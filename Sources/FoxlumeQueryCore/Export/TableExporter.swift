import Foundation

/// Exports whole tables to CSV, JSON, NDJSON or SQL files, streaming rows page by page.
///
/// Runs synchronously on the caller's thread against one `DatabaseConnection`, so call it from the
/// session queue (`DatabaseSession.run`) of a session used for nothing else: the export holds a
/// read-only snapshot transaction open for its whole run.
public final class TableExporter {
    private let connection: DatabaseConnection
    private let options: TableExportOptions
    private let cancellation: OperationCancellation
    private let databaseName: String?
    /// Literals in the output file. PostgreSQL files switch standard_conforming_strings on and MySQL files
    /// reset SQL_MODE, so backslashes are escaped exactly as these fixed dialects expect.
    private let outputDialect: SQLDialect
    private var warnings: [String] = []

    public init(connection: DatabaseConnection, options: TableExportOptions, cancellation: OperationCancellation = OperationCancellation(), databaseName: String? = nil) {
        self.connection = connection
        self.options = options
        self.cancellation = cancellation
        self.databaseName = databaseName ?? connection.currentDatabase
        switch connection.dialect.family {
        case .postgresql: outputDialect = .postgresql
        case .mysql: outputDialect = .mysql
        case .sqlite: outputDialect = .sqlite
        case .duckdb: outputDialect = .duckdb
        }
    }

    private struct Prepared {
        var item: TableExportItem
        var condition: String
        var structure: TableStructure?
        var total: Int?
        var rows = 0
    }

    // MARK: Run

    public func export(_ items: [TableExportItem], to destination: TableExportDestination, progress: @escaping (TableExportProgress) -> Void = { _ in }) throws -> TableExportReport {
        guard !items.isEmpty else { throw DatabaseError.unsupported("Choose at least one table to export.") }
        let started = Date()
        warnings = []
        var prepared = try items.map { Prepared(item: $0, condition: try TableExportItem.validatedCondition($0.whereClause)) }

        try beginSnapshot()
        var writers: [ExportFileWriter] = []
        do {
            for index in prepared.indices {
                try cancellation.check()
                prepared[index].structure = loadStructure(prepared[index].item)
            }
            if options.format == .sql {
                let order = Self.dependencyOrder(prepared.map { ($0.item, $0.structure) })
                prepared = order.map { prepared[$0] }
            }
            for index in prepared.indices where wantsData(prepared[index].item) {
                try cancellation.check()
                prepared[index].total = try count(prepared[index])
            }
            let grandTotal = prepared.contains { wantsData($0.item) && $0.total == nil } ? nil : prepared.reduce(0) { $0 + ($1.total ?? 0) }
            var tracker = ProgressTracker(tableCount: prepared.count, grandTotal: grandTotal, report: progress)

            if options.writesFilePerTable(tableCount: prepared.count) {
                guard case .directory(let folder) = destination else {
                    throw DatabaseError.unsupported("Choose a folder: each table is written to its own file.")
                }
                let names = Self.fileNames(for: prepared.map(\.item.table), extension: options.fileExtension())
                for index in prepared.indices {
                    let writer = try ExportFileWriter(destination: folder.appendingPathComponent(names[index]), compress: compresses)
                    writers.append(writer)
                    try writeFile(&prepared[index...index], writer: writer, tracker: &tracker)
                }
            } else {
                let url: URL
                switch destination {
                case .file(let file): url = file
                case .directory(let folder):
                    url = folder.appendingPathComponent(Self.fileNames(for: [prepared[0].item.table], extension: options.fileExtension())[0])
                }
                let writer = try ExportFileWriter(destination: url, compress: compresses)
                writers.append(writer)
                try writeFile(&prepared[...], writer: writer, tracker: &tracker)
            }
            try cancellation.check()
            endSnapshot(commit: true)
            // Every file is complete before any of them replaces what is on disk.
            for writer in writers { try writer.commit() }
        } catch {
            for writer in writers { writer.discard() }
            endSnapshot(commit: false)
            throw cancellation.isCancelled ? DatabaseError.cancelled : error
        }
        return TableExportReport(
            files: writers.map(\.destination),
            tables: prepared.map { ($0.item.table, $0.rows) },
            totalRows: prepared.reduce(0) { $0 + $1.rows },
            warnings: warnings,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    private var compresses: Bool { options.format == .sql && options.compress }

    private func wantsData(_ item: TableExportItem) -> Bool {
        options.format != .sql || (item.includeData && !item.isView)
    }

    private struct ProgressTracker {
        let tableCount: Int
        let grandTotal: Int?
        let report: (TableExportProgress) -> Void
        var totalRows = 0

        mutating func update(index: Int, table: TableRef, rows: Int, total: Int?, added: Int) {
            totalRows += added
            report(TableExportProgress(tableIndex: index, tableCount: tableCount, table: table, tableRows: rows, tableTotal: total, totalRows: totalRows, grandTotal: grandTotal))
        }
    }

    // MARK: Snapshot

    /// One read-only snapshot for every table, so related tables agree with each other.
    private func beginSnapshot() throws {
        switch connection.dialect.family {
        case .postgresql:
            _ = try connection.execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY", rowLimit: nil)
            // A dump of a large table must not trip a statement_timeout meant for interactive queries.
            _ = try? connection.execute("SET LOCAL statement_timeout = 0", rowLimit: nil)
        case .mysql:
            _ = try connection.execute("START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY", rowLimit: nil)
        case .sqlite, .duckdb:
            break
        }
    }

    private func endSnapshot(commit: Bool) {
        switch connection.dialect.family {
        case .postgresql, .mysql:
            _ = try? connection.execute(commit ? "COMMIT" : "ROLLBACK", rowLimit: nil)
        case .sqlite, .duckdb:
            break
        }
    }

    // MARK: Metadata

    private func loadStructure(_ item: TableExportItem) -> TableStructure? {
        do {
            return try connection.structure(of: item.table)
        } catch {
            warnings.append("Could not read the structure of \(item.table.name): \(TransferText.message(error))")
            return nil
        }
    }

    /// Rows the table will give, for progress. A failing count usually means a bad row filter, which is
    /// reported here rather than after the files were started.
    private func count(_ prepared: Prepared) throws -> Int? {
        let dialect = connection.dialect
        let sql = "SELECT COUNT(*) FROM \(dialect.qualifiedName(prepared.item.table))" + TableRowPagers.whereClause([prepared.condition])
        let value = try connection.execute(sql, rowLimit: nil).last { $0.hasResultSet }?.rows.first?.first?.textValue
        guard let counted = value.flatMap({ Int($0) }) else { return nil }
        return prepared.item.rowLimit.map { min($0, counted) } ?? counted
    }

    /// Positions of `entries` with parents before the tables whose foreign keys point at them, and views after
    /// tables. A foreign key cycle keeps the selection order for the tables involved.
    static func dependencyOrder(_ entries: [(item: TableExportItem, structure: TableStructure?)]) -> [Int] {
        let tables = entries.indices.filter { !entries[$0].item.isView }
        let views = entries.indices.filter { entries[$0].item.isView }
        let selected = Set(tables.map { entries[$0].item.table })
        var ordered: [Int] = []
        var placed = Set<TableRef>()
        var remaining = tables
        while !remaining.isEmpty {
            let readyIndex = remaining.firstIndex { position in
                let entry = entries[position]
                let parents = (entry.structure?.foreignKeys ?? []).map { normalized($0.referencedTable, like: entry.item.table) }
                return parents.allSatisfy { $0 == entry.item.table || !selected.contains($0) || placed.contains($0) }
            } ?? 0
            let next = remaining.remove(at: readyIndex)
            ordered.append(next)
            placed.insert(entries[next].item.table)
        }
        return ordered + views
    }

    /// Foreign keys on MySQL name the referenced table with a nil schema when it lives in the same database.
    private static func normalized(_ reference: TableRef, like table: TableRef) -> TableRef {
        reference.schema == nil ? TableRef(schema: table.schema, name: reference.name) : reference
    }

    /// `name.ext` per table; the schema is added when two tables would share a name.
    static func fileNames(for tables: [TableRef], extension ext: String) -> [String] {
        func clean(_ text: String) -> String {
            var result = text.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            if result.hasPrefix(".") { result = "_" + result.dropFirst() }
            return result.isEmpty ? "table" : result
        }
        let duplicates = Dictionary(grouping: tables, by: { $0.name.lowercased() }).filter { $0.value.count > 1 }.keys
        var used = Set<String>()
        return tables.map { table in
            var base = clean(table.name)
            if duplicates.contains(table.name.lowercased()), let schema = table.schema { base = clean(schema) + "." + base }
            var name = base + "." + ext
            var counter = 2
            while used.contains(name.lowercased()) {
                name = "\(base) \(counter).\(ext)"
                counter += 1
            }
            used.insert(name.lowercased())
            return name
        }
    }

    // MARK: Writing

    private func writeFile(_ tables: inout ArraySlice<Prepared>, writer: ExportFileWriter, tracker: inout ProgressTracker) throws {
        switch options.format {
        case .sql: try writeSQL(&tables, writer: writer, tracker: &tracker)
        case .csv: try writeCSV(&tables, writer: writer, tracker: &tracker)
        case .json: try writeJSON(&tables, writer: writer, tracker: &tracker)
        case .ndjson: try writeNDJSON(&tables, writer: writer, tracker: &tracker)
        }
    }

    /// Streams the rows of one table to `body`, page by page, updating progress and honouring Cancel.
    private func streamRows(_ prepared: inout Prepared, tracker: inout ProgressTracker, tableIndex: Int, body: (_ columns: [ResultColumn], _ rows: [[CellValue]]) throws -> Void) throws {
        let pager = try TableRowPagers.make(
            connection: connection,
            item: prepared.item,
            condition: prepared.condition,
            primaryKey: prepared.structure?.primaryKey ?? [],
            fetchSize: options.fetchSize
        )
        defer { pager.close() }
        tracker.update(index: tableIndex, table: prepared.item.table, rows: 0, total: prepared.total, added: 0)
        var first = true
        while true {
            try cancellation.check()
            guard let page = try pager.nextPage() else { break }
            if !first, page.rows.isEmpty { break }
            try body(page.columns, page.rows)
            first = false
            prepared.rows += page.rows.count
            tracker.update(index: tableIndex, table: prepared.item.table, rows: prepared.rows, total: prepared.total, added: page.rows.count)
        }
    }

    // MARK: CSV

    private func writeCSV(_ tables: inout ArraySlice<Prepared>, writer: ExportFileWriter, tracker: inout ProgressTracker) throws {
        if options.csvByteOrderMark { try writer.write("\u{FEFF}") }
        for index in tables.indices {
            var columns: [ExportColumn]?
            try streamRows(&tables[index], tracker: &tracker, tableIndex: index) { resultColumns, rows in
                if columns == nil {
                    let exportColumns = resultColumns.map(ExportColumn.init)
                    columns = exportColumns
                    if options.csvHeader { try writer.write(ExportValueEncoding.csvHeader(exportColumns, options: options)) }
                }
                guard let columns else { return }
                for row in rows {
                    try writer.write(ExportValueEncoding.csvRow(row, columns: columns, options: options))
                }
            }
        }
    }

    // MARK: JSON

    private func writeJSON(_ tables: inout ArraySlice<Prepared>, writer: ExportFileWriter, tracker: inout ProgressTracker) throws {
        let pretty = options.jsonPrettyPrint
        let keyed = tables.count > 1
        if keyed { try writer.write(pretty ? "{\n" : "{") }
        var firstTable = true
        for index in tables.indices {
            let indent = pretty ? (keyed ? "    " : "  ") : ""
            if keyed {
                let table = tables[index].item.table
                let key = table.schema.map { "\($0).\(table.name)" } ?? table.name
                try writer.write((firstTable ? "" : (pretty ? ",\n" : ",")) + (pretty ? "  " : "") + ResultExporter.jsonString(key) + (pretty ? ": " : ":"))
            }
            firstTable = false
            try writer.write("[")
            var firstRow = true
            var columns: [ExportColumn]?
            try streamRows(&tables[index], tracker: &tracker, tableIndex: index) { resultColumns, rows in
                if columns == nil { columns = resultColumns.map(ExportColumn.init) }
                guard let columns else { return }
                for row in rows {
                    let object = ExportValueEncoding.jsonObject(row, columns: columns, options: options, spaced: pretty)
                    try writer.write((firstRow ? "" : ",") + (pretty ? "\n" + indent : "") + object)
                    firstRow = false
                }
            }
            if pretty, !firstRow { try writer.write("\n" + (keyed ? "  " : "")) }
            try writer.write("]")
        }
        if keyed { try writer.write(pretty ? "\n}" : "}") }
        try writer.write("\n")
    }

    private func writeNDJSON(_ tables: inout ArraySlice<Prepared>, writer: ExportFileWriter, tracker: inout ProgressTracker) throws {
        for index in tables.indices {
            var columns: [ExportColumn]?
            try streamRows(&tables[index], tracker: &tracker, tableIndex: index) { resultColumns, rows in
                if columns == nil { columns = resultColumns.map(ExportColumn.init) }
                guard let columns else { return }
                for row in rows {
                    try writer.write(ExportValueEncoding.jsonObject(row, columns: columns, options: options, spaced: false) + "\n")
                }
            }
        }
    }

    // MARK: SQL

    private func writeSQL(_ tables: inout ArraySlice<Prepared>, writer: ExportFileWriter, tracker: inout ProgressTracker) throws {
        let dialect = outputDialect
        try writer.write(sqlHeader())
        try writer.write(sqlPrologue())

        let drops = tables.reversed().filter(\.item.includeDrop)
        if !drops.isEmpty {
            try writer.write("\n")
            for prepared in drops {
                try writer.write(dropStatement(prepared.item) + "\n")
            }
        }

        for index in tables.indices {
            try cancellation.check()
            let item = tables[index].item
            let structure = tables[index].structure
            try writer.write("\n--\n-- \(item.isView ? "View" : "Table"): \(dialect.qualifiedName(item.table))\n")
            if !tables[index].condition.isEmpty || item.rowLimit != nil, wantsData(item) {
                var scope: [String] = []
                if !tables[index].condition.isEmpty { scope.append("WHERE " + TransferText.snippet(tables[index].condition, limit: 300)) }
                if let limit = item.rowLimit { scope.append("first \(limit) rows") }
                try writer.write("-- Rows: \(scope.joined(separator: ", "))\n")
            }
            try writer.write("--\n\n")

            if item.includeStructure {
                if !item.isView { try writer.write(sequenceStatements(structure, table: item.table, phase: .beforeCreate)) }
                do {
                    try writer.write(cleanedDDL(try connection.ddl(of: item.table), isView: item.isView) + "\n")
                } catch {
                    warnings.append("Could not read the definition of \(item.table.name): \(TransferText.message(error))")
                    try writer.write("-- The definition could not be read: \(TransferText.snippet(TransferText.message(error)))\n")
                }
                if !item.isView { try writer.write(sequenceStatements(structure, table: item.table, phase: .afterCreate)) }
            }
            if wantsData(item) {
                if item.includeStructure { try writer.write("\n") }
                try writeInserts(&tables[index], writer: writer, tracker: &tracker, tableIndex: index)
                try writer.write(sequenceStatements(structure, table: item.table, phase: .afterData))
            }
        }
        try writer.write(sqlEpilogue())
    }

    private func sqlHeader() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        var lines = ["-- Foxlume Query SQL export"]
        let engine = connection.kind.displayName + (connection.serverVersion.isEmpty ? "" : " " + connection.serverVersion)
        lines.append("-- Source: \(engine)" + (databaseName.map { ", database \($0)" } ?? ""))
        lines.append("-- Created: \(formatter.string(from: Date()))")
        return lines.joined(separator: "\n") + "\n"
    }

    private func sqlPrologue() -> String {
        switch outputDialect.family {
        case .postgresql:
            return "\nSET client_encoding = 'UTF8';\nSET standard_conforming_strings = on;\n"
        case .mysql:
            return """

                SET NAMES utf8mb4;
                SET @FOXLUME_DUMP_FOREIGN_KEY_CHECKS = @@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS = 0;
                SET @FOXLUME_DUMP_SQL_MODE = @@SQL_MODE, SQL_MODE = 'NO_AUTO_VALUE_ON_ZERO';

                """
        case .sqlite, .duckdb:
            return ""
        }
    }

    private func sqlEpilogue() -> String {
        guard outputDialect.family == .mysql else { return "" }
        return "\nSET SQL_MODE = @FOXLUME_DUMP_SQL_MODE;\nSET FOREIGN_KEY_CHECKS = @FOXLUME_DUMP_FOREIGN_KEY_CHECKS;\n"
    }

    func dropStatement(_ item: TableExportItem) -> String {
        let name = outputDialect.qualifiedName(item.table)
        let object: String
        switch item.kind {
        case .view: object = "VIEW"
        case .materializedView: object = "MATERIALIZED VIEW"
        case .foreignTable: object = "FOREIGN TABLE"
        case .table, .systemTable, .keyspace: object = "TABLE"
        }
        // CASCADE also removes dependent views and foreign keys of tables outside the export, as a restore expects.
        let cascade = outputDialect.family == .postgresql ? " CASCADE" : ""
        return "DROP \(object) IF EXISTS \(name)\(cascade);"
    }

    /// MySQL definitions lose the AUTO_INCREMENT counter and the DEFINER clause when asked.
    func cleanedDDL(_ ddl: String, isView: Bool) -> String {
        guard outputDialect.family == .mysql else { return ddl }
        var text = ddl
        if options.stripAutoIncrement, !isView {
            text = text.replacingOccurrences(of: #"\s+AUTO_INCREMENT=\d+"#, with: "", options: .regularExpression)
        }
        if options.stripDefiner {
            text = text.replacingOccurrences(of: #"DEFINER\s*=\s*(`[^`]*`|'[^']*'|[^\s@]+)@(`[^`]*`|'[^']*'|\S+)\s+"#, with: "", options: .regularExpression)
        }
        return text
    }

    // MARK: Inserts

    private func writeInserts(_ prepared: inout Prepared, writer: ExportFileWriter, tracker: inout ProgressTracker, tableIndex: Int) throws {
        let dialect = outputDialect
        let table = dialect.qualifiedName(prepared.item.table)
        let structureColumns = prepared.structure?.columns ?? []
        let generated = Set(structureColumns.filter { Self.isGenerated($0, family: dialect.family) }.map(\.name))
        let overriding = dialect.family == .postgresql && structureColumns.contains { $0.extra == "GENERATED ALWAYS AS IDENTITY" }
        let perStatement = max(1, options.rowsPerInsert)
        let byteLimit = max(1024, options.maxStatementBytes)

        var prefix: String?
        var selected: [(index: Int, column: ExportColumn)] = []
        var open = false
        var rowsInStatement = 0
        var bytesInStatement = 0

        func close() throws {
            guard open else { return }
            try writer.write(";\n")
            open = false
        }

        try streamRows(&prepared, tracker: &tracker, tableIndex: tableIndex) { resultColumns, rows in
            if prefix == nil {
                selected = resultColumns.enumerated().filter { !generated.contains($0.element.name) }.map { ($0.offset, ExportColumn($0.element)) }
                let names = selected.map { dialect.quoteIdentifier($0.column.name) }.joined(separator: ", ")
                prefix = "INSERT INTO \(table) (\(names))" + (overriding ? " OVERRIDING SYSTEM VALUE" : "") + " VALUES"
            }
            guard let prefix, !selected.isEmpty else { return }
            for row in rows {
                let tuple = ExportValueEncoding.sqlTuple(row, columns: selected, dialect: dialect)
                if open, rowsInStatement >= perStatement || bytesInStatement + tuple.utf8.count > byteLimit {
                    try close()
                }
                if !open {
                    try writer.write(prefix + (perStatement == 1 ? " " : "\n") + tuple)
                    open = true
                    rowsInStatement = 1
                    bytesInStatement = prefix.utf8.count + tuple.utf8.count
                } else {
                    try writer.write(",\n" + tuple)
                    rowsInStatement += 1
                    bytesInStatement += tuple.utf8.count + 2
                }
            }
        }
        try close()
    }

    /// Computed columns cannot be inserted into; their values come back on their own.
    public static func isGenerated(_ column: ColumnInfo, family: SQLDialect.Family) -> Bool {
        guard let extra = column.extra?.uppercased() else { return false }
        switch family {
        case .postgresql: return extra.hasPrefix("GENERATED ALWAYS AS (")
        case .mysql: return extra.contains("VIRTUAL GENERATED") || extra.contains("STORED GENERATED")
        case .sqlite, .duckdb: return extra.contains("GENERATED")
        }
    }

    // MARK: PostgreSQL sequences

    enum SequencePhase {
        case beforeCreate
        case afterCreate
        case afterData
    }

    /// Serial columns use a sequence that DROP TABLE removes with the table: recreate it before CREATE TABLE,
    /// hand it back to the column afterwards, and move every serial or identity sequence past the imported rows.
    func sequenceStatements(_ structure: TableStructure?, table: TableRef, phase: SequencePhase) -> String {
        guard outputDialect.family == .postgresql, let structure else { return "" }
        let dialect = outputDialect
        let qualified = dialect.qualifiedName(table)
        var lines: [String] = []
        for column in structure.columns {
            let sequence = column.defaultValue.flatMap(Self.serialSequence)
            switch phase {
            case .beforeCreate:
                if let sequence { lines.append("CREATE SEQUENCE IF NOT EXISTS \(sequence);") }
            case .afterCreate:
                if let sequence { lines.append("ALTER SEQUENCE \(sequence) OWNED BY \(qualified).\(dialect.quoteIdentifier(column.name));") }
            case .afterData:
                guard column.isAutoIncrement else { continue }
                let name = dialect.quoteIdentifier(column.name)
                lines.append("SELECT pg_catalog.setval(pg_catalog.pg_get_serial_sequence(\(dialect.quoteString(qualified)), \(dialect.quoteString(column.name))), COALESCE(MAX(\(name)), 0) + 1, false) FROM \(qualified);")
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// The sequence named in `nextval('name'::regclass)`, as SQL text.
    static func serialSequence(in defaultValue: String) -> String? {
        guard let range = defaultValue.range(of: #"^nextval\('((?:[^']|'')+)'::regclass\)$"#, options: .regularExpression) else { return nil }
        let inner = defaultValue[range].dropFirst("nextval('".count).dropLast("'::regclass)".count)
        return inner.replacingOccurrences(of: "''", with: "'")
    }
}

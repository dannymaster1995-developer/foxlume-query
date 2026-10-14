import Foundation
import SQLite3

public final class SQLiteConnection: DatabaseConnection {
    public let kind: DatabaseKind = .sqlite
    public let dialect: SQLDialect = .sqlite
    public private(set) var serverVersion: String = ""

    private let parameters: ConnectionParameters
    private var handle: OpaquePointer?
    private let handleLock = NSLock()

    public init(parameters: ConnectionParameters) {
        self.parameters = parameters
    }

    deinit { close() }

    public func connect() throws {
        let path = (parameters.config.filePath as NSString).expandingTildeInPath
        guard !path.isEmpty else { throw DatabaseError.connection("Choose a SQLite database file.") }
        var flags = SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        flags |= parameters.config.readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var db: OpaquePointer?
        let status = sqlite3_open_v2(path, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "error \(status)"
            if let db { sqlite3_close_v2(db) }
            throw DatabaseError.connection("Cannot open \(path): \(message)")
        }
        sqlite3_busy_timeout(db, 5000)
        sqlite3_extended_result_codes(db, 1)
        handleLock.lock()
        handle = db
        handleLock.unlock()
        serverVersion = String(cString: sqlite3_libversion())
        _ = try? execute("PRAGMA foreign_keys = ON", rowLimit: nil)
    }

    public func close() {
        handleLock.lock()
        let db = handle
        handle = nil
        handleLock.unlock()
        if let db { sqlite3_close_v2(db) }
    }

    public func cancel() {
        handleLock.lock()
        defer { handleLock.unlock() }
        if let handle { sqlite3_interrupt(handle) }
    }

    private func db() throws -> OpaquePointer {
        guard let handle else { throw DatabaseError.notConnected }
        return handle
    }

    private func error(_ db: OpaquePointer, code: Int32) -> DatabaseError {
        if code == SQLITE_INTERRUPT { return .cancelled }
        let message = String(cString: sqlite3_errmsg(db))
        return .server(message: message, code: String(sqlite3_extended_errcode(db)))
    }

    public func execute(_ sql: String, rowLimit: Int?) throws -> [StatementResult] {
        let db = try db()
        var results: [StatementResult] = []
        try sql.withCString { start in
            var cursor: UnsafePointer<CChar>? = start
            while let current = cursor, current.pointee != 0 {
                var statement: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                let began = Date()
                let prepareStatus = sqlite3_prepare_v2(db, current, -1, &statement, &tail)
                guard prepareStatus == SQLITE_OK else { throw error(db, code: prepareStatus) }
                cursor = tail
                guard let statement else { continue }
                defer { sqlite3_finalize(statement) }
                var result = try step(statement, db: db, rowLimit: rowLimit)
                result.elapsed = Date().timeIntervalSince(began)
                results.append(result)
            }
        }
        return results
    }

    private func step(_ statement: OpaquePointer, db: OpaquePointer, rowLimit: Int?) throws -> StatementResult {
        let columnCount = Int(sqlite3_column_count(statement))
        var columns: [ResultColumn] = []
        for index in 0..<columnCount {
            let name = sqlite3_column_name(statement, Int32(index)).map { String(cString: $0) } ?? "?"
            let declared = sqlite3_column_decltype(statement, Int32(index)).map { String(cString: $0) } ?? ""
            let table = sqlite3_column_table_name(statement, Int32(index)).map { String(cString: $0) }
            columns.append(ResultColumn(name: name, typeName: declared, isNumeric: Self.isNumericType(declared), tableName: table))
        }

        let changesBefore = sqlite3_total_changes64(db)
        var rows: [[CellValue]] = []
        var truncated = false
        var sawNumericValue = Array(repeating: false, count: columnCount)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw error(db, code: status) }
            if let rowLimit, rows.count >= rowLimit {
                truncated = true
                continue
            }
            var row: [CellValue] = []
            row.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                let i = Int32(index)
                switch sqlite3_column_type(statement, i) {
                case SQLITE_NULL:
                    row.append(.null)
                case SQLITE_INTEGER:
                    sawNumericValue[index] = true
                    row.append(.text(String(sqlite3_column_int64(statement, i))))
                case SQLITE_FLOAT:
                    sawNumericValue[index] = true
                    row.append(.text(Self.format(sqlite3_column_double(statement, i))))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, i))
                    if let pointer = sqlite3_column_blob(statement, i), count > 0 {
                        row.append(.bytes(Data(bytes: pointer, count: count)))
                    } else {
                        row.append(.bytes(Data()))
                    }
                default:
                    if let text = sqlite3_column_text(statement, i) {
                        row.append(.text(String(cString: text)))
                    } else {
                        row.append(.null)
                    }
                }
            }
            rows.append(row)
        }
        for index in 0..<columnCount where columns[index].typeName.isEmpty && sawNumericValue[index] {
            columns[index].isNumeric = true
        }

        if columnCount > 0 {
            return StatementResult(columns: columns, rows: rows, truncated: truncated)
        }
        let readOnly = sqlite3_stmt_readonly(statement) != 0
        let changed = Int(sqlite3_total_changes64(db) - changesBefore)
        let verb = sqlite3_sql(statement).map { String(cString: $0) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1).first.map { $0.uppercased() } ?? "OK"
        return StatementResult(
            affectedRows: readOnly ? nil : changed,
            message: readOnly ? verb : "\(verb) \(changed)"
        )
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 { return String(format: "%.1f", value) }
        return String(value)
    }

    static func isNumericType(_ declared: String) -> Bool {
        let upper = declared.uppercased()
        return ["INT", "REAL", "FLOA", "DOUB", "NUM", "DEC"].contains { upper.contains($0) }
    }

    // MARK: - Metadata

    public func databases() throws -> [String] {
        try execute("PRAGMA database_list", rowLimit: nil).first?.rows.compactMap { $0[1].textValue } ?? ["main"]
    }

    public var currentDatabase: String? { "main" }

    public func useDatabase(_ name: String) throws {
        guard name == "main" else { throw DatabaseError.unsupported("SQLite has one database per file.") }
    }

    public func schemas() throws -> [String] { [] }

    public var defaultSchema: String? { nil }

    public func tables(schema: String?) throws -> [TableInfo] {
        let rows = try execute(
            "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name",
            rowLimit: nil
        ).first?.rows ?? []
        return rows.compactMap { row in
            guard let name = row[0].textValue else { return nil }
            let type = row[1].textValue ?? "table"
            let kind: TableKind = type == "view" ? .view : (name.hasPrefix("sqlite_") ? .systemTable : .table)
            return TableInfo(ref: TableRef(name: name), kind: kind)
        }
    }

    public func structure(of table: TableRef) throws -> TableStructure {
        let quoted = dialect.quoteString(table.name)
        let columnRows = try execute("SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_xinfo(\(quoted)) WHERE hidden IN (0, 2, 3)", rowLimit: nil).first?.rows ?? []
        let ddl = (try? self.ddl(of: table)) ?? ""
        let hasAutoincrement = ddl.uppercased().contains("AUTOINCREMENT")
        var pkColumns: [(Int, String)] = []
        var columns: [ColumnInfo] = []
        for row in columnRows {
            let name = row[0].textValue ?? ""
            let type = row[1].textValue ?? ""
            let pkOrder = Int(row[4].textValue ?? "0") ?? 0
            if pkOrder > 0 { pkColumns.append((pkOrder, name)) }
            columns.append(ColumnInfo(
                name: name,
                dataType: type,
                isNullable: row[2].textValue == "0",
                defaultValue: row[3].textValue,
                isPrimaryKey: pkOrder > 0,
                isAutoIncrement: pkOrder > 0 && type.uppercased() == "INTEGER" && (hasAutoincrement || columnRows.filter { ($0[4].textValue ?? "0") != "0" }.count == 1)
            ))
        }

        var indexes: [IndexInfo] = []
        if !pkColumns.isEmpty {
            indexes.append(IndexInfo(name: "PRIMARY", columns: pkColumns.sorted { $0.0 < $1.0 }.map(\.1), isUnique: true, isPrimary: true))
        }
        let indexRows = try execute("SELECT name, \"unique\", origin FROM pragma_index_list(\(quoted))", rowLimit: nil).first?.rows ?? []
        for row in indexRows {
            guard let name = row[0].textValue, row[2].textValue != "pk" else { continue }
            let cols = try execute("SELECT name FROM pragma_index_info(\(dialect.quoteString(name))) ORDER BY seqno", rowLimit: nil)
                .first?.rows.compactMap { $0[0].textValue } ?? []
            indexes.append(IndexInfo(name: name, columns: cols, isUnique: row[1].textValue == "1", isPrimary: false))
        }

        var foreignKeys: [String: ForeignKeyInfo] = [:]
        let fkRows = try execute("SELECT id, \"table\", \"from\", \"to\", on_update, on_delete FROM pragma_foreign_key_list(\(quoted)) ORDER BY id, seq", rowLimit: nil).first?.rows ?? []
        for row in fkRows {
            let id = row[0].textValue ?? "0"
            var fk = foreignKeys[id] ?? ForeignKeyInfo(
                name: "fk_\(table.name)_\(id)",
                columns: [],
                referencedTable: TableRef(name: row[1].textValue ?? ""),
                referencedColumns: [],
                onUpdate: row[4].textValue,
                onDelete: row[5].textValue
            )
            fk.columns.append(row[2].textValue ?? "")
            fk.referencedColumns.append(row[3].textValue ?? "")
            foreignKeys[id] = fk
        }
        return TableStructure(
            table: table,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys.keys.sorted().compactMap { foreignKeys[$0] }
        )
    }

    public func ddl(of table: TableRef) throws -> String {
        let rows = try execute(
            "SELECT sql FROM sqlite_master WHERE tbl_name = \(dialect.quoteString(table.name)) AND sql IS NOT NULL ORDER BY type = 'table' DESC, name",
            rowLimit: nil
        ).first?.rows ?? []
        return rows.compactMap { $0[0].textValue }.map { $0 + ";" }.joined(separator: "\n\n")
    }
}

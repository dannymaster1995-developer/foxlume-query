import Foundation

/// Every option of the Import CSV sheet. Codable so the last choices can be remembered.
public struct CSVImportOptions: Hashable, Sendable, Codable {
    public var encoding: ImportTextEncoding = .automatic
    /// Nil detects the delimiter from the start of the file.
    public var delimiter: CSVDelimiter?
    public var hasHeaderRow = true
    public var trimWhitespace = false
    /// An empty field becomes NULL. A quoted empty field (`""`) stays an empty string in text columns.
    public var emptyAsNull = true
    /// Extra text that means NULL, such as `\N` or `NULL`. Empty for none.
    public var nullToken = ""
    /// Stop and Roll Back runs in one transaction; the other policies commit as they go.
    public var errorPolicy: ImportErrorPolicy = .stopAndRollBack
    /// DELETE every row of the target table before importing (inside the transaction when there is one).
    public var deleteExistingRows = false
    public var rowsPerInsert = 500
    public var maxStatementBytes = 1 << 20

    public init() {}
}

/// One source field going into one target column.
public struct CSVColumnMapping: Hashable, Sendable {
    public var sourceIndex: Int
    public var column: String

    public init(sourceIndex: Int, column: String) {
        self.sourceIndex = sourceIndex
        self.column = column
    }
}

public struct CSVImportProgress: Sendable, Equatable {
    public var rowsRead: Int
    public var rowsImported: Int
    public var rowsSkipped: Int
    public var bytesRead: Int64
    public var totalBytes: Int64
}

public struct CSVImportReport: Sendable {
    public var rowsRead: Int
    public var rowsImported: Int
    public var rowsSkipped: Int
    /// Failures that were skipped (at most `CSVImporter.maxIssues`).
    public var issues: [ImportIssue]
    /// The failure that stopped the import, if any.
    public var failure: ImportIssue?
    public var cancelled: Bool
    /// True when the transaction was rolled back, so nothing was imported.
    public var rolledBack: Bool
    public var elapsed: TimeInterval
}

/// Header names and column matching for the mapping step.
public enum CSVImportMapping {
    /// Header names trimmed, blanks named "Column N", repeats numbered "name 2".
    public static func headerNames(_ record: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return record.enumerated().map { index, raw in
            var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = "Column \(index + 1)" }
            let key = name.lowercased()
            if let count = seen[key] {
                seen[key] = count + 1
                name += " \(count + 1)"
            } else {
                seen[key] = 1
            }
            return name
        }
    }

    /// Generic names for files without a header row.
    public static func positionalNames(count: Int) -> [String] {
        (0..<count).map { "Column \($0 + 1)" }
    }

    /// Source fields matched to columns by exact name, then ignoring case. Each column is used once.
    public static func byName(sources: [String], columns: [String]) -> [CSVColumnMapping] {
        var used = Set<String>()
        var chosen: [Int: String] = [:]
        for (index, source) in sources.enumerated() {
            if let column = columns.first(where: { $0 == source }), !used.contains(column) {
                chosen[index] = column
                used.insert(column)
            }
        }
        for (index, source) in sources.enumerated() where chosen[index] == nil {
            if let column = columns.first(where: { $0.lowercased() == source.lowercased() && !used.contains($0) }) {
                chosen[index] = column
                used.insert(column)
            }
        }
        return chosen.sorted { $0.key < $1.key }.map { CSVColumnMapping(sourceIndex: $0.key, column: $0.value) }
    }

    /// The first field into the first column, and so on.
    public static func byPosition(sourceCount: Int, columns: [String]) -> [CSVColumnMapping] {
        (0..<min(sourceCount, columns.count)).map { CSVColumnMapping(sourceIndex: $0, column: columns[$0]) }
    }

    /// Why `mapping` cannot run, or nil when it can.
    public static func problem(with mapping: [CSVColumnMapping], columns: [ColumnInfo]) -> String? {
        guard !mapping.isEmpty else { return "Map at least one field to a column." }
        var seen = Set<String>()
        for entry in mapping {
            guard let column = columns.first(where: { $0.name == entry.column }) else {
                return "The table has no column named \(entry.column)."
            }
            if !seen.insert(entry.column).inserted { return "Two fields are mapped to \(entry.column)." }
            if TableExporter.isGenerated(column, family: .postgresql) || TableExporter.isGenerated(column, family: .mysql) {
                return "\(entry.column) is a generated column and cannot be imported into."
            }
        }
        return nil
    }
}

/// Imports a CSV file, or the records of any `ImportRecordReader` (JSON, NDJSON, XLSX), into an existing
/// table with multi-row INSERTs.
///
/// Values are sent as quoted text and the server converts them to the column types, so dates, numbers,
/// booleans, JSON and UUIDs need no parsing here. Runs synchronously; call it on the session queue of a
/// session used only for this import.
public final class CSVImporter {
    public static let maxIssues = 1000

    private let connection: DatabaseConnection
    private let table: TableRef
    private let structure: TableStructure
    private let mapping: [CSVColumnMapping]
    private let options: CSVImportOptions
    private let cancellation: OperationCancellation

    public init(connection: DatabaseConnection, table: TableRef, structure: TableStructure, mapping: [CSVColumnMapping], options: CSVImportOptions, cancellation: OperationCancellation = OperationCancellation()) {
        self.connection = connection
        self.table = table
        self.structure = structure
        self.mapping = mapping.sorted { $0.sourceIndex < $1.sourceIndex }
        self.options = options
        self.cancellation = cancellation
    }

    private struct PendingRow {
        var line: Int
        var tuple: String
        var preview: String
    }

    private struct State {
        var rowsRead = 0
        var imported = 0
        var skipped = 0
        var issues: [ImportIssue] = []
        var failure: ImportIssue?
        /// Rows of the batch that failed inside the transaction, to find the bad one after the rollback.
        var failedBatch: [PendingRow] = []
    }

    public func run(file: URL, progress: @escaping (CSVImportProgress) -> Void = { _ in }) throws -> CSVImportReport {
        if let problem = CSVImportMapping.problem(with: mapping, columns: structure.columns) {
            throw DatabaseError.unsupported(problem)
        }
        let delimiter = try options.delimiter ?? CSVReader.preview(url: file, delimiter: nil, encoding: options.encoding, limit: 0).delimiter
        let reader = try CSVReader(url: file, delimiter: delimiter, encoding: options.encoding)
        return try run(reader: reader, skipFirstRecord: options.hasHeaderRow, progress: progress)
    }

    /// Imports the records of `reader`. `skipFirstRecord` drops a header row; `binaryAsBase64` reads text going
    /// into binary columns as Base64 (how JSON exports write bytes) as well as `0x…` hex.
    public func run(reader: ImportRecordReader, skipFirstRecord: Bool, binaryAsBase64: Bool = false, progress: @escaping (CSVImportProgress) -> Void = { _ in }) throws -> CSVImportReport {
        let started = Date()
        if let problem = CSVImportMapping.problem(with: mapping, columns: structure.columns) {
            throw DatabaseError.unsupported(problem)
        }
        let dialect = connection.dialect
        let columns = mapping.map { entry in structure.columns.first { $0.name == entry.column } }
        let overriding = dialect.family == .postgresql && columns.contains { $0?.extra == "GENERATED ALWAYS AS IDENTITY" }
        let prefix = "INSERT INTO \(dialect.qualifiedName(table)) (" + mapping.map { dialect.quoteIdentifier($0.column) }.joined(separator: ", ") + ")"
            + (overriding ? " OVERRIDING SYSTEM VALUE" : "") + " VALUES "
        let inTransaction = options.errorPolicy == .stopAndRollBack

        var state = State()
        func report(cancelled: Bool, rolledBack: Bool) -> CSVImportReport {
            CSVImportReport(
                rowsRead: state.rowsRead,
                rowsImported: rolledBack ? 0 : state.imported,
                rowsSkipped: state.skipped,
                issues: state.issues,
                failure: state.failure,
                cancelled: cancelled,
                rolledBack: rolledBack,
                elapsed: Date().timeIntervalSince(started)
            )
        }
        func notify() {
            progress(CSVImportProgress(rowsRead: state.rowsRead, rowsImported: state.imported, rowsSkipped: state.skipped, bytesRead: reader.bytesRead, totalBytes: reader.totalBytes))
        }

        if inTransaction { _ = try connection.execute(dialect.beginStatement, rowLimit: nil) }
        do {
            if options.deleteExistingRows {
                _ = try connection.execute("DELETE FROM \(dialect.qualifiedName(table))", rowLimit: nil)
            }
            var batch: [PendingRow] = []
            var batchBytes = 0
            var isFirst = true

            /// Inserts the batch. Returns false when the policy says to stop.
            func flush() throws -> Bool {
                guard !batch.isEmpty else { return true }
                defer {
                    batch.removeAll(keepingCapacity: true)
                    batchBytes = 0
                }
                do {
                    _ = try connection.execute(prefix + batch.map(\.tuple).joined(separator: ", "), rowLimit: nil)
                    state.imported += batch.count
                    return true
                } catch let error as DatabaseError where Self.isRowError(error) {
                    // A cancelled statement can come back as an ordinary server error (MySQL KILL QUERY).
                    try cancellation.check()
                    if inTransaction {
                        // The transaction is gone either way; name the rows and stop.
                        let first = batch[0].line
                        let last = batch[batch.count - 1].line
                        let snippet = batch.count == 1 ? batch[0].preview : "Rows starting on lines \(first)–\(last)"
                        state.failure = ImportIssue(line: first, snippet: snippet, message: TransferText.message(error))
                        if batch.count > 1 { state.failedBatch = batch }
                        return false
                    }
                    // Outside a transaction the failed statement changed nothing: retry row by row to find the bad rows.
                    for row in batch {
                        try cancellation.check()
                        do {
                            _ = try connection.execute(prefix + row.tuple, rowLimit: nil)
                            state.imported += 1
                        } catch let rowError as DatabaseError where Self.isRowError(rowError) {
                            try cancellation.check()
                            let issue = ImportIssue(line: row.line, snippet: row.preview, message: TransferText.message(rowError))
                            if options.errorPolicy == .skipAndContinue {
                                state.skipped += 1
                                if state.issues.count < Self.maxIssues { state.issues.append(issue) }
                            } else {
                                state.failure = issue
                                return false
                            }
                        }
                    }
                    return true
                }
            }

            readLoop: while let record = try reader.next() {
                if isFirst {
                    isFirst = false
                    if skipFirstRecord { continue }
                }
                state.rowsRead += 1
                var values: [String] = []
                values.reserveCapacity(mapping.count)
                for (position, entry) in mapping.enumerated() {
                    let field = entry.sourceIndex < record.fields.count ? record.fields[entry.sourceIndex] : CSVField("")
                    values.append(Self.literal(field, column: columns[position], options: options, dialect: dialect, base64: binaryAsBase64))
                }
                let tuple = "(" + values.joined(separator: ", ") + ")"
                batch.append(PendingRow(line: record.line, tuple: tuple, preview: reader.snippet(record)))
                batchBytes += tuple.utf8.count
                if batch.count >= max(1, options.rowsPerInsert) || batchBytes >= options.maxStatementBytes {
                    try cancellation.check()
                    if try !flush() { break readLoop }
                    notify()
                }
            }
            if state.failure == nil {
                try cancellation.check()
                _ = try flush()
            }
            notify()
            if inTransaction {
                if state.failure != nil {
                    _ = try? connection.execute("ROLLBACK", rowLimit: nil)
                    if let exact = locateFailure(in: state.failedBatch, prefix: prefix) { state.failure = exact }
                    return report(cancelled: false, rolledBack: true)
                }
                _ = try connection.execute("COMMIT", rowLimit: nil)
            }
            return report(cancelled: false, rolledBack: false)
        } catch {
            if inTransaction { _ = try? connection.execute("ROLLBACK", rowLimit: nil) }
            if cancellation.isCancelled || (error as? DatabaseError).map({ if case .cancelled = $0 { return true } else { return false } }) == true {
                return report(cancelled: true, rolledBack: inTransaction)
            }
            throw error
        }
    }

    /// Replays a failed batch row by row in a throwaway transaction to name the exact bad row.
    /// Returns nil when every row passes alone (the conflict was with an earlier, rolled back batch).
    private func locateFailure(in batch: [PendingRow], prefix: String) -> ImportIssue? {
        guard !batch.isEmpty, (try? connection.execute(connection.dialect.beginStatement, rowLimit: nil)) != nil else { return nil }
        defer { _ = try? connection.execute("ROLLBACK", rowLimit: nil) }
        if options.deleteExistingRows {
            guard (try? connection.execute("DELETE FROM \(connection.dialect.qualifiedName(table))", rowLimit: nil)) != nil else { return nil }
        }
        for row in batch {
            guard !cancellation.isCancelled else { return nil }
            do {
                _ = try connection.execute(prefix + row.tuple, rowLimit: nil)
            } catch let error as DatabaseError where Self.isRowError(error) {
                return ImportIssue(line: row.line, snippet: row.preview, message: TransferText.message(error))
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Errors about the data (bad value, constraint) as opposed to a lost connection.
    static func isRowError(_ error: DatabaseError) -> Bool {
        switch error {
        case .server, .unsupported: return true
        case .connection, .authentication, .protocolViolation, .cancelled, .queryTimeout, .notConnected: return false
        }
    }

    // MARK: Values

    /// The SQL literal for one field going into `column`.
    static func literal(_ field: CSVField, column: ColumnInfo?, options: CSVImportOptions, dialect: SQLDialect, base64: Bool = false) -> String {
        if field.isNull { return "NULL" }
        var text = field.text
        if options.trimWhitespace { text = text.trimmingCharacters(in: .whitespaces) }
        let type = column?.dataType.lowercased() ?? ""
        if text.isEmpty, options.emptyAsNull, !field.wasQuoted || !isTextLike(type) {
            return "NULL"
        }
        if !options.nullToken.isEmpty, text == options.nullToken { return "NULL" }
        // MySQL BIT values export as 0x… like binary ones.
        if isBinary(type) || (dialect.family == .mysql && type.hasPrefix("bit")),
           let data = base64 ? Data(base64Encoded: text) ?? hexData(text) : hexData(text) {
            return dialect.literal(.bytes(data))
        }
        if dialect.family == .mysql || dialect.family == .sqlite, !type.isEmpty, !isTextLike(type) {
            // MySQL in strict mode refuses the words true and false for numeric and BIT columns; SQLite would
            // store them as text in its BOOLEAN (numeric) columns.
            switch text.lowercased() {
            case "true": return "1"
            case "false": return "0"
            default: break
            }
            if type.hasPrefix("bit"), !text.isEmpty, text.allSatisfy(\.isASCIIDigit) { return text }
        }
        return dialect.quoteString(text)
    }

    /// Types where an empty string is a real value rather than a missing one.
    static func isTextLike(_ type: String) -> Bool {
        guard !type.isEmpty else { return true }
        return ["char", "text", "clob", "string", "enum", "set", "name", "blob", "binary", "bytea"].contains { type.contains($0) }
    }

    static func isBinary(_ type: String) -> Bool {
        ["blob", "binary", "bytea"].contains { type.contains($0) }
    }

    /// Bytes of `0x…` text, as CSV exports write binary values.
    static func hexData(_ text: String) -> Data? {
        guard text.count >= 2, text.hasPrefix("0x") || text.hasPrefix("0X") else { return nil }
        let digits = Array(text.utf8.dropFirst(2))
        guard digits.count % 2 == 0 else { return nil }
        var data = Data(capacity: digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = hexValue(digits[index]), let low = hexValue(digits[index + 1]) else { return nil }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

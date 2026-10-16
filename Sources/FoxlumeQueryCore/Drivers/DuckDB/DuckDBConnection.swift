import CDuckDB
import Foundation

/// What a DuckDB connection opens, decided from the file path.
enum DuckDBSource: Equatable {
    case memory
    /// A DuckDB database file, created when missing.
    case database(path: String)
    /// A Parquet, CSV, TSV, JSON or NDJSON file, shown as a view in an in-memory database.
    case dataFile(path: String, reader: String)

    static let dataFileExtensions: Set<String> = ["parquet", "csv", "tsv", "json", "ndjson"]

    init(filePath: String) {
        let trimmed = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ":memory:" else {
            self = .memory
            return
        }
        let path = (trimmed as NSString).expandingTildeInPath
        let literal = SQLDialect.duckdb.quoteString(path)
        switch (path as NSString).pathExtension.lowercased() {
        case "parquet": self = .dataFile(path: path, reader: "read_parquet(\(literal))")
        case "csv": self = .dataFile(path: path, reader: "read_csv_auto(\(literal))")
        case "tsv": self = .dataFile(path: path, reader: "read_csv_auto(\(literal), delim = '\\t')")
        case "json": self = .dataFile(path: path, reader: "read_json_auto(\(literal))")
        case "ndjson": self = .dataFile(path: path, reader: "read_json_auto(\(literal), format = 'newline_delimited')")
        default: self = .database(path: path)
        }
    }

    var path: String? {
        switch self {
        case .memory: return nil
        case .database(let path), .dataFile(let path, _): return path
        }
    }

    /// The view over a data file is named after the file without its extension.
    var viewName: String? {
        guard case .dataFile(let path, _) = self else { return nil }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

/// DuckDB through its C API. The engine runs in-process, so every call blocks the session queue until DuckDB returns.
public final class DuckDBConnection: DatabaseConnection {
    public let kind: DatabaseKind = .duckdb
    public let dialect: SQLDialect = .duckdb
    public private(set) var serverVersion: String = ""

    private let parameters: ConnectionParameters
    private var database: duckdb_database?
    private var connection: duckdb_connection?
    /// Guards `connection` and `cancelRequested`, which `cancel()` touches from another thread.
    private let handleLock = NSLock()
    private var cancelRequested = false
    private(set) var source: DuckDBSource = .memory
    /// DuckDB cannot open an in-memory database read-only, so for data files (and read-only `:memory:`)
    /// the driver refuses writes itself.
    private var refusesWrites = false
    /// DuckDB's keywords, which it quotes when they name a STRUCT or UNION member in a type name.
    private var keywords: Set<String> = []

    /// Database files are opened through one process-wide cache so every session on a file shares a single
    /// DuckDB instance. DuckDB's file lock only keeps other processes out, and two instances in one process
    /// would each write the file without seeing the other's changes.
    private static let instanceCache: duckdb_instance_cache? = duckdb_create_instance_cache()

    public init(parameters: ConnectionParameters) {
        self.parameters = parameters
    }

    deinit { close() }

    // MARK: - Lifecycle

    public func connect() throws {
        let config = parameters.config
        let source = DuckDBSource(filePath: config.filePath)
        if case .dataFile(let path, _) = source, !FileManager.default.fileExists(atPath: path) {
            throw DatabaseError.connection("File not found: \(path)")
        }

        var configuration: duckdb_config?
        guard duckdb_create_config(&configuration) == DuckDBSuccess else {
            duckdb_destroy_config(&configuration)
            throw DatabaseError.connection("Cannot configure DuckDB.")
        }
        defer { duckdb_destroy_config(&configuration) }
        if config.readOnly, case .database = source {
            duckdb_set_config(configuration, "access_mode", "READ_ONLY")
        }

        var opened: duckdb_database?
        var openError: UnsafeMutablePointer<CChar>?
        let databasePath: String? = {
            if case .database(let path) = source { return path }
            return nil
        }()
        let status: duckdb_state
        if let databasePath, let cache = Self.instanceCache {
            status = duckdb_get_or_create_from_cache(cache, databasePath, &opened, configuration, &openError)
        } else {
            status = duckdb_open_ext(databasePath, &opened, configuration, &openError)
        }
        guard status == DuckDBSuccess, opened != nil else {
            let message = DuckDBType.takeString(openError) ?? "unknown error"
            if opened != nil { duckdb_close(&opened) }
            throw DatabaseError.connection(Self.openFailure(message, path: databasePath, readOnly: config.readOnly))
        }
        var connected: duckdb_connection?
        guard duckdb_connect(opened, &connected) == DuckDBSuccess, connected != nil else {
            duckdb_disconnect(&connected)
            duckdb_close(&opened)
            throw DatabaseError.connection("Cannot open a connection to the DuckDB database.")
        }

        handleLock.lock()
        database = opened
        connection = connected
        cancelRequested = false
        handleLock.unlock()
        self.source = source
        let version = String(cString: duckdb_library_version())
        serverVersion = version.hasPrefix("v") ? String(version.dropFirst()) : version

        keywords = Set((try? execute("SELECT keyword_name FROM duckdb_keywords()", rowLimit: nil))?.first?.rows.compactMap { $0.first?.textValue } ?? [])

        if case .dataFile(let path, let reader) = source, let viewName = source.viewName {
            do {
                _ = try execute("CREATE VIEW \(dialect.quoteIdentifier(viewName)) AS SELECT * FROM \(reader)", rowLimit: nil)
            } catch {
                close()
                throw DatabaseError.connection("Cannot read \(path): \(error.localizedDescription)")
            }
        }
        refusesWrites = source.viewName != nil || (source == .memory && config.readOnly)
        do {
            try applySessionSetup(config)
        } catch {
            close()
            throw error
        }
    }

    /// Rewrites DuckDB's lock conflict, which names the holder's executable and a documentation link,
    /// into a sentence that says which file is busy and what to do.
    static func openFailure(_ message: String, path: String?, readOnly: Bool) -> String {
        let file = path.map { ($0 as NSString).lastPathComponent } ?? "The database file"
        if message.contains("different configuration than existing connections") {
            return "\(file) is already open in Foxlume Query with a different read-only setting. Close that connection first."
        }
        guard message.contains("Could not set lock on file") else {
            return "Cannot open \(path ?? "the database"): \(message)"
        }
        var holder = "another process"
        if let start = message.range(of: "Conflicting lock is held in "),
           let pid = message.range(of: " (PID ", range: start.upperBound..<message.endIndex),
           let end = message.range(of: ")", range: pid.upperBound..<message.endIndex) {
            let executable = (String(message[start.upperBound..<pid.lowerBound]) as NSString).lastPathComponent
            holder = "\(executable) (PID \(message[pid.upperBound..<end.lowerBound]))"
        }
        if readOnly {
            return "\(file) is in use by \(holder), which has it open for writing. Close it there and try again."
        }
        return "\(file) is in use by \(holder). Close it there, or open the file read-only."
    }

    public func close() {
        handleLock.lock()
        var openConnection = connection
        var openDatabase = database
        connection = nil
        database = nil
        handleLock.unlock()
        if openConnection != nil { duckdb_disconnect(&openConnection) }
        if openDatabase != nil { duckdb_close(&openDatabase) }
    }

    public func cancel() {
        handleLock.lock()
        defer { handleLock.unlock() }
        guard let connection else { return }
        cancelRequested = true
        duckdb_interrupt(connection)
    }

    private func liveConnection() throws -> duckdb_connection {
        handleLock.lock()
        defer { handleLock.unlock() }
        guard let connection else { throw DatabaseError.notConnected }
        return connection
    }

    private func takeCancelRequest() -> Bool {
        handleLock.lock()
        defer { handleLock.unlock() }
        let requested = cancelRequested
        cancelRequested = false
        return requested
    }

    // MARK: - Statements

    public func execute(_ sql: String, rowLimit: Int?) throws -> [StatementResult] {
        let connection = try liveConnection()
        _ = takeCancelRequest()

        var extracted: duckdb_extracted_statements?
        let count = duckdb_extract_statements(connection, sql, &extracted)
        defer { duckdb_destroy_extracted(&extracted) }
        guard count > 0 else {
            if let extracted, let message = duckdb_extract_statements_error(extracted) {
                throw DatabaseError.server(message: String(cString: message), code: nil)
            }
            return []
        }

        // DuckDB does not hand back each statement's text, which the VARCHAR projection needs.
        // The splitter's pieces are used only when they line up one-to-one with DuckDB's statements.
        let pieces = SQLStatementSplitter.split(sql, family: .duckdb).map(\.text)
        let texts: [String?] = pieces.count == Int(count) ? pieces : Array(repeating: nil, count: Int(count))

        var results: [StatementResult] = []
        for index in 0..<Int(count) {
            if takeCancelRequest() { throw DatabaseError.cancelled }
            let began = Date()
            var prepared: duckdb_prepared_statement?
            let status = duckdb_prepare_extracted_statement(connection, extracted, idx_t(index), &prepared)
            defer { duckdb_destroy_prepare(&prepared) }
            guard status == DuckDBSuccess, let statement = prepared else {
                throw DatabaseError.server(message: prepared.flatMap { duckdb_prepare_error($0) }.map { String(cString: $0) } ?? "Cannot prepare the statement.", code: nil)
            }
            var result = try run(statement, text: texts[index], connection: connection, rowLimit: rowLimit)
            result.elapsed = Date().timeIntervalSince(began)
            results.append(result)
        }
        return results
    }

    private static let writingStatements = Set([
        DUCKDB_STATEMENT_TYPE_INSERT, DUCKDB_STATEMENT_TYPE_UPDATE, DUCKDB_STATEMENT_TYPE_DELETE,
        DUCKDB_STATEMENT_TYPE_CREATE, DUCKDB_STATEMENT_TYPE_CREATE_FUNC, DUCKDB_STATEMENT_TYPE_ALTER,
        DUCKDB_STATEMENT_TYPE_DROP, DUCKDB_STATEMENT_TYPE_COPY, DUCKDB_STATEMENT_TYPE_COPY_DATABASE,
        DUCKDB_STATEMENT_TYPE_EXPORT, DUCKDB_STATEMENT_TYPE_ANALYZE, DUCKDB_STATEMENT_TYPE_VACUUM,
        DUCKDB_STATEMENT_TYPE_MERGE_INTO,
    ].map(\.rawValue))

    private func run(_ statement: duckdb_prepared_statement, text: String?, connection: duckdb_connection, rowLimit: Int?) throws -> StatementResult {
        let statementType = duckdb_prepared_statement_type(statement)
        if refusesWrites, Self.writingStatements.contains(statementType.rawValue) {
            let target = source.path.map { ($0 as NSString).lastPathComponent } ?? "the in-memory database"
            throw DatabaseError.server(message: "Cannot run \(Self.commandWord(statementType)): \(target) is open read-only.", code: nil)
        }

        let isQuery = statementType == DUCKDB_STATEMENT_TYPE_SELECT
        var declared: [(name: String, type: DuckDBType)] = []
        var projection: duckdb_prepared_statement?
        defer { duckdb_destroy_prepare(&projection) }
        if isQuery, let text {
            declared = Self.columns(of: statement)
            if declared.contains(where: { !$0.type.isDecodedNatively }) {
                projection = Self.prepareProjection(text, columns: declared.map(\.type), connection: connection)
            }
        }

        var result = duckdb_result()
        defer { duckdb_destroy_result(&result) }
        let target = projection ?? statement
        // Streaming lets a row limit stop a large SELECT early; other statements must run to completion.
        let status = isQuery ? duckdb_execute_prepared_streaming(target, &result) : duckdb_execute_prepared(target, &result)
        guard status == DuckDBSuccess else { throw failure(&result) }

        switch duckdb_result_return_type(result) {
        case DUCKDB_RESULT_TYPE_CHANGED_ROWS:
            let changed = Int(duckdb_rows_changed(&result))
            return StatementResult(affectedRows: changed, message: "\(Self.commandTag(statementType, text: text)) \(changed)")
        case DUCKDB_RESULT_TYPE_NOTHING:
            return StatementResult(message: Self.commandTag(statementType, text: text))
        default:
            return try readRows(&result, declared: projection == nil ? nil : declared, rowLimit: rowLimit)
        }
    }

    /// Reads chunks until the row limit, keeping one past it to know whether the result was cut short.
    private func readRows(_ result: inout duckdb_result, declared: [(name: String, type: DuckDBType)]?, rowLimit: Int?) throws -> StatementResult {
        let columnCount = Int(duckdb_column_count(&result))
        var decodeTypes: [DuckDBType] = []
        var columns: [ResultColumn] = []
        for index in 0..<columnCount {
            guard let handle = duckdb_column_logical_type(&result, idx_t(index)) else {
                throw DatabaseError.protocolViolation("DuckDB returned no type for result column \(index + 1).")
            }
            let type = DuckDBType(taking: handle)
            decodeTypes.append(type)
            let name = duckdb_column_name(&result, idx_t(index)).map { String(cString: $0) } ?? "?"
            let shown = declared?[index] ?? (name: name, type: type)
            columns.append(ResultColumn(name: shown.name, typeName: shown.type.name(keywords: keywords), isNumeric: shown.type.isNumeric))
        }

        let limit = rowLimit ?? Int.max
        var rows: [[CellValue]] = []
        var truncated = false
        while true {
            var fetched: duckdb_data_chunk? = duckdb_fetch_chunk(result)
            defer { duckdb_destroy_data_chunk(&fetched) }
            guard let chunk = fetched else {
                if duckdb_result_error(&result) != nil { throw failure(&result) }
                break
            }
            let size = Int(duckdb_data_chunk_get_size(chunk))
            let room = limit - rows.count
            if size > room { truncated = true }
            let take = min(size, max(room, 0))
            if take > 0 {
                let views = try decodeTypes.enumerated().map { index, type -> DuckDBVectorView in
                    guard let vector = duckdb_data_chunk_get_vector(chunk, idx_t(index)) else {
                        throw DatabaseError.protocolViolation("DuckDB returned a chunk without column \(index + 1).")
                    }
                    return DuckDBVectorView(vector, type: type)
                }
                rows.reserveCapacity(rows.count + take)
                for row in 0..<take {
                    rows.append(views.map { DuckDBValueDecoder.cell($0, row: row) })
                }
            }
            if truncated { break }
        }
        return StatementResult(columns: columns, rows: rows, truncated: truncated)
    }

    private func failure(_ result: inout duckdb_result) -> DatabaseError {
        if duckdb_result_error_type(&result) == DUCKDB_ERROR_INTERRUPT || takeCancelRequest() {
            return .cancelled
        }
        let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "DuckDB reported an error."
        return .server(message: message, code: nil)
    }

    private static func columns(of statement: duckdb_prepared_statement) -> [(name: String, type: DuckDBType)] {
        (0..<duckdb_prepared_statement_column_count(statement)).compactMap { index in
            guard let type = duckdb_prepared_statement_column_logical_type(statement, index) else { return nil }
            let name = DuckDBType.takeString(UnsafeMutablePointer(mutating: duckdb_prepared_statement_column_name(statement, index))) ?? "?"
            return (name, DuckDBType(taking: type))
        }
    }

    /// Wraps a SELECT so DuckDB itself casts the columns Foxlume Query does not format natively, giving exactly
    /// the text of `CAST(x AS VARCHAR)` in the session's settings (time zone included). Nil when the wrapped
    /// query does not prepare or its columns do not line up, in which case the original statement runs.
    private static func prepareProjection(_ text: String, columns: [DuckDBType], connection: duckdb_connection) -> duckdb_prepared_statement? {
        let aliases = columns.indices.map { "c\($0 + 1)" }
        let list = zip(aliases, columns).map { alias, type in
            type.isDecodedNatively ? alias : "CAST(\(alias) AS VARCHAR)"
        }
        let sql = "SELECT \(list.joined(separator: ", ")) FROM (\(text)\n) AS fq_projection(\(aliases.joined(separator: ", ")))"
        var prepared: duckdb_prepared_statement?
        guard duckdb_prepare(connection, sql, &prepared) == DuckDBSuccess, let statement = prepared,
              Int(duckdb_prepared_statement_column_count(statement)) == columns.count,
              columns.indices.allSatisfy({ index in
                  let id = duckdb_prepared_statement_column_type(statement, idx_t(index))
                  return columns[index].isDecodedNatively ? id == columns[index].id : id == DUCKDB_TYPE_VARCHAR
              }) else {
            duckdb_destroy_prepare(&prepared)
            return nil
        }
        return statement
    }

    // MARK: - Command tags

    /// `INSERT 3`-style tags: DML takes the statement type, DDL names the object kind from the text.
    static func commandTag(_ type: duckdb_statement_type, text: String?) -> String {
        let word = commandWord(type)
        switch type {
        case DUCKDB_STATEMENT_TYPE_INSERT, DUCKDB_STATEMENT_TYPE_UPDATE, DUCKDB_STATEMENT_TYPE_DELETE, DUCKDB_STATEMENT_TYPE_MERGE_INTO:
            return word
        default:
            break
        }
        guard let text else { return word }
        let words = SQLStatementSplitter.strippingComments(text)
            .split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ";" })
            .prefix(8)
            .map { $0.uppercased() }
        guard let first = words.first, first.allSatisfy({ $0.isLetter }) else { return word }
        guard ["CREATE", "DROP", "ALTER"].contains(first) else { return first }
        let modifiers: Set<String> = ["OR", "REPLACE", "TEMP", "TEMPORARY", "UNIQUE", "PERSISTENT", "IF", "NOT", "EXISTS"]
        guard let object = words.dropFirst().first(where: { !modifiers.contains($0) }), object.allSatisfy({ $0.isLetter }) else { return first }
        return first + " " + object
    }

    static func commandWord(_ type: duckdb_statement_type) -> String {
        switch type {
        case DUCKDB_STATEMENT_TYPE_SELECT: return "SELECT"
        case DUCKDB_STATEMENT_TYPE_INSERT: return "INSERT"
        case DUCKDB_STATEMENT_TYPE_UPDATE: return "UPDATE"
        case DUCKDB_STATEMENT_TYPE_DELETE: return "DELETE"
        case DUCKDB_STATEMENT_TYPE_MERGE_INTO: return "MERGE"
        case DUCKDB_STATEMENT_TYPE_EXPLAIN: return "EXPLAIN"
        case DUCKDB_STATEMENT_TYPE_PREPARE: return "PREPARE"
        case DUCKDB_STATEMENT_TYPE_EXECUTE: return "EXECUTE"
        case DUCKDB_STATEMENT_TYPE_CREATE, DUCKDB_STATEMENT_TYPE_CREATE_FUNC: return "CREATE"
        case DUCKDB_STATEMENT_TYPE_ALTER: return "ALTER"
        case DUCKDB_STATEMENT_TYPE_DROP: return "DROP"
        case DUCKDB_STATEMENT_TYPE_TRANSACTION: return "TRANSACTION"
        case DUCKDB_STATEMENT_TYPE_COPY, DUCKDB_STATEMENT_TYPE_COPY_DATABASE: return "COPY"
        case DUCKDB_STATEMENT_TYPE_ANALYZE: return "ANALYZE"
        case DUCKDB_STATEMENT_TYPE_VARIABLE_SET, DUCKDB_STATEMENT_TYPE_SET: return "SET"
        case DUCKDB_STATEMENT_TYPE_EXPORT: return "EXPORT"
        case DUCKDB_STATEMENT_TYPE_PRAGMA: return "PRAGMA"
        case DUCKDB_STATEMENT_TYPE_VACUUM: return "VACUUM"
        case DUCKDB_STATEMENT_TYPE_CALL: return "CALL"
        case DUCKDB_STATEMENT_TYPE_LOAD: return "LOAD"
        case DUCKDB_STATEMENT_TYPE_ATTACH: return "ATTACH"
        case DUCKDB_STATEMENT_TYPE_DETACH: return "DETACH"
        default: return "OK"
        }
    }
}

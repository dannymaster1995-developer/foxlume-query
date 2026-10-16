import Foundation

public enum DatabaseError: Error, LocalizedError, Sendable {
    case connection(String)
    case authentication(String)
    /// An error reported by the server for a statement. `code` is the SQLSTATE or engine error number.
    case server(message: String, code: String?, detail: String? = nil)
    case protocolViolation(String)
    case cancelled
    /// The connection's query timeout stopped the statement (`ConnectionConfig.queryTimeout`).
    case queryTimeout(seconds: Int)
    case unsupported(String)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .connection(let message): return message
        case .authentication(let message): return message
        case let .server(message, code, detail):
            var text = message
            if let code, !code.isEmpty { text = "[\(code)] " + text }
            if let detail, !detail.isEmpty { text += "\n" + detail }
            return text
        case .protocolViolation(let message): return "Protocol error: \(message)"
        case .cancelled: return "The query was cancelled."
        case .queryTimeout(let seconds):
            return "The query was stopped after \(seconds) second\(seconds == 1 ? "" : "s") by the connection's query timeout."
        case .unsupported(let message): return message
        case .notConnected: return "Not connected."
        }
    }

    /// The link to the server is gone, as opposed to the server refusing a statement.
    public var isConnectionLoss: Bool {
        switch self {
        case .connection, .notConnected: return true
        case .authentication, .server, .protocolViolation, .cancelled, .queryTimeout, .unsupported: return false
        }
    }
}

/// Implemented by drivers that can run over TLS.
public protocol TLSReporting: AnyObject {
    /// The negotiated TLS version ("TLS 1.3") while the session is encrypted, nil otherwise.
    var tlsProtocolVersion: String? { get }
}

/// A single open database session.
///
/// Every method except `cancel()` is called on one serial queue owned by `DatabaseSession`,
/// so implementations may block and need no locking for their own state.
/// `cancel()` is called from another thread while a statement is running and must be thread-safe.
public protocol DatabaseConnection: AnyObject {
    var kind: DatabaseKind { get }
    var dialect: SQLDialect { get }

    func connect() throws
    func close()

    /// Server version string, for example `16.2` or `8.4.9-MariaDB`. Valid after `connect()`.
    var serverVersion: String { get }

    /// Run one or more statements separated by `;`. Returns one result per statement.
    /// Rows beyond `rowLimit` are read and discarded, and the result is marked `truncated`.
    func execute(_ sql: String, rowLimit: Int?) throws -> [StatementResult]

    /// Interrupt the statement currently running on this session.
    func cancel()

    /// A cheap round trip that proves the link still answers.
    func ping() throws
    /// Shuts the socket down from another thread so a read blocked on a dead link returns. The link is unusable afterwards.
    func abort()

    func databases() throws -> [String]
    var currentDatabase: String? { get }
    /// Switch database. PostgreSQL reconnects; MySQL issues `USE`.
    func useDatabase(_ name: String) throws

    /// Schemas of the current database. Empty for engines without schemas.
    func schemas() throws -> [String]
    /// Default schema for table listings, for example `public`.
    var defaultSchema: String? { get }

    func tables(schema: String?) throws -> [TableInfo]
    func structure(of table: TableRef) throws -> TableStructure
    func ddl(of table: TableRef) throws -> String

    /// What the UI may offer for this engine. SQL engines use the default.
    var capabilities: EngineCapabilities { get }

    /// One page of a table, collection or key list, with filters and sort applied.
    func fetchRows(_ query: TableQuery) throws -> StatementResult
    /// Total rows matching the query's filters, or nil when counting is too expensive or unsupported.
    func countRows(_ query: TableQuery) throws -> Int?
    /// Saves grid edits atomically when the engine allows it.
    func applyChanges(_ batch: ChangeBatch) throws

    /// Keys of the current database for a key/value sidebar tree. Nil for engines without keys.
    func browseKeys(pattern: String, limit: Int) throws -> KeyListing?

    /// Procedures, functions, triggers or types of a schema (MySQL: the current database), without system and
    /// extension-owned objects. Empty for kinds the engine does not list. See SchemaObjects.swift.
    func schemaObjects(_ kind: SchemaObjectKind, schema: String?) throws -> [SchemaObject]
    /// The CREATE statement of an object listed by `schemaObjects`.
    func definition(of object: SchemaObject) throws -> SchemaObjectDefinition
    /// Triggers of one table, for the Structure view.
    func triggers(of table: TableRef) throws -> [TriggerInfo]
    /// CHECK constraints of one table, for the Structure view. Empty where the server ignores CHECK.
    func checkConstraints(of table: TableRef) throws -> [CheckConstraintInfo]
    /// Columns, primary and unique keys and foreign keys of every table and view in a schema (MySQL: a database) in a
    /// few catalog queries, for the ER diagram. Columns carry name, type, nullability and primary key only. Nil when
    /// the engine has no bulk reader; the caller then reads `structure(of:)` table by table. See DiagramMetadata.swift.
    func diagramStructures(schema: String?) throws -> [TableStructure]?
    /// Rows of a referenced table for the foreign key value picker: key and label, searched on the server, at most
    /// `request.limit`. Empty for engines without foreign keys. See ReferenceCandidates.swift.
    func referenceCandidates(_ request: ReferenceCandidateRequest) throws -> [ReferenceCandidate]
}

/// Keys found by a scan, for the Redis key tree.
public struct KeyListing: Sendable {
    public struct Key: Sendable, Hashable {
        public var name: String
        /// Lowercase type name as the server reports it: `string`, `hash`, `list`, `set`, `zset`, `stream`.
        public var type: String

        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    public var keys: [Key]
    /// True when the scan stopped at the limit.
    public var truncated: Bool

    public init(keys: [Key], truncated: Bool) {
        self.keys = keys
        self.truncated = truncated
    }
}

/// How the browse view filters rows.
public enum BrowseFilterStyle: Sendable, Hashable {
    /// Column / operator / value rules plus a raw expression (SQL `WHERE`, MongoDB filter document).
    case columns
    /// A glob pattern on the key name plus a type picker (Redis). The pattern travels in `TableQuery.rawWhere`
    /// and the chosen type as a `FilterRule` on the `Type` column.
    case keyPattern(types: [String])
}

/// Differences between engines that the UI has to respect.
public struct EngineCapabilities: Sendable, Hashable {
    public var queryLanguage: QueryLanguage
    /// Word for one browsable object: "table", "collection", "key".
    public var objectNoun: String
    public var objectNounPlural: String
    /// Word for one record: "row", "document", "entry".
    public var rowNoun: String
    public var supportsDDL: Bool
    public var supportsForeignKeys: Bool
    public var supportsIndexes: Bool
    /// Whether grid edits are saved all-or-nothing.
    public var savesAtomically: Bool
    /// Label and placeholder of the free-form filter field (`WHERE` for SQL, a filter document for MongoDB).
    public var rawFilterLabel: String
    public var rawFilterPlaceholder: String
    public var browseFilterStyle: BrowseFilterStyle
    /// Whether clicking a column header re-sorts rows (Redis key lists are always sorted by key).
    public var supportsColumnSort: Bool
    /// Columns shown but never editable, such as MongoDB `_id` or the Redis `Length`.
    public var immutableColumns: Set<String>
    /// Whether the toolbar offers a database switcher. Redis lists its databases in the sidebar instead.
    public var supportsDatabaseSwitching: Bool
    /// Whether a cell can be set to "missing" (MongoDB field removal, saved as `$unset`).
    public var supportsFieldRemoval: Bool
    /// Rows per page when the engine needs a smaller page than the user setting.
    public var preferredPageSize: Int?

    public init(
        queryLanguage: QueryLanguage,
        objectNoun: String = "table",
        objectNounPlural: String = "tables",
        rowNoun: String = "row",
        supportsDDL: Bool = true,
        supportsForeignKeys: Bool = true,
        supportsIndexes: Bool = true,
        savesAtomically: Bool = true,
        rawFilterLabel: String = "WHERE",
        rawFilterPlaceholder: String = "Raw SQL condition, e.g. total > 100 AND status <> 'cancelled'",
        browseFilterStyle: BrowseFilterStyle = .columns,
        supportsColumnSort: Bool = true,
        immutableColumns: Set<String> = [],
        supportsDatabaseSwitching: Bool = true,
        supportsFieldRemoval: Bool = false,
        preferredPageSize: Int? = nil
    ) {
        self.queryLanguage = queryLanguage
        self.objectNoun = objectNoun
        self.objectNounPlural = objectNounPlural
        self.rowNoun = rowNoun
        self.supportsDDL = supportsDDL
        self.supportsForeignKeys = supportsForeignKeys
        self.supportsIndexes = supportsIndexes
        self.savesAtomically = savesAtomically
        self.rawFilterLabel = rawFilterLabel
        self.rawFilterPlaceholder = rawFilterPlaceholder
        self.browseFilterStyle = browseFilterStyle
        self.supportsColumnSort = supportsColumnSort
        self.immutableColumns = immutableColumns
        self.supportsDatabaseSwitching = supportsDatabaseSwitching
        self.supportsFieldRemoval = supportsFieldRemoval
        self.preferredPageSize = preferredPageSize
    }

    public static func relational(_ family: SQLDialect.Family) -> EngineCapabilities {
        EngineCapabilities(queryLanguage: .sql(family))
    }
}

/// Grid edits for one table, with everything a driver needs to turn them into writes.
public struct ChangeBatch: Sendable {
    public var table: TableRef
    public var columns: [ResultColumn]
    /// Columns that identify a row; empty when the table has no primary key.
    public var primaryKey: [String]
    public var originalRows: [[CellValue]]
    public var changes: PendingChanges

    public init(table: TableRef, columns: [ResultColumn], primaryKey: [String], originalRows: [[CellValue]], changes: PendingChanges) {
        self.table = table
        self.columns = columns
        self.primaryKey = primaryKey
        self.originalRows = originalRows
        self.changes = changes
    }
}

/// SQL behaviour shared by every relational driver.
public extension DatabaseConnection {
    var capabilities: EngineCapabilities { .relational(dialect.family) }

    func browseKeys(pattern: String, limit: Int) throws -> KeyListing? { nil }

    func schemaObjects(_ kind: SchemaObjectKind, schema: String?) throws -> [SchemaObject] { [] }

    func definition(of object: SchemaObject) throws -> SchemaObjectDefinition {
        throw DatabaseError.unsupported("\(kind.displayName) cannot show the definition of a \(object.kind.noun).")
    }

    func triggers(of table: TableRef) throws -> [TriggerInfo] { [] }

    func checkConstraints(of table: TableRef) throws -> [CheckConstraintInfo] { [] }

    func diagramStructures(schema: String?) throws -> [TableStructure]? { nil }

    func referenceCandidates(_ request: ReferenceCandidateRequest) throws -> [ReferenceCandidate] {
        guard case .sql = capabilities.queryLanguage else { return [] }
        let result = try execute(ReferenceCandidates.sql(request, dialect: dialect), rowLimit: request.limit).last { $0.hasResultSet }
        return result.map { ReferenceCandidates.candidates(from: $0, hasLabel: request.labelColumn != nil) } ?? []
    }

    func ping() throws {
        switch capabilities.queryLanguage {
        case .sql: _ = try execute("SELECT 1", rowLimit: 1)
        case .mongo: _ = try execute("db.runCommand({ ping: 1 })", rowLimit: 1)
        case .redis: _ = try execute("PING", rowLimit: 1)
        }
    }

    /// Local engines have no socket to shut down.
    func abort() {}

    func fetchRows(_ query: TableQuery) throws -> StatementResult {
        try execute(query.selectSQL(dialect: dialect), rowLimit: nil).last { $0.hasResultSet } ?? StatementResult()
    }

    func countRows(_ query: TableQuery) throws -> Int? {
        try execute(query.countSQL(dialect: dialect), rowLimit: 1).first?.rows.first?.first?.textValue.flatMap { Int($0) }
    }

    /// Runs the generated statements in one transaction and rolls back on the first failure.
    /// Every UPDATE and DELETE stands for one grid row, so one that touches several rows (identical rows in a table
    /// without a primary key) or none (the row changed elsewhere) rolls the whole save back.
    func applyChanges(_ batch: ChangeBatch) throws {
        let statements = try SQLStatementGenerator.statements(
            table: batch.table,
            columns: batch.columns.map(\.name),
            primaryKey: batch.primaryKey,
            originalRows: batch.originalRows,
            changes: batch.changes,
            dialect: dialect
        )
        guard !statements.isEmpty else { return }
        _ = try execute(dialect.beginStatement, rowLimit: nil)
        do {
            for statement in statements {
                let affected = try execute(statement, rowLimit: nil).last?.affectedRows
                try Self.checkSingleRow(statement: statement, affected: affected, family: dialect.family)
            }
            _ = try execute("COMMIT", rowLimit: nil)
        } catch {
            _ = try? execute("ROLLBACK", rowLimit: nil)
            throw error
        }
    }

    static func checkSingleRow(statement: String, affected: Int?, family: SQLDialect.Family) throws {
        let verb = statement.prefix(6).uppercased()
        guard verb == "UPDATE" || verb == "DELETE", let affected else { return }
        if affected > 1 {
            throw DatabaseError.unsupported("Nothing was saved: one change matched \(affected) identical rows. Add a primary key to the table, or change those rows with a query.")
        }
        // MySQL reports changed rows, so an UPDATE that writes the values a row already holds counts 0.
        if affected == 0, !(family == .mysql && verb == "UPDATE") {
            throw DatabaseError.unsupported("Nothing was saved: a row was changed or deleted by someone else since it was loaded. Refresh and try again.")
        }
    }
}

public enum ConnectionFactory {
    public static func make(_ parameters: ConnectionParameters) -> DatabaseConnection {
        switch parameters.config.kind {
        case .sqlite:
            return SQLiteConnection(parameters: parameters)
        case .postgresql:
            return PostgresConnection(parameters: parameters)
        case .mysql, .mariadb:
            return MySQLConnection(parameters: parameters)
        case .duckdb:
            return DuckDBConnection(parameters: parameters)
        case .mongodb:
            return MongoConnection(parameters: parameters)
        case .redis:
            return RedisConnection(parameters: parameters)
        }
    }
}

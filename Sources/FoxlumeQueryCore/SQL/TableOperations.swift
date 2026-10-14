import Foundation

public enum TableOperationKind: String, Sendable, Codable {
    case truncate
    case drop
}

/// The checkboxes of the Truncate and Drop prompts.
public struct TableOperationOptions: Hashable, Sendable, Codable {
    /// Turn foreign key checks off around the operation (MySQL, MariaDB, SQLite, PostgreSQL).
    public var ignoreForeignKeys: Bool
    /// Also empty or drop the objects that depend on this one (PostgreSQL, DuckDB drop).
    public var cascade: Bool

    public init(ignoreForeignKeys: Bool = false, cascade: Bool = false) {
        self.ignoreForeignKeys = ignoreForeignKeys
        self.cascade = cascade
    }
}

/// A Truncate or Drop chosen in the sidebar, waiting for Save.
public struct PendingTableOperation: Hashable, Sendable {
    public var table: TableRef
    public var objectKind: TableKind
    public var operation: TableOperationKind
    public var options: TableOperationOptions

    public init(table: TableRef, objectKind: TableKind, operation: TableOperationKind, options: TableOperationOptions = TableOperationOptions()) {
        self.table = table
        self.objectKind = objectKind
        self.operation = operation
        self.options = options
    }
}

/// Statements staged operations run as, in order. `restore` runs even when a statement fails,
/// so a session never keeps foreign key checks switched off.
public struct TableOperationPlan: Sendable, Equatable {
    public var setup: [String] = []
    public var statements: [String] = []
    public var restore: [String] = []

    public var all: [String] { setup + statements + restore }
    public var isEmpty: Bool { statements.isEmpty }
}

/// Truncate, Drop and Rename statements for one engine, written the way TablePro writes them.
public struct TableOperationSQL: Sendable {
    public let kind: DatabaseKind

    public init(kind: DatabaseKind) {
        self.kind = kind
    }

    private var dialect: SQLDialect {
        switch kind {
        case .postgresql: return .postgresql
        case .mysql, .mariadb: return .mysql
        case .duckdb: return .duckdb
        case .sqlite, .mongodb, .redis: return .sqlite
        }
    }

    // MARK: What the engine offers

    public func canTruncate(_ objectKind: TableKind) -> Bool {
        guard kind != .redis else { return false }
        return objectKind == .table
    }

    public func canDrop(_ objectKind: TableKind) -> Bool {
        switch objectKind {
        case .table, .view: return kind != .redis
        case .materializedView, .foreignTable: return kind == .postgresql
        case .systemTable, .keyspace: return false
        }
    }

    public func canRename(_ objectKind: TableKind) -> Bool {
        switch objectKind {
        case .table: return kind != .redis
        // SQLite has no ALTER VIEW and MongoDB cannot rename a view.
        case .view: return kind == .postgresql || kind == .mysql || kind == .mariadb || kind == .duckdb
        case .materializedView, .foreignTable: return kind == .postgresql
        case .systemTable, .keyspace: return false
        }
    }

    /// Whether "Ignore foreign key checks" can be ticked.
    public var supportsForeignKeyToggle: Bool {
        switch kind {
        case .mysql, .mariadb, .sqlite, .postgresql: return true
        case .duckdb, .mongodb, .redis: return false
        }
    }

    /// Whether "Cascade" can be ticked for this operation.
    public func supportsCascade(_ operation: TableOperationKind) -> Bool {
        switch kind {
        case .postgresql: return true
        case .duckdb: return operation == .drop
        case .mysql, .mariadb, .sqlite, .mongodb, .redis: return false
        }
    }

    // MARK: Statements

    public var foreignKeyDisableStatements: [String] {
        switch kind {
        case .mysql, .mariadb: return ["SET FOREIGN_KEY_CHECKS = 0"]
        case .sqlite: return ["PRAGMA foreign_keys = OFF"]
        case .postgresql: return ["SET session_replication_role = replica"]
        case .duckdb, .mongodb, .redis: return []
        }
    }

    public var foreignKeyEnableStatements: [String] {
        switch kind {
        case .mysql, .mariadb: return ["SET FOREIGN_KEY_CHECKS = 1"]
        case .sqlite: return ["PRAGMA foreign_keys = ON"]
        case .postgresql: return ["SET session_replication_role = DEFAULT"]
        case .duckdb, .mongodb, .redis: return []
        }
    }

    public func truncateStatements(_ table: TableRef, options: TableOperationOptions = TableOperationOptions()) -> [String] {
        let name = dialect.qualifiedName(table)
        let cascade = options.cascade && supportsCascade(.truncate) ? " CASCADE" : ""
        switch kind {
        case .postgresql: return ["TRUNCATE TABLE \(name)\(cascade)"]
        case .mysql, .mariadb: return ["TRUNCATE TABLE \(name)"]
        case .duckdb: return ["TRUNCATE \(name)"]
        // SQLite has no TRUNCATE; an unqualified DELETE uses its truncate optimisation.
        case .sqlite: return ["DELETE FROM \(name)"]
        // Empties the collection and keeps its indexes and options, unlike drop().
        case .mongodb: return ["\(Self.mongoCollection(table.name)).deleteMany({})"]
        case .redis: return []
        }
    }

    public func dropStatement(_ table: TableRef, objectKind: TableKind, options: TableOperationOptions = TableOperationOptions()) -> String? {
        guard canDrop(objectKind) else { return nil }
        if kind == .mongodb {
            return "\(Self.mongoCollection(table.name)).drop()"
        }
        let cascade = options.cascade && supportsCascade(.drop) ? " CASCADE" : ""
        return "DROP \(Self.keyword(for: objectKind)) \(dialect.qualifiedName(table))\(cascade)"
    }

    public func renameStatement(_ table: TableRef, objectKind: TableKind, to newName: String) -> String? {
        guard canRename(objectKind), !newName.isEmpty else { return nil }
        let target = dialect.quoteIdentifier(newName)
        switch kind {
        case .mysql, .mariadb:
            return "RENAME TABLE \(dialect.qualifiedName(table)) TO \(target)"
        case .postgresql, .duckdb, .sqlite:
            return "ALTER \(Self.keyword(for: objectKind)) \(dialect.qualifiedName(table)) RENAME TO \(target)"
        case .mongodb:
            return "\(Self.mongoCollection(table.name)).renameCollection(\(Self.jsString(newName)))"
        case .redis:
            return nil
        }
    }

    /// Truncates first, then drops, each group in name order. Foreign key checks are switched off
    /// around them when any operation asks for it and the engine allows it.
    public func plan(_ operations: [PendingTableOperation]) -> TableOperationPlan {
        var plan = TableOperationPlan()
        let order: (PendingTableOperation, PendingTableOperation) -> Bool = {
            ($0.table.schema ?? "", $0.table.name) < ($1.table.schema ?? "", $1.table.name)
        }
        for operation in operations.filter({ $0.operation == .truncate }).sorted(by: order) {
            plan.statements += truncateStatements(operation.table, options: operation.options)
        }
        for operation in operations.filter({ $0.operation == .drop }).sorted(by: order) {
            if let statement = dropStatement(operation.table, objectKind: operation.objectKind, options: operation.options) {
                plan.statements.append(statement)
            }
        }
        if supportsForeignKeyToggle, operations.contains(where: \.options.ignoreForeignKeys) {
            plan.setup = foreignKeyDisableStatements
            plan.restore = foreignKeyEnableStatements
        }
        return plan
    }

    /// What the prompts call the object: "table", "view", "collection"…
    public func noun(for objectKind: TableKind) -> String {
        if kind == .mongodb, objectKind == .table { return "collection" }
        return Self.keyword(for: objectKind).lowercased()
    }

    public static func keyword(for objectKind: TableKind) -> String {
        switch objectKind {
        case .view: return "VIEW"
        case .materializedView: return "MATERIALIZED VIEW"
        case .foreignTable: return "FOREIGN TABLE"
        case .table, .systemTable, .keyspace: return "TABLE"
        }
    }

    static func mongoCollection(_ name: String) -> String {
        "db.getCollection(\(jsString(name)))"
    }

    /// A JavaScript string literal; JSON escaping covers quotes, backslashes and line breaks.
    static func jsString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed]),
              let array = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}

extension DatabaseSession {
    /// Runs a plan as one session job, so nothing else interleaves while foreign key checks are off.
    /// Stops at the first failing statement; `restore` still runs.
    public func run(_ plan: TableOperationPlan) async throws {
        try await run { connection in
            defer {
                for statement in plan.restore { _ = try? connection.execute(statement, rowLimit: nil) }
            }
            for statement in plan.setup + plan.statements {
                _ = try connection.execute(statement, rowLimit: nil)
            }
        }
    }
}

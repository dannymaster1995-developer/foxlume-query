import Foundation

public enum DatabaseKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case postgresql
    case mysql
    case mariadb
    case sqlite
    case duckdb
    case mongodb
    case redis

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .postgresql: return "PostgreSQL"
        case .mysql: return "MySQL"
        case .mariadb: return "MariaDB"
        case .sqlite: return "SQLite"
        case .duckdb: return "DuckDB"
        case .mongodb: return "MongoDB"
        case .redis: return "Redis"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .postgresql: return 5432
        case .mysql, .mariadb: return 3306
        case .sqlite, .duckdb: return 0
        case .mongodb: return 27017
        case .redis: return 6379
        }
    }

    public var defaultUser: String {
        switch self {
        case .postgresql: return "postgres"
        case .mysql, .mariadb: return "root"
        case .sqlite, .duckdb, .mongodb, .redis: return ""
        }
    }

    /// Engines opened from a local file instead of a server.
    public var isFileBased: Bool { self == .sqlite || self == .duckdb }

    /// MySQL and MariaDB speak the same wire protocol and SQL dialect for everything Foxlume Query does.
    public var usesMySQLProtocol: Bool { self == .mysql || self == .mariadb }

    public var supportsSchemas: Bool { self == .postgresql || self == .duckdb }

    public var supportsMultipleDatabases: Bool {
        switch self {
        case .postgresql, .mysql, .mariadb, .mongodb, .redis: return true
        case .sqlite, .duckdb: return false
        }
    }

    /// Databases the engine keeps for itself, hidden from the switcher unless the user asks for them.
    public var systemDatabases: Set<String> {
        switch self {
        case .mysql, .mariadb: return ["information_schema", "mysql", "performance_schema", "sys"]
        case .mongodb: return ["admin", "local", "config"]
        case .duckdb: return ["system", "temp"]
        case .postgresql, .sqlite, .redis: return []
        }
    }

    /// PostgreSQL and MySQL are the supported core; every other engine works but is labelled Beta in the app.
    public var isBeta: Bool { self != .postgresql && self != .mysql }

    /// Whether the engine is queried with SQL. MongoDB and Redis use their own command languages.
    public var isSQL: Bool { self != .mongodb && self != .redis }
}

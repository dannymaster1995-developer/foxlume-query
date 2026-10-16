import Foundation

/// CREATE / DROP / RENAME for databases and schemas, written per engine; Copy Database (PostgreSQL) as well.
public struct DatabaseObjectSQL: Sendable {
    public let kind: DatabaseKind

    public init(kind: DatabaseKind) {
        self.kind = kind
    }

    private var dialect: SQLDialect {
        kind.usesMySQLProtocol ? .mysql : .postgresql
    }

    public var canManageDatabases: Bool {
        kind == .postgresql || kind.usesMySQLProtocol
    }

    public var canManageSchemas: Bool { kind == .postgresql }

    /// PostgreSQL only. DuckDB (1.5.6) answers "Altering schemas is not yet supported"; MySQL schemas are databases.
    public var canRenameSchemas: Bool { kind == .postgresql }

    /// ALTER DATABASE … RENAME TO and CREATE DATABASE … TEMPLATE: PostgreSQL only.
    public var canRenameDatabases: Bool { kind == .postgresql }

    public var canCopyDatabases: Bool { kind == .postgresql }

    /// Why Rename Database… is unavailable, for the menu item's tooltip; nil where it works.
    public var databaseRenameUnavailableReason: String? {
        switch kind {
        case .postgresql: return nil
        case .mysql: return "MySQL has no RENAME DATABASE"
        case .mariadb: return "MariaDB has no RENAME DATABASE"
        case .sqlite, .duckdb, .mongodb, .redis: return "\(kind.displayName) cannot rename or copy databases"
        }
    }

    /// Why Copy Database… is unavailable; nil where it works.
    public var databaseCopyUnavailableReason: String? {
        switch kind {
        case .postgresql: return nil
        case .mysql, .mariadb: return "\(kind.displayName) has no statement that copies a database"
        case .sqlite, .duckdb, .mongodb, .redis: return "\(kind.displayName) cannot rename or copy databases"
        }
    }

    /// The catalog schemas a rename refuses: `pg_*` (pg_catalog, pg_toast, temporary schemas) and information_schema.
    public static func isSystemSchema(_ name: String) -> Bool {
        name.lowercased().hasPrefix("pg_") || name.lowercased() == "information_schema"
    }

    /// MySQL databases default to utf8mb4 so a new database holds any text.
    public func createDatabase(_ name: String) -> String? {
        guard canManageDatabases, !name.isEmpty else { return nil }
        if kind.usesMySQLProtocol {
            return "CREATE DATABASE \(dialect.quoteIdentifier(name)) CHARACTER SET utf8mb4"
        }
        return "CREATE DATABASE \(dialect.quoteIdentifier(name))"
    }

    public func dropDatabase(_ name: String) -> String? {
        guard canManageDatabases, !name.isEmpty else { return nil }
        return "DROP DATABASE \(dialect.quoteIdentifier(name))"
    }

    public func createSchema(_ name: String) -> String? {
        guard canManageSchemas, !name.isEmpty else { return nil }
        return "CREATE SCHEMA \(dialect.quoteIdentifier(name))"
    }

    public func dropSchema(_ name: String, cascade: Bool) -> String? {
        guard canManageSchemas, !name.isEmpty else { return nil }
        return "DROP SCHEMA \(dialect.quoteIdentifier(name))\(cascade ? " CASCADE" : "")"
    }

    /// Nil for system schemas: a superuser may rename even pg_catalog, after which the database no longer works.
    public func renameSchema(_ name: String, to newName: String) -> String? {
        guard canRenameSchemas, !name.isEmpty, !newName.isEmpty, name != newName, !Self.isSystemSchema(name) else { return nil }
        return "ALTER SCHEMA \(dialect.quoteIdentifier(name)) RENAME TO \(dialect.quoteIdentifier(newName))"
    }

    public func renameDatabase(_ name: String, to newName: String) -> String? {
        guard canRenameDatabases, !name.isEmpty, !newName.isEmpty, name != newName else { return nil }
        return "ALTER DATABASE \(dialect.quoteIdentifier(name)) RENAME TO \(dialect.quoteIdentifier(newName))"
    }

    /// A copy made from `name` as its template; `owner` keeps the source's owner instead of the user running it.
    public func copyDatabase(_ name: String, to newName: String, owner: String? = nil) -> String? {
        guard canCopyDatabases, !name.isEmpty, !newName.isEmpty, name != newName else { return nil }
        let ownerClause = owner.flatMap { $0.isEmpty ? nil : " OWNER \(dialect.quoteIdentifier($0))" } ?? ""
        return "CREATE DATABASE \(dialect.quoteIdentifier(newName)) TEMPLATE \(dialect.quoteIdentifier(name))\(ownerClause)"
    }

    /// The owner of a database, as one row with one column.
    public func ownerQuery(of database: String) -> String? {
        guard kind == .postgresql else { return nil }
        return "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = \(dialect.quoteString(database))"
    }
}

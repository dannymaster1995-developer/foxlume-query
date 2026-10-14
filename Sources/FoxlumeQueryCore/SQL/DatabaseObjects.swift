import Foundation

/// CREATE / DROP for databases and schemas, written per engine.
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
}

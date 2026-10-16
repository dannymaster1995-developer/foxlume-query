import Foundation

/// A schema or database renamed on the server, applied to what the app remembers under its name: grid column
/// layouts, ER diagram layouts, filter presets, Open Quickly recents and the tables open in tabs.
public enum StoredStateRename: Hashable, Sendable {
    /// Schema `from` of `database` (nil when the scopes carry none) became `to`.
    case schema(connectionID: UUID, database: String?, from: String, to: String)
    case database(connectionID: UUID, from: String, to: String)

    public var connectionID: UUID {
        switch self {
        case .schema(let id, _, _, _), .database(let id, _, _): return id
        }
    }

    /// The (database, schema) a scope moves to, or nil when the rename does not touch it.
    public func renamed(connectionID: UUID, database: String?, schema: String?) -> (database: String?, schema: String?)? {
        guard connectionID == self.connectionID else { return nil }
        switch self {
        case .schema(_, let renamedDatabase, let from, let to):
            guard schema == from, database == renamedDatabase else { return nil }
            return (database, to)
        case .database(_, let from, let to):
            guard database == from else { return nil }
            return (to, schema)
        }
    }

    public func renamed(_ scope: GridColumnLayoutScope) -> GridColumnLayoutScope? {
        renamed(connectionID: scope.connectionID, database: scope.database, schema: scope.schema).map {
            GridColumnLayoutScope(connectionID: scope.connectionID, database: $0.database, schema: $0.schema, table: scope.table)
        }
    }

    public func renamed(_ scope: ERDiagramScope) -> ERDiagramScope? {
        renamed(connectionID: scope.connectionID, database: scope.database, schema: scope.schema).map {
            ERDiagramScope(connectionID: scope.connectionID, database: $0.database, schema: $0.schema)
        }
    }

    public func renamed(_ scope: FilterPresetScope) -> FilterPresetScope? {
        renamed(connectionID: scope.connectionID, database: scope.database, schema: scope.schema).map {
            FilterPresetScope(connectionID: scope.connectionID, database: $0.database, schema: $0.schema, table: scope.table)
        }
    }

    /// A table open in a tab of the renamed schema, under the new name. Table refs carry no database, so a database
    /// rename leaves them as they are.
    public func renamed(_ table: TableRef) -> TableRef? {
        guard case .schema(_, _, let from, let to) = self, table.schema == from else { return nil }
        return TableRef(schema: to, name: table.name)
    }

    /// An Open Quickly recency key (`QuickOpenItem.key`) under the new name, or nil when it does not change.
    /// Table and object keys name their schema, schema and database keys their own name.
    public func renamedQuickOpenKey(_ key: String) -> String? {
        switch self {
        case .schema(_, _, let from, let to):
            if key == "schema:" + from { return "schema:" + to }
            let tablePrefix = "table:" + from + "."
            if key.hasPrefix(tablePrefix) { return "table:" + to + "." + key.dropFirst(tablePrefix.count) }
            if key.hasPrefix("object:") {
                var parts = key.dropFirst("object:".count).components(separatedBy: "\u{1F}")
                guard parts.count > 1, parts[1] == from else { return nil }
                parts[1] = to
                return "object:" + parts.joined(separator: "\u{1F}")
            }
            return nil
        case .database(_, let from, let to):
            return key == "database:" + from ? "database:" + to : nil
        }
    }
}

extension GridColumnLayoutStore {
    /// Moves the layouts of a renamed schema or database to the new name, replacing any left there before.
    public func apply(_ rename: StoredStateRename) throws {
        try moveEntries { rename.renamed($0) }
    }
}

extension ERDiagramLayoutStore {
    /// Moves the diagrams of a renamed schema or database to the new name, replacing any left there before.
    public func apply(_ rename: StoredStateRename) throws {
        try moveEntries { rename.renamed($0) }
    }
}

extension FilterPresetStore {
    /// Moves the presets of a renamed schema or database to the new name, replacing any left there before.
    public func apply(_ rename: StoredStateRename) throws {
        try moveEntries { rename.renamed($0) }
    }
}

extension QuickOpenFrecencyStore {
    /// Moves the visits of renamed items to their new keys.
    public func apply(_ rename: StoredStateRename) {
        renameKeys(connection: rename.connectionID) { rename.renamedQuickOpenKey($0) }
    }
}

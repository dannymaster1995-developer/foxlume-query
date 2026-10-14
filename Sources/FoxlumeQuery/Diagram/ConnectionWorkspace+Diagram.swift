import AppKit
import FoxlumeQueryCore

/// What an ER diagram reads: the tables of one schema, then their columns, keys and foreign keys.
extension ConnectionWorkspace {
    /// SQL engines with foreign keys; MongoDB and Redis have no diagram.
    var supportsERDiagram: Bool { kind.isSQL }

    /// The schema a diagram opened now would show: PostgreSQL and DuckDB schemas, nil for MySQL (the current
    /// database) and SQLite.
    var diagramSchema: String? { kind.supportsSchemas ? currentSchema : nil }

    /// The tables a diagram of `schema` shows: the sidebar's cached list when it is that schema, otherwise a fresh
    /// read. Views are kept (they have columns), system tables are not.
    func diagramTables(schema: String?) async throws -> [TableInfo] {
        let list: [TableInfo]
        if schema == diagramSchema, !tables.isEmpty {
            list = tables
        } else {
            list = try await tracked { try await session.run { try $0.tables(schema: schema) } }
        }
        return list.filter { $0.kind != .systemTable && $0.kind != .keyspace }
    }

    /// Columns, keys and foreign keys of `tables`: PostgreSQL and MySQL read the whole schema in three catalog
    /// queries; other engines read table by table, reusing structures already cached, each table its own session job
    /// so queries the user runs meanwhile are not held up. `progress` gets (done, total) on the main actor.
    func diagramStructures(schema: String?, tables: [TableInfo], progress: @escaping (Int, Int) -> Void) async throws -> [TableStructure] {
        progress(0, tables.count)
        let bulk = try await tracked { try await session.run { try $0.diagramStructures(schema: schema) } }
        if let bulk {
            progress(tables.count, tables.count)
            return bulk
        }
        var structures: [TableStructure] = []
        for (index, table) in tables.enumerated() {
            try Task.checkCancellation()
            if let cached = cachedStructure(of: table.ref) {
                structures.append(cached)
            } else {
                do {
                    structures.append(try await structure(of: table.ref))
                } catch let error as DatabaseError where !error.isConnectionLoss {
                    // A table that cannot be read (dropped meanwhile, no privilege) shows with no columns.
                }
            }
            progress(index + 1, tables.count)
        }
        return structures
    }
}

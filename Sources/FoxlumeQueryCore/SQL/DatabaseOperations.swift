import Foundation

/// Rename Database… or Copy Database… (PostgreSQL). Both need the source database to themselves: the server refuses
/// while any other session is connected to it, the app's own included.
public enum DatabaseChange: Hashable, Sendable {
    case rename(from: String, to: String)
    /// CREATE DATABASE `to` TEMPLATE `from`; `owner` is the source's owner when the copy keeps it.
    case copy(from: String, to: String, owner: String?)

    public var source: String {
        switch self {
        case .rename(let from, _), .copy(let from, _, _): return from
        }
    }

    public var target: String {
        switch self {
        case .rename(_, let to), .copy(_, let to, _): return to
        }
    }

    public func statement(_ sql: DatabaseObjectSQL) -> String? {
        switch self {
        case .rename(let from, let to): return sql.renameDatabase(from, to: to)
        case .copy(let from, let to, let owner): return sql.copyDatabase(from, to: to, owner: owner)
        }
    }

    /// Where a session that was moved off the source goes back to: the new name after a rename, the source after a copy.
    public var returnDatabase: String {
        switch self {
        case .rename(_, let to): return to
        case .copy(let from, _, _): return from
        }
    }

    /// "Rename" or "Copy", for titles and errors.
    public var verb: String {
        switch self {
        case .rename: return "Rename"
        case .copy: return "Copy"
        }
    }
}

/// Sessions connected to a database, grouped by application and user, as pg_stat_activity reports them.
public struct DatabaseSessionGroup: Hashable, Sendable {
    public var application: String
    public var user: String
    public var count: Int

    public init(application: String, user: String, count: Int) {
        self.application = application
        self.user = user
        self.count = count
    }

    /// `psql (alice) × 2`.
    public var summary: String {
        "\(application) (\(user.isEmpty ? "unknown user" : user))" + (count > 1 ? " × \(count)" : "")
    }
}

public enum DatabaseChangeError: LocalizedError, Equatable {
    /// Other sessions use the source; they are listed so the user can close them. Nothing was changed.
    case otherSessions(database: String, groups: [DatabaseSessionGroup])

    public var total: Int {
        switch self {
        case .otherSessions(_, let groups): return groups.reduce(0) { $0 + $1.count }
        }
    }

    public var errorDescription: String? {
        switch self {
        case .otherSessions(let database, let groups):
            let count = total
            return "“\(database)” has \(count) other session\(count == 1 ? "" : "s"): "
                + groups.map(\.summary).joined(separator: ", ")
                + ". PostgreSQL renames or copies a database only when nobody else is connected to it; close those sessions and try again."
        }
    }
}

extension DatabaseObjectSQL {
    /// Sessions on `database` other than the asking session and the processes in `excluding`, grouped by application
    /// and user, largest group first.
    public func otherSessionsQuery(on database: String, excluding pids: [Int] = []) -> String? {
        guard kind == .postgresql else { return nil }
        let excluded = pids.isEmpty ? "" : " AND pid NOT IN (\(pids.map(String.init).joined(separator: ", ")))"
        return """
            SELECT coalesce(nullif(application_name, ''), backend_type, 'unknown') AS application, coalesce(usename, '') AS username, count(*) AS sessions \
            FROM pg_stat_activity WHERE datname = \(SQLDialect.postgresql.quoteString(database)) AND pid <> pg_backend_pid()\(excluded) \
            GROUP BY 1, 2 ORDER BY 3 DESC, 1, 2
            """
    }

    /// Rows of `otherSessionsQuery` as groups.
    public static func sessionGroups(_ rows: [[CellValue]]) -> [DatabaseSessionGroup] {
        rows.compactMap { row in
            guard row.count >= 3, let count = Int(row[2].displayString), count > 0 else { return nil }
            return DatabaseSessionGroup(application: row[0].displayString, user: row[1].isNull ? "" : row[1].displayString, count: count)
        }
    }

    /// The database a session waits in while `source` is renamed or copied: `postgres`, else another database that is
    /// not a template, else `template1`. Nil when the server lists nothing else.
    public static func maintenanceDatabase(for source: String, target: String? = nil, among databases: [String]) -> String? {
        let others = databases.filter { $0 != source && $0 != target }
        if others.contains("postgres") { return "postgres" }
        if let user = others.first(where: { $0 != "template0" && $0 != "template1" }) { return user }
        return others.contains("template1") ? "template1" : nil
    }
}

/// Runs a rename or copy. The statement runs on `maintenance`, a session of its own already connected to another
/// database (no query timeout: a copy of a large database takes long). `own` is the workspace's session: when it is
/// connected to the source it moves to `maintenance`'s database for the statement and comes back afterwards, to the
/// new name after a rename. Other sessions on the source make it stop before anything changes; they are never ended.
public struct DatabaseChangeRunner: Sendable {
    public let change: DatabaseChange
    private let sql = DatabaseObjectSQL(kind: .postgresql)

    public init(change: DatabaseChange) {
        self.change = change
    }

    public struct Outcome: Equatable, Sendable {
        /// The statement that ran.
        public var statement: String
        /// The database `own` is connected to afterwards when it had to move; nil when it stayed where it was.
        public var ownDatabase: String?
    }

    /// - Parameter waitDatabase: the database `maintenance` is connected to, where `own` waits.
    public func run(own: DatabaseSession, maintenance: DatabaseSession, waitDatabase: String) async throws -> Outcome {
        guard let statement = change.statement(sql) else {
            throw DatabaseError.unsupported("Give the database a new name that differs from “\(change.source)”.")
        }
        let source = change.source
        let ownIsOnSource = await own.currentDatabase() == source
        var excluded: [Int] = []
        if ownIsOnSource, let pid = try await Self.backendPID(own) { excluded.append(pid) }
        try await checkOtherSessions(on: maintenance, excluding: excluded)

        if ownIsOnSource {
            try await own.run { try $0.useDatabase(waitDatabase) }
        }
        do {
            _ = try await maintenance.run { try $0.execute(statement, rowLimit: nil) }
        } catch {
            if ownIsOnSource { _ = try? await own.run { try $0.useDatabase(source) } }
            throw error
        }
        guard ownIsOnSource else { return Outcome(statement: statement, ownDatabase: nil) }
        let back = change.returnDatabase
        try await own.run { try $0.useDatabase(back) }
        return Outcome(statement: statement, ownDatabase: back)
    }

    /// Throws `DatabaseChangeError.otherSessions` when anyone but `maintenance` and the `excluding` processes uses the source.
    public func checkOtherSessions(on maintenance: DatabaseSession, excluding pids: [Int]) async throws {
        guard let query = sql.otherSessionsQuery(on: change.source, excluding: pids) else { return }
        let rows = try await maintenance.run { try $0.execute(query, rowLimit: nil) }.first?.rows ?? []
        let groups = DatabaseObjectSQL.sessionGroups(rows)
        if !groups.isEmpty {
            throw DatabaseChangeError.otherSessions(database: change.source, groups: groups)
        }
    }

    static func backendPID(_ session: DatabaseSession) async throws -> Int? {
        let rows = try await session.run { try $0.execute("SELECT pg_backend_pid()", rowLimit: nil) }.first?.rows ?? []
        return rows.first.flatMap { $0.first.flatMap { Int($0.displayString) } }
    }
}

import Foundation

/// One session in the server's session list (PostgreSQL pg_stat_activity, MySQL and MariaDB PROCESSLIST).
public struct ServerActivitySession: Hashable, Sendable, Identifiable {
    /// PostgreSQL backend pid, MySQL connection id.
    public var id: Int
    public var user: String
    public var database: String
    /// PostgreSQL application_name; empty on MySQL.
    public var application: String
    /// Client address and port (PostgreSQL), host (MySQL).
    public var client: String
    /// PostgreSQL state (active, idle, idle in transaction…); MySQL thread state (executing, Sending data…).
    public var state: String
    /// MySQL command (Query, Sleep, Daemon…); empty on PostgreSQL.
    public var command: String
    /// PostgreSQL wait event as "type: event"; empty on MySQL.
    public var waitEvent: String
    /// PostgreSQL backend start and query start, `YYYY-MM-DD HH:MM:SS` in the server's time zone; empty on MySQL.
    public var backendStart: String
    public var queryStart: String
    /// Seconds the current statement (or, idle in a transaction, the transaction) has been running. Nil when idle.
    public var runningSeconds: Double?
    /// The statement running, or for PostgreSQL the last one when idle.
    public var query: String
    /// Idle: PostgreSQL state `idle`, MySQL command `Sleep` or `Daemon`.
    public var isIdle: Bool
    /// Set by the app for its own sessions: "This window", "Server Activity", "Foxlume Query".
    public var owner: String?

    public init(
        id: Int, user: String = "", database: String = "", application: String = "", client: String = "", state: String = "",
        command: String = "", waitEvent: String = "", backendStart: String = "", queryStart: String = "",
        runningSeconds: Double? = nil, query: String = "", isIdle: Bool = false, owner: String? = nil
    ) {
        self.id = id
        self.user = user
        self.database = database
        self.application = application
        self.client = client
        self.state = state
        self.command = command
        self.waitEvent = waitEvent
        self.backendStart = backendStart
        self.queryStart = queryStart
        self.runningSeconds = runningSeconds
        self.query = query
        self.isIdle = isIdle
        self.owner = owner
    }

    /// The running time as a sort key: idle sessions (no running time) sort below every running one.
    public var runningSortKey: Double { runningSeconds ?? -1 }

    /// Whether the session matches the filter text: id, user, database, application, client, state or query.
    public func matches(_ text: String) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return [String(id), user, database, application, client, state, command, query, owner ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

/// What can be done to another session: stop its statement, or end the session.
public enum ServerSessionAction: String, CaseIterable, Sendable {
    /// PostgreSQL `pg_cancel_backend`, MySQL `KILL QUERY`.
    case cancelQuery
    /// PostgreSQL `pg_terminate_backend`, MySQL `KILL CONNECTION`.
    case terminate

    /// Ending a session rolls back its open transaction and closes its connection.
    public var isDestructive: Bool { self == .terminate }
}

/// The result of an action on one session.
public enum ServerSessionActionOutcome: Equatable, Sendable {
    case done
    /// The session ended before the action reached it (PostgreSQL answers false, MySQL 1094 Unknown thread id).
    case notFound
    case failed(String)
}

/// One row of the slow query list: a normalized statement and its totals since the statistics were last reset.
public struct SlowQueryStat: Hashable, Sendable, Identifiable {
    public var id: Int
    /// PostgreSQL normalized query, MySQL digest text.
    public var query: String
    /// A real statement of this digest (MySQL 8 QUERY_SAMPLE_TEXT), else nil.
    public var sample: String?
    public var database: String
    /// PostgreSQL role; empty on MySQL.
    public var user: String
    public var calls: Int
    public var totalSeconds: Double
    public var meanSeconds: Double
    /// Rows returned (PostgreSQL rows, MySQL rows sent).
    public var rows: Int?
    /// MySQL rows examined; nil on PostgreSQL.
    public var rowsExamined: Int?

    public init(id: Int, query: String, sample: String? = nil, database: String = "", user: String = "", calls: Int = 0,
                totalSeconds: Double = 0, meanSeconds: Double = 0, rows: Int? = nil, rowsExamined: Int? = nil) {
        self.id = id
        self.query = query
        self.sample = sample
        self.database = database
        self.user = user
        self.calls = calls
        self.totalSeconds = totalSeconds
        self.meanSeconds = meanSeconds
        self.rows = rows
        self.rowsExamined = rowsExamined
    }

    /// What Open in Query Tab and Copy Query use: the sample statement when there is one, else the normalized text.
    public var runnableText: String { sample.flatMap { $0.isEmpty ? nil : $0 } ?? query }
}

public enum SlowQueryOrder: String, CaseIterable, Sendable {
    case totalTime
    case meanTime

    public var title: String {
        switch self {
        case .totalTime: return "Total Time"
        case .meanTime: return "Mean Time"
        }
    }
}

/// Whether the server collects statement statistics, and from where. The app never installs or enables anything.
public enum SlowQuerySource: Equatable, Sendable {
    /// PostgreSQL: the schema pg_stat_statements is installed in. MySQL: performance_schema.
    case available(schema: String)
    case unavailable(reason: String, hint: String)
}

/// Server Activity for PostgreSQL, MySQL and MariaDB: the statements that list sessions, act on them and read the
/// statement statistics, and the parsing of their rows. Other engines have none (`isSupported` is false).
public struct ServerActivitySQL: Sendable {
    public let kind: DatabaseKind
    /// `session.serverVersion`, such as `16.2`, `8.4.9` or `11.4.2-MariaDB`.
    public let serverVersion: String

    public init(kind: DatabaseKind, serverVersion: String = "") {
        self.kind = kind
        self.serverVersion = serverVersion
    }

    public static func isSupported(_ kind: DatabaseKind) -> Bool { kind == .postgresql || kind.usesMySQLProtocol }

    public var isSupported: Bool { Self.isSupported(kind) }

    var isMariaDB: Bool { kind == .mariadb || serverVersion.range(of: "MariaDB", options: .caseInsensitive) != nil }

    /// Major, minor and patch numbers of the server version; missing parts are 0.
    var versionParts: [Int] {
        let numbers = serverVersion.prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap { Int($0) }
        return (numbers + [0, 0, 0]).prefix(3).map { $0 }
    }

    func versionAtLeast(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> Bool {
        let parts = versionParts
        // An unknown version is taken as a current server.
        guard parts[0] > 0 else { return true }
        return (parts[0], parts[1], parts[2]) >= (major, minor, patch)
    }

    // MARK: Titles

    public func title(_ action: ServerSessionAction) -> String {
        switch (action, kind == .postgresql) {
        case (.cancelQuery, true): return "Cancel Query"
        case (.terminate, true): return "Terminate Session"
        case (.cancelQuery, false): return "Kill Query"
        case (.terminate, false): return "Kill Connection"
        }
    }

    /// The confirmation's explanation of what the action does.
    public func explanation(_ action: ServerSessionAction) -> String {
        switch action {
        case .cancelQuery:
            return "The running statement is stopped and returns an error to its client; the session stays connected."
        case .terminate:
            return "The session is closed: its running statement stops, its open transaction is rolled back and its client loses the connection."
        }
    }

    // MARK: Sessions

    /// Every client session except the one asking, with what it runs and for how long.
    public var sessionsQuery: String? {
        switch kind {
        case .postgresql:
            // backend_type exists since PostgreSQL 10; it keeps autovacuum, WAL and other server processes out.
            let clientsOnly = versionAtLeast(10) ? " AND backend_type = 'client backend'" : ""
            return """
                SELECT pid, coalesce(usename, '') AS username, coalesce(datname, '') AS database, \
                coalesce(application_name, '') AS application, \
                CASE WHEN client_addr IS NOT NULL THEN host(client_addr) || ':' || client_port WHEN client_port = -1 THEN 'local socket' ELSE '' END AS client, \
                coalesce(state, '') AS state, coalesce(wait_event_type || ': ' || wait_event, '') AS wait_event, \
                coalesce(to_char(backend_start, 'YYYY-MM-DD HH24:MI:SS'), '') AS backend_start, \
                coalesce(to_char(query_start, 'YYYY-MM-DD HH24:MI:SS'), '') AS query_start, \
                CASE WHEN state = 'active' THEN extract(epoch FROM clock_timestamp() - query_start) \
                WHEN state LIKE 'idle in transaction%' THEN extract(epoch FROM clock_timestamp() - xact_start) END AS running_seconds, \
                coalesce(query, '') AS query \
                FROM pg_stat_activity WHERE pid <> pg_backend_pid()\(clientsOnly) ORDER BY pid
                """
        case .mysql, .mariadb:
            // information_schema.PROCESSLIST answers on every MySQL and MariaDB version, with or without performance_schema.
            return """
                SELECT ID AS id, coalesce(USER, '') AS user, coalesce(HOST, '') AS host, coalesce(DB, '') AS db, \
                coalesce(COMMAND, '') AS command, TIME AS time, coalesce(STATE, '') AS state, coalesce(INFO, '') AS info \
                FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID() ORDER BY ID
                """
        case .sqlite, .duckdb, .mongodb, .redis:
            return nil
        }
    }

    /// The rows of `sessionsQuery`, columns found by name.
    public func sessions(from result: StatementResult) -> [ServerActivitySession] {
        let row = RowReader(result)
        return result.rows.compactMap { cells -> ServerActivitySession? in
            switch kind {
            case .postgresql:
                guard let pid = row.int(cells, "pid") else { return nil }
                let state = row.text(cells, "state")
                return ServerActivitySession(
                    id: pid, user: row.text(cells, "username"), database: row.text(cells, "database"),
                    application: row.text(cells, "application"), client: row.text(cells, "client"), state: state,
                    waitEvent: row.text(cells, "wait_event"), backendStart: row.text(cells, "backend_start"),
                    queryStart: row.text(cells, "query_start"), runningSeconds: row.double(cells, "running_seconds"),
                    query: row.text(cells, "query"), isIdle: state == "idle"
                )
            case .mysql, .mariadb:
                guard let id = row.int(cells, "id") else { return nil }
                let command = row.text(cells, "command")
                let idle = ["sleep", "daemon"].contains(command.lowercased())
                return ServerActivitySession(
                    id: id, user: row.text(cells, "user"), database: row.text(cells, "db"), client: row.text(cells, "host"),
                    state: row.text(cells, "state"), command: command, runningSeconds: idle ? nil : row.double(cells, "time"),
                    query: row.text(cells, "info"), isIdle: idle
                )
            case .sqlite, .duckdb, .mongodb, .redis:
                return nil
            }
        }
    }

    /// The sessions shown: idle ones left out when `hideIdle`, the rest matching `filter`, longest running first.
    public static func visible(_ sessions: [ServerActivitySession], filter: String, hideIdle: Bool) -> [ServerActivitySession] {
        sessions
            .filter { !(hideIdle && $0.isIdle) && $0.matches(filter) }
            .sorted { ($0.runningSortKey, -$0.id) > ($1.runningSortKey, -$1.id) }
    }

    /// Marks the app's own sessions: `owners` maps a process id to the label shown for it.
    public static func marking(_ sessions: [ServerActivitySession], owners: [Int: String]) -> [ServerActivitySession] {
        sessions.map { session in
            var marked = session
            marked.owner = owners[session.id]
            return marked
        }
    }

    // MARK: Actions

    public func statement(_ action: ServerSessionAction, id: Int) -> String? {
        switch (kind, action) {
        case (.postgresql, .cancelQuery): return "SELECT pg_cancel_backend(\(id))"
        case (.postgresql, .terminate): return "SELECT pg_terminate_backend(\(id))"
        case (.mysql, .cancelQuery), (.mariadb, .cancelQuery): return "KILL QUERY \(id)"
        case (.mysql, .terminate), (.mariadb, .terminate): return "KILL CONNECTION \(id)"
        default: return nil
        }
    }

    /// What `statement` answered: PostgreSQL returns false for a pid that is gone; MySQL answers OK or an error.
    public func outcome(of results: [StatementResult]) -> ServerSessionActionOutcome {
        guard kind == .postgresql else { return .done }
        let answer = results.last(where: \.hasResultSet)?.rows.first?.first?.textValue?.lowercased()
        return answer == "f" || answer == "false" ? .notFound : .done
    }

    /// An error from `statement`, explained: a missing session is `notFound`, a refused one says which privilege it takes.
    public func outcome(of error: Error) -> ServerSessionActionOutcome {
        let message = error.localizedDescription
        guard case let .server(_, code, _)? = error as? DatabaseError, let code else { return .failed(message) }
        let number = code.split(separator: "/").first.map(String.init) ?? code
        switch (kind == .postgresql, number) {
        case (false, "1094"):
            return .notFound
        case (true, "42501"):
            return .failed(message + "\nCancelling or terminating another role's session takes superuser or membership in pg_signal_backend (superuser sessions only a superuser).")
        case (false, "1095"):
            return .failed(message + "\nKilling another user's session takes the CONNECTION_ADMIN privilege (MySQL 8) or SUPER.")
        default:
            return .failed(message)
        }
    }

    // MARK: Slow queries

    /// Finds where the statement statistics are: the schema of the pg_stat_statements extension (no row when it is not
    /// installed), or whether performance_schema is on and collects digests.
    public var slowQuerySourceQuery: String? {
        switch kind {
        case .postgresql:
            return "SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'pg_stat_statements'"
        case .mysql, .mariadb:
            return "SELECT @@performance_schema AS enabled, (SELECT ENABLED FROM performance_schema.setup_consumers WHERE NAME = 'statements_digest') AS digests"
        case .sqlite, .duckdb, .mongodb, .redis:
            return nil
        }
    }

    public func slowQuerySource(from result: StatementResult?) -> SlowQuerySource {
        let row = result?.rows.first ?? []
        switch kind {
        case .postgresql:
            guard let schema = row.first?.textValue, !schema.isEmpty else { return Self.pgStatStatementsMissing }
            return .available(schema: schema)
        case .mysql, .mariadb:
            let reader = result.map(RowReader.init)
            let enabled = reader?.text(row, "enabled") ?? ""
            guard enabled == "1" || enabled.uppercased() == "ON" else {
                return .unavailable(
                    reason: "performance_schema is off",
                    hint: "Statement statistics come from performance_schema, which this server has turned off. Set performance_schema=ON in the server's configuration and restart it."
                )
            }
            let digests = (reader?.text(row, "digests") ?? "").uppercased()
            guard digests != "NO" else {
                return .unavailable(
                    reason: "Statement digests are not collected",
                    hint: "performance_schema is on, but its statements_digest consumer is disabled. An administrator can enable it with UPDATE performance_schema.setup_consumers SET ENABLED = 'YES' WHERE NAME = 'statements_digest'."
                )
            }
            return .available(schema: "performance_schema")
        case .sqlite, .duckdb, .mongodb, .redis:
            return .unavailable(reason: "Not available for \(kind.displayName)", hint: "")
        }
    }

    static let pgStatStatementsMissingHint = "Slow queries come from the pg_stat_statements extension. To use it, an administrator adds pg_stat_statements to shared_preload_libraries, restarts the server and runs CREATE EXTENSION pg_stat_statements in this database."

    static let pgStatStatementsMissing = SlowQuerySource.unavailable(reason: "pg_stat_statements is not installed", hint: pgStatStatementsMissingHint)

    /// The source read failed: the extension exists but the server did not load its library.
    public func slowQuerySource(fromFailure error: Error) -> SlowQuerySource? {
        guard kind == .postgresql, error.localizedDescription.contains("shared_preload_libraries") else { return nil }
        return .unavailable(
            reason: "pg_stat_statements is not loaded",
            hint: "The extension is installed, but the server did not load its library. An administrator adds pg_stat_statements to shared_preload_libraries and restarts the server."
        )
    }

    /// The top `limit` statements by total or mean time from the source `slowQuerySource` found.
    public func slowQueriesQuery(schema: String, order: SlowQueryOrder, limit: Int = 50) -> String? {
        switch kind {
        case .postgresql:
            // PostgreSQL 13 renamed total_time and mean_time to total_exec_time and mean_exec_time.
            let total = versionAtLeast(13) ? "total_exec_time" : "total_time"
            let mean = versionAtLeast(13) ? "mean_exec_time" : "mean_time"
            let view = SQLDialect.postgresql.quoteIdentifier(schema) + ".pg_stat_statements"
            let sort = order == .totalTime ? "s.\(total)" : "s.\(mean)"
            return """
                SELECT s.query, coalesce(d.datname, '') AS database, coalesce(r.rolname, '') AS username, s.calls, \
                s.\(total) / 1000.0 AS total_seconds, s.\(mean) / 1000.0 AS mean_seconds, s.rows \
                FROM \(view) s LEFT JOIN pg_database d ON d.oid = s.dbid LEFT JOIN pg_roles r ON r.oid = s.userid \
                ORDER BY \(sort) DESC NULLS LAST LIMIT \(limit)
                """
        case .mysql, .mariadb:
            // Timers are in picoseconds; dividing by the DOUBLE 1e12 keeps the fraction (a DECIMAL division keeps 4 digits).
            // QUERY_SAMPLE_TEXT exists in MySQL 8.0.3 and later, not in MariaDB.
            let sample = !isMariaDB && versionAtLeast(8, 0, 3) ? "QUERY_SAMPLE_TEXT" : "NULL"
            let sort = order == .totalTime ? "SUM_TIMER_WAIT" : "AVG_TIMER_WAIT"
            return """
                SELECT DIGEST_TEXT AS query, \(sample) AS sample, coalesce(SCHEMA_NAME, '') AS db, COUNT_STAR AS calls, \
                SUM_TIMER_WAIT / 1e12 AS total_seconds, AVG_TIMER_WAIT / 1e12 AS mean_seconds, \
                SUM_ROWS_SENT AS rows_sent, SUM_ROWS_EXAMINED AS rows_examined \
                FROM performance_schema.events_statements_summary_by_digest WHERE DIGEST_TEXT IS NOT NULL \
                ORDER BY \(sort) DESC LIMIT \(limit)
                """
        case .sqlite, .duckdb, .mongodb, .redis:
            return nil
        }
    }

    /// The rows of `slowQueriesQuery`, numbered in their order.
    public func slowQueries(from result: StatementResult) -> [SlowQueryStat] {
        let row = RowReader(result)
        return result.rows.enumerated().map { index, cells in
            let mysql = kind != .postgresql
            return SlowQueryStat(
                id: index,
                query: row.text(cells, "query"),
                sample: mysql ? row.optionalText(cells, "sample") : nil,
                database: row.text(cells, mysql ? "db" : "database"),
                user: mysql ? "" : row.text(cells, "username"),
                calls: row.int(cells, "calls") ?? 0,
                totalSeconds: row.double(cells, "total_seconds") ?? 0,
                meanSeconds: row.double(cells, "mean_seconds") ?? 0,
                rows: row.int(cells, mysql ? "rows_sent" : "rows"),
                rowsExamined: mysql ? row.int(cells, "rows_examined") : nil
            )
        }
    }

    // MARK: Formatting

    /// "850 ms", "12.4 s", "3 min 05 s", "2 h 07 min"; empty for nil.
    public static func durationText(_ seconds: Double?) -> String {
        guard let seconds, seconds >= 0 else { return "" }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let whole = Int(seconds)
        if whole < 3600 { return String(format: "%d min %02d s", whole / 60, whole % 60) }
        return String(format: "%d h %02d min", whole / 3600, (whole % 3600) / 60)
    }
}

/// Reads cells of a result row by column name, case-insensitively.
private struct RowReader {
    private let index: [String: Int]

    init(_ result: StatementResult) {
        var index: [String: Int] = [:]
        for (position, column) in result.columns.enumerated() where index[column.name.lowercased()] == nil {
            index[column.name.lowercased()] = position
        }
        self.index = index
    }

    func optionalText(_ cells: [CellValue], _ name: String) -> String? {
        guard let position = index[name], cells.indices.contains(position) else { return nil }
        return cells[position].textValue
    }

    func text(_ cells: [CellValue], _ name: String) -> String { optionalText(cells, name) ?? "" }

    func double(_ cells: [CellValue], _ name: String) -> Double? { optionalText(cells, name).flatMap { Double($0) } }

    /// Whole numbers, also when the server sends them as decimals (MySQL SUM columns arrive as DECIMAL).
    func int(_ cells: [CellValue], _ name: String) -> Int? {
        guard let text = optionalText(cells, name) else { return nil }
        return Int(text) ?? Double(text).map { Int($0) }
    }
}

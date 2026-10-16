import Foundation

/// A command of the Maintenance submenu (sidebar and Database menu).
public enum MaintenanceOperation: String, CaseIterable, Sendable {
    // PostgreSQL
    case vacuum
    case vacuumAnalyze
    case vacuumFull
    case reindex
    /// PostgreSQL ANALYZE, MySQL ANALYZE TABLE, SQLite and DuckDB ANALYZE.
    case analyze
    // MySQL, MariaDB
    case optimize
    case check
    case checkQuick
    case checkExtended
    case repair
    // SQLite
    case integrityCheck
    case vacuumDatabase
    // DuckDB
    case checkpoint

    /// Runs once for the whole database (SQLite VACUUM, DuckDB CHECKPOINT) instead of once per table.
    public var isDatabaseWide: Bool { self == .vacuumDatabase || self == .checkpoint }

    /// Shown before the command runs, whatever the connection's Safe Mode: these rewrite tables under a lock or can
    /// lose rows.
    public var warning: String? {
        switch self {
        case .vacuumFull:
            return "VACUUM FULL rewrites each table into a new file and holds an ACCESS EXCLUSIVE lock until it finishes: nothing can read or write the table meanwhile. It needs free disk space for a full copy of the table."
        case .optimize:
            return "OPTIMIZE TABLE rebuilds each table (InnoDB recreates and analyzes it). Writes to the table can wait while it runs, and it needs free disk space for a copy of the table."
        case .repair:
            return "REPAIR TABLE can drop rows it cannot read. Back up the table first."
        default:
            return nil
        }
    }
}

/// One statement of a maintenance run: one per table, or one for the whole database.
public struct MaintenanceStep: Hashable, Sendable {
    /// Nil for a database-wide command.
    public var table: TableRef?
    public var statement: String

    public init(table: TableRef?, statement: String) {
        self.table = table
        self.statement = statement
    }
}

/// Maintenance commands per engine: which ones the menus offer and the statements they run.
/// PostgreSQL: VACUUM, VACUUM ANALYZE, ANALYZE, VACUUM FULL, REINDEX TABLE. MySQL and MariaDB: OPTIMIZE, ANALYZE,
/// CHECK (plain, QUICK, EXTENDED) and, for MyISAM and Aria tables, REPAIR TABLE. SQLite: ANALYZE, PRAGMA
/// integrity_check and VACUUM (whole database). DuckDB: ANALYZE and CHECKPOINT (its VACUUM does nothing).
/// MongoDB and Redis have none. Every statement runs on its own, outside a transaction (VACUUM refuses to run in one).
public struct MaintenanceSQL: Sendable {
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

    /// Whether the engine has maintenance commands at all.
    public var isSupported: Bool { kind.isSQL }

    public func title(_ operation: MaintenanceOperation) -> String {
        switch operation {
        case .vacuum: return "Vacuum"
        case .vacuumAnalyze: return "Vacuum Analyze"
        case .vacuumFull: return "Vacuum Full…"
        case .reindex: return "Reindex Table"
        case .analyze: return kind.usesMySQLProtocol ? "Analyze Table" : "Analyze"
        case .optimize: return "Optimize Table…"
        case .check: return "Check Table"
        case .checkQuick: return "Check Table (Quick)"
        case .checkExtended: return "Check Table (Extended)"
        case .repair: return "Repair Table…"
        case .integrityCheck: return "Integrity Check"
        case .vacuumDatabase: return "Vacuum Database"
        case .checkpoint: return "Checkpoint"
        }
    }

    /// The title without the ellipsis, for the results sheet and the history.
    public func name(_ operation: MaintenanceOperation) -> String {
        title(operation).replacingOccurrences(of: "…", with: "")
    }

    /// Objects a per-table command may run on. System tables, views and foreign tables are never offered.
    public func isMaintainable(_ table: TableInfo) -> Bool {
        switch table.kind {
        case .table: return isSupported
        case .materializedView: return kind == .postgresql
        case .view, .foreignTable, .systemTable, .keyspace: return false
        }
    }

    /// MySQL and MariaDB repair only MyISAM and Aria tables; InnoDB answers that it cannot.
    public static func supportsRepair(engine: String?) -> Bool {
        guard let engine = engine?.lowercased() else { return false }
        return engine == "myisam" || engine == "aria"
    }

    /// The menu's commands for `tables` (the selection; empty for none), in groups shown between separators.
    /// Per-table commands appear when at least one table is maintainable; Repair Table only when every one of them
    /// is MyISAM or Aria. Database-wide commands appear with or without a selection.
    public func operationGroups(for tables: [TableInfo]) -> [[MaintenanceOperation]] {
        let targets = tables.filter(isMaintainable)
        let hasTables = !targets.isEmpty
        var groups: [[MaintenanceOperation]]
        switch kind {
        case .postgresql:
            groups = hasTables ? [[.vacuum, .vacuumAnalyze, .analyze], [.vacuumFull, .reindex]] : []
        case .mysql, .mariadb:
            groups = hasTables ? [[.optimize, .analyze], [.check, .checkQuick, .checkExtended]] : []
            if hasTables, targets.allSatisfy({ Self.supportsRepair(engine: $0.engine) }) {
                groups.append([.repair])
            }
        case .sqlite:
            groups = hasTables ? [[.analyze, .integrityCheck]] : [[.integrityCheck]]
            groups.append([.vacuumDatabase])
        case .duckdb:
            groups = (hasTables ? [[.analyze]] : []) + [[.checkpoint]]
        case .mongodb, .redis:
            groups = []
        }
        return groups.filter { !$0.isEmpty }
    }

    /// The statements `operation` runs: one per maintainable table in `tables` (in the given order), or a single one
    /// for a database-wide command and for an integrity check without tables.
    public func steps(_ operation: MaintenanceOperation, tables: [TableInfo]) -> [MaintenanceStep] {
        if operation.isDatabaseWide || (operation == .integrityCheck && tables.isEmpty) {
            return statement(operation, table: nil).map { [MaintenanceStep(table: nil, statement: $0)] } ?? []
        }
        return tables.filter(isMaintainable).compactMap { info in
            if operation == .repair, !Self.supportsRepair(engine: info.engine) { return nil }
            return statement(operation, table: info.ref).map { MaintenanceStep(table: info.ref, statement: $0) }
        }
    }

    /// The statement for one table, or for the whole database when `table` is nil. Nil when the engine has no such
    /// command.
    public func statement(_ operation: MaintenanceOperation, table: TableRef?) -> String? {
        let name = table.map(dialect.qualifiedName)
        switch (kind, operation) {
        case (.postgresql, .vacuum): return name.map { "VACUUM \($0)" }
        case (.postgresql, .vacuumAnalyze): return name.map { "VACUUM ANALYZE \($0)" }
        case (.postgresql, .vacuumFull): return name.map { "VACUUM FULL \($0)" }
        case (.postgresql, .analyze): return name.map { "ANALYZE \($0)" }
        case (.postgresql, .reindex): return name.map { "REINDEX TABLE \($0)" }
        case (.mysql, .optimize), (.mariadb, .optimize): return name.map { "OPTIMIZE TABLE \($0)" }
        case (.mysql, .analyze), (.mariadb, .analyze): return name.map { "ANALYZE TABLE \($0)" }
        case (.mysql, .check), (.mariadb, .check): return name.map { "CHECK TABLE \($0)" }
        case (.mysql, .checkQuick), (.mariadb, .checkQuick): return name.map { "CHECK TABLE \($0) QUICK" }
        case (.mysql, .checkExtended), (.mariadb, .checkExtended): return name.map { "CHECK TABLE \($0) EXTENDED" }
        case (.mysql, .repair), (.mariadb, .repair): return name.map { "REPAIR TABLE \($0)" }
        case (.sqlite, .analyze), (.duckdb, .analyze): return name.map { "ANALYZE \($0)" }
        case (.sqlite, .integrityCheck):
            // PRAGMA takes the schema in front of its name and the table as its argument.
            guard let table else { return "PRAGMA integrity_check" }
            let schema = table.schema.flatMap { $0.isEmpty ? nil : dialect.quoteIdentifier($0) + "." } ?? ""
            return "PRAGMA \(schema)integrity_check(\(dialect.quoteIdentifier(table.name)))"
        case (.sqlite, .vacuumDatabase): return table == nil ? "VACUUM" : nil
        case (.duckdb, .checkpoint): return table == nil ? "CHECKPOINT" : nil
        default: return nil
        }
    }

    /// Whether the run changes anything, for Safe Mode and Read-Only connections. Judged by the same classifier as
    /// query tabs (`SQLStatementSplitter.looksReadOnly`): VACUUM, ANALYZE, REINDEX, OPTIMIZE, CHECKPOINT, REPAIR and
    /// also CHECK TABLE count as writes (CHECK TABLE locks the table and can mark a MyISAM table as crashed or
    /// checked); only SQLite's PRAGMA integrity_check is a read.
    public static func writes(_ steps: [MaintenanceStep]) -> Bool {
        steps.contains { !SQLStatementSplitter.looksReadOnly($0.statement) }
    }
}

// MARK: - Results

/// One line of what the server answered for a step.
public struct MaintenanceMessage: Hashable, Sendable {
    public enum Level: String, Sendable {
        case info
        case note
        case warning
        case error
    }

    public var level: Level
    public var text: String

    public init(_ level: Level, _ text: String) {
        self.level = level
        self.text = text
    }
}

public enum MaintenanceStatus: Hashable, Sendable {
    case waiting
    case running
    case ok
    case warning
    case failed
    case cancelled
    /// Not started because the run was cancelled before its turn.
    case skipped

    public var isFinished: Bool { self != .waiting && self != .running }

    public var title: String {
        switch self {
        case .waiting: return "Waiting"
        case .running: return "Running…"
        case .ok: return "OK"
        case .warning: return "Warning"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .skipped: return "Not run"
        }
    }
}

/// What happened to one step.
public struct MaintenanceOutcome: Hashable, Sendable {
    public var status: MaintenanceStatus
    public var messages: [MaintenanceMessage]
    public var elapsed: TimeInterval?

    public init(status: MaintenanceStatus, messages: [MaintenanceMessage] = [], elapsed: TimeInterval? = nil) {
        self.status = status
        self.messages = messages
        self.elapsed = elapsed
    }

    /// The messages on one line, for the results list and copies.
    public var summary: String {
        messages.map(\.text).joined(separator: "; ")
    }

    /// Reads what a step returned:
    /// - MySQL and MariaDB answer with a Table / Op / Msg_type / Msg_text result set; an `error` row (or a status of
    ///   "Operation failed" or "Corrupt") fails the step and a `warning` row makes it a warning.
    /// - SQLite's integrity_check returns `ok` or one row per problem.
    /// - Otherwise the completion tag (PostgreSQL `VACUUM`) is reported, with the notices the server sent:
    ///   a PostgreSQL WARNING (such as "skipping … only table or database owner can vacuum it") makes it a warning.
    public static func reading(_ results: [StatementResult], notices: [String] = [], elapsed: TimeInterval? = nil) -> MaintenanceOutcome {
        var messages: [MaintenanceMessage] = []
        var status = MaintenanceStatus.ok
        func raise(to level: MaintenanceStatus) {
            if level == .failed || (level == .warning && status == .ok) { status = level }
        }
        for result in results {
            let names = result.columns.map { $0.name.lowercased() }
            if let type = names.firstIndex(of: "msg_type"), let text = names.firstIndex(of: "msg_text") {
                for row in result.rows where row.count > max(type, text) {
                    let kind = row[type].displayString.lowercased()
                    let message = row[text].displayString
                    switch kind {
                    case "error":
                        messages.append(MaintenanceMessage(.error, message))
                        raise(to: .failed)
                    case "warning":
                        messages.append(MaintenanceMessage(.warning, message))
                        raise(to: .warning)
                    case "note", "info":
                        messages.append(MaintenanceMessage(.note, message))
                    default:
                        let failed = ["operation failed", "corrupt"].contains(message.lowercased())
                        messages.append(MaintenanceMessage(failed ? .error : .info, message))
                        if failed { raise(to: .failed) }
                    }
                }
            } else if names == ["integrity_check"] {
                for row in result.rows {
                    let text = row.first?.displayString ?? ""
                    if text.lowercased() == "ok" {
                        messages.append(MaintenanceMessage(.info, "ok"))
                    } else {
                        messages.append(MaintenanceMessage(.error, text))
                        raise(to: .failed)
                    }
                }
            } else if let tag = result.message, !tag.isEmpty, !tag.hasPrefix("Affected rows") {
                messages.append(MaintenanceMessage(.info, tag))
            }
        }
        for notice in notices {
            let upper = notice.uppercased()
            if upper.hasPrefix("WARNING") {
                messages.append(MaintenanceMessage(.warning, notice))
                raise(to: .warning)
            } else {
                messages.append(MaintenanceMessage(upper.hasPrefix("INFO") ? .info : .note, notice))
            }
        }
        if messages.isEmpty { messages = [MaintenanceMessage(.info, "Done")] }
        return MaintenanceOutcome(status: status, messages: messages, elapsed: elapsed)
    }
}

// MARK: - Running

/// Runs maintenance steps one after another on a session of its own (no query timeout), one statement per queue job
/// and never inside a transaction. `cancel()` stops the running statement through the session's cancel path (the one
/// ⌘. uses) and leaves the remaining steps unrun. A failing step does not stop the others.
public final class MaintenanceRun: @unchecked Sendable {
    public let steps: [MaintenanceStep]
    private let lock = NSLock()
    private var cancelled = false
    private var session: DatabaseSession?
    private var token: QueryToken?

    public init(steps: [MaintenanceStep]) {
        self.steps = steps
    }

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    /// Safe from any thread.
    public func cancel() {
        let running = lock.withLock { () -> (DatabaseSession?, QueryToken?) in
            cancelled = true
            return (session, token)
        }
        if let session = running.0, let token = running.1 { session.cancel(token) }
    }

    /// Makes `token` the running statement, or returns false when the run was cancelled before this step.
    private func start(_ token: QueryToken, on session: DatabaseSession) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            self.session = session
            self.token = token
            return true
        }
    }

    private func finish() {
        lock.withLock {
            session = nil
            token = nil
        }
    }

    /// Runs every step and returns their outcomes in order. `update` gets each step's index and outcome when it
    /// starts and when it ends, from the task that runs the steps.
    public func run(on session: DatabaseSession, update: @escaping @Sendable (Int, MaintenanceOutcome) -> Void = { _, _ in }) async -> [MaintenanceOutcome] {
        var outcomes: [MaintenanceOutcome] = []
        for (index, step) in steps.enumerated() {
            let token = QueryToken()
            guard start(token, on: session) else {
                let skipped = MaintenanceOutcome(status: .skipped)
                outcomes.append(skipped)
                update(index, skipped)
                continue
            }
            update(index, MaintenanceOutcome(status: .running))
            let started = Date()
            let outcome: MaintenanceOutcome
            do {
                let (results, notices) = try await session.runStatement(token) { connection -> ([StatementResult], [String]) in
                    let results = try connection.execute(step.statement, rowLimit: nil)
                    return (results, (connection as? PostgresConnection)?.notices ?? [])
                }
                var read = MaintenanceOutcome.reading(results, notices: notices, elapsed: Date().timeIntervalSince(started))
                // MySQL reports a killed OPTIMIZE or CHECK as an error row ("Query execution was interrupted").
                if read.status == .failed, isCancelled {
                    read.status = .cancelled
                    read.messages.insert(MaintenanceMessage(.warning, "Stopped by Cancel"), at: 0)
                }
                outcome = read
            } catch {
                let elapsed = Date().timeIntervalSince(started)
                var wasCancelled = isCancelled
                if case .cancelled? = error as? DatabaseError { wasCancelled = true }
                if wasCancelled {
                    outcome = MaintenanceOutcome(status: .cancelled, messages: [MaintenanceMessage(.warning, "Stopped by Cancel")], elapsed: elapsed)
                } else {
                    outcome = MaintenanceOutcome(status: .failed, messages: [MaintenanceMessage(.error, error.localizedDescription)], elapsed: elapsed)
                }
            }
            finish()
            outcomes.append(outcome)
            update(index, outcome)
        }
        return outcomes
    }
}

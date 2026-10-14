import AppKit
import FoxlumeQueryCore

/// Export and import run on a session of their own: they hold a transaction and the session queue for a long
/// time, and the workspace's session must stay free for the grid and query tabs meanwhile.
extension ConnectionWorkspace {
    /// Engines whose tables can be exported and imported with SQL.
    var supportsTableTransfer: Bool { kind.isSQL }

    /// Opens a second session with the same settings, switched to the database (and read-only mode) in use.
    func openTransferSession() async throws -> DatabaseSession {
        let session = DatabaseSession(parameters: self.session.parameters)
        do {
            try await session.connect()
            if kind.supportsMultipleDatabases, let database = currentDatabase, !database.isEmpty {
                let current = await session.currentDatabase()
                if current != database {
                    try await session.run { try $0.useDatabase(database) }
                }
            }
            if config.readOnly {
                switch kind {
                case .postgresql: _ = try await session.execute("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY")
                case .mysql, .mariadb: _ = try await session.execute("SET SESSION TRANSACTION READ ONLY")
                case .sqlite, .duckdb, .mongodb, .redis: break
                }
            }
            return session
        } catch {
            await session.close()
            throw error
        }
    }

    /// Tables and views of the current database or schema that an export can read.
    var exportableObjects: [TableInfo] {
        tables.filter { [.table, .view, .materializedView, .foreignTable].contains($0.kind) }
    }

    /// Tables an import can write to.
    var importableTables: [TableInfo] {
        tables.filter { $0.kind == .table }
    }

    /// Applies the connection's Safe Mode before an import writes: refused on Read-Only, confirmed (and for the
    /// Safe Mode levels authenticated) as other writes are. Calls `proceed` when allowed.
    func confirmImport(_ action: String, detail: String, in window: NSWindow?, proceed: @escaping () -> Void) {
        let level = SafeModeGate.level(for: config)
        guard !level.blocksAllWrites else {
            Alerts.showError(DatabaseError.unsupported("This connection is read-only. Imports are not run."), title: "Read-only connection", in: window)
            return
        }
        SafeModeGate.authorize(config: config, statements: [], writes: true, action: action, extraDetail: level.gates(writes: true) ? detail : nil, in: window) { allowed in
            if allowed { proceed() }
        }
    }

    /// One line in the query history for an import, so it shows up next to the statements of the session.
    func recordTransfer(_ summary: String, duration: TimeInterval, rows: Int?, error: String?) {
        AppEnvironment.history.add(sql: summary, connectionID: config.id, database: currentDatabase, duration: duration, rowCount: rows, error: error)
    }
}

/// Keeps an eye on the transfer sheet in front, for the scripted UI checks.
@MainActor
enum TransferSheets {
    static weak var exportSheet: ExportTablesController?
    static weak var importSheet: ImportCSVController?
    static weak var sqlFileSheet: RunSQLFileController?
}

/// Progress callbacks arrive on the session queue for every page; the UI only needs a few per second.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
    }

    /// True when enough time passed since the last accepted update.
    func shouldReport() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}

extension Int64 {
    var byteCountText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

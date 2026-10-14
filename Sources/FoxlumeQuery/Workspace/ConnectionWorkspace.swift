import AppKit
import FoxlumeQueryCore

/// Everything one open connection knows: the session, the catalog it browses and cached table structures.
@MainActor
final class ConnectionWorkspace {
    static let metadataDidChange = Notification.Name("FoxlumeQuery.ConnectionWorkspace.metadataDidChange")
    static let activityDidChange = Notification.Name("FoxlumeQuery.ConnectionWorkspace.activityDidChange")

    private(set) var config: ConnectionConfig
    private(set) var session: DatabaseSession
    private let password: String

    private(set) var databases: [String] = []
    private(set) var currentDatabase: String?
    private(set) var schemas: [String] = []
    private(set) var currentSchema: String?
    private(set) var tables: [TableInfo] = []
    private(set) var isLoadingTables = false
    /// Keys of the current database for engines with a key tree (Redis).
    private(set) var keyListing: KeyListing?
    static let keyTreeLimit = 50_000
    private(set) var lastError: Error?
    /// Round trip of the last metadata refresh, shown in the toolbar.
    private(set) var latency: TimeInterval?
    private(set) var runningStatements = 0

    enum ConnectionState: Equatable {
        case connected
        case reconnecting
        /// The link failed or the user disconnected; the message says why.
        case lost(String)
    }

    /// Shown in the toolbar. A lost connection reconnects on its next use or from Reconnect.
    private(set) var connectionState: ConnectionState = .connected
    private var healthTask: Task<Void, Never>?
    private var monitoredHealthCheck: ConnectionHealthCheck?
    private var settingsObserver: NSObjectProtocol?
    private var reconnectTask: Task<Void, Error>?
    static let pingTimeout: TimeInterval = 10

    private var structures: [TableRef: TableStructure] = [:]
    private var structureTasks: [TableRef: Task<TableStructure, Error>] = [:]
    private var prefetchTask: Task<Void, Never>?
    /// Engine and caches behind editor completion; see ConnectionWorkspace+Completion.swift.
    let completionCatalog = CompletionCatalog()

    init(config: ConnectionConfig, password: String, sshSecret: String? = nil) {
        self.config = config
        self.password = password
        self.session = DatabaseSession(parameters: ConnectionParameters(config: config, password: password, sshSecret: sshSecret))
    }

    var kind: DatabaseKind { config.kind }
    var dialect: SQLDialect { session.dialect }
    var serverVersion: String { session.serverVersion }
    var isReadOnly: Bool { config.readOnly }

    func connect() async throws {
        try await session.connect()
        do {
            try await applyReadOnly()
        } catch {
            await session.close()
            throw error
        }
        AppEnvironment.connections.markUsed(id: config.id)
        await refreshMetadata()
        startHealthMonitor()
    }

    /// Makes the server refuse writes for read-only connections. Runs after every (re)connect, because a
    /// PostgreSQL database switch opens a new session. Failing here must stop the connection, not continue writable.
    private func applyReadOnly() async throws {
        guard config.readOnly else { return }
        switch config.kind {
        case .postgresql:
            _ = try await session.execute("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY")
        case .mysql, .mariadb:
            _ = try await session.execute("SET SESSION TRANSACTION READ ONLY")
        case .sqlite, .duckdb:
            // Opened with read-only flags by the driver.
            break
        case .mongodb, .redis:
            // No session-level switch exists; `execute` and `applyChanges` refuse writes on the client.
            break
        }
    }

    var capabilities: EngineCapabilities { session.capabilities }
    var queryLanguage: QueryLanguage { capabilities.queryLanguage }

    /// Statements in `sql` that may change data, for read-only and production checks.
    func writeStatements(in sql: String) -> [SQLStatementRange] {
        queryLanguage.split(sql).filter { !queryLanguage.isReadOnly($0.text) }
    }

    /// Stops the running statement, if any. Used when the window closes.
    func cancelEverything() {
        session.cancel()
    }

    func disconnect() async {
        healthTask?.cancel()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        prefetchTask?.cancel()
        completionCatalog.cancelLoads()
        for task in structureTasks.values { task.cancel() }
        await session.close()
    }

    /// Reloads databases, schemas and tables. Keeps the previous lists when the refresh fails.
    func refreshMetadata() async {
        // A lost link reconnects first; a successful reconnect refreshes on its own.
        if case .lost = connectionState, reconnectTask == nil {
            do {
                try await reconnect()
            } catch {
                lastError = error
                notifyMetadata()
            }
            return
        }
        isLoadingTables = tables.isEmpty
        notifyMetadata()
        let started = Date()
        do {
            let kind = config.kind
            let loaded = try await session.run { connection -> ([String], String?, [String], String?) in
                let databases = kind.supportsMultipleDatabases ? ((try? connection.databases()) ?? []) : []
                let schemas = try connection.schemas()
                return (databases, connection.currentDatabase, schemas, connection.defaultSchema)
            }
            let hidden = AppEnvironment.settings.showSystemDatabases ? [] : kind.systemDatabases
            databases = loaded.0.filter { !hidden.contains($0) || $0 == loaded.1 }
            currentDatabase = loaded.1
            schemas = loaded.2
            if currentSchema == nil || !(schemas.contains(currentSchema ?? "")) {
                currentSchema = loaded.3 ?? schemas.first
            }
            let schema = currentSchema
            tables = try await session.run { try $0.tables(schema: schema) }
            if case .keyPattern = capabilities.browseFilterStyle {
                keyListing = try await session.browseKeys(pattern: "*", limit: Self.keyTreeLimit)
            }
            latency = Date().timeIntervalSince(started)
            lastError = nil
            // Staged operations on objects that are gone (dropped elsewhere, renamed) can no longer run.
            pendingTableOperations.removeAll { operation in
                operation.table.schema == schema && !tables.contains { $0.ref == operation.table }
            }
            structures.removeAll()
            completionCatalog.catalogDidRefresh()
            prefetchStructures()
        } catch {
            lastError = error
            noteFailure(error)
        }
        isLoadingTables = false
        notifyMetadata()
    }

    /// Reloads only the key tree, for the sidebar's Refresh.
    func refreshKeys() async {
        guard case .keyPattern = capabilities.browseFilterStyle else { return }
        keyListing = (try? await session.browseKeys(pattern: "*", limit: Self.keyTreeLimit)) ?? keyListing
        notifyMetadata()
    }

    /// Separator used to group keys into folders (Redis `user:1:name` → user / 1 / name).
    var keySeparator: String { config.option(.redisKeySeparator) ?? ":" }

    func switchDatabase(_ name: String) async throws {
        guard name != currentDatabase else { return }
        completionCatalog.stopPreload()
        try await session.run { try $0.useDatabase(name) }
        pendingTableOperations.removeAll()
        try await applyReadOnly()
        currentSchema = nil
        tables = []
        await refreshMetadata()
    }

    func switchSchema(_ name: String) async {
        guard name != currentSchema else { return }
        completionCatalog.stopPreload()
        currentSchema = name
        tables = []
        await refreshMetadata()
    }

    func structure(of table: TableRef) async throws -> TableStructure {
        if let cached = structures[table] { return cached }
        if let running = structureTasks[table] { return try await running.value }
        let session = self.session
        let task = Task { try await session.run { try $0.structure(of: table) } }
        structureTasks[table] = task
        defer { structureTasks[table] = nil }
        let structure = try await task.value
        structures[table] = structure
        return structure
    }

    /// Loads column lists in the background so editor completion can offer them right away.
    /// Each table is a separate session job, so user queries interleave instead of waiting for the whole batch.
    private func prefetchStructures() {
        prefetchTask?.cancel()
        let targets = tables.filter { $0.kind != .systemTable }.prefix(150).map(\.ref)
        prefetchTask = Task { [weak self] in
            for table in targets {
                guard let self, !Task.isCancelled else { return }
                if self.structures[table] == nil {
                    _ = try? await self.structure(of: table)
                }
            }
        }
    }

    func cachedStructure(of table: TableRef) -> TableStructure? {
        structures[table]
    }

    /// Every structure loaded so far, for completion with no table in scope.
    var cachedStructures: [TableStructure] {
        Array(structures.values)
    }

    func invalidateStructure(of table: TableRef) {
        structures[table] = nil
    }

    func ddl(of table: TableRef) async throws -> String {
        try await session.run { try $0.ddl(of: table) }
    }

    /// Run SQL and record it in the query history. Pass a token to make this statement cancellable on its own.
    func execute(_ sql: String, rowLimit: Int? = nil, recordHistory: Bool = true, token: QueryToken? = nil) async throws -> [StatementResult] {
        if config.readOnly, !writeStatements(in: sql).isEmpty {
            throw DatabaseError.unsupported("This connection is read-only. Statements that change data are not run.")
        }
        try await ensureConnected()
        runningStatements += 1
        NotificationCenter.default.post(name: Self.activityDidChange, object: self)
        defer {
            runningStatements -= 1
            NotificationCenter.default.post(name: Self.activityDidChange, object: self)
        }
        let started = Date()
        do {
            let results = try await session.execute(sql, rowLimit: rowLimit, token: token)
            if recordHistory {
                let rows = results.last(where: \.hasResultSet)?.rows.count ?? results.last?.affectedRows
                AppEnvironment.history.add(sql: sql, connectionID: config.id, database: currentDatabase, duration: Date().timeIntervalSince(started), rowCount: rows, error: nil)
            }
            if queryLanguage.split(sql).contains(where: { queryLanguage.changesCatalog($0.text) }) {
                await refreshMetadata()
            }
            return results
        } catch {
            if recordHistory {
                AppEnvironment.history.add(sql: sql, connectionID: config.id, database: currentDatabase, duration: Date().timeIntervalSince(started), rowCount: nil, error: error.localizedDescription)
            }
            noteFailure(error)
            throw error
        }
    }

    func cancel(_ token: QueryToken) {
        session.cancel(token)
    }

    /// Saves grid edits as one session job; the driver makes it atomic where the engine allows.
    /// `summary` is what the history shows, for example the generated SQL.
    func applyChanges(_ batch: ChangeBatch, summary: String, token: QueryToken? = nil) async throws {
        if config.readOnly {
            throw DatabaseError.unsupported("This connection is read-only.")
        }
        try await tracked {
            let started = Date()
            do {
                try await session.applyChanges(batch, token: token)
                AppEnvironment.history.add(sql: summary, connectionID: config.id, database: currentDatabase, duration: Date().timeIntervalSince(started), rowCount: batch.changes.changeCount, error: nil)
            } catch {
                AppEnvironment.history.add(sql: summary, connectionID: config.id, database: currentDatabase, duration: Date().timeIntervalSince(started), rowCount: nil, error: error.localizedDescription)
                throw error
            }
        }
    }

    func fetchRows(_ query: TableQuery, token: QueryToken? = nil) async throws -> StatementResult {
        try await tracked { try await session.fetchRows(query, token: token) }
    }

    func countRows(_ query: TableQuery) async throws -> Int? {
        try await tracked { try await session.countRows(query) }
    }

    /// Counts the operation as running so the toolbar shows activity, after making sure the link is up.
    func tracked<T>(_ body: () async throws -> T) async throws -> T {
        try await ensureConnected()
        runningStatements += 1
        NotificationCenter.default.post(name: Self.activityDidChange, object: self)
        defer {
            runningStatements -= 1
            NotificationCenter.default.post(name: Self.activityDidChange, object: self)
        }
        do {
            return try await body()
        } catch {
            noteFailure(error)
            throw error
        }
    }

    // MARK: Connection health

    private func setConnectionState(_ state: ConnectionState) {
        guard state != connectionState else { return }
        connectionState = state
        NotificationCenter.default.post(name: Self.activityDidChange, object: self)
    }

    /// A statement that failed because the link is gone marks the connection lost.
    private func noteFailure(_ error: Error) {
        guard (error as? DatabaseError)?.isConnectionLoss == true, connectionState == .connected else { return }
        setConnectionState(.lost(error.localizedDescription))
    }

    /// Reconnects first when the link was lost, so the user's next action just works.
    private func ensureConnected() async throws {
        switch connectionState {
        case .connected: return
        case .reconnecting, .lost: try await reconnect()
        }
    }

    /// Pings on the interval from Settings while nothing else runs, and reconnects in the background when a ping fails.
    func startHealthMonitor() {
        healthTask?.cancel()
        monitoredHealthCheck = AppEnvironment.settings.connectionHealthCheck
        if settingsObserver == nil {
            settingsObserver = NotificationCenter.default.addObserver(forName: SettingsStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.connectionState == .connected, self.monitoredHealthCheck != AppEnvironment.settings.connectionHealthCheck else { return }
                    self.startHealthMonitor()
                }
            }
        }
        guard let interval = AppEnvironment.settings.connectionHealthCheck.interval, !kind.isFileBased else { return }
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.checkHealth()
            }
        }
    }

    func checkHealth() async {
        guard connectionState == .connected, runningStatements == 0 else { return }
        do {
            try await session.ping(timeout: Self.pingTimeout)
        } catch {
            setConnectionState(.lost(error.localizedDescription))
            // Three quiet attempts, as a background reconnect; after that Reconnect is up to the user.
            for delay in [0.0, 2, 5] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if (try? await reconnect()) != nil { return }
            }
        }
    }

    /// Opens a fresh link, returns to the database in use and reloads the catalog. Concurrent callers share one attempt.
    func reconnect() async throws {
        if let reconnectTask { return try await reconnectTask.value }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.performReconnect()
        }
        reconnectTask = task
        defer { reconnectTask = nil }
        try await task.value
    }

    private func performReconnect() async throws {
        let database = currentDatabase
        setConnectionState(.reconnecting)
        do {
            try await session.reconnect()
            if kind.supportsMultipleDatabases, let database, !database.isEmpty {
                let current = await session.currentDatabase()
                if current != database {
                    try await session.run { try $0.useDatabase(database) }
                }
            }
            try await applyReadOnly()
        } catch {
            setConnectionState(.lost(error.localizedDescription))
            throw error
        }
        setConnectionState(.connected)
        await refreshMetadata()
        startHealthMonitor()
    }

    /// Closes the link but keeps the window, as TablePro's Disconnect does. Reconnect or any use opens it again.
    func disconnectKeepingWindow() async {
        healthTask?.cancel()
        session.cancel()
        await session.close()
        setConnectionState(.lost("Disconnected."))
    }

    // MARK: Truncate, Drop and Rename

    /// Truncates and drops chosen in the sidebar. As in TablePro they wait for Save (⌘S).
    private(set) var pendingTableOperations: [PendingTableOperation] = []

    var tableOperations: TableOperationSQL { TableOperationSQL(kind: kind) }

    func pendingOperation(for table: TableRef) -> PendingTableOperation? {
        pendingTableOperations.first { $0.table == table }
    }

    /// Stages `operation`, replacing any other operation staged for the same object.
    func stage(_ operation: PendingTableOperation) {
        pendingTableOperations.removeAll { $0.table == operation.table }
        pendingTableOperations.append(operation)
        notifyMetadata()
    }

    func unstage(_ table: TableRef) {
        pendingTableOperations.removeAll { $0.table == table }
        notifyMetadata()
    }

    func discardPendingTableOperations() {
        guard !pendingTableOperations.isEmpty else { return }
        pendingTableOperations.removeAll()
        notifyMetadata()
    }

    var pendingTableOperationPlan: TableOperationPlan {
        tableOperations.plan(pendingTableOperations)
    }

    /// Runs the staged operations as one session job, then reloads the catalog.
    /// On failure they stay staged, so the user can fix the cause and save again or discard them.
    @discardableResult
    func applyPendingTableOperations() async throws -> [PendingTableOperation] {
        let operations = pendingTableOperations
        guard !operations.isEmpty else { return [] }
        if config.readOnly {
            throw DatabaseError.unsupported("This connection is read-only.")
        }
        let plan = tableOperations.plan(operations)
        let summary = plan.all.joined(separator: ";\n")
        try await tracked {
            let started = Date()
            do {
                try await session.run(plan)
                AppEnvironment.history.add(sql: summary, connectionID: config.id, database: currentDatabase, duration: Date().timeIntervalSince(started), rowCount: nil, error: nil)
            } catch {
                AppEnvironment.history.add(sql: summary, connectionID: config.id, database: currentDatabase, duration: Date().timeIntervalSince(started), rowCount: nil, error: error.localizedDescription)
                await refreshMetadata()
                throw error
            }
        }
        pendingTableOperations.removeAll { operations.contains($0) }
        await refreshMetadata()
        return operations
    }

    /// Renames right away, like TablePro's inline rename.
    func rename(_ table: TableRef, objectKind: TableKind, to newName: String) async throws {
        guard let statement = tableOperations.renameStatement(table, objectKind: objectKind, to: newName) else {
            throw DatabaseError.unsupported("\(kind.displayName) cannot rename this object.")
        }
        _ = try await execute(statement)
        if !queryLanguage.changesCatalog(statement) {
            await refreshMetadata()
        }
    }

    private func notifyMetadata() {
        NotificationCenter.default.post(name: Self.metadataDidChange, object: self)
    }
}

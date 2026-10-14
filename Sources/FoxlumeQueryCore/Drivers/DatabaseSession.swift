import Foundation

/// Identifies one queued statement so it can be cancelled without touching other work on the session.
public final class QueryToken: @unchecked Sendable {
    fileprivate var isCancelled = false
    public init() {}
}

/// Owns one `DatabaseConnection` and serializes all work on it onto a private queue.
public final class DatabaseSession: @unchecked Sendable {
    public let parameters: ConnectionParameters
    /// Replaced once in `connect()` when an SSH tunnel moves the endpoint to a local port.
    private var connection: DatabaseConnection
    private var tunnel: SSHTunnel?
    /// The token of the statement running right now, guarded by `stateLock`.
    private var activeToken: QueryToken?
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var _isConnected = false
    private var _serverVersion = ""

    public init(parameters: ConnectionParameters) {
        self.parameters = parameters
        self.connection = ConnectionFactory.make(parameters)
        self.queue = DispatchQueue(label: "FoxlumeQuery.session.\(parameters.config.id.uuidString)", qos: .userInitiated)
    }

    public var kind: DatabaseKind { parameters.config.kind }
    public var dialect: SQLDialect { currentConnection.dialect }

    /// Guarded by `stateLock` because `cancel()` reads it while the queue is busy with a statement.
    private var currentConnection: DatabaseConnection { withState { connection } }

    public var isConnected: Bool { withState { _isConnected } }

    public var serverVersion: String { withState { _serverVersion } }

    /// "TLS 1.3" when the current connection is encrypted (and the driver can tell), nil otherwise.
    public var tlsProtocolVersion: String? { (currentConnection as? TLSReporting)?.tlsProtocolVersion }

    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    /// Run `body` on the session queue.
    public func run<T>(_ body: @escaping (DatabaseConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body(self.currentConnection))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func connect() async throws {
        if parameters.config.usesSSH, tunnel == nil {
            try await openTunnel()
        }
        let version: String = try await run { connection in
            try connection.connect()
            return connection.serverVersion
        }
        withState {
            _isConnected = true
            _serverVersion = version
        }
    }

    public func close() async {
        _ = try? await run { connection in connection.close() }
        withState { _isConnected = false }
        tunnel?.stop()
        tunnel = nil
    }

    /// Proves the link still answers within `timeout`. A link that stays silent is shut down,
    /// which frees the session queue for a reconnect.
    public func ping(timeout: TimeInterval) async throws {
        let connection = currentConnection
        let fired = LockedFlag()
        let watchdog = DispatchWorkItem {
            fired.set()
            connection.abort()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            try await run { try $0.ping() }
        } catch {
            if fired.isSet {
                throw DatabaseError.connection("The server did not answer within \(Int(timeout)) seconds.")
            }
            throw error
        }
    }

    /// Drops the link and any SSH tunnel, then opens a fresh driver with the same settings.
    /// Session state (current database, variables, temporary tables) does not survive.
    public func reconnect() async throws {
        currentConnection.abort()
        await close()
        withState { connection = ConnectionFactory.make(parameters) }
        try await connect()
    }

    /// Starts ssh and points the driver at the forwarded local port.
    private func openTunnel() async throws {
        let config = parameters.config
        guard let ssh = config.ssh else { return }
        let tunnel = SSHTunnel(config: ssh, secret: parameters.sshSecret, remoteHost: config.host, remotePort: config.port)
        let localPort = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            queue.async {
                do {
                    continuation.resume(returning: try tunnel.start(timeout: TimeInterval(config.connectTimeout), knownHostsFile: AppPaths.knownHostsFile))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        var forwarded = config
        forwarded.host = "127.0.0.1"
        forwarded.port = localPort
        var forwardedParameters = ConnectionParameters(config: forwarded, password: parameters.password, tlsSecret: parameters.tlsSecret)
        // TLS still names and checks the real server, not the tunnel's local end.
        forwardedParameters.tlsServerName = parameters.tlsServerName ?? config.host
        let replacement = ConnectionFactory.make(forwardedParameters)
        withState { connection = replacement }
        self.tunnel = tunnel
    }

    public func execute(_ sql: String, rowLimit: Int? = nil, token: QueryToken? = nil) async throws -> [StatementResult] {
        try await run { connection in
            try self.begin(token)
            defer { self.end(token) }
            return try connection.execute(sql, rowLimit: rowLimit)
        }
    }

    /// Loads one page and, separately, the matching count; both run on the session queue.
    public func fetchRows(_ query: TableQuery, token: QueryToken? = nil) async throws -> StatementResult {
        try await run { connection in
            try self.begin(token)
            defer { self.end(token) }
            return try connection.fetchRows(query)
        }
    }

    public func countRows(_ query: TableQuery) async throws -> Int? {
        try await run { try $0.countRows(query) }
    }

    /// Saves grid edits as one queue job, so nothing queued meanwhile runs inside the driver's transaction.
    public func applyChanges(_ batch: ChangeBatch, token: QueryToken? = nil) async throws {
        try await run { connection in
            try self.begin(token)
            defer { self.end(token) }
            try connection.applyChanges(batch)
        }
    }

    public var capabilities: EngineCapabilities { currentConnection.capabilities }

    public func browseKeys(pattern: String, limit: Int) async throws -> KeyListing? {
        try await run { try $0.browseKeys(pattern: pattern, limit: limit) }
    }

    /// Runs `statements` in one transaction as a single queue job, so nothing queued meanwhile can run
    /// inside the transaction, and rolls back on the same job when a statement fails.
    public func executeTransaction(_ statements: [String], token: QueryToken? = nil) async throws -> [StatementResult] {
        try await run { connection in
            try self.begin(token)
            defer { self.end(token) }
            let dialect = connection.dialect
            let batch = ([dialect.beginStatement] + statements + ["COMMIT"]).joined(separator: ";\n")
            do {
                return try connection.execute(batch, rowLimit: nil)
            } catch {
                _ = try? connection.execute("ROLLBACK", rowLimit: nil)
                throw error
            }
        }
    }

    /// Marks `token`'s statement as running, or fails when it was cancelled while queued. Call on the session queue.
    func begin(_ token: QueryToken?) throws {
        try withState {
            if let token, token.isCancelled { throw DatabaseError.cancelled }
            activeToken = token
        }
    }

    func end(_ token: QueryToken?) {
        withState {
            if activeToken === token { activeToken = nil }
        }
    }

    /// Cancels the statement for `token`: interrupts it when it is running, or makes it fail
    /// before it starts when it is still queued. Other work on the session is left alone.
    public func cancel(_ token: QueryToken) {
        let isRunning = withState { () -> Bool in
            token.isCancelled = true
            return activeToken === token
        }
        if isRunning { currentConnection.cancel() }
    }

    /// Interrupts whatever statement is running. Safe to call from any thread.
    public func cancel() {
        currentConnection.cancel()
    }

    public func currentDatabase() async -> String? {
        (try? await run { $0.currentDatabase }) ?? nil
    }

    public func defaultSchema() async -> String? {
        (try? await run { $0.defaultSchema }) ?? nil
    }
}

/// A flag set from one thread and read from another.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

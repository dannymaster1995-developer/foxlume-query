import Foundation
import Security

/// MySQL and MariaDB over the client/server text protocol.
public final class MySQLConnection: DatabaseConnection, TLSReporting {
    public var kind: DatabaseKind { parameters.config.kind }
    public private(set) var serverVersion: String = ""
    public private(set) var currentDatabase: String?

    public var dialect: SQLDialect {
        stateLock.lock()
        defer { stateLock.unlock() }
        return SQLDialect(family: .mysql, backslashEscapes: !noBackslashEscapes)
    }

    let parameters: ConnectionParameters
    /// Tests turn this off to exercise the legacy EOF-terminated result sets.
    var requestsDeprecateEOF = true

    enum AuthenticationPath: Equatable {
        /// The first response was accepted (native password, or caching_sha2 with an empty password).
        case direct
        /// caching_sha2_password found the scramble in the server cache.
        case cachedFastPath
        case fullOverTLS
        case fullWithRSA
    }

    /// How the last `connect()` authenticated. Tests use it to check that each path ran.
    private(set) var authenticationPath: AuthenticationPath?

    private var transport: SocketTransport?
    private var stream: MySQLPacketStream?
    private(set) var capabilities: MySQLCapabilities = []

    /// Guards the state that `cancel()` and `dialect` read from other threads.
    private let stateLock = NSLock()
    private var connectionID: UInt32?
    private var isExecuting = false
    private var noBackslashEscapes = false

    public init(parameters: ConnectionParameters) {
        self.parameters = parameters
    }

    deinit { close() }

    var isTLS: Bool { transport?.isTLS ?? false }
    public var tlsProtocolVersion: String? { transport?.tlsProtocolVersion }

    var isMariaDB: Bool {
        kind == .mariadb || serverVersion.range(of: "MariaDB", options: .caseInsensitive) != nil
    }

    // MARK: - Connection

    public func connect() throws {
        guard stream == nil else { return }
        let config = parameters.config
        let timeout = TimeInterval(max(1, config.connectTimeout))
        let transport = SocketTransport()
        try transport.connect(host: config.host, port: config.port, timeout: timeout)

        // A server that accepts TCP but never speaks MySQL (a wrong port) would block the first read forever.
        let deadline = ConnectDeadline(timeout: timeout)
        deadline.watch(transport)
        let timedOut = DatabaseError.connection("Timed out after \(Int(timeout)) seconds waiting for the MySQL handshake from \(config.host):\(config.port).")
        do {
            let tls = try TLSContext.load(parameters)
            try handshake(transport: transport, tls: tls)
        } catch {
            let fired = deadline.finish()
            transport.close()
            throw fired ? timedOut : error
        }
        if deadline.finish() {
            teardown(sendQuit: false)
            throw timedOut
        }
        do {
            // MySQL's max_execution_time stops read-only SELECTs only. MariaDB's max_statement_time would stop writes
            // too, so MariaDB relies on the client-side stop alone.
            let isMariaDB = isMariaDB
            try applySessionSetup(config) { isMariaDB ? nil : "SET SESSION max_execution_time = \($0)" }
        } catch {
            teardown(sendQuit: true)
            throw error
        }
    }

    private func handshake(transport: SocketTransport, tls: TLSContext) throws {
        let config = parameters.config
        let stream = MySQLPacketStream(channel: transport)
        let first = try stream.read()
        if first.first == MySQLProtocol.errHeader {
            throw DatabaseError.connection(try MySQLErrorPacket(payload: first).message)
        }
        let greeting = try MySQLHandshake(payload: first)
        guard greeting.capabilities.contains([.protocol41, .secureConnection]) else {
            throw DatabaseError.unsupported("The server speaks a MySQL protocol older than 4.1, which is not supported.")
        }

        var desired: MySQLCapabilities = [
            .longPassword, .longFlag, .protocol41, .transactions, .secureConnection,
            .multiStatements, .multiResults, .psMultiResults, .pluginAuth, .pluginAuthLenencClientData,
        ]
        if requestsDeprecateEOF { desired.insert(.deprecateEOF) }
        if !config.database.isEmpty { desired.insert(.connectWithDB) }
        var client = desired.intersection(greeting.capabilities)

        var useTLS = false
        if config.sslMode.wantsTLS, greeting.capabilities.contains(.ssl) {
            client.insert(.ssl)
            var request = ByteWriter(capacity: 32)
            Self.writeResponsePrefix(&request, capabilities: client)
            try stream.write(request.bytes)
            try transport.startTLS(tls.options(host: config.host))
            useTLS = true
        } else if config.sslMode.requiresTLS {
            throw DatabaseError.connection("The server does not support SSL/TLS, which this connection requires.")
        }
        capabilities = client

        // Answer an unknown default plugin with native password; the server switches us if needed.
        var plugin = greeting.authPluginName
        if !MySQLAuth.supportedPlugins.contains(plugin) || (plugin == MySQLAuth.clearPassword && !useTLS) {
            plugin = MySQLAuth.nativePassword
        }
        let authData = try authResponse(plugin: plugin, scramble: greeting.scramble, isTLS: useTLS)

        var response = ByteWriter(capacity: 128)
        Self.writeResponsePrefix(&response, capabilities: client)
        response.cString(config.user)
        if client.contains(.pluginAuthLenencClientData) {
            response.lengthEncodedBytes(authData)
        } else {
            response.uint8(UInt8(truncatingIfNeeded: authData.count))
            response.append(authData)
        }
        if client.contains(.connectWithDB) { response.cString(config.database) }
        if client.contains(.pluginAuth) { response.cString(plugin) }

        let ok: MySQLOKPacket
        do {
            // With TLS, this first write runs the TLS handshake.
            try stream.write(response.bytes)
            ok = try authenticate(stream: stream, plugin: plugin, scramble: greeting.scramble, isTLS: useTLS)
        } catch {
            throw Self.explain(transport.tlsHandshakeError(error, endpoint: nil), tls: tls, isTLS: useTLS)
        }

        stateLock.lock()
        self.transport = transport
        self.stream = stream
        connectionID = greeting.connectionID
        noBackslashEscapes = ok.statusFlags.contains(.noBackslashEscapes)
        stateLock.unlock()
        serverVersion = MySQLHandshake.displayVersion(greeting.serverVersion)
        currentDatabase = config.database.isEmpty ? nil : config.database
    }

    /// A user created with `REQUIRE X509` is refused with the same "Access denied" as a wrong password when no client
    /// certificate was sent; mention the certificate.
    static func explain(_ error: Error, tls: TLSContext, isTLS: Bool) -> Error {
        guard isTLS, tls.identity == nil, case DatabaseError.authentication(let message)? = error as? DatabaseError,
              message.contains("Access denied")
        else { return error }
        return DatabaseError.authentication("\(message) Check the password. If the user requires a client certificate (REQUIRE X509), choose one in the SSL/TLS settings.")
    }

    /// The fixed 32-byte head shared by SSLRequest and HandshakeResponse41.
    private static func writeResponsePrefix(_ writer: inout ByteWriter, capabilities: MySQLCapabilities) {
        writer.uint32LE(capabilities.rawValue)
        writer.uint32LE(MySQLProtocol.clientMaxPacketSize)
        writer.uint8(MySQLProtocol.utf8mb4GeneralCI)
        writer.append([UInt8](repeating: 0, count: 23))
    }

    private func authResponse(plugin: String, scramble: [UInt8], isTLS: Bool) throws -> [UInt8] {
        let password = parameters.password
        switch plugin {
        case MySQLAuth.nativePassword:
            return MySQLAuth.nativePasswordScramble(password: password, scramble: scramble)
        case MySQLAuth.cachingSHA2Password:
            return MySQLAuth.cachingSHA2Scramble(password: password, scramble: scramble)
        case MySQLAuth.clearPassword:
            guard isTLS else {
                throw DatabaseError.authentication("The server asked for the password in clear text (mysql_clear_password). Foxlume Query only sends it over TLS; enable SSL for this connection.")
            }
            return MySQLAuth.cleartext(password)
        default:
            throw DatabaseError.unsupported("The authentication plugin \(plugin) is not supported.")
        }
    }

    /// Runs the authentication exchange after HandshakeResponse41 until the server sends OK.
    private func authenticate(stream: MySQLPacketStream, plugin initialPlugin: String, scramble initialScramble: [UInt8], isTLS: Bool) throws -> MySQLOKPacket {
        var plugin = initialPlugin
        var scramble = initialScramble
        var awaitingPublicKey = false
        var path = AuthenticationPath.direct
        while true {
            let packet = try stream.read()
            guard let header = packet.first else {
                throw DatabaseError.protocolViolation("Empty packet during authentication")
            }
            switch header {
            case MySQLProtocol.okHeader:
                authenticationPath = path
                return try MySQLOKPacket(payload: packet)

            case MySQLProtocol.errHeader:
                let error = try MySQLErrorPacket(payload: packet)
                if MySQLErrorPacket.authenticationCodes.contains(error.code) {
                    throw DatabaseError.authentication(error.message)
                }
                throw DatabaseError.server(message: error.message, code: error.codeText)

            case MySQLProtocol.eofHeader:
                guard packet.count > 1 else {
                    throw DatabaseError.unsupported("The server asked for pre-4.1 password authentication, which is not supported.")
                }
                var reader = ByteReader(packet)
                try reader.skip(1)
                plugin = try reader.cString()
                var data = reader.rest()
                if data.last == 0 { data.removeLast() }
                scramble = data
                awaitingPublicKey = false
                try stream.write(try authResponse(plugin: plugin, scramble: scramble, isTLS: isTLS))

            case MySQLProtocol.authMoreDataHeader:
                guard plugin == MySQLAuth.cachingSHA2Password else {
                    throw DatabaseError.protocolViolation("Unexpected authentication data for \(plugin)")
                }
                let data = Array(packet.dropFirst())
                if awaitingPublicKey {
                    awaitingPublicKey = false
                    try stream.write(try MySQLAuth.encryptPassword(parameters.password, scramble: scramble, publicKeyPEM: data))
                } else if data == [MySQLAuth.fastAuthSuccess] {
                    path = .cachedFastPath
                } else if data == [MySQLAuth.performFullAuthentication] {
                    if isTLS {
                        path = .fullOverTLS
                        try stream.write(MySQLAuth.cleartext(parameters.password))
                    } else {
                        path = .fullWithRSA
                        try stream.write([MySQLAuth.requestPublicKey])
                        awaitingPublicKey = true
                    }
                } else {
                    throw DatabaseError.protocolViolation("Unexpected caching_sha2_password state \(data.first ?? 0)")
                }

            default:
                throw DatabaseError.protocolViolation("Unexpected packet 0x\(String(header, radix: 16)) during authentication")
            }
        }
    }

    public func close() {
        teardown(sendQuit: true)
    }

    public func abort() {
        stateLock.lock()
        let transport = self.transport
        stateLock.unlock()
        transport?.interrupt()
    }

    private func teardown(sendQuit: Bool) {
        stateLock.lock()
        let transport = self.transport
        let stream = self.stream
        self.transport = nil
        self.stream = nil
        connectionID = nil
        stateLock.unlock()
        guard let transport else { return }
        if sendQuit, let stream {
            stream.resetSequence()
            try? stream.write([MySQLCommand.quit.rawValue])
        }
        transport.close()
    }

    /// Run `body` against the open stream. Errors that leave the stream in an unknown state close the connection.
    private func withStream<T>(_ body: (MySQLPacketStream) throws -> T) throws -> T {
        guard let stream else { throw DatabaseError.notConnected }
        do {
            return try body(stream)
        } catch let error as DatabaseError {
            switch error {
            case .server, .cancelled, .queryTimeout, .unsupported, .authentication:
                throw error
            case .connection, .protocolViolation, .notConnected:
                teardown(sendQuit: false)
                throw error
            }
        } catch {
            teardown(sendQuit: false)
            throw error
        }
    }

    private func updateStatus(_ status: MySQLServerStatus) {
        stateLock.lock()
        noBackslashEscapes = status.contains(.noBackslashEscapes)
        stateLock.unlock()
    }

    private func setExecuting(_ executing: Bool) {
        stateLock.lock()
        isExecuting = executing
        stateLock.unlock()
    }

    // MARK: - Statements

    public func execute(_ sql: String, rowLimit: Int?) throws -> [StatementResult] {
        let mayChangeDatabase = sql.range(of: #"\buse\s"#, options: [.regularExpression, .caseInsensitive]) != nil
        // The server stops a SELECT after `sql_select_limit` rows, so a capped result is not sent in full only to be
        // thrown away. One row past the cap tells "exactly the cap" from "more rows exist". The session's own value is
        // put back afterwards.
        let cap = rowLimit.flatMap { Self.returnsCappableRows(sql) ? $0 + 1 : nil }
        if let cap {
            _ = try runQuery("SET @foxlume_select_limit = @@SESSION.sql_select_limit, SESSION sql_select_limit = \(cap)", rowLimit: nil)
        }
        defer {
            if cap != nil {
                _ = try? runQuery("SET SESSION sql_select_limit = @foxlume_select_limit", rowLimit: nil)
            }
        }
        do {
            let results = try runQuery(sql, rowLimit: rowLimit)
            if mayChangeDatabase { refreshCurrentDatabase() }
            return results
        } catch {
            if mayChangeDatabase { refreshCurrentDatabase() }
            throw error
        }
    }

    /// True when the batch has a top-level SELECT a row cap would shorten. Batches asking for ROW_COUNT() or FOUND_ROWS()
    /// are left alone, because the SET that installs the cap would reset what those report.
    static func returnsCappableRows(_ sql: String) -> Bool {
        let lowered = sql.lowercased()
        if lowered.contains("row_count(") || lowered.contains("found_rows(") { return false }
        return SQLStatementSplitter.split(sql, family: .mysql).contains { statement in
            let text = SQLStatementSplitter.strippingComments(statement.text).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return ["SELECT", "WITH", "TABLE", "VALUES", "("].contains { text.hasPrefix($0) }
        }
    }

    /// COM_QUERY without the `USE` bookkeeping of `execute`. Metadata queries go through here.
    func runQuery(_ sql: String, rowLimit: Int?) throws -> [StatementResult] {
        try withStream { stream in
            setExecuting(true)
            defer { setExecuting(false) }
            var payload: [UInt8] = []
            payload.reserveCapacity(sql.utf8.count + 1)
            payload.append(MySQLCommand.query.rawValue)
            payload.append(contentsOf: sql.utf8)
            stream.resetSequence()
            try stream.write(payload)
            let reader = MySQLResultReader(stream: stream, deprecateEOF: capabilities.contains(.deprecateEOF))
            return try reader.readAll(rowLimit: rowLimit) { status in updateStatus(status) }
        }
    }

    /// Interrupts the running statement with `KILL QUERY` from a second, short-lived connection.
    public func cancel() {
        stateLock.lock()
        let target = isExecuting ? connectionID : nil
        stateLock.unlock()
        guard let target else { return }
        var killerParameters = parameters
        killerParameters.config.database = ""
        // KILL QUERY needs none of the session settings, and a failing startup command must not block the cancel.
        killerParameters.config.startupCommands = nil
        killerParameters.config.queryTimeout = nil
        // Connecting can take a while on a remote server; never block the caller (usually the main thread).
        // Best effort: if the kill fails, the statement simply runs to completion.
        DispatchQueue.global(qos: .userInitiated).async {
            let killer = MySQLConnection(parameters: killerParameters)
            defer { killer.close() }
            guard (try? killer.connect()) != nil else { return }
            _ = try? killer.runQuery("KILL QUERY \(target)", rowLimit: nil)
        }
    }

    // MARK: - Databases

    public func useDatabase(_ name: String) throws {
        try withStream { stream in
            stream.resetSequence()
            try stream.write([MySQLCommand.initDB.rawValue] + Array(name.utf8))
            let packet = try stream.read()
            switch packet.first {
            case MySQLProtocol.okHeader:
                updateStatus(try MySQLOKPacket(payload: packet).statusFlags)
            case MySQLProtocol.errHeader:
                throw try MySQLErrorPacket(payload: packet).serverError
            default:
                throw DatabaseError.protocolViolation("Unexpected reply to COM_INIT_DB")
            }
        }
        currentDatabase = name
    }

    private func refreshCurrentDatabase() {
        guard stream != nil, let result = try? runQuery("SELECT DATABASE()", rowLimit: 1).first else { return }
        currentDatabase = Self.string(result.rows.first?.first)
    }

    /// Cell as text. Metadata never needs the hex rendering that `CellValue.textValue` gives bytes.
    static func string(_ value: CellValue?) -> String? {
        switch value {
        case .text(let string)?: return string
        case .bytes(let data)?: return String(decoding: data, as: UTF8.self)
        case .expression(let sql)?: return sql
        case .null?, .missing?, nil: return nil
        }
    }
}

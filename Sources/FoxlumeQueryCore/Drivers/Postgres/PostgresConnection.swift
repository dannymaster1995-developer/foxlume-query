import Foundation

/// PostgreSQL over the frontend/backend protocol 3.0: simple query protocol, text-format results.
public final class PostgresConnection: DatabaseConnection, TLSReporting {
    public var kind: DatabaseKind { parameters.config.kind }
    public private(set) var serverVersion: String = ""
    public private(set) var currentDatabase: String?
    public private(set) var defaultSchema: String?
    /// Transaction state from the last ReadyForQuery: `I` idle, `T` in a transaction block, `E` in a failed one.
    public private(set) var transactionStatus: Character = "I"
    /// NoticeResponse messages (warnings, INFO) received during the last `execute`.
    public private(set) var notices: [String] = []
    /// `server_version_num`, for example `180000`. Valid after `connect()`.
    public private(set) var serverVersionNumber: Int = 0
    public var isTLS: Bool { transport?.isTLS ?? false }
    public var tlsProtocolVersion: String? { transport?.tlsProtocolVersion }

    private let parameters: ConnectionParameters
    private var transport: SocketTransport?
    private var databaseName: String

    private struct BackendKey {
        var processID: Int32
        var secretKey: [UInt8]
    }

    /// Guards the state read from other threads by `cancel()` and `dialect`.
    private let stateLock = NSLock()
    private var backendKey: BackendKey?
    private var cancelRequested = false
    private var standardConformingStrings = true

    public init(parameters: ConnectionParameters) {
        self.parameters = parameters
        let config = parameters.config
        databaseName = config.database.isEmpty ? config.user : config.database
    }

    deinit { close() }

    /// With `standard_conforming_strings` off, backslashes in string literals are escapes and must be doubled.
    public var dialect: SQLDialect {
        stateLock.lock()
        defer { stateLock.unlock() }
        return standardConformingStrings ? .postgresql : SQLDialect(family: .postgresql, backslashEscapes: true)
    }

    // MARK: - Connection

    public func connect() throws {
        close()
        let timeout = TimeInterval(max(1, parameters.config.connectTimeout))
        let deadline = ConnectDeadline(timeout: timeout)
        let timedOut = DatabaseError.connection("Timed out after \(Int(timeout)) seconds waiting for PostgreSQL at \(parameters.config.host):\(parameters.config.port). Is this a PostgreSQL server?")
        do {
            let tls = try TLSContext.load(parameters)
            let transport = try openTransport(deadline: deadline, tls: tls)
            self.transport = transport
            let config = parameters.config
            let startup = PostgresFrontend.startup(parameters: [
                ("user", config.user),
                ("database", databaseName),
                ("application_name", "Foxlume Query"),
                ("client_encoding", "UTF8"),
                ("DateStyle", "ISO, MDY"),
            ])
            do {
                // The TLS handshake finishes before this first write, so certificate problems surface here; with
                // TLS 1.3 a refused client certificate shows up on the first read, inside `authenticate`.
                try transport.write(startup)
                try authenticate(transport)
            } catch {
                throw Self.explainCertificateError(transport.tlsHandshakeError(error, endpoint: config.host), tls: tls)
            }
            try readUntilReady(transport)
            try loadSessionInfo()
            if deadline.finish() { throw timedOut }
        } catch {
            let fired = deadline.finish()
            dropConnection()
            throw fired ? timedOut : error
        }
    }

    public func close() {
        guard let transport else { return }
        try? transport.write(PostgresFrontend.terminate())
        dropConnection()
    }

    public func abort() {
        transport?.interrupt()
    }

    /// Tear down without sending Terminate; afterwards every call throws `.notConnected`.
    private func dropConnection() {
        transport?.close()
        transport = nil
        stateLock.lock()
        backendKey = nil
        stateLock.unlock()
    }

    private func makeSocket(deadline: ConnectDeadline? = nil) throws -> SocketTransport {
        let config = parameters.config
        let transport = SocketTransport()
        try transport.connect(host: config.host, port: config.port, timeout: TimeInterval(config.connectTimeout))
        deadline?.watch(transport)
        return transport
    }

    /// TCP connect, then the SSLRequest exchange when the SSL mode asks for TLS.
    private func openTransport(deadline: ConnectDeadline, tls: TLSContext) throws -> SocketTransport {
        let sslMode = parameters.config.sslMode
        let transport = try makeSocket(deadline: deadline)
        guard sslMode.wantsTLS else { return transport }
        do {
            try transport.write(PostgresFrontend.sslRequest())
            let answer = try transport.readByte()
            switch answer {
            case UInt8(ascii: "S"):
                try transport.startTLS(tls.options(host: parameters.config.host))
                return transport
            case UInt8(ascii: "N"):
                guard !sslMode.requiresTLS else {
                    throw DatabaseError.connection("The server does not accept TLS connections, but the SSL mode requires TLS.")
                }
                return transport
            case UInt8(ascii: "E"):
                // Servers that cannot parse SSLRequest answer with an error and hang up. That text comes from an
                // unauthenticated peer (CVE-2024-10977), so it is not shown; retry in plaintext when allowed.
                transport.close()
                guard !sslMode.requiresTLS else {
                    throw DatabaseError.connection("The server rejected the TLS request, but the SSL mode requires TLS.")
                }
                return try makeSocket(deadline: deadline)
            default:
                throw DatabaseError.protocolViolation("Unexpected answer to the TLS request. Is this a PostgreSQL server?")
            }
        } catch {
            transport.close()
            throw error
        }
    }

    private func authenticate(_ transport: SocketTransport) throws {
        let config = parameters.config
        var scram: SCRAMSHA256Client?
        var scramVerified = false
        while true {
            let message = try transport.readPostgresMessage()
            switch message.type {
            case PostgresBackendType.authentication:
                var reader = ByteReader(message.payload)
                let request = try reader.int32BE()
                switch request {
                case PostgresAuthRequest.ok:
                    guard scram == nil || scramVerified else {
                        throw DatabaseError.authentication("The server skipped the SCRAM server verification step.")
                    }
                    return
                case PostgresAuthRequest.cleartextPassword:
                    try transport.write(PostgresFrontend.password(try requirePassword()))
                case PostgresAuthRequest.md5Password:
                    let salt = try reader.bytes(4)
                    let hashed = PostgresFrontend.md5Password(user: config.user, password: try requirePassword(), salt: salt)
                    try transport.write(PostgresFrontend.password(hashed))
                case PostgresAuthRequest.sasl:
                    var mechanisms: [String] = []
                    while !reader.isAtEnd {
                        let mechanism = try reader.cString()
                        if mechanism.isEmpty { break }
                        mechanisms.append(mechanism)
                    }
                    guard mechanisms.contains(SCRAMSHA256Client.mechanism) else {
                        if mechanisms.contains(SCRAMSHA256Client.channelBindingMechanism) {
                            throw DatabaseError.authentication("The server requires SCRAM-SHA-256-PLUS (channel binding), which Foxlume Query does not support.")
                        }
                        throw DatabaseError.authentication("The server offered unsupported SASL mechanisms: \(mechanisms.joined(separator: ", ")).")
                    }
                    let client = SCRAMSHA256Client(password: try requirePassword())
                    try transport.write(PostgresFrontend.saslInitialResponse(
                        mechanism: SCRAMSHA256Client.mechanism,
                        data: Array(client.clientFirstMessage.utf8)
                    ))
                    scram = client
                case PostgresAuthRequest.saslContinue:
                    guard var client = scram else {
                        throw DatabaseError.protocolViolation("SASLContinue without a SASL exchange")
                    }
                    let finalMessage = try client.clientFinalMessage(serverFirstMessage: String(decoding: reader.rest(), as: UTF8.self))
                    scram = client
                    try transport.write(PostgresFrontend.saslResponse(Array(finalMessage.utf8)))
                case PostgresAuthRequest.saslFinal:
                    guard let client = scram else {
                        throw DatabaseError.protocolViolation("SASLFinal without a SASL exchange")
                    }
                    try client.verifyServerFinal(String(decoding: reader.rest(), as: UTF8.self))
                    scramVerified = true
                case PostgresAuthRequest.kerberosV5:
                    throw DatabaseError.authentication("The server requested Kerberos V5 authentication, which Foxlume Query does not support.")
                case PostgresAuthRequest.gss, PostgresAuthRequest.gssContinue, PostgresAuthRequest.sspi:
                    throw DatabaseError.authentication("The server requested GSSAPI/SSPI authentication, which Foxlume Query does not support.")
                default:
                    throw DatabaseError.authentication("The server requested an unsupported authentication method (\(request)).")
                }
            case PostgresBackendType.errorResponse:
                throw Self.startupError(try PostgresServerError(payload: message.payload))
            case PostgresBackendType.noticeResponse:
                notices.append(try PostgresServerError(payload: message.payload).noticeText)
            case PostgresBackendType.negotiateProtocolVersion:
                continue
            default:
                throw DatabaseError.protocolViolation("Unexpected message '\(Character(Unicode.Scalar(message.type)))' during authentication")
            }
        }
    }

    private func requirePassword() throws -> String {
        guard !parameters.password.isEmpty else {
            throw DatabaseError.authentication("The server requires a password for user \"\(parameters.config.user)\", but none was given.")
        }
        return parameters.password
    }

    /// After AuthenticationOk the server reports parameters and the cancel key, then ReadyForQuery.
    private func readUntilReady(_ transport: SocketTransport) throws {
        while true {
            let message = try transport.readPostgresMessage()
            switch message.type {
            case PostgresBackendType.parameterStatus:
                try applyParameterStatus(message.payload)
            case PostgresBackendType.backendKeyData:
                var reader = ByteReader(message.payload)
                let processID = try reader.int32BE()
                let key = BackendKey(processID: processID, secretKey: reader.rest())
                stateLock.lock()
                backendKey = key
                stateLock.unlock()
            case PostgresBackendType.noticeResponse:
                notices.append(try PostgresServerError(payload: message.payload).noticeText)
            case PostgresBackendType.errorResponse:
                throw Self.startupError(try PostgresServerError(payload: message.payload))
            case PostgresBackendType.readyForQuery:
                transactionStatus = message.payload.first.map { Character(Unicode.Scalar($0)) } ?? "I"
                return
            default:
                continue
            }
        }
    }

    /// SQLSTATE class 28 is "invalid authorization specification": wrong password, no pg_hba entry, and so on.
    /// pg_hba `cert` (or `clientcert=…`) refusals, with what to change in the connection.
    static func explainCertificateError(_ error: Error, tls: TLSContext) -> Error {
        guard case DatabaseError.authentication(let message)? = error as? DatabaseError else { return error }
        if tls.identity == nil, message.contains("client certificate") {
            return DatabaseError.authentication("\(message). Choose a client certificate and key in the connection's SSL/TLS settings.")
        }
        if let identity = tls.identity, message.contains("certificate authentication failed") {
            return DatabaseError.authentication("\(message). The client certificate \"\(identity.subjectSummary)\" was accepted, but its common name (CN) must match the user name (or the server's pg_ident.conf map).")
        }
        return error
    }

    private static func startupError(_ error: PostgresServerError) -> DatabaseError {
        if error.code?.hasPrefix("28") == true {
            return .authentication(error.message)
        }
        var text = error.message
        if let detail = error.detailText { text += "\n" + detail }
        return .connection(text)
    }

    private func loadSessionInfo() throws {
        let row = try execute(
            "SELECT pg_catalog.current_database(), pg_catalog.current_schema(), pg_catalog.current_setting('server_version_num')",
            rowLimit: nil
        ).first?.rows.first
        currentDatabase = row?[0].textValue ?? databaseName
        defaultSchema = row?[1].textValue
        serverVersionNumber = row.flatMap { Int($0[2].textValue ?? "") } ?? 0
    }

    private func applyParameterStatus(_ payload: [UInt8]) throws {
        let (name, value) = try PostgresParser.parameterStatus(payload)
        switch name {
        case "server_version":
            // Distribution builds append details, for example `16.2 (Debian 16.2-1.pgdg120+2)`.
            serverVersion = value.split(separator: " ").first.map(String.init) ?? value
        case "standard_conforming_strings":
            stateLock.lock()
            standardConformingStrings = value == "on"
            stateLock.unlock()
        default:
            break
        }
    }

    // MARK: - Queries

    public func execute(_ sql: String, rowLimit: Int?) throws -> [StatementResult] {
        guard let transport else { throw DatabaseError.notConnected }
        guard !sql.utf8.contains(0) else {
            throw DatabaseError.unsupported("The query contains a NUL character, which PostgreSQL does not accept.")
        }
        stateLock.lock()
        cancelRequested = false
        stateLock.unlock()
        do {
            if let rowLimit, let statements = Self.boundableStatements(sql) {
                return try boundedQuery(statements, rowLimit: rowLimit, on: transport)
            }
            return try simpleQuery(sql, rowLimit: rowLimit, on: transport)
        } catch let error as DatabaseError {
            switch error {
            case .server, .cancelled, .unsupported:
                // Thrown only after ReadyForQuery (or for FATAL, after dropping), so the session is in sync.
                break
            case .connection, .authentication, .protocolViolation, .notConnected:
                dropConnection()
            }
            throw error
        } catch {
            dropConnection()
            throw error
        }
    }

    private func simpleQuery(_ sql: String, rowLimit: Int?, on transport: SocketTransport) throws -> [StatementResult] {
        notices = []
        var statementStart = Date()
        try transport.write(PostgresFrontend.query(sql))

        var results: [StatementResult] = []
        var columns: [ResultColumn] = []
        var rows: [[CellValue]] = []
        var truncated = false
        var serverError: PostgresServerError?
        var unsupportedCopy: String?

        while true {
            let message = try transport.readPostgresMessage()
            switch message.type {
            case PostgresBackendType.dataRow:
                if let rowLimit, rows.count >= rowLimit {
                    truncated = true
                    continue
                }
                rows.append(try PostgresParser.dataRow(message.payload))
            case PostgresBackendType.rowDescription:
                columns = try PostgresParser.rowDescription(message.payload).map(\.resultColumn)
                rows = []
                truncated = false
            case PostgresBackendType.commandComplete:
                let tag = try PostgresParser.commandTag(message.payload)
                results.append(StatementResult(
                    columns: columns,
                    rows: rows,
                    affectedRows: PostgresParser.affectedRows(commandTag: tag, hasResultSet: !columns.isEmpty),
                    message: tag,
                    truncated: truncated,
                    elapsed: Date().timeIntervalSince(statementStart)
                ))
                columns = []
                rows = []
                truncated = false
                statementStart = Date()
            case PostgresBackendType.emptyQueryResponse:
                statementStart = Date()
            case PostgresBackendType.errorResponse:
                let error = try PostgresServerError(payload: message.payload)
                if error.isFatal {
                    // The server closes the connection right after a FATAL error.
                    dropConnection()
                    throw error.databaseError
                }
                if serverError == nil { serverError = error }
            case PostgresBackendType.noticeResponse:
                notices.append(try PostgresServerError(payload: message.payload).noticeText)
            case PostgresBackendType.parameterStatus:
                try applyParameterStatus(message.payload)
            case PostgresBackendType.copyInResponse:
                unsupportedCopy = "COPY FROM STDIN is not supported. Use INSERT statements or a server-side COPY FROM 'file'."
                try transport.write(PostgresFrontend.copyFail("COPY FROM STDIN is not supported by Foxlume Query"))
            case PostgresBackendType.copyOutResponse:
                unsupportedCopy = "COPY TO STDOUT is not supported. Run the query as a SELECT instead."
            case PostgresBackendType.copyData, PostgresBackendType.copyDone:
                continue
            case PostgresBackendType.copyBothResponse:
                throw DatabaseError.protocolViolation("Streaming replication (CopyBoth) is not supported")
            case PostgresBackendType.readyForQuery:
                transactionStatus = message.payload.first.map { Character(Unicode.Scalar($0)) } ?? "I"
                if let unsupportedCopy {
                    throw DatabaseError.unsupported(unsupportedCopy)
                }
                if let serverError {
                    throw mapError(serverError)
                }
                return results
            default:
                // NotificationResponse and anything newer than protocol 3.0 that does not affect the result.
                continue
            }
        }
    }

    /// The statements of `sql` for the extended protocol, or nil to use a simple query instead (nothing to run, or
    /// COPY, which needs the copy sub-protocol).
    static func boundableStatements(_ sql: String) -> [String]? {
        let statements = SQLStatementSplitter.split(sql, family: .postgresql).map(\.text)
        guard !statements.isEmpty else { return nil }
        let runnable = statements.filter { !SQLStatementSplitter.strippingComments($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !runnable.isEmpty else { return nil }
        if runnable.contains(where: { SQLStatementSplitter.strippingComments($0).trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("COPY") }) {
            return nil
        }
        return runnable
    }

    /// Runs statements through the extended protocol so the server stops after `rowLimit + 1` rows of each result
    /// instead of sending all of it across the network to be thrown away. One Sync at the end keeps the statements in
    /// one implicit transaction, exactly as a multi-statement simple query would.
    private func boundedQuery(_ statements: [String], rowLimit: Int, on transport: SocketTransport) throws -> [StatementResult] {
        notices = []
        let maxRows = Int32(clamping: rowLimit + 1)
        var request: [UInt8] = []
        for statement in statements {
            request += PostgresFrontend.extendedStatement(statement, maxRows: maxRows)
        }
        request += PostgresFrontend.sync()
        try transport.write(request)

        var results: [StatementResult] = []
        var columns: [ResultColumn] = []
        var rows: [[CellValue]] = []
        var statementStart = Date()
        var serverError: PostgresServerError?
        var unsupportedCopy: String?

        func finish(tag: String?, truncated: Bool) {
            let shown = truncated ? Array(rows.prefix(rowLimit)) : rows
            results.append(StatementResult(
                columns: columns,
                rows: shown,
                affectedRows: tag.flatMap { PostgresParser.affectedRows(commandTag: $0, hasResultSet: !columns.isEmpty) },
                message: tag ?? "SELECT \(shown.count)",
                truncated: truncated || rows.count > rowLimit,
                elapsed: Date().timeIntervalSince(statementStart)
            ))
            columns = []
            rows = []
        }

        while true {
            let message = try transport.readPostgresMessage()
            switch message.type {
            case PostgresBackendType.parseComplete:
                statementStart = Date()
                columns = []
                rows = []
            case PostgresBackendType.bindComplete, PostgresBackendType.closeComplete, PostgresBackendType.noData:
                continue
            case PostgresBackendType.rowDescription:
                columns = try PostgresParser.rowDescription(message.payload).map(\.resultColumn)
            case PostgresBackendType.dataRow:
                rows.append(try PostgresParser.dataRow(message.payload))
            case PostgresBackendType.portalSuspended:
                finish(tag: nil, truncated: true)
            case PostgresBackendType.commandComplete:
                finish(tag: try PostgresParser.commandTag(message.payload), truncated: false)
            case PostgresBackendType.emptyQueryResponse:
                continue
            case PostgresBackendType.errorResponse:
                let error = try PostgresServerError(payload: message.payload)
                if error.isFatal {
                    dropConnection()
                    throw error.databaseError
                }
                if serverError == nil { serverError = error }
            case PostgresBackendType.noticeResponse:
                notices.append(try PostgresServerError(payload: message.payload).noticeText)
            case PostgresBackendType.parameterStatus:
                try applyParameterStatus(message.payload)
            case PostgresBackendType.copyInResponse:
                unsupportedCopy = "COPY FROM STDIN is not supported. Use INSERT statements or a server-side COPY FROM 'file'."
                try transport.write(PostgresFrontend.copyFail("COPY FROM STDIN is not supported by Foxlume Query"))
            case PostgresBackendType.copyOutResponse:
                unsupportedCopy = "COPY TO STDOUT is not supported. Run the query as a SELECT instead."
            case PostgresBackendType.copyData, PostgresBackendType.copyDone:
                continue
            case PostgresBackendType.copyBothResponse:
                throw DatabaseError.protocolViolation("Streaming replication (CopyBoth) is not supported")
            case PostgresBackendType.readyForQuery:
                transactionStatus = message.payload.first.map { Character(Unicode.Scalar($0)) } ?? "I"
                if let unsupportedCopy { throw DatabaseError.unsupported(unsupportedCopy) }
                if let serverError {
                    // The extended protocol reports `$1` placeholders as a Bind mismatch rather than a missing parameter.
                    if serverError.code == "08P01", serverError.message.contains("bind message supplies 0 parameters") {
                        throw DatabaseError.server(message: "The query uses parameter placeholders such as $1. Replace them with values to run it.", code: "42P02")
                    }
                    throw mapError(serverError)
                }
                return results
            default:
                continue
            }
        }
    }

    /// 57014 is query_canceled. It also covers statement_timeout, which keeps its server message.
    private func mapError(_ error: PostgresServerError) -> DatabaseError {
        guard error.code == "57014" else { return error.databaseError }
        stateLock.lock()
        let requested = cancelRequested
        stateLock.unlock()
        return requested ? .cancelled : error.databaseError
    }

    /// Ask the server, over a separate connection, to interrupt the running statement. Safe from any thread.
    public func cancel() {
        stateLock.lock()
        let key = backendKey
        if key != nil { cancelRequested = true }
        stateLock.unlock()
        guard let key else { return }

        let socket = SocketTransport()
        defer { socket.close() }
        do {
            let config = parameters.config
            try socket.connect(host: config.host, port: config.port, timeout: TimeInterval(config.connectTimeout))
            try socket.write(PostgresFrontend.cancelRequest(processID: key.processID, secretKey: key.secretKey))
        } catch {
            // Cancellation is best effort: when it cannot be delivered the statement simply runs to completion.
        }
    }

    // MARK: - Databases

    public func databases() throws -> [String] {
        try rows("SELECT datname FROM pg_catalog.pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname")
            .compactMap { $0.first?.textValue }
    }

    /// PostgreSQL binds a session to one database, so switching means reconnecting with the same credentials.
    public func useDatabase(_ name: String) throws {
        guard name != currentDatabase || transport == nil else { return }
        let previous = databaseName
        databaseName = name
        do {
            try connect()
        } catch {
            // Restore the previous database so a typo does not leave the session disconnected.
            databaseName = previous
            try? connect()
            throw error
        }
    }

    /// Rows of the first result of an internal query.
    func rows(_ sql: String) throws -> [[CellValue]] {
        try execute(sql, rowLimit: nil).first?.rows ?? []
    }
}

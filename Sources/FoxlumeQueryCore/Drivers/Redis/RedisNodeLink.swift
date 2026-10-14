import Foundation

/// `host:port` of one Redis server, sentinel or cluster node.
struct RedisEndpoint: Hashable, Sendable, CustomStringConvertible {
    var host: String
    var port: Int

    var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    /// `host:port`, `[v6]:port`, a bare v6 address followed by `:port` as `MOVED` prints it, or `host` alone.
    init?(parsing text: String, defaultPort: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.hasPrefix(":") {
                guard let value = Int(rest.dropFirst()) else { return nil }
                port = value
            } else {
                port = defaultPort
            }
            return
        }
        if let colon = trimmed.lastIndex(of: ":"), let value = Int(trimmed[trimmed.index(after: colon)...]) {
            host = String(trimmed[..<colon])
            port = value
        } else if trimmed.contains(":") {
            return nil
        } else {
            host = trimmed
            port = defaultPort
        }
        guard !host.isEmpty, (1...65535).contains(port) else { return nil }
    }

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Comma-, space- or newline-separated list as typed in the connection form.
    static func list(_ text: String?, defaultPort: Int) -> [RedisEndpoint] {
        guard let text else { return [] }
        return text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .compactMap { RedisEndpoint(parsing: String($0), defaultPort: defaultPort) }
    }
}

/// What `INFO server` (or the HELLO map) says about a server.
struct RedisServerInfo: Equatable {
    var version = ""
    /// `standalone`, `sentinel` or `cluster`; empty when the server did not say.
    var mode = ""
    /// `Valkey`, `KeyDB`, `Dragonfly` for forks that identify themselves.
    var flavor: String?

    var displayVersion: String {
        guard let flavor else { return version }
        return version.isEmpty ? flavor : "\(version) (\(flavor))"
    }

    /// Major version used for feature checks (SCAN TYPE, SET KEEPTTL). Forks report a compatible redis_version.
    var compatibleMajor = 0

    /// Parses `INFO server` text.
    init(info text: String) {
        let fields = RedisInfo.fields(text)
        let redisVersion = fields["redis_version"] ?? ""
        version = redisVersion
        mode = fields["redis_mode"] ?? fields["server_mode"] ?? ""
        compatibleMajor = Int(redisVersion.split(separator: ".").first ?? "") ?? 0
        if fields["server_name"]?.lowercased() == "valkey" || fields["valkey_version"] != nil {
            flavor = "Valkey"
            version = fields["valkey_version"] ?? redisVersion
        } else if let dragonfly = fields["dragonfly_version"] {
            flavor = "Dragonfly"
            version = dragonfly.hasPrefix("df-") ? String(dragonfly.dropFirst(3)) : dragonfly
        } else if fields.keys.contains(where: { $0.hasPrefix("keydb") }) || (fields["executable"]?.lowercased().contains("keydb") ?? false) {
            flavor = "KeyDB"
        }
    }

    init(hello: [String: RESPValue]) {
        version = hello["version"]?.string ?? ""
        mode = hello["mode"]?.string ?? ""
        compatibleMajor = Int(version.split(separator: ".").first ?? "") ?? 0
        if let server = hello["server"]?.string?.lowercased(), server != "redis" {
            flavor = server == "valkey" ? "Valkey" : server == "keydb" ? "KeyDB" : server.capitalized
        }
    }

    init() {}
}

/// `INFO` text: `# Section` headers followed by `key:value` lines.
enum RedisInfo {
    struct Entry: Equatable {
        var section: String
        var key: String
        var value: String
    }

    static func entries(_ text: String) -> [Entry] {
        var section = ""
        var result: [Entry] = []
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                section = line.dropFirst().trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            result.append(Entry(section: section, key: String(line[..<colon]), value: String(line[line.index(after: colon)...])))
        }
        return result
    }

    static func fields(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries(text) where result[entry.key] == nil {
            result[entry.key] = entry.value
        }
        return result
    }

    /// `INFO keyspace`: `db0:keys=12,expires=3,avg_ttl=0` → [0: 12].
    static func keyCounts(_ text: String) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for entry in entries(text) where entry.key.hasPrefix("db") {
            guard let index = Int(entry.key.dropFirst(2)) else { continue }
            for part in entry.value.split(separator: ",") where part.hasPrefix("keys=") {
                counts[index] = Int(part.dropFirst(5))
            }
        }
        return counts
    }
}

/// One connection to one Redis node: TCP (and TLS), then HELLO/AUTH. Replies come back as values;
/// a server error is a `.error` reply, not a thrown error, so callers can decide what it means.
final class RedisNodeLink {
    struct Options {
        var endpoint: RedisEndpoint
        /// ACL user; empty means the default user.
        var user = ""
        var password = ""
        var sslMode: SSLMode = .disable
        /// Certificates for TLS links; `sslMode` decides how strictly they are checked.
        var tls = TLSContext(mode: .disable)
        var timeout: TimeInterval = 10
        /// Try `HELLO 3` first. Tests turn it off to exercise RESP2.
        var preferRESP3 = true
        var clientName: String? = "FoxlumeQuery"
    }

    let endpoint: RedisEndpoint
    let transport: SocketTransport
    private let reader: RESPReader
    private(set) var protocolVersion = 2
    /// `CLIENT ID`, used by `cancel()` to unblock this connection from another one.
    private(set) var clientID: Int64?
    private(set) var hello: [String: RESPValue] = [:]
    /// Database selected on this connection, as far as the driver knows.
    var database = 0
    /// Set when a read or write failed: the stream position is unknown and the link must be replaced.
    private(set) var isBroken = false

    var isTLS: Bool { transport.isTLS }

    private init(endpoint: RedisEndpoint, transport: SocketTransport) {
        self.endpoint = endpoint
        self.transport = transport
        reader = RESPReader(channel: transport)
    }

    deinit { transport.close() }

    // MARK: - Opening

    /// Connects and authenticates. `sslMode` other than `disable` starts TLS right after the TCP connect.
    static func open(_ options: Options) throws -> RedisNodeLink {
        options.sslMode.wantsTLS ? try openTLS(options) : try openPlain(options, transport: nil)
    }

    private static func timedOut(_ options: Options) -> DatabaseError {
        .connection("Timed out after \(Int(options.timeout)) seconds waiting for Redis at \(options.endpoint). Is this a Redis server?")
    }

    /// Plaintext connection. `transport` is an already connected socket from the plaintext probe.
    private static func openPlain(_ options: Options, transport existing: SocketTransport?) throws -> RedisNodeLink {
        let transport: SocketTransport
        if let existing {
            transport = existing
        } else {
            transport = SocketTransport()
            try transport.connect(host: options.endpoint.host, port: options.endpoint.port, timeout: options.timeout)
        }
        // A peer that accepts TCP but never answers (a wrong port) would block the first read forever.
        let deadline = ConnectDeadline(timeout: options.timeout)
        deadline.watch(transport)
        let link = RedisNodeLink(endpoint: options.endpoint, transport: transport)
        do {
            try link.handshake(options)
        } catch {
            let fired = deadline.finish()
            transport.close()
            throw fired ? timedOut(options) : error
        }
        if deadline.finish() {
            transport.close()
            throw timedOut(options)
        }
        return link
    }

    /// TLS from the first byte, the way Redis serves it on its `tls-port`.
    ///
    /// A plaintext Redis never answers a TLS ClientHello: it waits for a newline that never comes. So while the
    /// handshake runs, a second socket sends a credential-free `PING`. A RESP answer proves the port is plaintext:
    /// the TLS attempt is abandoned at once, and `prefer` continues on the probe socket while `require` fails.
    private static func openTLS(_ options: Options) throws -> RedisNodeLink {
        let endpoint = options.endpoint
        let transport = SocketTransport()
        try transport.connect(host: endpoint.host, port: endpoint.port, timeout: options.timeout)
        let deadline = ConnectDeadline(timeout: options.timeout)
        deadline.watch(transport)
        let probe = RedisPlaintextProbe(endpoint: endpoint, timeout: options.timeout) { transport.interrupt() }
        do {
            try transport.startTLS(options.tls.options(host: endpoint.host, mode: options.sslMode))
            probe.start()
            let link = RedisNodeLink(endpoint: endpoint, transport: transport)
            // The TLS handshake runs on the first write, inside `handshake`.
            try link.handshake(options)
            if deadline.finish() { throw timedOut(options) }
            probe.cancel()
            return link
        } catch {
            let fired = deadline.finish()
            transport.close()
            // Authentication and server errors came over a working TLS session; never retry those in plaintext.
            guard Self.isTransportFailure(error) else {
                probe.cancel()
                throw error
            }
            switch probe.result() {
            case .plaintext(let plain, let greeting):
                guard !options.sslMode.requiresTLS else {
                    plain.close()
                    throw DatabaseError.connection("\(endpoint) does not use TLS, but the SSL mode \"\(options.sslMode.displayName)\" requires it. Use the server's tls-port or set SSL to Disabled.")
                }
                if let greeting, greeting.hasPrefix("DENIED") {
                    plain.close()
                    throw DatabaseError.connection(greeting)
                }
                return try openPlain(options, transport: plain)
            case .notPlaintext, .notStarted:
                if fired { throw DatabaseError.connection("Timed out after \(Int(options.timeout)) seconds waiting for the TLS handshake with \(endpoint).") }
                throw tlsFailure(transport.tlsHandshakeError(error, endpoint: "\(endpoint)"), options: options)
            }
        }
    }

    static func isTransportFailure(_ error: Error) -> Bool {
        guard let error = error as? DatabaseError else { return false }
        switch error {
        case .connection, .protocolViolation, .notConnected: return true
        default: return false
        }
    }

    private static func tlsFailure(_ error: Error, options: Options) -> DatabaseError {
        var reason = (error as? DatabaseError)?.errorDescription ?? error.localizedDescription
        // Already explained by the transport: a certificate or client certificate problem.
        if reason.hasPrefix("TLS handshake with \(options.endpoint) failed: ") { return .connection(reason) }
        let generic = "TLS handshake with \(options.endpoint) failed. "
        if reason.hasPrefix(generic) { reason.removeFirst(generic.count) }
        guard options.sslMode.verifiesCertificate else {
            return .connection("TLS handshake with \(options.endpoint) failed. \(reason)")
        }
        return .connection("""
            TLS handshake with \(options.endpoint) failed: the server certificate could not be verified. \
            It must be signed by a trusted authority and match the host name; use SSL mode \
            "\(SSLMode.require.displayName)" to encrypt without verifying. \(reason)
            """)
    }

    /// `HELLO 3 [AUTH user pass] [SETNAME name]`; servers before 6.0 or without RESP3 get `AUTH` and RESP2.
    private func handshake(_ options: Options) throws {
        let user = options.user.isEmpty ? "default" : options.user
        let sendsAuth = !options.password.isEmpty || !options.user.isEmpty
        if options.preferRESP3 {
            var arguments = ["HELLO", "3"]
            if sendsAuth { arguments += ["AUTH", user, options.password] }
            if let name = options.clientName { arguments += ["SETNAME", name] }
            let reply = try roundTrip(arguments)
            switch reply {
            case .map, .array:
                protocolVersion = 3
                hello = reply.dictionary
                clientID = hello["id"]?.integer
                return
            case .error(let message):
                if Self.isAuthenticationFailure(message) { throw Self.authenticationError(message) }
                if message.hasPrefix("DENIED") || message.hasPrefix("LOADING") { throw DatabaseError.connection(message) }
                // Unknown command (before 6.0) or NOPROTO: fall through to RESP2.
            default:
                throw DatabaseError.protocolViolation("Unexpected reply to HELLO. Is this a Redis server?")
            }
        }
        protocolVersion = 2
        var replies: [RESPValue] = []
        var commands: [[Data]] = []
        if sendsAuth {
            commands.append(Self.data(options.user.isEmpty ? ["AUTH", options.password] : ["AUTH", options.user, options.password]))
        }
        commands.append(Self.data(["CLIENT", "ID"]))
        if let name = options.clientName { commands.append(Self.data(["CLIENT", "SETNAME", name])) }
        replies = try pipeline(commands)
        if sendsAuth, case .error(let message) = replies[0], !Self.isPasswordNotNeeded(message) {
            if message.hasPrefix("DENIED") || message.hasPrefix("LOADING") { throw DatabaseError.connection(message) }
            throw Self.authenticationError(message)
        }
        if let idReply = replies.dropFirst(sendsAuth ? 1 : 0).first {
            if case .error(let message) = idReply, message.hasPrefix("NOAUTH") {
                throw Self.authenticationError(message)
            }
            clientID = idReply.integer
        }
    }

    static func isAuthenticationFailure(_ message: String) -> Bool {
        let code = message.split(separator: " ").first.map(String.init) ?? ""
        if ["WRONGPASS", "NOAUTH", "NOPERM"].contains(code) { return true }
        let lower = message.lowercased()
        return lower.contains("invalid password") || lower.contains("invalid username-password")
    }

    /// A password was given but the server has none: Redis 5 says "no password is set", Redis 6+ says
    /// "called without any password configured". The connection works, so carry on.
    static func isPasswordNotNeeded(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("no password is set") || lower.contains("without any password configured")
    }

    static func authenticationError(_ message: String) -> DatabaseError {
        if message.hasPrefix("NOAUTH") {
            return .authentication("The Redis server requires a password. (\(message))")
        }
        return .authentication(message)
    }

    // MARK: - Commands

    /// Sends one command and reads its reply.
    func call(_ arguments: [Data]) throws -> RESPValue {
        try pipeline([arguments])[0]
    }

    func call(_ arguments: [String]) throws -> RESPValue {
        try call(Self.data(arguments))
    }

    /// Writes every command in one go and reads the replies in order.
    func pipeline(_ commands: [[Data]]) throws -> [RESPValue] {
        guard !isBroken, transport.isOpen else { throw DatabaseError.notConnected }
        guard !commands.isEmpty else { return [] }
        do {
            var bytes: [UInt8] = []
            for command in commands { bytes += RESPEncoder.command(command) }
            try transport.write(bytes)
            var replies: [RESPValue] = []
            replies.reserveCapacity(commands.count)
            for _ in commands { replies.append(try reader.readReply()) }
            return replies
        } catch {
            isBroken = true
            transport.close()
            throw error
        }
    }

    private func roundTrip(_ arguments: [String]) throws -> RESPValue {
        try call(Self.data(arguments))
    }

    /// `INFO server` parsed, falling back to the HELLO map when ACLs deny INFO.
    func serverInfo() throws -> RedisServerInfo {
        let reply = try call(["INFO", "server"])
        if let text = reply.string, !reply.isError {
            var info = RedisServerInfo(info: text)
            if info.mode.isEmpty, let mode = hello["mode"]?.string { info.mode = mode }
            return info
        }
        return RedisServerInfo(hello: hello)
    }

    /// Wakes a read blocked on another thread. The link is unusable afterwards.
    func interrupt() {
        transport.interrupt()
    }

    func close() {
        transport.close()
    }

    static func data(_ arguments: [String]) -> [Data] {
        arguments.map { Data($0.utf8) }
    }
}

/// Sends `PING` in plaintext on a separate socket to learn whether a port speaks plain RESP.
/// The probe carries no credentials, so it is harmless against a TLS port, which just drops it.
final class RedisPlaintextProbe: @unchecked Sendable {
    enum Outcome {
        case notStarted
        /// The port answered in RESP. The socket is open with the PING reply consumed; `greeting` is an error reply's text.
        case plaintext(SocketTransport, greeting: String?)
        case notPlaintext
    }

    private let endpoint: RedisEndpoint
    private let timeout: TimeInterval
    private let onPlaintext: () -> Void
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var started = false
    private var cancelled = false
    private var outcome: Outcome = .notStarted
    private var transport: SocketTransport?

    init(endpoint: RedisEndpoint, timeout: TimeInterval, onPlaintext: @escaping () -> Void) {
        self.endpoint = endpoint
        self.timeout = timeout
        self.onPlaintext = onPlaintext
    }

    func start() {
        lock.lock()
        started = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { self.run() }
    }

    private func run() {
        let socket = SocketTransport()
        lock.lock()
        transport = socket
        let skip = cancelled
        lock.unlock()
        var result = Outcome.notPlaintext
        if !skip {
            let deadline = ConnectDeadline(timeout: timeout)
            do {
                try socket.connect(host: endpoint.host, port: endpoint.port, timeout: timeout)
                deadline.watch(socket)
                try socket.write(Array("PING\r\n".utf8))
                let reply = try RESPReader(channel: socket).read()
                if !deadline.finish() {
                    switch reply {
                    case .simple: result = .plaintext(socket, greeting: nil)
                    case .error(let message): result = .plaintext(socket, greeting: message)
                    default: break
                    }
                }
            } catch {}
            deadline.finish()
        }
        lock.lock()
        if cancelled, case .plaintext = result { result = .notPlaintext }
        if case .notPlaintext = result { socket.close() }
        outcome = result
        let notify = !cancelled
        lock.unlock()
        if notify, case .plaintext = result { onPlaintext() }
        finished.signal()
    }

    /// Waits for the probe; it ends within its own timeout.
    func result() -> Outcome {
        lock.lock()
        let wasStarted = started
        lock.unlock()
        guard wasStarted else { return .notStarted }
        finished.wait()
        finished.signal()
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }

    /// The TLS attempt won or failed for good: stop the probe and drop its socket.
    func cancel() {
        lock.lock()
        cancelled = true
        let socket = transport
        if case .plaintext(let open, _) = outcome {
            open.close()
            outcome = .notPlaintext
        }
        lock.unlock()
        socket?.interrupt()
    }
}

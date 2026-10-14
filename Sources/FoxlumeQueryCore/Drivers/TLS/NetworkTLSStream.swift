import Darwin
import Foundation
import Network
import Security

/// TLS 1.2/1.3 through Network.framework on a TCP socket that is already open and may have carried plaintext.
///
/// Network.framework cannot adopt an existing socket or add TLS to a running connection, yet PostgreSQL and MySQL
/// negotiate TLS after a plaintext exchange. So the TLS connection is made to a private Unix socket, and a relay copies
/// its bytes to and from the TCP socket. The TLS session still runs end to end with the server: the relay only moves
/// ciphertext. The socket file lives in a fresh 0700 folder under the temporary directory and is deleted as soon as
/// the one expected connection is accepted.
final class NetworkTLSStream: @unchecked Sendable {
    private enum State {
        case connecting
        case ready
        case failed(Error)
        case cancelled
    }

    /// Written by the verify block on Network.framework's queue, read by the connecting thread.
    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: TLSFailure?
        var value: TLSFailure? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private let connection: NWConnection
    private let relay: SocketRelay
    private let queue = DispatchQueue(label: "com.foxlume.query.tls")
    private let condition = NSCondition()
    private var state = State.connecting
    private let verificationFailure = FailureBox()
    private let lastFailure = FailureBox()
    private let options: TLSClientOptions

    /// TLS version agreed with the server, for example "TLS 1.3". Nil until the handshake is done.
    private(set) var protocolVersion: String?

    /// Takes over `socket`: from here on the relay owns it and closes it.
    init(socket: Int32, options: TLSClientOptions, timeout: TimeInterval = 10) throws {
        self.options = options
        relay = SocketRelay(remote: socket)
        let rendezvous: UnixRendezvous
        do {
            rendezvous = try UnixRendezvous()
        } catch {
            Darwin.close(socket)
            throw error
        }
        defer { rendezvous.remove() }

        // Everything is configured before the parameters and the connection are created from it.
        let tls = NWProtocolTLS.Options()
        let securityOptions = tls.securityProtocolOptions
        if CertificateNames.ipBytes(options.serverName) == nil, !options.serverName.isEmpty {
            sec_protocol_options_set_tls_server_name(securityOptions, options.serverName)
        }
        if let identity = options.identity {
            let created = identity.chain.isEmpty
                ? sec_identity_create(identity.identity)
                : sec_identity_create_with_certificates(identity.identity, identity.chain as CFArray)
            if let created { sec_protocol_options_set_local_identity(securityOptions, created) }
        }
        let verification = options.verification
        let host = options.serverName
        let failureBox = verificationFailure
        sec_protocol_options_set_verify_block(securityOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            if let failure = verification.evaluate(secTrust, host: host) {
                failureBox.value = failure
                complete(false)
            } else {
                complete(true)
            }
        }, queue)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        connection = NWConnection(to: .unix(path: rendezvous.path), using: parameters)
        connection.stateUpdateHandler = { [weak self] state in self?.update(state) }
        connection.start(queue: queue)

        let accepted: Int32
        do {
            accepted = try rendezvous.accept(timeout: timeout)
        } catch {
            connection.cancel()
            Darwin.close(socket)
            throw error
        }
        relay.start(local: accepted)
    }

    deinit {
        connection.cancel()
        relay.shutdown()
    }

    private func update(_ newState: NWConnection.State) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        switch (state, newState) {
        case (.connecting, .ready):
            state = .ready
            if let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                protocolVersion = Self.versionName(sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata))
            }
        case (.connecting, .failed(let error)), (.connecting, .waiting(let error)),
             (.ready, .failed(let error)), (.ready, .waiting(let error)):
            // A failed connection keeps pending sends and receives waiting until it is cancelled; `.waiting`
            // would retry forever. Either way the stream is done: remember why, then cancel to release them.
            state = .failed(error)
            connection.cancel()
        case (.connecting, .cancelled), (.ready, .cancelled):
            state = .cancelled
        default:
            break
        }
    }

    /// The error that ended the connection, when it failed (as opposed to being closed by us).
    private var terminalError: Error? {
        condition.lock()
        defer { condition.unlock() }
        if case .failed(let error) = state { return error }
        return nil
    }

    /// The classified reason of the last TLS failure: our verification result, or what the server's alert means.
    var failure: TLSFailure? { verificationFailure.value ?? lastFailure.value }

    private func waitUntilReady() throws {
        condition.lock()
        while case .connecting = state {
            condition.wait()
        }
        let current = state
        condition.unlock()
        switch current {
        case .ready, .connecting:
            return
        case .failed(let error):
            throw describe(error)
        case .cancelled:
            throw DatabaseError.connection("The connection was closed during the TLS handshake.")
        }
    }

    // MARK: - I/O

    func write(_ bytes: [UInt8]) throws {
        try waitUntilReady()
        let done = DispatchSemaphore(value: 0)
        var sendError: NWError?
        connection.send(content: Data(bytes), completion: .contentProcessed { error in
            sendError = error
            done.signal()
        })
        done.wait()
        if let sendError { throw describe(sendError) }
    }

    /// At least one byte, or an empty array at the end of the stream.
    func read(maxLength: Int) throws -> [UInt8] {
        try waitUntilReady()
        let done = DispatchSemaphore(value: 0)
        var result: Result<[UInt8], NWError> = .success([])
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, _, error in
            if let data, !data.isEmpty {
                result = .success([UInt8](data))
            } else if let error {
                result = .failure(error)
            }
            done.signal()
        }
        done.wait()
        switch result {
        case .success(let bytes): return bytes
        case .failure(let error): throw describe(error)
        }
    }

    /// Wakes a blocked read or write from another thread.
    func interrupt() {
        relay.shutdown()
        connection.cancel()
    }

    func close() {
        connection.cancel()
        relay.shutdown()
    }

    // MARK: - Errors

    private func describe(_ error: Error) -> DatabaseError {
        // Once the connection failed, pending operations end with "cancelled"; the failure itself says more.
        let error = terminalError ?? error
        if let failure = verificationFailure.value ?? classify(error) {
            lastFailure.value = failure
            return .connection("TLS error: \(failure.message)")
        }
        if case .posix(let code) = error as? NWError {
            switch code {
            case .ECONNRESET, .EPIPE, .ENOTCONN, .ECONNABORTED, .ECANCELED:
                return .connection("The connection to the server was lost (\(String(cString: strerror(code.rawValue)).lowercased())).")
            case .ETIMEDOUT:
                return .connection("The connection to the server timed out.")
            default:
                break
            }
        }
        return .connection(error.localizedDescription)
    }

    /// Server alerts and handshake errors in plain words. Nil for errors that are not about TLS.
    private func classify(_ error: Error) -> TLSFailure? {
        guard case .tls(let status) = error as? NWError else { return nil }
        let alert = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        let certificateAlerts: Set<OSStatus> = [
            errSSLPeerBadCert, errSSLPeerUnsupportedCert, errSSLPeerCertRevoked, errSSLPeerCertExpired,
            errSSLPeerCertUnknown, errSSLPeerUnknownCA, errSSLPeerAccessDenied, errSSLPeerDecryptError,
        ]
        if let identity = options.identity, certificateAlerts.contains(status) {
            return TLSFailure(.clientCertificateRejected, """
                The server rejected the client certificate "\(identity.subjectSummary)" (\(alert)). \
                It must be issued by a CA the server trusts and still be valid.
                """)
        }
        if options.identity == nil, status == errSSLCertificateRequired || certificateAlerts.contains(status) {
            return TLSFailure(.clientCertificateRequired, "The server requires a client certificate (\(alert)). Choose one in the connection's SSL/TLS settings.")
        }
        switch status {
        case errSSLPeerProtocolVersion, errSSLProtocol, errSSLPeerInsufficientSecurity, errSSLNegotiation:
            return TLSFailure(.handshake, "The server and this Mac have no TLS version or cipher in common (\(alert)).")
        case errSSLClosedAbort, errSSLClosedNoNotify, errSSLRecordOverflow, errSSLPeerDecodeError, errSSLPeerUnexpectedMsg:
            return TLSFailure(.handshake, "The server did not complete the TLS handshake (\(alert)). Is TLS enabled on the server and port?")
        case errSSLPeerHandshakeFail:
            let hint = options.identity == nil ? " If the server requires a client certificate, choose one in the connection's SSL/TLS settings." : ""
            return TLSFailure(.handshake, "The server refused the TLS handshake (\(alert)).\(hint)")
        default:
            return TLSFailure(.handshake, "\(alert) (\(status)).")
        }
    }

    private static func versionName(_ version: tls_protocol_version_t) -> String {
        switch version {
        case .TLSv13: return "TLS 1.3"
        case .TLSv12: return "TLS 1.2"
        case .TLSv11: return "TLS 1.1"
        case .TLSv10: return "TLS 1.0"
        default: return "TLS"
        }
    }
}

// MARK: - Unix socket rendezvous

/// A listening Unix socket in a private folder, used once and deleted.
private final class UnixRendezvous {
    let path: String
    private let directory: String
    private var listener: Int32

    init() throws {
        var lastError = "no temporary folder"
        for base in Self.candidateFolders() {
            var template = Array((base as NSString).appendingPathComponent("fqtls.XXXXXX").utf8CString)
            guard let created = mkdtemp(&template) else {
                lastError = String(cString: strerror(errno))
                continue
            }
            let folder = String(cString: created)
            let socketPath = (folder as NSString).appendingPathComponent("s")
            var address = sockaddr_un()
            guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
                rmdir(folder)
                lastError = "the temporary folder path is too long for a socket"
                continue
            }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                rmdir(folder)
                throw DatabaseError.connection("Cannot start TLS: \(String(cString: strerror(errno)))")
            }
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: socketPath.utf8)
                buffer[socketPath.utf8.count] = 0
            }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(fd, 1) == 0 else {
                lastError = String(cString: strerror(errno))
                Darwin.close(fd)
                unlink(socketPath)
                rmdir(folder)
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            path = socketPath
            directory = folder
            listener = fd
            return
        }
        throw DatabaseError.connection("Cannot start TLS: \(lastError)")
    }

    /// The app's temporary folder, then the per-user one from confstr, which is always short.
    private static func candidateFolders() -> [String] {
        var folders = [NSTemporaryDirectory()]
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            folders.append(String(cString: buffer))
        }
        return folders
    }

    func accept(timeout: TimeInterval) throws -> Int32 {
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32(max(1, timeout) * 1000))
        guard ready > 0 else {
            throw DatabaseError.connection("Cannot start TLS: the local TLS channel did not connect.")
        }
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else {
            throw DatabaseError.connection("Cannot start TLS: \(String(cString: strerror(errno)))")
        }
        // Only a process of this user could reach the 0700 folder; check anyway.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
            Darwin.close(fd)
            throw DatabaseError.connection("Cannot start TLS: unexpected peer on the local TLS channel.")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) & ~O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        remove()
        return fd
    }

    func remove() {
        if listener >= 0 {
            Darwin.close(listener)
            listener = -1
            unlink(path)
            rmdir(directory)
        }
    }
}

// MARK: - Relay

/// Copies bytes both ways between the TLS side (a Unix socket) and the server (the TCP socket), one thread per
/// direction so neither side can stall the other. The last thread to finish closes both sockets.
private final class SocketRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let remote: Int32
    private var local: Int32 = -1
    private var running = 0
    private var closed = false

    init(remote: Int32) {
        self.remote = remote
    }

    func start(local: Int32) {
        lock.lock()
        self.local = local
        running = 2
        lock.unlock()
        spawn(from: remote, to: local, name: "server to TLS")
        spawn(from: local, to: remote, name: "TLS to server")
    }

    private func spawn(from source: Int32, to destination: Int32, name: String) {
        let thread = Thread { [self] in
            pump(from: source, to: destination)
            finish()
        }
        thread.name = "Foxlume TLS relay (\(name))"
        thread.stackSize = 256 * 1024
        thread.start()
    }

    private func pump(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            var written = 0
            while written < count {
                let n = buffer.withUnsafeBytes { Darwin.write(destination, $0.baseAddress! + written, count - written) }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return closeBoth() }
                written += n
            }
        }
        // End of stream from `source`: pass the half-close on, so the other side sees it too.
        lock.lock()
        if !closed { Darwin.shutdown(destination, SHUT_WR) }
        lock.unlock()
    }

    private func closeBoth() {
        shutdown()
    }

    private func finish() {
        lock.lock()
        defer { lock.unlock() }
        running -= 1
        guard running == 0 else { return }
        closed = true
        Darwin.close(remote)
        Darwin.close(local)
    }

    /// Ends both directions; the pumps then close the sockets. Safe from any thread, any number of times.
    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard running > 0, !closed else { return }
        Darwin.shutdown(remote, SHUT_RDWR)
        Darwin.shutdown(local, SHUT_RDWR)
    }
}

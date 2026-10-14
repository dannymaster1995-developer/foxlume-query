import Darwin
import Foundation

/// A blocking TCP stream that can upgrade to TLS in place.
///
/// PostgreSQL and MySQL both negotiate TLS after a plaintext exchange (STARTTLS style). The plaintext part runs on a
/// plain BSD socket; `startTLS` hands that socket to `NetworkTLSStream`, which runs TLS 1.2/1.3 through
/// Network.framework (custom CA, host name checks, client certificates) without reconnecting.
public final class SocketTransport {
    private var socketHandle: Int32 = -1
    private var tls: NetworkTLSStream?
    private var buffer = [UInt8]()
    private var bufferStart = 0
    private var scratch = [UInt8](repeating: 0, count: 64 * 1024)
    private let closeLock = NSLock()
    private var connectTimeout: TimeInterval = 10

    public private(set) var isTLS = false
    public private(set) var isOpen = false

    public init() {}

    deinit { close() }

    /// The TLS version agreed with the server ("TLS 1.3"), once the handshake has run.
    public var tlsProtocolVersion: String? { tls?.protocolVersion }

    /// Why the TLS handshake or session failed, in plain words, when it was a TLS problem.
    public var tlsFailure: TLSFailure? { tls?.failure }

    public func connect(host: String, port: Int, timeout: TimeInterval) throws {
        connectTimeout = timeout
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_flags = AI_ADDRCONFIG
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else {
            let reason = status == 0 ? "no address" : String(cString: gai_strerror(status))
            throw DatabaseError.connection("Cannot resolve host \"\(host)\": \(reason)")
        }
        defer { freeaddrinfo(first) }

        var lastError = "connection failed"
        var connected: Int32 = -1
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let info = candidate {
            candidate = info.pointee.ai_next
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else {
                lastError = String(cString: strerror(errno))
                continue
            }
            if let error = Self.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen, timeout: timeout) {
                lastError = error
                Darwin.close(fd)
                continue
            }
            connected = fd
            break
        }
        guard connected >= 0 else {
            throw DatabaseError.connection("Cannot connect to \(host):\(port): \(lastError)")
        }

        var on: Int32 = 1
        setsockopt(connected, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(connected, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(connected, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
        closeLock.lock()
        socketHandle = connected
        isOpen = true
        closeLock.unlock()
    }

    /// Non-blocking connect with a deadline, then back to blocking mode.
    private static func connect(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ length: socklen_t, timeout: TimeInterval) -> String? {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }

        if Darwin.connect(fd, address, length) == 0 { return nil }
        guard errno == EINPROGRESS else { return String(cString: strerror(errno)) }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(max(1, timeout) * 1000)
        let ready = poll(&descriptor, 1, milliseconds)
        if ready == 0 { return "timed out after \(Int(timeout)) seconds" }
        if ready < 0 { return String(cString: strerror(errno)) }

        var socketError: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size)
        return socketError == 0 ? nil : String(cString: strerror(socketError))
    }

    /// Upgrade the open stream to TLS. The handshake runs right away; its outcome surfaces on the next read or
    /// write, so a certificate problem is reported before any data is sent.
    public func startTLS(_ options: TLSClientOptions) throws {
        guard availableBuffered == 0 else {
            throw DatabaseError.protocolViolation("Plaintext bytes received before the TLS handshake")
        }
        closeLock.lock()
        guard isOpen, socketHandle >= 0, tls == nil else {
            closeLock.unlock()
            throw DatabaseError.notConnected
        }
        let fd = socketHandle
        // The TLS stream owns the socket from here on, even when it fails to start.
        socketHandle = -1
        closeLock.unlock()
        let stream: NetworkTLSStream
        do {
            stream = try NetworkTLSStream(socket: fd, options: options, timeout: max(5, connectTimeout))
        } catch {
            closeLock.lock()
            isOpen = false
            closeLock.unlock()
            throw error
        }
        closeLock.lock()
        tls = stream
        isTLS = true
        let stillOpen = isOpen
        closeLock.unlock()
        if !stillOpen { stream.close() }
    }

    /// TLS without custom certificates: verify against the system roots and the host name, or not at all.
    public func startTLS(host: String, verifyCertificate: Bool) throws {
        let verification = TLSVerification(level: verifyCertificate ? .chainAndHostname : .none)
        try startTLS(TLSClientOptions(serverName: host, verification: verification))
    }

    private var availableBuffered: Int { buffer.count - bufferStart }

    public func write(_ data: Data) throws {
        try write([UInt8](data))
    }

    public func write(_ bytes: [UInt8]) throws {
        guard isOpen else { throw DatabaseError.notConnected }
        if let tls {
            try tls.write(bytes)
            return
        }
        let fd = socketHandle
        guard fd >= 0 else { throw DatabaseError.notConnected }
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + written, bytes.count - written, 0) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 {
                throw DatabaseError.connection(Self.posixErrorText(n < 0 ? errno : EPIPE, fallback: "Connection closed while writing"))
            }
            written += n
        }
    }

    /// Read exactly `count` bytes, blocking until they arrive.
    public func read(exactly count: Int) throws -> [UInt8] {
        while availableBuffered < count {
            try fill()
        }
        let slice = Array(buffer[bufferStart..<(bufferStart + count)])
        bufferStart += count
        if bufferStart == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            bufferStart = 0
        } else if bufferStart > 256 * 1024 {
            buffer.removeFirst(bufferStart)
            bufferStart = 0
        }
        return slice
    }

    /// Read a single byte. Used for one-byte replies such as the PostgreSQL SSL answer.
    public func readByte() throws -> UInt8 {
        try read(exactly: 1)[0]
    }

    private func fill() throws {
        guard isOpen else { throw DatabaseError.notConnected }
        if let tls {
            let bytes = try tls.read(maxLength: scratch.count)
            if bytes.isEmpty { throw DatabaseError.connection("The server closed the connection") }
            buffer.append(contentsOf: bytes)
            return
        }
        let fd = socketHandle
        guard fd >= 0 else { throw DatabaseError.notConnected }
        var n: Int
        repeat {
            n = scratch.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
        } while n < 0 && errno == EINTR
        if n < 0 {
            throw DatabaseError.connection(Self.posixErrorText(errno, fallback: "Connection error while reading"))
        }
        if n == 0 {
            throw DatabaseError.connection("The server closed the connection")
        }
        buffer.append(contentsOf: scratch[0..<n])
    }

    private static func posixErrorText(_ code: Int32, fallback: String) -> String {
        switch code {
        case EPIPE, ECONNRESET, ENOTCONN, ECONNABORTED:
            return "The connection to the server was lost (\(String(cString: strerror(code)).lowercased()))."
        case ETIMEDOUT:
            return "The connection to the server timed out."
        case 0:
            return fallback
        default:
            return "\(fallback): \(String(cString: strerror(code)))"
        }
    }

    /// Wake a read or write blocked on another thread. The owner still calls `close()` afterwards.
    /// The lock keeps the descriptor from being closed and reused while it is shut down.
    public func interrupt() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard isOpen else { return }
        if let tls {
            tls.interrupt()
        } else if socketHandle >= 0 {
            shutdown(socketHandle, SHUT_RDWR)
        }
    }

    /// Close the socket. Safe to call more than once. Use `interrupt()` to abort a read from another thread.
    public func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard isOpen else { return }
        isOpen = false
        if let tls {
            tls.close()
        } else if socketHandle >= 0 {
            shutdown(socketHandle, SHUT_RDWR)
            Darwin.close(socketHandle)
        }
        socketHandle = -1
    }
}

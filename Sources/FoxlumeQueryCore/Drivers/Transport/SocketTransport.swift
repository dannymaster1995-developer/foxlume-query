import Darwin
import Foundation

/// A blocking TCP stream that can upgrade to TLS in place.
///
/// PostgreSQL and MySQL both negotiate TLS after a plaintext exchange (STARTTLS style),
/// which Network.framework cannot do on an open connection. CFStream can: setting
/// `kCFStreamPropertySSLSettings` on an open socket stream starts the handshake.
public final class SocketTransport {
    private var socketHandle: Int32 = -1
    private var input: InputStream?
    private var output: OutputStream?
    private var buffer = [UInt8]()
    private var bufferStart = 0
    private var scratch = [UInt8](repeating: 0, count: 64 * 1024)
    private let closeLock = NSLock()

    public private(set) var isTLS = false
    public private(set) var isOpen = false

    public init() {}

    deinit { close() }

    public func connect(host: String, port: Int, timeout: TimeInterval) throws {
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
            socketHandle = fd
            break
        }
        guard socketHandle >= 0 else {
            throw DatabaseError.connection("Cannot connect to \(host):\(port): \(lastError)")
        }

        var on: Int32 = 1
        setsockopt(socketHandle, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socketHandle, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socketHandle, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))

        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(kCFAllocatorDefault, socketHandle, &readStream, &writeStream)
        guard let readStream, let writeStream else {
            Darwin.close(socketHandle)
            socketHandle = -1
            throw DatabaseError.connection("Cannot create socket streams")
        }
        let input = readStream.takeRetainedValue() as InputStream
        let output = writeStream.takeRetainedValue() as OutputStream
        input.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
        output.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
        input.open()
        output.open()
        self.input = input
        self.output = output
        isOpen = true
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

    /// Upgrade the open stream to TLS. The handshake runs on the next read or write.
    public func startTLS(host: String, verifyCertificate: Bool) throws {
        guard let input, let output else { throw DatabaseError.notConnected }
        guard availableBuffered == 0 else {
            throw DatabaseError.protocolViolation("Plaintext bytes received before the TLS handshake")
        }
        var settings: [String: Any] = [
            kCFStreamSSLValidatesCertificateChain as String: verifyCertificate,
        ]
        if verifyCertificate || !Self.isIPAddress(host) {
            settings[kCFStreamSSLPeerName as String] = verifyCertificate ? host : NSNull()
        }
        let key = Stream.PropertyKey(kCFStreamPropertySSLSettings as String)
        guard input.setProperty(settings as NSDictionary, forKey: key),
              output.setProperty(settings as NSDictionary, forKey: key)
        else {
            throw DatabaseError.connection("This system refused to start TLS on the connection")
        }
        isTLS = true
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    private var availableBuffered: Int { buffer.count - bufferStart }

    public func write(_ data: Data) throws {
        try write([UInt8](data))
    }

    public func write(_ bytes: [UInt8]) throws {
        guard let output, isOpen else { throw DatabaseError.notConnected }
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBufferPointer { pointer in
                output.write(pointer.baseAddress! + written, maxLength: bytes.count - written)
            }
            if n <= 0 {
                throw DatabaseError.connection(streamErrorText(output.streamError, fallback: "Connection closed while writing"))
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
        guard let input, isOpen else { throw DatabaseError.notConnected }
        let n = scratch.withUnsafeMutableBufferPointer { pointer in
            input.read(pointer.baseAddress!, maxLength: pointer.count)
        }
        if n < 0 {
            throw DatabaseError.connection(streamErrorText(input.streamError, fallback: "Connection error while reading"))
        }
        if n == 0 {
            throw DatabaseError.connection("The server closed the connection")
        }
        buffer.append(contentsOf: scratch[0..<n])
    }

    private func streamErrorText(_ error: Error?, fallback: String) -> String {
        guard let error else { return fallback }
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain || nsError.domain == "kCFStreamErrorDomainSSL" {
            let status = OSStatus(truncatingIfNeeded: nsError.code)
            let message = SecCopyErrorMessageString(status, nil) as String? ?? nsError.localizedDescription
            return "TLS error (\(nsError.code)): \(message)"
        }
        if nsError.domain == NSPOSIXErrorDomain {
            switch Int32(nsError.code) {
            case EPIPE, ECONNRESET, ENOTCONN, ECONNABORTED:
                return "The connection to the server was lost (\(String(cString: strerror(Int32(nsError.code))).lowercased()))."
            case ETIMEDOUT:
                return "The connection to the server timed out."
            default:
                break
            }
        }
        return nsError.localizedDescription
    }

    /// Wake a read or write blocked on another thread. The owner still calls `close()` afterwards.
    /// `CFReadStreamRead` does not return when its stream is closed from another thread, but it does after `shutdown(2)`;
    /// the lock keeps the descriptor from being closed and reused while it is shut down.
    public func interrupt() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard isOpen, socketHandle >= 0 else { return }
        shutdown(socketHandle, SHUT_RDWR)
    }

    /// Close the socket. Safe to call more than once. Use `interrupt()` to abort a read from another thread.
    public func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard isOpen else { return }
        isOpen = false
        if socketHandle >= 0 {
            shutdown(socketHandle, SHUT_RDWR)
        }
        input?.close()
        output?.close()
        input = nil
        output = nil
        socketHandle = -1
    }
}

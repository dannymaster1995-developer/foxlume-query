import Darwin
import Foundation
import Testing
@testable import FoxlumeQueryCore

/// `openssl s_server -www` on a free local port with the fixture certificates: it answers `GET /` over TLS.
final class OpenSSLTestServer {
    let port: Int
    private let process = Process()

    /// `requireClientCertificate` makes the server ask for a certificate signed by the test CA and refuse the
    /// handshake without one.
    init?(requireClientCertificate: Bool = false) {
        guard TLSFixtures.isAvailable, let port = Self.freePort() else { return nil }
        self.port = port
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        var arguments = ["s_server", "-accept", String(port), "-cert", TLSFixtures.path("server.crt"),
                         "-key", TLSFixtures.path("server.key"), "-www", "-quiet"]
        if requireClientCertificate {
            arguments += ["-Verify", "1", "-verify_return_error", "-CAfile", TLSFixtures.path("ca.crt")]
        }
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        for _ in 0..<50 {
            let probe = SocketTransport()
            if (try? probe.connect(host: "127.0.0.1", port: port, timeout: 1)) != nil {
                probe.close()
                return
            }
            usleep(100_000)
        }
        process.terminate()
        return nil
    }

    deinit {
        process.terminate()
        process.waitUntilExit()
    }

    private static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }

    /// Connects, starts TLS and sends `GET /`; returns the transport and the first line of the answer.
    func get(_ options: TLSClientOptions) throws -> (SocketTransport, String) {
        let transport = SocketTransport()
        try transport.connect(host: "127.0.0.1", port: port, timeout: 3)
        try transport.startTLS(options)
        try transport.write(Array("GET / HTTP/1.0\r\n\r\n".utf8))
        var line: [UInt8] = []
        while line.last != UInt8(ascii: "\n") {
            line.append(try transport.readByte())
        }
        return (transport, String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

@Suite("TLS transport against openssl s_server", .serialized, .enabled(if: TLSFixtures.isAvailable, "needs /usr/bin/openssl"))
struct TLSTransportTests {
    private func options(_ level: TLSVerification.Level, host: String = "localhost", ca: String = "ca.crt", identity: TLSClientIdentity? = nil) throws -> TLSClientOptions {
        TLSClientOptions(
            serverName: host,
            verification: TLSVerification(level: level, anchors: [try TLSFixtures.certificate(ca)], anchorsPath: TLSFixtures.path(ca)),
            identity: identity
        )
    }

    private func connectionError(_ body: () throws -> Void) -> String? {
        do {
            try body()
        } catch DatabaseError.connection(let message) {
            return message
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        return nil
    }

    @Test func verifiedSessionCarriesData() throws {
        let server = try #require(OpenSSLTestServer())
        let (transport, line) = try server.get(try options(.chainAndHostname))
        defer { transport.close() }
        #expect(line == "HTTP/1.0 200 ok")
        #expect(transport.isTLS)
        #expect(transport.tlsProtocolVersion?.hasPrefix("TLS 1.") == true)
        #expect(transport.tlsFailure == nil)
    }

    @Test func hostNameMismatchStopsBeforeAnyDataIsSent() throws {
        let server = try #require(OpenSSLTestServer())
        let message = connectionError { _ = try server.get(try options(.chainAndHostname, host: "127.0.0.1")) }
        #expect(message?.hasPrefix("TLS error: Host name mismatch") == true)
    }

    @Test func unknownCAIsReported() throws {
        let server = try #require(OpenSSLTestServer())
        let transport = SocketTransport()
        defer { transport.close() }
        try transport.connect(host: "127.0.0.1", port: server.port, timeout: 3)
        try transport.startTLS(try options(.chain, ca: "other-ca.crt"))
        let message = connectionError { try transport.write([0x0a]) }
        #expect(message?.contains("unknown CA") == true)
        #expect(transport.tlsFailure?.kind == .unknownCA)
    }

    @Test func mutualTLS() throws {
        let server = try #require(OpenSSLTestServer(requireClientCertificate: true))
        let identity = try TLSCredentials.identity(certificatePath: TLSFixtures.path("client.crt"), keyPath: TLSFixtures.path("client.key"), passphrase: nil)
        let (transport, line) = try server.get(try options(.chainAndHostname, identity: identity))
        transport.close()
        #expect(line == "HTTP/1.0 200 ok")

        let message = connectionError { _ = try server.get(try options(.chainAndHostname)) }
        #expect(message?.contains("The server requires a client certificate") == true)

        let stranger = try TLSCredentials.identity(certificatePath: TLSFixtures.path("other-client.crt"), keyPath: TLSFixtures.path("other-client.key"), passphrase: nil)
        let rejected = connectionError { _ = try server.get(try options(.chainAndHostname, identity: stranger)) }
        #expect(rejected?.contains("rejected the client certificate \"certuser\"") == true)
    }

    @Test func interruptWakesABlockedRead() throws {
        let server = try #require(OpenSSLTestServer())
        let transport = SocketTransport()
        defer { transport.close() }
        try transport.connect(host: "127.0.0.1", port: server.port, timeout: 3)
        try transport.startTLS(try options(.none))
        // s_server waits for a request, so this read blocks until interrupted.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { transport.interrupt() }
        let started = Date()
        _ = connectionError { _ = try transport.readByte() }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func closingLeavesNoSocketFiles() throws {
        let server = try #require(OpenSSLTestServer())
        for _ in 0..<3 {
            let (transport, _) = try server.get(try options(.none))
            transport.close()
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix("fqtls.") }
        #expect(leftovers.isEmpty)
    }
}

import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct ReconnectTests {
    @Test func connectionLossErrorsAreRecognised() {
        #expect(DatabaseError.connection("The server closed the connection").isConnectionLoss)
        #expect(DatabaseError.notConnected.isConnectionLoss)
        #expect(!DatabaseError.server(message: "syntax error", code: "42601").isConnectionLoss)
        #expect(!DatabaseError.cancelled.isConnectionLoss)
    }

    @Test func healthCheckSettingDecodesAndDefaults() throws {
        #expect(AppSettings().connectionHealthCheck == .every30Seconds)
        #expect(ConnectionHealthCheck.onDemand.interval == nil)
        #expect(ConnectionHealthCheck.every5Minutes.interval == 300)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"rowsPerPage": 100}"#.utf8))
        #expect(old.connectionHealthCheck == .every30Seconds)
        var settings = AppSettings()
        settings.connectionHealthCheck = .onDemand
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.connectionHealthCheck == .onDemand)
    }

    @Test func sqliteSessionPingsAndReconnectsToTheSameFile() async throws {
        let url = TestFiles.url("reconnect-\(UUID().uuidString).sqlite")
        defer { TestFiles.removeDatabase(url) }
        let session = DatabaseSession(parameters: ConnectionParameters(config: ConnectionConfig(kind: .sqlite, filePath: url.path), password: ""))
        try await session.connect()
        _ = try await session.execute("CREATE TABLE t (id INTEGER); INSERT INTO t VALUES (1), (2)")
        try await session.ping(timeout: 5)
        try await session.reconnect()
        let rows = try await session.execute("SELECT COUNT(*) FROM t")
        #expect(rows.first?.rows.first?.first?.displayString == "2")
        await session.close()
    }

    /// A server that accepts the connection but never answers stands in for a dropped network.
    @Test func connectGivesUpOnASilentServer() async throws {
        let listener = try SilentServer()
        defer { listener.stop() }
        var config = ConnectionConfig(kind: .redis, host: "127.0.0.1", port: listener.port, user: "", database: "", sslMode: .disable)
        config.connectTimeout = 2
        let session = DatabaseSession(parameters: ConnectionParameters(config: config, password: ""))
        // The handshake itself never gets an answer, so connecting must fail on its deadline rather than hang.
        let started = Date()
        await #expect(throws: (any Error).self) { try await session.connect() }
        #expect(Date().timeIntervalSince(started) < 15)
    }
}

@Suite("Reconnect against MySQL", .serialized, .enabled(if: MySQLTestServer.isAvailable))
struct MySQLReconnectTests {
    @Test func abortedLinkFailsAsConnectionLossAndReconnectRestoresIt() async throws {
        let session = DatabaseSession(parameters: MySQLTestServer.parameters(ssl: .disable))
        try await session.connect()
        try await session.ping(timeout: 5)
        try await session.run { $0.abort() }
        do {
            _ = try await session.execute("SELECT 1")
            Issue.record("A statement on an aborted link succeeded.")
        } catch {
            #expect((error as? DatabaseError)?.isConnectionLoss == true, "\(error)")
        }
        await #expect(throws: (any Error).self) { try await session.ping(timeout: 5) }
        try await session.reconnect()
        try await session.ping(timeout: 5)
        let rows = try await session.execute("SELECT DATABASE()")
        #expect(rows.first?.rows.first?.first?.displayString == "foxlume")
        await session.close()
    }
}

/// Accepts TCP connections and never writes a byte.
final class SilentServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private var accepted: [Int32] = []
    private let lock = NSLock()

    init() throws {
        let listening = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listening, $0, length) } }
        guard bound == 0, listen(listening, 4) == 0 else { throw DatabaseError.connection("listen failed") }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listening, $0, &length) } }
        fd = listening
        port = Int(UInt16(bigEndian: address.sin_port))
        DispatchQueue.global().async { [weak self] in
            while true {
                let client = accept(listening, nil, nil)
                guard client >= 0 else { return }
                self?.lock.lock()
                self?.accepted.append(client)
                self?.lock.unlock()
            }
        }
    }

    func stop() {
        lock.lock()
        accepted.forEach { close($0) }
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}

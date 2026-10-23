import Foundation
import Testing
@testable import FoxlumeQueryCore

/// The scratch servers from `scripts/dbtest-tls.sh` (PostgreSQL 55442, MySQL 53316) and the certificates they were
/// set up with (`.dbtest/tls`, or `FOXLUME_TLS_DIR`). Suites skip when a port is closed.
enum TLSTestServers {
    static let certificates: String = ProcessInfo.processInfo.environment["FOXLUME_TLS_DIR"]
        ?? URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".dbtest/tls").path

    static func file(_ name: String) -> String { (certificates as NSString).appendingPathComponent(name) }

    static func isOpen(_ port: Int) -> Bool {
        guard FileManager.default.fileExists(atPath: file("ca.crt")) else { return false }
        let transport = SocketTransport()
        defer { transport.close() }
        return (try? transport.connect(host: "127.0.0.1", port: port, timeout: 1)) != nil
    }

    static let postgresPort = 55442
    static let mysqlPort = 53316
    static let postgresAvailable = isOpen(postgresPort)
    static let mysqlAvailable = isOpen(mysqlPort)

    /// Certificate files by fixture name; an empty name leaves the field empty.
    static func files(ca: String = "", cert: String = "", key: String = "", p12: String = "") -> TLSCertificateFiles {
        func path(_ name: String) -> String { name.isEmpty ? "" : file(name) }
        return TLSCertificateFiles(caCertificatePath: path(ca), clientCertificatePath: path(cert), clientKeyPath: path(key), pkcs12Path: path(p12))
    }

    static func parameters(_ kind: DatabaseKind, host: String = "127.0.0.1", user: String, password: String = "", mode: SSLMode, files: TLSCertificateFiles, secret: String? = nil) -> ConnectionParameters {
        let port = kind == .postgresql ? postgresPort : mysqlPort
        var config = ConnectionConfig(kind: kind, host: host, port: port, user: user, database: kind == .postgresql ? "postgres" : "", sslMode: mode, connectTimeout: 5)
        config.certificates = files
        return ConnectionParameters(config: config, password: password, tlsSecret: secret)
    }
}

private func failure(_ body: () throws -> Void) -> DatabaseError? {
    do {
        try body()
    } catch let error as DatabaseError {
        return error
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    return nil
}

// MARK: - PostgreSQL

@Suite("PostgreSQL TLS certificates", .enabled(if: TLSTestServers.postgresAvailable, "needs scripts/dbtest-tls.sh"))
struct PostgresTLSLiveTests {
    private func connect(host: String = "127.0.0.1", user: String = "postgres", mode: SSLMode, files: TLSCertificateFiles, secret: String? = nil, serverName: String? = nil) throws -> PostgresConnection {
        var parameters = TLSTestServers.parameters(.postgresql, host: host, user: user, password: "postgres", mode: mode, files: files, secret: secret)
        parameters.tlsServerName = serverName
        let connection = PostgresConnection(parameters: parameters)
        try connection.connect()
        return connection
    }

    private func value(_ connection: PostgresConnection, _ sql: String) throws -> String? {
        try connection.execute(sql, rowLimit: nil).last?.rows.first?.first?.textValue
    }

    @Test func verifyCAWithTheRightCAOverTLS13() throws {
        let connection = try connect(mode: .verifyCA, files: TLSTestServers.files(ca: "ca.crt"))
        defer { connection.close() }
        #expect(connection.tlsProtocolVersion == "TLS 1.3")
        #expect(try value(connection, "SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid()") == "TLSv1.3")
    }

    @Test func verifyIdentityChecksTheHostName() throws {
        let mismatch = failure { _ = try connect(mode: .verifyFull, files: TLSTestServers.files(ca: "ca.crt")) }
        guard case .connection(let message)? = mismatch else {
            Issue.record("Expected a connection error")
            return
        }
        #expect(message.hasPrefix("TLS handshake with 127.0.0.1 failed: Host name mismatch: the server certificate is for \"localhost\""))

        let matching = try connect(host: "localhost", mode: .verifyFull, files: TLSTestServers.files(ca: "ca.crt"))
        matching.close()
        // Behind an SSH tunnel the driver dials 127.0.0.1 but checks the real host name.
        let tunnelled = try connect(mode: .verifyFull, files: TLSTestServers.files(ca: "ca.crt"), serverName: "localhost")
        tunnelled.close()
    }

    @Test func wrongCAIsAnUnknownCA() {
        guard case .connection(let message)? = failure({ _ = try connect(mode: .verifyCA, files: TLSTestServers.files(ca: "other-ca.crt")) }) else {
            Issue.record("Expected a connection error")
            return
        }
        #expect(message.contains("(unknown CA)"))
        #expect(message.contains("“other-ca.crt”"))
    }

    @Test func requiredIgnoresTheCA() throws {
        let connection = try connect(mode: .require, files: TLSTestServers.files(ca: "other-ca.crt"))
        connection.close()
    }

    @Test(arguments: [
        ("client.crt", "client.key", nil as String?),
        ("client.crt", "client-pkcs8-enc.key", "secret"),
        ("client.crt", "client-legacy-enc.key", "secret"),
        ("client-ec.crt", "client-ec.key", nil),
        ("client-chain.crt", "client-rsa.key", nil),
    ])
    func mutualTLS(cert: String, key: String, secret: String?) throws {
        let connection = try connect(user: "certuser", mode: .verifyCA, files: TLSTestServers.files(ca: "ca.crt", cert: cert, key: key), secret: secret)
        defer { connection.close() }
        #expect(try value(connection, "SELECT current_user") == "certuser")
    }

    @Test func mutualTLSWithPKCS12() throws {
        guard #available(macOS 15.0, *) else { return }
        let connection = try connect(user: "certuser", mode: .require, files: TLSTestServers.files(p12: "client.p12"), secret: "secret")
        defer { connection.close() }
        #expect(try value(connection, "SELECT current_user") == "certuser")
    }

    @Test func missingClientCertificateIsRefused() {
        guard case .authentication(let message)? = failure({ _ = try connect(user: "certuser", mode: .require, files: TLSCertificateFiles()) }) else {
            Issue.record("Expected an authentication error")
            return
        }
        #expect(message.contains("connection requires a valid client certificate"))
        #expect(message.contains("Choose a client certificate"))
    }

    @Test func certificateFromAnotherCAIsRejected() {
        let files = TLSTestServers.files(cert: "other-client.crt", key: "other-client.key")
        guard case .connection(let message)? = failure({ _ = try connect(user: "certuser", mode: .require, files: files) }) else {
            Issue.record("Expected a connection error")
            return
        }
        #expect(message.contains("The server rejected the client certificate \"certuser\""))
    }

    @Test func wrongKeyPassphrase() {
        let files = TLSTestServers.files(cert: "client.crt", key: "client-pkcs8-enc.key")
        guard case .connection(let message)? = failure({ _ = try connect(user: "certuser", mode: .require, files: files, secret: "wrong") }) else {
            Issue.record("Expected a connection error")
            return
        }
        #expect(message == "Wrong passphrase for the client key “client-pkcs8-enc.key”.")
    }

    @Test func cancelWorksOverTLS() async throws {
        let connection = try connect(mode: .verifyCA, files: TLSTestServers.files(ca: "ca.crt"))
        defer { connection.close() }
        TestThreads.after(0.5) { connection.cancel() }
        let started = Date()
        #expect(throws: DatabaseError.self) { _ = try connection.execute("SELECT pg_sleep(10)", rowLimit: nil) }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(try value(connection, "SELECT 1") == "1")
    }

    @Test func sessionReportsTheTLSVersion() async throws {
        let session = DatabaseSession(parameters: TLSTestServers.parameters(.postgresql, user: "certuser", mode: .verifyCA, files: TLSTestServers.files(ca: "ca.crt", cert: "client.crt", key: "client.key")))
        try await session.connect()
        #expect(session.tlsProtocolVersion == "TLS 1.3")
        await session.close()
    }
}

// MARK: - MySQL

@Suite("MySQL TLS certificates", .enabled(if: TLSTestServers.mysqlAvailable, "needs scripts/dbtest-tls.sh"))
struct MySQLTLSLiveTests {
    private func connect(host: String = "127.0.0.1", user: String = "root", password: String = "root", mode: SSLMode, files: TLSCertificateFiles, secret: String? = nil) throws -> MySQLConnection {
        let connection = MySQLConnection(parameters: TLSTestServers.parameters(.mysql, host: host, user: user, password: password, mode: mode, files: files, secret: secret))
        try connection.connect()
        return connection
    }

    private func value(_ connection: MySQLConnection, _ sql: String) throws -> String? {
        try connection.execute(sql, rowLimit: nil).last?.rows.first?.last?.textValue
    }

    @Test func verifyCAWithTheRightCAOverTLS13() throws {
        let connection = try connect(mode: .verifyCA, files: TLSTestServers.files(ca: "ca.crt"))
        defer { connection.close() }
        #expect(connection.tlsProtocolVersion == "TLS 1.3")
        #expect(try value(connection, "SHOW STATUS LIKE 'Ssl_version'") == "TLSv1.3")
    }

    @Test func verifyIdentityChecksTheHostName() throws {
        guard case .connection(let message)? = failure({ _ = try connect(mode: .verifyFull, files: TLSTestServers.files(ca: "ca.crt")) }) else {
            Issue.record("Expected a connection error")
            return
        }
        #expect(message.hasPrefix("TLS handshake failed: Host name mismatch"))
        let matching = try connect(host: "localhost", mode: .verifyFull, files: TLSTestServers.files(ca: "ca.crt"))
        matching.close()
    }

    @Test func wrongCAIsAnUnknownCA() {
        guard case .connection(let message)? = failure({ _ = try connect(mode: .verifyCA, files: TLSTestServers.files(ca: "other-ca.crt")) }) else {
            Issue.record("Expected a connection error")
            return
        }
        #expect(message.contains("(unknown CA)"))
    }

    @Test(arguments: [("client.key", nil as String?), ("client-pkcs8-enc.key", "secret"), ("client-legacy-enc.key", "secret")])
    func mutualTLS(key: String, secret: String?) throws {
        let connection = try connect(user: "certuser", password: "certpass", mode: .verifyCA, files: TLSTestServers.files(ca: "ca.crt", cert: "client.crt", key: key), secret: secret)
        defer { connection.close() }
        #expect(try value(connection, "SELECT CURRENT_USER()") == "certuser@%")
        #expect(try value(connection, "SHOW STATUS LIKE 'Ssl_version'") == "TLSv1.3")
    }

    @Test func missingClientCertificateIsRefused() {
        guard case .authentication(let message)? = failure({ _ = try connect(user: "certuser", password: "certpass", mode: .require, files: TLSCertificateFiles()) }) else {
            Issue.record("Expected an authentication error")
            return
        }
        #expect(message.contains("Access denied"))
        #expect(message.contains("REQUIRE X509"))
    }

    @Test func certificateFromAnotherCAIsRejected() {
        let files = TLSTestServers.files(cert: "other-client.crt", key: "other-client.key")
        guard case .connection(let message)? = failure({ _ = try connect(user: "certuser", password: "certpass", mode: .require, files: files) }) else {
            Issue.record("Expected a connection error")
            return
        }
        #expect(message.hasPrefix("TLS handshake failed: The server rejected the client certificate \"certuser\""))
    }

    @Test func wrongKeyPassphrase() {
        let files = TLSTestServers.files(cert: "client.crt", key: "client-legacy-enc.key")
        guard case .connection(let message)? = failure({ _ = try connect(user: "certuser", password: "certpass", mode: .require, files: files, secret: "nope") }) else {
            Issue.record("Expected a connection error")
            return
        }
        #expect(message == "Wrong passphrase for the client key “client-legacy-enc.key”.")
    }

    @Test func killQueryReusesTheClientCertificate() throws {
        let connection = try connect(user: "certuser", password: "certpass", mode: .require, files: TLSTestServers.files(cert: "client.crt", key: "client.key"))
        defer { connection.close() }
        TestThreads.after(0.5) { connection.cancel() }
        let started = Date()
        _ = try? connection.execute("SELECT SLEEP(10)", rowLimit: nil)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

// MARK: - MongoDB and Redis (Beta)

/// The regular test servers use self-signed certificates for CN=localhost; as their own CA they show that custom CAs
/// work for these engines too.
enum BetaTLSCertificates {
    static let dbtest = URL(fileURLWithPath: TLSTestServers.certificates).deletingLastPathComponent()
    static let mongo = dbtest.appendingPathComponent("run/mongo.crt").path
    static let redisProxy = dbtest.appendingPathComponent("redis-extra/tls/cert.pem").path
    static var mongoAvailable: Bool { FileManager.default.fileExists(atPath: mongo) && MongoTestServer.isAvailable }
    static var redisProxyAvailable: Bool {
        FileManager.default.fileExists(atPath: redisProxy) && RedisTestServer.reachable(RedisExtraServers.tlsProxy)
    }
}

@Suite("MongoDB TLS certificates", .serialized, .enabled(if: BetaTLSCertificates.mongoAvailable, "needs the MongoDB test server"))
struct MongoTLSLiveTests {
    private func connection(host: String, mode: SSLMode, uri: String? = nil) -> MongoConnection {
        var config = ConnectionConfig(kind: .mongodb, host: host, port: MongoTestServer.port, user: "root", database: "foxlume", sslMode: mode, connectTimeout: 5)
        config.setOption(.mongoAuthSource, "admin")
        if let uri { config.setOption(.mongoConnectionString, uri) }
        config.certificates = TLSCertificateFiles(caCertificatePath: BetaTLSCertificates.mongo)
        return MongoConnection(parameters: ConnectionParameters(config: config, password: "root"))
    }

    @Test func verifiesAgainstTheCustomCA() throws {
        let verified = connection(host: "localhost", mode: .verifyFull)
        try verified.connect()
        #expect(verified.isTLS)
        #expect(verified.tlsProtocolVersion != nil)
        verified.close()

        let chainOnly = connection(host: "127.0.0.1", mode: .verifyCA)
        try chainOnly.connect()
        chainOnly.close()
    }

    @Test func hostNameMismatch() {
        guard case .connection(let message)? = failure({ try connection(host: "127.0.0.1", mode: .verifyFull).connect() }) else {
            Issue.record("Expected a connection error")
            return
        }
        #expect(message.contains("Host name mismatch: the server certificate is for \"localhost\", not \"127.0.0.1\""))
    }

    @Test func connectionStringCAFile() throws {
        let uri = "mongodb://root@localhost:\(MongoTestServer.port)/foxlume?authSource=admin&tls=true&tlsCAFile=\(BetaTLSCertificates.mongo)"
        var config = ConnectionConfig(kind: .mongodb, host: "localhost", port: MongoTestServer.port, sslMode: .verifyFull, connectTimeout: 5)
        config.setOption(.mongoConnectionString, uri)
        let connection = MongoConnection(parameters: ConnectionParameters(config: config, password: "root"))
        try connection.connect()
        #expect(connection.isTLS)
        connection.close()
    }
}

@Suite("Redis TLS certificates", .enabled(if: BetaTLSCertificates.redisProxyAvailable, "needs scripts/redis-extra.sh"))
struct RedisTLSCertificateLiveTests {
    @Test func verifyIdentityWithTheProxyCertificateAsCA() throws {
        var config = RedisTestServer.config(port: RedisExtraServers.tlsProxy, ssl: .verifyFull)
        config.host = "localhost"
        config.certificates = TLSCertificateFiles(caCertificatePath: BetaTLSCertificates.redisProxy)
        let connection = RedisConnection(parameters: ConnectionParameters(config: config, password: RedisTestServer.password))
        try connection.connect()
        defer { connection.close() }
        #expect(connection.isTLS)
        #expect(connection.tlsProtocolVersion != nil)
    }
}

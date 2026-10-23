import Foundation
import Security
import Testing
@testable import FoxlumeQueryCore

// MARK: - Helpers

/// Serves scripted server bytes and records what the client writes.
private final class ScriptedChannel: MySQLByteChannel {
    private let incoming: [UInt8]
    private var offset = 0
    private(set) var written: [[UInt8]] = []

    init(_ incoming: [UInt8] = []) {
        self.incoming = incoming
    }

    var isDrained: Bool { offset == incoming.count }

    func read(exactly count: Int) throws -> [UInt8] {
        guard offset + count <= incoming.count else { throw DatabaseError.connection("The server closed the connection") }
        defer { offset += count }
        return Array(incoming[offset..<(offset + count)])
    }

    func write(_ bytes: [UInt8]) throws {
        written.append(bytes)
    }
}

private func frame(_ payload: [UInt8], sequence: UInt8) -> [UInt8] {
    let count = payload.count
    return [UInt8(count & 0xFF), UInt8((count >> 8) & 0xFF), UInt8((count >> 16) & 0xFF), sequence] + payload
}

/// Server packets numbered consecutively from `start`.
private func script(_ payloads: [[UInt8]], startingAt start: UInt8 = 0) -> [UInt8] {
    var bytes: [UInt8] = []
    for (index, payload) in payloads.enumerated() {
        bytes += frame(payload, sequence: start &+ UInt8(index))
    }
    return bytes
}

private func lenenc(_ string: String) -> [UInt8] {
    var writer = ByteWriter()
    writer.lengthEncodedBytes(Array(string.utf8))
    return writer.bytes
}

private func columnPacket(_ name: String, type: UInt8, charset: UInt16 = 45, flags: UInt16 = 0, table: String = "t") -> [UInt8] {
    var writer = ByteWriter()
    for part in ["def", "foxlume", table, table, name, name] {
        writer.lengthEncodedBytes(Array(part.utf8))
    }
    writer.uint8(0x0C)
    writer.uint16LE(charset)
    writer.uint32LE(255)
    writer.uint8(type)
    writer.uint16LE(flags)
    writer.uint8(0)
    writer.uint16LE(0)
    return writer.bytes
}

private func rowPacket(_ values: [String?]) -> [UInt8] {
    values.flatMap { $0.map(lenenc) ?? [0xFB] }
}

private func okPacket(header: UInt8 = 0x00, affected: UInt64 = 0, insertID: UInt64 = 0, status: UInt16 = 0x0002, warnings: UInt16 = 0, info: String = "") -> [UInt8] {
    var writer = ByteWriter()
    writer.uint8(header)
    writer.lengthEncodedInt(affected)
    writer.lengthEncodedInt(insertID)
    writer.uint16LE(status)
    writer.uint16LE(warnings)
    if !info.isEmpty { writer.lengthEncodedBytes(Array(info.utf8)) }
    return writer.bytes
}

private func eofPacket(status: UInt16 = 0x0002) -> [UInt8] {
    [0xFE, 0, 0, UInt8(status & 0xFF), UInt8(status >> 8)]
}

private func errPacket(code: UInt16, state: String, message: String) -> [UInt8] {
    var writer = ByteWriter()
    writer.uint8(0xFF)
    writer.uint16LE(code)
    writer.utf8("#" + state)
    writer.utf8(message)
    return writer.bytes
}

private func hex(_ bytes: [UInt8]) -> String {
    Data(bytes).hexString
}

private func caught(_ body: () throws -> Void) -> DatabaseError? {
    do {
        try body()
    } catch let error as DatabaseError {
        return error
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
    return nil
}

// MARK: - Protocol (no server needed)

@Suite("MySQL protocol")
struct MySQLProtocolTests {
    // Expected values computed with openssl, independently of CryptoKit:
    //   s1 = sha1("secret"); s2 = sha1(s1); s3 = sha1(scramble || s2); s1 XOR s3
    //   d1 = sha256("secret"); d2 = sha256(d1); d3 = sha256(d2 || scramble); d1 XOR d3
    private let scramble = Array("abcdefghijklmnopqrst".utf8)

    @Test func nativePasswordScrambleMatchesOpenSSLVector() {
        let response = MySQLAuth.nativePasswordScramble(password: "secret", scramble: scramble)
        #expect(hex(response) == "8817c50fa779daef010ee7577825b0847df9842e")
    }

    @Test func cachingSHA2ScrambleMatchesOpenSSLVector() {
        let response = MySQLAuth.cachingSHA2Scramble(password: "secret", scramble: scramble)
        #expect(hex(response) == "c76e2898612a4cf042c77fa8c4702c4c64c0c2c557c53c4d75595aaa6abae809")
    }

    @Test func emptyPasswordSendsEmptyResponse() {
        #expect(MySQLAuth.nativePasswordScramble(password: "", scramble: scramble).isEmpty)
        #expect(MySQLAuth.cachingSHA2Scramble(password: "", scramble: scramble).isEmpty)
        #expect(MySQLAuth.cleartext("pw") == [0x70, 0x77, 0x00])
    }

    @Test func rsaPasswordEncryptionRoundTrips() throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(publicKey, &error) as Data?)

        // Wrap PKCS#1 in SubjectPublicKeyInfo, as the server sends it.
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString = derElement(0x03, [0x00] + [UInt8](pkcs1))
        let spki = derElement(0x30, algorithm + bitString)
        #expect(MySQLAuth.pkcs1PublicKey(fromSubjectPublicKeyInfo: spki) == [UInt8](pkcs1))
        #expect(MySQLAuth.pkcs1PublicKey(fromSubjectPublicKeyInfo: [UInt8](pkcs1)) == nil)

        let base64 = Data(spki).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = Array("-----BEGIN PUBLIC KEY-----\n\(base64)\n-----END PUBLIC KEY-----\n".utf8)
        let encrypted = try MySQLAuth.encryptPassword("Pässwörd!", scramble: scramble, publicKeyPEM: pem)
        #expect(encrypted.count == 256)

        let decrypted = try #require(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA1, Data(encrypted) as CFData, &error) as Data?)
        let plain = [UInt8](decrypted).enumerated().map { $0.element ^ scramble[$0.offset % scramble.count] }
        #expect(plain == Array("Pässwörd!".utf8) + [0])
    }

    private func derElement(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let count = content.count
        if count < 0x80 { return [tag, UInt8(count)] + content }
        if count <= 0xFF { return [tag, 0x81, UInt8(count)] + content }
        return [tag, 0x82, UInt8(count >> 8), UInt8(count & 0xFF)] + content
    }

    @Test func writesFramesWithIncreasingSequence() throws {
        let channel = ScriptedChannel()
        let stream = MySQLPacketStream(channel: channel)
        try stream.write([0x03, 0x41])
        try stream.write([])
        #expect(channel.written == [[2, 0, 0, 0, 0x03, 0x41], [0, 0, 0, 1]])
        stream.resetSequence()
        #expect(stream.sequence == 0)
    }

    @Test func splitsLargePayloads() throws {
        let max = MySQLProtocol.maxPacketPayload
        let channel = ScriptedChannel()
        let stream = MySQLPacketStream(channel: channel)
        try stream.write([UInt8](repeating: 7, count: max + 5))
        #expect(channel.written.map(\.count) == [max + 4, 9])
        #expect(Array(channel.written[0].prefix(4)) == [0xFF, 0xFF, 0xFF, 0])
        #expect(Array(channel.written[1].prefix(4)) == [5, 0, 0, 1])

        // A payload that fills a packet exactly is terminated by an empty packet.
        let exact = ScriptedChannel()
        try MySQLPacketStream(channel: exact).write([UInt8](repeating: 1, count: max))
        #expect(exact.written.map(\.count) == [max + 4, 4])
        #expect(exact.written[1] == [0, 0, 0, 1])
    }

    @Test func joinsContinuationPackets() throws {
        let max = MySQLProtocol.maxPacketPayload
        let first = [UInt8](repeating: 9, count: max)
        let channel = ScriptedChannel(frame(first, sequence: 0) + frame([1, 2, 3], sequence: 1) + frame([4], sequence: 2))
        let stream = MySQLPacketStream(channel: channel)
        let joined = try stream.read()
        #expect(joined.count == max + 3)
        #expect(Array(joined.suffix(3)) == [1, 2, 3])
        #expect(try stream.read() == [4])
        #expect(stream.sequence == 3)
    }

    @Test func rejectsOutOfOrderPackets() {
        let stream = MySQLPacketStream(channel: ScriptedChannel(frame([0], sequence: 5)))
        guard case .protocolViolation? = caught({ _ = try stream.read() }) else {
            Issue.record("Expected a protocol violation")
            return
        }
    }

    @Test func reportsStrayServerErrors() {
        let message = "The client was disconnected by the server because of inactivity."
        let stream = MySQLPacketStream(channel: ScriptedChannel(frame(errPacket(code: 4031, state: "HY000", message: message), sequence: 0)))
        try? stream.write([MySQLCommand.query.rawValue])
        guard case .connection(let text)? = caught({ _ = try stream.read() }) else {
            Issue.record("Expected a connection error")
            return
        }
        #expect(text == message)
    }

    @Test func parsesHandshakeV10() throws {
        var writer = ByteWriter()
        writer.uint8(10)
        writer.cString("8.4.9")
        writer.uint32LE(4242)
        writer.append(Array("abcdefgh".utf8))
        writer.uint8(0)
        writer.uint16LE(0xFFFF)
        writer.uint8(255)
        writer.uint16LE(0x0202)
        writer.uint16LE(0xDFFF)
        writer.uint8(21)
        writer.append([UInt8](repeating: 0, count: 10))
        writer.append(Array("ijklmnopqrst".utf8) + [0])
        writer.cString("caching_sha2_password")

        let handshake = try MySQLHandshake(payload: writer.bytes)
        #expect(handshake.serverVersion == "8.4.9")
        #expect(handshake.connectionID == 4242)
        #expect(handshake.scramble == scramble)
        #expect(handshake.capabilities.contains([.protocol41, .ssl, .pluginAuth, .deprecateEOF, .secureConnection]))
        #expect(handshake.statusFlags.contains(.noBackslashEscapes))
        #expect(handshake.authPluginName == "caching_sha2_password")
    }

    @Test func stripsMariaDBReplicationPrefix() {
        #expect(MySQLHandshake.displayVersion("5.5.5-10.11.6-MariaDB") == "10.11.6-MariaDB")
        #expect(MySQLHandshake.displayVersion("5.5.5-10.6.18-MariaDB-0ubuntu0.22.04.1") == "10.6.18-MariaDB-0ubuntu0.22.04.1")
        #expect(MySQLHandshake.displayVersion("8.4.9") == "8.4.9")
        #expect(MySQLHandshake.displayVersion("5.5.62") == "5.5.62")
    }

    @Test func okPacketMessage() throws {
        let ok = try MySQLOKPacket(payload: okPacket(affected: 3, insertID: 7, status: 0x000A, info: "Records: 3  Duplicates: 0  Warnings: 0"))
        #expect(ok.affectedRows == 3)
        #expect(ok.statusFlags.contains(.moreResultsExist))
        #expect(ok.message == "Affected rows: 3; Records: 3  Duplicates: 0  Warnings: 0; Last insert ID: 7")
        let bare = try MySQLOKPacket(payload: okPacket(affected: 1, warnings: 2))
        #expect(bare.message == "Affected rows: 1; Warnings: 2")
        let short = try MySQLOKPacket(payload: [0x00, 0x00, 0x00])
        #expect(short.message == "Affected rows: 0")
    }

    @Test func errorPacketMapping() throws {
        let syntax = try MySQLErrorPacket(payload: errPacket(code: 1064, state: "42000", message: "You have an error"))
        guard case let .server(message, code, _) = syntax.serverError else {
            Issue.record("Expected a server error")
            return
        }
        #expect(message == "You have an error")
        #expect(code == "1064/42000")

        let interrupted = try MySQLErrorPacket(payload: errPacket(code: 1317, state: "70100", message: "Query execution was interrupted"))
        guard case .cancelled = interrupted.serverError else {
            Issue.record("Expected cancellation")
            return
        }

        // Errors sent before the handshake carry no SQLSTATE.
        let early = try MySQLErrorPacket(payload: [0xFF, 0x10, 0x04] + Array("Too many connections".utf8))
        #expect(early.code == 1040)
        #expect(early.codeText == "1040")
        #expect(early.message == "Too many connections")
    }

    @Test func columnTypes() {
        typealias Case = (type: UInt8, charset: UInt16, flags: UInt16, name: String, numeric: Bool, binary: Bool)
        let cases: [Case] = [
            (1, 63, 0, "TINYINT", true, false),
            (3, 63, 0x20, "INT", true, false),
            (8, 63, 0, "BIGINT", true, false),
            (246, 63, 0, "DECIMAL", true, false),
            (4, 63, 0, "FLOAT", true, false),
            (5, 63, 0, "DOUBLE", true, false),
            (13, 63, 0, "YEAR", true, false),
            (10, 63, 0, "DATE", false, false),
            (12, 63, 0, "DATETIME", false, false),
            (7, 63, 0, "TIMESTAMP", false, false),
            (11, 63, 0, "TIME", false, false),
            (245, 63, 0, "JSON", false, false),
            (253, 45, 0, "VARCHAR", false, false),
            (253, 63, 0, "VARBINARY", false, true),
            (254, 45, 0, "CHAR", false, false),
            (254, 63, 0, "BINARY", false, true),
            (254, 45, 0x0100, "ENUM", false, false),
            (254, 45, 0x0800, "SET", false, false),
            (252, 45, 0, "TEXT", false, false),
            (252, 63, 0, "BLOB", false, true),
            (16, 63, 0, "BIT", false, true),
            (255, 63, 0, "GEOMETRY", false, true),
            (242, 63, 0, "VECTOR", false, false),
            (99, 45, 0, "type:99", false, false),
        ]
        for item in cases {
            let column = MySQLColumnDefinition(name: "c", type: item.type, characterSet: item.charset, flags: item.flags)
            #expect(column.typeName == item.name, "type \(item.type)")
            #expect(column.isNumeric == item.numeric, "type \(item.type)")
            #expect(column.isBinary == item.binary, "type \(item.type)")
        }
    }

    @Test func decodesTextRows() throws {
        let columns = [
            MySQLColumnDefinition(name: "id", type: 3, characterSet: 63),
            MySQLColumnDefinition(name: "raw", type: 253, characterSet: 63),
            MySQLColumnDefinition(name: "at", type: 12, characterSet: 63),
            MySQLColumnDefinition(name: "name", type: 253),
            MySQLColumnDefinition(name: "doc", type: 245, characterSet: 63),
            MySQLColumnDefinition(name: "missing", type: 253),
        ]
        var packet = lenenc("42")
        packet += [4, 0xDE, 0xAD, 0xBE, 0xEF]
        packet += lenenc("2026-10-13 08:30:00.125")
        packet += lenenc("Zoë ✓")
        packet += lenenc("{\"a\": 1}")
        packet += [0xFB]
        let row = try MySQLTextRow.decode(packet, columns: columns)
        #expect(row == [
            .text("42"),
            .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])),
            .text("2026-10-13 08:30:00.125"),
            .text("Zoë ✓"),
            .text("{\"a\": 1}"),
            .null,
        ])

        // Invalid UTF-8 in a text column falls back to bytes instead of being mangled.
        let invalid = try MySQLTextRow.decode([2, 0xC3, 0x28], columns: [MySQLColumnDefinition(name: "x", type: 253)])
        #expect(invalid == [.bytes(Data([0xC3, 0x28]))])

        guard case .protocolViolation? = caught({ _ = try MySQLTextRow.decode(lenenc("1"), columns: columns) }) else {
            Issue.record("Expected a protocol violation for a short row")
            return
        }
    }

    @Test func readsDeprecateEOFResultWithRowLimit() throws {
        let channel = ScriptedChannel(script([
            [2],
            columnPacket("id", type: 3, charset: 63),
            columnPacket("name", type: 253),
            rowPacket(["1", "a"]),
            rowPacket(["2", nil]),
            rowPacket(["3", "c"]),
            okPacket(header: 0xFE, status: 0x0202),
        ]))
        var statuses: [MySQLServerStatus] = []
        let reader = MySQLResultReader(stream: MySQLPacketStream(channel: channel), deprecateEOF: true)
        let results = try reader.readAll(rowLimit: 2) { statuses.append($0) }
        #expect(results.count == 1)
        #expect(results[0].columns.map(\.name) == ["id", "name"])
        #expect(results[0].columns[0].isNumeric)
        #expect(results[0].columns[0].tableName == "t")
        #expect(results[0].rows == [[.text("1"), .text("a")], [.text("2"), .null]])
        #expect(results[0].truncated)
        #expect(statuses.first?.contains(.noBackslashEscapes) == true)
        #expect(channel.isDrained)
    }

    @Test func readsLegacyEOFResultsAndMultipleResults() throws {
        let channel = ScriptedChannel(script([
            [1],
            columnPacket("n", type: 8, charset: 63),
            eofPacket(),
            rowPacket(["1"]),
            eofPacket(status: 0x000A),
            okPacket(affected: 2, status: 0x000A, info: "Rows matched: 2  Changed: 2  Warnings: 0"),
            [1],
            columnPacket("s", type: 253),
            eofPacket(),
            rowPacket(["x"]),
            eofPacket(status: 0x0002),
        ]))
        let reader = MySQLResultReader(stream: MySQLPacketStream(channel: channel), deprecateEOF: false)
        let results = try reader.readAll(rowLimit: nil) { _ in }
        #expect(results.count == 3)
        #expect(results[0].rows == [[.text("1")]])
        #expect(!results[0].truncated)
        #expect(results[1].affectedRows == 2)
        #expect(results[1].message == "Affected rows: 2; Rows matched: 2  Changed: 2  Warnings: 0")
        #expect(results[2].rows == [[.text("x")]])
        #expect(channel.isDrained)
    }

    @Test func rejectsLocalInfile() {
        let incoming = frame([0xFB] + Array("/etc/passwd".utf8), sequence: 0) + frame(okPacket(), sequence: 2)
        let channel = ScriptedChannel(incoming)
        let reader = MySQLResultReader(stream: MySQLPacketStream(channel: channel), deprecateEOF: true)
        guard case .unsupported? = caught({ _ = try reader.readAll(rowLimit: nil) { _ in } }) else {
            Issue.record("Expected LOCAL INFILE to be rejected")
            return
        }
        #expect(channel.written == [[0, 0, 0, 1]])
        #expect(channel.isDrained)
    }

    @Test func errorsInsideResultSets() {
        let failing = ScriptedChannel(script([
            [1], columnPacket("n", type: 3, charset: 63), rowPacket(["1"]),
            errPacket(code: 1365, state: "22012", message: "Division by 0"),
        ]))
        let reader = MySQLResultReader(stream: MySQLPacketStream(channel: failing), deprecateEOF: true)
        guard case let .server(_, code, _)? = caught({ _ = try reader.readAll(rowLimit: nil) { _ in } }) else {
            Issue.record("Expected a server error")
            return
        }
        #expect(code == "1365/22012")

        let killed = ScriptedChannel(script([
            [1], columnPacket("n", type: 3, charset: 63),
            errPacket(code: 1317, state: "70100", message: "Query execution was interrupted"),
        ]))
        let killedReader = MySQLResultReader(stream: MySQLPacketStream(channel: killed), deprecateEOF: true)
        guard case .cancelled? = caught({ _ = try killedReader.readAll(rowLimit: nil) { _ in } }) else {
            Issue.record("Expected cancellation")
            return
        }
    }
}

/// A listener that accepts TCP connections (through the backlog) but never sends a byte.
private final class SilentListener {
    let descriptor: Int32
    let port: Int

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(descriptor, address, length) == 0 && listen(descriptor, 4) == 0 && getsockname(descriptor, address, &length) == 0
            }
        }
        guard descriptor >= 0, bound else {
            close(descriptor)
            throw DatabaseError.connection("Cannot open a test listener")
        }
        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    deinit { close(descriptor) }
}

@Suite("MySQL handshake timeout")
struct MySQLHandshakeTimeoutTests {
    @Test func silentServerTimesOut() throws {
        let listener = try SilentListener()
        let config = ConnectionConfig(kind: .mysql, host: "127.0.0.1", port: listener.port, user: "root", sslMode: .disable, connectTimeout: 1)
        let connection = MySQLConnection(parameters: ConnectionParameters(config: config, password: ""))
        let began = Date()
        guard case .connection(let message)? = caught({ try connection.connect() }) else {
            Issue.record("Expected a connection error")
            return
        }
        #expect(message.hasPrefix("Timed out after 1 seconds"))
        #expect(Date().timeIntervalSince(began) < 3)
        guard case .notConnected? = caught({ _ = try connection.execute("SELECT 1", rowLimit: nil) }) else {
            Issue.record("Expected notConnected")
            return
        }
    }
}

// MARK: - Live server

/// The local test server from `scripts/dbtest.sh`. These tests are skipped when it is not running.
enum MySQLTestServer {
    static let host = "127.0.0.1"
    static let port = 53306

    static let isAvailable: Bool = {
        let transport = SocketTransport()
        defer { transport.close() }
        return (try? transport.connect(host: host, port: port, timeout: 1)) != nil
    }()

    static func parameters(user: String = "root", password: String = "root", database: String = "foxlume", ssl: SSLMode = .prefer) -> ConnectionParameters {
        let config = ConnectionConfig(kind: .mysql, host: host, port: port, user: user, database: database, sslMode: ssl)
        return ConnectionParameters(config: config, password: password)
    }

    static func connect(user: String = "root", password: String = "root", database: String = "foxlume", ssl: SSLMode = .prefer) throws -> MySQLConnection {
        let connection = MySQLConnection(parameters: parameters(user: user, password: password, database: database, ssl: ssl))
        try connection.connect()
        return connection
    }

    /// A caching_sha2 user that only the authentication-path tests log in with. Other suites log in as root in
    /// parallel, and any such login refills root's cache entry between a flush and the check.
    static let authUser = "fqauth"
    static let authPassword = "fqauthpass"

    /// Creates `authUser` if needed and empties the caching_sha2 cache, so its next login takes the full path.
    static func resetAuthenticationCache() throws {
        let connection = try connect()
        defer { connection.close() }
        _ = try connection.execute("CREATE USER IF NOT EXISTS '\(authUser)'@'%' IDENTIFIED WITH caching_sha2_password BY '\(authPassword)'", rowLimit: nil)
        _ = try connection.execute("GRANT SELECT ON foxlume.* TO '\(authUser)'@'%'", rowLimit: nil)
        _ = try connection.execute("FLUSH PRIVILEGES", rowLimit: nil)
    }

    static func connectAsAuthUser(ssl: SSLMode) throws -> MySQLConnection {
        try connect(user: authUser, password: authPassword, ssl: ssl)
    }
}

/// Serialized: FLUSH PRIVILEGES empties the caching_sha2 cache, so parallel logins would race the path checks.
@Suite("MySQL live server", .serialized, .enabled(if: MySQLTestServer.isAvailable))
struct MySQLLiveTests {
    @Test func createAndDropDatabase() throws {
        let connection = try MySQLTestServer.connect(ssl: .disable)
        defer { connection.close() }
        let objects = DatabaseObjectSQL(kind: .mysql)
        _ = try? connection.execute(try #require(objects.dropDatabase("fq_db_probe")), rowLimit: nil)
        _ = try connection.execute(try #require(objects.createDatabase("fq_db_probe")), rowLimit: nil)
        #expect(try connection.databases().contains("fq_db_probe"))
        _ = try connection.execute(try #require(objects.dropDatabase("fq_db_probe")), rowLimit: nil)
        #expect(try !connection.databases().contains("fq_db_probe"))
    }

    @Test func searchAllRowsMatchesWildcardsLiterally() throws {
        let connection = try MySQLTestServer.connect(ssl: .disable)
        defer { connection.close() }
        _ = try connection.execute("CREATE TEMPORARY TABLE search_probe (id INT, note VARCHAR(40))", rowLimit: nil)
        let values = ["50% off", "500 items", "a_b", "axb", #"C:\temp"#, "Zoe MULLER"].enumerated()
            .map { "(\($0.offset + 1), \(SQLDialect.mysql.quoteString($0.element)))" }.joined(separator: ", ")
        _ = try connection.execute("INSERT INTO search_probe VALUES \(values)", rowLimit: nil)
        func ids(_ text: String) throws -> [String] {
            let condition = TableQuery.anyColumnContains(text, columns: ["id", "note"], dialect: .mysql)
            return try connection.execute("SELECT id FROM search_probe WHERE \(condition) ORDER BY id", rowLimit: nil)[0].rows.map { $0[0].displayString }
        }
        #expect(try ids("50%") == ["1"])
        #expect(try ids("a_b") == ["3"])
        #expect(try ids(#"C:\temp"#) == ["5"])
        // Case folding of non-ASCII letters depends on the database collation, so check ASCII here.
        #expect(try ids("muller") == ["6"])
        #expect(try ids("4") == ["4"])
    }

    @Test func gridEditsCanSetDefaultAndCurrentTimestamp() throws {
        let connection = try MySQLTestServer.connect(ssl: .disable)
        defer { connection.close() }
        _ = try connection.execute("CREATE TEMPORARY TABLE expr_edit (id INT PRIMARY KEY, status VARCHAR(20) DEFAULT 'new', touched DATETIME NULL)", rowLimit: nil)
        _ = try connection.execute("INSERT INTO expr_edit VALUES (1, 'old', NULL)", rowLimit: nil)
        let page = try connection.fetchRows(TableQuery(table: TableRef(name: "expr_edit"), pageSize: 10))
        var changes = PendingChanges()
        changes.setValue(.expression("DEFAULT"), row: 0, column: 1, original: page.rows[0][1])
        changes.setValue(.expression("CURRENT_TIMESTAMP"), row: 0, column: 2, original: page.rows[0][2])
        changes.addInsertion([.value(.text("2")), .value(.expression("DEFAULT")), .value(.expression("CURRENT_TIMESTAMP"))])
        try connection.applyChanges(ChangeBatch(table: TableRef(name: "expr_edit"), columns: page.columns, primaryKey: ["id"], originalRows: page.rows, changes: changes))
        let rows = try connection.execute("SELECT id, status, touched IS NOT NULL FROM expr_edit ORDER BY id", rowLimit: nil)[0].rows
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0[1] == .text("new") })
        #expect(rows.allSatisfy { ["t", "1"].contains($0[2].displayString) })
    }

    @Test func copiedUpdateAndInListRun() throws {
        let connection = try MySQLTestServer.connect(ssl: .disable)
        defer { connection.close() }
        _ = try connection.execute("CREATE TEMPORARY TABLE copy_probe (a INT, b VARCHAR(20), note TEXT, flag BOOLEAN, score DECIMAL(6,2), PRIMARY KEY (a, b))", rowLimit: nil)
        try SQLRowCopyTests.liveRoundTrip(connection, dialect: .mysql, trueText: "1")
    }

    @Test func rowLimitIsAppliedByTheServerAndThenRestored() throws {
        let connection = try MySQLTestServer.connect(ssl: .disable)
        defer { connection.close() }
        _ = try connection.execute("SET SESSION sql_select_limit = 7777", rowLimit: nil)
        let started = Date()
        let results = try connection.execute(
            "WITH RECURSIVE s(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM s WHERE g < 900) SELECT g FROM s; SELECT 42 AS answer",
            rowLimit: 50
        )
        #expect(Date().timeIntervalSince(started) < 2)
        let resultSets = results.filter(\.hasResultSet)
        #expect(resultSets.last?.rows == [[.text("42")]])
        let capped = try #require(resultSets.first)
        #expect(capped.rows.count == 50 && capped.truncated)
        // The session's own value comes back.
        #expect(try connection.execute("SELECT @@SESSION.sql_select_limit", rowLimit: nil).first?.rows == [[.text("7777")]])
        _ = try connection.execute("SET SESSION sql_select_limit = DEFAULT", rowLimit: nil)
    }

    @Test func rowCountBatchesAreNotDisturbedByTheCap() throws {
        let connection = try MySQLTestServer.connect(ssl: .disable)
        defer { connection.close() }
        _ = try connection.execute("CREATE TEMPORARY TABLE cap_probe (x INT)", rowLimit: nil)
        _ = try connection.execute("INSERT INTO cap_probe VALUES (1), (2), (3)", rowLimit: 10)
        #expect(try connection.execute("SELECT ROW_COUNT()", rowLimit: 10).first?.rows == [[.text("3")]])
        #expect(MySQLConnection.returnsCappableRows("/* c */ select 1") && MySQLConnection.returnsCappableRows("(SELECT 1) UNION (SELECT 2)"))
        #expect(!MySQLConnection.returnsCappableRows("UPDATE t SET a = 1") && !MySQLConnection.returnsCappableRows("SELECT FOUND_ROWS()"))
    }

    private func value(_ connection: MySQLConnection, _ sql: String) throws -> CellValue? {
        try connection.execute(sql, rowLimit: nil).last?.rows.first?.first
    }

    @Test func connectsWithTLSAndCachingSHA2() throws {
        let connection = try MySQLTestServer.connect(ssl: .prefer)
        defer { connection.close() }
        #expect(connection.isTLS)
        #expect(connection.serverVersion.hasPrefix("8."))
        #expect(connection.currentDatabase == "foxlume")
        let cipher = try connection.execute("SHOW STATUS LIKE 'Ssl_cipher'", rowLimit: nil)[0].rows[0][1]
        #expect(cipher.textValue?.isEmpty == false)
    }

    @Test func fullAuthenticationWithRSAWithoutTLS() throws {
        try MySQLTestServer.resetAuthenticationCache()
        let first = try MySQLTestServer.connectAsAuthUser(ssl: .disable)
        #expect(!first.isTLS)
        #expect(first.authenticationPath == .fullWithRSA)
        #expect(try value(first, "SELECT CURRENT_USER()")?.textValue?.hasPrefix("\(MySQLTestServer.authUser)@") == true)
        first.close()

        let second = try MySQLTestServer.connectAsAuthUser(ssl: .disable)
        defer { second.close() }
        #expect(second.authenticationPath == .cachedFastPath)
    }

    @Test func fullAuthenticationOverTLS() throws {
        try MySQLTestServer.resetAuthenticationCache()
        let connection = try MySQLTestServer.connectAsAuthUser(ssl: .require)
        defer { connection.close() }
        #expect(connection.isTLS)
        #expect(connection.authenticationPath == .fullOverTLS)
        #expect(try value(connection, "SELECT 1") == .text("1"))
    }

    @Test(arguments: [SSLMode.disable, .prefer])
    func nativePasswordUser(ssl: SSLMode) throws {
        let connection = try MySQLTestServer.connect(user: "native", password: "nativepass", ssl: ssl)
        defer { connection.close() }
        #expect(connection.authenticationPath == .direct)
        #expect(try value(connection, "SELECT CURRENT_USER()")?.textValue?.hasPrefix("native@") == true)
    }

    @Test(arguments: ["root", "native"])
    func wrongPasswordIsAnAuthenticationError(user: String) {
        guard case .authentication(let message)? = caught({ _ = try MySQLTestServer.connect(user: user, password: "wrong", ssl: .disable) }) else {
            Issue.record("Expected an authentication error")
            return
        }
        #expect(message.contains("Access denied"))
    }

    @Test func verifyFullRejectsSelfSignedCertificate() {
        guard case .connection(let message)? = caught({ _ = try MySQLTestServer.connect(ssl: .verifyFull) }) else {
            Issue.record("Expected a TLS failure")
            return
        }
        #expect(message.hasPrefix("TLS handshake failed"))
    }

    @Test func multiStatementBatch() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        let results = try connection.execute(
            "SELECT 1; CREATE TEMPORARY TABLE t(x int); INSERT INTO t VALUES (1),(2); UPDATE t SET x = 3; DELETE FROM t; SELECT 'Zoë ✓'",
            rowLimit: nil
        )
        #expect(results.count == 6)
        #expect(results[0].rows == [[.text("1")]])
        #expect(results[1].affectedRows == 0)
        #expect(results[2].affectedRows == 2)
        #expect(results[2].message == "Affected rows: 2; Records: 2  Duplicates: 0  Warnings: 0")
        #expect(results[3].message == "Affected rows: 2; Rows matched: 2  Changed: 2  Warnings: 0")
        #expect(results[4].affectedRows == 2)
        #expect(results[5].rows == [[.text("Zoë ✓")]])
        #expect(results.allSatisfy { $0.elapsed >= 0 })

        let insert = try connection.execute("CREATE TEMPORARY TABLE tmp_ai(id int AUTO_INCREMENT PRIMARY KEY, v int); INSERT INTO tmp_ai(v) VALUES (5)", rowLimit: nil)
        #expect(insert[1].message == "Affected rows: 1; Last insert ID: 1")
    }

    @Test func errorStopsBatchAndSessionStaysUsable() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        guard case let .server(_, code, _)? = caught({ _ = try connection.execute("SELECT 1; SELECT * FROM nope; SELECT 2", rowLimit: nil) }) else {
            Issue.record("Expected a server error")
            return
        }
        #expect(code == "1146/42S02")
        guard case let .server(_, syntaxCode, _)? = caught({ _ = try connection.execute("SELEC 1", rowLimit: nil) }) else {
            Issue.record("Expected a syntax error")
            return
        }
        #expect(syntaxCode == "1064/42000")
        #expect(try value(connection, "SELECT 2") == .text("2"))
    }

    @Test(arguments: [true, false])
    func decodesTypesDemo(deprecateEOF: Bool) throws {
        let connection = MySQLConnection(parameters: MySQLTestServer.parameters())
        connection.requestsDeprecateEOF = deprecateEOF
        try connection.connect()
        defer { connection.close() }
        #expect(connection.capabilities.contains(.deprecateEOF) == deprecateEOF)

        let result = try connection.execute("SELECT * FROM types_demo ORDER BY id", rowLimit: nil)[0]
        #expect(result.columns.map(\.typeName) == [
            "INT", "SMALLINT", "BIGINT", "FLOAT", "DOUBLE", "DECIMAL", "TINYINT", "DATE", "DATETIME", "JSON", "VARBINARY", "BLOB", "TEXT",
        ])
        #expect(result.columns.map(\.isNumeric) == [true, true, true, true, true, true, true, false, false, false, false, false, false])
        #expect(result.columns.allSatisfy { $0.tableName == "types_demo" })
        #expect(result.rows.count == 2)
        #expect(result.rows[0] == [
            .text("1"), .text("7"), .text("9007199254740993"), .text("1.5"), .text("3.141592653589793"), .text("1234.5678"), .text("1"),
            .text("2026-10-13"), .text("2026-10-13 08:30:00.125"), .text("{\"a\": 1, \"b\": [true, null]}"),
            .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])), .bytes(Data([0x00, 0xFF, 0x10])), .text("It's a \"quote\" \\ backslash"),
        ])
        #expect(result.rows[1] == [.text("2")] + Array(repeating: CellValue.null, count: 12))

        // Multiple results also work without DEPRECATE_EOF.
        let batch = try connection.execute("SELECT 1; SELECT 2", rowLimit: nil)
        #expect(batch.map(\.rows) == [[[.text("1")]], [[.text("2")]]])
    }

    @Test func rowLimitTruncates() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        let results = try connection.execute(
            "SET SESSION cte_max_recursion_depth = 300000; WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 200000) SELECT n FROM s",
            rowLimit: 5
        )
        #expect(results[1].rows.count == 5)
        #expect(results[1].truncated)
        #expect(try value(connection, "SELECT 'after'") == .text("after"))
    }

    @Test func largePacketsSplitInBothDirections() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        let maxAllowed = Int(try value(connection, "SELECT @@max_allowed_packet")?.textValue ?? "") ?? 0
        guard maxAllowed >= 40 * 1024 * 1024 else { return }

        let size = 17_000_000
        let literal = String(repeating: "a", count: size)
        #expect(try value(connection, "SELECT LENGTH('\(literal)')") == .text(String(size)))

        let row = try connection.execute("SELECT REPEAT('x', \(size)) AS big, 1 AS tail", rowLimit: nil)[0].rows[0]
        #expect(row[0].textValue?.utf8.count == size)
        #expect(row[1] == .text("1"))
        #expect(try value(connection, "SELECT 3") == .text("3"))
    }

    @Test func cancelInterruptsRunningQuery() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        TestThreads.after(0.5) { connection.cancel() }
        let began = Date()
        let error = caught {
            _ = try connection.execute(
                "WITH RECURSIVE d(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM d WHERE x < 1000) SELECT COUNT(*) FROM d a, d b, d c, d e",
                rowLimit: nil
            )
        }
        guard case .cancelled? = error else {
            Issue.record("Expected cancellation, got \(String(describing: error))")
            return
        }
        #expect(Date().timeIntervalSince(began) < 3)
        #expect(try value(connection, "SELECT 'still alive'") == .text("still alive"))
    }

    @Test func cancelWithoutRunningQueryDoesNothing() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        connection.cancel()
        #expect(try value(connection, "SELECT 1") == .text("1"))
    }

    @Test func tracksCurrentDatabase() throws {
        let connection = try MySQLTestServer.connect(database: "")
        defer { connection.close() }
        #expect(connection.currentDatabase == nil)
        #expect(try connection.tables(schema: nil).isEmpty)

        _ = try connection.execute("USE foxlume", rowLimit: nil)
        #expect(connection.currentDatabase == "foxlume")
        #expect(try connection.tables(schema: nil).contains { $0.name == "orders" })

        try connection.useDatabase("mysql")
        #expect(connection.currentDatabase == "mysql")
        #expect(try value(connection, "SELECT DATABASE()") == .text("mysql"))

        _ = try connection.execute("select 1;\nuse foxlume", rowLimit: nil)
        #expect(connection.currentDatabase == "foxlume")

        guard case .server? = caught({ try connection.useDatabase("no_such_database_xyz") }) else {
            Issue.record("Expected a server error")
            return
        }
        #expect(connection.currentDatabase == "foxlume")
    }

    @Test func noBackslashEscapesUpdatesDialect() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        let tricky = "a\\b'c\\'"
        #expect(connection.dialect.backslashEscapes)
        #expect(try value(connection, "SELECT \(connection.dialect.quoteString(tricky))") == .text(tricky))

        _ = try connection.execute("SET SESSION sql_mode = CONCAT(@@sql_mode, ',NO_BACKSLASH_ESCAPES')", rowLimit: nil)
        #expect(!connection.dialect.backslashEscapes)
        #expect(try value(connection, "SELECT \(connection.dialect.quoteString(tricky))") == .text(tricky))

        _ = try connection.execute("SET SESSION sql_mode = DEFAULT", rowLimit: nil)
        #expect(connection.dialect.backslashEscapes)
    }

    @Test func metadata() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        #expect(try connection.databases().contains("foxlume"))
        #expect(try connection.schemas().isEmpty)
        #expect(connection.defaultSchema == nil)

        let tables = try connection.tables(schema: nil)
        let byName = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) })
        #expect(tables.map(\.name) == tables.map(\.name).sorted())
        #expect(byName["orders"]?.kind == .table)
        #expect(byName["orders"]?.estimatedRows != nil)
        #expect(byName["order_summary"]?.kind == .view)
        #expect(byName["order_summary"]?.comment == nil)
        #expect(byName["users"]?.comment == "Application users")
        #expect(try connection.tables(schema: "foxlume").first?.ref.schema == "foxlume")

        let orders = try connection.structure(of: TableRef(name: "orders"))
        #expect(orders.columns.map(\.name) == ["id", "user_id", "status", "total", "currency", "shipping_address", "notes", "paid_at"])
        #expect(orders.columns[0].dataType == "bigint unsigned")
        #expect(orders.columns[0].isAutoIncrement)
        #expect(orders.columns[0].extra == "auto_increment")
        #expect(orders.columns[2].defaultValue == "pending")
        #expect(orders.columns[5].isNullable)
        #expect(orders.primaryKey == ["id"])
        #expect(orders.indexes.first?.isPrimary == true)
        #expect(orders.indexes.contains { $0.name == "orders_user_id_idx" && $0.columns == ["user_id"] && !$0.isUnique })
        let fk = try #require(orders.foreignKeys.first)
        #expect(fk.name == "orders_user_fk")
        #expect(fk.columns == ["user_id"])
        #expect(fk.referencedTable == TableRef(name: "users"))
        #expect(fk.referencedColumns == ["id"])
        #expect(fk.onDelete == "CASCADE")

        let users = try connection.structure(of: TableRef(name: "users"))
        #expect(users.indexes.contains { $0.name == "email" && $0.isUnique })

        let noKey = try connection.structure(of: TableRef(name: "no_pk_log"))
        #expect(noKey.primaryKey.isEmpty)
        #expect(noKey.indexes.isEmpty)

        let ddl = try connection.ddl(of: TableRef(name: "orders"))
        #expect(ddl.hasPrefix("CREATE TABLE `orders`"))
        #expect(ddl.hasSuffix(";"))
        let viewDDL = try connection.ddl(of: TableRef(name: "order_summary"))
        #expect(viewDDL.contains("VIEW `order_summary` AS"))
        #expect(viewDDL.hasSuffix(";"))
    }

    @Test func idleTimeoutClosesConnectionWithServerMessage() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        _ = try connection.execute("SET SESSION wait_timeout = 1", rowLimit: nil)
        Thread.sleep(forTimeInterval: 2.5)
        guard case .connection(let message)? = caught({ _ = try connection.execute("SELECT 1", rowLimit: nil) }) else {
            Issue.record("Expected a connection error")
            return
        }
        #expect(message.contains("inactivity"))
        guard case .notConnected? = caught({ _ = try connection.execute("SELECT 1", rowLimit: nil) }) else {
            Issue.record("Expected the connection to be closed")
            return
        }
    }

    @Test func transportFailureClosesConnection() throws {
        let victim = try MySQLTestServer.connect()
        defer { victim.close() }
        let id = try #require(try value(victim, "SELECT CONNECTION_ID()")?.textValue)
        let killer = try MySQLTestServer.connect()
        _ = try killer.execute("KILL CONNECTION \(id)", rowLimit: nil)
        killer.close()

        var failures: [DatabaseError] = []
        for _ in 0..<3 {
            if let error = caught({ _ = try victim.execute("SELECT 1", rowLimit: nil) }) {
                failures.append(error)
            }
        }
        #expect(failures.count == 3)
        guard case .notConnected? = failures.last else {
            Issue.record("Expected the connection to be closed, got \(failures)")
            return
        }
    }
}


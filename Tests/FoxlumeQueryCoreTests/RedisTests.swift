import Darwin
import Foundation
import Testing
@testable import FoxlumeQueryCore

// MARK: - Helpers

/// Serves scripted server bytes to a RESP reader.
private final class ScriptedRedisChannel: RedisByteChannel {
    private let incoming: [UInt8]
    private var offset = 0

    init(_ text: String) {
        incoming = Array(text.utf8)
    }

    init(bytes: [UInt8]) {
        incoming = bytes
    }

    var isDrained: Bool { offset == incoming.count }

    func read(exactly count: Int) throws -> [UInt8] {
        guard offset + count <= incoming.count else { throw DatabaseError.connection("The server closed the connection") }
        defer { offset += count }
        return Array(incoming[offset..<(offset + count)])
    }

    func write(_ bytes: [UInt8]) throws {}
}

private func decode(_ text: String) throws -> RESPValue {
    try RESPReader(channel: ScriptedRedisChannel(text)).read()
}

private func bulk(_ text: String) -> RESPValue { .bulk(Data(text.utf8)) }

private func strings(_ arguments: [Data]) -> [String] {
    arguments.map { String(decoding: $0, as: UTF8.self) }
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

/// Accepts TCP connections and never answers.
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
                bind(descriptor, address, length) == 0 && listen(descriptor, 8) == 0 && getsockname(descriptor, address, &length) == 0
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

// MARK: - Command parsing (no server needed)

@Suite("Redis command parser")
struct RedisCommandParserTests {
    private func tokens(_ line: String) throws -> [String] {
        strings(try RedisCommandParser.tokenize(line))
    }

    @Test func splitsOnWhitespace() throws {
        #expect(try tokens("  GET   user:1  ") == ["GET", "user:1"])
        #expect(try tokens("HSET h\tf v") == ["HSET", "h", "f", "v"])
        #expect(try tokens("") == [])
    }

    @Test func doubleQuotesUnderstandEscapes() throws {
        #expect(try tokens(#"SET k "hello world""#) == ["SET", "k", "hello world"])
        #expect(try tokens(#"SET k "a\nb\tc\rd""#) == ["SET", "k", "a\nb\tc\rd"])
        #expect(try RedisCommandParser.tokenize(#"SET k "\b\a""#)[2] == Data([0x08, 0x07]))
        #expect(try tokens(#"SET k "say \"hi\" \\ end""#) == ["SET", "k", #"say "hi" \ end"#])
        #expect(try tokens(#"SET k "\q""#) == ["SET", "k", "q"])
    }

    @Test func hexEscapesProduceRawBytes() throws {
        let arguments = try RedisCommandParser.tokenize(#"SET k "\x41\x42\xff\x00""#)
        #expect(arguments[2] == Data([0x41, 0x42, 0xFF, 0x00]))
        // Not two hex digits: the backslash is dropped, as redis-cli does.
        #expect(try tokens(#"SET k "\xZZ""#) == ["SET", "k", "xZZ"])
    }

    @Test func singleQuotesOnlyUnderstandEscapedQuote() throws {
        #expect(try tokens(#"SET k 'it\'s'"#) == ["SET", "k", "it's"])
        #expect(try tokens(#"SET k 'a\nb'"#) == ["SET", "k", #"a\nb"#])
        #expect(try tokens(#"SET k 'say "hi"'"#) == ["SET", "k", #"say "hi""#])
    }

    @Test func emptyQuotedArgument() throws {
        #expect(try tokens(#"SET k """#) == ["SET", "k", ""])
        #expect(try tokens("SET k ''") == ["SET", "k", ""])
    }

    @Test func quoteInsideWordStartsQuotedPart() throws {
        #expect(try tokens(#"SET k foo"bar baz""#) == ["SET", "k", "foobar baz"])
    }

    @Test func keepsUTF8() throws {
        #expect(try tokens(#"SET greeting "Hello from Foxlume Query""#) == ["SET", "greeting", "Hello from Foxlume Query"])
        #expect(try tokens("SET café crème") == ["SET", "café", "crème"])
    }

    @Test(arguments: [#"SET k "abc"def"#, "SET k 'abc'def", #"SET k "abc"#, "SET k 'abc", #"GET "unterminated\""#])
    func rejectsBadQuoting(_ line: String) {
        guard case .server? = caught({ _ = try RedisCommandParser.tokenize(line) }) else {
            Issue.record("Expected a parse error for \(line)")
            return
        }
    }

    @Test func databasePrefix() throws {
        let command = try RedisCommandParser.parse("DB 2 GET k")
        #expect(command.database == 2)
        #expect(strings(command.arguments) == ["GET", "k"])
        #expect(try RedisCommandParser.parse("db 1 hgetall user:1").database == 1)
        #expect(try RedisCommandParser.parse("GET k").database == nil)
        #expect(caught { _ = try RedisCommandParser.parse("DB x GET k") } != nil)
        #expect(caught { _ = try RedisCommandParser.parse("DB 1") } != nil)
        #expect(caught { _ = try RedisCommandParser.parse("   ") } != nil)
    }

    @Test func databaseNames() {
        #expect(RedisCommandParser.databaseIndex("db3") == 3)
        #expect(RedisCommandParser.databaseIndex("DB0") == 0)
        #expect(RedisCommandParser.databaseIndex("7") == 7)
        #expect(RedisCommandParser.databaseIndex("users") == nil)
        #expect(RedisCommandParser.databaseIndex("db-1") == nil)
    }

    @Test func classifiesCommands() throws {
        #expect(RedisCommandParser.isBlocking(try RedisCommandParser.parse("BLPOP q 30")))
        #expect(RedisCommandParser.isBlocking(try RedisCommandParser.parse("XREAD BLOCK 0 STREAMS s $")))
        #expect(!RedisCommandParser.isBlocking(try RedisCommandParser.parse("XREAD STREAMS s 0")))
        #expect(!RedisCommandParser.isBlocking(try RedisCommandParser.parse("GET k")))
        #expect(RedisCommandParser.scriptKind(try RedisCommandParser.parse("EVAL \"return 1\" 0")) == .script)
        #expect(RedisCommandParser.scriptKind(try RedisCommandParser.parse("FCALL f 0")) == .function)
    }

    @Test func routingKeys() throws {
        func key(_ line: String) throws -> String? {
            RedisCommandParser.routingKey(try RedisCommandParser.parse(line)).map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(try key("GET user:1") == "user:1")
        #expect(try key("PING") == nil)
        #expect(try key("SCAN 0 MATCH *") == nil)
        #expect(try key("EVAL \"return 1\" 1 k1 arg") == "k1")
        #expect(try key("EVAL \"return 1\" 0") == nil)
        #expect(try key("XREAD COUNT 2 STREAMS s1 s2 0 0") == "s1")
        #expect(try key("OBJECT ENCODING k") == "k")
        #expect(try key("ZUNION 2 a b") == "a")
    }
}

// MARK: - RESP (no server needed)

@Suite("Redis RESP codec")
struct RedisRESPTests {
    @Test func resp2Scalars() throws {
        #expect(try decode("+OK\r\n") == .simple("OK"))
        #expect(try decode("-ERR bad thing\r\n") == .error("ERR bad thing"))
        #expect(try decode(":42\r\n") == .integer(42))
        #expect(try decode(":-3\r\n") == .integer(-3))
        #expect(try decode("$5\r\nhello\r\n") == bulk("hello"))
        #expect(try decode("$0\r\n\r\n") == bulk(""))
        #expect(try decode("$-1\r\n") == .null)
        #expect(try decode("*-1\r\n") == .null)
    }

    @Test func bulkStringsAreBinarySafe() throws {
        let bytes: [UInt8] = Array("$5\r\n".utf8) + [0x00, 0xFF, 0x0D, 0x0A, 0x10] + [0x0D, 0x0A]
        let value = try RESPReader(channel: ScriptedRedisChannel(bytes: bytes)).read()
        #expect(value == .bulk(Data([0x00, 0xFF, 0x0D, 0x0A, 0x10])))
        #expect(value.cell == .bytes(Data([0x00, 0xFF, 0x0D, 0x0A, 0x10])))
        #expect(bulk("Café crème").cell == .text("Café crème"))
    }

    @Test func nestedArrays() throws {
        let value = try decode("*3\r\n*2\r\n:1\r\n$1\r\na\r\n*0\r\n$-1\r\n")
        #expect(value == .array([.array([.integer(1), bulk("a")]), .array([]), .null]))
        #expect(RedisResults.generic(value, rowLimit: nil).rows == [[.text(#"[1,"a"]"#)], [.text("[]")], [.null]])
    }

    @Test func resp3Types() throws {
        let map = try decode("%2\r\n+first\r\n:1\r\n$6\r\nsecond\r\n:2\r\n")
        #expect(map == .map([.simple("first"), .integer(1), bulk("second"), .integer(2)]))
        #expect(map.dictionary["second"] == .integer(2))
        #expect(try decode("~2\r\n+a\r\n+b\r\n") == .set([.simple("a"), .simple("b")]))
        #expect(try decode(",3.14\r\n") == .double(3.14))
        #expect(try decode(",inf\r\n") == .double(.infinity))
        #expect(try decode(",-inf\r\n") == .double(-.infinity))
        #expect(try decode(",nan\r\n").string == "nan")
        #expect(try decode("#t\r\n") == .boolean(true))
        #expect(try decode("#f\r\n") == .boolean(false))
        #expect(try decode("(3492890328409238509324850943850943825024385\r\n") == .bigNumber("3492890328409238509324850943850943825024385"))
        #expect(try decode("_\r\n") == .null)
        #expect(try decode("=15\r\ntxt:Some string\r\n") == bulk("Some string"))
        #expect(try decode("!21\r\nSYNTAX invalid syntax\r\n") == .error("SYNTAX invalid syntax"))
    }

    @Test func resp3NestedMapsBecomeJSON() throws {
        let value = try decode("*1\r\n%2\r\n+name\r\n$2\r\nan\r\n+scores\r\n*2\r\n,1.5\r\n_\r\n")
        #expect(RedisResults.generic(value, rowLimit: nil).rows == [[.text(#"{"name":"an","scores":[1.5,null]}"#)]])
    }

    @Test func attributesAreSkipped() throws {
        let value = try decode("|1\r\n+key-popularity\r\n%2\r\n$1\r\na\r\n,0.1923\r\n$1\r\nb\r\n,0.0012\r\n*2\r\n:2039123\r\n:9543892\r\n")
        #expect(value == .array([.integer(2039123), .integer(9543892)]))
    }

    @Test func pushMessagesAreSkippedWhenReadingReplies() throws {
        let channel = ScriptedRedisChannel(">3\r\n$7\r\nmessage\r\n$3\r\nch1\r\n$2\r\nhi\r\n+OK\r\n")
        #expect(try RESPReader(channel: channel).readReply() == .simple("OK"))
        #expect(channel.isDrained)
        #expect(try decode(">1\r\n+x\r\n") == .push([.simple("x")]))
    }

    @Test func malformedReplies() {
        guard case .protocolViolation? = caught({ _ = try decode("?what\r\n") }) else {
            Issue.record("Expected a protocol violation for an unknown type byte")
            return
        }
        guard case .protocolViolation? = caught({ _ = try decode("$3\r\nabcde\r\n") }) else {
            Issue.record("Expected a protocol violation for a bad bulk terminator")
            return
        }
        guard case .connection? = caught({ _ = try decode("$5\r\nhel") }) else {
            Issue.record("Expected a connection error for a truncated reply")
            return
        }
        let deep = String(repeating: "*1\r\n", count: 200) + ":1\r\n"
        guard case .protocolViolation? = caught({ _ = try decode(deep) }) else {
            Issue.record("Expected the nesting limit to apply")
            return
        }
    }

    @Test func encodesCommandsAsBulkArrays() {
        let bytes = RESPEncoder.command(["SET", "k", "Cé"])
        #expect(String(decoding: bytes, as: UTF8.self) == "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$3\r\nCé\r\n")
        #expect(RESPEncoder.command([Data([0x00, 0xFF])]) == Array("*1\r\n$2\r\n".utf8) + [0x00, 0xFF, 0x0D, 0x0A])
    }

    @Test func doublesPrintLikeRedisCli() {
        #expect(RESPValue.format(1500) == "1500")
        #expect(RESPValue.format(0.5) == "0.5")
        #expect(RESPValue.format(-2.25) == "-2.25")
        #expect(RESPValue.format(.infinity) == "inf")
    }
}

// MARK: - Cluster slots (no server needed)

@Suite("Redis cluster slots")
struct RedisClusterSlotTests {
    @Test func crc16MatchesReferenceVector() {
        #expect(RedisKeySlot.crc16(Data("123456789".utf8)) == 0x31C3)
    }

    /// Expected slots come from `CLUSTER KEYSLOT` on a live cluster.
    @Test func slotsMatchRedis() {
        #expect(RedisKeySlot.slot(for: "foo") == 12182)
        #expect(RedisKeySlot.slot(for: "123456789") == 12739)
        #expect(RedisKeySlot.slot(for: "somekey") == 11058)
        #expect(RedisKeySlot.slot(for: "hello") == 866)
        #expect(RedisKeySlot.slot(for: "{user1000}.following") == 3443)
    }

    @Test func hashTags() {
        #expect(RedisKeySlot.slot(for: "{user1000}.following") == RedisKeySlot.slot(for: "{user1000}.followers"))
        #expect(RedisKeySlot.slot(for: "foo{bar}{zap}") == RedisKeySlot.slot(for: "bar"))
        // An empty tag hashes the whole key.
        #expect(RedisKeySlot.hashTag(Data("foo{}{bar}".utf8)) == Data("foo{}{bar}".utf8))
        #expect(RedisKeySlot.hashTag(Data("foo{{bar}}zap".utf8)) == Data("{bar".utf8))
        #expect(RedisKeySlot.hashTag(Data("no-close{tag".utf8)) == Data("no-close{tag".utf8))
    }

    @Test func parsesClusterSlots() throws {
        func node(_ host: String, _ port: Int64) -> RESPValue { .array([bulk(host), .integer(port), bulk("id-\(port)")]) }
        let reply = RESPValue.array([
            .array([.integer(5461), .integer(10922), node("10.0.0.2", 7001)]),
            .array([.integer(0), .integer(5460), node("10.0.0.1", 7000), node("10.0.0.4", 7003)]),
            .array([.integer(10923), .integer(16383), node("", 7002)]),
        ])
        let topology = try #require(RedisClusterTopology.fromSlots(reply, answeredBy: RedisEndpoint(host: "seed", port: 7000)))
        #expect(topology.masters.map(\.description) == ["10.0.0.1:7000", "10.0.0.2:7001", "seed:7002"])
        #expect(topology.owner(of: 0)?.port == 7000)
        #expect(topology.owner(of: 5461)?.port == 7001)
        #expect(topology.owner(of: RedisKeySlot.slot(for: "foo"))?.port == 7002)
    }

    @Test func parsesClusterShards() throws {
        func shard(_ start: Int64, _ end: Int64, _ port: Int64) -> RESPValue {
            .map([
                bulk("slots"), .array([.integer(start), .integer(end)]),
                bulk("nodes"), .array([
                    .map([bulk("id"), bulk("r\(port)"), bulk("port"), .integer(port + 100), bulk("ip"), bulk("127.0.0.1"),
                          bulk("role"), bulk("replica"), bulk("health"), bulk("online")]),
                    .map([bulk("id"), bulk("m\(port)"), bulk("port"), .integer(port), bulk("ip"), bulk("127.0.0.1"),
                          bulk("role"), bulk("master"), bulk("health"), bulk("online")]),
                ]),
            ])
        }
        let reply = RESPValue.array([shard(8192, 16383, 7001), shard(0, 8191, 7000)])
        let topology = try #require(RedisClusterTopology.fromShards(reply, answeredBy: RedisEndpoint(host: "seed", port: 7000)))
        #expect(topology.masters.map(\.port) == [7000, 7001])
        #expect(topology.owner(of: 8191)?.port == 7000)
        #expect(topology.owner(of: 8192)?.port == 7001)
    }

    @Test func parsesRedirects() throws {
        let moved = try #require(RedisRedirect("MOVED 3999 127.0.0.1:6381"))
        #expect(moved.kind == .moved)
        #expect(moved.slot == 3999)
        #expect(moved.endpoint == RedisEndpoint(host: "127.0.0.1", port: 6381))
        let ask = try #require(RedisRedirect("ASK 12 ::1:7000"))
        #expect(ask.kind == .ask)
        #expect(ask.endpoint == RedisEndpoint(host: "::1", port: 7000))
        #expect(RedisRedirect("ERR something") == nil)
        #expect(RedisRedirect("MOVED x y") == nil)
    }

    @Test func compositeScanCursor() {
        let masters = [RedisEndpoint(host: "redis-a.local", port: 7000), RedisEndpoint(host: "127.0.0.1", port: 7001)]
        #expect(RedisClusterCursor.decode("0", masters: masters) == .node(index: 0, cursor: "0"))
        let next = RedisClusterCursor.advance(index: 0, nodeCursor: "17", masters: masters)
        #expect(next == "redis-a.local:7000-17")
        #expect(RedisClusterCursor.decode(next, masters: masters) == .node(index: 0, cursor: "17"))
        #expect(RedisClusterCursor.advance(index: 0, nodeCursor: "0", masters: masters) == "127.0.0.1:7001-0")
        #expect(RedisClusterCursor.advance(index: 1, nodeCursor: "0", masters: masters) == "0")
    }

    @Test func endpoints() {
        #expect(RedisEndpoint(parsing: "cache.local:6380", defaultPort: 26379) == RedisEndpoint(host: "cache.local", port: 6380))
        #expect(RedisEndpoint(parsing: "cache.local", defaultPort: 26379) == RedisEndpoint(host: "cache.local", port: 26379))
        #expect(RedisEndpoint(parsing: "[::1]:26380", defaultPort: 26379) == RedisEndpoint(host: "::1", port: 26380))
        #expect(RedisEndpoint.list("a:1, b:2;c", defaultPort: 9) == [
            RedisEndpoint(host: "a", port: 1), RedisEndpoint(host: "b", port: 2), RedisEndpoint(host: "c", port: 9),
        ])
    }
}

// MARK: - Result grids and save plans (no server needed)

@Suite("Redis results")
struct RedisResultTests {
    private func command(_ line: String) throws -> RedisCommand { try RedisCommandParser.parse(line) }

    @Test func hashGridIsTheSameForRESP2AndRESP3() throws {
        let resp2 = RESPValue.array([bulk("name"), bulk("An"), bulk("visits"), bulk("12")])
        let resp3 = RESPValue.map([bulk("name"), bulk("An"), bulk("visits"), bulk("12")])
        for reply in [resp2, resp3] {
            let result = RedisResults.format(try command("HGETALL user:1"), reply: reply, rowLimit: nil)
            #expect(result.columns.map(\.name) == ["Field", "Value"])
            #expect(result.rows == [[.text("name"), .text("An")], [.text("visits"), .text("12")]])
        }
    }

    @Test func scoresAreTheSameForRESP2AndRESP3() throws {
        let resp2 = RESPValue.array([bulk("alice"), bulk("980"), bulk("bob"), bulk("2100.5")])
        let resp3 = RESPValue.array([.array([bulk("alice"), .double(980)]), .array([bulk("bob"), .double(2100.5)])])
        for reply in [resp2, resp3] {
            let result = RedisResults.format(try command("ZRANGE leaderboard 0 -1 WITHSCORES"), reply: reply, rowLimit: nil)
            #expect(result.columns.map(\.name) == ["Member", "Score"])
            #expect(result.rows == [[.text("alice"), .text("980")], [.text("bob"), .text("2100.5")]])
        }
        let members = RedisResults.format(try command("ZRANGE leaderboard 0 -1"), reply: .array([bulk("alice")]), rowLimit: nil)
        #expect(members.columns.map(\.name) == ["Member"])
    }

    @Test func typedGrids() throws {
        let list = RedisResults.format(try command("LRANGE q 2 3"), reply: .array([bulk("c"), bulk("d")]), rowLimit: nil, listStart: 2)
        #expect(list.rows == [[.text("2"), .text("c")], [.text("3"), .text("d")]])

        let stream = RedisResults.format(try command("XRANGE s - +"), reply: .array([
            .array([bulk("1-0"), .array([bulk("order"), bulk("1001"), bulk("status"), bulk("paid")])]),
        ]), rowLimit: nil)
        #expect(stream.columns.map(\.name) == ["ID", "Fields"])
        #expect(stream.rows == [[.text("1-0"), .text("order=1001, status=paid")]])

        let get = RedisResults.format(try command("GET k"), reply: .null, rowLimit: nil)
        #expect(get.columns.map(\.name) == ["Key", "Value"])
        #expect(get.rows == [[.text("k"), .null]])

        let ttl = RedisResults.format(try command("TTL k"), reply: .integer(-1), rowLimit: nil)
        #expect(ttl.columns.map(\.name) == ["Key", "TTL"])

        let config = RedisResults.format(try command("CONFIG GET *memory*"), reply: .map([bulk("maxmemory"), bulk("0"), bulk("hash-max"), bulk("1")]), rowLimit: nil)
        #expect(config.columns.map(\.name) == ["Parameter", "Value"])
        #expect(config.rows.first == [.text("hash-max"), .text("1")])

        let deleted = RedisResults.format(try command("DEL a b"), reply: .integer(2), rowLimit: nil)
        #expect(deleted.columns.map(\.name) == ["deleted"])
        #expect(deleted.affectedRows == 2)

        #expect(RedisResults.format(try command("SET k v"), reply: .simple("OK"), rowLimit: nil).message == "OK")
        #expect(RedisResults.format(try command("HGETALL k"), reply: .simple("QUEUED"), rowLimit: nil).message == "QUEUED")
        #expect(RedisResults.format(try command("PING"), reply: .simple("PONG"), rowLimit: nil).rows == [[.text("PONG")]])

        let scan = RedisResults.format(try command("HSCAN h 0"), reply: .array([bulk("0"), .array([bulk("f"), bulk("v")])]), rowLimit: nil)
        #expect(scan.message == "Next cursor: 0")
        #expect(scan.rows == [[.text("f"), .text("v")]])

        let generic = RedisResults.generic(.map([bulk("server"), bulk("redis"), bulk("proto"), .integer(3)]), rowLimit: nil)
        #expect(generic.columns.map(\.name) == ["field", "value"])
    }

    @Test func rowLimitTruncates() throws {
        let result = RedisResults.format(try command("SMEMBERS s"), reply: .set([bulk("a"), bulk("b"), bulk("c")]), rowLimit: 2)
        #expect(result.rows.count == 2)
        #expect(result.truncated)
    }

    @Test func infoGridHasSections() throws {
        let text = "# Server\r\nredis_version:8.10.2\r\nredis_mode:standalone\r\n\r\n# Keyspace\r\ndb0:keys=12,expires=2,avg_ttl=0\r\ndb3:keys=5,expires=0,avg_ttl=0\r\n"
        let result = RedisResults.format(try command("INFO"), reply: bulk(text), rowLimit: nil)
        #expect(result.columns.map(\.name) == ["Section", "Key", "Value"])
        #expect(result.rows.first == [.text("Server"), .text("redis_version"), .text("8.10.2")])
        #expect(result.rows.last == [.text("Keyspace"), .text("db3"), .text("keys=5,expires=0,avg_ttl=0")])
        #expect(RedisInfo.keyCounts(text) == [0: 12, 3: 5])
    }

    @Test func serverIdentification() {
        let redis = RedisServerInfo(info: "# Server\r\nredis_version:8.10.2\r\nredis_mode:cluster\r\n")
        #expect(redis.displayVersion == "8.10.2")
        #expect(redis.mode == "cluster")
        #expect(redis.compatibleMajor == 8)
        let valkey = RedisServerInfo(info: "# Server\r\nredis_version:7.2.4\r\nserver_name:valkey\r\nvalkey_version:8.0.1\r\nredis_mode:standalone\r\n")
        #expect(valkey.displayVersion == "8.0.1 (Valkey)")
        #expect(valkey.compatibleMajor == 7)
        let keydb = RedisServerInfo(info: "# Server\r\nredis_version:6.3.4\r\nexecutable:/usr/local/bin/keydb-server\r\n")
        #expect(keydb.displayVersion == "6.3.4 (KeyDB)")
    }

    @Test func serverErrorsKeepTheirCode() {
        guard case let .server(message, code, _) = RedisResults.serverError("WRONGTYPE Operation against a key holding the wrong kind of value") else {
            Issue.record("Expected a server error")
            return
        }
        #expect(code == "WRONGTYPE")
        #expect(message == "Operation against a key holding the wrong kind of value")
        guard case let .server(_, plainCode, _) = RedisResults.serverError("unknown failure") else { return }
        #expect(plainCode == nil)
    }

    // MARK: Save plans

    private let columns = RedisResults.keyColumns(table: "db0")
    private let rows: [[CellValue]] = [
        [.text("s1"), .text("STRING"), .text("50"), .text("3"), .text("abc")],
        [.text("h1"), .text("HASH"), .text("60"), .text("1"), .text(#"{"f":"v"}"#)],
        [.bytes(Data([0xFF, 0x01])), .text("STRING"), .text("-1"), .text("1"), .text("x")],
    ]

    private func plan(_ changes: PendingChanges, keepTTL: Bool = true) throws -> RedisSavePlan {
        try RedisSavePlan(batch: ChangeBatch(table: TableRef(name: "db0"), columns: columns, primaryKey: ["Key"], originalRows: rows, changes: changes), keepTTL: keepTTL)
    }

    @Test func savePlanForEdits() throws {
        var changes = PendingChanges()
        changes.setValue(.text("s2"), row: 0, column: 0, original: rows[0][0])
        changes.setValue(.text("-1"), row: 0, column: 2, original: rows[0][2])
        changes.setValue(.text("new value"), row: 0, column: 4, original: rows[0][4])
        changes.setValue(.null, row: 1, column: 2, original: rows[1][2])
        changes.markDeleted(rows: [2])
        changes.addInsertion([.value(.text("h2")), .value(.text("HASH")), .value(.text("100")), .useDefault, .value(.text(#"{"b":2,"a":"x"}"#))])
        changes.addInsertion([.value(.text("z1")), .value(.text("zset")), .useDefault, .useDefault, .value(.text("m"))])
        changes.addInsertion([.value(.text("h3")), .value(.text("hash")), .useDefault, .useDefault, .value(.text("plain"))])
        let plan = try plan(changes)
        #expect(plan.deletions == [Data([0xFF, 0x01])])
        #expect(plan.writes.map { strings($0.arguments) } == [
            ["RENAME", "s1", "s2"],
            ["SET", "s2", "new value", "KEEPTTL"],
            ["PERSIST", "s2"],
            ["PERSIST", "h1"],
            ["HSET", "h2", "a", "x", "b", "2"],
            ["EXPIRE", "h2", "100"],
            ["ZADD", "z1", "0", "m"],
            ["HSET", "h3", "value", "plain"],
        ])
        #expect(plan.writes[1].key == Data("s2".utf8))
    }

    @Test func savePlanWithoutKeepTTLStillOrdersValueBeforeTTL() throws {
        var changes = PendingChanges()
        changes.setValue(.text("30"), row: 0, column: 2, original: rows[0][2])
        changes.setValue(.text("v"), row: 0, column: 4, original: rows[0][4])
        let plan = try plan(changes, keepTTL: false)
        #expect(plan.writes.map { strings($0.arguments) } == [["SET", "s1", "v"], ["EXPIRE", "s1", "30"]])
    }

    @Test func savePlanRefusals() {
        func refusal(_ edit: (inout PendingChanges) -> Void) -> String? {
            var changes = PendingChanges()
            edit(&changes)
            guard case .unsupported(let message)? = caught({ _ = try plan(changes) }) else { return nil }
            return message
        }
        #expect(refusal { $0.setValue(.text("{}"), row: 1, column: 4, original: rows[1][4]) }?.contains("hash key cannot be edited") == true)
        #expect(refusal { $0.setValue(.null, row: 0, column: 4, original: rows[0][4]) }?.contains("NULL") == true)
        #expect(refusal { $0.setValue(.text("0"), row: 0, column: 2, original: rows[0][2]) }?.contains("TTL") == true)
        #expect(refusal { $0.setValue(.text("9"), row: 0, column: 3, original: rows[0][3]) }?.contains("Length") == true)
        #expect(refusal { $0.addInsertion([.value(.text("s")), .value(.text("stream")), .useDefault, .useDefault, .value(.text("x"))]) }?.contains("stream key cannot be added") == true)
        #expect(refusal { $0.addInsertion([.useDefault, .value(.text("string")), .useDefault, .useDefault, .value(.text("x"))]) }?.contains("needs a name") == true)
    }
}

// MARK: - Live server

/// The local test server from `scripts/dbtest.sh`. These tests are skipped when it is not running.
enum RedisTestServer {
    static let host = "127.0.0.1"
    static let port = 56379
    static let password = "redispass"

    static func reachable(_ port: Int) -> Bool {
        let transport = SocketTransport()
        defer { transport.close() }
        return (try? transport.connect(host: host, port: port, timeout: 1)) != nil
    }

    static let isAvailable = reachable(port)

    static func config(port: Int = port, user: String = "", database: String = "", ssl: SSLMode = .disable, timeout: Int = 5, options: [ConnectionOption: String] = [:]) -> ConnectionConfig {
        var config = ConnectionConfig(kind: .redis, host: host, port: port, user: user, database: database, sslMode: ssl, connectTimeout: timeout)
        for (key, value) in options { config.setOption(key, value) }
        return config
    }

    static func connect(port: Int = port, user: String = "", password: String = password, database: String = "", ssl: SSLMode = .disable, options: [ConnectionOption: String] = [:], resp3: Bool = true) throws -> RedisConnection {
        let connection = RedisConnection(parameters: ConnectionParameters(config: config(port: port, user: user, database: database, ssl: ssl, options: options), password: password))
        connection.preferRESP3 = resp3
        try connection.connect()
        return connection
    }

    /// A key prefix no other test uses.
    static func scratchPrefix() -> String {
        "tmp:fqtest:\(UUID().uuidString.prefix(8)):"
    }
}

private extension RedisConnection {
    func run(_ text: String, rowLimit: Int? = nil) throws -> [StatementResult] {
        try execute(text, rowLimit: rowLimit)
    }

    func one(_ text: String, rowLimit: Int? = nil) throws -> StatementResult {
        try execute(text, rowLimit: rowLimit).last ?? StatementResult()
    }

    func value(_ text: String) throws -> CellValue? {
        try one(text).rows.first?.last
    }

    /// Deletes every key under `prefix` in the current database.
    func dropKeys(_ prefix: String) {
        guard let keys = try? one("KEYS \(prefix)*").rows.compactMap({ $0.first?.textValue }), !keys.isEmpty else { return }
        _ = try? run("DEL " + keys.map { "\"\($0)\"" }.joined(separator: " "))
    }
}

@Suite("Redis live server", .serialized, .enabled(if: RedisTestServer.isAvailable))
struct RedisLiveTests {
    @Test func connectsWithRESP3AndDefaultUser() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        #expect(connection.protocolVersion == 3)
        #expect(connection.serverVersion.first?.isNumber == true)
        #expect(connection.currentDatabase == "db0")
        #expect(!connection.isTLS)
        #expect(try connection.value("PING") == .text("PONG"))
    }

    @Test func connectsWithACLUser() throws {
        let connection = try RedisTestServer.connect(user: "easy", password: "easypass")
        defer { connection.close() }
        #expect(try connection.value("ACL WHOAMI") == .text("easy"))
    }

    @Test func fallsBackToRESP2WithTheSameGrids() throws {
        let resp2 = try RedisTestServer.connect(resp3: false)
        let resp3 = try RedisTestServer.connect()
        defer {
            resp2.close()
            resp3.close()
        }
        #expect(resp2.protocolVersion == 2)
        for command in ["HGETALL user:1", "ZRANGE leaderboard 0 -1 WITHSCORES", "XRANGE events:orders - +", "SMEMBERS tags:post:1", "CONFIG GET maxmemory", "SCAN 0 MATCH user:* COUNT 100"] {
            let left = try resp2.one(command)
            let right = try resp3.one(command)
            #expect(left.columns.map(\.name) == right.columns.map(\.name), "\(command)")
            #expect(Set(left.rows.map { $0.map(\.displayString) }) == Set(right.rows.map { $0.map(\.displayString) }), "\(command)")
        }
    }

    @Test func wrongPasswordIsAnAuthenticationError() {
        guard case .authentication(let message)? = caught({ _ = try RedisTestServer.connect(password: "wrong") }) else {
            Issue.record("Expected an authentication error")
            return
        }
        #expect(message.contains("WRONGPASS"))
        guard case .authentication? = caught({ _ = try RedisTestServer.connect(password: "") }) else {
            Issue.record("Expected an authentication error without a password")
            return
        }
        guard case .authentication? = caught({ _ = try RedisTestServer.connect(password: "wrong", resp3: false) }) else {
            Issue.record("Expected an authentication error on RESP2")
            return
        }
    }

    @Test func databaseIndexFromConfig() throws {
        let connection = try RedisTestServer.connect(database: "1")
        defer { connection.close() }
        #expect(connection.currentDatabase == "db1")
        #expect(try connection.value("GET other:db") == .text("value in db 1"))
        guard case .connection? = caught({ _ = try RedisTestServer.connect(database: "abc") }) else {
            Issue.record("Expected a bad database index to fail")
            return
        }
    }

    @Test func typedResults() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }

        let hash = try connection.one("HGETALL user:1")
        #expect(hash.columns.map(\.name) == ["Field", "Value"])
        #expect(hash.rows.contains([.text("name"), .text("Zoë Müller")]))

        let list = try connection.one("LRANGE queue:emails 0 -1")
        #expect(list.rows.map { $0.map(\.displayString) } == [["0", "welcome:1"], ["1", "reset:2"], ["2", "digest:3"], ["3", "welcome:4"]])
        let tail = try connection.one("LRANGE queue:emails -2 -1")
        #expect(tail.rows.map { $0[0] } == [.text("2"), .text("3")])

        let scores = try connection.one("ZRANGE leaderboard 0 -1 WITHSCORES")
        #expect(scores.rows.first == [.text("alice"), .text("980")])
        #expect(scores.rows.count == 4)

        let stream = try connection.one("XRANGE events:orders - +")
        #expect(stream.columns.map(\.name) == ["ID", "Fields"])
        #expect(stream.rows.map { $0[1] } == [.text("order=1001, status=paid"), .text("order=1002, status=shipped")])

        #expect(try connection.value("GET binary:blob") == .bytes(Data([0x00, 0xFF, 0x10])))
        #expect(try connection.value("GET greeting") == .text("Hello from Foxlume Query"))
        #expect(try connection.one("SMEMBERS tags:post:1").rows.count == 4)

        let ttl = try connection.one("TTL session:abc123")
        #expect(ttl.columns.map(\.name) == ["Key", "TTL"])
        #expect((Int(ttl.rows[0][1].textValue ?? "") ?? 0) > 0)

        let info = try connection.one("INFO memory")
        #expect(info.columns.map(\.name) == ["Section", "Key", "Value"])
        #expect(info.rows.contains { $0[0] == .text("Memory") && $0[1] == .text("used_memory") })

        let config = try connection.one("CONFIG GET maxmemory")
        #expect(config.rows == [[.text("maxmemory"), .text("0")]])

        let size = try connection.one("DBSIZE")
        #expect(size.columns.first?.isNumeric == true)
    }

    @Test func severalStatementsInOneRun() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        let key = RedisTestServer.scratchPrefix() + "a"
        let results = try connection.run("SET \(key) \"x;y\"; GET \(key)\nDEL \(key)")
        #expect(results.count == 3)
        #expect(results[0].message == "OK")
        #expect(results[1].rows == [[.text(key), .text("x;y")]])
        #expect(results[2].rows == [[.text("1")]])
        #expect(results[2].affectedRows == 1)
    }

    @Test func databasePrefixReturnsToCurrentDatabase() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        #expect(try connection.value("DB 1 GET other:db") == .text("value in db 1"))
        #expect(connection.currentDatabase == "db0")
        #expect(try connection.value("GET other:db") == .null)
        #expect(try connection.one("DB 1 KEYS other:*").rows.first?.first == .text("other:db"))
        #expect(try connection.value("GET greeting") == .text("Hello from Foxlume Query"))
    }

    @Test func selectChangesCurrentDatabase() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        _ = try connection.run("SELECT 1")
        #expect(connection.currentDatabase == "db1")
        #expect(try connection.value("GET other:db") == .text("value in db 1"))
        try connection.useDatabase("db0")
        #expect(connection.currentDatabase == "db0")
        #expect(try connection.value("GET other:db") == .null)
    }

    @Test func errorsKeepTheSessionUsable() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        guard case .server(_, let code, _)? = caught({ _ = try connection.run("NOSUCHCOMMAND x") }) else {
            Issue.record("Expected a server error")
            return
        }
        #expect(code == "ERR")
        guard case .server(_, let wrongType, _)? = caught({ _ = try connection.run("LPUSH user:1 x") }) else {
            Issue.record("Expected WRONGTYPE")
            return
        }
        #expect(wrongType == "WRONGTYPE")
        #expect(caught { _ = try connection.run(#"GET "unterminated"#) } != nil)
        guard case .unsupported? = caught({ _ = try connection.run("SUBSCRIBE news") }) else {
            Issue.record("Expected SUBSCRIBE to be refused")
            return
        }
        #expect(try connection.value("PING") == .text("PONG"))
    }

    @Test func rowLimitCapsRows() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        let result = try connection.one("LRANGE queue:emails 0 -1", rowLimit: 2)
        #expect(result.rows.count == 2)
        #expect(result.truncated)
    }

    @Test func keysAndScanShowTheKeyGrid() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        let scan = try connection.one("SCAN 0 MATCH user:* COUNT 100")
        #expect(scan.columns.map(\.name) == ["Key", "Type", "TTL", "Length", "Value"])
        #expect(scan.message?.hasPrefix("Next cursor: ") == true)
        let keys = try connection.one("KEYS user:*")
        #expect(keys.rows.map { $0[0] } == [.text("user:1"), .text("user:2"), .text("user:3")])
        #expect(keys.rows[0][1] == .text("HASH"))
        #expect(keys.rows[0][3] == .text("4"))
    }

    @Test func multiQueuesAndExecRuns() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        let key = RedisTestServer.scratchPrefix() + "m"
        defer { _ = try? connection.run("DEL \(key)") }
        let results = try connection.run("MULTI\nSET \(key) 1\nINCR \(key)\nHGETALL \(key)\nEXEC")
        #expect(results.map(\.message) == ["OK", "QUEUED", "QUEUED", "QUEUED", nil])
        #expect(results[4].rows.count == 3)
        #expect(results[4].rows[1] == [.text("2")])
        #expect(results[4].rows[2][0].displayString.hasPrefix("(error) WRONGTYPE"))
        #expect(!connection.inTransaction)
    }

    /// Browsing while the editor holds a MULTI open must not queue into it.
    @Test func browsingDuringAnOpenTransactionUsesASideConnection() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        let key = RedisTestServer.scratchPrefix() + "t"
        defer { _ = try? connection.run("DEL \(key)") }
        _ = try connection.run("MULTI\nSET \(key) queued")
        #expect(connection.inTransaction)
        #expect(try connection.tables(schema: nil).count == 16)
        let page = try connection.fetchRows(TableQuery(table: TableRef(name: "db1"), pageSize: 200))
        #expect(page.rows.map { $0[0] } == [.text("other:db")])
        #expect(try connection.browseKeys(pattern: "user:*", limit: 100)?.keys.count == 3)
        #expect(connection.inTransaction)
        let exec = try connection.one("EXEC")
        #expect(exec.rows == [[.text("OK")]])
        #expect(try connection.value("GET \(key)") == .text("queued"))
    }

    @Test func cancelFreesABlockingCommand() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        let link = try connection.singleLink()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { connection.cancel() }
        let began = Date()
        guard case .cancelled? = caught({ _ = try connection.run("BLPOP \(RedisTestServer.scratchPrefix())never 30") }) else {
            Issue.record("Expected cancellation")
            return
        }
        #expect(Date().timeIntervalSince(began) < 2)
        #expect(try connection.value("PING") == .text("PONG"))
        // CLIENT UNBLOCK freed it, so the connection was kept.
        #expect(try connection.singleLink() === link)
    }

    @Test func cancelOnAnotherDatabaseReturnsHome() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { connection.cancel() }
        guard case .cancelled? = caught({ _ = try connection.run("DB 2 BLPOP \(RedisTestServer.scratchPrefix())never 30") }) else {
            Issue.record("Expected cancellation")
            return
        }
        #expect(try connection.value("GET greeting") == .text("Hello from Foxlume Query"))
    }

    @Test func cancelWithoutRunningCommandDoesNothing() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        connection.cancel()
        #expect(try connection.value("PING") == .text("PONG"))
    }

    /// A link that died while idle fails the call that finds it dead (the command may or may not have run),
    /// then the next call reconnects on the session's database.
    @Test func droppedConnectionReconnectsOnTheSameDatabase() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        _ = try connection.run("SELECT 1")
        try connection.singleLink().interrupt()
        guard case .connection? = caught({ _ = try connection.run("PING") }) else {
            Issue.record("Expected the dead link to fail once")
            return
        }
        #expect(try connection.value("GET other:db") == .text("value in db 1"))
        #expect(connection.currentDatabase == "db1")
    }

    @Test func metadata() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        #expect(try connection.databases().isEmpty)
        #expect(try connection.schemas().isEmpty)
        let tables = try connection.tables(schema: nil)
        #expect(tables.count == 16)
        #expect(tables.allSatisfy { $0.kind == .keyspace })
        #expect(tables[0].name == "db0")
        // Compared with DBSIZE: the seed's cache:product:1 expires an hour after seeding.
        #expect(tables[0].estimatedRows == Int(try connection.value("DBSIZE")?.textValue ?? ""))
        #expect((tables[0].estimatedRows ?? 0) >= 11)
        #expect(tables[1].estimatedRows == 1)
        let structure = try connection.structure(of: TableRef(name: "db0"))
        #expect(structure.columns.map(\.name) == ["Key", "Type", "TTL", "Length", "Value"])
        #expect(structure.primaryKey == ["Key"])
        #expect(try connection.ddl(of: TableRef(name: "db0")) == "")
        let capabilities = connection.capabilities
        #expect(capabilities.queryLanguage == .redis)
        #expect(capabilities.browseFilterStyle == .keyPattern(types: ["string", "hash", "list", "set", "zset", "stream"]))
        #expect(capabilities.immutableColumns == ["Length"])
        #expect(capabilities.preferredPageSize == 200)
        #expect(!capabilities.supportsDatabaseSwitching)
        #expect(!capabilities.supportsColumnSort)
    }

    @Test func browsesWithPatternTypeAndPaging() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        let prefix = RedisTestServer.scratchPrefix()
        defer { connection.dropKeys(prefix) }
        _ = try connection.run("""
            SET \(prefix)s1 one
            SET \(prefix)s2 two EX 500
            SET \(prefix)s3 "\\xff\\x00"
            HSET \(prefix)h1 name An age 30
            HSET \(prefix)h2 f v
            RPUSH \(prefix)l1 a b c
            SADD \(prefix)set1 y x
            ZADD \(prefix)z1 2 b 1.5 a
            XADD \(prefix)x1 1-1 order 7
            """)
        let pattern = prefix + "*"
        var query = TableQuery(table: TableRef(name: "db0"), rawWhere: pattern, pageSize: 200)
        let all = try connection.fetchRows(query)
        #expect(all.columns.map(\.name) == ["Key", "Type", "TTL", "Length", "Value"])
        #expect(all.rows.map { $0[0].displayString } == ["h1", "h2", "l1", "s1", "s2", "s3", "set1", "x1", "z1"].map { prefix + $0 })
        let byKey = Dictionary(uniqueKeysWithValues: all.rows.map { ($0[0].displayString.replacingOccurrences(of: prefix, with: ""), $0) })
        #expect(byKey["h1"]?[1] == .text("HASH"))
        #expect(byKey["h1"]?[3] == .text("2"))
        #expect(byKey["h1"]?[4] == .text(#"{"age":"30","name":"An"}"#))
        #expect(byKey["l1"]?[4] == .text(#"["a","b","c"]"#))
        #expect(byKey["set1"]?[4] == .text(#"["x","y"]"#))
        #expect(byKey["z1"]?[4] == .text(#"[["a",1.5],["b",2]]"#))
        #expect(byKey["x1"]?[4] == .text(#"[["1-1",{"order":"7"}]]"#))
        #expect(byKey["s1"]?[2] == .text("-1"))
        #expect((Int(byKey["s2"]?[2].textValue ?? "") ?? 0) > 400)
        #expect(byKey["s3"]?[4] == .bytes(Data([0xFF, 0x00])))
        #expect(byKey["s3"]?[3] == .text("2"))

        query.filters = [FilterRule(column: "Type", op: .equals, value: "hash")]
        #expect(try connection.fetchRows(query).rows.count == 2)
        #expect(try connection.countRows(query) == 2)
        query.filters = [FilterRule(column: "Type", op: .equals, value: "Sorted Set")]
        #expect(try connection.fetchRows(query).rows.map { $0[1] } == [.text("ZSET")])

        query.filters = []
        query.pageSize = 4
        query.page = 1
        #expect(try connection.fetchRows(query).rows.map { $0[0].displayString } == ["s2", "s3", "set1", "x1"].map { prefix + $0 })
        query.page = 2
        #expect(try connection.fetchRows(query).rows.count == 1)
        #expect(try connection.countRows(query) == 9)

        let everything = try #require(try connection.countRows(TableQuery(table: TableRef(name: "db0"))))
        #expect(everything == Int(try connection.value("DBSIZE")?.textValue ?? ""))
        #expect(everything >= 9 + 11)
    }

    @Test func browsingAnotherDatabaseStaysOnTheCurrentOne() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        let other = try connection.fetchRows(TableQuery(table: TableRef(name: "db1"), pageSize: 200))
        #expect(other.rows.map { $0[0] } == [.text("other:db")])
        #expect(other.rows[0][4] == .text("value in db 1"))
        #expect(connection.currentDatabase == "db0")
        #expect(try connection.value("GET greeting") == .text("Hello from Foxlume Query"))
        #expect(try connection.countRows(TableQuery(table: TableRef(name: "db1"))) == 1)
    }

    @Test func savesEditsInOneTransaction() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        let prefix = RedisTestServer.scratchPrefix()
        defer { connection.dropKeys(prefix) }
        _ = try connection.run("""
            SET \(prefix)a alpha
            SET \(prefix)b beta EX 1000
            HSET \(prefix)h f v
            SET \(prefix)gone bye
            """)
        let query = TableQuery(table: TableRef(name: "db0"), rawWhere: prefix + "*", pageSize: 200)
        let page = try connection.fetchRows(query)
        let index = Dictionary(uniqueKeysWithValues: page.rows.enumerated().map { ($1[0].displayString.replacingOccurrences(of: prefix, with: ""), $0) })
        let a = try #require(index["a"]), b = try #require(index["b"]), h = try #require(index["h"]), gone = try #require(index["gone"])

        var changes = PendingChanges()
        changes.setValue(.text(prefix + "a2"), row: a, column: 0, original: page.rows[a][0])
        changes.setValue(.text("ALPHA"), row: a, column: 4, original: page.rows[a][4])
        changes.setValue(.text("-1"), row: b, column: 2, original: page.rows[b][2])
        changes.setValue(.text("300"), row: h, column: 2, original: page.rows[h][2])
        changes.markDeleted(rows: [gone])
        changes.addInsertion([.value(.text(prefix + "nh")), .value(.text("HASH")), .value(.text("120")), .useDefault, .value(.text(#"{"name":"Björn","n":1}"#))])
        changes.addInsertion([.value(.text(prefix + "nz")), .value(.text("zset")), .useDefault, .useDefault, .value(.text("member"))])
        changes.addInsertion([.value(.text(prefix + "ns")), .useDefault, .useDefault, .useDefault, .value(.text("plain"))])
        try connection.applyChanges(ChangeBatch(table: TableRef(name: "db0"), columns: page.columns, primaryKey: ["Key"], originalRows: page.rows, changes: changes))

        #expect(try connection.value("GET \(prefix)a2") == .text("ALPHA"))
        #expect(try connection.value("EXISTS \(prefix)a") == .text("0"))
        #expect(try connection.value("TTL \(prefix)b") == .text("-1"))
        let hashTTL = Int(try connection.value("TTL \(prefix)h")?.textValue ?? "") ?? 0
        #expect(hashTTL > 200 && hashTTL <= 300)
        #expect(try connection.value("EXISTS \(prefix)gone") == .text("0"))
        let hashRows = try connection.one("HGETALL \(prefix)nh").rows
        #expect(Set(hashRows) == [[.text("n"), .text("1")], [.text("name"), .text("Björn")]])
        #expect((Int(try connection.value("TTL \(prefix)nh")?.textValue ?? "") ?? 0) > 100)
        #expect(try connection.one("ZRANGE \(prefix)nz 0 -1 WITHSCORES").rows == [[.text("member"), .text("0")]])
        #expect(try connection.value("GET \(prefix)ns") == .text("plain"))
        #expect(connection.currentDatabase == "db0")
    }

    @Test func savingToAnotherDatabaseReturnsHome() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        let prefix = RedisTestServer.scratchPrefix()
        defer { _ = try? connection.run("DB 3 DEL \(prefix)k") }
        var changes = PendingChanges()
        changes.addInsertion([.value(.text(prefix + "k")), .value(.text("string")), .useDefault, .useDefault, .value(.text("in db3"))])
        try connection.applyChanges(ChangeBatch(table: TableRef(name: "db3"), columns: RedisResults.keyColumns(), primaryKey: ["Key"], originalRows: [], changes: changes))
        #expect(try connection.value("DB 3 GET \(prefix)k") == .text("in db3"))
        #expect(try connection.value("GET \(prefix)k") == .null)
        #expect(connection.currentDatabase == "db0")
    }

    @Test func execErrorFailsTheSave() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        let prefix = RedisTestServer.scratchPrefix()
        defer { connection.dropKeys(prefix) }
        _ = try connection.run("SET \(prefix)s text")
        var changes = PendingChanges()
        // RPUSH onto an existing string fails inside EXEC with WRONGTYPE.
        changes.addInsertion([.value(.text(prefix + "s")), .value(.text("list")), .useDefault, .useDefault, .value(.text("x"))])
        guard case .server(let message, let code, _)? = caught({
            try connection.applyChanges(ChangeBatch(table: TableRef(name: "db0"), columns: RedisResults.keyColumns(), primaryKey: ["Key"], originalRows: [], changes: changes))
        }) else {
            Issue.record("Expected the save to fail")
            return
        }
        #expect(code == "WRONGTYPE")
        #expect(message.contains("RPUSH"))
        #expect(try connection.value("GET \(prefix)s") == .text("text"))
    }

    @Test func keyTreeListingTruncatesAtTheLimit() throws {
        let connection = try RedisTestServer.connect()
        defer { connection.close() }
        let prefix = RedisTestServer.scratchPrefix()
        defer { connection.dropKeys(prefix) }
        let sets = (0..<30).map { "SET \(prefix)k\(String(format: "%02d", $0)) v" }
        _ = try connection.run(sets.joined(separator: "\n") + "\nHSET \(prefix)zz f v")
        let capped = try #require(try connection.browseKeys(pattern: prefix + "*", limit: 10))
        #expect(capped.keys.count == 10)
        #expect(capped.truncated)
        let full = try #require(try connection.browseKeys(pattern: prefix + "*", limit: 50_000))
        #expect(full.keys.count == 31)
        #expect(!full.truncated)
        #expect(full.keys.first == KeyListing.Key(name: prefix + "k00", type: "string"))
        #expect(full.keys.last == KeyListing.Key(name: prefix + "zz", type: "hash"))
        let seeded = try #require(try connection.browseKeys(pattern: "", limit: 50_000))
        #expect(seeded.keys.contains(KeyListing.Key(name: "leaderboard", type: "zset")))
        #expect(seeded.keys.contains(KeyListing.Key(name: "events:orders", type: "stream")))
    }

    @Test func modeMismatchIsExplained() {
        guard case .connection(let message)? = caught({ _ = try RedisTestServer.connect(options: [.redisMode: "cluster"]) }) else {
            Issue.record("Expected cluster mode to be refused")
            return
        }
        #expect(message.contains("not part of a Redis Cluster"))
        guard case .connection(let sentinel)? = caught({
            _ = try RedisTestServer.connect(options: [.redisMode: "sentinel", .redisNodes: "127.0.0.1:\(RedisTestServer.port)"])
        }) else {
            Issue.record("Expected sentinel mode to be refused")
            return
        }
        #expect(sentinel.contains("is not a Sentinel"))
    }
}

// MARK: - TLS

/// The local servers are built without TLS, so a TLS session itself is not exercised here.
@Suite("Redis TLS paths")
struct RedisTLSTests {
    @Test(.enabled(if: RedisTestServer.isAvailable))
    func preferFallsBackToPlaintextQuickly() throws {
        let began = Date()
        let connection = try RedisTestServer.connect(ssl: .prefer)
        defer { connection.close() }
        #expect(!connection.isTLS)
        #expect(Date().timeIntervalSince(began) < 2)
        #expect(try connection.value("PING") == .text("PONG"))
    }

    @Test(.enabled(if: RedisTestServer.isAvailable), arguments: [SSLMode.require, .verifyFull])
    func requireRefusesAPlaintextServerQuickly(_ mode: SSLMode) {
        let began = Date()
        guard case .connection(let message)? = caught({ _ = try RedisTestServer.connect(ssl: mode) }) else {
            Issue.record("Expected a TLS failure")
            return
        }
        #expect(message.contains("does not use TLS"))
        #expect(Date().timeIntervalSince(began) < 2)
    }

    @Test(arguments: [SSLMode.require, .prefer])
    func silentServerTimesOutDuringTheHandshake(_ mode: SSLMode) throws {
        let listener = try SilentListener()
        let config = ConnectionConfig(kind: .redis, host: "127.0.0.1", port: listener.port, sslMode: mode, connectTimeout: 1)
        let connection = RedisConnection(parameters: ConnectionParameters(config: config, password: "pw"))
        let began = Date()
        guard case .connection(let message)? = caught({ try connection.connect() }) else {
            Issue.record("Expected a timeout")
            return
        }
        #expect(message.contains("TLS handshake"))
        #expect(Date().timeIntervalSince(began) < 4)
        guard case .notConnected? = caught({ _ = try connection.execute("PING", rowLimit: nil) }) else {
            Issue.record("Expected notConnected")
            return
        }
    }

    @Test func plaintextSilentServerTimesOut() throws {
        let listener = try SilentListener()
        let config = ConnectionConfig(kind: .redis, host: "127.0.0.1", port: listener.port, sslMode: .disable, connectTimeout: 1)
        let connection = RedisConnection(parameters: ConnectionParameters(config: config, password: ""))
        guard case .connection(let message)? = caught({ try connection.connect() }) else {
            Issue.record("Expected a timeout")
            return
        }
        #expect(message.hasPrefix("Timed out after 1 seconds"))
    }
}

// MARK: - Sentinel and Cluster

/// Extra processes from `scripts/redis-extra.sh`: master 56380, replica 56381, sentinel 56382, cluster 56390-56392.
enum RedisExtraServers {
    static let master = 56380
    static let sentinel = 56382
    static let clusterSeed = 56390
    static let tlsProxy = 56398
    static let isAvailable = RedisTestServer.reachable(sentinel) && RedisTestServer.reachable(clusterSeed) && RedisTestServer.reachable(master)

    static func sentinelConnection(master: String = "mymaster", sentinelUser: String? = nil) throws -> RedisConnection {
        var options: [ConnectionOption: String] = [.redisMode: "sentinel", .redisNodes: "127.0.0.1:1, 127.0.0.1:\(sentinel)", .redisSentinelMaster: master]
        if let sentinelUser { options[.redisSentinelUser] = sentinelUser }
        return try RedisTestServer.connect(port: 1, options: options)
    }

    static func clusterConnection() throws -> RedisConnection {
        try RedisTestServer.connect(port: 1, options: [.redisMode: "cluster", .redisNodes: "127.0.0.1:\(clusterSeed)"])
    }
}

@Suite("Redis Sentinel, Cluster and TLS", .serialized, .enabled(if: RedisExtraServers.isAvailable))
struct RedisTopologyTests {
    @Test func sentinelResolvesTheMaster() throws {
        let connection = try RedisExtraServers.sentinelConnection()
        defer { connection.close() }
        #expect(try connection.singleLink().endpoint == RedisEndpoint(host: "127.0.0.1", port: RedisExtraServers.master))
        #expect(try connection.one("ROLE").rows.first?.first == .text("master"))
        let key = RedisTestServer.scratchPrefix() + "s"
        #expect(try connection.run("SET \(key) 1; GET \(key); DEL \(key)")[1].rows == [[.text(key), .text("1")]])
    }

    @Test func sentinelACLUser() throws {
        let connection = try RedisExtraServers.sentinelConnection(sentinelUser: "sentinel-admin")
        defer { connection.close() }
        #expect(try connection.singleLink().endpoint.port == RedisExtraServers.master)
    }

    @Test func sentinelUnknownMaster() {
        guard case .connection(let message)? = caught({ _ = try RedisExtraServers.sentinelConnection(master: "nope") }) else {
            Issue.record("Expected an unknown master to fail")
            return
        }
        #expect(message.contains("No sentinel could name the master \"nope\""))
    }

    @Test func clusterRoutesKeysAndAggregates() throws {
        let connection = try RedisExtraServers.clusterConnection()
        defer { connection.close() }
        let router = try #require(connection.cluster)
        #expect(router.masters.count == 3)
        #expect(!router.topology.slotOwners.contains(-1))
        #expect(connection.currentDatabase == "db0")
        let prefix = RedisTestServer.scratchPrefix()
        let keys = (0..<12).map { "\(prefix)\($0)" }
        let slots = Set(keys.map { router.endpoint(forSlot: RedisKeySlot.slot(for: $0)) })
        #expect(slots.count > 1)
        _ = try connection.run(keys.map { "SET \($0) v\($0)" }.joined(separator: "\n"))
        for key in keys {
            #expect(try connection.value("GET \(key)") == .text("v\(key)"))
        }
        let mget = try connection.one("MGET " + keys.joined(separator: " "))
        #expect(mget.rows.map { $0[1] } == keys.map { .text("v\($0)") })
        let total = Int(try connection.value("DBSIZE")?.textValue ?? "") ?? 0
        #expect(total >= keys.count)
        #expect(try connection.tables(schema: nil).map(\.name) == ["db0"])
        let deleted = try connection.one("DEL " + keys.joined(separator: " "))
        #expect(deleted.rows == [[.text("12")]])
        #expect(deleted.affectedRows == 12)
    }

    @Test func clusterFollowsMoved() throws {
        let connection = try RedisExtraServers.clusterConnection()
        defer { connection.close() }
        let router = try #require(connection.cluster)
        let key = RedisTestServer.scratchPrefix() + "moved"
        _ = try connection.run("SET \(key) here")
        defer { _ = try? connection.run("DEL \(key)") }
        let slot = RedisKeySlot.slot(for: key)
        let owner = router.endpoint(forSlot: slot)
        let wrong = try #require(router.masters.first { $0 != owner })
        router.noteMoved(slot: slot, to: wrong)
        #expect(router.endpoint(forSlot: slot) == wrong)
        #expect(try connection.value("GET \(key)") == .text("here"))
        #expect(router.endpoint(forSlot: slot) == owner)
    }

    @Test func clusterScanWalksEveryMaster() throws {
        let connection = try RedisExtraServers.clusterConnection()
        defer { connection.close() }
        let prefix = RedisTestServer.scratchPrefix()
        let keys = (0..<20).map { "\(prefix)\($0)" }
        _ = try connection.run(keys.map { "SET \($0) x" }.joined(separator: "\n"))
        defer { _ = try? connection.run("DEL " + keys.joined(separator: " ")) }

        var cursor = "0"
        var found: Set<String> = []
        var steps = 0
        repeat {
            let page = try connection.one("SCAN \(cursor) MATCH \(prefix)* COUNT 1000")
            found.formUnion(page.rows.compactMap { $0[0].textValue })
            cursor = String(page.message?.dropFirst("Next cursor: ".count) ?? "0")
            steps += 1
        } while cursor != "0" && steps < 100
        #expect(found == Set(keys))
        #expect(steps >= 3)

        let query = TableQuery(table: TableRef(name: "db0"), rawWhere: prefix + "*", pageSize: 200)
        #expect(try connection.fetchRows(query).rows.map { $0[0].displayString } == keys.sorted())
        #expect(try connection.countRows(query) == 20)
        #expect(try connection.one("KEYS \(prefix)*").rows.count == 20)
        let listing = try #require(try connection.browseKeys(pattern: prefix + "*", limit: 100))
        #expect(listing.keys.count == 20)
    }

    @Test func clusterSavesPerSlot() throws {
        let connection = try RedisExtraServers.clusterConnection()
        defer { connection.close() }
        let prefix = RedisTestServer.scratchPrefix()
        let tag = "{\(prefix)t}"
        defer { _ = try? connection.run("DEL \(prefix)a \(prefix)b \(prefix)c \(tag)x \(tag)y") }
        _ = try connection.run("SET \(tag)x one")
        var changes = PendingChanges()
        for name in ["a", "b", "c"] {
            changes.addInsertion([.value(.text(prefix + name)), .value(.text("string")), .value(.text("100")), .useDefault, .value(.text(name))])
        }
        let page = try connection.fetchRows(TableQuery(table: TableRef(name: "db0"), rawWhere: "\(tag)*", pageSize: 200))
        changes.setValue(.text("\(tag)y"), row: 0, column: 0, original: page.rows[0][0])
        try connection.applyChanges(ChangeBatch(table: TableRef(name: "db0"), columns: page.columns, primaryKey: ["Key"], originalRows: page.rows, changes: changes))
        #expect(try connection.value("GET \(prefix)b") == .text("b"))
        #expect(try connection.value("GET \(tag)y") == .text("one"))

        var crossSlot = PendingChanges()
        let renamed = try connection.fetchRows(TableQuery(table: TableRef(name: "db0"), rawWhere: "\(tag)*", pageSize: 200))
        crossSlot.setValue(.text(prefix + "elsewhere-\(UUID().uuidString)"), row: 0, column: 0, original: renamed.rows[0][0])
        guard case .unsupported(let message)? = caught({
            try connection.applyChanges(ChangeBatch(table: TableRef(name: "db0"), columns: renamed.columns, primaryKey: ["Key"], originalRows: renamed.rows, changes: crossSlot))
        }) else {
            Issue.record("Expected a cross-slot rename to be refused")
            return
        }
        #expect(message.contains("hash slot"))
    }

    @Test func clusterMultiPinsToTheFirstKeysNode() throws {
        let connection = try RedisExtraServers.clusterConnection()
        defer { connection.close() }
        let key = "{\(RedisTestServer.scratchPrefix())}k"
        defer { _ = try? connection.run("DEL \(key)") }
        let results = try connection.run("MULTI\nSET \(key) 5\nINCR \(key)\nEXEC")
        #expect(results.map(\.message) == ["OK", "QUEUED", "QUEUED", nil])
        #expect(results[3].rows.last == [.text("6")])
    }

    @Test func standaloneModeOnAClusterNodeIsExplained() {
        guard case .connection(let message)? = caught({ _ = try RedisTestServer.connect(port: RedisExtraServers.clusterSeed) }) else {
            Issue.record("Expected standalone mode on a cluster node to be refused")
            return
        }
        #expect(message.contains("Set the connection mode to Cluster"))
    }

    /// A user without CLIENT UNBLOCK: cancel falls back to closing the socket, and the next call reconnects.
    @Test func cancelFallsBackToInterrupting() throws {
        let admin = try RedisTestServer.connect(port: RedisExtraServers.master)
        defer { admin.close() }
        let user = "eq-nounblock-\(UUID().uuidString.prefix(6))"
        _ = try admin.run("ACL SETUSER \(user) on >pw ~* &* +@all -client")
        defer { _ = try? admin.run("ACL DELUSER \(user)") }

        let connection = try RedisTestServer.connect(port: RedisExtraServers.master, user: user, password: "pw")
        defer { connection.close() }
        let link = try connection.singleLink()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { connection.cancel() }
        let began = Date()
        guard case .cancelled? = caught({ _ = try connection.run("BLPOP \(RedisTestServer.scratchPrefix())never 30") }) else {
            Issue.record("Expected cancellation")
            return
        }
        #expect(Date().timeIntervalSince(began) < 3)
        #expect(try connection.value("PING") == .text("PONG"))
        #expect(try connection.singleLink() !== link)
    }

    /// SCRIPT KILL stops a busy script; the server only listens once busy-reply-threshold has passed.
    @Test func cancelKillsAScript() throws {
        let admin = try RedisTestServer.connect(port: RedisExtraServers.master)
        defer { admin.close() }
        let threshold = try admin.one("CONFIG GET busy-reply-threshold").rows.first?[1].textValue ?? "5000"
        _ = try admin.run("CONFIG SET busy-reply-threshold 300")
        defer { _ = try? admin.run("CONFIG SET busy-reply-threshold \(threshold)") }

        let connection = try RedisTestServer.connect(port: RedisExtraServers.master)
        defer { connection.close() }
        let link = try connection.singleLink()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { connection.cancel() }
        let began = Date()
        guard case .cancelled? = caught({ _ = try connection.run(#"EVAL "while true do end" 0"#) }) else {
            Issue.record("Expected cancellation")
            return
        }
        #expect(Date().timeIntervalSince(began) < 3)
        #expect(try connection.value("PING") == .text("PONG"))
        #expect(try connection.singleLink() === link)
    }

    // MARK: TLS through the proxy

    /// `scripts/redis-extra.sh` puts `openssl s_server` in front of the master on 56398, so this TLS session is real.
    /// The proxy serves one client at a time and shares the master with the tests above, hence this serialized suite.
    @Test(.enabled(if: RedisTestServer.reachable(RedisExtraServers.tlsProxy)), arguments: [SSLMode.require, .prefer])
    func negotiatesTLSThroughTheProxy(_ mode: SSLMode) throws {
        let connection = try RedisTestServer.connect(port: RedisExtraServers.tlsProxy, ssl: mode)
        defer { connection.close() }
        #expect(connection.isTLS)
        #expect(connection.protocolVersion == 3)
        let key = RedisTestServer.scratchPrefix() + "tls"
        let results = try connection.run("SET \(key) \"über TLS\"\nGET \(key)\nDEL \(key)")
        #expect(results[1].rows == [[.text(key), .text("über TLS")]])
    }

    @Test(.enabled(if: RedisTestServer.reachable(RedisExtraServers.tlsProxy)))
    func verifyFullRejectsASelfSignedCertificate() {
        var config = RedisTestServer.config(port: RedisExtraServers.tlsProxy, ssl: .verifyFull)
        config.host = "localhost"
        let connection = RedisConnection(parameters: ConnectionParameters(config: config, password: RedisTestServer.password))
        guard case .connection(let message)? = caught({ try connection.connect() }) else {
            Issue.record("Expected certificate verification to fail")
            return
        }
        #expect(message.contains("could not be verified"))
    }
}

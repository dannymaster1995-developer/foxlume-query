import Foundation
import Testing
@testable import FoxlumeQueryCore

/// Schema stand-in for the Redis completer: a key list and favorites.
@MainActor
private final class RedisFakeSchema: CompletionSchemaProvider {
    var keys = ["user:1", "user:2", "users:index", "session:abc", "my key"]
    var favoriteList: [CompletionFavorite] = []
    private(set) var keyRequests: [(prefix: String, limit: Int)] = []

    func unqualifiedTables() async -> [TableInfo] { [TableInfo(ref: TableRef(name: "db0"))] }
    func tables(inSchema schema: String) async -> [TableInfo]? { nil }
    func schemaNames() async -> [String] { [] }
    func databaseNames() async -> [String] { [] }
    func implicitSchema() async -> String? { nil }
    func columns(of table: TableRef) async -> [ColumnInfo]? { nil }
    func cachedColumns() -> [(table: TableRef, columns: [ColumnInfo])] { [] }
    func documentFields(of collection: String) async -> [CompletionField] { [] }
    func keyNames(prefix: String, limit: Int) async -> [String] {
        keyRequests.append((prefix, limit))
        return keys.filter { $0.hasPrefix(prefix) }
    }
    func favorites() -> [CompletionFavorite] { favoriteList }
}

/// `|` marks the caret.
private func split(_ marked: String) -> (text: String, caret: Int) {
    let caret = (marked as NSString).range(of: "|").location
    return (marked.replacingOccurrences(of: "|", with: ""), caret)
}

@MainActor
private func complete(_ marked: String, manual: Bool = false, keywordCase: KeywordCase = .matchTypedElseUpper, schema: RedisFakeSchema? = nil) async -> CompletionResult? {
    let (text, caret) = split(marked)
    // The engine holds its schema weakly.
    let schema = schema ?? RedisFakeSchema()
    let engine = RedisCompletionEngine(schema: schema)
    return await engine.complete(text: text, caret: caret, manual: manual, keywordCase: keywordCase)
}

@MainActor
private func labels(_ marked: String, manual: Bool = false, keywordCase: KeywordCase = .matchTypedElseUpper, schema: RedisFakeSchema? = nil) async -> [String] {
    await complete(marked, manual: manual, keywordCase: keywordCase, schema: schema)?.items.map(\.label) ?? []
}

private func slot(_ marked: String) -> RedisCompletionEngine.Slot? {
    let (text, caret) = split(marked)
    return RedisCompletionEngine.analyze(text, caret: caret).slot
}

@Suite("Redis completion analysis")
struct RedisCompletionAnalysisTests {
    @Test(arguments: [
        ("|", RedisCompletionEngine.Slot.command),
        ("hg|", .command),
        ("  hg|", .command),
        ("GET a\nhs|", .command),
        ("GET a; hs|", .command),
        ("DB 1 hg|", .command),
        ("db 2 |", .command),
        ("GET |", .argument(command: "GET", index: 1)),
        ("get us|", .argument(command: "GET", index: 1)),
        ("HGET user:1 |", .argument(command: "HGET", index: 2)),
        ("SET \"a b\" 'c d' e|", .argument(command: "SET", index: 3)),
        ("DB 3 zrange k 0 -1 W|", .argument(command: "ZRANGE", index: 4)),
        ("SET \"a\\\"b\" |", .argument(command: "SET", index: 2)),
    ])
    func slots(_ marked: String, expected: RedisCompletionEngine.Slot) {
        #expect(slot(marked) == expected, "\(marked)")
    }

    @Test(arguments: ["# hg|", "// GET |", "DB |", "DB 1|", "DB x |"])
    func noSlot(_ marked: String) {
        #expect(slot(marked) == nil, "\(marked)")
    }

    @Test func tokenIncludesTheOpeningQuote() {
        let (text, caret) = split("GET \"us|")
        let analysis = RedisCompletionEngine.analyze(text, caret: caret)
        #expect(analysis.token == "\"us")
        #expect(analysis.prefix == "us")
        #expect(analysis.quote == "\"")
        #expect(analysis.tokenRange == NSRange(location: 4, length: 3))
        #expect(RedisCompletionEngine.tokenRange(in: text, caret: caret) == NSRange(location: 4, length: 3))
    }

    @Test func vocabularyIsBroadAndUpperCase() {
        let names = RedisCompletionVocabulary.commands.map(\.name)
        #expect(names.count >= 120)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0 == $0.uppercased() })
        for name in ["GET", "SET", "DEL", "HGET", "HGETALL", "LPUSH", "ZADD", "SCAN", "XADD", "EXPIRE", "INFO", "CONFIG",
                     "SUBSTR", "JSON.OBJLEN", "WAITAOF", "QUIT", "SHUTDOWN", "MODULE", "ZDIFFSTORE"] {
            #expect(names.contains(name), "\(name)")
        }
        #expect(RedisCompletionVocabulary.command(named: "hget")?.name == "HGET")
    }
}

@MainActor
@Suite("Redis completion engine")
struct RedisCompletionEngineTests {
    // Spec 12 row 114; commands are fixed case (5.3).
    @Test func commandsMatchByPrefixInFixedUpperCase() async throws {
        let result = try #require(await complete("hg|"))
        #expect(result.items.prefix(2).map(\.label) == ["HGET", "HGETALL"])
        #expect(result.items[0].insertText == "HGET")
        #expect(result.items[0].detail == "HGET key field")
        #expect(result.items[0].kind == .keyword && !result.items[0].followsKeywordCase)
        #expect(result.items[0].highlights == [NSRange(location: 0, length: 2)])
        #expect(result.limit == .max)
        #expect(result.replacementRange == NSRange(location: 0, length: 2))
        #expect(await labels("HG|").prefix(2) == ["HGET", "HGETALL"])
        #expect(await labels("Hg|").first == "HGET")
        #expect(try #require(await complete("bgsave|")).items.first?.detail == "BGSAVE")
    }

    @Test func prefixMatchesComeBeforeSubstringsInListOrder() async {
        let ran = await labels("ran|")
        #expect(ran.first == "RANDOMKEY")
        let substrings = Array(ran.dropFirst())
        #expect(substrings.contains("LRANGE") && substrings.contains("ZRANGE"))
        #expect(substrings == substrings.sorted())
        #expect(await complete("zzqq|") == nil)
    }

    @Test func keywordCaseSettingIsIgnored() async {
        for policy in [KeywordCase.upper, .lower, .matchTypedElseUpper, .matchTypedElseLower] {
            #expect(await labels("hg|", keywordCase: policy).first == "HGET", "\(policy)")
            #expect(await labels("|", manual: true, keywordCase: policy).first == "ACL", "\(policy)")
            #expect(await labels("set k v e|", keywordCase: policy).first == "EX", "\(policy)")
        }
    }

    @Test func lineStartNeedsATypedLetterUnlessManual() async throws {
        #expect(await complete("|") == nil)
        #expect(await complete("GET a\n|") == nil)
        #expect(await complete("DB 1 |") == nil)
        let all = try #require(await complete("|", manual: true))
        #expect(all.items.count == RedisCompletionVocabulary.commands.count)
        #expect(await labels("DB 1 hg|").prefix(2) == ["HGET", "HGETALL"])
        #expect(await labels("GET a; hs|").prefix(2) == ["HSCAN", "HSET"])
    }

    @Test func keysForKeyArguments() async throws {
        let schema = RedisFakeSchema()
        // The space after a key-taking command opens the key list.
        let opened = try #require(await complete("GET |", schema: schema))
        #expect(opened.items.map(\.label) == schema.keys)
        #expect(opened.items.allSatisfy { $0.kind == .key && !$0.followsKeywordCase })
        #expect(schema.keyRequests.last?.prefix == "")
        #expect(schema.keyRequests.last?.limit == RedisCompletionEngine.keyLimit)

        let typed = try #require(await complete("get user:|", schema: schema))
        #expect(typed.items.map(\.label) == ["user:1", "user:2"])
        #expect(schema.keyRequests.last?.prefix == "user:")
        #expect(typed.replacementRange == NSRange(location: 4, length: 5))

        // Keys keep their case and are quoted when they would split or when the user opened a quote.
        #expect(try #require(await complete("DEL a my|", schema: schema)).items.first?.insertText == "\"my key\"")
        #expect(try #require(await complete("GET \"us|", schema: schema)).items.first?.insertText == "\"user:1\"")
        #expect(try #require(await complete("GET 'se|", schema: schema)).items.first?.insertText == "'session:abc'")

        // Values are not keys: nothing for HGET's field or SET's value.
        #expect(await complete("HGET user:1 |", manual: true, schema: schema) == nil)
        #expect(await complete("SET user:1 |", manual: true, schema: schema) == nil)
        // MSET alternates key and value.
        #expect(await complete("MSET a 1 |", schema: schema) != nil)
        #expect(await complete("MSET a |", manual: true, schema: schema) == nil)
        // Commands without keys and unknown commands offer nothing.
        #expect(await complete("PING |", manual: true, schema: schema) == nil)
        #expect(await complete("FROB |", manual: true, schema: schema) == nil)
    }

    @Test func optionWordsWaitForALetter() async throws {
        #expect(await complete("SET k v |") == nil)
        let manual = try #require(await complete("SET k v |", manual: true))
        #expect(manual.items.map(\.label) == ["EX", "PX", "EXAT", "PXAT", "NX", "XX", "KEEPTTL", "GET"])
        #expect(await labels("SET k v e|") == ["EX", "EXAT", "KEEPTTL", "GET"])
        #expect(await labels("SCAN 0 |", manual: true) == ["MATCH", "COUNT", "TYPE"])
        #expect(await labels("SCAN 0 MATCH user:* C|") == ["COUNT", "MATCH"])
        #expect(await labels("ZRANGE k 0 -1 |", manual: true) == ["BYSCORE", "BYLEX", "REV", "LIMIT", "WITHSCORES"])
        #expect(await labels("zrange k 0 -1 with|") == ["WITHSCORES"])
        // Before `optionsFrom` the words are not offered (SET's key and value).
        #expect(await complete("SET e|", manual: true, schema: RedisFakeSchema()) == nil)
    }

    @Test func subcommands() async throws {
        let config = try #require(await complete("CONFIG |"))
        #expect(config.items.map(\.label) == ["GET", "RESETSTAT", "REWRITE", "SET"])
        #expect(await labels("config g|") == ["GET"])
        // OBJECT ENCODING takes the key second.
        let schema = RedisFakeSchema()
        #expect(await labels("OBJECT ENCODING ses|", schema: schema) == ["session:abc"])
    }

    @Test func commentsOfferNothing() async {
        #expect(await complete("# hg|", manual: true) == nil)
        #expect(await complete("// GET |", manual: true) == nil)
    }

    @Test func favoritesAtLineStart() async throws {
        let schema = RedisFakeSchema()
        schema.favoriteList = [CompletionFavorite(keyword: "hot", name: "Hot keys", query: "SCAN 0 MATCH hot:* COUNT ;;100")]
        let items = try #require(await complete("ho|", schema: schema)).items
        let favorite = try #require(items.first)
        #expect(favorite.kind == .favorite)
        #expect(favorite.label == "hot" && favorite.detail == "Hot keys")
        #expect(favorite.insertText == "SCAN 0 MATCH hot:* COUNT 100")
        #expect(favorite.caretOffsetFromEnd == 3)
        // The keyword must start with what was typed.
        #expect(await labels("ot|", schema: schema).contains("hot") == false)
    }

    @Test func refilterUsesThePool() async throws {
        let engine = RedisCompletionEngine(schema: RedisFakeSchema())
        let result = try #require(await engine.complete(text: "h", caret: 1, manual: false, keywordCase: .matchTypedElseUpper))
        #expect(result.pool.count == RedisCompletionVocabulary.commands.count)
        #expect(engine.refilter(result, token: "hgeta", keywordCase: .matchTypedElseUpper).map(\.label) == ["HGETALL"])
        #expect(engine.refilter(result, token: "HGETA", keywordCase: .lower).map(\.label) == ["HGETALL"])
        // Backspacing to another letter widens again: the pool is every command.
        #expect(engine.refilter(result, token: "x", keywordCase: .matchTypedElseUpper).first?.label == "XACK")
        #expect(engine.refilter(result, token: "", keywordCase: .matchTypedElseUpper).isEmpty)
        #expect(engine.refilter(result, token: "hget k", keywordCase: .matchTypedElseUpper).isEmpty)
        #expect(engine.refilter(result, token: "zzqq", keywordCase: .matchTypedElseUpper).isEmpty)
    }

    @Test func refilterQuotesKeysForTheLiveToken() async throws {
        let schema = RedisFakeSchema()
        let engine = RedisCompletionEngine(schema: schema)
        // The pool was built on the space, before any quote was typed.
        let bare = try #require(await engine.complete(text: "GET ", caret: 4, manual: false, keywordCase: .matchTypedElseUpper))
        let doubled = engine.refilter(bare, token: "\"use", keywordCase: .matchTypedElseUpper)
        #expect(doubled.first?.label == "user:1" && doubled.first?.insertText == "\"user:1\"")
        #expect(engine.refilter(bare, token: "'ses", keywordCase: .matchTypedElseUpper).first?.insertText == "'session:abc'")
        #expect(engine.refilter(bare, token: "us", keywordCase: .matchTypedElseUpper).first?.insertText == "user:1")
        // And the other way: built inside a quote, refiltered without one.
        let quoted = try #require(await engine.complete(text: "GET \"us", caret: 7, manual: false, keywordCase: .matchTypedElseUpper))
        #expect(quoted.items.first?.insertText == "\"user:1\"")
        #expect(engine.refilter(quoted, token: "user:", keywordCase: .matchTypedElseUpper).first?.insertText == "user:1")
        #expect(engine.refilter(bare, token: "my", keywordCase: .matchTypedElseUpper).first?.insertText == "\"my key\"")
    }

    @Test func keyQuotingRoundTripsThroughTheParser() throws {
        let keys = ["plain", "my key", "it's", "say \"hi\"", "back\\slash", "trailing\\", "line\nbreak", "tab\there", "bell\u{07}", "semi;colon", "", "Schlüssel straße"]
        for key in keys {
            for quote: Character? in [nil, "\"", "'"] {
                let insert = RedisCompletionEngine.keyInsertText(key, quote: quote)
                #expect(!insert.contains("\n") && !insert.contains("\t"), "\(key) \(String(describing: quote))")
                let arguments = try RedisCommandParser.tokenize("GET " + insert)
                #expect(arguments.count == 2 && arguments[1] == Data(key.utf8), "\(key) \(String(describing: quote)) -> \(insert)")
            }
        }
        #expect(RedisCompletionEngine.keyInsertText("user:1", quote: nil) == "user:1")
        #expect(RedisCompletionEngine.keyInsertText("a\\", quote: "'") == "\"a\\\\\"")
        #expect(RedisCompletionEngine.keyInsertText("line\nbreak", quote: nil) == "\"line\\nbreak\"")
    }

    @Test func favoritesLeadTheirMatchGroup() async throws {
        let schema = RedisFakeSchema()
        schema.favoriteList = [CompletionFavorite(keyword: "hot", name: "Hot keys", query: "SCAN 0 MATCH hot:*")]
        #expect(await labels("h|", schema: schema).first == "hot")
        // A manual open on an empty line keeps every favorite in the pool; typing narrows by prefix only.
        let engine = RedisCompletionEngine(schema: schema)
        let all = try #require(await engine.complete(text: "", caret: 0, manual: true, keywordCase: .matchTypedElseUpper))
        #expect(all.items.first?.label == "hot")
        #expect(engine.refilter(all, token: "ho", keywordCase: .matchTypedElseUpper).first?.label == "hot")
        #expect(!engine.refilter(all, token: "ot", keywordCase: .matchTypedElseUpper).contains { $0.kind == .favorite })
    }

    @Test func countedKeyArguments() async throws {
        let schema = RedisFakeSchema()
        // Destination, then `numkeys` keys, then options.
        #expect(await labels("ZINTERSTORE |", schema: schema) == schema.keys)
        #expect(await complete("ZINTERSTORE dst |", manual: true, schema: schema) == nil)
        #expect(await labels("ZINTERSTORE dst 2 |", schema: schema) == schema.keys)
        #expect(await labels("ZINTERSTORE dst 2 a |", schema: schema) == schema.keys)
        #expect(await labels("ZINTERSTORE dst 2 a b |", manual: true, schema: schema) == ["WEIGHTS", "AGGREGATE", "SUM", "MIN", "MAX"])
        #expect(await labels("ZUNIONSTORE dst 1 |", schema: schema) == schema.keys)
        #expect(await labels("ZDIFFSTORE dst 1 |", schema: schema) == schema.keys)
        #expect(await labels("ZINTER 1 a W|", schema: schema) == ["WEIGHTS", "WITHSCORES"])
        // Scripts: keys only while numkeys lasts.
        #expect(await complete("EVAL \"return 1\" 0 |", manual: true, schema: schema) == nil)
        #expect(await labels("EVAL \"return 1\" 1 |", schema: schema) == schema.keys)
        #expect(await complete("EVAL \"return 1\" 1 k |", manual: true, schema: schema) == nil)
        #expect(await complete("FCALL f x |", manual: true, schema: schema) == nil)
        #expect(await labels("BLMPOP 0 1 |", schema: schema) == schema.keys)
        #expect(await labels("BLMPOP 0 1 a |", manual: true, schema: schema) == ["LEFT", "RIGHT", "COUNT"])
    }

    @Test func streamsAndTimeoutKeyArguments() async throws {
        let schema = RedisFakeSchema()
        #expect(await labels("XREAD |", manual: true, schema: schema) == ["COUNT", "BLOCK", "STREAMS"])
        #expect(await labels("XREAD COUNT 5 STREAMS |", schema: schema) == schema.keys)
        // Later arguments may be ids: offered once a name is being typed, not for ids.
        #expect(await complete("XREAD STREAMS s1 |", schema: schema) == nil)
        #expect(await labels("XREAD STREAMS s1 us|", schema: schema) == ["user:1", "user:2", "users:index"])
        #expect(await complete("XREAD STREAMS s1 0|", manual: true, schema: schema) == nil)
        #expect(await complete("XREADGROUP GROUP g c STREAMS s1 $|", manual: true, schema: schema) == nil)
        #expect(await labels("BLPOP |", schema: schema) == schema.keys)
        #expect(await complete("BLPOP a |", schema: schema) == nil)
        #expect(await labels("BLPOP a |", manual: true, schema: schema) == schema.keys)
        #expect(await complete("BLPOP a 5|", manual: true, schema: schema) == nil)
    }

    @Test func longLinesAreScannedWithoutKeepingThem() async throws {
        let value = String(repeating: "x", count: 200_000)
        let quoted = RedisCompletionEngine.analyze("SET k \"\(value)\" ", caret: 200_010)
        #expect(quoted.slot == .argument(command: "SET", index: 3))
        #expect(quoted.words == ["SET", "k", String(repeating: "x", count: RedisCompletionEngine.maxArgument)])
        #expect(await labels("SET k \"\(value)\" N|") == ["NX"])
        // An over-long argument at the caret is a value, never a name.
        #expect(RedisCompletionEngine.analyze("GET " + value, caret: 200_004).slot == nil)
        let many = "DEL " + Array(repeating: "k", count: 50_000).joined(separator: " ") + " "
        let analysis = RedisCompletionEngine.analyze(many, caret: (many as NSString).length)
        #expect(analysis.slot == .argument(command: "DEL", index: 50_001))
        #expect(analysis.words.count == RedisCompletionEngine.keptWords)
    }
}

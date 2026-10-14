import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct QueryLanguageTests {
    @Test func splitsMongoCommandsOnSemicolonsAndNewTopLevelCalls() {
        let text = """
        db.orders.find({ note: "a; b", items: [1, 2] })
          .sort({ _id: -1 })
        db.users.countDocuments({})
        // a comment
        use shop; show collections
        """
        let parts = QueryLanguage.mongo.split(text).map(\.text)
        #expect(parts.count == 4)
        #expect(parts[0].hasPrefix("db.orders.find") && parts[0].hasSuffix(".sort({ _id: -1 })"))
        #expect(parts[1] == "db.users.countDocuments({})")
        #expect(parts[2].hasSuffix("use shop"))
        #expect(parts[3] == "show collections")
    }

    @Test func mongoReadOnlyIgnoresFieldNamesAndStrings() {
        #expect(QueryLanguage.mongo.isReadOnly(#"db.orders.find({ updatedAt: { $gt: 1 }, note: ".delete(" })"#))
        #expect(QueryLanguage.mongo.isReadOnly("db.orders.aggregate([{ $match: { a: 1 } }])"))
        #expect(!QueryLanguage.mongo.isReadOnly("db.orders.updateOne({ _id: 1 }, { $set: { a: 2 } })"))
        #expect(!QueryLanguage.mongo.isReadOnly(#"db.orders.aggregate([{ "$out": "copy" }])"#))
        #expect(!QueryLanguage.mongo.isReadOnly("db.orders.drop()"))
    }

    @Test func redisSplitsLinesAndClassifiesCommands() {
        let parts = QueryLanguage.redis.split("GET a\n\n# note\n  HSET h f \"v w\"\n").map(\.text)
        #expect(parts == ["GET a", "HSET h f \"v w\""])
        #expect(QueryLanguage.redis.isReadOnly("hgetall user:1"))
        #expect(!QueryLanguage.redis.isReadOnly("DEL user:1"))
        #expect(QueryLanguage.redis.isReadOnly("CONFIG GET maxmemory"))
        #expect(!QueryLanguage.redis.isReadOnly("CONFIG SET maxmemory 1mb"))
        #expect(QueryLanguage.redis.isReadOnly("DB 1 GET other:db"))
        #expect(!QueryLanguage.redis.isReadOnly("DB 1 DEL other:db"))
    }

    @Test func duckdbDialect() {
        #expect(SQLDialect.duckdb.literal(.bytes(Data([0xab]))) == "from_hex('ab')")
        #expect(SQLDialect.duckdb.caseInsensitiveLike == "ILIKE")
    }
}

@Suite struct RedisSplitTests {
    @Test func semicolonsSeparateCommandsOutsideQuotes() {
        let parts = QueryLanguage.redis.split("SET a \"x;y\"; GET a\nDEL a").map(\.text)
        #expect(parts == ["SET a \"x;y\"", "GET a", "DEL a"])
    }
}

import Foundation
import Testing
@testable import FoxlumeQueryCore

// MARK: - BSON

@Suite("Mongo BSON")
struct MongoBSONTests {
    static let objectId = BSONObjectId(hex: "65a1b2c3d4e5f60718293a4b")

    /// One field per BSON type, in a deliberate (non-alphabetical) order.
    static var everyType: BSONDocument {
        var document = BSONDocument()
        document.append("z_double", .double(3.25))
        document.append("string", .string("Grüße \u{0}embedded NUL"))
        document.append("document", .document(["b": .int32(1), "a": .document(["deep": .bool(true)])]))
        document.append("array", .array([.int32(1), .string("two"), .document(["three": .int64(3)])]))
        document.append("binary", .binary(subtype: 0, data: Data([1, 2, 3, 4])))
        document.append("old_binary", .binary(subtype: 2, data: Data([9, 8])))
        document.append("uuid", .binary(subtype: 4, data: Data(hexString: "123e4567e89b42d3a456426614174000") ?? Data()))
        document.append("undefined", .undefined)
        document.append("objectId", .objectId(objectId ?? .generate()))
        document.append("bool", .bool(false))
        document.append("date", .date(1_714_555_800_250))
        document.append("pre_epoch", .date(-86_400_001))
        document.append("null", .null)
        document.append("regex", .regex(pattern: "^m[uü]ller", options: "im"))
        document.append("dbPointer", .dbPointer(namespace: "foxlume.users", id: objectId ?? .generate()))
        document.append("javascript", .javascript("function () { return 1; }"))
        document.append("symbol", .symbol("sym"))
        document.append("codeWithScope", .javascriptWithScope(code: "x + 1", scope: ["x": .int32(41)]))
        document.append("int32", .int32(-42))
        document.append("timestamp", .timestamp(seconds: 1_714_555_800, increment: 7))
        document.append("int64", .int64(9_007_199_254_740_993))
        document.append("decimal", .decimal128(BSONDecimal128("1234567890.123456789") ?? .nan))
        document.append("minKey", .minKey)
        document.append("maxKey", .maxKey)
        document.append("nan", .double(.infinity))
        return document
    }

    @Test func encodesTheSpecExample() throws {
        let bytes = try (["hello": .string("world")] as BSONDocument).encoded()
        #expect(bytes == [0x16, 0, 0, 0, 0x02] + Array("hello".utf8) + [0, 6, 0, 0, 0] + Array("world".utf8) + [0, 0])
    }

    @Test func roundTripsEveryTypeInOrder() throws {
        let original = Self.everyType
        let decoded = try BSONDocument(bytes: try original.encoded())
        #expect(decoded == original)
        #expect(decoded.keys == original.keys)
    }

    @Test func rejectsTruncatedAndCorruptInput() throws {
        let bytes = try Self.everyType.encoded()
        #expect(throws: BSONError.self) { try BSONDocument(bytes: Array(bytes.dropLast(3))) }
        var corrupt = bytes
        corrupt[4] = 0x42
        #expect(throws: BSONError.self) { try BSONDocument(bytes: corrupt) }
        #expect(throws: BSONError.self) { try (["bad\u{0}key": .null] as BSONDocument).encoded() }
    }

    @Test func objectIds() throws {
        let id = try #require(BSONObjectId(hex: "65A1B2C3D4E5F60718293A4B"))
        #expect(id.hex == "65a1b2c3d4e5f60718293a4b")
        #expect(id.timestamp == Date(timeIntervalSince1970: TimeInterval(0x65a1b2c3)))
        #expect(BSONObjectId(hex: "65a1b2c3") == nil)
        #expect(BSONObjectId(hex: "zza1b2c3d4e5f60718293a4b") == nil)
        let first = BSONObjectId.generate()
        let second = BSONObjectId.generate()
        #expect(first != second)
        #expect(abs(first.timestamp.timeIntervalSinceNow) < 5)
        #expect(BSONObjectId.looksLikeObjectId("65a1b2c3d4e5f60718293a4b"))
        #expect(!BSONObjectId.looksLikeObjectId("not-an-object-id-at-all!"))
    }

    /// Vectors from the BSON corpus (decimal128-1.json).
    @Test(arguments: [
        ("0", UInt64(0x3040_0000_0000_0000), UInt64(0), "0"),
        ("-0", 0xB040_0000_0000_0000, 0, "-0"),
        ("1", 0x3040_0000_0000_0000, 1, "1"),
        ("-1", 0xB040_0000_0000_0000, 1, "-1"),
        ("0.1", 0x303E_0000_0000_0000, 1, "0.1"),
        ("0.001234", 0x3034_0000_0000_0000, 1234, "0.001234"),
        ("0.00123400000", 0x302A_0000_0000_0000, 123_400_000, "0.00123400000"),
        ("1234567890123456789012345678901234", 0x3040_3CDE_6FFF_9732, 0xDE82_5CD0_7E96_AFF2, "1234567890123456789012345678901234"),
        ("9.999999999999999999999999999999999E-6143", 0x0001_ED09_BEAD_87C0, 0x378D_8E63_FFFF_FFFF, "9.999999999999999999999999999999999E-6143"),
        ("1E-6176", 0, 1, "1E-6176"),
        ("1E+3", 0x3046_0000_0000_0000, 1, "1E+3"),
        ("1.000000000000000000000000000000000E+6144", 0x5FFE_314D_C644_8D93, 0x38C1_5B0A_0000_0000, "1.000000000000000000000000000000000E+6144"),
        ("1.23E-7", 0x302E_0000_0000_0000, 123, "1.23E-7"),
        ("NaN", 0x7C00_0000_0000_0000, 0, "NaN"),
        ("Infinity", 0x7800_0000_0000_0000, 0, "Infinity"),
        ("-Infinity", 0xF800_0000_0000_0000, 0, "-Infinity"),
    ])
    func decimal128CorpusVectors(text: String, high: UInt64, low: UInt64, printed: String) throws {
        let value = try #require(BSONDecimal128(text))
        #expect(value.high == high)
        #expect(value.low == low)
        #expect(value.description == printed)
        #expect(BSONDecimal128(low: low, high: high).description == printed)
    }

    @Test func decimal128ClampsAndRejects() {
        #expect(BSONDecimal128("1E+6112")?.description == "1.0E+6112")
        #expect(BSONDecimal128("12345678901234567890123456789012345") == nil)
        #expect(BSONDecimal128("1234567890123456789012345678901234000")?.description == "1.234567890123456789012345678901234E+36")
        #expect(BSONDecimal128("abc") == nil)
        #expect(BSONDecimal128("1.2.3") == nil)
        #expect(BSONDecimal128("1E-6177") == nil)
        #expect(BSONDecimal128("0E-7000")?.description == "0E-6176")
    }
}

// MARK: - Extended JSON

@Suite("Mongo Extended JSON")
struct MongoExtendedJSONTests {
    @Test func canonicalRoundTripsEveryType() throws {
        let document = MongoBSONTests.everyType
        let text = ExtendedJSON.string(document, mode: .canonical)
        let parsed = try ExtendedJSON.parseDocument(text)
        // The deprecated subtype 2 is printed and read back as itself; only the wire form differs.
        #expect(parsed == document)
        #expect(parsed.keys == document.keys)
    }

    @Test func relaxedFormsMatchTheSpec() throws {
        #expect(ExtendedJSON.string(.date(1_356_351_330_501)) == #"{"$date":"2012-12-24T12:15:30.501Z"}"#)
        #expect(ExtendedJSON.string(.date(0)) == #"{"$date":"1970-01-01T00:00:00Z"}"#)
        #expect(ExtendedJSON.string(.date(-1)) == #"{"$date":{"$numberLong":"-1"}}"#)
        #expect(ExtendedJSON.string(.int64(42)) == "42")
        #expect(ExtendedJSON.string(.int64(42), mode: .canonical) == #"{"$numberLong":"42"}"#)
        #expect(ExtendedJSON.string(.int32(-7), mode: .canonical) == #"{"$numberInt":"-7"}"#)
        #expect(ExtendedJSON.string(.double(1)) == "1.0")
        #expect(ExtendedJSON.string(.double(-0.0)) == "-0.0")
        #expect(ExtendedJSON.string(.double(.nan)) == #"{"$numberDouble":"NaN"}"#)
        #expect(ExtendedJSON.string(.double(-.infinity)) == #"{"$numberDouble":"-Infinity"}"#)
        #expect(ExtendedJSON.string(.binary(subtype: 0x80, data: Data([0xFF]))) == #"{"$binary":{"base64":"/w==","subType":"80"}}"#)
        #expect(ExtendedJSON.string(.regex(pattern: "a\"b", options: "xi")) == #"{"$regularExpression":{"pattern":"a\"b","options":"ix"}}"#)
        #expect(ExtendedJSON.string(.timestamp(seconds: 123, increment: 4)) == #"{"$timestamp":{"t":123,"i":4}}"#)
        #expect(ExtendedJSON.string(.javascriptWithScope(code: "x", scope: ["x": .int32(1)])) == #"{"$code":"x","$scope":{"x":1}}"#)
        #expect(ExtendedJSON.string(.string("line\nbreak\u{1}")) == #""line\nbreak\u0001""#)
        let ordered: BSONDocument = ["z": .int32(1), "a": .int32(2), "m": .array([.minKey, .maxKey])]
        #expect(ExtendedJSON.string(ordered) == #"{"z":1,"a":2,"m":[{"$minKey":1},{"$maxKey":1}]}"#)
    }

    @Test func parsesCanonicalAndLegacyWrappers() throws {
        let text = #"""
        {"a":{"$numberLong":"9007199254740993"},"b":{"$numberDecimal":"1.10"},"c":{"$oid":"65a1b2c3d4e5f60718293a4b"},
         "d":{"$date":"2024-05-01T09:30:00.250+07:00"},"e":{"$uuid":"123e4567-e89b-42d3-a456-426614174000"},
         "f":{"$binary":"AQI=","$type":"05"},"g":{"$regex":"^a","$options":"i"},"h":{"$numberDouble":"-Infinity"},
         "i":{"$date":{"$numberLong":"-5"}},"j":{"$symbol":"s"},"k":{"$undefined":true},"l":{"$dbPointer":{"$ref":"db.c","$id":{"$oid":"65a1b2c3d4e5f60718293a4b"}}}}
        """#
        let document = try ExtendedJSON.parseDocument(text)
        #expect(document["a"] == .int64(9_007_199_254_740_993))
        #expect(document["b"] == .decimal128(try #require(BSONDecimal128("1.10"))))
        #expect(document["c"] == .objectId(try #require(BSONObjectId(hex: "65a1b2c3d4e5f60718293a4b"))))
        #expect(document["d"] == .date(1_714_530_600_250))
        #expect(document["e"] == .binary(subtype: 4, data: try #require(Data(hexString: "123e4567e89b42d3a456426614174000"))))
        #expect(document["f"] == .binary(subtype: 5, data: Data([1, 2])))
        #expect(document["g"] == .regex(pattern: "^a", options: "i"))
        #expect(document["h"] == .double(-.infinity))
        #expect(document["i"] == .date(-5))
        #expect(document["j"] == .symbol("s"))
        #expect(document["k"] == .undefined)
        #expect(document["l"] == .dbPointer(namespace: "db.c", id: try #require(BSONObjectId(hex: "65a1b2c3d4e5f60718293a4b"))))
        // Operators that only look like wrappers stay documents.
        #expect(try ExtendedJSON.parseDocument(#"{"total":{"$gt":100}}"#)["total"] == .document(["$gt": .int32(100)]))
        #expect(throws: MongoLiteralError.self) { try ExtendedJSON.parseDocument(#"{"a":{"$oid":"nothex"}}"#) }
    }

    @Test func relaxedNumbersPickTheSmallestIntegerType() throws {
        let document = try ExtendedJSON.parseDocument(#"{"a":1,"b":2147483648,"c":1.0,"d":1e3,"e":-0.0,"f":99999999999999999999}"#)
        #expect(document["a"] == .int32(1))
        #expect(document["b"] == .int64(2_147_483_648))
        #expect(document["c"] == .double(1))
        #expect(document["d"] == .double(1000))
        #expect(document["e"] == .double(-0.0))
        #expect(document["f"] == .double(1e20))
    }

    @Test func parsesShellSyntax() throws {
        let text = """
        { status: 'paid', "total": { $gt: NumberDecimal("100") }, at: ISODate("2024-01-15"), when: new Date("2024-01-15T10:00:00Z"),
          id: ObjectId("65a1b2c3d4e5f60718293a4b"), n: NumberLong("9007199254740993"), i: NumberInt(5), re: /ab+c\\/d/gi,
          u: UUID("123e4567-e89b-42d3-a456-426614174000"), b: BinData(0, "AQI="), h: HexData(0, "0102"), ts: Timestamp(5, 6),
          code: Code("f()"), min: MinKey(), max: MaxKey, ref: DBRef("users", 1), neg: -Infinity, list: [1, 2, ], // comment
          /* block */ ünïcode: true, }
        """
        let document = try ExtendedJSON.parseDocument(text)
        #expect(document.keys.first == "status")
        #expect(document["status"] == .string("paid"))
        #expect(document["total"] == .document(["$gt": .decimal128(try #require(BSONDecimal128("100")))]))
        #expect(document["at"] == .date(1_705_276_800_000))
        #expect(document["when"] == .date(1_705_312_800_000))
        #expect(document["n"] == .int64(9_007_199_254_740_993))
        #expect(document["i"] == .int32(5))
        #expect(document["re"] == .regex(pattern: "ab+c\\/d", options: "i"))
        #expect(document["u"] == .binary(subtype: 4, data: try #require(Data(hexString: "123e4567e89b42d3a456426614174000"))))
        #expect(document["b"] == .binary(subtype: 0, data: Data([1, 2])))
        #expect(document["h"] == document["b"])
        #expect(document["ts"] == .timestamp(seconds: 5, increment: 6))
        #expect(document["code"] == .javascript("f()"))
        #expect(document["min"] == .minKey)
        #expect(document["max"] == .maxKey)
        #expect(document["ref"] == .document(["$ref": .string("users"), "$id": .int32(1)]))
        #expect(document["neg"] == .double(-.infinity))
        #expect(document["list"] == .array([.int32(1), .int32(2)]))
        #expect(document["ünïcode"] == .bool(true))
        #expect(throws: MongoLiteralError.self) { try ExtendedJSON.parseDocument("{ a: Foo(1) }") }
        #expect(throws: MongoLiteralError.self) { try ExtendedJSON.parseDocument("{ a: 1 } trailing") }
    }

    @Test func templatesKeepNumberTypes() throws {
        let template: BSONValue = .document(["big": .int64(1), "ratio": .double(0.5), "price": .decimal128(try #require(BSONDecimal128("1"))), "nested": .document(["n": .int64(2)])])
        let parsed = try ExtendedJSON.parseValue(#"{"big":5,"ratio":2,"price":19.99,"nested":{"n":3},"new":7}"#, template: template)
        let document = try #require(parsed.documentValue)
        #expect(document["big"] == .int64(5))
        #expect(document["ratio"] == .double(2))
        #expect(document["price"] == .decimal128(try #require(BSONDecimal128("19.99"))))
        #expect(document["nested"] == .document(["n": .int64(3)]))
        #expect(document["new"] == .int32(7))
    }

    @Test func shellFormatterReadsBack() throws {
        let document = MongoBSONTests.everyType
        let shell = MongoShellFormatter.format(document, pretty: true)
        #expect(shell.contains(#"objectId: ObjectId("65a1b2c3d4e5f60718293a4b")"#))
        #expect(shell.contains(#"int64: NumberLong("9007199254740993")"#))
        #expect(shell.contains(#"uuid: UUID("123e4567-e89b-42d3-a456-426614174000")"#))
        #expect(shell.contains(#"date: ISODate("2024-05-01T09:30:00.250Z")"#))
        // Everything except types the shell has no literal for (undefined, DBPointer, symbol, old binary) reads back.
        var comparable = document
        for key in ["undefined", "dbPointer", "symbol", "old_binary"] { comparable.removeValue(forKey: key) }
        #expect(try ExtendedJSON.parseDocument(MongoShellFormatter.format(comparable, pretty: true)) == comparable)
    }

    @Test func isoDates() {
        #expect(ExtendedJSON.parseISODate("2024-05-01") == 1_714_521_600_000)
        #expect(ExtendedJSON.parseISODate("2024-05-01 09:30:00") == 1_714_555_800_000)
        #expect(ExtendedJSON.parseISODate("2024-05-01T09:30:00.25Z") == 1_714_555_800_250)
        #expect(ExtendedJSON.parseISODate("2024-05-01T16:30:00+0700") == 1_714_555_800_000)
        #expect(ExtendedJSON.parseISODate("May 1st") == nil)
        #expect(ExtendedJSON.isoDateText(1_714_555_800_000) == "2024-05-01T09:30:00Z")
        #expect(ExtendedJSON.isoDateText(-1) == "1969-12-31T23:59:59.999Z")
    }
}

// MARK: - Authentication

@Suite("Mongo SCRAM")
struct MongoSCRAMTests {
    /// RFC 5802 section 5, with the password used as is.
    @Test func sha1MatchesRFC5802() throws {
        var client = MongoSCRAMClient(hash: .sha1, username: "user", preparedPassword: "pencil", clientNonce: "fyko+d2lbbFgONRv9qkxdawL")
        #expect(client.clientFirstMessage == "n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL")
        let final = try client.clientFinalMessage(serverFirstMessage: "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096")
        #expect(final == "c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=")
        try client.verifyServerFinal("v=rmF9pqV8S7suAoZWja4dJRkFsKQ=")
    }

    /// The MongoDB auth specification's SCRAM-SHA-1 example, where the password is the hex MD5 digest.
    @Test func sha1MatchesMongoSpecVector() throws {
        #expect(MongoSCRAMClient.mongoPasswordDigest(username: "user", password: "pencil") == "1c33006ec1ffd90f9cadcbcc0e118200")
        var client = MongoSCRAMClient.mongo(mechanism: .scramSHA1, username: "user", password: "pencil", clientNonce: "fyko+d2lbbFgONRv9qkxdawL")
        let final = try client.clientFinalMessage(
            serverFirstMessage: "r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,s=rQ9ZY3MntBeuP3E1TDVC4w==,i=10000"
        )
        #expect(final == "c=biws,r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,p=MC2T8BvbmWRckDw8oWl5IVghwCY=")
        try client.verifyServerFinal("v=UMWeI25JD1yNYZRMpZ4VHvhZ9e0=")
    }

    /// RFC 7677 section 3, which is also the MongoDB SCRAM-SHA-256 example.
    @Test func sha256MatchesRFC7677() throws {
        var client = MongoSCRAMClient.mongo(mechanism: .scramSHA256, username: "user", password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO")
        #expect(client.clientFirstMessage == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
        let final = try client.clientFinalMessage(serverFirstMessage: "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
        #expect(final == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        try client.verifyServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
    }

    @Test func rejectsForgedServerSignatureAndWeakParameters() throws {
        var client = MongoSCRAMClient.mongo(mechanism: .scramSHA256, username: "user", password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO")
        _ = try client.clientFinalMessage(serverFirstMessage: "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
        #expect(throws: DatabaseError.self) { try client.verifyServerFinal("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=") }
        var weak = MongoSCRAMClient.mongo(mechanism: .scramSHA1, username: "u", password: "p", clientNonce: "abc")
        #expect(throws: DatabaseError.self) { try weak.clientFinalMessage(serverFirstMessage: "r=abcdef,s=QSXCR+Q6sek8bf92,i=100") }
        #expect(throws: DatabaseError.self) { try weak.clientFinalMessage(serverFirstMessage: "r=zzz,s=QSXCR+Q6sek8bf92,i=4096") }
    }

    @Test func escapesUserNamesAndNegotiates() {
        let client = MongoSCRAMClient.mongo(mechanism: .scramSHA256, username: "a=b,c", password: "x", clientNonce: "n")
        #expect(client.clientFirstMessageBare == "n=a=3Db=2Cc,r=n")
        #expect(MongoAuthenticator.negotiate(["SCRAM-SHA-1", "SCRAM-SHA-256"]) == .scramSHA256)
        #expect(MongoAuthenticator.negotiate(["SCRAM-SHA-1"]) == .scramSHA1)
        #expect(MongoAuthenticator.negotiate(nil) == .scramSHA1)
        #expect(MongoAuthMechanism(userText: "scram-sha-256") == .scramSHA256)
        #expect(MongoAuthMechanism(userText: "X.509") == .x509)
        #expect(MongoAuthMechanism(userText: "AWS IAM") == .aws)
        #expect(MongoAuthMechanism(userText: "magic") == nil)
    }
}

// MARK: - Connection strings and settings

@Suite("Mongo URI")
struct MongoURITests {
    @Test func parsesHostsCredentialsAndOptions() throws {
        let uri = try MongoConnectionString("mongodb://us%40er:p%3Aa%2Fss@db1.example.com:27018,db2.example.com,[::1]:27019/shop%2Dprod?authSource=admin&replicaSet=rs0&TLS=true&readPreference=secondaryPreferred&w=majority&authMechanism=SCRAM-SHA-1")
        #expect(!uri.isSRV)
        #expect(uri.hosts == [MongoHost(host: "db1.example.com", port: 27018), MongoHost(host: "db2.example.com"), MongoHost(host: "::1", port: 27019)])
        #expect(uri.user == "us@er")
        #expect(uri.password == "p:a/ss")
        #expect(uri.database == "shop-prod")
        #expect(uri.authSource == "admin")
        #expect(uri.replicaSet == "rs0")
        #expect(uri.tls == true)
        #expect(uri.readPreference == "secondaryPreferred")
        #expect(uri.writeConcern == "majority")
        #expect(uri.authMechanism == "SCRAM-SHA-1")
    }

    @Test func toleratesUnescapedSlashInPasswordAndPlusSigns() throws {
        let uri = try MongoConnectionString("mongodb://bob:a/b+c@localhost/?ssl=false")
        #expect(uri.password == "a/b+c")
        #expect(uri.database == nil)
        #expect(uri.tls == false)
        #expect(uri.hosts == [MongoHost(host: "localhost")])
    }

    @Test func srvRules() throws {
        let uri = try MongoConnectionString("mongodb+srv://cluster0.example.mongodb.net/app")
        #expect(uri.isSRV)
        #expect(uri.hosts.first?.host == "cluster0.example.mongodb.net")
        #expect(throws: DatabaseError.self) { try MongoConnectionString("mongodb+srv://a.example.com:27017/") }
        #expect(throws: DatabaseError.self) { try MongoConnectionString("mongodb+srv://a.example.com,b.example.com/") }
        #expect(throws: DatabaseError.self) { try MongoConnectionString("postgres://localhost") }
        #expect(throws: DatabaseError.self) { try MongoConnectionString("mongodb://") }
        #expect(throws: DatabaseError.self) { try MongoConnectionString("mongodb://host:99999") }
    }

    @Test func parsesDNSRecordData() {
        // priority 0, weight 5, port 27017, target "node1.example.com"
        var srv: [UInt8] = [0, 0, 0, 5, 0x69, 0x89]
        for label in ["node1", "example", "com"] {
            srv.append(UInt8(label.utf8.count))
            srv += Array(label.utf8)
        }
        srv.append(0)
        let record = MongoDNS.parseSRV(srv)
        #expect(record?.port == 27017)
        #expect(record?.weight == 5)
        #expect(record?.target == "node1.example.com")
        let txt: [UInt8] = [11] + Array("authSource=".utf8) + [5] + Array("admin".utf8)
        #expect(MongoDNS.parseTXT(txt) == ["authSource=admin"])
    }

    /// `.invalid` never resolves (RFC 2606), so this exercises the dnssd query loop and its negative answer.
    @Test func srvLookupOfAMissingNameFailsQuickly() {
        let started = Date()
        #expect(throws: DatabaseError.self) { try MongoDNS.resolveSRV("cluster0.example.invalid", timeout: 3) }
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(throws: DatabaseError.self) { try MongoDNS.resolveSRV("localhost", timeout: 1) }
    }

    private func settings(_ configure: (inout ConnectionConfig) -> Void, password: String = "pw") throws -> MongoSettings {
        var config = ConnectionConfig(kind: .mongodb, host: "db.local", port: 27017, user: "alice", database: "shop", sslMode: .prefer)
        configure(&config)
        return try MongoSettings.resolve(ConnectionParameters(config: config, password: password))
    }

    @Test func authSourceFollowsTheSpec() throws {
        #expect(try settings { _ in }.credential?.source == "shop")
        #expect(try settings { $0.database = "" }.credential?.source == "admin")
        #expect(try settings { $0.setOption(.mongoAuthSource, "users") }.credential?.source == "users")
        #expect(try settings({ _ in }, password: "").credential == nil)
        #expect(try settings { $0.user = "" }.credential == nil)
        #expect(try settings { $0.setOption(.mongoAuthMechanism, "PLAIN") }.credential?.source == "$external")
        #expect(try settings { $0.setOption(.mongoAuthMechanism, "SCRAM-SHA-1") }.credential?.mechanism == .scramSHA1)
        #expect(throws: DatabaseError.self) { try settings { $0.setOption(.mongoAuthMechanism, "bogus") } }
    }

    @Test func connectionStringOverridesTheForm() throws {
        let resolved = try settings {
            $0.setOption(.mongoConnectionString, "mongodb://bob:secret@h1:1,h2:2/app?authSource=admin&tls=true&tlsInsecure=true&w=2&readPreference=nearest")
            $0.sslMode = .verifyFull
        }
        #expect(resolved.hosts == [MongoHost(host: "h1", port: 1), MongoHost(host: "h2", port: 2)])
        #expect(resolved.credential?.user == "bob")
        #expect(resolved.credential?.password == "secret")
        #expect(resolved.credential?.source == "admin")
        #expect(resolved.database == "app")
        #expect(resolved.useTLS && resolved.requireTLS && !resolved.verifyCertificate)
        #expect(resolved.writeConcern == .int32(2))
        #expect(resolved.readPreference == "nearest")
        #expect(!resolved.directConnection)
        // The form password is used when the URI names a user without one.
        let noPassword = try settings { $0.setOption(.mongoConnectionString, "mongodb://carol@h1/") }
        #expect(noPassword.credential?.password == "pw")
        #expect(noPassword.credential?.source == "shop")
        #expect(throws: DatabaseError.self) { try settings { $0.setOption(.mongoReadPreference, "sometimes") } }
    }

    @Test func atlasHostsForceTLS() throws {
        let resolved = try settings {
            $0.host = "shard-00-00.abcde.mongodb.net"
            $0.sslMode = .disable
        }
        #expect(resolved.useTLS && resolved.requireTLS)
        let plain = try settings { $0.sslMode = .disable }
        #expect(!plain.useTLS)
        let hostURI = try settings { $0.host = "mongodb://bob:pw@h9:9/?authSource=admin" }
        #expect(hostURI.hosts == [MongoHost(host: "h9", port: 9)])
        #expect(hostURI.credential?.source == "admin")
    }
}

// MARK: - Wire protocol

@Suite("Mongo wire")
struct MongoWireTests {
    @Test func parsesOPMSGWithDocumentSequences() throws {
        var writer = BSONWriter()
        writer.uint32(0)
        writer.bytes.append(0)
        try writer.document(["ok": .double(1), "n": .int32(2)])
        writer.bytes.append(1)
        let start = writer.bytes.count
        writer.int32(0)
        try writer.cString("documents", what: "id")
        try writer.document(["a": .int32(1)])
        try writer.document(["a": .int32(2)])
        writer.setInt32(Int32(writer.bytes.count - start), at: start)
        let reply = try MongoLink.parseMessage(writer.bytes)
        #expect(reply["n"] == .int32(2))
        #expect(reply["documents"] == .array([.document(["a": .int32(1)]), .document(["a": .int32(2)])]))
    }

    @Test func mapsServerErrors() {
        let failed: BSONDocument = ["ok": .double(0), "errmsg": .string("bad thing"), "code": .int32(2), "codeName": .string("BadValue")]
        let error = MongoServerError.from(reply: failed)
        #expect(error?.code == 2)
        #expect(error?.databaseError.errorDescription == "[BadValue] bad thing")
        let writeErrors: BSONDocument = ["ok": .double(1), "n": .int32(0), "writeErrors": .array([
            .document(["index": .int32(0), "code": .int32(11000), "errmsg": .string("E11000 duplicate key")]),
            .document(["index": .int32(1), "code": .int32(11000), "errmsg": .string("E11000 duplicate key")]),
        ])]
        #expect(MongoServerError.from(reply: writeErrors)?.message == "E11000 duplicate key (and 1 more write errors)")
        #expect(MongoServerError.from(reply: writeErrors)?.code == 11000)
        #expect(MongoServerError.from(reply: ["ok": .int32(1)]) == nil)
        #expect(MongoServerError.from(reply: ["ok": .int32(1), "writeConcernError": .document(["code": .int32(64), "errmsg": .string("waiting")])])?.code == 64)
    }

    @Test func helloDescribesTopology() {
        #expect(MongoConnection.describeTopology(MongoHello(raw: ["isWritablePrimary": .bool(true)])) == "standalone")
        #expect(MongoConnection.describeTopology(MongoHello(raw: ["setName": .string("rs0"), "secondary": .bool(true)])) == "replica set rs0 (secondary)")
        #expect(MongoConnection.describeTopology(MongoHello(raw: ["msg": .string("isdbgrid")])) == "mongos")
    }
}

// MARK: - TLS fallback against a plaintext-only server

/// A tiny plaintext MongoDB imitation: it hangs up on a TLS ClientHello and answers every command with `ok: 1`.
final class FakeMongoServer: @unchecked Sendable {
    private(set) var port = 0
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var tlsAttempts = 0

    var tlsHandshakesRefused: Int {
        lock.lock()
        defer { lock.unlock() }
        return tlsAttempts
    }

    init() throws {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 4) == 0 else { throw DatabaseError.connection("fake server could not listen") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        let fd = listener
        Thread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                TestThreads.start { [weak self] in self?.serve(client) }
            }
        }.start()
    }

    func stop() {
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }

    private func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, count - offset) }
            guard n > 0 else { return nil }
            offset += n
        }
        return bytes
    }

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        let hello: BSONDocument = ["ismaster": .bool(true), "maxWireVersion": .int32(17), "minWireVersion": .int32(0), "version": .string("0.0.0-fake"), "ok": .double(1)]
        while let header = readExactly(fd, 16) {
            if header[0] == 0x16, header[1] == 0x03 {
                lock.lock()
                tlsAttempts += 1
                lock.unlock()
                return
            }
            var reader = BSONReader(header)
            guard let length = try? reader.int32(), let requestID = try? reader.int32(), (try? reader.int32()) != nil,
                  let opCode = try? reader.int32(), readExactly(fd, Int(length) - 16) != nil
            else { return }
            var reply = BSONWriter()
            reply.int32(0)
            reply.int32(1)
            reply.int32(requestID)
            if opCode == 2004 {
                reply.int32(1)
                reply.int32(0)
                reply.uint64(0)
                reply.int32(0)
                reply.int32(1)
            } else {
                reply.int32(2013)
                reply.uint32(0)
                reply.bytes.append(0)
            }
            guard (try? reply.document(hello)) != nil else { return }
            reply.setInt32(Int32(reply.bytes.count), at: 0)
            _ = reply.bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
    }
}

@Suite("Mongo TLS fallback", .serialized)
struct MongoTLSFallbackTests {
    private func connection(port: Int, sslMode: SSLMode) -> MongoConnection {
        // Generous: on a loaded CI machine the fake server can take seconds to answer. A refused TLS handshake still
        // fails at once, so the tests below never wait this long.
        let config = ConnectionConfig(kind: .mongodb, host: "127.0.0.1", port: port, database: "fake", sslMode: sslMode, connectTimeout: 15)
        return MongoConnection(parameters: ConnectionParameters(config: config, password: ""))
    }

    @Test func preferFallsBackToPlaintext() throws {
        let server = try FakeMongoServer()
        defer { server.stop() }
        let connection = connection(port: server.port, sslMode: .prefer)
        try connection.connect()
        defer { connection.close() }
        #expect(!connection.isTLS)
        #expect(connection.serverVersion == "0.0.0-fake")
        #expect(server.tlsHandshakesRefused == 1)
    }

    @Test func requireFailsWhenTheServerRefusesTLS() throws {
        let server = try FakeMongoServer()
        defer { server.stop() }
        let error = #expect(throws: DatabaseError.self) { try connection(port: server.port, sslMode: .require).connect() }
        guard case .connection(let message) = error else {
            Issue.record("expected a connection error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("TLS handshake"))
    }

    @Test func disabledNeverTriesTLS() throws {
        let server = try FakeMongoServer()
        defer { server.stop() }
        let connection = connection(port: server.port, sslMode: .disable)
        try connection.connect()
        connection.close()
        #expect(server.tlsHandshakesRefused == 0)
    }
}

// MARK: - Browsing rules

@Suite("Mongo browse rules")
struct MongoBrowseRuleTests {
    @Test func filterRulesBecomeTypedConditions() throws {
        let types = ["_id": "ObjectId", "total": "decimal", "qty": "INTEGER", "paid": "BOOLEAN", "createdAt": "TIMESTAMP", "name": "VARCHAR"]
        func condition(_ rule: FilterRule) -> BSONDocument? { MongoFilterBuilder.condition(for: rule, typeName: types[rule.column]) }
        let oid = try #require(BSONObjectId(hex: "65a1b2c3d4e5f60718293a4b"))

        #expect(condition(FilterRule(column: "_id", op: .equals, value: "65a1b2c3d4e5f60718293a4b")) == ["_id": .document(["$in": .array([.objectId(oid), .string("65a1b2c3d4e5f60718293a4b")])])])
        #expect(condition(FilterRule(column: "unknown", op: .equals, value: "65a1b2c3d4e5f60718293a4b")) == ["unknown": .document(["$in": .array([.objectId(oid), .string("65a1b2c3d4e5f60718293a4b")])])])
        #expect(condition(FilterRule(column: "qty", op: .greaterThan, value: "5")) == ["qty": .document(["$gt": .int32(5)])])
        #expect(condition(FilterRule(column: "total", op: .lessOrEqual, value: "19.99")) == ["total": .document(["$lte": .decimal128(try #require(BSONDecimal128("19.99")))])])
        #expect(condition(FilterRule(column: "paid", op: .notEquals, value: "true")) == ["paid": .document(["$ne": .bool(true)])])
        #expect(condition(FilterRule(column: "name", op: .contains, value: "a.b(c")) == ["name": .regex(pattern: #"a\.b\(c"#, options: "i")])
        #expect(condition(FilterRule(column: "name", op: .startsWith, value: "Müller")) == ["name": .regex(pattern: "^Müller", options: "i")])
        #expect(condition(FilterRule(column: "name", op: .endsWith, value: "$")) == ["name": .regex(pattern: #"\$$"#, options: "i")])
        #expect(condition(FilterRule(column: "name", op: .notContains, value: "x")) == ["name": .document(["$not": .regex(pattern: "x", options: "i")])])
        #expect(condition(FilterRule(column: "name", op: .isNull)) == ["name": .null])
        #expect(condition(FilterRule(column: "name", op: .isNotNull)) == ["name": .document(["$ne": .null])])
        #expect(condition(FilterRule(column: "qty", op: .inList, value: "1, 2,3")) == ["qty": .document(["$in": .array([.int32(1), .int32(2), .int32(3)])])])
        #expect(condition(FilterRule(column: "misc", op: .equals, value: "42")) == ["misc": .document(["$in": .array([.int32(42), .string("42")])])])
        #expect(condition(FilterRule(column: "createdAt", op: .equals, value: "2024-01-15")) == ["createdAt": .document(["$gte": .date(1_705_276_800_000), "$lt": .date(1_705_363_200_000)])])
        #expect(condition(FilterRule(column: "createdAt", op: .greaterOrEqual, value: "2024-01-15T10:00:00Z")) == ["createdAt": .document(["$gte": .date(1_705_312_800_000)])])
        #expect(condition(FilterRule(column: "name", op: .equals, value: "x", isEnabled: false)) == nil)

        let combined = MongoFilterBuilder.filter(
            rules: [FilterRule(column: "qty", op: .greaterThan, value: "1")],
            fieldTypes: types,
            raw: try ExtendedJSON.parseDocument(#"{ status: "paid", total: { $gt: 100 } }"#)
        )
        #expect(combined == ["$and": .array([
            .document(["qty": .document(["$gt": .int32(1)])]),
            .document(["status": .string("paid"), "total": .document(["$gt": .int32(100)])]),
        ])])
        #expect(MongoFilterBuilder.filter(rules: [], fieldTypes: [:], raw: nil).isEmpty)
    }

    @Test func cellsFollowTheDisplayRules() throws {
        #expect(MongoCellCodec.cell(nil) == .missing)
        #expect(MongoCellCodec.cell(.null) == .null)
        #expect(MongoCellCodec.cell(.objectId(try #require(BSONObjectId(hex: "65a1b2c3d4e5f60718293a4b")))) == .text("65a1b2c3d4e5f60718293a4b"))
        #expect(MongoCellCodec.cell(.date(1_714_555_800_250)) == .text("2024-05-01T09:30:00.250Z"))
        #expect(MongoCellCodec.cell(.decimal128(try #require(BSONDecimal128("1.50")))) == .text("1.50"))
        #expect(MongoCellCodec.cell(.bool(true)) == .text("true"))
        #expect(MongoCellCodec.cell(.double(.nan)) == .text("NaN"))
        #expect(MongoCellCodec.cell(.double(-.infinity)) == .text("-Infinity"))
        #expect(MongoCellCodec.cell(.binary(subtype: 0, data: Data([1, 2]))) == .bytes(Data([1, 2])))
        #expect(MongoCellCodec.cell(.binary(subtype: 4, data: try #require(Data(hexString: "123e4567e89b42d3a456426614174000")))) == .text(#"UUID("123e4567-e89b-42d3-a456-426614174000")"#))
        #expect(MongoCellCodec.cell(.javascript("f()")) == .text(#"Code("f()")"#))
        #expect(MongoCellCodec.cell(.document(["$ref": .string("users"), "$id": .int32(7)])) == .text(#"DBRef("users", 7)"#))
        #expect(MongoCellCodec.cell(.document(["b": .int64(5), "a": .date(0)])) == .text(#"{"b":5,"a":{"$date":"1970-01-01T00:00:00Z"}}"#))
        let long = BSONValue.array(Array(repeating: .string(String(repeating: "x", count: 100)), count: 200))
        if case .text(let text) = MongoCellCodec.cell(long) {
            #expect(text.count == MongoCellCodec.maxNestedLength + 1)
            #expect(text.hasSuffix("…"))
        } else {
            Issue.record("nested values render as text")
        }
    }

    @Test func columnTypesVoteAndOrder() {
        let documents: [BSONDocument] = [
            ["_id": .int32(1), "b": .int64(1), "a": .null],
            ["_id": .int32(2), "b": .int64(2), "c": .string("x")],
            ["_id": .int32(3), "b": .double(2.5), "a": .document([:])],
        ]
        let columns = MongoGrid.columns(for: documents)
        #expect(columns.map(\.name) == ["_id", "a", "b", "c"])
        #expect(columns.map(\.typeName) == ["INTEGER", "JSON", "BIGINT", "VARCHAR"])
        let result = MongoGrid.result(documents)
        #expect(result.rows[1][1] == .missing)
        #expect(result.rows[0][1] == .null)
        #expect(result.columns[2].isNumeric)
    }

    @Test func editedTextKeepsTheStoredType() throws {
        func parse(_ text: String, _ original: BSONValue?, _ type: String? = nil) throws -> BSONValue? {
            try MongoCellCodec.value(fromCell: .text(text), original: original, typeName: type, field: "f")
        }
        #expect(try parse("7", .int32(1)) == .int32(7))
        #expect(try parse("9007199254740995", .int32(1)) == .int64(9_007_199_254_740_995))
        #expect(try parse("7", .int64(1)) == .int64(7))
        #expect(try parse("7", .double(1)) == .double(7))
        #expect(try parse("7.10", .decimal128(try #require(BSONDecimal128("1")))) == .decimal128(try #require(BSONDecimal128("7.10"))))
        #expect(try parse("2024-01-15T10:00:00.5Z", .date(0)) == .date(1_705_312_800_500))
        #expect(try parse("65a1b2c3d4e5f60718293a4b", .objectId(.generate())) == .objectId(try #require(BSONObjectId(hex: "65a1b2c3d4e5f60718293a4b"))))
        #expect(try parse("false", .bool(true)) == .bool(false))
        #expect(try parse("12", .string("x")) == .string("12"))
        #expect(try parse("12", nil, "INTEGER") == .int32(12))
        #expect(try parse("12", .null, "VARCHAR") == .string("12"))
        #expect(try parse("plain words", nil, "JSON") == .string("plain words"))
        #expect(try parse("{ a: 1 }", nil, "JSON") == .document(["a": .int32(1)]))
        #expect(try parse(#"NumberLong("12")"#, .string("x")) == .int64(12))
        #expect(try parse("0x0a0b", .binary(subtype: 0, data: Data())) == .binary(subtype: 0, data: Data([10, 11])))
        #expect(try parse(#"UUID("123e4567-e89b-42d3-a456-426614174000")"#, .binary(subtype: 4, data: Data())) == .binary(subtype: 4, data: try #require(Data(hexString: "123e4567e89b42d3a456426614174000"))))
        #expect(try parse(#"Code("g()")"#, .javascript("f()")) == .javascript("g()"))
        #expect(try MongoCellCodec.value(fromCell: .missing, original: .int32(1), typeName: nil, field: "f") == nil)
        #expect(throws: DatabaseError.self) { try parse("abc", .int32(1)) }
        #expect(throws: DatabaseError.self) { try parse("yesterday", .date(0)) }
        #expect(throws: DatabaseError.self) { try parse("{ broken", .document([:])) }
    }

    @Test func nestedEditsBecomeDottedPaths() throws {
        let old: BSONValue = .document(["city": .string("Genève"), "zip": .int64(530_000), "geo": .document(["lat": .double(16.4), "lng": .double(107.5)]), "old": .bool(true)])
        let new = try ExtendedJSON.parseValue(#"{"city":"Zürich","zip":530000,"geo":{"lat":16.4,"lng":108},"extra":1}"#, template: old)
        var set = BSONDocument()
        var unset = BSONDocument()
        MongoCellCodec.diff(path: "address", old: old, new: new, set: &set, unset: &unset)
        #expect(set == ["address.city": .string("Zürich"), "address.geo.lng": .double(108), "address.extra": .int32(1)])
        #expect(unset == ["address.old": .string("")])

        var arraySet = BSONDocument()
        var arrayUnset = BSONDocument()
        MongoCellCodec.diff(path: "tags", old: .array([.string("a"), .string("b")]), new: .array([.string("a"), .string("c")]), set: &arraySet, unset: &arrayUnset)
        #expect(arraySet == ["tags.1": .string("c")])
        var resized = BSONDocument()
        MongoCellCodec.diff(path: "tags", old: .array([.string("a")]), new: .array([.string("a"), .string("c")]), set: &resized, unset: &arrayUnset)
        #expect(resized == ["tags": .array([.string("a"), .string("c")])])
    }

    @Test func affectedRowsFromWriteResults() {
        #expect(MongoConnection.affectedRows(["acknowledged": .bool(true), "insertedId": .int32(1)]) == 1)
        #expect(MongoConnection.affectedRows(["insertedCount": .int32(3)]) == 3)
        #expect(MongoConnection.affectedRows(["matchedCount": .int32(4), "modifiedCount": .int32(2), "upsertedCount": .int32(1)]) == 3)
        #expect(MongoConnection.affectedRows(["deletedCount": .int32(5)]) == 5)
        #expect(MongoConnection.affectedRows(["ok": .double(1)]) == nil)
    }

    @Test func scriptPreparation() {
        #expect(MongoScriptRuntime.prepare("const x = 1") == "var x = 1")
        #expect(MongoScriptRuntime.prepare("  let y = await db.c.findOne()") == "  var y = db.c.findOne()")
        #expect(MongoScriptRuntime.prepare("// totals\n/* note */ const t = 1") == "// totals\n/* note */ var t = 1")
        #expect(MongoScriptRuntime.prepare("for (let i = 0; i < 2; i++) {}") == "for (let i = 0; i < 2; i++) {}")
        #expect(MongoScriptRuntime.prepare(#"print("await me")"#) == #"print("await me")"#)
        #expect(MongoScriptRuntime.prepare("x.awaited = 1") == "x.awaited = 1")
    }

    @Test func capabilities() {
        let connection = MongoConnection(parameters: ConnectionParameters(config: ConnectionConfig(kind: .mongodb), password: ""))
        let capabilities = connection.capabilities
        #expect(capabilities.queryLanguage == .mongo)
        #expect(capabilities.objectNoun == "collection")
        #expect(capabilities.rowNoun == "document")
        #expect(!capabilities.savesAtomically)
        #expect(!capabilities.supportsForeignKeys)
        #expect(capabilities.supportsFieldRemoval)
        #expect(capabilities.immutableColumns == ["_id"])
        #expect(capabilities.rawFilterLabel == "Filter")
        #expect(capabilities.rawFilterPlaceholder == #"{ status: "paid", total: { $gt: 100 } }"#)
    }
}

// MARK: - Live server

enum MongoTestServer {
    static let host = ProcessInfo.processInfo.environment["FQ_MONGO_HOST"] ?? "127.0.0.1"
    static let port = Int(ProcessInfo.processInfo.environment["FQ_MONGO_PORT"] ?? "") ?? 57017

    static let isAvailable: Bool = {
        let transport = SocketTransport()
        defer { transport.close() }
        guard (try? transport.connect(host: host, port: port, timeout: 1)) != nil else { return false }
        return ensureSeeded()
    }()

    /// Runs scripts/seed-mongo.js when the root user or the sample data is missing.
    private static func ensureSeeded() -> Bool {
        if let connection = try? connect(), let count = try? connection.execute("db.orders.estimatedDocumentCount()", rowLimit: nil).first?.rows.first?.first, count == .text("250") {
            connection.close()
            return true
        }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/seed-mongo.js")
        guard let text = try? String(contentsOf: script, encoding: .utf8) else { return false }
        let anonymous = make(user: "", password: "", database: "foxlume", sslMode: .disable)
        defer { anonymous.close() }
        guard (try? anonymous.connect()) != nil, (try? anonymous.execute(text, rowLimit: nil)) != nil else { return false }
        return true
    }

    static func make(user: String = "root", password: String = "root", database: String = "foxlume", sslMode: SSLMode = .disable, options: [ConnectionOption: String] = [:]) -> MongoConnection {
        var config = ConnectionConfig(kind: .mongodb, host: host, port: port, user: user, database: database, sslMode: sslMode)
        if user == "root", options[.mongoAuthSource] == nil { config.setOption(.mongoAuthSource, "admin") }
        for (key, value) in options { config.setOption(key, value) }
        return MongoConnection(parameters: ConnectionParameters(config: config, password: password))
    }

    static func connect(user: String = "root", password: String = "root", database: String = "foxlume", sslMode: SSLMode = .disable, options: [ConnectionOption: String] = [:]) throws -> MongoConnection {
        let connection = make(user: user, password: password, database: database, sslMode: sslMode, options: options)
        try connection.connect()
        return connection
    }

}

@Suite("Mongo live server", .serialized, .enabled(if: MongoTestServer.isAvailable, "needs the MongoDB test server on 57017"))
struct MongoLiveTests {
    @Test func scram256OverPlaintextAndTLS() throws {
        let plain = try MongoTestServer.connect()
        defer { plain.close() }
        #expect(!plain.isTLS)
        #expect(plain.serverVersion.first?.isNumber == true)
        #expect(plain.topology == "standalone")
        let status = try plain.execute("db.runCommand({ connectionStatus: 1 }).authInfo.authenticatedUsers[0].user", rowLimit: nil)
        #expect(status.first?.rows.first?.first == .text("root"))

        let secure = try MongoTestServer.connect(sslMode: .require)
        defer { secure.close() }
        #expect(secure.isTLS)
        #expect(try secure.execute("db.runCommand({ ping: 1 }).ok", rowLimit: nil).first?.rows.first?.first == .text("1"))

        let preferred = try MongoTestServer.connect(sslMode: .prefer)
        defer { preferred.close() }
        #expect(preferred.isTLS)
    }

    @Test func verifyFullRejectsTheSelfSignedCertificate() {
        do {
            let connection = try MongoTestServer.connect(sslMode: .verifyFull)
            connection.close()
            Issue.record("verifyFull should fail against a self-signed certificate")
        } catch DatabaseError.connection(let message) {
            #expect(message.contains("could not be verified"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func readerUsesSCRAMSHA1WithItsAuthSource() throws {
        let reader = try MongoTestServer.connect(user: "reader", password: "readerpass", database: "foxlume", options: [.mongoAuthMechanism: "SCRAM-SHA-1"])
        defer { reader.close() }
        #expect(try reader.execute("db.orders.countDocuments()", rowLimit: nil).first?.rows.first?.first == .text("250"))
        #expect(throws: DatabaseError.self) { try reader.execute("db.orders.insertOne({ x: 1 })", rowLimit: nil) }
        // Negotiation also lands on SCRAM-SHA-1 because that is the only mechanism the user has.
        let negotiated = try MongoTestServer.connect(user: "reader", password: "readerpass", database: "foxlume")
        negotiated.close()
    }

    @Test(arguments: [("root", SSLMode.disable), ("reader", SSLMode.require)])
    func wrongPasswordIsAnAuthenticationError(user: String, sslMode: SSLMode) {
        let connection = MongoTestServer.make(user: user, password: "wrong", sslMode: sslMode)
        let error = #expect(throws: DatabaseError.self) { try connection.connect() }
        guard case .authentication(let message) = error else {
            Issue.record("expected an authentication error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("Authentication failed"))
    }

    @Test func connectionStringWithAuthSource() throws {
        let uri = "mongodb://root:root@\(MongoTestServer.host):\(MongoTestServer.port),\(MongoTestServer.host):1/analytics?authSource=admin&tls=true&w=majority"
        let connection = try MongoTestServer.connect(user: "", password: "", options: [.mongoConnectionString: uri])
        defer { connection.close() }
        #expect(connection.currentDatabase == "analytics")
        #expect(connection.isTLS)
        let result = try connection.execute("db.events.insertOne({ probe: true }); db.events.deleteMany({ probe: true })", rowLimit: nil)
        #expect(result.last?.affectedRows == 1)

        // The first reachable host wins.
        let fallback = "mongodb://reader:readerpass@127.0.0.1:1,\(MongoTestServer.host):\(MongoTestServer.port)/foxlume?authMechanism=SCRAM-SHA-1"
        let second = try MongoTestServer.connect(user: "", password: "", options: [.mongoConnectionString: fallback])
        defer { second.close() }
        #expect(second.link?.port == MongoTestServer.port)
    }

    @Test func catalog() throws {
        let connection = try MongoTestServer.connect()
        defer { connection.close() }
        let databases = try connection.databases()
        #expect(databases.contains("foxlume") && databases.contains("analytics") && databases.contains("admin"))
        let tables = try connection.tables(schema: nil)
        let byName = Dictionary(tables.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byName["orders"]?.kind == .table)
        #expect(byName["orders"]?.estimatedRows == 250)
        #expect(byName["order_summary"]?.kind == .view)
        #expect(byName["system.views"]?.kind == .systemTable)
        #expect(tables.map(\.name) == tables.map(\.name).sorted())
        #expect(try connection.schemas().isEmpty)

        let orders = try connection.structure(of: TableRef(name: "orders"))
        #expect(orders.columns.map(\.name) == ["_id", "createdAt", "items", "paidAt", "status", "total", "userId"])
        #expect(orders.columns.map(\.dataType) == ["ObjectId", "TIMESTAMP", "JSON", "TIMESTAMP", "VARCHAR", "decimal", "INTEGER"])
        #expect(orders.primaryKey == ["_id"])
        #expect(orders.columns.first { $0.name == "paidAt" }?.isNullable == true)
        #expect(orders.indexes.contains { $0.name == "userId_hashed" && $0.method == "hashed" })
        #expect(orders.foreignKeys.isEmpty)

        let users = try connection.structure(of: TableRef(name: "users"))
        #expect(users.columns.contains { $0.name == "phone" && $0.dataType == "VARCHAR" })
        #expect(users.indexes.contains { $0.method == "text" && $0.columns == ["name"] })
        #expect(users.indexes.contains { $0.method == "2dsphere" })
        #expect(users.indexes.contains { $0.name == "email_1" && $0.isUnique })

        let ddl = try connection.ddl(of: TableRef(name: "users"))
        #expect(ddl.hasPrefix(#"db.createCollection("users", {"#))
        #expect(ddl.contains("$jsonSchema"))
        #expect(ddl.contains(#"db.getCollection("users").createIndex({ email: 1 }, { name: "email_1", unique: true });"#))
        let view = try connection.ddl(of: TableRef(name: "order_summary"))
        #expect(view.hasPrefix(#"db.createView("order_summary", "orders", ["#))

        try connection.useDatabase("analytics")
        #expect(connection.currentDatabase == "analytics")
        #expect(try connection.tables(schema: nil).map(\.name) == ["events"])
    }

    @Test func shellStatements() throws {
        let connection = try MongoTestServer.connect()
        defer { connection.close() }
        let results = try connection.execute("""
            db.orders.find({ status: "paid" }).sort({ total: -1 }).limit(5)
            db.orders.aggregate([{ $group: { _id: "$status", n: { $sum: 1 } } }, { $sort: { _id: 1 } }])
            db.orders.distinct("status")
            db.orders.countDocuments({ status: "paid" });
            const paid = db.orders.find({ status: "paid" }).toArray();
            print("paid", paid.length);
            use analytics
            show collections
            """, rowLimit: nil)
        #expect(results.count == 8)
        #expect(results[0].rows.count == 5)
        #expect(results[0].columns.first?.name == "_id")
        #expect(results[0].columns.first { $0.name == "total" }?.typeName == "decimal")
        #expect(results[1].rows.map { $0[0] } == ["cancelled", "paid", "pending", "refunded", "shipped"].map { .text($0) })
        #expect(results[2].columns.map(\.name) == ["result"])
        #expect(results[2].rows.count == 5)
        #expect(results[3].rows.first?.first == .text("50"))
        #expect(results[5].columns.map(\.name) == ["output"])
        #expect(results[5].rows.first?.first == .text("paid 50"))
        #expect(results[6].message == "switched to db analytics")
        #expect(results[7].rows.first?.first == .text("events"))
        #expect(connection.currentDatabase == "analytics")

        // Variables persist across runs, and so does `use`.
        let again = try connection.execute("paid.length; db.getName()", rowLimit: nil)
        #expect(again[0].rows.first?.first == .text("50"))
        #expect(again[1].rows.first?.first == .text("analytics"))
    }

    @Test func writesReportAffectedRows() throws {
        let connection = try MongoTestServer.connect()
        defer { connection.close() }
        let results = try connection.execute("""
            db.fq_test_writes.drop()
            db.fq_test_writes.insertOne({ n: 1 })
            db.fq_test_writes.insertMany([{ n: 2 }, { n: 3 }, { n: 4 }])
            db.fq_test_writes.updateMany({ n: { $gte: 3 } }, { $inc: { n: 10 } })
            db.fq_test_writes.deleteMany({})
            db.fq_test_writes.drop()
            """, rowLimit: nil)
        #expect(results.map(\.affectedRows) == [nil, 1, 3, 2, 4, nil])
    }

    @Test func errorsLeaveTheSessionUsable() throws {
        let connection = try MongoTestServer.connect()
        defer { connection.close() }
        #expect(throws: DatabaseError.self) { try connection.execute("db.orders.find({ status: ", rowLimit: nil) }
        #expect(throws: DatabaseError.self) { try connection.execute("db.orders.aggregate([{ $bogus: 1 }])", rowLimit: nil) }
        do {
            _ = try connection.execute("db.users.insertOne({ _id: 1, name: 'dup', email: 'x' })", rowLimit: nil)
            Issue.record("duplicate key should fail")
        } catch DatabaseError.server(let message, let code, _) {
            #expect(message.contains("E11000"))
            #expect(code == "DuplicateKey" || code == "11000")
        }
        #expect(try connection.execute("db.orders.countDocuments()", rowLimit: nil).first?.rows.first?.first == .text("250"))
        // A JavaScript exception thrown by user code keeps its message.
        do {
            _ = try connection.execute("throw new Error('boom')", rowLimit: nil)
        } catch DatabaseError.server(let message, _, _) {
            #expect(message.contains("boom"))
        }
    }

    @Test func rowLimitTruncates() throws {
        let connection = try MongoTestServer.connect()
        defer { connection.close() }
        let cursor = try connection.execute("db.orders.find()", rowLimit: 5)
        #expect(cursor.first?.rows.count == 5)
        #expect(cursor.first?.truncated == true)
        let array = try connection.execute("db.orders.find().toArray()", rowLimit: 7)
        #expect(array.first?.rows.count == 7)
        #expect(array.first?.truncated == true)
        let exact = try connection.execute("db.orders.find().limit(5)", rowLimit: 5)
        #expect(exact.first?.truncated == false)
    }

    @Test func everyBSONTypeRendersPerTheSpec() throws {
        let connection = try MongoTestServer.connect()
        defer { connection.close() }
        let result = try #require(connection.execute("db.types_demo.find({}, { type: 1, value: 1 }).sort({ _id: 1 })", rowLimit: nil).first)
        let rendered = Dictionary(result.rows.map { ($0[1].textValue ?? "", $0[2]) }, uniquingKeysWith: { first, _ in first })
        #expect(rendered["double"] == .text("3.14159"))
        #expect(rendered["objectId"] == .text("65a1b2c3d4e5f60718293a4b"))
        #expect(rendered["date"] == .text("2024-05-01T09:30:00.250Z"))
        #expect(rendered["decimal128"] == .text("1234567890.123456789"))
        #expect(rendered["int64"] == .text("9007199254740993"))
        #expect(rendered["bool"] == .text("true"))
        #expect(rendered["null"] == .null)
        #expect(rendered["nan"] == .text("NaN"))
        #expect(rendered["binary"] == .bytes(Data([1, 2, 3, 4])))
        #expect(rendered["uuid"] == .text(#"UUID("123e4567-e89b-42d3-a456-426614174000")"#))
        #expect(rendered["javascript"] == .text(#"Code("function () { return 1; }")"#))
        #expect(rendered["dbref"] == .text(#"DBRef("users", 1)"#))
        #expect(rendered["object"] == .text(#"{"a":1,"b":{"c":"nested","d":5}}"#))
        #expect(rendered["sparse"] == .missing)
    }

    @Test func browseFiltersSortsAndPages() throws {
        let connection = try MongoTestServer.connect()
        defer { connection.close() }
        let table = TableRef(name: "orders")
        _ = try connection.structure(of: table)
        var query = TableQuery(table: table, filters: [FilterRule(column: "status", op: .equals, value: "paid")], sort: [SortKey(column: "total", ascending: false)], pageSize: 20)
        let page = try connection.fetchRows(query)
        #expect(page.rows.count == 20)
        let totalIndex = try #require(page.columns.firstIndex { $0.name == "total" })
        let totals = page.rows.compactMap { $0[totalIndex].textValue.flatMap(Double.init) }
        #expect(totals == totals.sorted(by: >))
        #expect(page.columns.first { $0.name == "total" }?.isNumeric == true)
        let paidAtIndex = try #require(page.columns.firstIndex { $0.name == "paidAt" })
        #expect(page.rows.allSatisfy { $0[paidAtIndex] != .missing })
        #expect(try connection.countRows(query) == 50)

        query.page = 2
        #expect(try connection.fetchRows(query).rows.count == 10)

        query.filters = [FilterRule(column: "total", op: .greaterThan, value: "60")]
        query.rawWhere = #"{ status: { $in: ["paid", "shipped"] }, createdAt: { $gte: ISODate("2024-02-01") } }"#
        query.page = 0
        let filtered = try connection.fetchRows(query)
        let expected = try connection.execute(#"db.orders.countDocuments({ total: { $gt: 60 }, status: { $in: ["paid", "shipped"] }, createdAt: { $gte: ISODate("2024-02-01") } })"#, rowLimit: nil)
        #expect(String(filtered.rows.count) == expected.first?.rows.first?.first?.textValue)
        #expect(try connection.countRows(query) == filtered.rows.count)

        query.rawWhere = "{ createdAt: { $lt: new Date(Date.UTC(2024, 0, 2)) } }"
        query.filters = []
        #expect(try connection.countRows(query) == 4)

        query.rawWhere = "{ broken"
        #expect(throws: DatabaseError.self) { try connection.fetchRows(query) }

        let unfiltered = TableQuery(table: table)
        #expect(try connection.countRows(unfiltered) == 250)

        let id = TableQuery(table: table, filters: [FilterRule(column: "_id", op: .equals, value: "65a000070000000000000000")])
        #expect(try connection.fetchRows(id).rows.count == 1)

        let sparse = try connection.fetchRows(TableQuery(table: TableRef(name: "types_demo"), pageSize: 100))
        let sparseRow = try #require(sparse.rows.first { $0[0] == .text("100") })
        #expect(sparseRow.filter { $0 == .missing }.count == sparse.columns.count - 2)
    }

    /// Browse, edit every interesting type, save, and read the raw BSON back.
    @Test func editRoundTripKeepsBSONTypes() throws {
        let connection = try MongoTestServer.connect()
        defer { connection.close() }
        let oid = try #require(BSONObjectId(hex: "65a1b2c3d4e5f60718293a4b"))
        let newOid = try #require(BSONObjectId(hex: "65a1b2c3d4e5f60718293fff"))
        _ = try connection.execute("""
            db.fq_test_edit.drop()
            db.fq_test_edit.insertMany([
              { _id: 1, i32: NumberInt(1), i64: NumberLong("9007199254740993"), dec: NumberDecimal("10.50"), when: ISODate("2024-01-01T00:00:00Z"),
                ref: ObjectId("65a1b2c3d4e5f60718293a4b"), ratio: 0.5, label: "old", address: { city: "Genève", zip: NumberLong(530000), geo: { lat: 16.4, lng: 107.5 } },
                gone: "remove me", tags: ["a", "b"] },
              { _id: 2, label: "delete me" }
            ])
            """, rowLimit: nil)
        defer { _ = try? connection.execute("db.fq_test_edit.drop()", rowLimit: nil) }

        let table = TableRef(name: "fq_test_edit")
        let structure = try connection.structure(of: table)
        let page = try connection.fetchRows(TableQuery(table: table, sort: [SortKey(column: "_id", ascending: true)]))
        let names = page.columns.map(\.name)
        func column(_ name: String) throws -> Int { try #require(names.firstIndex(of: name)) }
        let row = try #require(page.rows.firstIndex { $0[0] == .text("1") })
        #expect(page.rows[row][try column("ref")] == .text(oid.hex))
        #expect(page.rows[row][try column("address")] == .text(#"{"city":"Genève","zip":530000,"geo":{"lat":16.4,"lng":107.5}}"#))

        var changes = PendingChanges()
        func edit(_ name: String, _ value: CellValue) throws {
            let index = try column(name)
            changes.setValue(value, row: row, column: index, original: page.rows[row][index])
        }
        try edit("i32", .text("2"))
        try edit("i64", .text("9007199254740995"))
        try edit("dec", .text("19.99"))
        try edit("when", .text("2024-06-30T12:34:56.789Z"))
        try edit("ref", .text(newOid.hex))
        try edit("ratio", .text("2"))
        try edit("address", .text(#"{ "city": "Zürich", "zip": 100000, "geo": { "lat": 21.03, "lng": 107.5 } }"#))
        try edit("gone", .missing)
        try edit("tags", .text(#"["a", "c"]"#))
        try edit("label", .text("new"))
        let deleteRow = try #require(page.rows.firstIndex { $0[0] == .text("2") })
        changes.markDeleted(rows: [deleteRow])
        var insertion = Array(repeating: InsertValue.useDefault, count: names.count)
        insertion[try column("_id")] = .value(.text("3"))
        insertion[try column("i32")] = .value(.text("7"))
        insertion[try column("when")] = .value(.text("2024-02-02"))
        insertion[try column("label")] = .value(.text(""))
        changes.addInsertion(insertion)

        try connection.applyChanges(ChangeBatch(table: table, columns: page.columns, primaryKey: structure.primaryKey, originalRows: page.rows, changes: changes))

        let reply = try connection.runCommand(["find": .string("fq_test_edit"), "filter": .document([:]), "sort": .document(["_id": .int32(1)])], database: "foxlume")
        let documents = (reply["cursor"]?.documentValue?["firstBatch"]?.arrayValue ?? []).compactMap(\.documentValue)
        #expect(documents.map { $0["_id"] } == [.int32(1), .int32(3)])
        let saved = try #require(documents.first)
        #expect(saved["i32"] == .int32(2))
        #expect(saved["i64"] == .int64(9_007_199_254_740_995))
        #expect(saved["dec"] == .decimal128(try #require(BSONDecimal128("19.99"))))
        #expect(saved["when"] == .date(1_719_750_896_789))
        #expect(saved["ref"] == .objectId(newOid))
        #expect(saved["ratio"] == .double(2))
        #expect(saved["label"] == .string("new"))
        #expect(saved["gone"] == nil)
        #expect(saved["tags"] == .array([.string("a"), .string("c")]))
        // The nested int64 keeps its type and the untouched nested double stays a double.
        #expect(saved["address"] == .document(["city": .string("Zürich"), "zip": .int64(100_000), "geo": .document(["lat": .double(21.03), "lng": .double(107.5)])]))
        let inserted = try #require(documents.last)
        #expect(inserted["i32"] == .int32(7))
        #expect(inserted["when"] == .date(1_706_832_000_000))
        #expect(inserted["label"] == nil)
        #expect(inserted.keys.first == "_id")

        // _id is immutable, and a failing part reports what was already saved.
        var idEdit = PendingChanges()
        let reread = try connection.fetchRows(TableQuery(table: table, sort: [SortKey(column: "_id", ascending: true)]))
        idEdit.setValue(.text("99"), row: 0, column: 0, original: reread.rows[0][0])
        #expect(throws: DatabaseError.self) {
            try connection.applyChanges(ChangeBatch(table: table, columns: reread.columns, primaryKey: ["_id"], originalRows: reread.rows, changes: idEdit))
        }
        var badType = PendingChanges()
        let i32 = try #require(reread.columns.firstIndex { $0.name == "i32" })
        badType.setValue(.text("not a number"), row: 0, column: i32, original: reread.rows[0][i32])
        do {
            try connection.applyChanges(ChangeBatch(table: table, columns: reread.columns, primaryKey: ["_id"], originalRows: reread.rows, changes: badType))
            Issue.record("a non-numeric INTEGER edit should fail")
        } catch DatabaseError.server(let message, _, _) {
            #expect(message.contains("row 1"))
            #expect(message.contains("INTEGER"))
        }
    }

    @Test func cancelInterruptsARunningCommand() async throws {
        let connection = try MongoTestServer.connect()
        defer { connection.close() }
        let started = Date()
        TestThreads.after(1) { connection.cancel() }
        do {
            _ = try connection.execute(#"db.orders.find({ $where: "sleep(100) || true" }).toArray()"#, rowLimit: nil)
            Issue.record("the command should have been cancelled")
        } catch DatabaseError.cancelled {
            let elapsed = Date().timeIntervalSince(started)
            #expect(elapsed < 5)
            // killOp, not the socket fallback, stopped it: the connection is still open.
            #expect(connection.link != nil)
        }
        let ping = try connection.execute("db.runCommand({ ping: 1 })", rowLimit: nil)
        #expect(ping.first?.rows.first?.first == .text("1"))

        // A JavaScript sleep between commands is interrupted too.
        TestThreads.after(0.5) { connection.cancel() }
        #expect(throws: DatabaseError.self) { try connection.execute("sleep(20000); db.orders.findOne()", rowLimit: nil) }
        #expect(try connection.execute("db.orders.countDocuments()", rowLimit: nil).first?.rows.first?.first == .text("250"))
    }
}

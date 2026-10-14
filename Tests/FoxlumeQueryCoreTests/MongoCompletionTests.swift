import Foundation
import Testing
@testable import FoxlumeQueryCore

/// Schema stand-in for the MongoDB completer: collections, sampled fields and favorites.
@MainActor
private final class MongoFakeSchema: CompletionSchemaProvider {
    var collections: [TableInfo] = [TableInfo(ref: TableRef(name: "orders")), TableInfo(ref: TableRef(name: "users"))]
    var fields: [String: [CompletionField]] = [
        "users": [
            CompletionField(path: "_id", typeName: "int"),
            CompletionField(path: "name", typeName: "string"),
            CompletionField(path: "address", typeName: "object"),
            CompletionField(path: "address.city", typeName: "string"),
        ],
        "orders": [
            CompletionField(path: "_id", typeName: "objectId"),
            CompletionField(path: "status", typeName: "string"),
            CompletionField(path: "total", typeName: "decimal"),
            CompletionField(path: "items", typeName: "array"),
            CompletionField(path: "items.sku", typeName: "string"),
        ],
    ]
    var columnsByCollection: [String: [ColumnInfo]] = [:]
    var favoriteList: [CompletionFavorite] = []
    var databases: [String] = []
    private(set) var fieldRequests: [String] = []

    func unqualifiedTables() async -> [TableInfo] { collections }
    func tables(inSchema schema: String) async -> [TableInfo]? { nil }
    func schemaNames() async -> [String] { [] }
    func databaseNames() async -> [String] { databases }
    func implicitSchema() async -> String? { nil }
    func columns(of table: TableRef) async -> [ColumnInfo]? { columnsByCollection[table.name] }
    func cachedColumns() -> [(table: TableRef, columns: [ColumnInfo])] { [] }
    func documentFields(of collection: String) async -> [CompletionField] {
        fieldRequests.append(collection)
        return fields[collection] ?? []
    }
    func keyNames(prefix: String, limit: Int) async -> [String] { [] }
    func favorites() -> [CompletionFavorite] { favoriteList }
}

/// `|` marks the caret.
private func split(_ marked: String) -> (text: String, caret: Int) {
    let caret = (marked as NSString).range(of: "|").location
    return (marked.replacingOccurrences(of: "|", with: ""), caret)
}

private func position(_ marked: String) -> MongoCompletionPosition? {
    let (text, caret) = split(marked)
    return MongoCompletionScanner.analyze(text, caret: caret).position
}

@MainActor
private func complete(_ marked: String, manual: Bool = false, schema: MongoFakeSchema? = nil) async -> CompletionResult? {
    let (text, caret) = split(marked)
    let schema = schema ?? MongoFakeSchema()
    let engine = MongoCompletionEngine(schema: schema)
    return await engine.complete(text: text, caret: caret, manual: manual, keywordCase: .matchTypedElseUpper)
}

@MainActor
private func labels(_ marked: String, manual: Bool = false, schema: MongoFakeSchema? = nil) async -> [String] {
    await complete(marked, manual: manual, schema: schema)?.items.map(\.label) ?? []
}

@Suite("Mongo completion scanner")
struct MongoCompletionScannerTests {
    @Test func tokenKeepsUpToTwoDollarSigns() {
        func token(_ marked: String) -> String {
            let (text, caret) = split(marked)
            return MongoCompletionScanner.analyze(text, caret: caret).token
        }
        #expect(token("db.users.find({$g|") == "$g")
        #expect(token("{a: \"$$N|") == "$$N")
        #expect(token("{a: \"$$$N|") == "$$N")
        #expect(token("db.users.fin|") == "fin")
        #expect(token("db.|") == "")
        #expect(token("x = name_1|") == "name_1")
        let (text, caret) = split("db.users.find({$g|")
        #expect(MongoCompletionScanner.analyze(text, caret: caret).tokenRange == NSRange(location: 15, length: 2))
        #expect(MongoCompletionEngine.tokenRange(in: text, caret: caret) == NSRange(location: 15, length: 2))
    }

    @Test(arguments: [
        ("|", MongoCompletionPosition.statementStart),
        ("{|", .statementStart),
        ("db.|", .databaseMember),
        ("x = db.|", .databaseMember),
        ("db.users.fin|", .collectionMethod(collection: "users")),
        ("db.my.coll.|", .collectionMethod(collection: "my.coll")),
        ("db.orders.find({}).|", .cursorMethod),
        ("db.orders.find({}).sort({_id: -1}).li|", .cursorMethod),
        ("db.users.find({$g|", .filterDocument(collection: "users")),
        ("db.users.find ({na|", .filterDocument(collection: "users")),
        ("db.users.find({age: {$|", .filterDocument(collection: "users")),
        ("db.users.find({}, {|", .projectionDocument(collection: "users")),
        ("db.users.find({name: \"{\"}, {|", .projectionDocument(collection: "users")),
        ("db.users.find({name: '\\'{'}, {|", .projectionDocument(collection: "users")),
        ("db.users.distinct(\"name\", {|", .filterDocument(collection: "users")),
        ("db.users.deleteMany({|", .filterDocument(collection: "users")),
        ("db.users.updateOne({}, {|", .updateDocument(collection: "users", insideOperator: false)),
        ("db.users.updateOne({}, {$set: {|", .updateDocument(collection: "users", insideOperator: true)),
        ("db.users.updateOne({}, [{|", .updatePipelineStage(collection: "users")),
        ("db.users.updateOne({}, [{$set: {a: \"$|", .stageExpression(collection: "users")),
        ("db.users.insertOne({|", .plainDocument(collection: "users")),
        ("db.users.replaceOne({}, {|", .plainDocument(collection: "users")),
        ("db.users.createIndex({|", .plainDocument(collection: "users")),
        ("db.orders.aggregate([|", .pipelineStage(collection: "orders")),
        ("db.orders.aggregate([{ $ma|", .pipelineStage(collection: "orders")),
        ("db.orders.aggregate([{$group: {|", .stageExpression(collection: "orders")),
        ("db.o.aggregate([{$project: {a: \"$$N|", .stageExpression(collection: "o")),
        ("db.aggregate([{|", .pipelineStage(collection: nil)),
        ("/* db.users.find({ */ db.|", .databaseMember),
        ("db.users.find({}) // done\ndb.|", .databaseMember),
        ("db.users.find({a: 'open\n|", .filterDocument(collection: "users")),
        // getCollection / getSiblingDB chains resolve like `db.<name>`.
        ("db.getCollection(\"my-coll\").|", .collectionMethod(collection: "my-coll")),
        ("db.getCollection( 'a b' ).fi|", .collectionMethod(collection: "a b")),
        ("db.getCollection(\"my-coll\").find({st|", .filterDocument(collection: "my-coll")),
        ("db.getCollection(name).|", .collectionMethod(collection: "")),
        ("db.getCollection(name).find({|", .filterDocument(collection: nil)),
        ("db.getSiblingDB(\"x\").|", .databaseMember),
        ("db.getSiblingDB(\"x\").orders.find({|", .filterDocument(collection: "orders")),
        ("db.getSiblingDB(\"x\").getCollection(\"y\").aggregate([{|", .pipelineStage(collection: "y")),
        ("db.getCollection(\"orders\").find({}).|", .cursorMethod),
        // Chains continued on the next line, also across comments.
        ("db.orders.find({})\n  .|", .cursorMethod),
        ("db.orders.find({}) // newest first\n  .sort({_id: -1})\n  .li|", .cursorMethod),
        ("db.orders\n  .fin|", .collectionMethod(collection: "orders")),
        ("db.orders /* c */ .find({st|", .filterDocument(collection: "orders")),
        // Stage contents follow the stage.
        ("db.orders.aggregate([{$match: {st|", .filterDocument(collection: "orders")),
        ("db.orders.aggregate([{$match: {total: {$|", .filterDocument(collection: "orders")),
        ("db.orders.aggregate([{$match: {$expr: {$gt: [\"$|", .stageExpression(collection: "orders")),
        ("db.orders.find({$expr: {$eq: [\"$st|", .stageExpression(collection: "orders")),
        ("db.orders.aggregate([{$sort: {to|", .fieldNames(collection: "orders")),
        ("db.orders.aggregate([{$sort: {total: -1, st|", .fieldNames(collection: "orders")),
        ("db.orders.aggregate([{$project: {st|", .fieldNames(collection: "orders")),
        ("db.orders.aggregate([{$project: {x: \"$st|", .stageExpression(collection: "orders")),
        ("db.orders.aggregate([{$project: {x: {$concat: [\"$st|", .stageExpression(collection: "orders")),
        ("db.orders.aggregate([{\"$unset\": [\"st|", .fieldNames(collection: "orders")),
        ("db.orders.aggregate([{$unset: \"st|", .fieldNames(collection: "orders")),
        ("db.orders.aggregate([{$unwind: \"$it|", .stageExpression(collection: "orders")),
        ("db.orders.aggregate([{$match: {}}, {$unwind: {path: \"$it|", .stageExpression(collection: "orders")),
        ("db.orders.aggregate([{$match: {}}, {|", .pipelineStage(collection: "orders")),
        ("db.users.updateOne({}, [{$set: {na|", .fieldNames(collection: "users")),
    ])
    func positions(_ marked: String, expected: MongoCompletionPosition) {
        #expect(position(marked) == expected, "\(marked)")
    }

    @Test(arguments: [
        "db.users.find({}) // db.|",
        "/* db.|",
        "db.orders.aggregate({|",
        "db.orders.aggregate(|",
        "db.users.find({}, {}, {|",
        "db.users.countDocuments({}, {|",
        "db.users.updateOne({}, {}, {|",
        "db.users.find(\"ab|",
        "db.users.find({_id: ObjectId(|",
        "db.users.find({}).sort({|",
        "\"abc|",
        "print(|",
        // Member access on anything but `db` or a call result.
        "x.|",
        "Math.d|",
        "x = 1.|",
        "db.orders.aggregate([{$sort: {total: |",
    ])
    func suppressed(_ marked: String) {
        #expect(position(marked) == nil, "\(marked)")
    }

    @Test func stringsInsideDocumentsAreNotSuppressed() {
        let (text, caret) = split("db.o.aggregate([{$project: {a: \"$$N|")
        let analysis = MongoCompletionScanner.analyze(text, caret: caret)
        #expect(analysis.inString)
        #expect(analysis.position == .stageExpression(collection: "o"))
    }
}

@MainActor
@Suite("Mongo completion engine")
struct MongoCompletionEngineTests {
    // Spec 12 row 100.
    @Test func databaseMemberOpensWithCollectionsThenMethods() async throws {
        let result = try #require(await complete("db.|"))
        #expect(result.items.prefix(3).map(\.label) == ["orders", "users", "getCollectionNames"])
        #expect(result.items[0].kind == .table)
        #expect(result.items[0].detail == "Collection")
        #expect(result.items.count == 2 + 27)
        #expect(result.limit == .max)
        #expect(result.replacementRange == NSRange(location: 3, length: 0))
        let method = try #require(result.items.first { $0.label == "getSiblingDB" })
        #expect(method.kind == .function && method.insertText == "getSiblingDB()" && method.caretOffsetFromEnd == 1)
    }

    @Test func collectionsWithOddNamesGoThroughGetCollection() async throws {
        let schema = MongoFakeSchema()
        schema.collections = [
            TableInfo(ref: TableRef(name: "my-coll")),
            TableInfo(ref: TableRef(name: "logs.daily")),
            TableInfo(ref: TableRef(name: "paid_orders"), kind: .view),
        ]
        let items = try #require(await complete("db.|", schema: schema)).items
        #expect(items[0].insertText == "getCollection(\"my-coll\")")
        #expect(items[1].insertText == "logs.daily")
        #expect(items[2].kind == .view && items[2].detail == "View" && items[2].insertText == "paid_orders")
    }

    // Spec 12 row 101.
    @Test func collectionMethodsMatchByPrefixThenCodePoint() async throws {
        let result = try #require(await complete("db.users.fin|"))
        #expect(result.items.prefix(5).map(\.label) == ["find", "findOne", "findOneAndDelete", "findOneAndReplace", "findOneAndUpdate"])
        #expect(result.items[0].insertText == "find()")
        #expect(result.items[0].caretOffsetFromEnd == 1)
        #expect(result.items[0].detail == "(filter, projection)")
        #expect(result.items[0].highlights == [NSRange(location: 0, length: 3)])
        let legacy = try #require(result.items.first { $0.label == "findAndModify" })
        #expect(legacy.isDeprecated)
        #expect(result.items.firstIndex(of: legacy) == 5)
        #expect(result.prefix == "fin" && result.token == "fin")
    }

    @Test func deprecatedMethodsFollowTheirReplacementsAndSubstringsCome2nd() async throws {
        let items = try #require(await complete("db.users.in|")).items
        #expect(items.prefix(3).map(\.label) == ["insertMany", "insertOne", "insert"])
        #expect(items[2].isDeprecated && !items[0].isDeprecated)
        // Substring matches (`find` contains "in") follow every prefix match.
        #expect(items.dropFirst(3).allSatisfy { !$0.label.lowercased().hasPrefix("in") })
        #expect(items.contains { $0.label == "find" })
    }

    // Spec 12 row 102.
    @Test func dottedCollectionNames() async throws {
        let schema = MongoFakeSchema()
        let result = try #require(await complete("db.my.coll.|", schema: schema))
        #expect(result.items.first?.label == "find")
        #expect(result.items.count == 34 + 8)
    }

    // Spec 12 row 103.
    @Test func cursorMethodsAfterACall() async throws {
        let items = try #require(await complete("db.orders.find({}).|")).items
        #expect(items.prefix(3).map(\.label) == ["sort", "limit", "skip"])
        #expect(items.count == 23)
        // `count` is a regular cursor method; only collection-method positions flag deprecated names.
        #expect(items.first { $0.label == "count" }?.isDeprecated == false)
        #expect(items.allSatisfy { $0.kind == .function && $0.insertText.hasSuffix("()") })
    }

    // Spec 12 row 104.
    @Test func filterOperatorsSortByCodePoint() async throws {
        let schema = MongoFakeSchema()
        schema.fields = [:]
        let result = try #require(await complete("db.users.find({$g|", schema: schema))
        #expect(result.items.map(\.label) == ["$geoIntersects", "$geoWithin", "$geometry", "$gt", "$gte"])
        #expect(result.items.allSatisfy { $0.kind == .operator && $0.insertText == $0.label })
        #expect(result.prefix == "$g")
        #expect(result.refilterState.context == "filterDocument")
    }

    @Test func filterDocumentOffersFieldsWithDepthPriority() async throws {
        let schema = MongoFakeSchema()
        let result = try #require(await complete("db.users.find({|", manual: true, schema: schema))
        #expect(schema.fieldRequests == ["users"])
        #expect(result.items.prefix(4).map(\.label) == ["_id", "name", "address", "address.city"])
        let city = try #require(result.items.first { $0.label == "address.city" })
        #expect(city.kind == .column && city.detail == "string" && city.priority == 101)
        // A dotted path is not a valid object key unless quoted.
        #expect(city.insertText == "\"address.city\"")
        #expect(result.items.first { $0.label == "name" }?.insertText == "name")
        #expect(result.items.count == 4 + 39)

        let typed = try #require(await complete("db.users.find({ci|", schema: schema))
        #expect(typed.items.first?.label == "address.city")
        let quoted = try #require(await complete("db.users.find({\"address.ci|", schema: schema))
        #expect(quoted.items.map(\.label) == ["city"])
    }

    @Test func subFieldsAfterADottedPath() async throws {
        let schema = MongoFakeSchema()
        schema.fields["users"]?.append(CompletionField(path: "address.geo.lat", typeName: "double"))
        // `.` opens the list with nothing typed, named relative to the path so accepting does not repeat it.
        let opened = try #require(await complete("db.users.find({\"address.|", schema: schema))
        #expect(opened.items.map(\.label) == ["city", "geo.lat"])
        #expect(opened.items[1].priority == 101 && opened.items[1].detail == "double")
        #expect(opened.replacementRange == NSRange(location: 24, length: 0))

        let reference = try #require(await complete("db.orders.aggregate([{$project: {s: \"$items.s|", schema: schema))
        #expect(reference.items.map(\.label) == ["sku"])
        #expect(await labels("db.orders.aggregate([{$project: {s: \"$$ROOT.items.|", schema: schema) == ["sku"])
        #expect(await labels("db.orders.aggregate([{$project: {s: \"$$ROOT.st|", schema: schema) == ["status"])

        // Member access on something that is not a field offers nothing.
        #expect(await complete("db.users.find({a: Math.ro|", manual: true, schema: schema) == nil)
        #expect(await complete("db.users.find({d: ISODate().get|", manual: true, schema: schema) == nil)
        #expect(await complete("db.users.find({\"nope.|", manual: true, schema: schema) == nil)
        #expect(await complete("db.users.find({a: \"$$NOW.|", manual: true, schema: schema) == nil)
    }

    @Test func documentsNeedATypedCharacterUnlessManual() async {
        #expect(await complete("db.users.find({|") == nil)
        #expect(await complete("db.users.find({}, {|") == nil)
        #expect(await complete("db.users.updateOne({}, {|") == nil)
        #expect(await complete("db.orders.aggregate([{$group: {|") == nil)
        #expect(await complete("|") == nil)
        #expect(await complete("db.users.find({|", manual: true) != nil)
    }

    @Test func fieldsFallBackToProviderColumns() async throws {
        let schema = MongoFakeSchema()
        schema.fields = [:]
        schema.columnsByCollection = ["users": [ColumnInfo(name: "_id", dataType: "INTEGER"), ColumnInfo(name: "email", dataType: "VARCHAR")]]
        let items = try #require(await complete("db.users.find({em|", schema: schema)).items
        #expect(items.first?.label == "email")
        #expect(items.first?.detail == "VARCHAR")
    }

    // Spec 12 row 105.
    @Test func projectionDocument() async throws {
        let labels = await labels("db.users.find({}, {|", manual: true)
        #expect(labels == ["_id", "name", "address", "address.city", "$elemMatch", "$slice", "$meta"])
    }

    // Spec 12 row 106.
    @Test func updateDocumentAndUpdatePipeline() async throws {
        let update = await labels("db.users.updateOne({}, {|", manual: true)
        #expect(update.count == 19)
        #expect(update.prefix(3) == ["$set", "$unset", "$setOnInsert"])
        let inside = await labels("db.users.updateOne({}, {$set: {na|")
        #expect(inside.first == "name")
        // Spec 8.4 generation order, kept with nothing typed.
        let pipeline = try #require(await complete("db.users.updateOne({}, [{|"))
        #expect(pipeline.items.map(\.label) == ["$set", "$addFields", "$unset", "$project", "$replaceRoot", "$replaceWith"])
        #expect(pipeline.items.allSatisfy { $0.kind == .keyword })
    }

    // Spec 12 row 107.
    @Test func plainDocumentOffersConstructors() async throws {
        let items = try #require(await complete("db.users.insertOne({|", manual: true)).items
        #expect(items.prefix(4).map(\.label) == ["_id", "name", "address", "address.city"])
        #expect(items.count == 4 + 27)
        let objectId = try #require(items.first { $0.label == "ObjectId" })
        #expect(objectId.kind == .function && objectId.insertText == "ObjectId()" && objectId.caretOffsetFromEnd == 1)
        #expect(await labels("db.users.insertOne({createdAt: ISO|").first == "ISODate")
    }

    // Spec 12 row 108.
    @Test func stagesKeepTheirCase() async throws {
        #expect(await labels("db.orders.aggregate([{ $ma|").first == "$match")
        #expect(await labels("db.orders.aggregate([{ $MA|").first == "$match")
        let stages = try #require(await complete("db.orders.aggregate([{|"))
        #expect(stages.items.count == 36)
        #expect(stages.items.first?.label == "$match")
    }

    // Spec 12 row 109.
    @Test func stageExpressions() async throws {
        let schema = MongoFakeSchema()
        let result = try #require(await complete("db.orders.aggregate([{$group: {_id: \"$status\", n: {$su|", schema: schema))
        // Same kind and priority: code-point order puts `$substr…` and `$subtract` before `$sum`.
        #expect(result.items.prefix(5).map(\.label) == ["$substr", "$substrBytes", "$substrCP", "$subtract", "$sum"])
        #expect(schema.fieldRequests == ["orders"])

        let all = try #require(await complete("db.orders.aggregate([{$group: {|", manual: true))
        #expect(all.items.count > 150)
        #expect(all.items.contains { $0.label == "$dateToString" })
        #expect(all.items.contains { $0.label == "$$ROOT" })
        // Operators listed both as expressions and accumulators appear once.
        #expect(all.items.filter { $0.label == "$mergeObjects" }.count == 1)
        #expect(all.items.filter { $0.label == "$firstN" }.count == 1)
        let reference = try #require(all.items.first { $0.label == "$items.sku" })
        #expect(reference.kind == .column && reference.priority == 100 && reference.detail == "string")
    }

    @Test func fieldReferencesAreQuotedOutsideStrings() async throws {
        let inString = try #require(await complete("db.orders.aggregate([{$group: {_id: \"$sta|"))
        #expect(inString.items.first?.label == "$status")
        #expect(inString.items.first?.insertText == "$status")
        let bare = try #require(await complete("db.orders.aggregate([{$group: {_id: $sta|"))
        #expect(bare.items.first?.insertText == "\"$status\"")
    }

    // Spec 12 rows 110, 113.
    @Test func suppressedEvenWhenManual() async {
        #expect(await complete("db.orders.aggregate({|", manual: true) == nil)
        #expect(await complete("db.users.find({}) // db.|", manual: true) == nil)
        #expect(await complete("db.users.find({name: \"An|", manual: true) != nil)
        #expect(await complete("db.users.find(\"An|", manual: true) == nil)
    }

    // Spec 12 row 111.
    @Test func systemVariables() async throws {
        let result = try #require(await complete("db.o.aggregate([{$project: {a: \"$$N|"))
        #expect(result.items.first?.label == "$$NOW")
        #expect(result.items.first?.insertText == "$$NOW")
        #expect(result.prefix == "$$N")
        let bare = try #require(await complete("db.o.aggregate([{$project: {a: $$RO|"))
        #expect(bare.items.first?.insertText == "\"$$ROOT\"")
    }

    // Spec 12 row 112.
    @Test func braceInsideStringIsIgnored() async {
        #expect(await labels("db.users.find({name: \"{\"}, {|", manual: true).last == "$meta")
    }

    @Test func statementStart() async throws {
        let schema = MongoFakeSchema()
        schema.favoriteList = [CompletionFavorite(keyword: "recent", name: "Recent orders", query: "db.orders.find({;;}).sort({_id: -1})")]
        let all = try #require(await complete("|", manual: true, schema: schema))
        #expect(all.items.map(\.label) == ["use", "show dbs", "show collections", "show users", "show roles", "show profile", "recent", "db"])
        #expect(all.items[0].kind == .keyword)

        #expect(await labels("d|").contains("db"))
        #expect(await labels("D|").contains("db"))
        #expect(await labels("sh|", schema: schema).prefix(5) == ["show collections", "show dbs", "show profile", "show roles", "show users"])

        // Favorites filter like everything else, by substring too.
        let favorite = try #require(await complete("cen|", schema: schema)).items.first
        #expect(favorite?.kind == .favorite)
        #expect(favorite?.label == "recent")
        #expect(favorite?.detail == "Recent orders")
        #expect(favorite?.insertText == "db.orders.find({}).sort({_id: -1})")
        #expect(favorite?.caretOffsetFromEnd == "}).sort({_id: -1})".utf16.count)
    }

    @Test func shellCommandArguments() async throws {
        let schema = MongoFakeSchema()
        let show = try #require(await complete("show |", schema: schema))
        #expect(show.items.first?.label == "dbs")
        #expect(show.items.contains { $0.label == "collections" })
        #expect(show.replacementRange == NSRange(location: 5, length: 0))
        // `show d` completes the second word only (no `show show dbs`).
        #expect(await labels("show d|", schema: schema).prefix(2) == ["databases", "dbs"])
        #expect(position("x; show |") == .shellArgument(command: "show"))
        #expect(position("show dbs |") == .statementStart)
        #expect(position("use |") == .shellArgument(command: "use"))
        #expect(await complete("use |", schema: schema) == nil)
        schema.databases = ["admin", "foxlume"]
        let use = try #require(await complete("use fo|", schema: schema))
        #expect(use.items.map(\.label) == ["foxlume"])
        #expect(use.items[0].kind == .database)
    }

    @Test func noFuzzyMatching() async {
        #expect(await complete("db.users.fnd|") == nil)
        #expect(await complete("db.users.zzz|") == nil)
    }

    @Test func refilterUsesThePool() async throws {
        let engine = MongoCompletionEngine(schema: MongoFakeSchema())
        let result = try #require(await engine.complete(text: "db.users.f", caret: 10, manual: false, keywordCase: .upper))
        #expect(result.pool.count == 34 + 8)
        #expect(engine.refilter(result, token: "findOneAndR", keywordCase: .upper).map(\.label) == ["findOneAndReplace"])
        // Backspacing past the opening prefix widens again because the pool is the whole list.
        #expect(engine.refilter(result, token: "d", keywordCase: .upper).first?.label == "dataSize")
        #expect(engine.refilter(result, token: "", keywordCase: .upper).isEmpty)
        #expect(engine.refilter(result, token: "find(", keywordCase: .upper).isEmpty)
        #expect(engine.refilter(result, token: "zzz", keywordCase: .upper).isEmpty)
    }

    @Test func refilterKeepsDollarTokens() async throws {
        let engine = MongoCompletionEngine(schema: MongoFakeSchema())
        let result = try #require(await engine.complete(text: "db.users.find({$", caret: 16, manual: false, keywordCase: .upper))
        // Every operator prefix-matches `$`, so code-point order decides.
        #expect(result.items.first?.label == "$all")
        #expect(engine.refilter(result, token: "$exi", keywordCase: .lower).map(\.label) == ["$exists"])
    }

    @Test func getCollectionChainsKeepCollectionCompletion() async throws {
        let schema = MongoFakeSchema()
        let methods = try #require(await complete("db.getCollection(\"my-coll\").|", schema: schema))
        #expect(methods.items.first?.label == "find")
        #expect(methods.items.count == 34 + 8)
        #expect(await labels("db.getCollection(\"my-coll\").fi|", schema: schema).first == "find")
        #expect(await labels("db.getCollection(\"orders\").find({st|", schema: schema).first == "status")
        #expect(schema.fieldRequests.last == "orders")
        // What `db.` inserts for an odd name leads back into collection methods.
        schema.collections = [TableInfo(ref: TableRef(name: "my-coll"))]
        let insert = try #require(await complete("db.|", schema: schema)).items[0].insertText
        #expect(await labels("db.\(insert).|", schema: schema).first == "find")
    }

    @Test func chainsContinuedOnNewLines() async throws {
        let cursor = try #require(await complete("db.orders.find({})\n  .s|"))
        #expect(cursor.items.prefix(3).map(\.label) == ["size", "skip", "sort"])
        #expect(!cursor.items.contains { $0.label.hasPrefix("show") || $0.label == "use" })
        #expect(await labels("db.orders\n  .fin|").first == "find")
        #expect(await complete("Math.d|", manual: true) == nil)
        #expect(await complete("x.|", manual: true) == nil)
    }

    @Test func longStatementsKeepTheirCallContext() async throws {
        let schema = MongoFakeSchema()
        let documents = String(repeating: "{\"a\": 1, \"b\": \"x\"}, ", count: 400)
        let oneLine = try #require(await complete("db.users.insertMany([" + documents + "{na|", schema: schema))
        #expect(oneLine.items.first?.label == "name")
        #expect(oneLine.refilterState.context == "plainDocument")
        #expect(await labels("db.users.insertMany([" + documents + "{us|", schema: schema).contains("use") == false)
        let lines = String(repeating: "  {\"a\": 1, \"b\": \"x\"},\n", count: 400)
        #expect(await labels("db.users.insertMany([\n" + lines + "  {na|", schema: schema).first == "name")
    }

    @Test func scanStartsAtACommandLineInsideTheWindow() {
        let window = MongoCompletionScanner.window
        let filler = String(repeating: "  {a: 1},\ndb.a.find({})\n", count: window / 24 + 10)
        let units = Array((filler + "db.users.find({na").utf16)
        let token = units.count - 2
        let start = MongoCompletionScanner.scanStart(units, tokenStart: token)
        #expect(start > 0 && token - start <= window)
        #expect(String(decoding: units[start..<(start + 5)], as: UTF16.self) == "db.a.")
        // A line longer than the window is scanned from the window edge, not skipped.
        let line = Array((String(repeating: "x", count: window + 10) + "y").utf16)
        #expect(MongoCompletionScanner.scanStart(line, tokenStart: line.count) == line.count - window)
        // Short documents are scanned whole.
        #expect(MongoCompletionScanner.scanStart(Array("db.a.find({\n".utf16), tokenStart: 12) == 0)
    }

    @Test func stageContentsFollowTheStage() async throws {
        let schema = MongoFakeSchema()
        let match = await labels("db.orders.aggregate([{$match: {$|", schema: schema)
        #expect(match.contains("$gt") && match.contains("$in") && match.contains("$regex"))
        #expect(!match.contains("$abs") && !match.contains("$status") && !match.contains("$accumulator"))
        #expect(await labels("db.orders.aggregate([{$match: {st|", schema: schema).first == "status")
        #expect(await labels("db.orders.aggregate([{$sort: {to|", schema: schema) == ["total"])
        let project = try #require(await complete("db.orders.aggregate([{$project: {it|", schema: schema))
        #expect(project.items.map(\.label) == ["items", "items.sku"])
        #expect(project.items[1].insertText == "\"items.sku\"")
        let unwind = try #require(await complete("db.orders.aggregate([{$unwind: \"$it|", schema: schema))
        #expect(unwind.items.map(\.label) == ["$items", "$items.sku"])
        #expect(unwind.items[0].insertText == "$items")
        #expect(await labels("db.orders.aggregate([{$unset: [\"st|", schema: schema) == ["status"])
        #expect(await labels("db.users.updateOne({}, [{$set: {na|", schema: schema) == ["name"])
        #expect(await complete("db.orders.aggregate([{$sort: {total: |", manual: true, schema: schema) == nil)
    }

    @Test func dottedPathsCompleteOnlyInsideStrings() async throws {
        // `$items.sku` outside a string is JavaScript member access, not a field reference.
        #expect(await complete("db.orders.aggregate([{$project: {x: $items.|", manual: true) == nil)
        #expect(await complete("db.orders.aggregate([{$project: {x: $items.s|") == nil)
        #expect(await complete("db.users.find({address.ci|", manual: true) == nil)
        #expect(await labels("db.users.find({\"address.ci|") == ["city"])
    }

    @Test func nonASCIIFieldNames() async throws {
        let schema = MongoFakeSchema()
        schema.fields["users"] = [
            CompletionField(path: "név", typeName: "string"),
            CompletionField(path: "dirección", typeName: "object"),
            CompletionField(path: "dirección.población", typeName: "string"),
            CompletionField(path: "código postal", typeName: "string"),
        ]
        let typed = try #require(await complete("db.users.find({né|", schema: schema))
        #expect(typed.items.map(\.label) == ["név"])
        #expect(typed.token == "né" && typed.replacementRange == NSRange(location: 15, length: 2))
        #expect(typed.items[0].insertText == "név")
        #expect(try #require(await complete("db.users.find({có|", schema: schema)).items.first?.insertText == "\"código postal\"")
        #expect(await labels("db.users.find({\"dirección.po|", schema: schema) == ["población"])
        let engine = MongoCompletionEngine(schema: schema)
        #expect(engine.refilter(typed, token: "név", keywordCase: .upper).map(\.label) == ["név"])
        // Decomposed accents stay in the token; emoji and a caret inside a surrogate pair do not start one.
        #expect(MongoCompletionEngine.tokenRange(in: "{te\u{0302}", caret: 4) == NSRange(location: 1, length: 3))
        #expect(MongoCompletionEngine.tokenRange(in: "{😀", caret: 3) == NSRange(location: 3, length: 0))
        #expect(MongoCompletionEngine.tokenRange(in: "{😀", caret: 2) == NSRange(location: 2, length: 0))
        #expect(MongoCompletionEngine.tokenRange(in: "{\u{0301}a", caret: 3) == NSRange(location: 2, length: 1))
        #expect(MongoCompletionEngine.isIdentifier("név"))
        #expect(!MongoCompletionEngine.isIdentifier("1a") && !MongoCompletionEngine.isIdentifier("código postal") && !MongoCompletionEngine.isIdentifier("\u{0301}a"))
    }

    @Test func deduplicationKeepsTheBetterPriority() {
        let items = ShellCompletionMatcher.deduplicated([
            CompletionItem(label: "a", kind: .column, priority: 105),
            CompletionItem(label: "b", kind: .column),
            CompletionItem(label: "a", kind: .column, priority: 100),
            CompletionItem(label: "a", kind: .keyword),
        ])
        #expect(items.map(\.label) == ["a", "b", "a"])
        #expect(items[0].priority == 100)
    }
}

@Suite("Mongo completion field sampling")
struct MongoCompletionFieldSamplingTests {
    @Test func walksEmbeddedDocumentsAndArrays() {
        let documents: [BSONDocument] = [
            [
                "name": .string("An"),
                "_id": .int32(1),
                "address": .document(["city": .string("Zürich"), "geo": .document(["lat": .double(21.0)])]),
                "items": .array([.document(["sku": .string("CF-001"), "qty": .int32(2)]), .document(["sku": .string("TR-002"), "note": .null])]),
                "tags": .array([.string("vip")]),
            ],
            ["_id": .int32(2), "name": .null, "age": .int64(30)],
            ["_id": .string("x"), "age": .int32(4), "nothing": .null],
            ["_id": .string("y"), "age": .int32(5)],
        ]
        let fields = MongoConnection.completionFields(in: documents)
        #expect(fields.map(\.path) == [
            "_id", "name", "address", "address.city", "address.geo", "address.geo.lat",
            "items", "items.sku", "items.qty", "items.note", "tags", "age", "nothing",
        ])
        let types = Dictionary(uniqueKeysWithValues: fields.map { ($0.path, $0.typeName) })
        // Two ints and two strings: a tie keeps the type seen first.
        #expect(types["_id"] == "int")
        #expect(types["name"] == "string")
        #expect(types["address"] == "object")
        #expect(types["address.geo.lat"] == "double")
        #expect(types["items"] == "array")
        #expect(types["items.qty"] == "int")
        #expect(types["items.note"] == "null")
        #expect(types["age"] == "int")
    }

    @Test func limitsDepthAndCount() {
        var deep: BSONValue = .int32(1)
        for level in (1...8).reversed() { deep = .document(["l\(level)": deep]) }
        let nested = MongoConnection.completionFields(in: [["root": deep]])
        #expect(nested.map(\.path).last == "root.l1.l2.l3.l4")

        var wide = BSONDocument()
        for index in 0..<800 { wide.append("f\(index)", .int32(Int32(index))) }
        #expect(MongoConnection.completionFields(in: [wide]).count == 500)
    }
}

@Suite("Mongo completion fields live", .serialized, .enabled(if: MongoTestServer.isAvailable, "needs the MongoDB test server on 57017"))
struct MongoCompletionLiveTests {
    @Test func samplesSeededCollections() throws {
        let connection = try MongoTestServer.connect()
        defer { connection.close() }

        let orders = try connection.completionFields(collection: "orders")
        let orderTypes = Dictionary(uniqueKeysWithValues: orders.map { ($0.path, $0.typeName) })
        #expect(orders.first?.path == "_id")
        #expect(orderTypes["_id"] == "objectId")
        #expect(orderTypes["items"] == "array")
        #expect(orderTypes["items.sku"] == "string")
        #expect(orderTypes["items.price"] == "decimal")
        #expect(orderTypes["total"] == "decimal")
        #expect(orderTypes["createdAt"] == "date")

        let users = try connection.completionFields(collection: "users")
        let userPaths = Set(users.map(\.path))
        #expect(userPaths.isSuperset(of: ["name", "email", "address", "address.city", "address.street", "location.coordinates", "tags"]))

        let types = try connection.completionFields(collection: "types_demo")
        #expect(types.contains { $0.path == "object.b.d" && $0.typeName == "long" })
        #expect(try connection.completionFields(collection: "no_such_collection").isEmpty)
    }
}

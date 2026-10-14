import Foundation
import Testing
@testable import FoxlumeQueryCore

/// In-memory schema for completion tests; records which tables had their columns fetched.
@MainActor
final class FakeSchemaProvider: CompletionSchemaProvider {
    var tables: [TableInfo] = []
    /// Keyed by lowercased table name, or `schema.table` for a schema-specific entry.
    var columnsByTable: [String: [ColumnInfo]] = [:]
    var schemaTables: [String: [TableInfo]] = [:]
    var schemas: [String] = []
    var databases: [String] = []
    var implicit: String?
    var cached: [(table: TableRef, columns: [ColumnInfo])] = []
    var favoriteList: [CompletionFavorite] = []
    private(set) var fetched: [TableRef] = []

    func unqualifiedTables() async -> [TableInfo] { tables }
    func tables(inSchema schema: String) async -> [TableInfo]? { schemaTables[schema] }
    func schemaNames() async -> [String] { schemas }
    func databaseNames() async -> [String] { databases }
    func implicitSchema() async -> String? { implicit }
    func columns(of table: TableRef) async -> [ColumnInfo]? {
        fetched.append(table)
        if let schema = table.schema, let columns = columnsByTable["\(schema).\(table.name)".lowercased()] { return columns }
        return columnsByTable[table.name.lowercased()]
    }
    func cachedColumns() -> [(table: TableRef, columns: [ColumnInfo])] { cached }
    func documentFields(of collection: String) async -> [CompletionField] { [] }
    func keyNames(prefix: String, limit: Int) async -> [String] { [] }
    func favorites() -> [CompletionFavorite] { favoriteList }

    /// Adds a table whose columns are known (and cached unless told otherwise).
    func add(_ name: String, _ columns: [ColumnInfo], kind: TableKind = .table, schema: String? = nil, cache: Bool = true) {
        tables.append(TableInfo(ref: TableRef(schema: schema, name: name), kind: kind))
        columnsByTable[name.lowercased()] = columns
        if cache { cached.append((TableRef(schema: schema, name: name), columns)) }
    }

    func add(_ name: String, columns names: [String], schema: String? = nil) {
        add(name, names.map { ColumnInfo(name: $0, dataType: "INT") }, schema: schema)
    }

    /// Schema S of spec section 12.
    static func schemaS(cached: Bool = true) -> FakeSchemaProvider {
        let provider = FakeSchemaProvider()
        provider.add("users", [
            ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true),
            ColumnInfo(name: "name", dataType: "VARCHAR(255)"),
            ColumnInfo(name: "email", dataType: "VARCHAR(255)"),
            ColumnInfo(name: "created_at", dataType: "DATETIME"),
            ColumnInfo(name: "status", dataType: "enum('active','inactive')"),
        ], cache: cached)
        provider.add("orders", [
            ColumnInfo(name: "id", dataType: "INT", isPrimaryKey: true),
            ColumnInfo(name: "user_id", dataType: "INT"),
            ColumnInfo(name: "total", dataType: "DECIMAL(10,2)"),
            ColumnInfo(name: "created_at", dataType: "DATETIME"),
        ], cache: cached)
        provider.tables.append(TableInfo(ref: TableRef(name: "active_users"), kind: .view))
        return provider
    }
}

/// Spec section 12 rows 1–99 and 115–120, plus insertion, quoting, refilter and performance checks.
@Suite @MainActor struct SQLCompletionEngineTests {
    /// Splits `|` out of the marked text.
    func split(_ marked: String) -> (String, Int) {
        let caret = (marked as NSString).range(of: "|").location
        return ((marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: ""), caret)
    }

    func run(
        _ marked: String,
        _ provider: FakeSchemaProvider? = nil,
        family: SQLDialect.Family? = .mysql,
        manual: Bool = false,
        policy: KeywordCase = .matchTypedElseUpper
    ) async -> CompletionResult? {
        let (text, caret) = split(marked)
        let engine = SQLCompletionEngine(family: family, schema: provider)
        return await engine.complete(text: text, caret: caret, manual: manual, keywordCase: policy)
    }

    func labels(_ result: CompletionResult?) -> [String] { result?.items.map(\.label) ?? [] }
    func poolLabels(_ result: CompletionResult?) -> [String] { result?.pool.map(\.label) ?? [] }

    /// The text and caret after accepting `item`.
    func accept(_ item: CompletionItem, _ result: CompletionResult, in marked: String) -> (String, Int) {
        let (text, _) = split(marked)
        let replaced = (text as NSString).replacingCharacters(in: result.replacementRange, with: item.insertText)
        return (replaced, result.replacementRange.location + (item.insertText as NSString).length - item.caretOffsetFromEnd)
    }

    func item(_ result: CompletionResult?, _ label: String) -> CompletionItem? {
        result?.items.first { $0.label == label }
    }

    // MARK: SELECT list (rows 1–2, 20, 32–35)

    @Test func row01SelectWithoutTables() async throws {
        let s = FakeSchemaProvider.schemaS()
        let result = try #require(await run("SELECT |", s))
        let shown = labels(result)
        #expect(shown.contains("users.id") && shown.contains("orders.id") && shown.contains("users.created_at"))
        #expect(shown.contains("name") && shown.contains("user_id") && !shown.contains("id"))
        let star = try #require(shown.firstIndex(of: "*"))
        let columns = result.items.indices.filter { result.items[$0].kind == .column }
        #expect(columns.count == 9 && columns.allSatisfy { $0 < star })
        let firstFunction = try #require(result.items.firstIndex { $0.kind == .function })
        #expect(star < firstFunction)
        #expect(result.items.first { $0.label == "users.id" }?.priority == 150)
        // Keywords score 400+ and wait in the pool.
        #expect(!shown.contains("DISTINCT") && poolLabels(result).contains("DISTINCT"))
        #expect(labels(await run("SELECT DIS|", s)).contains("DISTINCT"))
    }

    @Test func row02AfterCommaStaysShutUntilManual() async throws {
        let s = FakeSchemaProvider.schemaS()
        #expect(await run("SELECT id, |", s) == nil)
        let manual = try #require(await run("SELECT id, |", s, manual: true))
        #expect(manual.items.first?.kind == .column)
    }

    @Test func row20TablesAfterTheCaretAreInScope() async throws {
        let result = try #require(await run("SELECT | FROM users", FakeSchemaProvider.schemaS()))
        #expect(Array(labels(result).prefix(2)) == ["*", "users.*"])
        #expect(item(result, "users.*")?.detail == "All columns from users")
        #expect(item(result, "*")?.detail == "All columns")
        #expect(labels(result).contains("status"))
    }

    @Test func row32CountOffersStarThenDistinct() async throws {
        let result = try #require(await run("SELECT COUNT(|", FakeSchemaProvider()))
        #expect(Array(labels(result).prefix(2)) == ["*", "DISTINCT"])
        #expect(result.items[0].documentation == "Count all rows")
        #expect(result.limit == 40)
    }

    @Test func row33SumOffersNoStar() async throws {
        let result = try #require(await run("SELECT SUM(|", FakeSchemaProvider.schemaS()))
        #expect(!labels(result).contains("*"))
        #expect(poolLabels(result).contains("DISTINCT"))
    }

    @Test func row34_35FunctionsInsertParentheses() async throws {
        let marked = "SELECT COU|"
        let upper = try #require(await run(marked, FakeSchemaProvider.schemaS()))
        let count = try #require(item(upper, "COUNT"))
        #expect(count.insertText == "COUNT()" && count.caretOffsetFromEnd == 1)
        #expect(accept(count, upper, in: marked) == ("SELECT COUNT()", 13))
        let lower = try #require(await run("select cou|", FakeSchemaProvider.schemaS()))
        #expect(item(lower, "count")?.insertText == "count()")
    }

    @Test func niladicFunctionsInsertWithoutParentheses() async throws {
        let result = try #require(await run("SELECT CURRENT_DA|", FakeSchemaProvider()))
        let date = try #require(item(result, "CURRENT_DATE"))
        #expect(date.insertText == "CURRENT_DATE" && date.caretOffsetFromEnd == 0)
    }

    // MARK: FROM / JOIN (rows 3–8)

    @Test func row03FromListsTablesFirst() async throws {
        let result = try #require(await run("SELECT * FROM |", FakeSchemaProvider.schemaS()))
        #expect(Array(labels(result).prefix(3)) == ["users", "orders", "active_users"])
        #expect(result.items[2].kind == .view && result.items[2].detail == "View")
        #expect(result.items[0].detail == "Table")
        #expect(result.items[3].kind == .keyword)
    }

    @Test func row04KeywordsLeadAfterATable() async throws {
        let result = try #require(await run("SELECT * FROM users |", FakeSchemaProvider.schemaS()))
        #expect(Array(labels(result).prefix(8)) == ["ON", "JOIN", "USING", "WHERE", "LIMIT", "UNION", "HAVING", "EXCEPT"])
    }

    @Test func row05JoinListsTablesFirst() async throws {
        let result = try #require(await run("SELECT * FROM users JOIN |", FakeSchemaProvider.schemaS()))
        #expect(Array(labels(result).prefix(3)) == ["users", "orders", "active_users"])
    }

    @Test func row06NearestJoinWinsOverEarlierOn() async throws {
        let provider = FakeSchemaProvider()
        for name in ["happiness_scores", "country_stats", "inflation_rates"] { provider.add(name, columns: ["country"]) }
        let marked = "SELECT * FROM happiness_scores hs INNER JOIN country_stats cs ON hs.country = cs.country INNER JOIN |"
        let result = try #require(await run(marked, provider))
        #expect(result.items.first?.kind == .table)
        #expect(labels(result).contains("inflation_rates"))
    }

    @Test func row07_08OnClauseTransitions() async throws {
        let typed = try #require(await run("SELECT * FROM a JOIN b ON a.id = b.id INNE|", FakeSchemaProvider()))
        #expect(labels(typed).first == "INNER JOIN")
        let empty = try #require(await run("SELECT * FROM a JOIN b ON a.id = b.id |", FakeSchemaProvider()))
        #expect(labels(empty).contains("INNER JOIN") && labels(empty).contains("WHERE"))
    }

    @Test func onClauseQualifiedColumnsAreNotDuplicated() async throws {
        let s = FakeSchemaProvider.schemaS()
        let result = try #require(await run("SELECT * FROM users u JOIN orders o ON o.user_id = |", s, manual: true))
        let ids = result.pool.filter { $0.label == "u.id" }
        #expect(ids.count == 1)
        #expect(ids.first?.priority == 80 && ids.first?.detail == "PK, NOT NULL, INT")
        // The generic and dialect `=` collapse into one row as well.
        let pg = try #require(await run("SELECT * FROM users u JOIN orders o ON o.user_id |", s, family: .postgresql, manual: true))
        #expect(pg.pool.filter { $0.label == "=" }.count == 1)
    }

    @Test func fromOffersDatabasesThenSchemasAsQualifiers() async throws {
        let provider = FakeSchemaProvider.schemaS()
        provider.databases = ["app"]
        provider.schemas = ["public", "sales", "app"]
        provider.implicit = "public"
        let result = try #require(await run("SELECT * FROM |", provider, manual: true))
        #expect(result.items.contains { $0.label == "app" && $0.kind == .database })
        #expect(result.items.contains { $0.label == "sales" && $0.kind == .schema && $0.detail == "Schema" })
        #expect(!labels(result).contains("public"))
        #expect(result.items.filter { $0.label == "app" }.count == 1)
    }

    // MARK: WHERE and values (rows 9–16)

    @Test func row09_10WhereAndAndStayShutUntilManual() async throws {
        let s = FakeSchemaProvider.schemaS()
        #expect(await run("SELECT * FROM users WHERE |", s) == nil)
        #expect(!(labels(await run("SELECT * FROM users WHERE |", s, manual: true)).isEmpty))
        #expect(await run("SELECT * FROM users WHERE id = 1 AND |", s) == nil)
    }

    @Test func row11ColumnsLeadWhileTyping() async throws {
        let result = try #require(await run("SELECT * FROM users WHERE id = 1 AND cre|", FakeSchemaProvider.schemaS()))
        #expect(labels(result).first == "created_at")
        let column = try #require(item(result, "created_at"))
        #expect(column.detail == "DATETIME" && column.documentation == "Column from users")
        #expect(column.highlights == [NSRange(location: 0, length: 3)])
    }

    @Test func row12_13AllowedValues() async throws {
        let s = FakeSchemaProvider.schemaS()
        let manual = try #require(await run("SELECT * FROM users WHERE status = |", s, manual: true))
        #expect(Array(labels(manual).prefix(2)) == ["'active'", "'inactive'"])
        #expect(manual.items[0].detail == "status" && manual.items[0].priority == 10)
        let marked = "SELECT * FROM users WHERE status = a|"
        let typed = try #require(await run(marked, s))
        let active = try #require(typed.items.first)
        #expect(active.label == "'active'")
        #expect(accept(active, typed, in: marked).0 == "SELECT * FROM users WHERE status = 'active'")
        // Never re-cased.
        let upper = try #require(await run("SELECT * FROM users WHERE status = A|", s))
        #expect(upper.items.first?.label == "'active'")
    }

    @Test func allowedValuesFromSetsAndChecks() {
        func values(_ type: String, extra: String? = nil) -> [String] {
            SQLCompletionItemBuilder.allowedValues(of: ColumnInfo(name: "c", dataType: type, extra: extra))
        }
        #expect(values("set('a','b''c')") == ["a", "b'c"])
        #expect(values("ENUM('x', 'y')") == ["x", "y"])
        #expect(values("text", extra: "CHECK (c IN ('low', 'high'))") == ["low", "high"])
        #expect(values("character varying CHECK (((c)::text = ANY ((ARRAY['on'::character varying, 'off'::character varying])::text[])))") == ["on", "off"])
        #expect(values("text", extra: "CHECK (c <> '')").isEmpty)
        #expect(values("varchar(10)").isEmpty)
    }

    @Test func row14_15_16StringsCommentsAndNestedComments() async throws {
        let s = FakeSchemaProvider.schemaS()
        #expect(await run("SELECT * FROM users WHERE name = 'Jo|", s, manual: true) == nil)
        #expect(await run("SELECT * FROM users -- comm|", s, manual: true) == nil)
        #expect(await run("/* outer /* inner */ still */SELECT |", s) != nil)
    }

    // MARK: Qualified names (rows 17–19, 21–28)

    @Test func row17QualifiedAliasOffersPlainColumns() async throws {
        let result = try #require(await run("SELECT u.| FROM users u", FakeSchemaProvider.schemaS()))
        // Ordered by score: same priority, so shorter names first.
        #expect(labels(result) == ["id", "name", "email", "status", "created_at"])
        #expect(result.items[0].detail == "PK, NOT NULL, INT")
        #expect(result.limit == 40)
    }

    @Test func row18_19TwoTablesQualifyColumns() async throws {
        let provider = FakeSchemaProvider()
        provider.add("users", columns: ["user_name"])
        provider.add("orders", columns: ["order_total"])
        let typed = try #require(await run("SELECT * FROM users u, orders o WHERE user_|", provider))
        let column = try #require(item(typed, "u.user_name"))
        #expect(column.insertText == "u.user_name")

        let fresh = FakeSchemaProvider()
        fresh.add("users", columns: ["user_name"])
        fresh.add("orders", columns: ["order_total"])
        let qualified = try #require(await run("SELECT * FROM users u, orders o WHERE u.|", fresh))
        #expect(labels(qualified) == ["user_name"])
        #expect(fresh.fetched.map(\.name) == ["users"])
    }

    @Test func row21DerivedTableColumns() async throws {
        let provider = FakeSchemaProvider()
        provider.add("happiness_scores", columns: ["country", "score"])
        let marked = "SELECT ahs.| FROM happiness_scores hs LEFT JOIN (SELECT country, AVG(score) AS avg_score FROM happiness_scores GROUP BY country) ahs ON hs.country = ahs.country"
        let result = try #require(await run(marked, provider))
        #expect(labels(result) == ["country", "avg_score"])
        #expect(result.items[0].documentation == "Column from ahs" && result.items[0].detail == nil)
    }

    @Test func row22_23CTEColumns() async throws {
        let provider = FakeSchemaProvider()
        provider.add("sales", columns: ["region", "amount"])
        let cte = try #require(await run("WITH totals AS (SELECT region, SUM(amount) AS total FROM sales GROUP BY region) SELECT t.| FROM totals t", provider))
        #expect(Set(labels(cte)) == ["region", "total"])
        let explicit = try #require(await run("WITH totals (region, amount) AS (SELECT country, SUM(score) FROM s GROUP BY country) SELECT t.| FROM totals t", provider))
        #expect(Set(labels(explicit)) == ["region", "amount"])
    }

    @Test func row24StarDerivedTableHasNoColumns() async throws {
        #expect(await run("SELECT * FROM (SELECT * FROM users) d WHERE d.|", FakeSchemaProvider.schemaS()) == nil)
    }

    @Test func row25_26SchemaOfReferences() async throws {
        let provider = FakeSchemaProvider()
        provider.columnsByTable["public.users"] = [ColumnInfo(name: "id", dataType: "integer")]
        let result = try #require(await run("SELECT * FROM public.users WHERE |", provider, family: .postgresql, manual: true))
        #expect(labels(result).contains("id"))
        #expect(provider.fetched.first == TableRef(schema: "public", name: "users"))
        let context = try #require(SQLContextAnalyzer.analyze(text: "SELECT * FROM analytics.sales.orders WHERE x", caret: 44, family: .mysql))
        #expect(context.references == [SQLTableReference(schema: "sales", table: "orders")])
    }

    @Test func row27SchemaQualifierListsItsTables() async throws {
        let provider = FakeSchemaProvider()
        provider.schemas = ["public", "sales"]
        provider.implicit = "public"
        provider.schemaTables["sales"] = [TableInfo(ref: TableRef(schema: "sales", name: "orders_2024")), TableInfo(ref: TableRef(schema: "sales", name: "Summary"), kind: .view)]
        let result = try #require(await run("SELECT * FROM sales.|", provider, family: .postgresql))
        #expect(labels(result) == ["orders_2024", "Summary"])
        // PostgreSQL folds bare names, so a capital needs quotes.
        #expect(item(result, "Summary")?.insertText == "\"Summary\"")
    }

    @Test func databaseQualifierListsSchemas() async throws {
        let provider = FakeSchemaProvider()
        provider.databases = ["warehouse"]
        provider.schemas = ["public", "sales"]
        let result = try #require(await run("SELECT * FROM warehouse.|", provider, family: .postgresql))
        #expect(Set(labels(result)) == ["public", "sales"])
    }

    @Test func row28UnknownQualifierShowsNothing() async throws {
        #expect(await run("SELECT nope.|", FakeSchemaProvider.schemaS()) == nil)
        #expect(await run("SELECT nope.|", FakeSchemaProvider.schemaS(), manual: true) == nil)
    }

    @Test func qualifierResolvesLoadedTablesWithoutFrom() async throws {
        let result = try #require(await run("SELECT users.| ", FakeSchemaProvider.schemaS()))
        #expect(labels(result).first == "id")
    }

    // MARK: Quotes (rows 29–31) and quoting on insert (A.2)

    @Test func row29_30BacktickedTokens() async throws {
        let provider = FakeSchemaProvider()
        provider.add("category", columns: ["id"])
        provider.add("inflation_rates", columns: ["id"])
        let marked = "SELECT * FROM `cat|"
        let result = try #require(await run(marked, provider))
        let category = try #require(result.items.first)
        #expect(category.label == "category")
        #expect(result.replacementRange == NSRange(location: 14, length: 4))
        // The typed quote is replaced by a quoted name (Foxlume Query decision A.2).
        #expect(accept(category, result, in: marked).0 == "SELECT * FROM `category`")
        let closed = try #require(await run("SELECT * FROM `cat`|", provider))
        #expect(accept(closed.items[0], closed, in: "SELECT * FROM `cat`|").0 == "SELECT * FROM `category`")
        let lone = try #require(await run("SELECT * FROM `|", provider))
        #expect(Set(labels(lone).prefix(2)) == ["category", "inflation_rates"])
    }

    @Test func row31DoubleQuoteDependsOnDialect() async throws {
        let provider = FakeSchemaProvider()
        provider.add("category", columns: ["id"])
        // MySQL: "… is a string. PostgreSQL: an identifier being typed (A.1).
        #expect(await run("SELECT * FROM \"cat|", provider, family: .mysql, manual: true) == nil)
        let pg = try #require(await run("SELECT * FROM \"cat|", provider, family: .postgresql))
        #expect(pg.items.first?.insertText == "\"category\"")
    }

    @Test func namesNeedingQuotesAreQuoted() async throws {
        let provider = FakeSchemaProvider()
        provider.add("order", [ColumnInfo(name: "group", dataType: "INT"), ColumnInfo(name: "first name", dataType: "TEXT"), ColumnInfo(name: "Total", dataType: "INT")])
        let mysql = try #require(await run("SELECT * FROM ord|", provider))
        #expect(item(mysql, "order")?.insertText == "`order`")
        let columns = try #require(await run("SELECT o.| FROM `order` o", provider))
        #expect(item(columns, "group")?.insertText == "`group`")
        #expect(item(columns, "first name")?.insertText == "`first name`")
        #expect(item(columns, "Total")?.insertText == "Total")
        let pg = try #require(await run("SELECT o.| FROM \"order\" o", provider, family: .postgresql))
        #expect(item(pg, "Total")?.insertText == "\"Total\"")
        #expect(SQLIdentifierQuoting.insertText(for: "2fa", family: .sqlite, typedQuote: nil) == "\"2fa\"")
        #expect(SQLIdentifierQuoting.insertText(for: "名前", family: .postgresql, typedQuote: nil) == "名前")
        #expect(SQLIdentifierQuoting.insertText(for: "a`b", family: .mysql, typedQuote: nil) == "`a``b`")
        // Reserved words differ per engine: `user` is fine bare in MySQL, `key` is fine bare in PostgreSQL.
        #expect(SQLIdentifierQuoting.insertText(for: "user", family: .mysql, typedQuote: nil) == "user")
        #expect(SQLIdentifierQuoting.insertText(for: "user", family: .postgresql, typedQuote: nil) == "\"user\"")
        #expect(SQLIdentifierQuoting.insertText(for: "key", family: .mysql, typedQuote: nil) == "`key`")
        #expect(SQLIdentifierQuoting.insertText(for: "key", family: .postgresql, typedQuote: nil) == "key")
        #expect(SQLIdentifierQuoting.insertText(for: "status", family: .postgresql, typedQuote: nil) == "status")
    }

    // MARK: Statement start and matching (rows 36–40)

    @Test func row36_37StatementStartFollowsTypedCase() async throws {
        let lower = try #require(await run("sel|", FakeSchemaProvider()))
        #expect(lower.items.first?.label == "select" && lower.items.first?.insertText == "select")
        let upper = try #require(await run("SEL|", FakeSchemaProvider()))
        #expect(upper.items.first?.label == "SELECT")
        #expect(upper.limit == 20)
    }

    @Test func row38_39_40SubstringFuzzyAndNothing() async throws {
        #expect(labels(await run("ELE|", FakeSchemaProvider())).contains("SELECT"))
        let fuzzy = try #require(await run("slc|", FakeSchemaProvider()))
        let select = try #require(item(fuzzy, "select"))
        #expect(select.highlights == [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1), NSRange(location: 4, length: 1)])
        #expect(await run("zzzqqq|", FakeSchemaProvider()) == nil)
        #expect(await run("zzzqqq|", FakeSchemaProvider(), manual: true) == nil)
    }

    @Test func statementStartAlsoOffersTables() async throws {
        let result = try #require(await run("use|", FakeSchemaProvider.schemaS()))
        #expect(labels(result).contains("users"))
        #expect(await run("|", FakeSchemaProvider.schemaS()) == nil)
        #expect(await run("|", FakeSchemaProvider.schemaS(), manual: true) != nil)
    }

    // MARK: Re-filtering (rows 41–42, spec 1.5)

    @Test func row41PoolRerankedForLongerToken() async throws {
        let s = FakeSchemaProvider.schemaS()
        let engine = SQLCompletionEngine(family: .mysql, schema: s)
        let text = "select * from t where t"
        let result = try #require(await engine.complete(text: text, caret: (text as NSString).length, manual: false, keywordCase: .matchTypedElseUpper))
        let refiltered = engine.refilter(result, token: "true", keywordCase: .matchTypedElseUpper)
        #expect(refiltered.first?.label == "true")
        #expect(refiltered.first?.highlights == [NSRange(location: 0, length: 4)])
        // Backspacing widens the list again from the pool.
        #expect(engine.refilter(result, token: "t", keywordCase: .matchTypedElseUpper).count == result.items.count)
    }

    @Test func row42VisibleListIsAPrefixOfThePool() async throws {
        let provider = FakeSchemaProvider()
        provider.add("gt_user", columns: ["title", "tag", "id"])
        let result = try #require(await run("SELECT * FROM gt_user WHERE t|", provider, family: .postgresql))
        #expect(result.pool.count >= result.items.count)
        #expect(result.pool.count <= result.limit * 10)
        #expect(result.items.map { $0.label.lowercased() } == result.pool.prefix(result.items.count).map { $0.label.lowercased() })
    }

    @Test func refilterRules() async throws {
        let s = FakeSchemaProvider.schemaS()
        let engine = SQLCompletionEngine(family: .mysql, schema: s)
        let text = "SELECT * FROM users WHERE n"
        let result = try #require(await engine.complete(text: text, caret: (text as NSString).length, manual: false, keywordCase: .matchTypedElseUpper))
        #expect(engine.refilter(result, token: "", keywordCase: .matchTypedElseUpper).isEmpty)
        #expect(engine.refilter(result, token: String(repeating: "n", count: 501), keywordCase: .matchTypedElseUpper).isEmpty)
        #expect(engine.refilter(result, token: "`", keywordCase: .matchTypedElseUpper).isEmpty)
        #expect(engine.refilter(result, token: "\"\"", keywordCase: .matchTypedElseUpper).isEmpty)
        let nam = engine.refilter(result, token: "nam", keywordCase: .matchTypedElseUpper)
        #expect(nam.first?.label == "name")
        let upper = engine.refilter(result, token: "NU", keywordCase: .matchTypedElseUpper)
        #expect(upper.contains { $0.label == "NULL" })
        #expect(engine.refilter(result, token: "zzzz", keywordCase: .matchTypedElseUpper).isEmpty)
        #expect(result.refilterState.context == SQLClause.whereClause.rawValue && result.refilterState.hasTablesInScope)
    }

    @Test func triggerCharacters() {
        let engine = SQLCompletionEngine(family: .mysql, schema: nil)
        #expect(engine.triggerCharacters == [".", " ", ":", "(", ","])
    }

    // MARK: Keyword positions (rows 43–58)

    @Test func row43_44_45WhereKeywords() async throws {
        let s = FakeSchemaProvider.schemaS()
        #expect(labels(await run("SELECT * FROM users WHERE id IN|", s)).first == "IN")
        let isList = labels(await run("SELECT * FROM users WHERE name IS|", s))
        #expect(isList.contains("IS NULL") && isList.contains("IS NOT NULL"))
        #expect(labels(await run("SELECT * FROM users WHERE id = 1 ORD|", s)).contains("ORDER BY"))
    }

    @Test func row46_47_48OrderByAndLimit() async throws {
        let s = FakeSchemaProvider.schemaS()
        let order = labels(await run("SELECT * FROM users ORDER BY name |", s, manual: true))
        for word in ["ASC", "DESC", "NULLS FIRST", "NULLS LAST", "LIMIT"] { #expect(order.contains(word)) }
        let offset = try #require(await run("SELECT * FROM users ORDER BY name ASC LIMIT 10 OFF|", s))
        #expect(labels(offset).contains("OFFSET") && offset.items.count < 20)
        #expect(await run("SELECT * FROM users LIMIT |", s) == nil)
        let limit = try #require(await run("SELECT * FROM users LIMIT |", s, manual: true))
        #expect(Set(labels(limit)) == ["OFFSET", "FETCH", "NEXT", "ROWS", "ONLY"])
    }

    @Test func row49GroupBy() async throws {
        let result = labels(await run("SELECT COUNT(*) FROM users GROUP BY status |", FakeSchemaProvider.schemaS(), manual: true))
        #expect(result.contains("HAVING") && result.contains("ORDER BY"))
    }

    @Test func row50_51UpdateSet() async throws {
        let s = FakeSchemaProvider.schemaS()
        let result = try #require(await run("UPDATE users SET |", s, family: .postgresql))
        let shown = labels(result)
        for word in ["id", "name", "email", "created_at", "status", "WHERE", "RETURNING"] { #expect(shown.contains(word)) }
        #expect(!shown.contains("user_id"))
        // MySQL has no RETURNING.
        let mysql = labels(await run("UPDATE users SET |", s))
        #expect(mysql.contains("WHERE") && !mysql.contains("RETURNING"))
        #expect(SQLContextAnalyzer.analyze(text: "UPDATE users SET name = 'a' WHERE ", caret: 34, family: .mysql)?.clause == .whereClause)
        // Typing in SET puts columns ahead of keywords.
        #expect(labels(await run("UPDATE users SET n|", s)).first == "name")
    }

    @Test func row52_53_54InsertInto() async throws {
        let s = FakeSchemaProvider.schemaS()
        let into = try #require(await run("INSERT INTO |", s))
        #expect(into.items.first?.kind == .table)
        let after = labels(await run("INSERT INTO users |", s))
        #expect(after.contains("VALUES") && after.contains("SELECT"))
        let columns = labels(await run("INSERT INTO users (id, |", s))
        #expect(columns.contains("name") && columns.contains("status") && !columns.contains("user_id"))
    }

    @Test func row55_56_57ValuesAndReturning() async throws {
        let s = FakeSchemaProvider.schemaS()
        #expect(labels(await run("INSERT INTO users (name) VALUES ('test') RE|", s, family: .postgresql)).contains("RETURNING"))
        #expect(labels(await run("INSERT INTO t VALUES (1) RETURNING |", s, family: .postgresql)).contains("*"))
        // After the tuple only the clauses that can follow it; inside a tuple the value keywords.
        let after = labels(await run("INSERT INTO users (name) VALUES ('test') |", s, family: .postgresql, manual: true))
        #expect(Set(after) == ["ON CONFLICT", "RETURNING"])
        let inside = labels(await run("INSERT INTO users (name) VALUES ('test', |", s, family: .postgresql, manual: true))
        for word in ["NULL", "DEFAULT", "TRUE", "FALSE"] { #expect(inside.contains(word)) }
        #expect(!inside.contains("RETURNING") && !inside.contains("ON CONFLICT"))
        // MySQL offers its own upsert clause and neither PostgreSQL one.
        let mysql = labels(await run("INSERT INTO users (name) VALUES ('test') |", s, manual: true))
        #expect(mysql.contains("ON DUPLICATE KEY UPDATE") && !mysql.contains("ON CONFLICT") && !mysql.contains("RETURNING"))
    }

    @Test func row58DeleteScope() async throws {
        let result = labels(await run("DELETE FROM users WHERE |", FakeSchemaProvider.schemaS(), manual: true))
        #expect(result.contains("status") && !result.contains("user_id"))
    }

    // MARK: CASE, subqueries, lists, windows (rows 59–66)

    @Test func row59_60_61_62ClausesAroundParensAndCase() async throws {
        func clause(_ marked: String) -> SQLClause? {
            let (text, caret) = split(marked)
            return SQLContextAnalyzer.analyze(text: text, caret: caret, family: .mysql)?.clause
        }
        #expect(clause("SELECT CASE WHEN a THEN b END, |") == .selectList)
        #expect(clause("SELECT CASE WHEN x = 1 THEN |") == .caseExpression)
        // Functions (300) outrank keywords (400) in CASE, so its keywords surface once a letter is typed.
        #expect(labels(await run("SELECT CASE WHEN x = 1 THEN 2 EN|", FakeSchemaProvider())).contains("END"))
        #expect(labels(await run("SELECT CASE WHEN x = 1 THEN 2 ELS|", FakeSchemaProvider())).first == "ELSE")
        #expect(await run("SELECT CASE WHEN x = 1 THEN |", FakeSchemaProvider()) == nil)
        #expect(clause("SELECT * FROM t WHERE id IN (SELECT id FROM u WHERE |") == .whereClause)
        #expect(clause("SELECT * FROM users WHERE id IN (SELECT 1) AND |") == .and)
    }

    @Test func row63_64_65_66ListsWindowsUnionUsing() async throws {
        let s = FakeSchemaProvider.schemaS()
        #expect(labels(await run("SELECT * FROM users WHERE id IN (|", s, manual: true)).contains("SELECT"))
        let window = labels(await run("SELECT ROW_NUMBER() OVER (|", FakeSchemaProvider(), manual: true))
        for word in ["PARTITION BY", "ORDER BY", "ROWS", "RANGE"] { #expect(window.contains(word)) }
        #expect(Set(labels(await run("SELECT id FROM users UNION |", s, manual: true))) == ["SELECT", "ALL"])
        let provider = FakeSchemaProvider()
        provider.add("a", columns: ["id", "name"])
        provider.add("b", columns: ["id", "a_id"])
        let using = try #require(await run("SELECT * FROM a JOIN b USING (|", provider))
        #expect(labels(using).contains("a.id") && labels(using).contains("b.a_id"))
    }

    // MARK: DDL (rows 67–82)

    @Test func row67_68CreateTableColumnList() async throws {
        let manual = labels(await run("CREATE TABLE test (id |", FakeSchemaProvider(), family: nil, manual: true))
        #expect(manual.contains("INT"))
        for function in ["SUM", "AVG", "COUNT"] { #expect(!manual.contains(function)) }
        #expect(await run("CREATE TABLE test (id |", FakeSchemaProvider(), family: nil) == nil)
        #expect(labels(await run("CREATE TABLE test (id VAR|", FakeSchemaProvider(), family: nil)).contains("VARCHAR"))
        // The column list survives a closed type paren (A.5).
        #expect(labels(await run("CREATE TABLE test (name VARCHAR(255), id IN|", FakeSchemaProvider(), family: nil)).contains("INT"))
    }

    @Test func row69ForeignKeyKeywordsLead() async throws {
        let result = try #require(await run("CREATE TABLE test (id INT PRIMARY KEY, user_id INT |", FakeSchemaProvider(), family: nil, manual: true))
        #expect(Set(labels(result).prefix(7)) == ["REFERENCES", "ON DELETE", "ON UPDATE", "CASCADE", "RESTRICT", "SET NULL", "NO ACTION"])
        #expect(result.items[0].priority == 300)
        let types = Set(SQLCompletionVocabulary.dataTypes(nil))
        #expect(types.contains(result.items[7].label) && result.items[7].priority == 380)
    }

    @Test func row70_71DialectTypes() async throws {
        #expect(labels(await run("CREATE TABLE test (col JSON|", FakeSchemaProvider(), family: .postgresql)).contains("JSONB"))
        let mysql = try #require(await run("CREATE TABLE test (col |", FakeSchemaProvider(), family: .mysql, manual: true))
        #expect(poolLabels(mysql).contains("ENUM"))
        let sqlite = try #require(await run("CREATE TABLE test (col |", FakeSchemaProvider(), family: .sqlite, manual: true))
        #expect(!poolLabels(sqlite).contains("JSONB"))
        #expect(await run("CREATE TABLE test (col JSONB|", FakeSchemaProvider(), family: .sqlite).map { labels($0).contains("JSONB") } != true)
    }

    @Test func row72_73CreateTableOptions() async throws {
        #expect(labels(await run("CREATE TABLE test (id INT) ENG|", FakeSchemaProvider(), family: nil)).contains("ENGINE"))
        #expect(labels(await run("CREATE TABLE test (id INT) ENG|", FakeSchemaProvider(), family: .mysql)).contains("ENGINE=InnoDB"))
        #expect(labels(await run("CREATE TABLE |", FakeSchemaProvider(), manual: true)).contains("IF NOT EXISTS"))
    }

    @Test func row74_75_76_77AlterTable() async throws {
        let s = FakeSchemaProvider.schemaS()
        let alter = labels(await run("ALTER TABLE users |", s, manual: true))
        for word in ["ADD", "DROP", "MODIFY", "CHANGE", "RENAME"] { #expect(alter.contains(word)) }
        let definition = labels(await run("ALTER TABLE users ADD COLUMN email |", s, family: nil, manual: true))
        #expect(definition.contains("VARCHAR") && definition.contains("INT"))
        let drop = try #require(await run("ALTER TABLE users DROP COLUMN |", s))
        #expect(Set(labels(drop)) == ["id", "name", "email", "created_at", "status"])
        let constraint = labels(await run("ALTER TABLE users ADD CONSTRAINT |", s, manual: true))
        for word in ["PRIMARY KEY", "UNIQUE", "FOREIGN KEY", "CHECK"] { #expect(constraint.contains(word)) }
    }

    @Test func row78_79_80_81_82DropIndexView() async throws {
        let s = FakeSchemaProvider.schemaS()
        let drop = labels(await run("DROP TABLE IF EXISTS |", s))
        for word in ["users", "orders", "IF EXISTS", "CASCADE", "RESTRICT"] { #expect(drop.contains(word)) }
        let index = labels(await run("CREATE INDEX |", s))
        #expect(index.contains("users") && index.contains("ON"))
        let columns = labels(await run("CREATE INDEX idx ON users (|", s))
        for word in ["id", "status", "USING", "BTREE", "HASH", "GIN", "GIST"] { #expect(columns.contains(word)) }
        #expect(!columns.contains("user_id"))
        // A.6: the table slot after ON lists tables.
        let onTable = try #require(await run("CREATE INDEX idx ON |", s))
        #expect(onTable.items.first?.label == "users")
        let view = labels(await run("CREATE OR REPLACE VIEW |", s, manual: true))
        for word in ["SELECT", "AS", "users"] { #expect(view.contains(word)) }
        // A.7: a view body completes like a query.
        #expect(labels(await run("CREATE VIEW v AS SELECT * FROM users WHERE st|", s)).first == "status")
    }

    // MARK: Casts and statements (rows 83–86)

    @Test func row83_84CastTargets() async throws {
        let result = try #require(await run("SELECT id::|", FakeSchemaProvider(), family: .postgresql))
        #expect(result.items.allSatisfy { $0.label == $0.label.lowercased() && !$0.followsKeywordCase })
        for type in ["integer", "jsonb", "timestamptz"] { #expect(poolLabels(result).contains(type)) }
        #expect(result.items.first?.priority == 300)
        let typed = try #require(await run("SELECT id::JS|", FakeSchemaProvider(), family: .postgresql))
        #expect(typed.items.first?.label.hasPrefix("json") == true && labels(typed).contains("jsonb"))
        #expect(await run("SELECT id::|", FakeSchemaProvider(), family: nil, manual: true) == nil)
    }

    @Test func row85_86Statements() async throws {
        let s = FakeSchemaProvider.schemaS()
        let second = try #require(await run("SELECT 1; SELECT * FROM |", s))
        #expect(second.items.first?.kind == .table)
        #expect(await run("SELECT 1;|", s, manual: true) == nil)
    }

    // MARK: Favorites (rows 87–90)

    func favorites(_ list: [CompletionFavorite]) -> FakeSchemaProvider {
        let provider = FakeSchemaProvider()
        provider.favoriteList = list
        return provider
    }

    @Test func row87_88_89Favorites() async throws {
        let provider = favorites([CompletionFavorite(keyword: "report", name: "Daily Report", query: "SELECT * FROM reports")])
        let marked = "rep|"
        let result = try #require(await run(marked, provider))
        let favorite = try #require(result.items.first { $0.kind == .favorite })
        #expect(favorite.label == "report" && favorite.detail == "Daily Report" && favorite.documentation == "SELECT * FROM reports")
        #expect(accept(favorite, result, in: marked).0 == "SELECT * FROM reports")
        #expect(await run("SEL|", provider).map { $0.items.contains { $0.kind == .favorite } } == false)
        let col = favorites([CompletionFavorite(keyword: "col", name: "Columns", query: "SELECT 1")])
        col.add("users", columns: ["column_a"])
        #expect(await run("SELECT users.col|", col).map { $0.pool.contains { $0.kind == .favorite } } != true)
        // Favorites keep their own case.
        let upper = try #require(await run("REP|", provider))
        #expect(upper.items.contains { $0.label == "report" })
    }

    @Test func row90FavoriteCaretMarker() async throws {
        let provider = favorites([CompletionFavorite(keyword: "cnt", name: "Count", query: "SELECT COUNT(*) FROM t WHERE ;; LIMIT 1")])
        let marked = "cnt|"
        let result = try #require(await run(marked, provider))
        let favorite = try #require(result.items.first { $0.kind == .favorite })
        let (text, caret) = accept(favorite, result, in: marked)
        #expect(text == "SELECT COUNT(*) FROM t WHERE  LIMIT 1" && caret == 29)
        let parens = SQLCompletionItemBuilder(family: .mysql, token: "").favorite(CompletionFavorite(keyword: "n", name: "Now", query: "SELECT NOW()"))
        #expect(parens.caretOffsetFromEnd == 1)
    }

    // MARK: Casing (rows 91–96)

    func cased(_ result: CompletionResult?, policy: KeywordCase = .matchTypedElseUpper) -> [String] {
        guard let result else { return [] }
        return KeywordCasing.apply(items: result.pool, prefix: result.prefix, policy: policy).map(\.label)
    }

    @Test func row91_92PhrasesFoldAsOne() async throws {
        #expect(labels(await run("SELECT * FROM t group b|", FakeSchemaProvider())).contains("group by"))
        #expect(cased(await run("SELECT * FROM t WHERE a IS N|", FakeSchemaProvider())).contains("IS NOT NULL"))
    }

    @Test func row93_94AbsolutePolicies() async throws {
        #expect(labels(await run("sel|", FakeSchemaProvider(), policy: .upper)).first == "SELECT")
        #expect(labels(await run("SEL|", FakeSchemaProvider(), policy: .lower)).first == "select")
    }

    @Test func row95DialectOperatorsFollowCasing() async throws {
        let result = await run("SELECT * FROM t WHERE a is d|", FakeSchemaProvider(), family: .postgresql)
        #expect(cased(result).contains("is distinct from"))
    }

    @Test func row96CaseSensitiveFunctionNamesStayAsWritten() {
        let build = SQLCompletionItemBuilder(family: nil, token: "tos")
        let item = build.function(SQLFunctionEntry(name: "toString", signature: "toString(x)"))
        #expect(!item.followsKeywordCase && item.insertText == "toString()")
        #expect(KeywordCasing.apply(items: [item], prefix: "TOS", policy: .matchTypedElseUpper)[0].insertText == "toString()")
    }

    // MARK: Replacement (rows 97–99)

    @Test func row97_98_99OnlyTheTokenIsReplaced() async throws {
        let provider = FakeSchemaProvider()
        provider.add("people", [ColumnInfo(name: "名前", dataType: "TEXT"), ColumnInfo(name: "name", dataType: "TEXT")])
        let cjk = "SELECT 名|"
        let cjkResult = try #require(await run(cjk, provider))
        #expect(accept(try #require(item(cjkResult, "名前")), cjkResult, in: cjk).0 == "SELECT 名前")
        let dotted = "SELECT people.na|"
        let dottedResult = try #require(await run(dotted, provider))
        #expect(accept(try #require(item(dottedResult, "name")), dottedResult, in: dotted).0 == "SELECT people.name")
        let middle = "SELECT na|me"
        let middleResult = try #require(await run(middle, provider))
        #expect(accept(try #require(item(middleResult, "name")), middleResult, in: middle).0 == "SELECT nameme")
    }

    // MARK: Filter box (rows 115–120)

    func filter(_ marked: String, _ provider: FakeSchemaProvider, table: String = "users", family: SQLDialect.Family? = .mysql) async -> CompletionResult? {
        let (text, caret) = split(marked)
        let engine = SQLCompletionEngine(family: family, schema: provider)
        return await engine.completeFilter(fragment: text, caret: caret, table: TableRef(name: table), keywordCase: .matchTypedElseUpper)
    }

    @Test func row115FilterRangeMapsBackIntoTheField() async throws {
        let result = try #require(await filter("id = 1 AND cre|", FakeSchemaProvider.schemaS()))
        #expect(labels(result).first == "created_at")
        #expect(result.replacementRange == NSRange(location: 11, length: 3))
    }

    @Test func row116FilterUsesOnlyTheFilteredTable() async throws {
        let provider = FakeSchemaProvider()
        provider.add("users", columns: ["title"])
        provider.add("orders", columns: ["total"])
        let result = labels(await filter("id = 1 AND t|", provider))
        #expect(result.contains("title") && !result.contains("total"))
        #expect(!labels(await filter("x = 1 FROM orders WHERE t|", provider)).contains("total"))
    }

    @Test func row117_118_119_120FilterTriggerPolicy() async throws {
        let s = FakeSchemaProvider.schemaS()
        #expect(await filter("region='EU'|", s) == nil)
        #expect(await filter("region IN ('EU')|", s) == nil)
        #expect(await filter("id = 1 AND |", s) == nil)
        #expect(await filter("|", s) == nil)
        let backtick = try #require(await filter("`|", s))
        for column in ["id", "name", "email", "created_at", "status"] { #expect(labels(backtick).contains(column)) }
        #expect(await filter("\"|", s) == nil)
        #expect(labels(await filter("users.|", s)).contains("email"))
        let cast = try #require(await filter("id::|", FakeSchemaProvider(), family: .postgresql))
        #expect(poolLabels(cast).contains("jsonb"))
    }

    // MARK: Review fixes

    @Test func quoteTypedBeforeExistingFromKeepsItsTables() async throws {
        let s = FakeSchemaProvider.schemaS()
        let pg = try #require(await run("SELECT u.\"na| FROM users u", s, family: .postgresql))
        #expect(item(pg, "name")?.insertText == "\"name\"")
        let mysql = try #require(await run("SELECT u.`na| FROM users u", s))
        #expect(item(mysql, "name")?.insertText == "`name`")
        // Two tables after the caret: qualified names from both, not every cached column.
        let joined = try #require(await run("SELECT `na| FROM users u JOIN orders o ON o.user_id = u.id", FakeSchemaProvider.schemaS(cached: false)))
        #expect(item(joined, "u.name")?.insertText == "`u`.`name`")
        #expect(!labels(joined).contains("name"))
    }

    @Test func engineReservedNamesAreQuoted() async throws {
        let provider = FakeSchemaProvider()
        provider.add("scores", [ColumnInfo(name: "rank", dataType: "INT"), ColumnInfo(name: "status", dataType: "INT"), ColumnInfo(name: "verbose", dataType: "INT"), ColumnInfo(name: "qualify", dataType: "INT")])
        let mysql = try #require(await run("SELECT s.| FROM scores s", provider))
        #expect(item(mysql, "rank")?.insertText == "`rank`")
        #expect(item(mysql, "status")?.insertText == "status")
        #expect(item(mysql, "verbose")?.insertText == "verbose")
        let pg = try #require(await run("SELECT s.| FROM scores s", provider, family: .postgresql))
        #expect(item(pg, "rank")?.insertText == "rank")
        #expect(item(pg, "verbose")?.insertText == "\"verbose\"")
        let duck = try #require(await run("SELECT s.| FROM scores s", provider, family: .duckdb))
        #expect(item(duck, "qualify")?.insertText == "\"qualify\"")
    }

    @Test func dialectAdjustedFunctionsAndCastTargets() async throws {
        // MySQL only accepts USER() with parentheses; PostgreSQL's USER is niladic (A.3).
        let mysql = try #require(await run("SELECT USE|", FakeSchemaProvider(), manual: true))
        #expect(item(mysql, "USER")?.insertText == "USER()")
        let pg = try #require(await run("SELECT USE|", FakeSchemaProvider(), family: .postgresql, manual: true))
        #expect(item(pg, "USER")?.insertText == "USER")
        // Column-only pseudo-types are no cast targets.
        let cast = try #require(await run("SELECT id::ser|", FakeSchemaProvider(), family: .postgresql, manual: true))
        #expect(!poolLabels(cast).contains("serial") && !poolLabels(cast).contains("bigserial"))
    }

    @Test func refilterDropsAFavoriteOnceItsKeywordNoLongerStartsTheToken() async throws {
        let provider = favorites([CompletionFavorite(keyword: "report", name: "Daily Report", query: "SELECT * FROM reports")])
        let engine = SQLCompletionEngine(family: .mysql, schema: provider)
        let result = try #require(await engine.complete(text: "re", caret: 2, manual: false, keywordCase: .matchTypedElseUpper))
        #expect(result.items.contains { $0.kind == .favorite })
        #expect(engine.refilter(result, token: "rep", keywordCase: .matchTypedElseUpper).contains { $0.kind == .favorite })
        #expect(!engine.refilter(result, token: "rept", keywordCase: .matchTypedElseUpper).contains { $0.kind == .favorite })
        #expect(await engine.complete(text: "rept", caret: 4, manual: false, keywordCase: .matchTypedElseUpper)?.items.contains { $0.kind == .favorite } != true)
    }

    @Test func tablesAfterADerivedTableAreInScope() async throws {
        let result = try #require(await run("SELECT * FROM (SELECT id FROM users) d, orders o WHERE o.|", FakeSchemaProvider.schemaS()))
        #expect(labels(result).contains("user_id") && labels(result).contains("total"))
    }

    @Test func highlightsNeverOverrunTheLabel() async throws {
        let provider = FakeSchemaProvider()
        provider.add("cafe", columns: ["café", "İd"])
        for marked in ["SELECT cafe\u{301}| FROM cafe", "SELECT i\u{307}| FROM cafe", "SELECT İ| FROM cafe"] {
            let result = try #require(await run(marked, provider, manual: true))
            for row in result.items + result.pool {
                #expect(row.highlights.allSatisfy { NSMaxRange($0) <= row.label.utf16.count }, "\(row.label) \(row.highlights)")
            }
        }
        let typed = try #require(await run("SELECT cafe\u{301}| FROM cafe", provider))
        #expect(typed.items.first?.label == "café" && typed.items.first?.highlights == [NSRange(location: 0, length: 4)])
    }

    /// Random fragments with quotes, comments and dollars in every dialect: no crash, and the ranges stay sane.
    @Test func randomFragmentsKeepInvariants() async throws {
        let pieces = [
            "SELECT ", "FROM ", "users u", ", ", "orders o", " WHERE ", "u.", "na", "\"", "`", "'", "E'a\\'b'", "$$", "$t$",
            "a$b$", "/*", "*/", "--", "\n", ";", "(", ")", "JOIN ", " ON ", "=", "[x", "]", "#", "\\", "::", "é", "e\u{301}", "İ", "😀",
        ]
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let s = FakeSchemaProvider.schemaS()
        for family in [SQLDialect.Family.mysql, .postgresql, .sqlite, .duckdb, nil] {
            let engine = SQLCompletionEngine(family: family, schema: s)
            for _ in 0..<120 {
                let text = (0..<(1 + next(12))).map { _ in pieces[next(pieces.count)] }.joined()
                let length = (text as NSString).length
                for caret in [length, next(length + 1), next(length + 1)] {
                    if let context = SQLContextAnalyzer.analyze(text: text, caret: caret, family: family) {
                        #expect(NSMaxRange(context.replacementRange) == caret, "\(text) @\(caret)")
                        #expect(context.statementRange.location >= 0 && NSMaxRange(context.statementRange) <= length)
                    }
                    guard let result = await engine.complete(text: text, caret: caret, manual: true, keywordCase: .matchTypedElseUpper) else { continue }
                    #expect(result.items.count <= result.limit)
                    for row in result.pool {
                        #expect(row.highlights.allSatisfy { NSMaxRange($0) <= row.label.utf16.count }, "\(text) \(row.label)")
                    }
                }
            }
        }
    }

    // MARK: Performance

    @Test func largeDocumentAndSchemaStayFast() async throws {
        let provider = FakeSchemaProvider()
        for t in 0..<200 {
            provider.add("table_\(t)", (0..<10).map { ColumnInfo(name: "column_\($0)_\(t % 7)", dataType: "INT", isNullable: $0 != 0, isPrimaryKey: $0 == 0) })
        }
        var lines: [String] = []
        for i in 0..<2000 {
            lines.append(i % 5 == 0 ? "SELECT t.column_1_\(i % 7), 'it''s; fine' FROM table_\(i % 200) t" : "  JOIN table_\((i + 1) % 200) j\(i) ON j\(i).column_0_1 = t.column_0_1 -- note; \(i);")
        }
        let engine = SQLCompletionEngine(family: .postgresql, schema: provider)
        let middle = lines[..<1000].joined(separator: "\n") + "\nSELECT * FROM table_1 a JOIN table_2 b ON a.column_0_1 = b.c"
        let rest = "\n" + lines[1000...].joined(separator: "\n")
        let document = middle + rest
        let caret = (middle as NSString).length
        let probes: [(String, Int)] = [
            (document, caret),
            (lines[..<1000].joined(separator: "\n") + "\nSELECT c", (lines[..<1000].joined(separator: "\n") as NSString).length + 9),
            (lines[..<1000].joined(separator: "\n") + "\nSELECT * FROM ta", (lines[..<1000].joined(separator: "\n") as NSString).length + 17),
        ]
        _ = await engine.complete(text: probes[0].0, caret: probes[0].1, manual: false, keywordCase: .matchTypedElseUpper)
        for (text, position) in probes {
            let clock = ContinuousClock()
            var result: CompletionResult?
            let elapsed = await clock.measure {
                result = await engine.complete(text: text, caret: position, manual: true, keywordCase: .matchTypedElseUpper)
            }
            #expect(result != nil)
            #expect(elapsed < .milliseconds(200), "completion took \(elapsed)")
        }
    }

    @Test func manyCachedColumnsWithoutTablesStayFast() async throws {
        let provider = FakeSchemaProvider()
        for t in 0..<300 {
            provider.add("table_\(t)", (0..<30).map { ColumnInfo(name: "c\($0)_\(t % 11)", dataType: "INT", isNullable: $0 != 0, isPrimaryKey: $0 == 0) })
        }
        let engine = SQLCompletionEngine(family: .mysql, schema: provider)
        for text in ["SELECT ", "SELECT c1"] {
            let caret = (text as NSString).length
            let clock = ContinuousClock()
            var result: CompletionResult?
            let elapsed = await clock.measure {
                result = await engine.complete(text: text, caret: caret, manual: true, keywordCase: .matchTypedElseUpper)
            }
            #expect(result?.items.count == 40 && result?.pool.count == 400)
            #expect(elapsed < .milliseconds(300), "completion took \(elapsed)")
        }
    }
}

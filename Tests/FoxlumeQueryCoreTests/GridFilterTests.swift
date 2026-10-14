import Foundation
import Testing
@testable import FoxlumeQueryCore

/// SQL the filter bar and the sort headers produce, per dialect.
@Suite struct FilterSQLTests {
    private func sql(_ rule: FilterRule, _ dialect: SQLDialect) -> String? { rule.sql(dialect: dialect) }

    @Test func textOperatorsIgnoreCaseByDefault() {
        let rule = FilterRule(column: "name", op: .contains, value: "ab")
        #expect(sql(rule, .postgresql) == "\"name\"::text ILIKE '%ab%'")
        #expect(sql(rule, .mysql) == "CAST(`name` AS CHAR) LIKE '%ab%'")
        #expect(sql(rule, .sqlite) == "CAST(\"name\" AS TEXT) LIKE '%ab%' ESCAPE '\\'")
        #expect(sql(rule, .duckdb) == "CAST(\"name\" AS VARCHAR) ILIKE '%ab%' ESCAPE '\\'")
    }

    @Test func matchCaseSwitchesToCaseSensitiveMatching() {
        let contains = FilterRule(column: "name", op: .contains, value: "Ab", matchCase: true)
        #expect(sql(contains, .postgresql) == "\"name\"::text LIKE '%Ab%'")
        #expect(sql(contains, .mysql) == "CAST(`name` AS CHAR) LIKE '%Ab%' COLLATE utf8mb4_bin")
        #expect(sql(contains, .sqlite) == "CAST(\"name\" AS TEXT) GLOB '*Ab*'")
        #expect(sql(contains, .duckdb) == "CAST(\"name\" AS VARCHAR) LIKE '%Ab%' ESCAPE '\\'")

        let notContains = FilterRule(column: "name", op: .notContains, value: "Ab", matchCase: true)
        #expect(sql(notContains, .postgresql) == "\"name\"::text NOT LIKE '%Ab%'")
        #expect(sql(notContains, .sqlite) == "CAST(\"name\" AS TEXT) NOT GLOB '*Ab*'")

        let starts = FilterRule(column: "name", op: .startsWith, value: "a*?[b", matchCase: true)
        #expect(sql(starts, .sqlite) == "CAST(\"name\" AS TEXT) GLOB 'a[*][?][[]b*'", "GLOB wildcards in the value are literal")
        let ends = FilterRule(column: "name", op: .endsWith, value: "50%_", matchCase: true)
        #expect(sql(ends, .mysql) == "CAST(`name` AS CHAR) LIKE '%50\\\\%\\\\_' COLLATE utf8mb4_bin")
        #expect(sql(ends, .postgresql) == "\"name\"::text LIKE '%50\\%\\_'")
    }

    @Test func matchCaseDoesNotChangeEquality() {
        let rule = FilterRule(column: "name", op: .equals, value: "Ab", matchCase: true)
        #expect(sql(rule, .postgresql) == "\"name\" = 'Ab'")
        #expect(sql(rule, .mysql) == "`name` = 'Ab'")
    }

    @Test func regexPerEngine() {
        let rule = FilterRule(column: "code", op: .regex, value: "^A\\d+$")
        #expect(sql(rule, .postgresql) == "\"code\"::text ~* '^A\\d+$'")
        #expect(sql(rule, .mysql) == "CAST(`code` AS CHAR) REGEXP '^A\\\\d+$'", "MySQL string literals escape the backslash")
        #expect(sql(rule, .sqlite) == "CAST(\"code\" AS TEXT) REGEXP '(?i)^A\\d+$'")
        #expect(sql(rule, .duckdb) == "regexp_matches(CAST(\"code\" AS VARCHAR), '^A\\d+$', 'i')")

        var exact = rule
        exact.matchCase = true
        #expect(sql(exact, .postgresql) == "\"code\"::text ~ '^A\\d+$'")
        #expect(sql(exact, .mysql) == "CAST(`code` AS CHAR) COLLATE utf8mb4_bin REGEXP '^A\\\\d+$'")
        #expect(sql(exact, .sqlite) == "CAST(\"code\" AS TEXT) REGEXP '^A\\d+$'")
        #expect(sql(exact, .duckdb) == "regexp_matches(CAST(\"code\" AS VARCHAR), '^A\\d+$')")

        #expect(sql(FilterRule(column: "code", op: .regex, value: ""), .postgresql) == nil, "an empty pattern is not applied")
    }

    @Test func betweenNeedsBothBoundsAndQuotesThem() {
        let rule = FilterRule(column: "total", op: .between, value: "10", secondValue: "20")
        #expect(sql(rule, .postgresql) == "\"total\" BETWEEN '10' AND '20'")
        #expect(sql(rule, .mysql) == "`total` BETWEEN '10' AND '20'")
        var not = rule
        not.op = .notBetween
        #expect(sql(not, .sqlite) == "\"total\" NOT BETWEEN '10' AND '20'")
        #expect(sql(FilterRule(column: "total", op: .between, value: "10"), .postgresql) == nil)

        let quoted = FilterRule(column: "name", op: .between, value: "O'Brien", secondValue: "x\\'; DROP TABLE t; --")
        #expect(sql(quoted, .postgresql) == "\"name\" BETWEEN 'O''Brien' AND 'x\\''; DROP TABLE t; --'")
        #expect(sql(quoted, .mysql) == "`name` BETWEEN 'O''Brien' AND 'x\\\\''; DROP TABLE t; --'")
    }

    @Test func emptyAndNotEmpty() {
        #expect(sql(FilterRule(column: "note", op: .isEmpty), .postgresql) == "(\"note\" IS NULL OR \"note\"::text = '')")
        #expect(sql(FilterRule(column: "note", op: .isNotEmpty), .mysql) == "(`note` IS NOT NULL AND CAST(`note` AS CHAR) <> '')")
        #expect(!FilterOperator.isEmpty.needsValue)
    }

    @Test func listsPullNullOut() {
        #expect(sql(FilterRule(column: "id", op: .notInList, value: "1, 2"), .postgresql) == "\"id\" NOT IN ('1', '2')")
        #expect(sql(FilterRule(column: "id", op: .inList, value: "1, null"), .postgresql) == "(\"id\" IN ('1') OR \"id\" IS NULL)")
        #expect(sql(FilterRule(column: "id", op: .notInList, value: "NULL,3"), .mysql) == "(`id` NOT IN ('3') AND `id` IS NOT NULL)")
        #expect(sql(FilterRule(column: "id", op: .inList, value: "NULL"), .sqlite) == "\"id\" IS NULL")
        #expect(sql(FilterRule(column: "id", op: .inList, value: " , "), .sqlite) == nil)
    }

    @Test func rulesCombineWithOrAndRawWhereStaysAnded() {
        var query = TableQuery(table: TableRef(name: "t"), pageSize: 10)
        query.filters = [FilterRule(column: "a", value: "1"), FilterRule(column: "b", value: "2")]
        query.filterLogic = .or
        query.rawWhere = "c > 1"
        #expect(query.selectSQL(dialect: .postgresql) == "SELECT * FROM \"t\" WHERE (\"a\" = '1' OR \"b\" = '2') AND (c > 1) LIMIT 10")
        query.filters[1].isEnabled = false
        #expect(query.whereClause(dialect: .postgresql) == "\"a\" = '1' AND (c > 1)", "one rule needs no parentheses")
        query.filterLogic = .and
        query.filters[1].isEnabled = true
        #expect(query.countSQL(dialect: .mysql) == "SELECT COUNT(*) FROM `t` WHERE `a` = '1' AND `b` = '2' AND (c > 1)")
    }

    @Test func orderByEveryKeyInOrder() {
        let query = TableQuery(table: TableRef(schema: "public", name: "t"), sort: [SortKey(column: "a", ascending: true), SortKey(column: "b", ascending: false), SortKey(column: "c\"d", ascending: true)], pageSize: 5)
        #expect(query.selectSQL(dialect: .postgresql) == "SELECT * FROM \"public\".\"t\" ORDER BY \"a\" ASC, \"b\" DESC, \"c\"\"d\" ASC LIMIT 5")
        let mysql = TableQuery(table: TableRef(name: "t"), sort: [SortKey(column: "x`y", ascending: false), SortKey(column: "id", ascending: true)], pageSize: 5)
        #expect(mysql.selectSQL(dialect: .mysql) == "SELECT * FROM `t` ORDER BY `x``y` DESC, `id` ASC LIMIT 5")
    }

    @Test func rulesSavedBeforeTheNewFieldsStillDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","column":"name","op":"contains","value":"x","isEnabled":true}"#
        let rule = try JSONDecoder().decode(FilterRule.self, from: Data(json.utf8))
        #expect(rule.column == "name" && rule.op == .contains && rule.value == "x")
        #expect(rule.secondValue == "" && rule.matchCase == false)
        let copy = try JSONDecoder().decode(FilterRule.self, from: JSONEncoder().encode(FilterRule(column: "n", op: .between, value: "1", secondValue: "2", matchCase: true)))
        #expect(copy.secondValue == "2" && copy.matchCase)
    }

    @Test func operatorMenuListsEveryOperatorOnce() {
        #expect(Set(FilterOperator.menuOrder) == Set(FilterOperator.allCases))
        #expect(FilterOperator.menuOrder.count == FilterOperator.allCases.count)
        #expect(FilterOperator.between.needsSecondValue && FilterOperator.notBetween.needsSecondValue && !FilterOperator.equals.needsSecondValue)
        #expect(FilterOperator.allCases.filter(\.supportsMatchCase) == [.contains, .notContains, .startsWith, .endsWith, .regex])
    }
}

@Suite struct MongoAdvancedFilterTests {
    private func condition(_ rule: FilterRule, type: String? = nil) -> BSONDocument? {
        MongoFilterBuilder.condition(for: rule, typeName: type)
    }

    @Test func regexAndMatchCase() {
        #expect(condition(FilterRule(column: "name", op: .regex, value: "^a.c")) == ["name": .regex(pattern: "^a.c", options: "i")])
        #expect(condition(FilterRule(column: "name", op: .regex, value: "^a", matchCase: true)) == ["name": .regex(pattern: "^a", options: "")])
        #expect(condition(FilterRule(column: "name", op: .contains, value: "a.b", matchCase: true)) == ["name": .regex(pattern: "a\\.b", options: "")])
    }

    @Test func rangesListsAndEmptiness() {
        #expect(condition(FilterRule(column: "n", op: .between, value: "1", secondValue: "5"), type: "INTEGER") == ["n": .document(["$gte": .int32(1), "$lte": .int32(5)])])
        #expect(condition(FilterRule(column: "n", op: .notBetween, value: "1", secondValue: "5"), type: "INTEGER")
            == ["$or": .array([.document(["n": .document(["$lt": .int32(1)])]), .document(["n": .document(["$gt": .int32(5)])])])])
        #expect(condition(FilterRule(column: "s", op: .notInList, value: "a, NULL"), type: "VARCHAR") == ["s": .document(["$nin": .array([.string("a"), .null])])])
        #expect(condition(FilterRule(column: "s", op: .isEmpty)) == ["s": .document(["$in": .array([.null, .string("")])])])
        #expect(condition(FilterRule(column: "s", op: .isNotEmpty)) == ["s": .document(["$nin": .array([.null, .string("")])])])
    }

    @Test func anyRuleMatchesWithOr() {
        let rules = [FilterRule(column: "a", value: "x"), FilterRule(column: "b", value: "y")]
        let filter = MongoFilterBuilder.filter(rules: rules, logic: .or, fieldTypes: ["a": "VARCHAR", "b": "VARCHAR"], raw: ["c": .int32(1)])
        #expect(filter == ["$and": .array([
            .document(["$or": .array([.document(["a": .document(["$eq": .string("x")])]), .document(["b": .document(["$eq": .string("y")])])])]),
            .document(["c": .int32(1)]),
        ])])
    }
}

/// The new operators against real engines that need no server.
@Suite struct EmbeddedFilterTests {
    private func names(_ session: DatabaseSession, _ table: String, _ rule: FilterRule, dialect: SQLDialect) async throws -> [String] {
        let query = TableQuery(table: TableRef(name: table), filters: [rule], sort: [SortKey(column: "name", ascending: true)], pageSize: 100)
        return try await session.execute(query.selectSQL(dialect: dialect))[0].rows.compactMap { $0[0].textValue }
    }

    @Test func sqliteRegexAndGlob() async throws {
        let url = TestFiles.url("fq-grid-\(UUID().uuidString).sqlite")
        defer { TestFiles.removeDatabase(url) }
        let session = DatabaseSession(parameters: ConnectionParameters(config: ConnectionConfig(kind: .sqlite, filePath: url.path), password: ""))
        try await session.connect()
        _ = try await session.execute("CREATE TABLE p (name TEXT, n INTEGER); INSERT INTO p VALUES ('Alpha', 1), ('alpine', 2), ('Beta*', 3), ('gamma', NULL)")
        #expect(try await names(session, "p", FilterRule(column: "name", op: .regex, value: "^al"), dialect: .sqlite) == ["Alpha", "alpine"])
        #expect(try await names(session, "p", FilterRule(column: "name", op: .regex, value: "^al", matchCase: true), dialect: .sqlite) == ["alpine"])
        #expect(try await names(session, "p", FilterRule(column: "name", op: .contains, value: "AL"), dialect: .sqlite) == ["Alpha", "alpine"])
        #expect(try await names(session, "p", FilterRule(column: "name", op: .contains, value: "Al", matchCase: true), dialect: .sqlite) == ["Alpha"])
        #expect(try await names(session, "p", FilterRule(column: "name", op: .endsWith, value: "a*", matchCase: true), dialect: .sqlite) == ["Beta*"])
        #expect(try await names(session, "p", FilterRule(column: "n", op: .between, value: "2", secondValue: "3"), dialect: .sqlite) == ["Beta*", "alpine"])
        await #expect(throws: (any Error).self) {
            _ = try await names(session, "p", FilterRule(column: "name", op: .regex, value: "(unclosed"), dialect: .sqlite)
        }
        await session.close()
    }

    @Test func duckdbRegexAndLikeEscapes() async throws {
        let session = try await DuckDBTests.open()
        _ = try await session.execute("CREATE TABLE p (name VARCHAR); INSERT INTO p VALUES ('Alpha'), ('alpine'), ('50%_off'), ('500 off')")
        #expect(try await names(session, "p", FilterRule(column: "name", op: .regex, value: "^AL"), dialect: .duckdb) == ["Alpha", "alpine"])
        #expect(try await names(session, "p", FilterRule(column: "name", op: .regex, value: "^Al", matchCase: true), dialect: .duckdb) == ["Alpha"])
        #expect(try await names(session, "p", FilterRule(column: "name", op: .contains, value: "%_"), dialect: .duckdb) == ["50%_off"], "LIKE wildcards in the value are literal")
        await session.close()
    }
}

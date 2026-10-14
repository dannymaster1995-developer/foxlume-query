import Foundation
import Testing
@testable import FoxlumeQueryCore

/// Matching (spec 4.3), ranking (4.4) and keyword casing (5.3).
@Suite struct CompletionMatcherTests {
    @Test func prefixSubstringAndFuzzy() throws {
        let prefix = try #require(CompletionMatcher.match(filterText: "select", prefix: "SEL"))
        #expect(prefix.kind == .prefix && prefix.penalty == 0 && prefix.ranges == [NSRange(location: 0, length: 3)])
        let substring = try #require(CompletionMatcher.match(filterText: "select", prefix: "ele"))
        #expect(substring.kind == .substring && substring.ranges == [NSRange(location: 1, length: 3)])
        let fuzzy = try #require(CompletionMatcher.match(filterText: "select", prefix: "slc"))
        #expect(fuzzy.kind == .fuzzy)
        #expect(fuzzy.ranges == [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1), NSRange(location: 4, length: 1)])
        #expect(CompletionMatcher.match(filterText: "select", prefix: "slct") != nil)
        #expect(CompletionMatcher.match(filterText: "select", prefix: "tces") == nil)
        #expect(CompletionMatcher.match(filterText: "users_table", prefix: "usr") != nil)
        #expect(CompletionMatcher.match(filterText: "select", prefix: "zzz") == nil)
        let empty = try #require(CompletionMatcher.match(filterText: "select", prefix: ""))
        #expect(empty.ranges.isEmpty)
    }

    @Test func fuzzyPenaltyFormula() throws {
        // slc in select: gaps e,e = 2, longest run 1 → 50 + 20 − 15.
        #expect(try #require(CompletionMatcher.match(filterText: "select", prefix: "slc")).penalty == 55)
        // usr in users_table: u,s consecutive (run 2), gap e → 50 + 10 − 30.
        #expect(try #require(CompletionMatcher.match(filterText: "users_table", prefix: "usr")).penalty == 30)
        // Long runs bring the penalty to zero, never below.
        #expect(try #require(CompletionMatcher.match(filterText: "created_at_x", prefix: "createdat")).penalty == 0)
    }

    @Test func highlightsMapOntoQuotedLabels() {
        #expect(CompletionMatcher.highlights(label: "'active'", filterText: "active", ranges: [NSRange(location: 0, length: 1)]) == [NSRange(location: 1, length: 1)])
        #expect(CompletionMatcher.highlights(label: "SELECT", filterText: "select", ranges: [NSRange(location: 1, length: 3)]) == [NSRange(location: 1, length: 3)])
    }

    @Test func matchingComparesUTF16UnitsSoHighlightsFitTheLabel() throws {
        // Typed decomposed (e + U+0301), stored composed: a prefix match whose range covers the 4-unit label.
        let composed = try #require(CompletionMatcher.match(filterText: "café", prefix: "cafe\u{301}"))
        #expect(composed.kind == .prefix && composed.isExact && composed.ranges == [NSRange(location: 0, length: 4)])
        // Stored decomposed: still a prefix match, without a highlight that would not line up.
        let decomposed = try #require(CompletionMatcher.match(filterText: "cafe\u{301}", prefix: "café"))
        #expect(decomposed.kind == .prefix && decomposed.ranges.isEmpty)
        #expect(CompletionMatcher.match(filterText: "cafe", prefix: "café") == nil)
        // Lowercasing that changes the length (İ → i + U+0307) drops the highlight instead of overrunning the label.
        #expect(CompletionMatcher.highlights(label: "İd", filterText: "İd".lowercased(), ranges: [NSRange(location: 0, length: 3)]).isEmpty)
        #expect(CompletionMatcher.highlights(label: "ab", filterText: "ab", ranges: [NSRange(location: 1, length: 5)]).isEmpty)
    }

    @Test func rankedHighlightsStayInsideLabels() {
        let items = [CompletionItem(label: "café", kind: .column), CompletionItem(label: "cafe\u{301}s", kind: .column)]
        let ranked = SQLCompletionRanking.rank(items, prefix: "cafe\u{301}", state: CompletionRefilterState(context: SQLClause.selectList.rawValue))
        #expect(ranked.map(\.label) == ["café", "cafe\u{301}s"])
        for item in ranked {
            #expect(item.highlights.allSatisfy { NSMaxRange($0) <= item.label.utf16.count })
        }
        #expect(ranked[0].highlights == [NSRange(location: 0, length: 4)])
    }

    // MARK: Ranking

    func rank(_ items: [CompletionItem], _ prefix: String, clause: SQLClause = .unknown, tables: Bool = false, comma: Bool = false, expects: Bool = false) -> [String] {
        let state = CompletionRefilterState(context: clause.rawValue, hasTablesInScope: tables, isAfterComma: comma, expectsObjectName: expects)
        return SQLCompletionRanking.rank(items, prefix: prefix, state: state).map(\.label)
    }

    @Test func workedExampleTrueVersusTruncate() {
        let items = [
            CompletionItem(label: "TRUNCATE", kind: .function, insertText: "TRUNCATE()", followsKeywordCase: true),
            CompletionItem(label: "TRUE", kind: .keyword, followsKeywordCase: true),
        ]
        #expect(rank(items, "t") == ["TRUNCATE", "TRUE"])
        #expect(rank(items, "true").first == "TRUE")
        #expect(rank(items, "tru") == ["TRUNCATE", "TRUE"])
    }

    @Test func exactMatchWinsAndShorterLabelsLead() {
        let items = ["INSTR", "INTERSECT", "IN"].map { CompletionItem(label: $0, kind: .keyword) }
        #expect(rank(items, "in").first == "IN")
        let names = ["created_at", "id", "name"].map { CompletionItem(label: $0, kind: .column) }
        #expect(rank(names, "") == ["id", "name", "created_at"])
    }

    @Test func tiesKeepGenerationOrder() {
        let items = ["USING", "WHERE", "LIMIT", "UNION"].map { CompletionItem(label: $0, kind: .keyword) }
        #expect(rank(items, "") == ["USING", "WHERE", "LIMIT", "UNION"])
    }

    @Test func contextAdjustments() {
        let items = [
            CompletionItem(label: "ON", kind: .keyword),
            CompletionItem(label: "users", kind: .table),
        ]
        // Empty prefix with a table in scope: keywords surface, unless a table name is expected.
        #expect(rank(items, "", clause: .from, tables: true) == ["ON", "users"])
        #expect(rank(items, "", clause: .from, tables: true, expects: true) == ["users", "ON"])
        // Typing in FROM favors tables.
        let typed = [CompletionItem(label: "user_id", kind: .keyword), CompletionItem(label: "users", kind: .table)]
        #expect(rank(typed, "us", clause: .from, tables: true) == ["users", "user_id"])
        // SET and INSERT column lists favor columns even more than WHERE does.
        let set = [CompletionItem(label: "WHERE", kind: .keyword), CompletionItem(label: "weight", kind: .column)]
        #expect(rank(set, "w", clause: .set) == ["weight", "WHERE"])
    }

    @Test func duplicatesKeepTheBetterScore() throws {
        let items = [
            CompletionItem(label: "u.id", kind: .column, detail: "PK, INT"),
            CompletionItem(label: "u.id", kind: .column, documentation: "Column from users", priority: 80),
            CompletionItem(label: "=", kind: .operator),
            CompletionItem(label: "=", kind: .operator, detail: "any"),
        ]
        let state = CompletionRefilterState(context: SQLClause.on.rawValue)
        let ranked = SQLCompletionRanking.rank(items, prefix: "", state: state)
        #expect(ranked.map(\.label) == ["u.id", "="])
        let column = try #require(ranked.first)
        #expect(column.priority == 80 && column.detail == "PK, INT" && column.documentation == "Column from users")
        #expect(ranked[1].detail == "any")
    }

    @Test func favoritesNeedAPrefixMatchAlsoWhenRefiltering() {
        let favorite = CompletionItem(label: "report", kind: .favorite, insertText: "SELECT * FROM reports", priority: 50)
        let keyword = CompletionItem(label: "REPEAT", kind: .keyword)
        #expect(rank([favorite, keyword], "rep") == ["report", "REPEAT"])
        #expect(rank([favorite, keyword], "rept") == ["REPEAT"])
        #expect(rank([favorite], "") == ["report"])
    }

    @Test func rankKeepsOnlyTheRequestedRows() {
        let items = (0..<50).map { CompletionItem(label: "c\($0)", kind: .column) }
        let ranked = SQLCompletionRanking.rank(items, prefix: "c", state: CompletionRefilterState(), keep: 5)
        #expect(ranked.map(\.label) == ["c0", "c1", "c2", "c3", "c4"])
        #expect(ranked.allSatisfy { $0.highlights == [NSRange(location: 0, length: 1)] })
    }

    // MARK: Casing

    func cased(_ label: String, _ prefix: String, _ policy: KeywordCase = .matchTypedElseUpper) -> String {
        let item = CompletionItem(label: label, kind: .keyword, followsKeywordCase: true)
        return KeywordCasing.apply(items: [item], prefix: prefix, policy: policy)[0].label
    }

    @Test func matchTypedCasing() {
        #expect(cased("SELECT", "s") == "select")
        #expect(cased("SELECT", "S") == "SELECT")
        #expect(cased("SELECT", "Sel") == "SELECT")
        #expect(cased("SELECT", "sElE") == "select")
        #expect(cased("SELECT", "_sel") == "select")
        #expect(cased("SELECT", "1SEL") == "SELECT")
        #expect(cased("SELECT", "") == "SELECT")
        #expect(cased("SELECT", "名") == "SELECT")
        #expect(cased("SELECT", "", .matchTypedElseLower) == "select")
        #expect(cased("GROUP BY", "b") == "group by")
        #expect(cased("IS NOT NULL", "N") == "IS NOT NULL")
    }

    @Test func absolutePolicies() {
        #expect(cased("SELECT", "sel", .upper) == "SELECT")
        #expect(cased("SELECT", "SEL", .lower) == "select")
    }

    @Test func casingKeepsInsertTextInStepAndSkipsFixedItems() {
        let function = CompletionItem(label: "COUNT", kind: .function, insertText: "COUNT()", caretOffsetFromEnd: 1, followsKeywordCase: true)
        let fixed = CompletionItem(label: "toString", kind: .function, insertText: "toString()", caretOffsetFromEnd: 1)
        let column = CompletionItem(label: "UserName", kind: .column)
        let result = KeywordCasing.apply(items: [function, fixed, column], prefix: "cou", policy: .matchTypedElseUpper)
        #expect(result[0].label == "count" && result[0].insertText == "count()")
        #expect(result[1].insertText == "toString()")
        let upper = KeywordCasing.apply(items: [fixed], prefix: "TOS", policy: .matchTypedElseUpper)
        #expect(upper[0].insertText == "toString()")
        #expect(result[2].label == "UserName")
    }

    @Test func casingIsLocaleIndependent() {
        // Turkish rules would turn i into İ; the root locale keeps ASCII I.
        #expect(cased("LIMIT", "li") == "limit")
        #expect(cased("limit", "LI") == "LIMIT")
        #expect(cased("INSERT", "i") == "insert")
    }
}

import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct SortCycleTests {
    private let id = SortKey(column: "id", ascending: true)

    @Test func plainClickCyclesOneColumn() {
        let first = SortCycle.next([], clicking: "name", additive: false)
        #expect(first == [SortKey(column: "name", ascending: true)])
        let second = SortCycle.next(first, clicking: "name", additive: false)
        #expect(second == [SortKey(column: "name", ascending: false)])
        #expect(SortCycle.next(second, clicking: "name", additive: false) == [])
    }

    @Test func plainClickReplacesSecondaryKeys() {
        let sort = [id, SortKey(column: "name", ascending: false)]
        #expect(SortCycle.next(sort, clicking: "name", additive: false) == [SortKey(column: "name", ascending: true)], "a secondary key is not the primary")
        #expect(SortCycle.next(sort, clicking: "id", additive: false) == [SortKey(column: "id", ascending: false)])
    }

    @Test func shiftClickAddsFlipsAndRemoves() {
        let added = SortCycle.next([id], clicking: "name", additive: true)
        #expect(added == [id, SortKey(column: "name", ascending: true)])
        let flipped = SortCycle.next(added, clicking: "name", additive: true)
        #expect(flipped == [id, SortKey(column: "name", ascending: false)])
        #expect(SortCycle.next(flipped, clicking: "name", additive: true) == [id])
        #expect(SortCycle.next(flipped, clicking: "id", additive: true) == [SortKey(column: "id", ascending: false), SortKey(column: "name", ascending: false)], "flipping keeps its place")
        #expect(SortCycle.next([], clicking: "a", additive: true) == [SortKey(column: "a", ascending: true)])
    }
}

@Suite struct LocalRowSortTests {
    private let rows: [[CellValue]] = [
        [.text("b"), .text("10")],
        [.text("a"), .text("9")],
        [.text("b"), .text("2")],
        [.null, .text("1")],
        [.text("a"), .null],
    ]

    @Test func sortsBySeveralKeysAndKeepsTiesInOrder() {
        let order = LocalRowSort.order(rows, by: [.init(column: 0, ascending: true, numeric: false), .init(column: 1, ascending: false, numeric: true)])
        #expect(order == [3, 1, 4, 0, 2], "NULL first; within a, 9 before NULL descending; within b, 10 before 2 numerically")
        #expect(LocalRowSort.order(rows, by: [.init(column: 0, ascending: true, numeric: false)]) == [3, 1, 4, 0, 2])
        #expect(LocalRowSort.order(rows, by: []) == [0, 1, 2, 3, 4])
    }

    @Test func numbersCompareByValueOnlyInNumericColumns() {
        let order = LocalRowSort.order(rows, by: [.init(column: 1, ascending: true, numeric: true)])
        #expect(order == [4, 3, 2, 1, 0])
        #expect(LocalRowSort.compare(.text("10"), .text("9"), numeric: false) == .orderedDescending, "natural text order also puts 9 before 10")
    }
}

@Suite struct GridPasteParserTests {
    @Test func tabSeparatedWithQuotedFields() {
        let text = "1\tAlice\t\"multi\nline\"\r\n2\t\"say \"\"hi\"\"\"\t\r\n"
        #expect(GridPasteParser.detectFormat(text) == .tsv)
        #expect(GridPasteParser.parse(text) == [["1", "Alice", "multi\nline"], ["2", "say \"hi\"", ""]])
    }

    @Test func csvOnlyWhenEveryLineHasTheSameFields() {
        let csv = "id,name\n1,\"Smith, John\"\n2,Bob"
        #expect(GridPasteParser.detectFormat(csv) == .csv)
        #expect(GridPasteParser.parse(csv) == [["id", "name"], ["1", "Smith, John"], ["2", "Bob"]])
        #expect(GridPasteParser.detectFormat("Smith, John") == .lines, "one line with a comma is one value")
        #expect(GridPasteParser.parse("Smith, John") == [["Smith, John"]])
        #expect(GridPasteParser.detectFormat("a,b\nc") == .lines)
        #expect(GridPasteParser.parse("a,b\nc\n") == [["a,b"], ["c"]])
    }

    @Test func linesKeepQuotesAndEmptyLines() {
        #expect(GridPasteParser.parse("\"x\"\n\ny") == [["\"x\""], [""], ["y"]])
        #expect(GridPasteParser.parse("") == [])
        #expect(GridPasteParser.parse("only") == [["only"]])
    }
}

@Suite struct GridPastePlanTests {
    private let names = ["id", "name", "note"]

    @Test func partialBlockFillsFromTheAnchor() throws {
        let plan = try GridPastePlan.make(block: [["a", "b"], ["c", "d"]], anchor: (1, 1), rowCount: 5, columnNames: names).get()
        #expect(plan.cells == [.init(row: 1, column: 1, text: "a"), .init(row: 1, column: 2, text: "b"), .init(row: 2, column: 1, text: "c"), .init(row: 2, column: 2, text: "d")])
        #expect(plan.newRows.isEmpty && plan.droppedRows == 0 && plan.droppedColumns == 0)
    }

    @Test func blockIsClippedAtTheLastRowAndColumn() throws {
        let plan = try GridPastePlan.make(block: [["a", "b"], ["c", "d"], ["e", "f"]], anchor: (3, 2), rowCount: 4, columnNames: names).get()
        #expect(plan.cells == [.init(row: 3, column: 2, text: "a")])
        #expect(plan.droppedRows == 2)
        #expect(plan.droppedColumns == 1)
    }

    @Test func singleValueGoesIntoTheAnchorEvenInAOneColumnTable() throws {
        let plan = try GridPastePlan.make(block: [["x"]], anchor: (0, 0), rowCount: 1, columnNames: ["only"]).get()
        #expect(plan.cells == [.init(row: 0, column: 0, text: "x")])
        #expect(plan.newRows.isEmpty)
    }

    @Test func fullWidthBlockBecomesNewRowsWithoutTheHeader() throws {
        let plan = try GridPastePlan.make(block: [names, ["1", "a", "NULL"], ["2", "b", ""]], anchor: nil, rowCount: 3, columnNames: names).get()
        #expect(plan.newRows == [["1", "a", "NULL"], ["2", "b", ""]])
        #expect(plan.cells.isEmpty)
    }

    @Test func failures() {
        #expect(GridPastePlan.make(block: [["a", "b"]], anchor: nil, rowCount: 3, columnNames: names) == .failure(.noAnchor))
        #expect(GridPastePlan.make(block: [], anchor: (0, 0), rowCount: 3, columnNames: names) == .failure(.empty))
        #expect(GridPastePlan.make(block: [names], anchor: (0, 0), rowCount: 3, columnNames: names) == .failure(.empty), "a header alone adds nothing")
        #expect(GridPastePlan.make(block: [["a"]], anchor: (5, 0), rowCount: 3, columnNames: names) == .failure(.noAnchor))
    }

    @Test func nullWord() {
        #expect(GridPastePlan.value(for: "NULL") == .null)
        #expect(GridPastePlan.value(for: "null") == .text("null"))
        #expect(GridPastePlan.value(for: "") == .text(""))
    }
}

@Suite struct SelectionStatisticsTests {
    @Test func numbersInNumericColumnsOnly() {
        let stats = SelectionStatistics([
            (.text("1.5"), true), (.text("2"), true), (.null, true), (.text("abc"), true), (.text("10"), false), (.text("-0.5"), true),
        ])
        #expect(stats.cellCount == 6)
        #expect(stats.valueCount == 5)
        #expect(stats.numberCount == 3)
        #expect(stats.sum == Decimal(3))
        #expect(stats.minimum == Decimal(string: "-0.5"))
        #expect(stats.maximum == Decimal(2))
        #expect(stats.average == Decimal(1))
        #expect(stats.summary == "Count 5 · Sum 3 · Average 1 · Min -0.5 · Max 2")
    }

    @Test func exactDecimalsAndRoundedAverage() {
        let stats = SelectionSummaryFixtures.values(["0.1", "0.2", "0.4"])
        #expect(SelectionStatistics.format(stats.sum ?? 0) == "0.7")
        #expect(stats.summary == "Count 3 · Sum 0.7 · Average 0.233333 · Min 0.1 · Max 0.4")
        #expect(SelectionSummaryFixtures.values(["1e3", "2"]).sum == Decimal(1002))
    }

    @Test func countOnlyWithoutNumbers() {
        let stats = SelectionStatistics([(.text("a"), false), (.missing, false), (.text("b"), false)])
        #expect(stats.summary == "Count 2")
        #expect(stats.average == nil)
        #expect(SelectionStatistics().summary == "Count 0")
    }
}

private enum SelectionSummaryFixtures {
    static func values(_ texts: [String]) -> SelectionStatistics {
        SelectionStatistics(texts.map { (CellValue.text($0), true) })
    }
}

@Suite struct FilterPresetStoreTests {
    private func makeStore() -> (FilterPresetStore, URL) {
        let directory = TestFiles.url("fq-presets-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("filter-presets.json")
        return (FilterPresetStore(url: url), url)
    }

    private let orders = FilterPresetScope(connectionID: UUID(), database: "shop", schema: "public", table: "orders")

    @Test func savesAppliesAndDeletesPerTable() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rules = [FilterRule(column: "total", op: .between, value: "10", secondValue: "20"), FilterRule(column: "note", op: .regex, value: "^x", matchCase: true)]
        let saved = try store.save(name: " Big orders ", rules: rules, logic: .or, rawWhere: "id > 3", for: orders)
        #expect(saved.name == "Big orders")
        let again = try store.save(name: "Big orders", rules: [], logic: .and, rawWhere: "", for: orders)
        #expect(again.name == "Big orders (2)")
        var other = orders
        other.table = "customers"
        try store.save(name: "Big orders", rules: [], logic: .and, rawWhere: "", for: other)

        let reloaded = FilterPresetStore(url: url)
        let presets = reloaded.presets(for: orders)
        #expect(presets.map(\.name) == ["Big orders", "Big orders (2)"])
        #expect(presets[0].rules == rules)
        #expect(presets[0].logic == .or && presets[0].rawWhere == "id > 3")
        #expect(reloaded.presets(for: other).count == 1)

        try reloaded.delete(id: saved.id, for: orders)
        #expect(FilterPresetStore(url: url).presets(for: orders).map(\.name) == ["Big orders (2)"])
        #expect(throws: FilterPresetError.emptyName) { try store.save(name: "  ", rules: [], logic: .and, rawWhere: "", for: orders) }
    }

    @Test func damagedFileIsSetAsideAndReadablePresetsSurvive() throws {
        let (_, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let scope = #"{"connectionID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","database":"shop","table":"orders"}"#
        let text = #"{"version":1,"tables":[{"scope":\#(scope),"presets":[{"name":"good","rules":[]},{"rules":"broken"}]},{"scope":7,"presets":[]}]}"#
        try Data(text.utf8).write(to: url)
        let store = FilterPresetStore(url: url)
        let id = try #require(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        let presets = store.presets(for: FilterPresetScope(connectionID: id, database: "shop", schema: nil, table: "orders"))
        #expect(presets.map(\.name) == ["good"])
        let aside = try #require(store.setAsideFile)
        #expect(FileManager.default.fileExists(atPath: aside.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // Text that is not JSON at all keeps nothing, but is still moved aside rather than overwritten.
        let other = url.deletingLastPathComponent().appendingPathComponent("other.json")
        try Data("not json".utf8).write(to: other)
        let garbage = FilterPresetStore(url: other)
        #expect(garbage.presets(for: orders).isEmpty)
        #expect(garbage.setAsideFile != nil)
        try garbage.save(name: "fresh", rules: [], logic: .and, rawWhere: "", for: orders)
        #expect(FilterPresetStore(url: other).presets(for: orders).map(\.name) == ["fresh"])
    }

    @Test func missingColumnsAreReported() {
        let preset = FilterPreset(name: "p", rules: [FilterRule(column: "a"), FilterRule(column: "gone"), FilterRule(column: "gone")])
        #expect(preset.missingColumns(in: ["a", "b"]) == ["gone"])
    }
}

@Suite struct CellFilterSuggestionTests {
    @Test func conditionsFollowTheValue() {
        #expect(CellFilterSuggestions.rules(column: "c", value: .null, ordered: true).map(\.op) == [.isNull, .isNotNull])
        #expect(CellFilterSuggestions.rules(column: "c", value: .text(""), ordered: false).map(\.op) == [.isEmpty, .isNotEmpty])
        #expect(CellFilterSuggestions.rules(column: "c", value: .text("7"), ordered: true).map(\.op) == [.equals, .notEquals, .greaterThan, .lessThan])
        let text = CellFilterSuggestions.rules(column: "c", value: .text("paid"), ordered: false)
        #expect(text.map(\.op) == [.equals, .notEquals, .contains])
        #expect(text.map(\.summary) == ["c = paid", "c ≠ paid", "c contains paid"])
        #expect(CellFilterSuggestions.rules(column: "c", value: .text(" padded"), ordered: false).isEmpty, "a filter would not find the row again")
        #expect(CellFilterSuggestions.rules(column: "c", value: .bytes(Data([1])), ordered: false).isEmpty)
    }

    @Test func orderedColumnsAndSummaries() {
        #expect(CellFilterSuggestions.isOrdered(ResultColumn(name: "n", typeName: "int4", isNumeric: true)))
        #expect(CellFilterSuggestions.isOrdered(ResultColumn(name: "d", typeName: "timestamptz")))
        #expect(!CellFilterSuggestions.isOrdered(ResultColumn(name: "s", typeName: "text")))
        #expect(FilterRule(column: "t", op: .between, value: "1", secondValue: "9").summary == "t between 1 and 9")
        #expect(FilterRule(column: "t", op: .regex, value: "^a", matchCase: true).summary == "t matches regex ^a (match case)")
        #expect(FilterRule(column: "t", op: .isNotEmpty).summary == "t is not empty")
    }
}

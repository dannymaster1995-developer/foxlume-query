import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct GridColumnLayoutTests {
    private typealias Column = GridColumnLayout.Column
    private typealias Placement = GridColumnLayout.Placement

    @Test func arrangeKeepsSavedOrderWidthsAndHiddenColumns() {
        let layout = GridColumnLayout(columns: [
            Column(name: "total", width: 120),
            Column(name: "id", width: 50),
            Column(name: "status", isHidden: true),
        ])
        #expect(layout.arrange(["id", "status", "total"]) == [
            Placement(index: 2, width: 120),
            Placement(index: 0, width: 50),
            Placement(index: 1, isHidden: true),
        ])
    }

    @Test func removedColumnsAreIgnoredAndNewOnesFollowVisible() {
        let layout = GridColumnLayout(columns: [
            Column(name: "notes", width: 300, isHidden: true),
            Column(name: "total", width: 80),
            Column(name: "gone", width: 90),
            Column(name: "id", width: 40),
        ])
        // "gone" was dropped from the table; "created_at" and "currency" were added.
        #expect(layout.arrange(["id", "created_at", "total", "notes", "currency"]) == [
            Placement(index: 3, width: 300, isHidden: true),
            Placement(index: 2, width: 80),
            Placement(index: 0, width: 40),
            Placement(index: 1),
            Placement(index: 4),
        ])
    }

    @Test func nothingHiddenWhenEveryRemainingColumnWouldBe() {
        let layout = GridColumnLayout(columns: [Column(name: "a", isHidden: true), Column(name: "b", isHidden: true), Column(name: "c")])
        // The only visible column ("c") is gone.
        #expect(layout.arrange(["a", "b"]) == [Placement(index: 0), Placement(index: 1)])
        #expect(layout.arrange([]) == [])
    }

    @Test func repeatedNamesAndBadWidths() {
        let layout = GridColumnLayout(columns: [
            Column(name: "id", width: 70),
            Column(name: "x", width: .infinity),
            Column(name: "id", width: 30, isHidden: true),
            Column(name: "y", width: -5),
        ])
        #expect(layout.arrange(["id", "y", "id", "x"]) == [
            Placement(index: 0, width: 70),
            Placement(index: 3),
            Placement(index: 2, width: 30, isHidden: true),
            Placement(index: 1),
        ])
        #expect(GridColumnLayout.defaultPlacements(count: 2) == [Placement(index: 0), Placement(index: 1)])
    }

    @Test func columnNameMatchRanksExactPrefixWordThenContains() {
        let names = ["user_id", "id", "created_at", "valid", "Identifier", "orderId", "total"]
        #expect(ColumnNameMatch.rank(names, query: "id").map { names[$0] } == ["id", "Identifier", "user_id", "orderId", "valid"])
        #expect(ColumnNameMatch.rank(names, query: "  ").count == names.count)
        #expect(ColumnNameMatch.rank(names, query: "AT").map { names[$0] } == ["created_at"])
        #expect(ColumnNameMatch.rank(names, query: "zzz").isEmpty)
        #expect(ColumnNameMatch.rank(["café_total"], query: "cafe") == [0])
    }
}

@Suite struct GridColumnLayoutStoreTests {
    private func makeStore() throws -> (GridColumnLayoutStore, URL, URL) {
        let folder = TestFiles.url("grid-layouts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("grid-column-layouts.json")
        return (GridColumnLayoutStore(url: file), file, folder)
    }

    @Test func savesPerTableAndClears() throws {
        let (store, file, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let connection = UUID()
        let orders = GridColumnLayoutScope(connectionID: connection, database: "foxlume", schema: "public", table: "orders")
        let mysqlOrders = GridColumnLayoutScope(connectionID: connection, database: "shop", schema: nil, table: "orders")
        let layout = GridColumnLayout(columns: [
            GridColumnLayout.Column(name: "total", width: 120.04),
            GridColumnLayout.Column(name: "id", width: .nan),
            GridColumnLayout.Column(name: "notes", width: 200, isHidden: true),
        ])
        try store.setLayout(layout, for: orders)
        try store.setLayout(GridColumnLayout(columns: [GridColumnLayout.Column(name: "id", width: 60)]), for: mysqlOrders)

        let reloaded = GridColumnLayoutStore(url: file)
        #expect(reloaded.layout(for: orders) == GridColumnLayout(columns: [
            GridColumnLayout.Column(name: "total", width: 120),
            GridColumnLayout.Column(name: "id"),
            GridColumnLayout.Column(name: "notes", width: 200, isHidden: true),
        ]))
        #expect(reloaded.layout(for: mysqlOrders)?.columns.map(\.name) == ["id"])
        #expect(reloaded.layout(for: GridColumnLayoutScope(connectionID: UUID(), database: "foxlume", schema: "public", table: "orders")) == nil)

        try reloaded.clear(orders)
        let afterReset = GridColumnLayoutStore(url: file)
        #expect(afterReset.layout(for: orders) == nil)
        #expect(afterReset.layout(for: mysqlOrders) != nil)
        #expect(afterReset.setAsideFile == nil)

        // Only hidden columns that are true are written, so the file stays small.
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("\"hidden\" : false"))
    }

    @Test func damagedFileIsSetAsideAndReadableTablesKept() throws {
        let (_, file, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let connection = UUID()
        let damaged = """
            {"version": 1, "tables": [
              {"scope": {"connectionID": "\(connection.uuidString)", "database": "foxlume", "schema": "public", "table": "orders"},
               "layout": {"columns": [{"name": "id", "width": 44}, {"width": 3}, {"name": "status", "hidden": true}]}},
              {"scope": {"connectionID": 12}, "layout": {"columns": [{"name": "a"}]}},
              "not even an object"
            ]}
            """
        try Data(damaged.utf8).write(to: file)
        let store = GridColumnLayoutStore(url: file)
        let scope = GridColumnLayoutScope(connectionID: connection, database: "foxlume", schema: "public", table: "orders")
        #expect(store.layout(for: scope) == GridColumnLayout(columns: [
            GridColumnLayout.Column(name: "id", width: 44),
            GridColumnLayout.Column(name: "status", isHidden: true),
        ]))
        let aside = try #require(store.setAsideFile)
        #expect(aside.lastPathComponent.hasPrefix("grid-column-layouts.unreadable-"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try store.setLayout(GridColumnLayout(columns: [GridColumnLayout.Column(name: "id", width: 50)]), for: scope)
        #expect(GridColumnLayoutStore(url: file).layout(for: scope)?.columns.first?.width == 50)

        try Data("\u{0}garbage".utf8).write(to: file)
        let garbage = GridColumnLayoutStore(url: file)
        #expect(garbage.layout(for: scope) == nil)
        #expect(garbage.setAsideFile != nil)
    }
}

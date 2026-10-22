import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct FavouritesStoreTests {
    private let connection = UUID()
    private let other = UUID()

    private func url() -> URL {
        TestFiles.url("favourites-\(UUID().uuidString).json")
    }

    private func table(_ name: String, database: String? = "shop", schema: String? = "public", kind: TableKind = .table) -> SidebarItemRef {
        SidebarItemRef(table: TableRef(schema: schema, name: name), kind: kind, database: database)!
    }

    @Test func itemsKeepWhatOpensThemAgain() {
        #expect(SidebarItemRef(table: TableRef(name: "db0"), kind: .keyspace, database: nil) == nil)
        let view = table("totals", kind: .materializedView)
        #expect(view.tableRef == TableRef(schema: "public", name: "totals"))
        #expect(view.schemaObject == nil)
        // A table that became a view is the same entry.
        #expect(view.identity == table("totals").identity)

        let function = SchemaObject(kind: .function, schema: "public", name: "total", arguments: "a integer", identityArguments: "integer", detail: "sql")
        let item = SidebarItemRef(object: function, database: "shop")
        #expect(item.tableRef == nil)
        #expect(item.schemaObject == function)
        #expect(item.schemaObject?.id == function.id)
        let overload = SidebarItemRef(object: SchemaObject(kind: .function, schema: "public", name: "total", identityArguments: "text"), database: "shop")
        #expect(item.identity != overload.identity)
        let trigger = SidebarItemRef(object: SchemaObject(kind: .trigger, schema: "public", name: "audit", table: "orders"), database: "shop")
        #expect(trigger.searchText == "audit orders")
        #expect(trigger.identity != table("audit").identity)
    }

    @Test func persistsAcrossInstances() throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = FavouritesStore(url: file)
        let orders = table("orders"), items = table("items")
        let function = SidebarItemRef(object: SchemaObject(kind: .function, schema: "public", name: "total", identityArguments: "integer"), database: "shop")
        try store.addFavourite(orders, connection: connection)
        try store.addFavourite(function, connection: connection)
        try store.recordOpened(items, connection: connection)
        try store.recordOpened(orders, connection: connection)
        // Objects are not recent; only tables and views are.
        try store.recordOpened(function, connection: connection)
        try store.setCollapsed(.recent, true)

        let reopened = FavouritesStore(url: file)
        #expect(reopened.favourites(for: connection) == [orders, function])
        #expect(reopened.recent(for: connection) == [orders, items])
        #expect(reopened.isFavourite(function, connection: connection))
        #expect(reopened.isCollapsed(.recent))
        #expect(!reopened.isCollapsed(.favourites))
        #expect(reopened.setAsideFile == nil)
    }

    @Test func connectionsAreKeptApart() throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = FavouritesStore(url: file)
        try store.addFavourite(table("orders"), connection: connection)
        try store.recordOpened(table("orders"), connection: connection)
        try store.addFavourite(table("users"), connection: other)
        #expect(store.favourites(for: other) == [table("users")])
        #expect(store.recent(for: other).isEmpty)
        #expect(!store.isFavourite(table("orders"), connection: other))

        try store.removeConnection(connection)
        #expect(FavouritesStore(url: file).favourites(for: connection).isEmpty)
        #expect(FavouritesStore(url: file).favourites(for: other) == [table("users")])
    }

    @Test func favouritesToggleAndReorder() throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = FavouritesStore(url: file)
        let a = table("a"), b = table("b"), c = table("c")
        for item in [a, b, c] { try store.addFavourite(item, connection: connection) }
        // Adding again keeps the place and takes the newer kind.
        try store.addFavourite(table("b", kind: .view), connection: connection)
        #expect(store.favourites(for: connection).map(\.name) == ["a", "b", "c"])
        #expect(store.favourites(for: connection)[1].kind == .view)

        try store.moveFavourite(c, before: a, connection: connection)
        #expect(store.favourites(for: connection).map(\.name) == ["c", "a", "b"])
        try store.moveFavourite(c, before: nil, connection: connection)
        #expect(store.favourites(for: connection).map(\.name) == ["a", "b", "c"])
        try store.moveFavourite(a, before: c, connection: connection)
        #expect(store.favourites(for: connection).map(\.name) == ["b", "a", "c"])

        #expect(try store.toggleFavourite(a, connection: connection) == false)
        #expect(store.favourites(for: connection).map(\.name) == ["b", "c"])
        #expect(try store.toggleFavourite(a, connection: connection) == true)
        #expect(store.favourites(for: connection).map(\.name) == ["b", "c", "a"])
    }

    @Test func recentIsNewestFirstAndCapped() throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = FavouritesStore(url: file)
        for index in 0..<12 { try store.recordOpened(table("t\(index)"), connection: connection) }
        #expect(store.recent(for: connection).count == FavouritesStore.recentLimit)
        #expect(store.recent(for: connection).first?.name == "t11")
        #expect(store.recent(for: connection).last?.name == "t2")
        // Opening one again moves it to the front without a duplicate.
        try store.recordOpened(table("t5"), connection: connection)
        #expect(store.recent(for: connection).prefix(2).map(\.name) == ["t5", "t11"])
        #expect(store.recent(for: connection).filter { $0.name == "t5" }.count == 1)

        try store.removeRecent(table("t5"), connection: connection)
        #expect(!store.recent(for: connection).contains { $0.name == "t5" })
        try store.clearRecent(connection: connection)
        #expect(store.recent(for: connection).isEmpty)
    }

    @Test func renamesAndDropsUpdateBothLists() throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = FavouritesStore(url: file)
        let orders = table("orders"), items = table("items")
        let otherDatabase = table("orders", database: "archive")
        for item in [orders, items, otherDatabase] {
            try store.addFavourite(item, connection: connection)
            try store.recordOpened(item, connection: connection)
        }
        try store.renameObject(orders, to: "purchases", connection: connection)
        #expect(store.favourites(for: connection).map(\.name) == ["purchases", "items", "orders"])
        #expect(store.recent(for: connection).map(\.name) == ["orders", "items", "purchases"])
        #expect(store.favourites(for: connection)[2].database == "archive")

        try store.removeObject(items, connection: connection)
        #expect(store.favourites(for: connection).map(\.name) == ["purchases", "orders"])
        #expect(store.recent(for: connection).map(\.name) == ["orders", "purchases"])
    }

    @Test func schemaAndDatabaseRenamesMoveItems() throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = FavouritesStore(url: file)
        let sales = table("orders", schema: "sales")
        let leftOver = table("orders", schema: "revenue")
        let function = SidebarItemRef(object: SchemaObject(kind: .function, schema: "sales", name: "total", identityArguments: "integer"), database: "shop")
        let otherDatabase = table("orders", database: "archive", schema: "sales")
        for item in [sales, function, otherDatabase, leftOver] { try store.addFavourite(item, connection: connection) }
        try store.addFavourite(sales, connection: other)

        try store.apply(.schema(connectionID: connection, database: "shop", from: "sales", to: "revenue"))
        // "revenue.orders" was already there: the renamed one takes its place first, the duplicate goes.
        #expect(store.favourites(for: connection).map { "\($0.database ?? "").\($0.schema ?? "").\($0.name)" }
            == ["shop.revenue.orders", "shop.revenue.total", "archive.sales.orders"])
        #expect(store.favourites(for: connection)[1].schemaObject?.schema == "revenue")
        // Other connections are not touched.
        #expect(store.favourites(for: other) == [sales])

        try store.apply(.database(connectionID: connection, from: "archive", to: "vault"))
        #expect(store.favourites(for: connection).last?.database == "vault")
        #expect(FavouritesStore(url: file).favourites(for: connection).last?.database == "vault")
    }

    @Test func unreadableFileIsSetAsideKeepingWhatDecodes() throws {
        let file = url()
        defer {
            try? FileManager.default.removeItem(at: file)
        }
        let id = connection.uuidString
        let json = """
        {"connections": {"\(id)": {"favourites": [{"kind": "table", "name": "orders", "database": "shop"}, {"kind": "galaxy", "name": "x"}],
         "recent": "oops"}}, "collapsed": ["recent", "nope"]}
        """
        try Data(json.utf8).write(to: file)
        let store = FavouritesStore(url: file)
        #expect(store.favourites(for: connection).map(\.name) == ["orders"])
        #expect(store.recent(for: connection).isEmpty)
        #expect(store.isCollapsed(.recent))
        let aside = try #require(store.setAsideFile)
        defer { try? FileManager.default.removeItem(at: aside) }
        #expect(FileManager.default.fileExists(atPath: aside.path))
    }

    @Test func notifiesOnlyWhenSomethingChanged() throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = FavouritesStore(url: file)
        final class Counter: @unchecked Sendable { var value = 0 }
        let count = Counter()
        let observer = NotificationCenter.default.addObserver(forName: FavouritesStore.didChangeNotification, object: store, queue: nil) { _ in count.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        try store.addFavourite(table("a"), connection: connection)
        try store.addFavourite(table("a"), connection: connection)
        try store.removeRecent(table("a"), connection: connection)
        try store.recordOpened(table("a"), connection: connection)
        try store.recordOpened(table("a"), connection: connection)
        #expect(count.value == 2)
    }
}

@Suite struct SidebarSectionsTests {
    private func table(_ name: String, database: String? = "shop", schema: String? = "public") -> SidebarItemRef {
        SidebarItemRef(kind: .table, database: database, schema: schema, name: name)
    }

    @Test func locationLabels() {
        #expect(table("t").locationLabel(currentDatabase: "shop") == "public")
        #expect(table("t", database: "archive").locationLabel(currentDatabase: "shop") == "archive.public")
        #expect(table("t", database: "archive", schema: nil).locationLabel(currentDatabase: "shop") == "archive")
        // MySQL objects carry their database as schema.
        let procedure = SidebarItemRef(kind: .procedure, database: "archive", schema: "archive", name: "p")
        #expect(procedure.locationLabel(currentDatabase: "shop") == "archive")
    }

    @Test func recentPutsTheBrowsedSchemaFirst() {
        let items = [table("a", schema: "sales"), table("b"), table("c", database: "archive"), table("d"), table("gone")]
        let browsed = SidebarSections.Browsed(database: "shop", schema: "public", schemasMatter: true, tables: ["b", "d"])
        let rows = SidebarSections.recentRows(items, browsed: browsed, filter: "")
        #expect(rows.map(\.item.name) == ["b", "d", "a", "c"])
        #expect(rows.map(\.location) == [nil, nil, "sales", "archive.public"])
        #expect(SidebarSections.recentRows(items, browsed: browsed, filter: "", limit: 2).map(\.item.name) == ["b", "a"])
        #expect(SidebarSections.recentRows(items, browsed: browsed, filter: " D ").map(\.item.name) == ["d"])
    }

    @Test func favouritesKeepTheirOrderAndMarkMissingOnes() {
        let function = SidebarItemRef(object: SchemaObject(kind: .function, schema: "public", name: "total", identityArguments: "integer"), database: "shop")
        let gone = SidebarItemRef(object: SchemaObject(kind: .function, schema: "public", name: "old"), database: "shop")
        let trigger = SidebarItemRef(object: SchemaObject(kind: .trigger, schema: "public", name: "audit", table: "orders"), database: "shop")
        let items = [table("z", schema: "sales"), table("b"), table("gone"), function, gone, trigger]
        var browsed = SidebarSections.Browsed(database: "shop", schema: "public", schemasMatter: true, tables: ["b"],
                                              objects: [.function: [function.identity]])
        let rows = SidebarSections.favouriteRows(items, browsed: browsed, filter: "")
        #expect(rows.map(\.item.name) == ["z", "b", "gone", "total", "old", "audit"])
        #expect(rows.map(\.isMissing) == [false, false, true, false, true, false])
        #expect(rows.map(\.location) == ["sales", nil, nil, nil, nil, nil])
        // A trigger matches its table's name too.
        #expect(SidebarSections.favouriteRows(items, browsed: browsed, filter: "ORDERS").map(\.item.name) == ["audit"])
        // Before the lists are read, nothing is missing.
        browsed.tables = nil
        browsed.objects = [:]
        #expect(SidebarSections.favouriteRows(items, browsed: browsed, filter: "").allSatisfy { !$0.isMissing })
    }

    @Test func enginesWithoutSchemasCompareTheDatabase() {
        let browsed = SidebarSections.Browsed(database: "shop", schema: nil, schemasMatter: false, tables: ["orders"],
                                              objects: [.procedure: []])
        let mine = table("orders", schema: nil)
        let elsewhere = table("orders", database: "archive", schema: nil)
        let procedure = SidebarItemRef(kind: .procedure, database: "shop", schema: "shop", name: "p")
        let rows = SidebarSections.favouriteRows([mine, elsewhere, procedure], browsed: browsed, filter: "")
        #expect(rows.map(\.location) == [nil, "archive", nil])
        #expect(rows.map(\.isMissing) == [false, false, true])
    }
}

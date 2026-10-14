import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

/// Scratch SQLite files for the app tests, inside `TMPDIR` (which `fqtest` keeps in the project).
private func scratchURL(_ name: String) -> URL {
    let directory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
    return directory.appendingPathComponent("\(name)-\(UUID().uuidString).sqlite")
}

/// Removes every saved query and folder a test made; their names all start with `fqtest`.
@MainActor
private func removeTestSavedQueries() {
    let store = AppEnvironment.savedQueries
    for query in store.library.queries where query.name.hasPrefix("fqtest") { try? store.deleteQuery(id: query.id) }
    for folder in store.library.folders where folder.name.hasPrefix("fqtest") { try? store.deleteFolder(id: folder.id) }
}

extension AppCompletionTests {
    @Suite("Saved queries in completion")
    @MainActor
    struct SavedQueryCompletionTests {
        private let workspace = ConnectionWorkspace(config: ConnectionConfig(name: "fqtest", kind: .postgresql, port: 1, database: "x"), password: "")

        private func saveSamples() throws {
            let store = AppEnvironment.savedQueries
            try store.save(SavedQuery(name: "fqtest top", sql: "SELECT * FROM customers WHERE id = ;; LIMIT 1", keyword: "fqtest_top", connectionID: workspace.config.id))
            try store.save(SavedQuery(name: "fqtest elsewhere", sql: "SELECT 2", keyword: "fqtest_other", connectionID: UUID()))
            try store.save(SavedQuery(name: "fqtest everywhere", sql: "SELECT 3", keyword: "fqtest_all"))
        }

        @Test func keywordsOfVisibleSavedQueriesReachTheEngine() async throws {
            removeTestSavedQueries()
            defer { removeTestSavedQueries() }
            try saveSamples()
            let engine = SQLCompletionEngine(family: .postgresql, schema: workspace)
            let result = await engine.complete(text: "fqtest_", caret: 7, manual: false, keywordCase: .matchTypedElseUpper)
            let favorites = result?.items.filter { $0.kind == .favorite } ?? []
            #expect(favorites.map(\.label) == ["fqtest_all", "fqtest_top"], "another connection's keyword is not offered")
            let top = favorites.first { $0.label == "fqtest_top" }
            #expect(top?.detail == "fqtest top")
            #expect(top?.insertText == "SELECT * FROM customers WHERE id =  LIMIT 1")
            #expect(top?.caretOffsetFromEnd == " LIMIT 1".utf16.count)
        }

        /// Typing the keyword in the editor and accepting puts the SQL in its place, the caret where `;;` was.
        @Test func acceptingAKeywordInsertsTheQuery() async throws {
            removeTestSavedQueries()
            defer { removeTestSavedQueries() }
            try saveSamples()
            let h = EditorHarness()
            defer { h.close() }
            h.provider.completionEngine = SQLCompletionEngine(family: .postgresql, schema: workspace)
            h.type("fqtest_t")
            await settle(until: { h.labels.contains("fqtest_top") })
            #expect(h.labels.first == "fqtest_top")
            h.text.acceptSelectedCompletion()
            #expect(h.string == "SELECT * FROM customers WHERE id =  LIMIT 1")
            #expect(h.text.selectedRange().location == ("SELECT * FROM customers WHERE id = " as NSString).length)
        }

        @Test func deletedQueriesAreNoLongerOffered() async throws {
            removeTestSavedQueries()
            defer { removeTestSavedQueries() }
            try saveSamples()
            removeTestSavedQueries()
            #expect(workspace.favorites().filter { $0.keyword.hasPrefix("fqtest") }.isEmpty)
        }
    }

    @Suite("Saved queries sidebar")
    @MainActor
    struct SavedQueriesSidebarTests {
        @Test func treeMenusRenameDuplicateAndMove() throws {
            removeTestSavedQueries()
            defer { removeTestSavedQueries() }
            let workspace = ConnectionWorkspace(config: ConnectionConfig(name: "fqtest", kind: .sqlite, filePath: scratchURL("sidebar").path), password: "")
            let store = AppEnvironment.savedQueries
            let folder = try store.saveFolder(SavedQueryFolder(name: "fqtest Reports", connectionID: workspace.config.id))
            let query = try store.save(SavedQuery(name: "fqtest Daily", sql: "SELECT 1", keyword: "fqtest_daily", folderID: folder.id, connectionID: workspace.config.id))
            try store.save(SavedQuery(name: "fqtest Shared", sql: "SELECT 2"))
            try store.save(SavedQuery(name: "fqtest Hidden", sql: "SELECT 3", connectionID: UUID()))

            let list = SavedQueriesViewController(workspace: workspace)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = list
            defer { window.close() }
            list.reload()

            let rows = list.rowDescriptions().filter { $0.contains("fqtest") }
            #expect(rows.contains("fqtest Reports/"))
            #expect(rows.contains("  fqtest Daily [fqtest_daily]"), "queries sit inside their folder")
            #expect(rows.contains("fqtest Shared {all}"))
            #expect(!rows.contains { $0.contains("Hidden") }, "another connection's query is not listed")

            let menu = list.menuTitles(forRowNamed: "fqtest Daily")
            #expect(menu.prefix(4) == ["Open", "Open in New Tab", "Run in New Tab", "Insert into Editor"])
            #expect(menu.contains("Delete…"))
            #expect(menu.contains { $0.hasPrefix("Move to ▸ Top Level") && $0.contains("✓ fqtest Reports") })
            // A query for every connection cannot go into a folder of one connection.
            #expect(!(list.menuTitles(forRowNamed: "fqtest Shared").first { $0.hasPrefix("Move to") } ?? "").contains("fqtest Reports"))
            #expect(list.menuTitles(forRowNamed: "fqtest Reports").contains("Available in All Connections"))

            list.rename(named: "fqtest Daily", to: "fqtest Daily totals")
            #expect(store.query(id: query.id)?.name == "fqtest Daily totals")
            #expect(list.performMenuItem("Duplicate", onRowNamed: "fqtest Daily totals"))
            let copy = try #require(store.library.queries.first { $0.name == "fqtest Daily totals copy" })
            #expect(copy.keyword == nil && copy.folderID == folder.id)
            #expect(list.performMenuItem("Move to", onRowNamed: "fqtest Daily totals copy", submenuItem: "Top Level"))
            #expect(store.query(id: copy.id)?.folderID == nil)
            #expect(list.performMenuItem("Available in All Connections", onRowNamed: "fqtest Reports"))
            #expect(store.library.folder(id: folder.id)?.connectionID == nil)
        }
    }

    @Suite("Open Quickly")
    @MainActor
    struct OpenQuicklyTests {
        /// A window on a scratch SQLite database with a few tables and a view.
        private func makeWindow() async throws -> (WorkspaceWindowController, URL) {
            let url = scratchURL("open-quickly")
            let workspace = ConnectionWorkspace(config: ConnectionConfig(name: "fqtest", kind: .sqlite, filePath: url.path), password: "")
            try await workspace.connect()
            _ = try await workspace.execute("""
                CREATE TABLE orders (id INTEGER PRIMARY KEY, total REAL);
                CREATE TABLE order_items (id INTEGER PRIMARY KEY, order_id INTEGER);
                CREATE TABLE customers (id INTEGER PRIMARY KEY);
                CREATE VIEW order_totals AS SELECT id, total FROM orders;
                """, recordHistory: false)
            await workspace.refreshMetadata()
            return (WorkspaceWindowController(workspace: workspace), url)
        }

        private func tearDown(_ window: WorkspaceWindowController, _ url: URL) {
            OpenQuicklyController.current?.close()
            let id = window.workspace.config.id
            window.window?.close()
            AppEnvironment.openQuicklyFrecency.removeConnection(id)
            try? FileManager.default.removeItem(at: AppPaths.tabStateDirectory.appendingPathComponent(id.uuidString + ".json"))
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }

        @Test func searchRanksHighlightsAndOpensTables() async throws {
            let (window, url) = try await makeWindow()
            defer { tearDown(window, url) }
            window.openQuickly(nil)
            let panel = try #require(OpenQuicklyController.current)
            panel.setQuery("ord")
            let rows = panel.rowDescriptions()
            #expect(rows.first?.hasPrefix("> table: «ord»ers") == true, "\(rows)")
            #expect(rows.contains { $0.contains("view: «ord»er_totals") })
            #expect(!rows.contains { $0.contains("customers") })

            panel.perform("return")
            #expect(OpenQuicklyController.current == nil)
            #expect(window.tabs.selectedTab?.table?.name == "orders")

            // The table opened last now leads the Recent section, and is marked as open.
            window.openQuickly(nil)
            let again = try #require(OpenQuicklyController.current)
            #expect(again.rowDescriptions().prefix(2) == ["[Recent]", "> table: orders {open} — " + (window.workspace.currentDatabase ?? "")])
            again.perform("toggle")
            #expect(OpenQuicklyController.current == nil)
        }

        @Test func keysScopesAndEscape() async throws {
            let (window, url) = try await makeWindow()
            defer { tearDown(window, url) }
            window.openQuickly(nil)
            let panel = try #require(OpenQuicklyController.current)
            panel.setQuery("order")
            let first = panel.rowDescriptions().first { $0.hasPrefix(">") }
            panel.perform("down")
            #expect(panel.rowDescriptions().first { $0.hasPrefix(">") } != first)
            panel.perform("ctrl-p")
            #expect(panel.rowDescriptions().first { $0.hasPrefix(">") } == first)
            panel.perform("up")
            #expect(panel.rowDescriptions().first { $0.hasPrefix(">") } == first, "the selection stops at the top")

            panel.perform("cmd-4")
            #expect(panel.scopeTitle == "Queries")
            panel.perform("cmd-2")
            #expect(panel.scopeTitle == "Tables")
            #expect(panel.rowDescriptions().allSatisfy { $0.contains("table:") || $0.contains("view:") })

            panel.perform("escape")
            #expect(OpenQuicklyController.current === panel, "the first Escape clears the text")
            panel.perform("escape")
            #expect(OpenQuicklyController.current == nil)

            // ⇧⌘O again closes the panel.
            window.openQuickly(nil)
            window.openQuickly(nil)
            #expect(OpenQuicklyController.current == nil)
        }

        @Test func savedQueriesOpenInAQueryTabWithoutRunning() async throws {
            removeTestSavedQueries()
            defer { removeTestSavedQueries() }
            let (window, url) = try await makeWindow()
            defer { tearDown(window, url) }
            let sql = "SELECT count(*) FROM orders"
            try AppEnvironment.savedQueries.save(SavedQuery(name: "fqtest order count", sql: sql, keyword: "fqtest_oc", connectionID: window.workspace.config.id))

            window.openQuickly(nil)
            let panel = try #require(OpenQuicklyController.current)
            panel.setQuery("fqtest_oc")
            #expect(panel.rowDescriptions().first?.hasPrefix("> savedQuery: fqtest order count") == true)
            panel.perform("return")
            let query = try #require(window.tabs.selectedTab?.content as? QueryTabViewController)
            #expect(query.sql == sql)
            #expect(query.tabTitle == "fqtest order count")
            #expect(query.currentResult == nil, "opening never runs the query")
        }
    }
}

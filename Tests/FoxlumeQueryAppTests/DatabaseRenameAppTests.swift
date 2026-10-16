import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

extension AppCompletionTests {
    /// Rename Schema, Rename Database and Copy Database through the window, on scratch databases named fq110_app*.
    @Suite("Rename schema and database", .enabled(if: LiveServer.postgres, "needs the PostgreSQL test server"))
    @MainActor
    struct DatabaseRenameAppTests {
        private static func config(_ database: String) -> ConnectionConfig {
            ConnectionConfig(name: "fqtest", kind: .postgresql, host: "127.0.0.1", port: 55432, user: "postgres", database: database, sslMode: .prefer)
        }

        private func admin(_ statements: [String]) async throws {
            let session = DatabaseSession(parameters: ConnectionParameters(config: Self.config("postgres"), password: "postgres"))
            try await session.connect()
            for statement in statements {
                _ = try? await session.run { try $0.execute(statement, rowLimit: nil) }
            }
            await session.close()
        }

        private func dropDatabases(_ names: [String]) async throws {
            try await admin(names.map { "DROP DATABASE IF EXISTS \($0)" })
        }

        private func makeWindow(on database: String) async throws -> WorkspaceWindowController {
            let workspace = ConnectionWorkspace(config: Self.config(database), password: "postgres")
            try await workspace.connect()
            return WorkspaceWindowController(workspace: workspace)
        }

        private func close(_ controller: WorkspaceWindowController) async {
            let id = controller.workspace.config.id
            controller.window?.close()
            await controller.workspace.disconnect()
            try? FileManager.default.removeItem(at: AppPaths.tabStateDirectory.appendingPathComponent(id.uuidString + ".json"))
        }

        private func waitUntil(_ seconds: Double = 20, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                guard Date() < deadline else { throw DatabaseError.unsupported("Timed out") }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        @Test func renameSchemaMovesTabsAndRememberedState() async throws {
            try await dropDatabases(["fq110_app"])
            try await admin(["CREATE DATABASE fq110_app"])
            let controller = try await makeWindow(on: "fq110_app")
            let workspace = controller.workspace
            _ = try await workspace.execute("CREATE SCHEMA fq110_sales; CREATE TABLE fq110_sales.orders (id int PRIMARY KEY, total numeric)")
            await workspace.switchSchema("fq110_sales")
            let old = TableRef(schema: "fq110_sales", name: "orders")
            controller.tabs.openTable(old, newTab: true)
            controller.tabs.openTable(TableRef(schema: "public", name: "missing"), newTab: true)
            controller.tabs.selectTab(at: 0)
            let firstID = try #require(controller.tabs.tabs.first?.id)

            let id = workspace.config.id
            let layoutScope = GridColumnLayoutScope(connectionID: id, database: "fq110_app", schema: "fq110_sales", table: "orders")
            try AppEnvironment.gridColumnLayouts.setLayout(GridColumnLayout(columns: [.init(name: "total", width: 150), .init(name: "id")]), for: layoutScope)
            let presetScope = FilterPresetScope(connectionID: id, database: "fq110_app", schema: "fq110_sales", table: "orders")
            try AppEnvironment.filterPresets.save(name: "Big", rules: [FilterRule(column: "total", op: .greaterThan, value: "100")], logic: .and, rawWhere: "", for: presetScope)
            try AppEnvironment.erDiagramLayouts.setPositions(["orders": CGPoint(x: 40, y: 60)], for: ERDiagramScope(connectionID: id, database: "fq110_app", schema: "fq110_sales"))
            AppEnvironment.openQuicklyFrecency.record(QuickOpenItem.tableKey(old), connection: id)

            controller.renameSchema("fq110_sales", to: "fq110_revenue")
            try await waitUntil { workspace.currentSchema == "fq110_revenue" && controller.tabs.tabs.first?.table?.schema == "fq110_revenue" }

            let renamed = TableRef(schema: "fq110_revenue", name: "orders")
            #expect(workspace.schemas.contains("fq110_revenue") && !workspace.schemas.contains("fq110_sales"))
            #expect(workspace.tables.map(\.ref) == [renamed])
            #expect(controller.tabs.tabs.map(\.table) == [renamed, TableRef(schema: "public", name: "missing")])
            #expect(controller.tabs.tabs.first?.id == firstID, "the tab is rebuilt in place")
            #expect(controller.tabs.selectedTab?.table == renamed)
            let newLayout = GridColumnLayoutScope(connectionID: id, database: "fq110_app", schema: "fq110_revenue", table: "orders")
            #expect(AppEnvironment.gridColumnLayouts.layout(for: newLayout)?.columns.map(\.name) == ["total", "id"])
            #expect(AppEnvironment.gridColumnLayouts.layout(for: layoutScope) == nil)
            #expect((controller.tabs.selectedTab?.content as? TableTabViewController)?.columnLayoutScope == newLayout)
            #expect(AppEnvironment.filterPresets.presets(for: FilterPresetScope(connectionID: id, database: "fq110_app", schema: "fq110_revenue", table: "orders")).map(\.name) == ["Big"])
            #expect(AppEnvironment.erDiagramLayouts.positions(for: ERDiagramScope(connectionID: id, database: "fq110_app", schema: "fq110_revenue"))["orders"] == CGPoint(x: 40, y: 60))
            #expect(AppEnvironment.openQuicklyFrecency.recentKeys(for: id).contains(QuickOpenItem.tableKey(renamed)))
            #expect(!AppEnvironment.openQuicklyFrecency.recentKeys(for: id).contains(QuickOpenItem.tableKey(old)))

            // System schemas are refused before anything reaches the server.
            await #expect(throws: DatabaseError.self) { try await workspace.renameSchema("pg_catalog", to: "fq110_catalog") }
            let catalog = try await workspace.execute("SELECT count(*) FROM pg_namespace WHERE nspname = 'pg_catalog'", recordHistory: false)
            #expect(catalog.first?.rows.first?.first?.displayString == "1")

            await close(controller)
            try await dropDatabases(["fq110_app"])
        }

        @Test func renameAndCopyTheCurrentDatabase() async throws {
            let names = ["fq110_appdb", "fq110_appdb_renamed", "fq110_appdb_copy"]
            try await dropDatabases(names)
            try await admin(["CREATE DATABASE fq110_appdb"])
            let controller = try await makeWindow(on: "fq110_appdb")
            let workspace = controller.workspace
            _ = try await workspace.execute("CREATE TABLE items (id int PRIMARY KEY)")
            controller.tabs.openTable(TableRef(schema: "public", name: "items"), newTab: true)
            let id = workspace.config.id
            let oldScope = GridColumnLayoutScope(connectionID: id, database: "fq110_appdb", schema: "public", table: "items")
            try AppEnvironment.gridColumnLayouts.setLayout(GridColumnLayout(columns: [.init(name: "id", width: 90)]), for: oldScope)

            controller.renameDatabase("fq110_appdb", to: "fq110_appdb_renamed")
            try await waitUntil { controller.isChangingDatabase }
            try await waitUntil { !controller.isChangingDatabase }
            #expect(workspace.currentDatabase == "fq110_appdb_renamed")
            #expect(workspace.config.database == "fq110_appdb_renamed", "reconnects open the new name")
            #expect(workspace.databases.contains("fq110_appdb_renamed") && !workspace.databases.contains("fq110_appdb"))
            let tab = try #require(controller.tabs.tabs.first?.content as? TableTabViewController)
            #expect(tab.openedDatabase == "fq110_appdb_renamed")
            #expect(AppEnvironment.gridColumnLayouts.layout(for: tab.columnLayoutScope)?.columns.first?.width == 90)
            #expect(AppEnvironment.gridColumnLayouts.layout(for: oldScope) == nil)
            try await workspace.reconnect()
            #expect(workspace.currentDatabase == "fq110_appdb_renamed")

            controller.copyDatabase("fq110_appdb_renamed", to: "fq110_appdb_copy", keepOwner: true)
            try await waitUntil { workspace.databases.contains("fq110_appdb_copy") }
            try await waitUntil { !controller.isChangingDatabase }
            #expect(workspace.currentDatabase == "fq110_appdb_renamed", "a copy returns to the source")

            // Another session on the source: nothing changes, and the sessions are named.
            let other = DatabaseSession(parameters: ConnectionParameters(config: Self.config("fq110_appdb_copy"), password: "postgres"))
            try await other.connect()
            do {
                try await workspace.performDatabaseChange(.rename(from: "fq110_appdb_copy", to: "fq110_appdb_x"))
                Issue.record("renamed while another session was connected")
            } catch let error as DatabaseChangeError {
                #expect(error.total == 1)
                #expect(error.localizedDescription.contains("Foxlume Query (postgres)"))
            }
            #expect(workspace.databases.contains("fq110_appdb_copy"))
            await other.close()

            await close(controller)
            try await dropDatabases(names + ["fq110_appdb_x"])
        }
    }
}

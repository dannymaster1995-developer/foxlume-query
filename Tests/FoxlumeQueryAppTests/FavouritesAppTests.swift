import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

extension AppCompletionTests {
    /// Favourites and Recent in the sidebar of a scratch SQLite file: the menu items and the star, both sections,
    /// opening from them, and a rename or drop of a favourite table.
    @Suite("Favourites")
    @MainActor
    struct FavouritesAppTests {
        private func scratchURL() -> URL {
            let directory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
            return directory.appendingPathComponent("favourites-\(UUID().uuidString).sqlite")
        }

        private func makeWindow(_ url: URL) async throws -> WorkspaceWindowController {
            _ = NSApplication.shared
            let session = DatabaseSession(parameters: ConnectionParameters(config: ConnectionConfig(kind: .sqlite, filePath: url.path), password: ""))
            try await session.connect()
            _ = try await session.execute("""
                CREATE TABLE fq_fav_a (id INTEGER PRIMARY KEY); CREATE TABLE fq_fav_b (id INTEGER PRIMARY KEY);
                CREATE TABLE fq_fav_c (id INTEGER PRIMARY KEY); CREATE VIEW fq_fav_v AS SELECT id FROM fq_fav_a;
                CREATE TRIGGER fq_fav_t AFTER INSERT ON fq_fav_a BEGIN SELECT 1; END
                """)
            await session.close()
            let workspace = ConnectionWorkspace(config: ConnectionConfig(name: "fqtest", kind: .sqlite, filePath: url.path), password: "")
            try await workspace.connect()
            let controller = WorkspaceWindowController(workspace: workspace)
            controller.window?.isReleasedWhenClosed = false
            controller.window?.orderFront(nil)
            await settle(until: { !workspace.isLoadingSchemaObjects && !workspace.schemaObjects.isEmpty })
            return controller
        }

        private func close(_ controller: WorkspaceWindowController, _ url: URL) async {
            let id = controller.workspace.config.id
            controller.window?.close()
            await controller.workspace.disconnect()
            try? AppEnvironment.favourites.removeConnection(id)
            try? AppEnvironment.favourites.setCollapsed(.favourites, false)
            try? AppEnvironment.favourites.setCollapsed(.recent, false)
            try? FileManager.default.removeItem(at: AppPaths.tabStateDirectory.appendingPathComponent(id.uuidString + ".json"))
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }

        private func info(_ name: String, in controller: WorkspaceWindowController) throws -> TableInfo {
            try #require(controller.workspace.tables.first { $0.name == name })
        }

        @Test func menuItemsAndStarToggleFavourites() async throws {
            let url = scratchURL()
            let controller = try await makeWindow(url)
            let sidebar = controller.sidebarController
            #expect(sidebar.describeShortcutSections().isEmpty)

            let a = try info("fq_fav_a", in: controller)
            #expect(controller.sidebarMenuTitles(for: a).contains("Add to Favourites"))
            // Database › Add to Favourites acts on the sidebar's selection here, and names what it will do.
            let database = MainMenu.build().items.first { $0.title == "Database" }?.submenu
            let menuItem = try #require(database?.items.first { $0.title == "Add to Favourites" })
            #expect(menuItem.keyEquivalent == "b" && menuItem.keyEquivalentModifierMask == [.command, .option])
            #expect(controller.validateMenuItem(menuItem))
            controller.toggleFavourite(nil)
            #expect(menuItem.title == "Add to Favourites")
            #expect(controller.validateMenuItem(menuItem))
            #expect(menuItem.title == "Remove from Favourites")
            #expect(controller.sidebarMenuTitles(for: a).contains("Remove from Favourites"))
            #expect(sidebar.describeShortcutSections() == ["Favourites (open): fq_fav_a"])

            // The star: filled on a favourite, hollow only while hovered elsewhere, and a click toggles.
            let rowA = try #require(sidebar.row(ofTable: "fq_fav_a"))
            let rowB = try #require(sidebar.row(ofTable: "fq_fav_b"))
            #expect(sidebar.isStarShown(atRow: rowA))
            #expect(!sidebar.isStarShown(atRow: rowB))
            sidebar.setHoveredRow(rowB)
            #expect(sidebar.isStarShown(atRow: rowB))
            let cell = try #require(sidebar.outline.view(atColumn: 0, row: rowB, makeIfNecessary: false) as? ObjectCellView)
            // Sent as the button sends it: performClick in a test process can stop the main run loop.
            sidebar.starClicked(cell.starButton)
            await settle(until: { sidebar.describeShortcutSections() == ["Favourites (open): fq_fav_a, fq_fav_b"] })
            #expect(sidebar.describeShortcutSections() == ["Favourites (open): fq_fav_a, fq_fav_b"])

            // Objects get the item too; the trigger is listed under its table.
            let trigger = try #require(controller.workspace.schemaObjects.first { $0.name == "fq_fav_t" })
            sidebar.setGroup("Triggers", expanded: true)
            sidebar.select(trigger)
            #expect(sidebar.menuTitlesForSelection().contains("Add to Favourites"))
            sidebar.toggleFavourite(try #require(sidebar.selectedSidebarItem))
            #expect(sidebar.describeShortcutSections() == ["Favourites (open): fq_fav_a, fq_fav_b, fq_fav_t"])
            #expect(AppEnvironment.favourites.favourites(for: controller.workspace.config.id).last?.table == "fq_fav_a")

            // Drag to reorder: the trigger in front of the first table.
            let favourites = AppEnvironment.favourites.favourites(for: controller.workspace.config.id)
            sidebar.moveFavourite(favourites[2], before: favourites[0])
            #expect(sidebar.describeShortcutSections() == ["Favourites (open): fq_fav_t, fq_fav_a, fq_fav_b"])
            await close(controller, url)
        }

        @Test func recentSectionFollowsOpenedTablesAndTheFilter() async throws {
            let url = scratchURL()
            let controller = try await makeWindow(url)
            let sidebar = controller.sidebarController
            controller.tabs.openTable(TableRef(name: "fq_fav_a"), newTab: true)
            controller.tabs.openTable(TableRef(name: "fq_fav_v"), newTab: true)
            await settle(until: { sidebar.describeShortcutSections() == ["Recent (open): fq_fav_v, fq_fav_a"] })
            #expect(sidebar.describeShortcutSections() == ["Recent (open): fq_fav_v, fq_fav_a"])
            #expect(AppEnvironment.favourites.recent(for: controller.workspace.config.id).first?.kind == .view)

            // A Recent row's menu has the table's actions plus its own.
            let titles = try #require(sidebar.shortcutMenuTitles(.recent, named: "fq_fav_a"))
            #expect(titles.contains("Show Structure"))
            #expect(titles.contains("Rename"))
            #expect(titles.contains("Remove from Recent"))
            #expect(titles.contains("Clear Recent"))

            // The filter narrows the sections too; a section without matches is hidden.
            controller.applySidebarFilter("_v")
            #expect(sidebar.describeShortcutSections() == ["Recent (open): fq_fav_v"])
            controller.applySidebarFilter("zzz")
            #expect(sidebar.describeShortcutSections().isEmpty)
            controller.applySidebarFilter("")

            // Opening from Recent selects the existing tab; collapsing is remembered.
            #expect(sidebar.openShortcut(.recent, named: "fq_fav_a"))
            #expect(controller.tabs.selectedTab?.table == TableRef(name: "fq_fav_a"))
            sidebar.setGroup("Recent", expanded: false)
            #expect(AppEnvironment.favourites.isCollapsed(.recent))
            sidebar.reload()
            #expect(sidebar.describeShortcutSections().first?.hasPrefix("Recent (closed)") == true)

            #expect(sidebar.shortcutMenuTitles(.recent, named: "fq_fav_v") == nil)
            sidebar.setGroup("Recent", expanded: true)
            await settle(until: { sidebar.describeShortcutSections().first?.hasPrefix("Recent (open): fq_fav_a") == true })
            _ = sidebar.shortcutMenuTitles(.recent, named: "fq_fav_v")
            let menu = NSMenu()
            sidebar.menuNeedsUpdate(menu)
            let clear = try #require(menu.items.first { $0.title == "Clear Recent" })
            NSApp.sendAction(try #require(clear.action), to: clear.target, from: clear)
            #expect(sidebar.describeShortcutSections().isEmpty)
            await close(controller, url)
        }

        @Test func renameAndDropFollowFavourites() async throws {
            let url = scratchURL()
            let controller = try await makeWindow(url)
            let sidebar = controller.sidebarController
            for name in ["fq_fav_b", "fq_fav_c"] {
                sidebar.toggleFavourite(try #require(sidebar.sidebarItem(try info(name, in: controller))))
            }
            controller.renameObject(try info("fq_fav_b", in: controller), to: "fq_fav_b2")
            await settle(until: { sidebar.describeShortcutSections() == ["Favourites (open): fq_fav_b2, fq_fav_c"] })
            #expect(sidebar.describeShortcutSections() == ["Favourites (open): fq_fav_b2, fq_fav_c"])

            // Clicking a favourite opens it like the tree.
            #expect(sidebar.openShortcut(.favourites, named: "fq_fav_b2"))
            #expect(controller.tabs.selectedTab?.table == TableRef(name: "fq_fav_b2"))

            // Dropped elsewhere (here from another session): dimmed with Remove, not silently gone.
            _ = try await controller.workspace.execute("DROP TABLE fq_fav_c")
            await controller.workspace.refreshMetadata()
            #expect(sidebar.describeShortcutSections().first?.hasSuffix("fq_fav_c (missing)") == true)
            #expect(sidebar.shortcutMenuTitles(.favourites, named: "fq_fav_c") == ["Remove"])
            #expect(!sidebar.openShortcut(.favourites, named: "fq_fav_c"))

            // Dropped from the sidebar: removed from both lists.
            controller.toggleTableOperation(try info("fq_fav_b2", in: controller), .drop, options: TableOperationOptions())
            controller.saveAll(nil)
            await settle(until: { !controller.workspace.tables.contains { $0.name == "fq_fav_b2" } })
            await settle(until: { !(sidebar.describeShortcutSections().first ?? "").contains("fq_fav_b2") })
            #expect(sidebar.describeShortcutSections() == ["Favourites (open): fq_fav_c (missing)"])
            #expect(AppEnvironment.favourites.recent(for: controller.workspace.config.id).isEmpty)
            await close(controller, url)
        }
    }
}

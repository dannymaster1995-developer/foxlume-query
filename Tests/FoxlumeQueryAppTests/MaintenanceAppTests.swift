import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

extension AppCompletionTests {
    /// Maintenance through the window on a scratch SQLite file: the sidebar's multi-selection, both submenus, Safe
    /// Mode on a Read-Only connection and the results sheet.
    @Suite("Maintenance")
    @MainActor
    struct MaintenanceAppTests {
        private func scratchURL() -> URL {
            let directory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
            return directory.appendingPathComponent("maintenance-\(UUID().uuidString).sqlite")
        }

        private func makeWindow(_ url: URL, readOnly: Bool = false) async throws -> WorkspaceWindowController {
            let workspace = ConnectionWorkspace(config: ConnectionConfig(name: "fqtest", kind: .sqlite, filePath: url.path, readOnly: readOnly), password: "")
            try await workspace.connect()
            let controller = WorkspaceWindowController(workspace: workspace)
            // On screen, so the results sheet attaches to the window as it does for a user.
            controller.window?.orderFront(nil)
            return controller
        }

        private func close(_ controller: WorkspaceWindowController, _ url: URL) async {
            let id = controller.workspace.config.id
            controller.window?.close()
            await controller.workspace.disconnect()
            try? FileManager.default.removeItem(at: AppPaths.tabStateDirectory.appendingPathComponent(id.uuidString + ".json"))
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }

        private func createTables(_ url: URL) async throws {
            let session = DatabaseSession(parameters: ConnectionParameters(config: ConnectionConfig(kind: .sqlite, filePath: url.path), password: ""))
            try await session.connect()
            _ = try await session.execute("CREATE TABLE fq_mt_a (id INTEGER PRIMARY KEY); CREATE TABLE fq_mt_b (id INTEGER PRIMARY KEY); CREATE VIEW fq_mt_v AS SELECT id FROM fq_mt_a")
            await session.close()
        }

        private func titles(_ items: [NSMenuItem], in controller: WorkspaceWindowController) -> [String] {
            items.map { item in
                if item.isSeparatorItem { return "-" }
                return controller.validateMenuItem(item) ? item.title : "[\(item.title)]"
            }
        }

        @Test func multiSelectionDrivesBothMenusAndTheRun() async throws {
            let url = scratchURL()
            try await createTables(url)
            let controller = try await makeWindow(url)
            defer { Task { await close(controller, url) } }
            let sidebar = controller.sidebarController
            sidebar.select([TableRef(name: "fq_mt_a"), TableRef(name: "fq_mt_b"), TableRef(name: "fq_mt_v")])
            #expect(sidebar.selectedTableInfos.map(\.name) == ["fq_mt_a", "fq_mt_b", "fq_mt_v"])
            #expect(sidebar.maintenanceMenuTitles(background: false) == ["Analyze", "Integrity Check", "-", "Vacuum Database"])
            #expect(sidebar.maintenanceMenuTitles(background: true) == ["Integrity Check", "-", "Vacuum Database"])
            #expect(sidebar.menuTitlesForSelection().contains("Maintenance"))

            let menu = NSMenu()
            controller.fillMaintenanceMenu(menu)
            #expect(titles(menu.items, in: controller) == ["Analyze", "Integrity Check", "-", "Vacuum Database"])

            // The view is left out of the statements; the sheet fills in a row per table.
            controller.performMaintenance(.integrityCheck, on: controller.maintenanceTargets)
            await settle(until: { MaintenanceController.presented?.model.isRunning == false && MaintenanceController.presented?.model.rows.allSatisfy { $0.outcome.status.isFinished } == true }, seconds: 10)
            let model = try #require(MaintenanceController.presented?.model)
            #expect(model.rows.map(\.target) == ["fq_mt_a", "fq_mt_b"])
            #expect(model.rows.map(\.outcome.status) == [.ok, .ok])
            #expect(model.resultText.hasPrefix("fq_mt_a\tOK\t"))
            // While the sheet is up, the menu does not start a second run.
            #expect(titles(controller.maintenanceItems(for: controller.maintenanceTargets, hidingRefused: false), in: controller).first == "[Analyze]")
            MaintenanceController.presented?.dismiss()
            #expect(controller.window?.attachedSheet == nil)
        }

        @Test func readOnlyKeepsOnlyTheIntegrityCheck() async throws {
            let url = scratchURL()
            try await createTables(url)
            let controller = try await makeWindow(url, readOnly: true)
            defer { Task { await close(controller, url) } }
            let sidebar = controller.sidebarController
            sidebar.select([TableRef(name: "fq_mt_a")])
            #expect(sidebar.maintenanceMenuTitles(background: false) == ["Integrity Check"])
            let items = controller.maintenanceItems(for: controller.maintenanceTargets, hidingRefused: false)
            #expect(titles(items, in: controller) == ["[Analyze]", "Integrity Check", "-", "[Vacuum Database]"])
            #expect(items.first?.toolTip == "This connection is read-only")
        }
    }
}

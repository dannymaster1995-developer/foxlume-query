import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

extension AppCompletionTests {
    @Suite("Tab strip")
    @MainActor
    struct TabStripAppTests {
        /// A workspace window on a scratch SQLite database, 1200 pt wide.
        private func makeWindow() async throws -> (WorkspaceWindowController, URL) {
            let directory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
            let url = directory.appendingPathComponent("tab-strip-\(UUID().uuidString).sqlite")
            let workspace = ConnectionWorkspace(config: ConnectionConfig(name: "fqtest", kind: .sqlite, filePath: url.path), password: "")
            try await workspace.connect()
            let controller = WorkspaceWindowController(workspace: workspace)
            let window = try #require(controller.window)
            window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 760), display: false)
            window.layoutIfNeeded()
            return (controller, url)
        }

        private func tearDown(_ controller: WorkspaceWindowController, _ url: URL) {
            let id = controller.workspace.config.id
            controller.window?.close()
            try? FileManager.default.removeItem(at: AppPaths.tabStateDirectory.appendingPathComponent(id.uuidString + ".json"))
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }

        private func settleLayout(_ controller: WorkspaceWindowController) {
            controller.window?.layoutIfNeeded()
            controller.tabs.strip.layoutSubtreeIfNeeded()
        }

        private func titles(_ controller: WorkspaceWindowController, _ ids: [UUID]) -> [String] {
            ids.map { id in controller.tabs.tabs.first { $0.id == id }?.content.tabTitle ?? "?" }
        }

        @Test func manyTabsKeepTheWindowWidthAndOverflowIntoTheMenu() async throws {
            let (controller, url) = try await makeWindow()
            defer { tearDown(controller, url) }
            let window = try #require(controller.window)
            let tabs = controller.tabs
            let strip = tabs.strip
            for _ in 0..<20 { tabs.openQuery() }
            settleLayout(controller)

            #expect(window.frame.width == 1200, "opening tabs must not widen the window")
            #expect(window.minSize.width == 760)
            let visible = strip.visibleIDs.count
            #expect(visible >= 3 && visible < 20, "\(visible) tabs shown")
            #expect(strip.hiddenIDs.count == 20 - visible)
            #expect(strip.tabWidth >= 120 && strip.tabWidth <= 240)
            #expect(strip.visibleIDs.contains(try #require(tabs.selectedTab?.id)))
            // The newest tabs show; the hidden ones are listed in tab order.
            #expect(titles(controller, strip.visibleIDs).last == "Query 20")
            let menu = strip.overflowMenu()
            #expect(menu.items.map(\.title) == titles(controller, strip.hiddenIDs))
            #expect(menu.items.first?.title == "Query 1")

            // Picking a hidden tab selects it and brings it into view in place of the least recently used one.
            let shownBefore = strip.visibleIDs
            menu.performActionForItem(at: 0)
            settleLayout(controller)
            let first = tabs.tabs[0].id
            #expect(tabs.selectedTab?.id == first)
            #expect(strip.visibleIDs.first == first)
            #expect(strip.visibleIDs.count == visible)
            #expect(Set(strip.visibleIDs).subtracting(shownBefore) == [first])
            #expect(!strip.visibleIDs.contains(shownBefore[0]), "the least recently used shown tab makes room")

            // Clicking a shown tab does not change which tabs show.
            let shown = strip.visibleIDs
            tabs.select(id: shown[1])
            settleLayout(controller)
            #expect(strip.visibleIDs == shown)

            // Tab shortcuts reach hidden tabs too.
            let hiddenIndex = try #require(tabs.tabs.firstIndex { !strip.visibleIDs.contains($0.id) })
            tabs.selectTab(at: hiddenIndex)
            settleLayout(controller)
            #expect(strip.visibleIDs.contains(tabs.tabs[hiddenIndex].id))
            tabs.selectNext(offset: 1)
            settleLayout(controller)
            #expect(strip.visibleIDs.contains(try #require(tabs.selectedTab?.id)))
            #expect(window.frame.width == 1200)
        }

        @Test func resizingTheWindowChangesHowManyTabsFit() async throws {
            let (controller, url) = try await makeWindow()
            defer { tearDown(controller, url) }
            let window = try #require(controller.window)
            let tabs = controller.tabs
            let strip = tabs.strip
            for _ in 0..<15 { tabs.openQuery() }
            settleLayout(controller)
            let atDefault = strip.visibleIDs.count

            window.setFrame(NSRect(x: 100, y: 100, width: 1700, height: 760), display: false)
            settleLayout(controller)
            #expect(window.frame.width == 1700)
            #expect(strip.visibleIDs.count > atDefault)

            window.setFrame(NSRect(x: 100, y: 100, width: 800, height: 760), display: false)
            settleLayout(controller)
            #expect(window.frame.width == 800)
            #expect(strip.visibleIDs.count < atDefault)
            #expect(strip.visibleIDs.count >= 1)
            #expect(strip.visibleIDs.contains(try #require(tabs.selectedTab?.id)))
            #expect(strip.hiddenIDs.count == 15 - strip.visibleIDs.count)

            // Closing tabs until all fit hides the "+N" button.
            while tabs.tabs.count > 2 { tabs.closeSelected() }
            settleLayout(controller)
            #expect(strip.hiddenIDs.isEmpty)
            #expect(strip.overflowMenu().items.isEmpty)
            #expect(strip.visibleIDs.count == 2)
            #expect(strip.tabWidth == 240)

            // Reopen Closed Tab still works and the reopened tab shows.
            tabs.reopenClosedTab()
            settleLayout(controller)
            #expect(tabs.tabs.count == 3)
            #expect(strip.visibleIDs.contains(try #require(tabs.selectedTab?.id)))
        }

        @Test func windowsLargerThanTheScreenAreClamped() {
            let screen = NSRect(x: 0, y: 25, width: 1512, height: 920)
            // A window grown to 7200 pt comes back inside the screen.
            let wide = WorkspaceWindowController.clamped(NSRect(x: -200, y: 40, width: 7200, height: 800), to: screen)
            #expect(wide == NSRect(x: 0, y: 40, width: 1512, height: 800))
            // One partly off the right and top edges moves back in without shrinking.
            #expect(WorkspaceWindowController.clamped(NSRect(x: 900, y: 300, width: 1000, height: 700), to: screen) == NSRect(x: 512, y: 245, width: 1000, height: 700))
            // One that already fits is left alone.
            let fits = NSRect(x: 100, y: 100, width: 1200, height: 760)
            #expect(WorkspaceWindowController.clamped(fits, to: screen) == fits)
        }
    }
}

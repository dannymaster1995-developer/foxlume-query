import AppKit
import FoxlumeQueryCore

/// Scripted commands for the tab strip and its "+N" overflow menu.
///
///     querytabs <n>               opens n empty query tabs
///     tabstrip                    logs the window and strip widths, the shown tabs ([selected]) and the hidden ones
///     overflowmenu                logs the titles in the "+N" menu
///     overflowpick <title>        chooses that tab from the "+N" menu
///     windowsize <width>x<height> resizes the workspace window, keeping its top left corner
@MainActor
enum TabsAutoTest {
    static let commands: Set<String> = ["querytabs", "tabstrip", "overflowmenu", "overflowpick", "windowsize"]
}

extension AutoTestRunner {
    func performTabs(_ command: String, _ argument: String) async throws {
        guard let window = workspace, let nsWindow = window.window else { throw DatabaseError.notConnected }
        let tabs = window.tabs
        let strip = tabs.strip
        func title(_ id: UUID) -> String {
            let name = tabs.tabs.first { $0.id == id }?.content.tabTitle ?? "?"
            return id == tabs.selectedTab?.id ? "[\(name)]" : name
        }
        switch command {
        case "querytabs":
            for _ in 0..<(Int(argument) ?? 1) { tabs.openQuery() }
            try await Task.sleep(nanoseconds: 300_000_000)
        case "tabstrip":
            strip.layoutSubtreeIfNeeded()
            record("  window: \(Int(nsWindow.frame.width))x\(Int(nsWindow.frame.height)); strip: \(Int(strip.bounds.width)); tab width: \(Int(strip.tabWidth)); tabs: \(tabs.tabs.count)")
            record("  visible (\(strip.visibleIDs.count)): " + strip.visibleIDs.map(title).joined(separator: " | "))
            record("  hidden (\(strip.hiddenIDs.count)): " + strip.hiddenIDs.map(title).joined(separator: " | "))
        case "overflowmenu":
            record("  menu: " + strip.overflowMenu().items.map(\.title).joined(separator: " | "))
        case "overflowpick":
            let menu = strip.overflowMenu()
            guard let index = menu.items.firstIndex(where: { $0.title == argument }) else {
                throw DatabaseError.unsupported("No hidden tab named \(argument)")
            }
            menu.performActionForItem(at: index)
            try await Task.sleep(nanoseconds: 300_000_000)
        case "windowsize":
            let size = argument.split(separator: "x").compactMap { Double($0) }
            guard size.count == 2 else { throw DatabaseError.unsupported("windowsize <width>x<height>") }
            var frame = nsWindow.frame
            frame.origin.y += frame.height - size[1]
            frame.size = NSSize(width: size[0], height: size[1])
            nsWindow.setFrame(frame, display: true)
            try await Task.sleep(nanoseconds: 400_000_000)
        default:
            break
        }
    }
}

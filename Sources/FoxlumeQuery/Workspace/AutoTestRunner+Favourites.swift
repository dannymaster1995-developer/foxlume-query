import AppKit
import FoxlumeQueryCore

/// Scripted commands for the sidebar's Favourites and Recent sections.
///
///     favourite <name>                adds or removes a table, view or object of the browsed schema, as its star does
///     favouritemenu                   logs Database › Add to Favourites as the menu shows it now (title, enabled)
///     favouritekey                    chooses Database › Add to Favourites (⌥⌘B) for the selected tab or sidebar row
///     favourites                      logs the Favourites and Recent sections ([location], (missing), open or closed)
///     openfavourite <name>            opens a Favourites row as a click does (switching database when needed)
///     openrecent <name>               opens a Recent row the same way
///     shortcutmenu favourites|recent <name>   logs that row's context menu
///     removerecent <name>             Remove from Recent on that row
///     clearrecent                     Clear Recent
///     movefavourite <name> [<before>] moves a favourite in front of another one, or to the end, as dragging does
///     favouritesection favourites|recent open|closed   expands or collapses a section
///     hovertable <name>               puts the mouse over a table's row in the tree, which shows its star
@MainActor
enum FavouritesAutoTest {
    static let commands: Set<String> = [
        "favourite", "favouritemenu", "favouritekey", "favourites", "openfavourite", "openrecent", "shortcutmenu", "removerecent",
        "clearrecent", "movefavourite", "favouritesection", "hovertable",
    ]
}

extension AutoTestRunner {
    func performFavourites(_ command: String, _ argument: String) async throws {
        guard let window = workspace else { throw DatabaseError.notConnected }
        let sidebar = window.sidebarController
        let connection = window.workspace.config.id
        let store = AppEnvironment.favourites
        func favourite(named name: String) throws -> SidebarItemRef {
            guard let item = store.favourites(for: connection).first(where: { $0.name == name }) else {
                throw DatabaseError.unsupported("No favourite named \(name)")
            }
            return item
        }
        switch command {
        case "favourite":
            if let info = window.workspace.tables.first(where: { $0.name == argument }), let item = sidebar.sidebarItem(info) {
                sidebar.toggleFavourite(item)
            } else if let object = window.workspace.schemaObjects.first(where: { $0.name == argument }), let item = sidebar.sidebarItem(object) {
                sidebar.toggleFavourite(item)
            } else {
                throw DatabaseError.unsupported("favourite <table or object of the browsed schema>")
            }
            record("  \(argument): " + (store.favourites(for: connection).contains { $0.name == argument } ? "favourite" : "not a favourite"))
        case "favouritemenu":
            let item = NSMenuItem(title: "Add to Favourites", action: #selector(WorkspaceWindowController.toggleFavourite(_:)), keyEquivalent: "")
            let enabled = window.validateMenuItem(item)
            record("  \(item.title): \(enabled ? "enabled" : "disabled")")
        case "favouritekey":
            window.toggleFavourite(nil)
        case "favourites":
            try await Task.sleep(nanoseconds: UInt64(NSEvent.doubleClickInterval * 1_000_000_000) + 200_000_000)
            sidebar.reload()
            let lines = sidebar.describeShortcutSections()
            record("  " + (lines.isEmpty ? "(no sections)" : lines.joined(separator: " | ")))
        case "openfavourite", "openrecent":
            guard sidebar.openShortcut(command == "openfavourite" ? .favourites : .recent, named: argument) else {
                throw DatabaseError.unsupported("No openable row \(argument)")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            try await waitFor(seconds: 20) { !window.workspace.isLoadingTables && window.workspace.runningStatements == 0 }
            try await Task.sleep(nanoseconds: 300_000_000)
            record("  tab: \(window.tabs.selectedTab?.content.tabTitle ?? "none") in \(window.workspace.currentDatabase ?? "-")")
        case "shortcutmenu":
            let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard words.count == 2, let section = FavouritesStore.Section(rawValue: words[0]),
                  let titles = sidebar.shortcutMenuTitles(section, named: words[1]) else {
                throw DatabaseError.unsupported("shortcutmenu favourites|recent <name>")
            }
            record("  " + titles.joined(separator: " | "))
        case "removerecent":
            guard let item = store.recent(for: connection).first(where: { $0.name == argument }) else { throw DatabaseError.unsupported("No recent \(argument)") }
            try store.removeRecent(item, connection: connection)
            sidebar.reload()
        case "clearrecent":
            try store.clearRecent(connection: connection)
            sidebar.reload()
        case "movefavourite":
            let words = argument.split(separator: " ").map(String.init)
            guard let name = words.first else { throw DatabaseError.unsupported("movefavourite <name> [<before>]") }
            sidebar.moveFavourite(try favourite(named: name), before: try words.dropFirst().first.map { try favourite(named: $0) })
        case "favouritesection":
            let words = argument.split(separator: " ").map(String.init)
            guard words.count == 2, let section = FavouritesStore.Section(rawValue: words[0]) else {
                throw DatabaseError.unsupported("favouritesection favourites|recent open|closed")
            }
            sidebar.setGroup(section == .favourites ? "Favourites" : "Recent", expanded: words[1] == "open")
        case "hovertable":
            guard let row = sidebar.row(ofTable: argument) else { throw DatabaseError.unsupported("No table row \(argument)") }
            sidebar.setHoveredRow(row)
            record("  star shown: \(sidebar.isStarShown(atRow: row))")
        default:
            break
        }
    }
}

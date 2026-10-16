import AppKit
import FoxlumeQueryCore

/// Scripted commands for New View…, Edit View… and Refresh Materialized View. Views are named as the sidebar lists them.
///
///     newview <name>              New View… without the prompt: the template in a new tab
///     newviewprompt [name]        shows the New View prompt with the name filled in (answer with confirm)
///     editview <name>             Edit View…; logs the new tab's text
///     setsql <text>               replaces the selected query tab's text, undoably (\n for line breaks)
///     saveview                    Save View in the selected tab; logs the status, a failure and the sidebar selection
///     refreshmatview <name>       Refresh Materialized View
///     sidebarselection            logs the row selected in the sidebar
///     views [prefix]              logs the views the sidebar lists, with their kind
@MainActor
enum ViewsAutoTest {
    static let commands: Set<String> = ["newview", "newviewprompt", "editview", "setsql", "saveview", "refreshmatview", "sidebarselection", "views"]
}

extension AutoTestRunner {
    func performViews(_ command: String, _ argument: String) async throws {
        guard let window = workspace else { throw DatabaseError.notConnected }
        func view(_ name: String) throws -> TableInfo {
            guard let info = window.workspace.tables.first(where: { $0.name == name && ($0.kind == .view || $0.kind == .materializedView) }) else {
                throw DatabaseError.unsupported("No view named \(name)")
            }
            return info
        }
        func queryTab() throws -> QueryTabViewController {
            guard let query = window.tabs.selectedTab?.content as? QueryTabViewController else { throw DatabaseError.unsupported("\(command) needs a query tab") }
            return query
        }
        func logText(_ query: QueryTabViewController) {
            record("  \(query.tabTitle): " + query.sql.replacingOccurrences(of: "\n", with: " | "))
        }
        switch command {
        case "newview":
            window.openNewViewEditor(name: argument, schema: window.workspace.currentSchema)
            try await Task.sleep(nanoseconds: 300_000_000)
            logText(try queryTab())
        case "newviewprompt":
            window.presentNewViewPrompt(name: argument)
            try await Task.sleep(nanoseconds: 500_000_000)
        case "editview":
            let info = try view(argument)
            window.editView(info)
            try await waitFor(seconds: 20) { (window.tabs.selectedTab?.content as? QueryTabViewController)?.tabTitle == "Edit \(info.name)" }
            try await Task.sleep(nanoseconds: 300_000_000)
            logText(try queryTab())
        case "setsql":
            try queryTab().replaceSQL(Self.queryText(argument), actionName: "Script")
        case "saveview":
            let query = try queryTab()
            query.saveView(nil)
            try await Task.sleep(nanoseconds: 300_000_000)
            try await waitFor(seconds: 30) { !query.isRunning }
            // The sidebar selection follows once the catalog is reloaded; a refused replace shows a question instead.
            try await Task.sleep(nanoseconds: 800_000_000)
            record("  status: \(query.resultStatus); sidebar: \(window.sidebarSelection?.name ?? "-")")
        case "refreshmatview":
            window.refreshMaterializedView(try view(argument))
            try await Task.sleep(nanoseconds: 300_000_000)
            try await waitFor(seconds: 30) { window.workspace.runningStatements == 0 }
        case "sidebarselection":
            record("  sidebar: \(window.sidebarSelection.map { [$0.schema, $0.name].compactMap { $0 }.joined(separator: ".") } ?? "-")")
        case "views":
            let views = window.workspace.tables.filter { ($0.kind == .view || $0.kind == .materializedView) && $0.name.hasPrefix(argument) }
            record("  views: " + (views.isEmpty ? "none" : views.map { "\($0.name) (\($0.kind == .view ? "view" : "materialized"))" }.joined(separator: ", ")))
        default:
            break
        }
    }
}

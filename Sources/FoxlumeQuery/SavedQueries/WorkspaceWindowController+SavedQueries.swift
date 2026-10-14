import AppKit
import FoxlumeQueryCore

/// Saving queries from a query tab or the history, and opening, running or inserting saved ones. Saved queries never
/// run by themselves: Run goes through the query tab's run path, so Safe Mode and read-only connections apply.
extension WorkspaceWindowController {
    /// Query › Add to Saved Queries… (⌘D): the selection, or the whole text of the query tab.
    @objc func addToSavedQueries(_ sender: Any?) {
        guard let query = tabs.selectedTab?.content as? QueryTabViewController, !query.textForSaving.isEmpty else { return NSSound.beep() }
        presentSaveQuery(sql: query.textForSaving)
    }

    /// The New Saved Query sheet with `sql`, for this connection only; the new query is selected in the sidebar.
    func presentSaveQuery(sql: String) {
        guard let window else { return }
        SavedQuerySheet(workspace: workspace, sql: sql).begin(for: window) { [weak self] saved in
            guard let self, let saved else { return }
            self.showSavedQueries(nil)
            self.savedQueriesList.select(id: saved.id)
        }
    }

    /// View › Saved Queries: shows the sidebar on its Saved Queries side.
    @objc func showSavedQueries(_ sender: Any?) {
        if let sidebarItem = splitItems.first, sidebarItem.isCollapsed {
            sidebarItem.isCollapsed = false
        }
        sidebarContainer.show(.savedQueries)
    }

    /// Fills the selected query tab when it is empty, otherwise opens a new one; never runs.
    func openSavedQuery(_ query: SavedQuery, newTab: Bool) {
        openSQL(query.sql, title: query.name, newTab: newTab)
    }

    /// Opens a query tab for the saved query and runs it the way Run All does.
    func runSavedQuery(_ query: SavedQuery) {
        tabs.openQuery(sql: query.sql, run: true, title: query.name)
    }

    /// Adds the query to the editor in front: its whole text when the editor is empty, otherwise after a blank line.
    func insertSavedQuery(_ query: SavedQuery) {
        guard let editor = tabs.selectedTab?.content as? QueryTabViewController else {
            return openSavedQuery(query, newTab: true)
        }
        editor.appendSQL(query.sql)
    }

    /// SQL from a saved query, the history or Open Quickly: into the selected query tab if it is empty, otherwise
    /// into a new query tab. Nothing runs.
    func openSQL(_ sql: String, title: String?, newTab: Bool) {
        if !newTab, let query = tabs.selectedTab?.content as? QueryTabViewController, query.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query.setSQL(sql)
        } else {
            tabs.openQuery(sql: sql, title: title)
        }
    }

    /// The sidebar's callbacks to this window.
    func connectSavedQueries() {
        savedQueriesList.onOpen = { [weak self] query, newTab in self?.openSavedQuery(query, newTab: newTab) }
        savedQueriesList.onRun = { [weak self] query in self?.runSavedQuery(query) }
        savedQueriesList.onInsert = { [weak self] query in self?.insertSavedQuery(query) }
    }

    /// Menu state for the saved query commands; nil for other actions.
    func validateSavedQueriesItem(_ action: Selector?) -> Bool? {
        switch action {
        case #selector(addToSavedQueries(_:)):
            guard let query = tabs.selectedTab?.content as? QueryTabViewController else { return false }
            return !query.textForSaving.isEmpty
        case #selector(showSavedQueries(_:)):
            return true
        default:
            return nil
        }
    }
}

extension AppDelegate {
    /// Tells the user once when saved-queries.json was damaged and set aside, as for the connection list.
    func reportUnreadableSavedQueries() {
        _ = AppEnvironment.savedQueries.library
        guard let aside = AppEnvironment.savedQueries.setAsideFile else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some saved queries could not be read"
        alert.informativeText = "The saved queries file was damaged. Queries that could still be read are kept, and the original file was saved as “\(aside.lastPathComponent)” in the app's data folder so nothing is lost."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show File")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([aside])
        }
    }
}

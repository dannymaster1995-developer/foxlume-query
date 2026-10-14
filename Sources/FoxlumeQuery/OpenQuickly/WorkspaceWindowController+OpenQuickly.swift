import AppKit
import FoxlumeQueryCore

/// File › Open Quickly… (⇧⌘O) and what choosing a row does.
extension WorkspaceWindowController {
    /// Shows the panel over this window, or closes it when it is already showing here.
    @objc func openQuickly(_ sender: Any?) {
        if let current = OpenQuicklyController.current {
            let here = current.host === self
            current.close()
            if here { return }
        }
        let controller = OpenQuicklyController(host: self, others: otherWorkspaceWindows)
        controller.onCommit = { [weak self] item, newTab in self?.openQuicklyItem(item, newTab: newTab) }
        controller.onOpenStructure = { [weak self] item in
            guard case .table(let ref) = item.target else { return }
            self?.tabs.openTable(ref, newTab: true, mode: .structure)
        }
        controller.present()
    }

    /// The other open connections, each in its own window.
    private var otherWorkspaceWindows: [WorkspaceWindowController] {
        ((NSApp.delegate as? AppDelegate)?.workspaces ?? []).filter { $0 !== self }
    }

    /// Opens an Open Quickly item: a table opens or selects its tab, a database or schema is switched to (table edits
    /// are guarded as in the toolbar), a saved query or history entry goes into a query tab without running.
    /// Items of another connection open in that connection's window, which comes to the front.
    func openQuicklyItem(_ item: QuickOpenItem, newTab: Bool) {
        let target: WorkspaceWindowController
        if item.isCurrentConnection {
            target = self
        } else if let other = otherWorkspaceWindows.first(where: { $0.workspace.config.id == item.connectionID }) {
            target = other
            other.window?.makeKeyAndOrderFront(nil)
        } else {
            return Alerts.showError(DatabaseError.unsupported("“\(item.connectionName)” is no longer open."), title: "Could not open “\(item.title)”", in: window)
        }
        switch item.target {
        case .table(let ref):
            target.tabs.openTable(ref, newTab: newTab)
        case .database(let name):
            target.requestDatabaseSwitch(to: name)
        case .schema(let name):
            Task { await target.workspace.switchSchema(name) }
        case .savedQuery(let id):
            guard let query = AppEnvironment.savedQueries.query(id: id) else { return NSSound.beep() }
            target.openSavedQuery(query, newTab: newTab)
        case .history:
            target.openSQL(item.sql ?? item.title, title: nil, newTab: newTab)
        case .schemaObject(let object):
            target.openObjectSource(object)
        }
    }
}

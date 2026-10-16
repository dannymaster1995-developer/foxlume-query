import AppKit
import FoxlumeQueryCore

/// Database › Server Activity (⌥⌘A): the server's sessions and slow queries in a window of their own, for PostgreSQL,
/// MySQL and MariaDB. See ServerActivityWindowController.swift.
extension WorkspaceWindowController {
    @objc func showServerActivity(_ sender: Any?) {
        guard workspace.supportsServerActivity, workspace.connectionState == .connected else { return NSSound.beep() }
        if let existing = serverActivityController {
            existing.showWindow(nil)
            return
        }
        let controller = ServerActivityWindowController(
            workspace: workspace,
            windows: { (NSApp.delegate as? AppDelegate)?.workspaces.map(\.workspace) ?? [] },
            openQuery: { [weak self] text in
                guard let self else { return }
                self.tabs.openQuery(sql: text)
                self.window?.makeKeyAndOrderFront(nil)
            }
        )
        controller.onClose = { [weak self] in self?.serverActivityController = nil }
        serverActivityController = controller
        controller.showWindow(nil)
    }

    /// Menu validation for Server Activity, called from `validateMenuItem`: hidden for engines without it.
    func validateActivityItem(_ menuItem: NSMenuItem) -> Bool? {
        guard menuItem.action == #selector(showServerActivity(_:)) else { return nil }
        menuItem.isHidden = !workspace.supportsServerActivity
        return workspace.supportsServerActivity && workspace.connectionState == .connected
    }
}

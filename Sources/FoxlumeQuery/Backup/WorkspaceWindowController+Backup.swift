import AppKit
import FoxlumeQueryCore

/// Database › Backup… and Restore…, and the sidebar's Backup entries (a table, the empty area, the schema picker).
/// See BackupSheet.swift and RestoreSheet.swift.
extension WorkspaceWindowController {
    /// Database › Backup…: the tables selected in the sidebar, else the whole database.
    @objc func backupDatabase(_ sender: Any?) {
        let selected = sidebarController.selectedTableInfos.map(\.ref)
        presentBackup(selected.isEmpty ? .database : .tables(selected))
    }

    /// Database › Restore…: chooses the file first, then shows the sheet.
    @objc func restoreDatabase(_ sender: Any?) {
        presentRestore(file: nil)
    }

    func presentBackup(_ request: BackupRequest) {
        guard workspace.supportsBackup, workspace.connectionState == .connected else { return NSSound.beep() }
        BackupController(workspace: workspace, request: request, parent: window).present()
    }

    func presentRestore(file: URL?) {
        guard workspace.supportsBackup, workspace.connectionState == .connected else { return NSSound.beep() }
        if workspace.isReadOnly {
            return Alerts.showError(DatabaseError.unsupported("This connection is read-only. Restores are not run."), title: "Read-only connection", in: window)
        }
        let show: (URL) -> Void = { [weak self] url in
            guard let self else { return }
            RestoreController(workspace: self.workspace, file: url, parent: self.window, onFinished: { [weak self] in
                guard let self else { return }
                Task { await self.workspace.refreshMetadata() }
            }, openRunSQLFile: { [weak self] file, database in
                self?.presentRestoreScript(file, into: database)
            }).present()
        }
        if let file { return show(file) }
        let panel = RestoreController.openPanel()
        guard let window else {
            if panel.runModal() == .OK, let url = panel.url { show(url) }
            return
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async { show(url) }
        }
    }

    /// A plain script from Restore runs in the Run SQL File sheet, in the chosen database; Restore confirmed already.
    private func presentRestoreScript(_ file: URL, into database: String) {
        let controller = RunSQLFileController(workspace: workspace, file: file, database: database, parent: window) { [weak self] in
            guard let self else { return }
            Task { await self.workspace.refreshMetadata() }
        }
        controller.model.confirm = { proceed in proceed() }
        controller.present()
    }

    /// Menu validation for Backup and Restore, called from `validateMenuItem`.
    func validateBackupItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(backupDatabase(_:)):
            return workspace.supportsBackup && workspace.connectionState == .connected && window?.attachedSheet == nil
        case #selector(restoreDatabase(_:)):
            if workspace.supportsBackup { menuItem.toolTip = workspace.isReadOnly ? "This connection is read-only" : nil }
            return workspace.supportsBackup && !workspace.isReadOnly && workspace.connectionState == .connected && window?.attachedSheet == nil
        default:
            return nil
        }
    }

    /// Connects the sidebar's Backup and Restore items.
    func connectBackup(_ sidebar: SidebarViewController) {
        sidebar.onBackup = { [weak self] request in self?.presentBackup(request) }
        sidebar.onRestore = { [weak self] in self?.presentRestore(file: nil) }
    }
}

import AppKit
import FoxlumeQueryCore
import UniformTypeIdentifiers

/// File menu and sidebar entry points of Export Tables, Import CSV and Run SQL File.
extension WorkspaceWindowController {
    /// File > Export Tables… (⌥⇧⌘E): ticks the table selected in the sidebar, if any.
    @objc func exportTables(_ sender: Any?) {
        presentExport(preselecting: sidebarSelection.map { [$0] } ?? [])
    }

    func presentExport(preselecting tables: [TableRef]) {
        guard workspace.supportsTableTransfer else { return NSSound.beep() }
        ExportTablesController(workspace: workspace, preselected: Set(tables), parent: window).present()
    }

    /// File > Import CSV into Table… (⇧⌘I): chooses the file first, then shows the mapping sheet.
    @objc func importCSV(_ sender: Any?) {
        let selected = sidebarSelection.flatMap { ref in workspace.importableTables.first { $0.ref == ref }?.ref }
        presentImportCSV(into: selected)
    }

    func presentImportCSV(into table: TableRef?, file: URL? = nil) {
        guard canImport() else { return }
        let show: (URL) -> Void = { [weak self] url in
            guard let self else { return }
            ImportCSVController(workspace: self.workspace, table: table, file: url, parent: self.window) { [weak self] imported in
                guard let self else { return }
                self.tabs.reloadTabs(showing: imported)
                Task { await self.workspace.refreshMetadata() }
            }.present()
        }
        if let file { return show(file) }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a CSV or TSV file to import" + (table.map { " into \($0.name)" } ?? "")
        open(panel) { url in show(url) }
    }

    /// File > Run SQL File…: chooses the file first, then shows the sheet with its preview and options.
    @objc func runSQLFile(_ sender: Any?) {
        presentRunSQLFile(file: nil)
    }

    func presentRunSQLFile(file: URL?) {
        guard canImport() else { return }
        let show: (URL) -> Void = { [weak self] url in
            guard let self else { return }
            RunSQLFileController(workspace: self.workspace, file: url, parent: self.window) { [weak self] in
                guard let self else { return }
                Task {
                    await self.workspace.refreshMetadata()
                    if let table = self.tabs.selectedTab?.table { self.tabs.reloadTabs(showing: table) }
                }
            }.present()
        }
        if let file { return show(file) }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .gzip, .plainText]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a .sql or .sql.gz file to run"
        open(panel) { url in show(url) }
    }

    private func open(_ panel: NSOpenPanel, then completion: @escaping (URL) -> Void) {
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard let window else {
            if panel.runModal() == .OK, let url = panel.url { completion(url) }
            return
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            // Let the panel's sheet finish closing before the next sheet attaches to the window.
            DispatchQueue.main.async { completion(url) }
        }
    }

    private func canImport() -> Bool {
        guard workspace.supportsTableTransfer else {
            NSSound.beep()
            return false
        }
        if workspace.isReadOnly {
            Alerts.showError(DatabaseError.unsupported("This connection is read-only. Imports are not run."), title: "Read-only connection", in: window)
            return false
        }
        return true
    }

    /// Menu validation for the transfer commands, called from `validateMenuItem`.
    func validateTransferItem(_ action: Selector?) -> Bool? {
        switch action {
        case #selector(exportTables(_:)):
            return workspace.supportsTableTransfer
        case #selector(importCSV(_:)), #selector(runSQLFile(_:)):
            return workspace.supportsTableTransfer && !workspace.isReadOnly
        default:
            return nil
        }
    }
}

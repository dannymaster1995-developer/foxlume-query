import AppKit
import FoxlumeQueryCore

/// Create Table, reached from the Database menu and the sidebar.
extension WorkspaceWindowController {
    @objc func newTable(_ sender: Any?) {
        guard workspace.canChangeStructure, let window, window.attachedSheet == nil,
              let controller = CreateTableController(workspace: workspace)
        else { return NSSound.beep() }
        controller.onCreated = { [weak self] table in self?.openCreatedTable(table) }
        controller.begin(for: window)
    }

    /// The catalog is already reloaded; a table made in another schema switches the sidebar there first.
    private func openCreatedTable(_ table: TableRef) {
        Task {
            if let schema = table.schema, workspace.kind.supportsSchemas, schema != workspace.currentSchema {
                await workspace.switchSchema(schema)
            }
            tabs.openTable(table, newTab: true)
        }
    }
}

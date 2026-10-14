import AppKit
import FoxlumeQueryCore

/// Database › ER Diagram, the sidebar's "ER Diagram" and a table's "Show in ER Diagram".
extension WorkspaceWindowController {
    func connectERDiagram(_ sidebar: SidebarViewController) {
        sidebar.onShowERDiagram = { [weak self] table in
            if let table {
                self?.showInERDiagram(table)
            } else {
                self?.showERDiagram(nil)
            }
        }
    }

    /// The diagram of the schema the sidebar shows (MySQL: the current database).
    @objc func showERDiagram(_ sender: Any?) {
        guard workspace.supportsERDiagram else { return NSSound.beep() }
        tabs.openERDiagram(database: workspace.currentDatabase, schema: workspace.diagramSchema)
    }

    /// Opens (or selects) the diagram of the table's schema with that table selected and in view.
    @discardableResult
    func showInERDiagram(_ table: TableRef) -> ERDiagramViewController? {
        guard workspace.supportsERDiagram else { return nil }
        let schema = workspace.kind.supportsSchemas ? (table.schema ?? workspace.currentSchema) : nil
        return tabs.openERDiagram(database: workspace.currentDatabase, schema: schema, focusing: table.name)
    }

    func validateDiagramItem(_ action: Selector?) -> Bool? {
        guard action == #selector(showERDiagram(_:)) else { return nil }
        return workspace.supportsERDiagram && workspace.connectionState == .connected
    }
}

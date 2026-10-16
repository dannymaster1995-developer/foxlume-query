import AppKit
import FoxlumeQueryCore

/// What a view row or the sidebar's empty area asks the window to do.
enum ViewCommand {
    case new
    case edit(TableInfo)
    case refresh(TableInfo)
}

/// New View… (Database menu and sidebar), Edit View… and Refresh Materialized View (a view's row). New and Edit open a
/// query tab with Save View; see QueryTabViewController+Views.swift.
extension WorkspaceWindowController {
    func performViewCommand(_ command: ViewCommand) {
        switch command {
        case .new: presentNewViewPrompt()
        case .edit(let info): editView(info)
        case .refresh(let info): refreshMaterializedView(info)
        }
    }

    @objc func newView(_ sender: Any?) {
        presentNewViewPrompt()
    }

    /// Asks for the name (and the schema where the engine has schemas), then opens the template.
    func presentNewViewPrompt(name prefill: String = "") {
        guard workspace.canEditViews, let window, window.attachedSheet == nil else { return NSSound.beep() }
        let name = NSTextField(string: prefill)
        name.placeholderString = "View name"
        name.setAccessibilityIdentifier("newViewName")
        var fields: [NSView] = [name]
        var schemaPicker: NSPopUpButton?
        if workspace.kind.supportsSchemas, !workspace.schemas.isEmpty {
            let picker = NSPopUpButton()
            picker.addItems(withTitles: workspace.schemas)
            if let current = workspace.currentSchema { picker.selectItem(withTitle: current) }
            fields.append(picker)
            schemaPicker = picker
        }
        let alert = NSAlert()
        alert.messageText = "New View"
        alert.informativeText = "Opens a query tab with a CREATE VIEW statement to complete. Save View creates the view."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = Self.stack(fields)
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            let viewName = name.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, let self else { return }
            guard !viewName.isEmpty else { return NSSound.beep() }
            self.openNewViewEditor(name: viewName, schema: schemaPicker?.titleOfSelectedItem ?? self.workspace.currentSchema)
        }
    }

    /// The template selects from the table selected in the sidebar when it is in the same schema.
    func openNewViewEditor(name: String, schema: String?) {
        let schema = workspace.kind.supportsSchemas ? schema : nil
        let selected = sidebarController.selectedTable.flatMap { ref in workspace.tables.first { $0.ref == ref } }
        let source = selected.flatMap { $0.kind == .table && $0.ref.schema == schema ? $0.ref : nil }
        guard let template = workspace.viewSQL.template(name: name, schema: schema, source: source) else { return NSSound.beep() }
        let context = ViewEditorContext(mode: .create, view: TableRef(schema: schema, name: name))
        let tab = tabs.openQuery(sql: template, title: "New View", viewEditor: context)
        tab.focusEditor()
    }

    /// A tab with the view's replace script, not run.
    func editView(_ info: TableInfo) {
        guard workspace.viewSQL.canEdit(info.kind) else { return NSSound.beep() }
        Task {
            do {
                let definition = try await workspace.viewDefinition(of: info.ref)
                let script = workspace.viewSQL.editScript(definition)
                let context = ViewEditorContext(mode: .edit, view: definition.view, definition: definition)
                tabs.openQuery(sql: script, title: "Edit \(info.name)", viewEditor: context)
            } catch {
                Alerts.showError(error, title: "Could not read the definition of “\(info.name)”", in: window)
            }
        }
    }

    /// REFRESH MATERIALIZED VIEW, through Safe Mode; read-only connections never get this far.
    func refreshMaterializedView(_ info: TableInfo) {
        guard !workspace.isReadOnly, let statement = workspace.viewSQL.refreshStatement(info.ref) else { return NSSound.beep() }
        SafeModeGate.authorize(config: workspace.config, statements: [statement], writes: true, action: "Refresh materialized view “\(info.name)”", in: window) { [weak self] allowed in
            guard allowed, let self else { return }
            Task {
                do {
                    _ = try await self.workspace.execute(statement)
                    self.tabs.reloadTabs(showing: info.ref)
                } catch {
                    Alerts.showError(error, title: "Could not refresh “\(info.name)”", in: self.window)
                }
            }
        }
    }

    /// After a view tab saved: the catalog is already reloaded, so switch the sidebar to the view's schema and select it.
    func selectSavedView(_ view: TableRef) {
        Task {
            var schema: String?
            if workspace.kind.supportsSchemas {
                schema = view.schema ?? workspace.currentSchema
                if let schema, schema != workspace.currentSchema, workspace.schemas.contains(schema) {
                    await workspace.switchSchema(schema)
                }
            }
            let views = workspace.tables.filter { $0.kind == .view || $0.kind == .materializedView }
            let sameSchema = { (info: TableInfo) in !self.workspace.kind.supportsSchemas || info.ref.schema == schema }
            let match = views.first { $0.name == view.name && sameSchema($0) }
                ?? views.first { $0.name.caseInsensitiveCompare(view.name) == .orderedSame && sameSchema($0) }
            if let match {
                sidebarController.select(match.ref)
                tabs.reloadTabs(showing: match.ref)
            }
        }
    }
}

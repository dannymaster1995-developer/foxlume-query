import AppKit
import FoxlumeQueryCore

/// Opening, copying, editing and dropping procedures, functions, triggers and types from the sidebar, the source tab
/// and Open Quickly.
extension WorkspaceWindowController {
    func openObjectSource(_ object: SchemaObject) {
        tabs.openObjectSource(object)
        AppEnvironment.openQuicklyFrecency.record(QuickOpenItem.objectKey(object), connection: workspace.config.id)
    }

    func performObjectCommand(_ command: SchemaObjectCommand) {
        switch command {
        case .copyDefinition(let object): copyDefinition(of: object)
        case .edit(let object): editInQueryTab(object)
        case .drop(let object): confirmDrop(object)
        case .newTrigger(let table): openTriggerTemplate(table: table)
        }
    }

    private func copyDefinition(of object: SchemaObject) {
        Task {
            do {
                let definition = try await workspace.definition(of: object)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(workspace.schemaObjectSQL.displayText(definition), forType: .string)
            } catch {
                Alerts.showError(error, title: "Could not read the definition of “\(object.name)”", in: window)
            }
        }
    }

    /// A new query tab with a script that replaces the object, not run. PostgreSQL routines arrive as CREATE OR
    /// REPLACE; MySQL and MariaDB as DROP … IF EXISTS plus CREATE, which runs without DELIMITER.
    func editInQueryTab(_ object: SchemaObject) {
        Task {
            do {
                let definition = try await workspace.definition(of: object)
                let script = workspace.schemaObjectSQL.editScript(for: object, definition: definition)
                tabs.openQuery(sql: script, title: "Edit \(object.name)")
            } catch {
                Alerts.showError(error, title: "Could not read the definition of “\(object.name)”", in: window)
            }
        }
    }

    /// Asks first, then passes the statement through Safe Mode; read-only connections never get this far.
    func confirmDrop(_ object: SchemaObject) {
        guard !workspace.isReadOnly else {
            return Alerts.showError(DatabaseError.unsupported("This connection is read-only."), title: "Could not drop “\(object.name)”", in: window)
        }
        guard let statement = workspace.schemaObjectSQL.dropStatement(object) else { return NSSound.beep() }
        let label = object.kind.isRoutine ? object.signatureName : object.name
        Alerts.confirm(
            "Drop \(object.kind.noun) “\(label)”?",
            detail: "This cannot be undone.\n\n\(statement)",
            confirmTitle: "Drop \(object.kind.label)",
            destructive: true,
            in: window
        ) { [weak self] confirmed in
            guard confirmed, let self else { return }
            SafeModeGate.authorize(config: self.workspace.config, statements: [statement], writes: true, action: "Drop \(object.kind.noun) “\(object.name)”", in: self.window) { allowed in
                guard allowed else { return }
                Task {
                    do {
                        try await self.workspace.drop(object)
                        self.tabs.closeObjectTabs(object)
                    } catch {
                        Alerts.showError(error, title: "Could not drop “\(object.name)”", in: self.window)
                    }
                }
            }
        }
    }

    func openTriggerTemplate(table: TableRef?) {
        let replaceable = workspace.kind == .postgresql && (Int(workspace.serverVersion.prefix { $0.isNumber }) ?? 0) >= 14
        guard let template = workspace.schemaObjectSQL.triggerTemplate(table: table, replaceable: replaceable) else { return NSSound.beep() }
        tabs.openQuery(sql: template, title: "New Trigger")
    }
}

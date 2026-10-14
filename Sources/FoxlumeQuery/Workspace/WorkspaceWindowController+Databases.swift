import AppKit
import FoxlumeQueryCore

/// Database › New / Drop Database and (PostgreSQL) New / Drop Schema.
extension WorkspaceWindowController {
    var databaseObjects: DatabaseObjectSQL { DatabaseObjectSQL(kind: workspace.kind) }

    @objc func newDatabase(_ sender: Any?) {
        guard databaseObjects.canManageDatabases else { return NSSound.beep() }
        let name = NSTextField(string: "")
        name.placeholderString = "Database name"
        let switchTo = NSButton(checkboxWithTitle: "Switch to the new database", target: nil, action: nil)
        switchTo.state = .on
        let alert = NSAlert()
        alert.messageText = "New Database"
        alert.informativeText = "Creates an empty database on \(workspace.config.displayName)."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = Self.stack([name, switchTo])
        alert.window.initialFirstResponder = name
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            let database = name.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, let self, let sql = self.databaseObjects.createDatabase(database) else { return }
            self.runDatabaseChange(sql, failure: "Could not create “\(database)”") {
                if switchTo.state == .on { self.switchToDatabase(database) }
            }
        }
    }

    @objc func dropDatabase(_ sender: Any?) {
        let hidden = workspace.kind.systemDatabases
        // PostgreSQL cannot drop the database a session is connected to.
        let candidates = workspace.databases.filter { !hidden.contains($0) && !(workspace.kind == .postgresql && $0 == workspace.currentDatabase) }
        guard !candidates.isEmpty else {
            return Alerts.showError(DatabaseError.unsupported(workspace.kind == .postgresql ? "Switch to another database first: PostgreSQL cannot drop the database you are connected to." : "There is no database to drop."), title: "Drop Database", in: window)
        }
        let picker = NSPopUpButton()
        picker.addItems(withTitles: candidates)
        if let current = workspace.currentDatabase, candidates.contains(current) { picker.selectItem(withTitle: current) }
        let confirmation = NSTextField(string: "")
        confirmation.placeholderString = "Type the database name to confirm"
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Drop Database"
        alert.informativeText = "Deletes the database and everything in it. This cannot be undone."
        let drop = alert.addButton(withTitle: "Drop")
        drop.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = Self.stack([picker, confirmation])
        alert.window.initialFirstResponder = confirmation
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let database = picker.titleOfSelectedItem else { return }
            guard confirmation.stringValue == database else {
                return Alerts.showError(DatabaseError.unsupported("The name you typed does not match “\(database)”, so nothing was dropped."), title: "Drop Database", in: window)
            }
            guard let sql = self.databaseObjects.dropDatabase(database) else { return }
            let wasCurrent = database == self.workspace.currentDatabase
            self.runDatabaseChange(sql, failure: "Could not drop “\(database)”") {
                if wasCurrent, let next = self.workspace.databases.first(where: { !hidden.contains($0) && $0 != database }) {
                    self.switchToDatabase(next)
                }
            }
        }
    }

    @objc func newSchema(_ sender: Any?) {
        let name = NSTextField(string: "")
        name.placeholderString = "Schema name"
        let alert = NSAlert()
        alert.messageText = "New Schema"
        alert.informativeText = "Creates a schema in \(workspace.currentDatabase ?? "the current database")."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = Self.stack([name])
        alert.window.initialFirstResponder = name
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            let schema = name.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, let self, let sql = self.databaseObjects.createSchema(schema) else { return }
            self.runDatabaseChange(sql, failure: "Could not create “\(schema)”") {
                Task { await self.workspace.switchSchema(schema) }
            }
        }
    }

    @objc func dropSchema(_ sender: Any?) {
        let candidates = workspace.schemas.filter { !["pg_catalog", "information_schema", "pg_toast"].contains($0) }
        guard !candidates.isEmpty else { return NSSound.beep() }
        let picker = NSPopUpButton()
        picker.addItems(withTitles: candidates)
        if let current = workspace.currentSchema, candidates.contains(current) { picker.selectItem(withTitle: current) }
        let cascade = NSButton(checkboxWithTitle: "Cascade (also drop the tables and other objects in it)", target: nil, action: nil)
        let confirmation = NSTextField(string: "")
        confirmation.placeholderString = "Type the schema name to confirm"
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Drop Schema"
        alert.informativeText = "This cannot be undone."
        let drop = alert.addButton(withTitle: "Drop")
        drop.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = Self.stack([picker, cascade, confirmation])
        alert.window.initialFirstResponder = confirmation
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let schema = picker.titleOfSelectedItem else { return }
            guard confirmation.stringValue == schema else {
                return Alerts.showError(DatabaseError.unsupported("The name you typed does not match “\(schema)”, so nothing was dropped."), title: "Drop Schema", in: window)
            }
            guard let sql = self.databaseObjects.dropSchema(schema, cascade: cascade.state == .on) else { return }
            self.runDatabaseChange(sql, failure: "Could not drop “\(schema)”") {}
        }
    }

    /// Runs one statement, records it in history, refreshes the catalog and then runs `completion`.
    private func runDatabaseChange(_ sql: String, failure: String, completion: @escaping () -> Void) {
        SafeModeGate.authorize(config: workspace.config, statements: [sql], writes: true, action: "Run \(sql.components(separatedBy: " ").prefix(2).joined(separator: " "))", in: window) { [weak self] confirmed in
            guard confirmed, let self else { return }
            Task {
                do {
                    _ = try await self.workspace.execute(sql)
                    await self.workspace.refreshMetadata()
                    completion()
                } catch {
                    Alerts.showError(error, title: failure, in: self.window)
                }
            }
        }
    }

    private func switchToDatabase(_ name: String) {
        guard !tabs.hasUnsavedTableEdits else { return }
        Task {
            do {
                try await workspace.switchDatabase(name)
                tabs.closeTableTabs()
            } catch {
                Alerts.showError(error, title: "Could not switch database", in: window)
            }
        }
    }

    private static func stack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in views {
            view.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        return stack
    }
}

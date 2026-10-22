import AppKit
import FoxlumeQueryCore

/// Database › New / Drop Database and (PostgreSQL) New / Rename / Drop Schema and Rename / Copy Database.
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

    // MARK: Rename Schema

    /// Database › Rename Schema…: the browsed schema is preselected unless it is a system one.
    @objc func renameSchema(_ sender: Any?) {
        presentRenameSchema(workspace.currentSchema.flatMap { DatabaseObjectSQL.isSystemSchema($0) ? nil : $0 })
    }

    /// Asks for the schema (preselected) and its new name. System schemas are refused with an explanation.
    func presentRenameSchema(_ preset: String?) {
        guard databaseObjects.canRenameSchemas, !workspace.isReadOnly, let window, window.attachedSheet == nil else { return NSSound.beep() }
        if let preset, DatabaseObjectSQL.isSystemSchema(preset) {
            return Alerts.showError(DatabaseError.unsupported("“\(preset)” is a system schema and cannot be renamed."), title: "Rename Schema", in: window)
        }
        let candidates = workspace.schemas.filter { !DatabaseObjectSQL.isSystemSchema($0) }
        guard !candidates.isEmpty else { return NSSound.beep() }
        let picker = NSPopUpButton()
        picker.addItems(withTitles: candidates)
        let initial = preset.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates[0]
        picker.selectItem(withTitle: initial)
        let name = NSTextField(string: initial)
        name.placeholderString = "New schema name"
        name.font = Theme.monospaced(12)
        name.setAccessibilityIdentifier("renameSchemaField")
        let alert = NSAlert()
        alert.messageText = "Rename Schema"
        alert.informativeText = "Queries, views and functions that name the schema stop working. Open tables, layouts and filter presets follow the new name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = Self.stack([picker, name])
        alert.window.initialFirstResponder = name
        // Choosing another schema puts its name in the field, as the preselected one's is.
        let follower = PopUpFollower(picker) { name.stringValue = $0 }
        alert.beginSheetModal(for: window) { [weak self] response in
            _ = follower
            let newName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, let self, let schema = picker.titleOfSelectedItem, !newName.isEmpty, newName != schema else { return }
            self.renameSchema(schema, to: newName)
        }
    }

    /// Runs the rename through Safe Mode, then moves open tabs and remembered layouts, presets and recents.
    func renameSchema(_ old: String, to new: String) {
        guard !DatabaseObjectSQL.isSystemSchema(old) else {
            return Alerts.showError(DatabaseError.unsupported("“\(old)” is a system schema and cannot be renamed."), title: "Rename Schema", in: window)
        }
        let rename = StoredStateRename.schema(connectionID: workspace.config.id, database: workspace.currentDatabase, from: old, to: new)
        guard !tabs.hasUnsavedEdits(affectedBy: rename) else {
            return Alerts.showError(DatabaseError.unsupported("Save or discard the edits in the open tables of “\(old)” before renaming it."), title: "Unsaved changes", in: window)
        }
        guard let statement = databaseObjects.renameSchema(old, to: new) else { return NSSound.beep() }
        SafeModeGate.authorize(config: workspace.config, statements: [statement], writes: true, action: "Rename schema “\(old)” to “\(new)”", in: window) { [weak self] confirmed in
            guard confirmed, let self else { return }
            Task {
                do {
                    try await self.workspace.renameSchema(old, to: new)
                    self.applyStoredStateRename(rename)
                } catch {
                    Alerts.showError(error, title: "Could not rename “\(old)”", in: self.window)
                }
            }
        }
    }

    /// Moves what the app remembers per schema or database, then rebuilds the tabs that show it.
    private func applyStoredStateRename(_ rename: StoredStateRename) {
        try? AppEnvironment.gridColumnLayouts.apply(rename)
        try? AppEnvironment.erDiagramLayouts.apply(rename)
        try? AppEnvironment.filterPresets.apply(rename)
        AppEnvironment.openQuicklyFrecency.apply(rename)
        try? AppEnvironment.favourites.apply(rename)
        tabs.retarget(rename)
    }

    // MARK: Rename and Copy Database

    @objc func renameDatabase(_ sender: Any?) {
        presentDatabaseChange(copy: false)
    }

    @objc func copyDatabase(_ sender: Any?) {
        presentDatabaseChange(copy: true)
    }

    /// Asks for the source (the current database preselected) and the new name; Copy also offers to keep the owner.
    func presentDatabaseChange(copy: Bool) {
        guard databaseObjects.canRenameDatabases, !workspace.isReadOnly, let window, window.attachedSheet == nil else { return NSSound.beep() }
        let hidden = workspace.kind.systemDatabases
        let candidates = workspace.databases.filter { !hidden.contains($0) }
        guard !candidates.isEmpty else { return NSSound.beep() }
        let picker = NSPopUpButton()
        picker.addItems(withTitles: candidates)
        let initial = workspace.currentDatabase.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates[0]
        picker.selectItem(withTitle: initial)
        let name = NSTextField(string: copy ? initial + "_copy" : initial)
        name.placeholderString = "New database name"
        name.font = Theme.monospaced(12)
        name.setAccessibilityIdentifier("databaseNameField")
        let keepOwner = NSButton(checkboxWithTitle: "Same owner as the source", target: nil, action: nil)
        let alert = NSAlert()
        alert.messageText = copy ? "Copy Database" : "Rename Database"
        alert.informativeText = (copy
            ? "Creates a new database from the source as a template. A large database takes a while to copy."
            : "Connections and scripts that name the database stop working.")
            + " Nobody else may be connected to the source; when it is the database you use, Foxlume Query steps out of it meanwhile."
        alert.addButton(withTitle: copy ? "Copy" : "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = Self.stack(copy ? [picker, name, keepOwner] : [picker, name])
        alert.window.initialFirstResponder = name
        let follower = PopUpFollower(picker) { name.stringValue = copy ? $0 + "_copy" : $0 }
        alert.beginSheetModal(for: window) { [weak self] response in
            _ = follower
            let newName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, let self, let source = picker.titleOfSelectedItem, !newName.isEmpty, newName != source else { return }
            if copy {
                self.copyDatabase(source, to: newName, keepOwner: keepOwner.state == .on)
            } else {
                self.renameDatabase(source, to: newName)
            }
        }
    }

    func renameDatabase(_ source: String, to target: String) {
        let rename = StoredStateRename.database(connectionID: workspace.config.id, from: source, to: target)
        guard !tabs.hasUnsavedEdits(affectedBy: rename), source != workspace.currentDatabase || workspace.pendingTableOperations.isEmpty else {
            return Alerts.showError(DatabaseError.unsupported("Save or discard the edits in your open tables and the pending truncates and drops before renaming the database you use."), title: "Unsaved changes", in: window)
        }
        runDatabaseChange(.rename(from: source, to: target)) { [weak self] in
            self?.applyStoredStateRename(rename)
        }
    }

    func copyDatabase(_ source: String, to target: String, keepOwner: Bool) {
        Task {
            var owner: String?
            if keepOwner, let query = databaseObjects.ownerQuery(of: source) {
                do {
                    owner = try await workspace.session.run { try $0.execute(query, rowLimit: nil) }.first?.rows.first?.first?.displayString
                } catch {
                    return Alerts.showError(error, title: "Could not read the owner of “\(source)”", in: window)
                }
            }
            runDatabaseChange(.copy(from: source, to: target, owner: owner)) {}
        }
    }

    /// Safe Mode first, then the statement under a progress sheet; other sessions on the source are listed with only
    /// Cancel to choose, since this app does not end other sessions.
    private func runDatabaseChange(_ change: DatabaseChange, completion: @escaping () -> Void) {
        guard let statement = change.statement(databaseObjects) else { return NSSound.beep() }
        let action = change.verb == "Rename" ? "Rename database “\(change.source)” to “\(change.target)”" : "Copy database “\(change.source)” to “\(change.target)”"
        SafeModeGate.authorize(config: workspace.config, statements: [statement], writes: true, action: action, in: window) { [weak self] confirmed in
            guard confirmed, let self, let window = self.window else { return }
            let progress = ActivitySheet(text: change.verb == "Rename"
                ? "Renaming “\(change.source)” to “\(change.target)”…"
                : "Copying “\(change.source)” to “\(change.target)”… A large database takes a while.")
            progress.begin(for: window)
            self.isChangingDatabase = true
            Task {
                defer { self.isChangingDatabase = false }
                do {
                    try await self.workspace.performDatabaseChange(change)
                    progress.end()
                    completion()
                } catch let error as DatabaseChangeError {
                    progress.end()
                    self.showOtherSessions(error, change: change)
                } catch {
                    progress.end()
                    Alerts.showError(error, title: "Could not \(change.verb.lowercased()) “\(change.source)”", in: self.window)
                }
            }
        }
    }

    private func showOtherSessions(_ error: DatabaseChangeError, change: DatabaseChange) {
        guard case .otherSessions(let database, let groups) = error else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(database)” is in use by \(error.total) other session\(error.total == 1 ? "" : "s")"
        alert.informativeText = groups.map { "• " + $0.summary }.joined(separator: "\n")
            + "\n\nPostgreSQL can \(change.verb.lowercased()) a database only while nobody else is connected to it. Close those sessions and try again."
        alert.addButton(withTitle: "Cancel")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Fields of a prompt sheet, stacked at one width; also used by New View… (WorkspaceWindowController+Views.swift).
    static func stack(_ views: [NSView]) -> NSView {
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

/// Calls `changed` with the title a pop-up button's user picks; keep it alive as long as the button.
@MainActor
final class PopUpFollower: NSObject {
    private let changed: (String) -> Void

    init(_ popUp: NSPopUpButton, changed: @escaping (String) -> Void) {
        self.changed = changed
        super.init()
        popUp.target = self
        popUp.action = #selector(picked(_:))
    }

    @objc private func picked(_ sender: NSPopUpButton) {
        if let title = sender.titleOfSelectedItem { changed(title) }
    }
}

/// A sheet with a spinner and one line, shown while a long statement runs; the window stays responsive behind it.
@MainActor
final class ActivitySheet: NSWindowController {
    private let spinner = NSProgressIndicator()

    init(text: String) {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 84), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.setAccessibilityIdentifier("activitySpinner")
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.setAccessibilityIdentifier("activityText")
        let row = NSStackView(views: [spinner, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        window.contentView = content
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func begin(for parent: NSWindow) {
        guard let window else { return }
        spinner.startAnimation(nil)
        parent.beginSheet(window) { _ in
            // The sheet keeps itself alive until it closes.
            _ = self
        }
    }

    func end() {
        spinner.stopAnimation(nil)
        guard let window else { return }
        window.sheetParent?.endSheet(window)
    }
}

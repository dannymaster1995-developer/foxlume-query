import AppKit
import FoxlumeQueryCore

/// Structure editing and Create Table, offered for PostgreSQL and MySQL; every other engine keeps a read-only structure view.
extension ConnectionWorkspace {
    var structureGenerator: TableDDLGenerator? { TableDDLGenerator(kind: kind) }

    var supportsStructureEditing: Bool { structureGenerator != nil }

    /// Read-only connections never change structure.
    var canChangeStructure: Bool { supportsStructureEditing && !isReadOnly }

    /// Runs a schema script as one session job, records it in the history and reloads the catalog afterwards,
    /// whether it worked or not, since MySQL keeps the statements that ran before a failure.
    func applySchemaStatements(_ statements: [String], transactional: Bool) async throws {
        guard !statements.isEmpty else { return }
        if isReadOnly {
            throw DatabaseError.unsupported("This connection is read-only.")
        }
        if connectionState != .connected {
            try await reconnect()
        }
        let summary = TableDDLGenerator.script(statements)
        let started = Date()
        do {
            try await session.applySchemaStatements(statements, transactional: transactional)
            AppEnvironment.history.add(sql: summary, connectionID: config.id, database: currentDatabase, duration: Date().timeIntervalSince(started), rowCount: nil, error: nil)
        } catch {
            AppEnvironment.history.add(sql: summary, connectionID: config.id, database: currentDatabase, duration: Date().timeIntervalSince(started), rowCount: nil, error: error.localizedDescription)
            await refreshMetadata()
            throw error
        }
        await refreshMetadata()
    }

    /// Plain tables of the current schema, for the referenced-table picker.
    var tableNamesForReferences: [String] {
        tables.filter { $0.kind == .table }.map(\.name)
    }
}

/// Asks to run a schema script, showing every statement, as the confirmation before Save and Create. The Safe Mode
/// levels that need it then ask for Touch ID or the login password.
@MainActor
enum SchemaScriptPrompt {
    static func confirm(title: String, statements: [String], workspace: ConnectionWorkspace, confirmTitle: String, in window: NSWindow?, handler: @escaping (Bool) -> Void) {
        let level = SafeModeGate.level(for: workspace.config)
        let handler: (Bool) -> Void = { confirmed in
            guard confirmed, level.requiresAuthentication, level.gates(writes: true) else { return handler(confirmed) }
            SafeModeGate.authenticate(reason: "change the structure on \(workspace.config.displayName)", completion: handler)
        }
        let alert = NSAlert()
        alert.messageText = title
        var notes: [String] = []
        if level.gates(writes: true) {
            notes.append("\(workspace.config.displayName) uses Safe Mode “\(level.title)”.")
        } else if workspace.config.environment == .production {
            notes.append("This is a production connection.")
        }
        if workspace.structureGenerator?.runsInTransaction == true, statements.count > 1 {
            notes.append("The statements run in one transaction; if one fails, nothing is changed.")
        } else if statements.count > 1 {
            notes.append("MySQL commits each statement on its own; if one fails, the ones before it stay applied.")
        }
        alert.informativeText = notes.joined(separator: " ")
        alert.alertStyle = workspace.config.environment == .production ? .critical : .warning
        let confirm = alert.addButton(withTitle: confirmTitle)
        confirm.hasDestructiveAction = workspace.config.environment == .production
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = scriptView(TableDDLGenerator.script(statements))
        alert.layout()
        if let window {
            alert.beginSheetModal(for: window) { handler($0 == .alertFirstButtonReturn) }
        } else {
            handler(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    /// Lists problems that keep a draft from being saved.
    static func showProblems(_ problems: [String], in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some changes are incomplete"
        alert.informativeText = problems.map { "• " + $0 }.joined(separator: "\n")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private static func scriptView(_ text: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 220))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = Theme.monospaced(11)
        textView.string = text
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.setAccessibilityIdentifier("schemaScript")
        scroll.documentView = textView
        return scroll
    }
}

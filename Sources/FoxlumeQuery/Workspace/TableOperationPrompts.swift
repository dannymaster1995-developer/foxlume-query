import AppKit
import FoxlumeQueryCore

/// The Truncate and Drop questions with TablePro's two options.
@MainActor
enum TableOperationAlert {
    private static let accessoryWidth: CGFloat = 280

    static func present(_ operation: TableOperationKind, table: TableInfo, sql: TableOperationSQL, in window: NSWindow?, completion: @escaping (TableOperationOptions?) -> Void) {
        let fkSupported = sql.supportsForeignKeyToggle
        let cascadeSupported = sql.supportsCascade(operation)
        let ignoreForeignKeys = NSButton(checkboxWithTitle: "Ignore foreign key checks", target: nil, action: nil)
        ignoreForeignKeys.isEnabled = fkSupported
        ignoreForeignKeys.setAccessibilityIdentifier("ignoreForeignKeys")
        let cascade = NSButton(checkboxWithTitle: "Cascade", target: nil, action: nil)
        cascade.isEnabled = cascadeSupported
        cascade.setAccessibilityIdentifier("cascade")

        var rows: [NSView] = [ignoreForeignKeys]
        if !fkSupported {
            rows.append(note(cascadeSupported ? "Not supported for this database. Use CASCADE instead." : "Not supported for this database."))
        }
        rows.append(cascade)
        switch operation {
        case .drop:
            rows.append(note(cascadeSupported ? "Drop all objects that depend on this one" : "Not supported for DROP with this database"))
        case .truncate:
            rows.append(note(cascadeSupported ? "Truncate all tables linked by foreign keys" : "Not supported for TRUNCATE with this database"))
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for row in rows {
            row.widthAnchor.constraint(equalToConstant: accessoryWidth).isActive = true
        }
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)

        let alert = NSAlert()
        alert.alertStyle = .warning
        let noun = sql.noun(for: table.kind)
        switch operation {
        case .truncate: alert.messageText = "Truncate \(noun) '\(table.name)'"
        case .drop: alert.messageText = "Drop \(noun) '\(table.name)'"
        }
        alert.informativeText = "Runs when you save (⌘S). Until then you can undo it from this menu or with Discard Changes."
        let confirm = alert.addButton(withTitle: operation == .truncate ? "Truncate" : "Drop")
        confirm.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = stack
        alert.layout()

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return completion(nil) }
            completion(TableOperationOptions(
                ignoreForeignKeys: fkSupported && ignoreForeignKeys.state == .on,
                cascade: cascadeSupported && cascade.state == .on
            ))
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private static func note(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = accessoryWidth - 20
        let container = NSStackView(views: [label])
        container.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        return container
    }
}

/// Asks for a new name, prefilled with the current one.
@MainActor
enum RenamePrompt {
    static func present(_ table: TableInfo, sql: TableOperationSQL, in window: NSWindow?, completion: @escaping (String?) -> Void) {
        let field = NSTextField(string: table.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.font = Theme.monospaced(12)
        field.setAccessibilityIdentifier("renameField")
        let alert = NSAlert()
        alert.messageText = "Rename \(sql.noun(for: table.kind)) '\(table.name)'"
        alert.informativeText = "Queries, views and code that use the old name stop working."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(response == .alertFirstButtonReturn && !name.isEmpty && name != table.name ? name : nil)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

/// Read-only, highlighted view of the statements Save would run (⇧⌘P).
@MainActor
final class SQLPreviewSheet: NSWindowController {
    private let editor = SQLEditorView()

    init(text: String, language: QueryLanguage) {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Preview"
        window.minSize = NSSize(width: 420, height: 240)
        super.init(window: window)

        editor.language = language
        editor.string = text
        editor.isEditable = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.setAccessibilityIdentifier("previewSQL")

        let title = UI.label("Statements Save will run", size: 13, weight: .semibold)
        let copy = UI.button("Copy", target: self, action: #selector(copyText(_:)))
        let close = UI.button("Close", target: self, action: #selector(closeSheet(_:)))
        close.keyEquivalent = "\r"
        let cancelShortcut = NSButton(title: "", target: self, action: #selector(closeSheet(_:)))
        cancelShortcut.keyEquivalent = "\u{1b}"
        cancelShortcut.isHidden = true
        let buttons = UI.hstack([copy, close], spacing: 8)

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        for view in [title, editor, buttons, cancelShortcut] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let border = NSBox()
        border.boxType = .custom
        border.borderColor = .separatorColor
        border.borderWidth = 1
        border.fillColor = .clear
        border.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(border)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            editor.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            editor.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            editor.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            editor.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            border.topAnchor.constraint(equalTo: editor.topAnchor, constant: -1),
            border.leadingAnchor.constraint(equalTo: editor.leadingAnchor, constant: -1),
            border.trailingAnchor.constraint(equalTo: editor.trailingAnchor, constant: 1),
            border.bottomAnchor.constraint(equalTo: editor.bottomAnchor, constant: 1),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.contentView = content
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func begin(for parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { _ in
            // The sheet keeps itself alive until it closes.
            _ = self
        }
    }

    @objc private func copyText(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(editor.string, forType: .string)
    }

    @objc private func closeSheet(_ sender: Any?) {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
    }
}

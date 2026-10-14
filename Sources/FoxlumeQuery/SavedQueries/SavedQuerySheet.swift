import AppKit
import FoxlumeQueryCore

/// "New Saved Query" / "Edit Saved Query": name, folder, SQL, completion keyword and scope.
@MainActor
final class SavedQuerySheet: NSWindowController, NSTextFieldDelegate {
    /// The sheet on screen, for scripted checks.
    private(set) static weak var presented: SavedQuerySheet?

    private let workspace: ConnectionWorkspace
    private let editing: SavedQuery?
    private var completion: ((SavedQuery?) -> Void)?

    private let nameField = NSTextField()
    private let folderPopup = NSPopUpButton()
    private let folderLabel = SavedQuerySheet.fieldLabel("Folder")
    private let editor = SQLEditorView()
    private let keywordField = NSTextField()
    private let keywordMessage = UI.label("", size: 11, color: .secondaryLabelColor)
    private let globalBox = NSButton(checkboxWithTitle: "Available in all connections", target: nil, action: nil)
    private let folderNote = UI.label("Only folders shared with all connections can hold a query for every connection.", size: 11, color: .secondaryLabelColor)
    private lazy var saveButton = UI.button(editing == nil ? "Add" : "Save", target: self, action: #selector(saveClicked(_:)))
    private lazy var cancelButton = UI.button("Cancel", target: self, action: #selector(cancelClicked(_:)))
    /// Folder ids in popup order; nil is "None".
    private var folderChoices: [UUID?] = []
    private var preferredFolder: UUID?

    /// A new saved query with `sql`, named after its first line, for this connection only.
    convenience init(workspace: ConnectionWorkspace, sql: String, folderID: UUID? = nil) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(workspace: workspace, editing: nil, draft: SavedQuery(
            name: trimmed.isEmpty ? "" : SavedQueryValidation.suggestedName(for: trimmed),
            sql: trimmed,
            folderID: folderID,
            connectionID: workspace.config.id
        ))
    }

    convenience init(workspace: ConnectionWorkspace, editing query: SavedQuery) {
        self.init(workspace: workspace, editing: query, draft: query)
    }

    private init(workspace: ConnectionWorkspace, editing: SavedQuery?, draft: SavedQuery) {
        self.workspace = workspace
        self.editing = editing
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = editing == nil ? "New Saved Query" : "Edit Saved Query"
        window.minSize = NSSize(width: 480, height: 440)
        super.init(window: window)
        buildContent()
        nameField.stringValue = draft.name
        editor.string = draft.sql
        keywordField.stringValue = draft.keyword ?? ""
        globalBox.state = draft.connectionID == nil ? .on : .off
        preferredFolder = draft.folderID
        reloadFolders()
        validate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func fieldLabel(_ text: String) -> NSTextField {
        let label = UI.label(text, size: 12, weight: .medium)
        label.alignment = .right
        return label
    }

    private func buildContent() {
        guard let window else { return }
        let title = UI.label(window.title, size: 15, weight: .semibold)
        let subtitle = UI.label(editing.map { _ in "Changes apply wherever this query is offered." } ?? "Saved for \(workspace.config.displayName) unless shared with all connections.",
                                size: 11, color: .secondaryLabelColor)

        nameField.placeholderString = "Name"
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(fieldReturn(_:))
        nameField.setAccessibilityIdentifier("savedQueryName")

        folderPopup.target = self
        folderPopup.action = #selector(folderChanged(_:))
        folderPopup.setAccessibilityIdentifier("savedQueryFolder")

        editor.language = workspace.queryLanguage
        editor.applyFontSize(CGFloat(AppEnvironment.settings.editorFontSize))
        editor.onTextChange = { [weak self] in self?.validate() }
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.setAccessibilityIdentifier("savedQuerySQL")
        let editorFrame = NSView()
        editorFrame.wantsLayer = true
        editorFrame.layer?.borderWidth = 1
        editorFrame.layer?.borderColor = NSColor.separatorColor.cgColor
        editorFrame.layer?.masksToBounds = true
        editorFrame.translatesAutoresizingMaskIntoConstraints = false
        editorFrame.addSubviewFilling(editor, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        let markerHint = UI.label("Type ;; where the cursor should land when the keyword inserts this query.", size: 11, color: .secondaryLabelColor)

        keywordField.placeholderString = "Optional, e.g. top10"
        keywordField.font = Theme.monospaced(12)
        keywordField.delegate = self
        keywordField.target = self
        keywordField.action = #selector(fieldReturn(_:))
        keywordField.setAccessibilityIdentifier("savedQueryKeyword")
        keywordMessage.setAccessibilityIdentifier("savedQueryKeywordMessage")
        let keywordHint = UI.label("Typing the keyword in the editor offers this query.", size: 11, color: .secondaryLabelColor)

        globalBox.target = self
        globalBox.action = #selector(scopeChanged(_:))
        globalBox.setAccessibilityIdentifier("savedQueryGlobal")

        let queryLabel = Self.fieldLabel("Query")
        let grid = NSGridView(views: [
            [Self.fieldLabel("Name"), nameField],
            [folderLabel, folderPopup],
            [queryLabel, editorFrame],
            [NSGridCell.emptyContentView, markerHint],
            [Self.fieldLabel("Keyword"), UI.hstack([keywordField, keywordMessage], spacing: 8)],
            [NSGridCell.emptyContentView, keywordHint],
            [NSGridCell.emptyContentView, globalBox],
            [NSGridCell.emptyContentView, folderNote],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 2).yPlacement = .top
        grid.row(at: 2).rowAlignment = .none
        for row in [3, 5] { grid.row(at: row).topPadding = -4 }

        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        saveButton.bezelColor = .controlAccentColor
        saveButton.toolTip = "\(saveButton.title) (⌘↩)"
        saveButton.setAccessibilityIdentifier("savedQuerySave")
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = UI.hstack([UI.flexibleSpace(), cancelButton, saveButton], spacing: 8)

        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        header.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(header)
        content.addSubview(grid)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            nameField.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            editorFrame.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            editorFrame.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            keywordField.widthAnchor.constraint(equalToConstant: 170),
        ])
        keywordMessage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [markerHint, keywordHint, folderNote] {
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        window.contentView = content
        window.initialFirstResponder = nameField
    }

    func begin(for parent: NSWindow, completion: @escaping (SavedQuery?) -> Void) {
        guard let window else { return }
        self.completion = completion
        Self.presented = self
        parent.beginSheet(window) { _ in
            // The sheet keeps itself alive until it closes.
            _ = self
        }
        // A new query without SQL starts in the editor once named; one with SQL starts at its name.
        window.makeFirstResponder(nameField)
    }

    // MARK: State

    private var scope: UUID? {
        globalBox.state == .on ? nil : (editing?.connectionID ?? workspace.config.id)
    }

    private var selectedFolder: UUID? {
        let index = folderPopup.indexOfSelectedItem
        return folderChoices.indices.contains(index) ? folderChoices[index] : nil
    }

    /// "None" plus every folder this connection shows that can hold the chosen scope, indented by depth.
    private func reloadFolders() {
        let library = AppEnvironment.savedQueries.library(visibleOn: workspace.config.id)
        let all = SavedQueryNode.foldersInOrder(library)
        let allowed = all.filter { $0.folder.canHold(scope: scope) }
        folderPopup.removeAllItems()
        folderChoices = [nil]
        folderPopup.addItem(withTitle: "None")
        for (folder, depth) in allowed {
            folderPopup.addItem(withTitle: folder.name)
            folderPopup.lastItem?.indentationLevel = min(depth + 1, 15)
            folderChoices.append(folder.id)
        }
        let index = folderChoices.firstIndex(of: preferredFolder) ?? 0
        folderPopup.selectItem(at: index)
        let hasFolders = !all.isEmpty
        folderPopup.isHidden = !hasFolders
        folderLabel.isHidden = !hasFolders
        folderNote.isHidden = !(globalBox.state == .on && allowed.count < all.count)
    }

    private var currentIssues: [SavedQueryValidation.Issue] {
        SavedQueryValidation.issues(name: nameField.stringValue, sql: editor.string, keyword: keywordField.stringValue,
                                    scope: scope, editing: editing?.id, in: AppEnvironment.savedQueries.library)
    }

    @discardableResult
    private func validate() -> [SavedQueryValidation.Issue] {
        let issues = currentIssues
        if let keywordIssue = issues.first(where: { $0.field == .keyword }) {
            keywordMessage.stringValue = keywordIssue.message
            keywordMessage.textColor = keywordIssue.isError ? .systemRed : .systemOrange
        } else {
            keywordMessage.stringValue = ""
        }
        keywordMessage.toolTip = keywordMessage.stringValue
        saveButton.isEnabled = SavedQueryValidation.canSave(issues)
        return issues
    }

    func controlTextDidChange(_ notification: Notification) {
        validate()
    }

    @objc private func folderChanged(_ sender: Any?) {
        preferredFolder = selectedFolder
    }

    @objc private func scopeChanged(_ sender: Any?) {
        reloadFolders()
        validate()
    }

    @objc private func fieldReturn(_ sender: Any?) {
        if saveButton.isEnabled { saveClicked(sender) }
    }

    // MARK: Buttons

    @objc private func saveClicked(_ sender: Any?) {
        guard SavedQueryValidation.canSave(validate()) else { return NSSound.beep() }
        var query = editing ?? SavedQuery(name: "", sql: "")
        query.name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        query.sql = editor.string
        query.keyword = SavedQueryValidation.normalizedKeyword(keywordField.stringValue)
        query.connectionID = scope
        query.folderID = selectedFolder
        do {
            let saved = try AppEnvironment.savedQueries.save(query)
            finish(saved)
        } catch {
            Alerts.showError(error, title: "Could not save the query", in: window)
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        finish(nil)
    }

    private func finish(_ saved: SavedQuery?) {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        completion?(saved)
        completion = nil
    }

    // MARK: Scripted checks

    /// Sets a field as typing would: name, keyword, sql, folder (a folder name or None) or global (true/false).
    func setValue(_ value: String, for field: String) {
        switch field {
        case "name": nameField.stringValue = value
        case "keyword": keywordField.stringValue = value
        case "sql": editor.string = value
        case "global":
            globalBox.state = value == "true" ? .on : .off
            reloadFolders()
        case "folder":
            if let index = (0..<folderPopup.numberOfItems).first(where: { folderPopup.item(at: $0)?.title == value }) {
                folderPopup.selectItem(at: index)
                preferredFolder = selectedFolder
            }
        default: break
        }
        validate()
    }

    var stateDescription: String {
        let folders = (0..<folderPopup.numberOfItems).compactMap { folderPopup.item(at: $0)?.title }
        return "name=\(nameField.stringValue) keyword=\(keywordField.stringValue) global=\(globalBox.state == .on) folder=\(folderPopup.titleOfSelectedItem ?? "-") folders=\(folderPopup.isHidden ? "hidden" : folders.joined(separator: ","))"
            + " message=\(keywordMessage.stringValue.isEmpty ? "-" : keywordMessage.stringValue) save=\(saveButton.isEnabled ? "enabled" : "disabled")"
            + " sql=\(editor.string.replacingOccurrences(of: "\n", with: "\\n"))"
    }

    func pressSave() { saveClicked(nil) }
    func pressCancel() { cancelClicked(nil) }
}

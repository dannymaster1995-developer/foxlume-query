import AppKit
import FoxlumeQueryCore

/// "New Table…": name the table, define columns, indexes and foreign keys, watch the CREATE TABLE script
/// take shape and run it. PostgreSQL and MySQL only.
@MainActor
final class CreateTableController: NSWindowController, NSTextFieldDelegate, NSComboBoxDelegate {
    /// The sheet on screen, for scripted checks.
    private(set) static weak var presented: CreateTableController?

    private let workspace: ConnectionWorkspace
    private let generator: TableDDLGenerator
    let editor: StructureDraftEditor
    /// Called with the new table after it was created and the catalog reloaded.
    var onCreated: ((TableRef) -> Void)?

    private let nameField = NSTextField()
    private let schemaPopup = NSPopUpButton()
    private let commentField = NSTextField()
    private let engineBox = NSComboBox()
    private let charsetBox = NSComboBox()
    private let collationBox = NSComboBox()
    private let picker = NSSegmentedControl(labels: ["Columns", "Indexes", "Foreign Keys"], trackingMode: .selectOne, target: nil, action: nil)
    private let preview = SQLEditorView()
    private let problemLabel = UI.label("", size: 11, color: .systemRed)
    private lazy var createButton = UI.button("Create Table", target: self, action: #selector(createClicked(_:)))
    private lazy var cancelButton = UI.button("Cancel", target: self, action: #selector(cancelClicked(_:)))
    private(set) var isCreating = false

    private var isMySQL: Bool { generator.dialect.family == .mysql }

    private static let collations: [String: [String]] = [
        "utf8mb4": ["utf8mb4_unicode_ci", "utf8mb4_0900_ai_ci", "utf8mb4_general_ci", "utf8mb4_bin"],
        "utf8mb3": ["utf8mb3_general_ci", "utf8mb3_unicode_ci", "utf8mb3_bin"],
        "latin1": ["latin1_swedish_ci", "latin1_general_ci", "latin1_bin"],
        "ascii": ["ascii_general_ci", "ascii_bin"],
        "binary": ["binary"],
    ]

    init?(workspace: ConnectionWorkspace) {
        guard let generator = workspace.structureGenerator else { return nil }
        self.workspace = workspace
        self.generator = generator
        // One blank column to start from; rows left blank are skipped.
        var draft = StructureDraft(newTable: TableRef(schema: workspace.kind.supportsSchemas ? workspace.currentSchema : nil, name: ""))
        draft.addColumn(ColumnDefinition(name: "", dataType: ""))
        editor = StructureDraftEditor(draft: draft, generator: generator)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "New Table"
        window.minSize = NSSize(width: 720, height: 480)
        super.init(window: window)
        buildContent()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildContent() {
        guard let window else { return }
        let title = UI.label("New Table", size: 15, weight: .semibold)
        let subtitle = UI.label("\(workspace.kind.displayName) · \(workspace.currentDatabase ?? workspace.config.database)", size: 11, color: .secondaryLabelColor)

        nameField.placeholderString = "table_name"
        nameField.font = Theme.monospaced(12)
        nameField.delegate = self
        nameField.setAccessibilityIdentifier("newTableName")
        commentField.placeholderString = "Optional"
        commentField.delegate = self
        commentField.setAccessibilityIdentifier("newTableComment")

        var fieldRow: [NSView] = [UI.label("Name", size: 12, weight: .medium), nameField]
        if workspace.kind.supportsSchemas {
            schemaPopup.addItems(withTitles: workspace.schemas)
            if let schema = workspace.currentSchema { schemaPopup.selectItem(withTitle: schema) }
            schemaPopup.target = self
            schemaPopup.action = #selector(optionChanged(_:))
            schemaPopup.controlSize = .small
            fieldRow += [UI.label("Schema", size: 12, weight: .medium), schemaPopup]
        }
        fieldRow += [UI.label("Comment", size: 12, weight: .medium), commentField]
        let fields = UI.hstack(fieldRow, spacing: 8)

        var rows: [NSView] = [UI.hstack([title, subtitle], spacing: 10), fields]
        if isMySQL {
            let defaults = CreateTableOptions.mysqlDefaults
            configure(engineBox, items: ["InnoDB", "MyISAM", "MEMORY", "ARCHIVE", "CSV"], value: defaults.engine)
            configure(charsetBox, items: ["utf8mb4", "utf8mb3", "latin1", "ascii", "binary"], value: defaults.charset)
            configure(collationBox, items: Self.collations[defaults.charset] ?? [], value: defaults.collation)
            rows.append(UI.hstack([
                UI.label("Engine", size: 12, weight: .medium), engineBox,
                UI.label("Charset", size: 12, weight: .medium), charsetBox,
                UI.label("Collation", size: 12, weight: .medium), collationBox,
            ], spacing: 8))
        }

        picker.selectedSegment = 0
        picker.target = self
        picker.action = #selector(sectionChanged(_:))
        picker.controlSize = .small
        let add = UI.iconButton("plus", tooltip: "Add", target: self, action: #selector(addClicked(_:)))
        let remove = UI.iconButton("minus", tooltip: "Delete Selected", target: self, action: #selector(removeClicked(_:)))
        for button in [add, remove] {
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
        rows.append(UI.hstack([picker, add, remove], spacing: 6))

        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.onChange = { [weak self] in self?.refresh() }
        let editorBorder = bordered(editor)

        preview.isEditable = false
        preview.language = workspace.queryLanguage
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.setAccessibilityIdentifier("createTablePreview")
        let previewBorder = bordered(preview)
        problemLabel.setAccessibilityIdentifier("createTableProblem")
        let previewHeader = UI.hstack([UI.label("SQL Preview", size: 11, weight: .semibold, color: .secondaryLabelColor), problemLabel], spacing: 10)

        createButton.keyEquivalent = "\r"
        createButton.keyEquivalentModifierMask = [.command]
        createButton.bezelColor = .controlAccentColor
        createButton.toolTip = "Create Table (⌘↩)"
        createButton.setAccessibilityIdentifier("createTableButton")
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = UI.hstack([UI.flexibleSpace(), cancelButton, createButton], spacing: 8)

        let content = NSView()
        let stack = NSStackView(views: rows + [editorBorder, previewHeader, previewBorder, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubviewFilling(stack)
        for view in [editorBorder, previewBorder, buttons, fields] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(equalToConstant: 220),
            commentField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            editorBorder.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            previewBorder.heightAnchor.constraint(equalToConstant: 150),
        ])
        editorBorder.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = content
        window.initialFirstResponder = nameField
    }

    private func configure(_ box: NSComboBox, items: [String], value: String) {
        box.addItems(withObjectValues: items)
        box.stringValue = value
        box.controlSize = .small
        box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        box.delegate = self
        box.widthAnchor.constraint(equalToConstant: 170).isActive = true
    }

    /// A thin frame around the editor and the preview.
    private func bordered(_ inner: NSView) -> NSView {
        let frame = NSView()
        frame.wantsLayer = true
        frame.layer?.borderWidth = 1
        frame.layer?.borderColor = NSColor.separatorColor.cgColor
        // The editor's line-number gutter draws past its own bottom edge.
        frame.layer?.masksToBounds = true
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubviewFilling(inner, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        return frame
    }

    func begin(for parent: NSWindow) {
        guard let window else { return }
        Self.presented = self
        parent.beginSheet(window) { _ in
            // The sheet keeps itself alive until it closes.
            _ = self
        }
    }

    // MARK: State

    /// The draft with the name, schema and comment from the fields.
    private func currentDraft() -> StructureDraft {
        var draft = editor.draft
        draft.table = tableRef
        draft.comment = commentField.stringValue.isEmpty ? nil : commentField.stringValue
        return draft
    }

    private var tableRef: TableRef {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        return TableRef(schema: workspace.kind.supportsSchemas ? schemaPopup.titleOfSelectedItem : nil, name: name)
    }

    private var options: CreateTableOptions {
        guard isMySQL else { return CreateTableOptions() }
        return CreateTableOptions(engine: engineBox.stringValue, charset: charsetBox.stringValue, collation: collationBox.stringValue)
    }

    /// Redraws the script and the first problem after every change.
    private func refresh() {
        let draft = currentDraft()
        let problems = generator.problems(draft)
        problemLabel.stringValue = problems.first ?? ""
        problemLabel.toolTip = problems.joined(separator: "\n")
        createButton.isEnabled = problems.isEmpty && !isCreating
        if problems.isEmpty, let statements = try? generator.createStatements(draft, options: options) {
            preview.string = TableDDLGenerator.script(statements)
        } else {
            preview.string = "-- " + (problems.first ?? "Nothing to create yet")
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSTextField) === nameField {
            editor.setTableName(tableRef.name, schema: tableRef.schema)
        }
        refresh()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let box = notification.object as? NSComboBox, box.indexOfSelectedItem >= 0 else { return }
        let picked = box.itemObjectValue(at: box.indexOfSelectedItem) as? String ?? ""
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            box.stringValue = picked
            if box === self.charsetBox { self.charsetChanged(picked) }
            self.refresh()
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if (notification.object as? NSComboBox) === charsetBox {
            charsetChanged(charsetBox.stringValue)
        }
        refresh()
    }

    /// A collation belongs to one charset, so it follows the charset.
    private func charsetChanged(_ charset: String) {
        let collations = Self.collations[charset] ?? []
        collationBox.removeAllItems()
        collationBox.addItems(withObjectValues: collations)
        if !collationBox.stringValue.hasPrefix(charset + "_") || collations.isEmpty {
            collationBox.stringValue = collations.first ?? ""
        }
    }

    @objc private func optionChanged(_ sender: Any?) {
        editor.setTableName(tableRef.name, schema: tableRef.schema)
        refresh()
    }

    @objc private func sectionChanged(_ sender: Any?) {
        editor.table.commitEditing()
        editor.section = StructureSection(rawValue: picker.selectedSegment) ?? .columns
    }

    func showSection(_ section: StructureSection) {
        picker.selectedSegment = section.rawValue
        sectionChanged(nil)
    }

    @objc private func addClicked(_ sender: Any?) { editor.addRow() }
    @objc private func removeClicked(_ sender: Any?) { editor.deleteSelectedRows() }

    /// For scripted checks.
    func setName(_ name: String) {
        nameField.stringValue = name
        editor.setTableName(tableRef.name, schema: tableRef.schema)
        refresh()
    }

    func setComment(_ text: String) {
        commentField.stringValue = text
        refresh()
    }

    // MARK: Create

    @objc private func cancelClicked(_ sender: Any?) {
        guard !isCreating else { return NSSound.beep() }
        close(sheet: nil)
    }

    @objc private func createClicked(_ sender: Any?) {
        create()
    }

    func create() {
        editor.table.commitEditing()
        window?.makeFirstResponder(nil)
        guard !isCreating else { return }
        let draft = currentDraft()
        let statements: [String]
        do {
            statements = try generator.createStatements(draft, options: options)
        } catch {
            SchemaScriptPrompt.showProblems((error as? StructureChangeError)?.problems ?? [error.localizedDescription], in: window)
            return
        }
        guard !workspace.isReadOnly else {
            Alerts.showError(DatabaseError.unsupported("This connection is read-only."), title: "The table was not created", in: window)
            return
        }
        let table = draft.table
        let run = { [weak self] in self?.run(statements, table: table) }
        // The sheet already previews the script, so only the connection's Safe Mode asks again.
        if SafeModeGate.level(for: workspace.config).gates(writes: true) {
            SchemaScriptPrompt.confirm(title: "Create table \(table.name)?", statements: statements, workspace: workspace, confirmTitle: "Create", in: window) { confirmed in
                if confirmed { run() }
            }
            return
        }
        run()
    }

    private func run(_ statements: [String], table: TableRef) {
        isCreating = true
        refresh()
        Task {
            do {
                try await workspace.applySchemaStatements(statements, transactional: generator.runsInTransaction && statements.count > 1)
                isCreating = false
                close(sheet: table)
            } catch {
                isCreating = false
                refresh()
                Alerts.showError(error, title: "The table was not created", in: window)
            }
        }
    }

    private func close(sheet created: TableRef?) {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        if Self.presented === self { Self.presented = nil }
        if let created { onCreated?(created) }
    }
}

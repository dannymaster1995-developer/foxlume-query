import AppKit
import FoxlumeQueryCore

/// Columns, indexes, foreign keys and DDL of one table. PostgreSQL and MySQL tables can be edited here;
/// edits stay pending until Save, like grid edits.
@MainActor
final class StructureViewController: NSViewController {
    private let workspace: ConnectionWorkspace
    private let table: TableRef
    private let picker = NSSegmentedControl(labels: ["Columns", "Indexes", "Foreign Keys", "DDL"], trackingMode: .selectOne, target: nil, action: nil)
    private let grid = DataGridView()
    private let ddlView = SQLEditorView()
    private let status = UI.label("", size: 11, color: .secondaryLabelColor)
    private let body = NSView()
    private let commentRow = NSStackView()
    private let commentField = NSTextField()
    private lazy var addButton = UI.iconButton("plus", tooltip: "Add (⇧⌘N)", target: self, action: #selector(addRowClicked(_:)))
    private lazy var removeButton = UI.iconButton("minus", tooltip: "Delete Selected (⌫)", target: self, action: #selector(removeRowsClicked(_:)))
    private var structure: TableStructure?
    private var ddl: String?
    /// The editor, for engines that support structure editing. Read-only structures use the grid.
    private(set) var editor: StructureDraftEditor?
    private(set) var isSaving = false

    /// Whether the tab allows changes now: not read-only, not a view, still on the database it was opened from.
    var canEdit: () -> Bool = { false }
    /// A reason that blocks saving structure edits, such as unsaved data edits in the same tab.
    var saveBlocker: () -> String? = { nil }
    /// Pending edits changed: the tab updates its Save button and dirty dot.
    var onChange: (() -> Void)?
    /// A save reached the server: the tab reloads its rows, whose columns may have changed.
    var onSaved: (() -> Void)?

    init(workspace: ConnectionWorkspace, table: TableRef) {
        self.workspace = workspace
        self.table = table
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        let capabilities = workspace.capabilities
        var sections: [(String, Int)] = [("Columns", 0)]
        if capabilities.supportsIndexes { sections.append(("Indexes", 1)) }
        if capabilities.supportsForeignKeys { sections.append(("Foreign Keys", 2)) }
        if capabilities.supportsDDL { sections.append(("DDL", 3)) }
        picker.segmentCount = sections.count
        for (index, section) in sections.enumerated() {
            picker.setLabel(section.0, forSegment: index)
            picker.setTag(section.1, forSegment: index)
            picker.setWidth(0, forSegment: index)
        }
        picker.selectedSegment = 0
        picker.target = self
        picker.action = #selector(sectionChanged(_:))
        picker.controlSize = .small
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.setAccessibilityIdentifier("structureSection")

        ddlView.isEditable = false
        ddlView.language = workspace.queryLanguage
        ddlView.isHidden = true
        grid.showsRowNumbers = false
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addSubviewFilling(grid)
        body.addSubviewFilling(ddlView)

        addButton.setAccessibilityIdentifier("structureAdd")
        removeButton.setAccessibilityIdentifier("structureRemove")
        addButton.isHidden = true
        removeButton.isHidden = true
        // The minus symbol is only a few points tall, so both buttons get a fixed size to stay visible and clickable.
        for button in [addButton, removeButton] {
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }

        commentField.placeholderString = "No table comment"
        commentField.font = .systemFont(ofSize: 12)
        commentField.controlSize = .small
        // Drawn like a grid cell, so a changed comment can be tinted like a changed cell.
        commentField.isBezeled = false
        commentField.isBordered = false
        commentField.drawsBackground = false
        commentField.wantsLayer = true
        commentField.layer?.cornerRadius = 4
        commentField.layer?.borderWidth = 1
        commentField.delegate = self
        commentField.translatesAutoresizingMaskIntoConstraints = false
        commentField.setAccessibilityIdentifier("tableComment")
        let commentLabel = UI.label("Comment", size: 11, weight: .medium, color: .secondaryLabelColor)
        commentRow.orientation = .horizontal
        commentRow.spacing = 8
        commentRow.setViews([commentLabel, commentField], in: .leading)
        commentRow.translatesAutoresizingMaskIntoConstraints = false
        commentRow.isHidden = true

        let header = UI.hstack([picker, addButton, removeButton, UI.flexibleSpace(), status])
        header.setCustomSpacing(12, after: picker)
        root.addSubview(header)
        root.addSubview(commentRow)
        root.addSubview(body)
        let commentTop = commentRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            commentTop,
            commentRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            commentRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            commentField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8).withPriority(.defaultLow),
            body.topAnchor.constraint(greaterThanOrEqualTo: header.bottomAnchor, constant: 8),
            bodyBelowComment,
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        bodyBelowComment.isActive = false
        view = root
    }

    /// Active only while the comment row shows.
    private lazy var bodyBelowComment = body.topAnchor.constraint(equalTo: commentRow.bottomAnchor, constant: 6)

    // MARK: Loading

    /// Whether this table is edited through the draft editor right now.
    private var usesEditor: Bool { workspace.supportsStructureEditing && (editor != nil || canEdit()) }

    var hasPendingChanges: Bool { editor?.draft.hasChanges ?? false }
    var pendingChangeCount: Int { editor?.draft.changeCount ?? 0 }

    /// Refresh: reloads from the server, after asking when edits would be lost.
    func reload() {
        guard !isSaving else { return NSSound.beep() }
        guard hasPendingChanges else { return reloadFromServer() }
        Alerts.confirm("Discard structure changes and reload?", detail: "Reloading replaces the pending changes with the structure on the server.", confirmTitle: "Discard and Reload", destructive: true, in: view.window) { [weak self] confirmed in
            if confirmed { self?.reloadFromServer() }
        }
    }

    private func reloadFromServer() {
        workspace.invalidateStructure(of: table)
        structure = nil
        ddl = nil
        load(force: true)
    }

    /// Shows the structure, read again from the workspace cache so DDL run elsewhere shows up.
    /// Pending edits survive switching between Data and Structure: a draft with changes is never replaced here.
    func load(force: Bool = false) {
        if !force, hasPendingChanges {
            render()
            return
        }
        status.stringValue = "Loading…"
        Task {
            do {
                let loaded = try await workspace.structure(of: table)
                structure = loaded
                if usesEditor, let generator = workspace.structureGenerator {
                    let draft = StructureDraft(structure: loaded, family: generator.dialect.family)
                    if let editor {
                        if !editor.draft.hasChanges || force { editor.replaceDraft(draft) }
                    } else {
                        installEditor(draft: draft, generator: generator)
                    }
                }
                render()
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }

    private func installEditor(draft: StructureDraft, generator: TableDDLGenerator) {
        let editor = StructureDraftEditor(draft: draft, generator: generator)
        editor.tableNames = workspace.tableNamesForReferences
        editor.isEditable = canEdit() && !isSaving
        editor.onChange = { [weak self] in
            self?.editorChanged()
        }
        editor.table.onSelectionChange = { [weak self] in self?.updateButtons() }
        body.addSubviewFilling(editor)
        self.editor = editor
    }

    private func editorChanged() {
        updateStatus()
        updateComment()
        onChange?()
    }

    func showSection(_ section: Int) {
        if let segment = (0..<picker.segmentCount).first(where: { picker.tag(forSegment: $0) == section }) {
            picker.selectedSegment = segment
        }
        sectionChanged(nil)
    }

    var selectedSection: Int {
        picker.selectedSegment >= 0 ? picker.tag(forSegment: picker.selectedSegment) : 0
    }

    @objc private func sectionChanged(_ sender: Any?) {
        editor?.table.commitEditing()
        render()
    }

    private func render() {
        let section = selectedSection
        let editing = editor != nil && section != 3
        grid.isHidden = section == 3 || editor != nil
        ddlView.isHidden = section != 3
        editor?.isHidden = !editing
        commentRow.isHidden = !editing
        bodyBelowComment.isActive = editing
        if let editor, editing, let draftSection = StructureSection(rawValue: section) {
            editor.tableNames = workspace.tableNamesForReferences
            editor.isEditable = canEdit() && !isSaving
            editor.section = draftSection
            editor.table.reload()
        }
        updateComment()
        updateButtons()
        updateStatus()
        guard let structure else { return }
        switch section {
        case 0 where editor == nil:
            let columns = ["#", "Name", "Type", "Nullable", "Default", "Key", "Extra", "Comment"].map { ResultColumn(name: $0) }
            let primary = Set(structure.primaryKey)
            let rows: [[CellValue]] = structure.columns.enumerated().map { index, column in
                [
                    .text(String(index + 1)),
                    .text(column.name),
                    .text(column.dataType),
                    .text(column.isNullable ? "YES" : "NO"),
                    column.defaultValue.map(CellValue.text) ?? .null,
                    .text(primary.contains(column.name) ? "PRIMARY" : ""),
                    .text([column.isAutoIncrement ? "auto increment" : nil, column.extra].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")),
                    column.comment.map(CellValue.text) ?? .null,
                ]
            }
            grid.setContent(DataGridContent(columns: columns, rows: rows), localSort: true)
        case 1 where editor == nil:
            let columns = ["Name", "Columns", "Unique", "Primary", "Method"].map { ResultColumn(name: $0) }
            let rows: [[CellValue]] = structure.indexes.map {
                [.text($0.name), .text($0.columns.joined(separator: ", ")), .text($0.isUnique ? "YES" : "NO"), .text($0.isPrimary ? "YES" : "NO"), $0.method.map(CellValue.text) ?? .null]
            }
            grid.setContent(DataGridContent(columns: columns, rows: rows), localSort: true)
        case 2 where editor == nil:
            let columns = ["Name", "Columns", "References", "Referenced Columns", "On Update", "On Delete"].map { ResultColumn(name: $0) }
            let rows: [[CellValue]] = structure.foreignKeys.map {
                let target = [$0.referencedTable.schema, $0.referencedTable.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ".")
                return [.text($0.name), .text($0.columns.joined(separator: ", ")), .text(target), .text($0.referencedColumns.joined(separator: ", ")), $0.onUpdate.map(CellValue.text) ?? .null, $0.onDelete.map(CellValue.text) ?? .null]
            }
            grid.setContent(DataGridContent(columns: columns, rows: rows), localSort: true)
        case 3:
            if let ddl {
                ddlView.string = ddl
            } else {
                ddlView.string = "-- Loading…"
                Task {
                    do {
                        ddl = try await workspace.ddl(of: table)
                    } catch {
                        ddl = "-- \(error.localizedDescription)"
                    }
                    ddlView.string = ddl ?? ""
                }
            }
        default:
            break
        }
    }

    private func updateStatus() {
        let section = selectedSection
        func count(_ n: Int, _ singular: String, _ plural: String) -> String { "\(n) \(n == 1 ? singular : plural)" }
        var parts: [String] = []
        if let editor {
            let draft = editor.draft
            switch section {
            case 0: parts.append(count(draft.columns.filter { !$0.isDeleted }.count, "column", "columns"))
            case 1: parts.append(count(draft.indexes.filter { !$0.isDeleted }.count + (draft.primaryKey.isEmpty ? 0 : 1), "index", "indexes"))
            case 2: parts.append(count(draft.foreignKeys.filter { !$0.isDeleted }.count, "foreign key", "foreign keys"))
            default: break
            }
            if draft.hasChanges { parts.append(count(draft.changeCount, "pending change", "pending changes")) }
            if isSaving { parts.append("saving…") }
        } else if let structure {
            switch section {
            case 0: parts.append(count(structure.columns.count, "column", "columns"))
            case 1: parts.append(count(structure.indexes.count, "index", "indexes"))
            case 2: parts.append(count(structure.foreignKeys.count, "foreign key", "foreign keys"))
            default: break
            }
        }
        status.stringValue = parts.joined(separator: " · ")
    }

    private func updateButtons() {
        let editable = editor != nil && selectedSection != 3
        addButton.isHidden = !editable
        removeButton.isHidden = !editable
        let enabled = canEdit() && !isSaving
        addButton.isEnabled = enabled
        removeButton.isEnabled = enabled
        let noun = selectedSection == 1 ? "Index" : selectedSection == 2 ? "Foreign Key" : "Column"
        addButton.toolTip = "Add \(noun) (⇧⌘N)"
        removeButton.toolTip = "Delete Selected \(noun == "Index" ? "Indexes" : noun + "s") (⌫)"
    }

    private func updateComment() {
        guard let draft = editor?.draft else { return }
        if commentField.currentEditor() == nil {
            commentField.stringValue = draft.comment ?? ""
        }
        commentField.isEditable = canEdit() && !isSaving
        // Tinted like a changed cell while the comment differs from the server's.
        commentField.effectiveAppearance.performAsCurrentDrawingAppearance {
            commentField.layer?.borderColor = NSColor.separatorColor.cgColor
            commentField.layer?.backgroundColor = draft.commentChanged ? Theme.modifiedCell.cgColor : NSColor.textBackgroundColor.cgColor
        }
    }

    // MARK: Editing

    @objc private func addRowClicked(_ sender: Any?) { addRow() }
    @objc private func removeRowsClicked(_ sender: Any?) { deleteSelectedRows() }

    var canEditNow: Bool { editor != nil && canEdit() && !isSaving }

    func addRow() {
        guard let editor, canEditNow else { return NSSound.beep() }
        if selectedSection == 3 { showSection(0) }
        editor.addRow()
    }

    func deleteSelectedRows() {
        guard let editor, canEditNow, selectedSection != 3 else { return NSSound.beep() }
        editor.deleteSelectedRows()
    }

    /// For scripted checks: sets one cell of the current section as typing would.
    func setCell(row: Int, key: String, value: StructureCellValue) {
        editor?.setValue(value, row: row, key: key)
    }

    func setTableComment(_ text: String) {
        editor?.setComment(text)
    }

    func discardChanges() {
        guard let editor, !isSaving, let structure, let generator = workspace.structureGenerator else { return }
        editor.table.commitEditing()
        editor.replaceDraft(StructureDraft(structure: structure, family: generator.dialect.family))
        render()
    }

    var undoManagerForEdits: UndoManager? { editor?.editUndoManager }

    /// The statements Save would run, for Preview SQL. Nil without pending changes.
    func previewOfPendingChanges() -> String? {
        guard let editor, let generator = workspace.structureGenerator else { return nil }
        editor.table.commitEditing()
        commitCommentField()
        guard editor.draft.hasChanges else { return nil }
        do {
            return TableDDLGenerator.script(try generator.alterStatements(editor.draft))
        } catch {
            let problems = (error as? StructureChangeError)?.problems ?? [error.localizedDescription]
            return "-- Error generating SQL:\n" + problems.map { "-- " + $0 }.joined(separator: "\n")
        }
    }

    private func commitCommentField() {
        guard commentField.currentEditor() != nil else { return }
        view.window?.makeFirstResponder(nil)
    }

    // MARK: Saving

    /// Validates, shows the script for confirmation and runs it.
    func saveChanges() {
        guard let editor, let generator = workspace.structureGenerator else { return }
        editor.table.commitEditing()
        commitCommentField()
        let draft = editor.draft
        guard draft.hasChanges, !isSaving else { return }
        guard canEdit() else {
            Alerts.showError(DatabaseError.unsupported(workspace.isReadOnly ? "This connection is read-only." : "This table can no longer be changed from this tab. Reopen it from the sidebar."), title: "Changes were not saved", in: view.window)
            return
        }
        if let blocker = saveBlocker() {
            Alerts.showError(DatabaseError.unsupported(blocker), title: "Changes were not saved", in: view.window)
            return
        }
        let statements: [String]
        do {
            statements = try generator.alterStatements(draft)
        } catch {
            SchemaScriptPrompt.showProblems((error as? StructureChangeError)?.problems ?? [error.localizedDescription], in: view.window)
            return
        }
        guard !statements.isEmpty else {
            // Only no-op edits (such as retyping a value) remain.
            discardChanges()
            return
        }
        let count = draft.changeCount
        SchemaScriptPrompt.confirm(
            title: "Apply \(count) structure change\(count == 1 ? "" : "s") to \(table.name)?",
            statements: statements,
            workspace: workspace,
            confirmTitle: "Apply",
            in: view.window
        ) { [weak self] confirmed in
            if confirmed { self?.run(statements, transactional: generator.runsInTransaction) }
        }
    }

    private func run(_ statements: [String], transactional: Bool) {
        guard !isSaving else { return }
        setSaving(true)
        Task {
            do {
                try await workspace.applySchemaStatements(statements, transactional: transactional)
                setSaving(false)
                ddl = nil
                load(force: true)
                onSaved?()
            } catch {
                setSaving(false)
                let applied = (error as? SchemaScriptError).map { !$0.rolledBack && $0.position > 1 } ?? false
                if applied {
                    // Part of the script is on the server, so the draft no longer describes what is left to do.
                    Alerts.showError(error, title: "Some changes were applied; the structure was reloaded", in: view.window)
                    reloadFromServer()
                    onSaved?()
                } else {
                    Alerts.showError(error, title: "Changes were not saved", in: view.window)
                }
            }
        }
    }

    private func setSaving(_ saving: Bool) {
        isSaving = saving
        editor?.isEditable = canEdit() && !saving
        updateButtons()
        updateComment()
        updateStatus()
        onChange?()
    }
}

extension StructureViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === commentField else { return }
        editor?.setComment(commentField.stringValue)
    }
}

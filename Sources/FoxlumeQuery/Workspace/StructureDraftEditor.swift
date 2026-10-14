import AppKit
import FoxlumeQueryCore

/// Edits one section of a `StructureDraft` (columns, indexes or foreign keys) with undo.
/// Used by the Structure view of a table and by Create Table.
@MainActor
final class StructureDraftEditor: NSView {
    private(set) var draft: StructureDraft
    let generator: TableDDLGenerator
    let table = StructureEditorTable()
    /// Edit history of this draft, separate from text undo.
    let editUndoManager = UndoManager()
    /// Table names offered for a foreign key's referenced table.
    var tableNames: [String] = [] {
        didSet { if section == .foreignKeys { configureSection() } }
    }
    var onChange: (() -> Void)?

    var section: StructureSection = .columns {
        didSet { if oldValue != section { configureSection() } }
    }

    var isEditable = true {
        didSet { table.isEditable = isEditable }
    }

    private var isMySQL: Bool { generator.dialect.family == .mysql }

    init(draft: StructureDraft, generator: TableDDLGenerator) {
        self.draft = draft
        self.generator = generator
        super.init(frame: .zero)
        table.showsChangeColors = !draft.isNewTable
        // One undo step per edit, whatever events the edits arrive in.
        editUndoManager.groupsByEvent = false
        table.rowCount = { [weak self] in self?.displayRowCount ?? 0 }
        table.value = { [weak self] row, key in self?.value(row: row, key: key) ?? .text("") }
        table.rowState = { [weak self] row in self?.rowState(row) ?? .unchanged }
        table.cellModified = { [weak self] row, key in self?.isModified(row: row, key: key) ?? false }
        table.cellEditable = { [weak self] row, key in self?.isCellEditable(row: row, key: key) ?? false }
        table.onEdit = { [weak self] row, key, value in self?.setValue(value, row: row, key: key) }
        table.onDeleteRows = { [weak self] rows in self?.toggleDeletion(rows) }
        table.menuItems = { [weak self] rows in self?.menuItems(for: rows) ?? [] }
        addSubviewFilling(table)
        configureSection()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Draft

    /// Replaces the draft after a load or a save. History goes with it: its steps refer to the old rows.
    func replaceDraft(_ newDraft: StructureDraft) {
        draft = newDraft
        editUndoManager.removeAllActions()
        table.reload()
        onChange?()
    }

    /// Applies an edit and records how to go back to the draft before it.
    func apply(_ newDraft: StructureDraft, action: String) {
        guard newDraft != draft else { return table.reload() }
        let previous = draft
        editUndoManager.beginUndoGrouping()
        editUndoManager.registerUndo(withTarget: self) { editor in
            editor.apply(previous, action: action)
        }
        editUndoManager.setActionName(action)
        editUndoManager.endUndoGrouping()
        draft = newDraft
        table.reload()
        onChange?()
    }

    func setComment(_ text: String) {
        var updated = draft
        updated.comment = text.isEmpty ? nil : text
        guard StructureDraft.normalized(updated.comment) != StructureDraft.normalized(draft.comment) else { return }
        apply(updated, action: "Edit Table Comment")
    }

    func setTableName(_ name: String, schema: String?) {
        var updated = draft
        updated.table = TableRef(schema: schema, name: name)
        guard updated.table != draft.table else { return }
        // Renaming the new table is not an undoable structure edit; the name field keeps its own text undo.
        draft = updated
        onChange?()
    }

    // MARK: Rows

    /// The primary key is shown as a read-only first row of the index list; it changes through the column checkboxes.
    private var showsPrimaryRow: Bool {
        section == .indexes && (draft.primaryIndex != nil || !draft.primaryKey.isEmpty)
    }

    private var rowOffset: Int { showsPrimaryRow ? 1 : 0 }

    var displayRowCount: Int { draft.rowCount(section) + rowOffset }

    /// Index of `row` in the draft, nil for the primary key row.
    private func draftRow(_ row: Int) -> Int? {
        let index = row - rowOffset
        return index >= 0 && index < draft.rowCount(section) ? index : nil
    }

    private func rowState(_ row: Int) -> StructureRowState {
        guard let index = draftRow(row) else { return primaryRowState }
        return draft.state(section, row: index)
    }

    private var primaryRowState: StructureRowState {
        guard draft.primaryKeyChanged, !draft.isNewTable else { return .unchanged }
        if draft.originalPrimaryKey.isEmpty { return .inserted }
        return draft.primaryKey.isEmpty ? .deleted : .modified
    }

    func addRow() {
        guard isEditable else { return NSSound.beep() }
        var updated = draft
        let row: Int
        let focusKey: String
        switch section {
        case .columns:
            row = updated.addColumn(ColumnDefinition(name: "", dataType: isMySQL ? "varchar(255)" : "text"))
            focusKey = "name"
        case .indexes:
            row = updated.addIndex(IndexDefinition(name: uniqueIndexName(), columns: []))
            focusKey = "columns"
        case .foreignKeys:
            row = updated.addForeignKey(ForeignKeyDefinition(name: "", columns: [], referencedTable: TableRef(schema: draft.table.schema, name: ""), referencedColumns: []))
            focusKey = "columns"
        }
        apply(updated, action: section == .columns ? "Add Column" : section == .indexes ? "Add Index" : "Add Foreign Key")
        let shown = row + rowOffset
        table.select(row: shown)
        DispatchQueue.main.async { [weak self] in self?.table.beginEditing(row: shown, key: focusKey) }
    }

    private func uniqueIndexName() -> String {
        let base = (draft.table.name.isEmpty ? "table" : draft.table.name) + "_idx"
        let taken = Set(draft.indexes.map { $0.current.name.lowercased() })
        var number = 1
        while taken.contains("\(base)\(number)".lowercased()) { number += 1 }
        return "\(base)\(number)"
    }

    func deleteSelectedRows() {
        toggleDeletion(table.selectedRows)
    }

    /// Deletes the rows, or restores them when they are all deleted already.
    func toggleDeletion(_ rows: IndexSet) {
        guard isEditable else { return NSSound.beep() }
        let indexes = IndexSet(rows.compactMap(draftRow))
        guard !indexes.isEmpty else { return NSSound.beep() }
        var updated = draft
        let restoring = indexes.allSatisfy { draft.state(section, row: $0) == .deleted }
        updated.toggleDeletion(section, rows: indexes)
        apply(updated, action: restoring ? "Restore Rows" : "Delete Rows")
    }

    func revert(_ rows: IndexSet) {
        guard isEditable else { return NSSound.beep() }
        var updated = draft
        for index in rows.compactMap(draftRow).sorted(by: >) {
            updated.revert(section, row: index)
        }
        apply(updated, action: "Revert Changes")
    }

    private func menuItems(for rows: IndexSet) -> [NSMenuItem] {
        guard isEditable else { return [] }
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        let noun = section == .columns ? "Column" : section == .indexes ? "Index" : "Foreign Key"
        var items = [item("Add \(noun)", #selector(menuAdd(_:)))]
        let indexes = rows.compactMap(draftRow)
        guard !indexes.isEmpty else { return items }
        items.append(.separator())
        let allDeleted = indexes.allSatisfy { draft.state(section, row: $0) == .deleted }
        items.append(item(allDeleted ? "Undo Delete" : (indexes.count > 1 ? "Delete \(indexes.count) Rows" : "Delete \(noun)"), #selector(menuDelete(_:))))
        if indexes.contains(where: { draft.state(section, row: $0) == .modified }) {
            items.append(item("Revert Changes", #selector(menuRevert(_:))))
        }
        return items
    }

    @objc private func menuAdd(_ sender: Any?) { addRow() }
    @objc private func menuDelete(_ sender: Any?) { toggleDeletion(table.selectedRows) }
    @objc private func menuRevert(_ sender: Any?) { revert(table.selectedRows) }

    // MARK: Section layout

    private func configureSection() {
        switch section {
        case .columns:
            var specs = [
                StructureColumnSpec("#", "#", width: 34, kind: .label),
                StructureColumnSpec("name", "Name", width: 170, kind: .text, placeholder: "column_name"),
                StructureColumnSpec("type", "Type", width: 180, kind: .combo(generator.commonTypes), placeholder: "type"),
                StructureColumnSpec("nullable", "Nullable", width: 64, kind: .check),
                StructureColumnSpec("default", "Default", width: 180, kind: .combo(generator.defaultSuggestions), placeholder: "no default",
                                    toolTip: "Raw SQL: quote strings ('text'); empty means no default"),
                StructureColumnSpec("primary", "Primary Key", width: 80, kind: .check),
                StructureColumnSpec("auto", "Auto Inc", width: 66, kind: .check),
                StructureColumnSpec("comment", "Comment", width: 200, kind: .text),
            ]
            if !draft.isNewTable {
                specs.append(StructureColumnSpec("extra", "Extra", width: 220, kind: .label))
            }
            table.setSpecs(specs)
        case .indexes:
            table.setSpecs([
                StructureColumnSpec("name", "Name", width: 220, kind: .text, placeholder: "index_name"),
                StructureColumnSpec("columns", "Columns", width: 260, kind: .text, placeholder: "col1, col2",
                                    toolTip: "Comma-separated columns; expressions in parentheses"),
                StructureColumnSpec("unique", "Unique", width: 60, kind: .check),
                StructureColumnSpec("method", "Method", width: 120, kind: .combo(generator.indexMethods), placeholder: "default"),
                StructureColumnSpec("kind", "Kind", width: 150, kind: .label),
            ])
        case .foreignKeys:
            let actions = generator.referentialActions.map(\.rawValue)
            table.setSpecs([
                StructureColumnSpec("name", "Name", width: 200, kind: .text, placeholder: "automatic"),
                StructureColumnSpec("columns", "Columns", width: 170, kind: .text, placeholder: "col1, col2"),
                StructureColumnSpec("refTable", "Referenced Table", width: 200, kind: .combo(tableNames), placeholder: "table"),
                StructureColumnSpec("refColumns", "Referenced Columns", width: 170, kind: .text, placeholder: "id"),
                StructureColumnSpec("onUpdate", "On Update", width: 120, kind: .popup(actions)),
                StructureColumnSpec("onDelete", "On Delete", width: 120, kind: .popup(actions)),
            ])
        }
    }

    // MARK: Values

    private func value(row: Int, key: String) -> StructureCellValue {
        guard let index = draftRow(row) else { return primaryRowValue(key) }
        switch section {
        case .columns:
            let column = draft.columns[index].current
            switch key {
            case "#": return .text(String(index + 1))
            case "name": return .text(column.name)
            case "type": return .text(column.dataType)
            case "nullable": return .flag(column.isNullable)
            case "default": return .text(column.defaultValue ?? "")
            case "primary": return .flag(column.isPrimaryKey)
            case "auto": return .flag(column.isAutoIncrement)
            case "comment": return .text(column.comment ?? "")
            case "extra": return .text(Self.extraText(column))
            default: return .text("")
            }
        case .indexes:
            let definition = draft.indexes[index].current
            switch key {
            case "name": return .text(definition.name)
            case "columns": return .text(definition.columns.joined(separator: ", "))
            case "unique": return .flag(definition.isUnique)
            case "method": return .text(definition.method ?? "")
            case "kind":
                if definition.isConstraint { return .text(definition.isUnique ? "UNIQUE constraint" : "constraint") }
                return .text(definition.isUnique ? "UNIQUE index" : "index")
            default: return .text("")
            }
        case .foreignKeys:
            let key2 = draft.foreignKeys[index].current
            switch key {
            case "name": return .text(key2.name)
            case "columns": return .text(key2.columns.joined(separator: ", "))
            case "refTable": return .text(referencedTableText(key2.referencedTable))
            case "refColumns": return .text(key2.referencedColumns.joined(separator: ", "))
            case "onUpdate": return .text(key2.onUpdate.rawValue)
            case "onDelete": return .text(key2.onDelete.rawValue)
            default: return .text("")
            }
        }
    }

    private func primaryRowValue(_ key: String) -> StructureCellValue {
        let columns = draft.primaryKey.isEmpty ? draft.originalPrimaryKey : draft.primaryKey
        switch key {
        case "name": return .text(draft.primaryKeyName ?? (isMySQL ? "PRIMARY" : "primary key"))
        case "columns": return .text(columns.joined(separator: ", "))
        case "unique": return .flag(true)
        case "method": return .text(draft.primaryIndex?.method ?? "")
        case "kind": return .text("PRIMARY KEY")
        default: return .text("")
        }
    }

    /// Read-only details: engine extras without what the checkboxes already show, plus a non-default collation.
    static func extraText(_ column: ColumnDefinition) -> String {
        var parts: [String] = []
        if let extra = column.extra {
            let cleaned = extra
                .replacingOccurrences(of: "auto_increment", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "DEFAULT_GENERATED", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty { parts.append(cleaned) }
        }
        if let collation = column.collation { parts.append("COLLATE \(collation)") }
        return parts.joined(separator: ", ")
    }

    private func referencedTableText(_ table: TableRef) -> String {
        if let schema = table.schema, !schema.isEmpty, schema != draft.table.schema, !table.name.isEmpty {
            return "\(schema).\(table.name)"
        }
        return table.name
    }

    private func parseReferencedTable(_ text: String) -> TableRef {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let dot = trimmed.firstIndex(of: "."), dot != trimmed.startIndex {
            return TableRef(schema: String(trimmed[..<dot]), name: String(trimmed[trimmed.index(after: dot)...]))
        }
        return TableRef(schema: draft.table.schema, name: trimmed)
    }

    private func isModified(row: Int, key: String) -> Bool {
        guard let index = draftRow(row) else { return key == "columns" }
        switch section {
        case .columns:
            guard let original = draft.columns[index].original else { return false }
            let current = draft.columns[index].current
            switch key {
            case "name": return current.name != original.name
            case "type": return current.dataType != original.dataType
            case "nullable": return current.isNullable != original.isNullable
            case "default": return current.defaultValue != original.defaultValue
            case "primary": return current.isPrimaryKey != original.isPrimaryKey
            case "auto": return current.isAutoIncrement != original.isAutoIncrement
            case "comment": return StructureDraft.normalized(current.comment) != StructureDraft.normalized(original.comment)
            default: return false
            }
        case .indexes:
            guard let original = draft.indexes[index].original else { return false }
            let current = draft.indexes[index].current
            switch key {
            case "name": return current.name != original.name
            case "columns": return current.columns != original.columns
            case "unique": return current.isUnique != original.isUnique
            case "method": return (current.method ?? "") != (original.method ?? "")
            default: return false
            }
        case .foreignKeys:
            guard let original = draft.foreignKeys[index].original else { return false }
            let current = draft.foreignKeys[index].current
            switch key {
            case "name": return current.name != original.name
            case "columns": return current.columns != original.columns
            case "refTable": return current.referencedTable != original.referencedTable
            case "refColumns": return current.referencedColumns != original.referencedColumns
            case "onUpdate": return current.onUpdate != original.onUpdate
            case "onDelete": return current.onDelete != original.onDelete
            default: return false
            }
        }
    }

    private func isCellEditable(row: Int, key: String) -> Bool {
        guard let index = draftRow(row) else { return false }
        switch section {
        case .columns:
            let column = draft.columns[index].current
            switch key {
            case "#", "extra": return false
            case "default", "auto": return column.generationExpression == nil
            default: return true
            }
        case .indexes:
            return key != "kind"
        case .foreignKeys:
            return true
        }
    }

    /// Applies one cell edit. Values are taken as typed; only surrounding spaces of names and types are dropped.
    func setValue(_ value: StructureCellValue, row: Int, key: String) {
        guard isEditable, let index = draftRow(row) else { return NSSound.beep() }
        var updated = draft
        let text = value.text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch section {
        case .columns:
            updated.updateColumn(at: index) { column in
                switch key {
                case "name": column.name = trimmed
                case "type": column.dataType = trimmed
                case "nullable": column.isNullable = value.flag
                case "default": column.defaultValue = trimmed.isEmpty ? nil : trimmed
                case "primary": column.isPrimaryKey = value.flag
                case "auto": column.isAutoIncrement = value.flag
                case "comment": column.comment = text.isEmpty ? nil : text
                default: break
                }
            }
        case .indexes:
            updated.updateIndex(at: index) { definition in
                switch key {
                case "name": definition.name = trimmed
                case "columns": definition.columns = Self.splitList(text)
                case "unique": definition.isUnique = value.flag
                case "method": definition.method = trimmed.isEmpty ? nil : trimmed
                default: break
                }
            }
        case .foreignKeys:
            updated.updateForeignKey(at: index) { foreignKey in
                switch key {
                case "name": foreignKey.name = trimmed
                case "columns": foreignKey.columns = Self.splitList(text)
                case "refTable": foreignKey.referencedTable = parseReferencedTable(trimmed)
                case "refColumns": foreignKey.referencedColumns = Self.splitList(text)
                case "onUpdate": foreignKey.onUpdate = ReferentialAction(rawValue: text) ?? .noAction
                case "onDelete": foreignKey.onDelete = ReferentialAction(rawValue: text) ?? .noAction
                default: break
                }
            }
        }
        apply(updated, action: "Edit \(section == .columns ? "Column" : section == .indexes ? "Index" : "Foreign Key")")
    }

    /// Splits `a, lower(b), c` on top-level commas, so expressions with commas stay whole.
    static func splitList(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
                continue
            }
            switch character {
            case "'", "\"", "`":
                quote = character
                current.append(character)
            case "(":
                depth += 1
                current.append(character)
            case ")":
                depth = max(0, depth - 1)
                current.append(character)
            case "," where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

extension StructureDraft {
    /// Empty text and nil both mean "none" for comments.
    static func normalized(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

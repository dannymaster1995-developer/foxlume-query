import AppKit
import FoxlumeQueryCore

/// Range edits, paste and the cell Filter submenu of a table tab. Everything is staged in the pending changes, so
/// Save still runs through Safe Mode and the affected-row checks, and one undo step takes a whole paste back.
extension TableTabViewController {
    func dataGrid(_ grid: DataGridView, didEditCells edits: [GridCellEdit], actionName: String) {
        guard grid.isEditable else { return NSSound.beep() }
        var changes = grid.content.changes
        for edit in edits { stage(edit, into: &changes) }
        commit(changes, action: actionName)
    }

    /// Pasted cells replace values; pasted rows are added. Auto-increment columns of new rows keep their default,
    /// as when duplicating a row.
    func dataGrid(_ grid: DataGridView, paste edits: [GridCellEdit], newRows: [[CellValue?]]) {
        guard grid.isEditable else { return NSSound.beep() }
        var changes = grid.content.changes
        for edit in edits { stage(edit, into: &changes) }
        let autoColumns = Set(structure?.columns.filter(\.isAutoIncrement).map(\.name) ?? [])
        for fields in newRows {
            let values = grid.content.columns.indices.map { column -> InsertValue in
                guard !autoColumns.contains(grid.content.columns[column].name), let field = fields[safe: column], let value = field else { return .useDefault }
                return .value(value)
            }
            changes.addInsertion(values)
        }
        commit(changes, action: newRows.isEmpty ? "Paste" : (newRows.count == 1 ? "Paste Row" : "Paste Rows"))
    }

    private func stage(_ edit: GridCellEdit, into changes: inout PendingChanges) {
        if grid.content.isInserted(edit.row) {
            changes.setInsertValue(.value(edit.value), insertion: edit.row - grid.content.rows.count, column: edit.column)
        } else if let original = grid.content.rows[safe: edit.row]?[safe: edit.column] {
            changes.setValue(edit.value, row: edit.row, column: edit.column, original: original)
        }
    }

    func dataGrid(_ grid: DataGridView, filterColumn column: Int) {
        guard let name = grid.content.columns[safe: column]?.name else { return }
        showFilters(adding: FilterRule(column: name, op: .equals))
    }

    // MARK: Filter submenu

    /// "Filter" in a cell's menu: conditions that keep the clicked row, as TablePro offers them.
    func filterMenuItem(row: Int, column: Int) -> NSMenuItem? {
        guard let info = grid.content.columns[safe: column], let value = grid.content.rows[safe: row]?[safe: column] else { return nil }
        let rules = CellFilterSuggestions.rules(column: info.name, value: value, ordered: CellFilterSuggestions.isOrdered(info))
        guard !rules.isEmpty else { return nil }
        let submenu = NSMenu()
        for rule in rules {
            let item = NSMenuItem(title: rule.summary, action: #selector(filterFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rule
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Filter", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
        item.submenu = submenu
        return item
    }

    @objc private func filterFromMenu(_ sender: NSMenuItem) {
        guard let rule = sender.representedObject as? FilterRule else { return }
        addFilter(rule)
    }
}

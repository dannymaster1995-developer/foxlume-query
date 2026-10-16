import AppKit
import FoxlumeQueryCore

/// Typed cell editors of table tabs: the panel under a cell being edited (date picker, enum list, foreign key picker)
/// and the check box of boolean cells. Every edit goes to the delegate like a typed one, so it is staged, saved with
/// ⌘S and undone in one step; the cell's text field stays usable for typing a value by hand.
extension DataGridView {
    // MARK: Panel

    /// Opens the panel for the cell that just started editing, when its column has one.
    func openCellEditorPanel(row: Int, column: Int, tableColumn: Int) {
        closeCellEditorPanel()
        guard let editor = columnEditors[column], editor.hasPanel else { return }
        let value = content.currentValue(row: row, column: column)
        let text = value.map { $0.isAbsent ? "" : $0.displayString } ?? ""
        let panel = GridCellEditorPanel(grid: self, row: row, column: column, editor: editor, text: text, font: font)
        cellEditorPanel = panel
        panel.show(below: tableView.frameOfCell(atColumn: tableColumn, row: row), in: tableView)
    }

    func closeCellEditorPanel() {
        cellEditorPanel?.close()
        cellEditorPanel = nil
    }

    /// Keeps the panel under its cell while the grid scrolls.
    func repositionCellEditorPanel() {
        guard let panel = cellEditorPanel, let tableColumn = tableView.tableColumns.firstIndex(where: { dataColumnIndex($0) == panel.column }) else { return }
        panel.show(below: tableView.frameOfCell(atColumn: tableColumn, row: panel.row), in: tableView)
    }

    func cellWidth(column: Int) -> CGFloat? {
        tableView.tableColumns.first { dataColumnIndex($0) == column }?.width
    }

    /// The text field of the cell being edited, while one is.
    private var editingField: NSTextField? {
        guard let editor = tableView.window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField, field.isDescendant(of: tableView)
        else { return nil }
        return field
    }

    /// The text in the cell being edited.
    var cellEditorText: String {
        (editingField?.currentEditor() as? NSTextView)?.string ?? ""
    }

    /// Puts `text` in the cell being edited, as if typed, with the caret at the end.
    func replaceCellEditorText(_ text: String) {
        guard let editor = editingField?.currentEditor() as? NSTextView else { return }
        editor.string = text
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    /// Ends editing and stages the cell's text, as Return does.
    func commitCellEditorText() {
        closeCellEditorPanel()
        tableView.window?.makeFirstResponder(tableView)
    }

    /// Ends editing and stages `value` (NULL from the panel) instead of the cell's text.
    func commitCellEditor(value: CellValue) {
        guard let panel = cellEditorPanel else { return }
        let row = panel.row
        let column = panel.column
        closeCellEditorPanel()
        if let field = editingField {
            isAbortingCellEdit = true
            field.abortEditing()
            isAbortingCellEdit = false
            (field.superview as? GridCellView)?.finishEditing()
        }
        tableView.window?.makeFirstResponder(tableView)
        if content.currentValue(row: row, column: column) == value {
            let tableColumn = tableView.tableColumns.firstIndex { dataColumnIndex($0) == column }
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: tableColumn ?? 0))
            return
        }
        delegate?.dataGrid(self, didEditRow: row, column: column, value: value)
    }

    /// Up, Down and Return typed in the cell, offered to the panel first. True when the panel used the command.
    func cellEditorPanelHandles(_ commandSelector: Selector) -> Bool {
        guard let panel = cellEditorPanel else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            return panel.moveHighlight(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            return panel.moveHighlight(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            guard panel.highlightsNull else { return false }
            commitCellEditor(value: .null)
            return true
        default:
            return false
        }
    }

    /// Typing as a person would: the cell's text becomes `text` and the panel follows it. Used by scripted checks.
    func typeInCellEditor(_ text: String) {
        replaceCellEditorText(text)
        cellEditorPanel?.cellTextDidChange(text)
    }

    /// A key command typed in the cell being edited (moveDown:, insertNewline:, cancelOperation:). Used by scripted checks.
    func sendCellEditorCommand(_ selector: Selector) {
        guard let field = editingField, let editor = field.currentEditor() as? NSTextView else { return }
        if control(field, textView: editor, doCommandBy: selector) { return }
        if selector == #selector(NSResponder.insertNewline(_:)) { commitCellEditorText() }
    }

    var isEditingCell: Bool { editingField != nil }

    // MARK: Boolean check boxes

    func columnEditorKind(_ column: Int) -> CellEditorKind? {
        columnEditors[column]?.kind
    }

    /// The check box a boolean cell shows; nil for other columns, DEFAULT, SQL expressions and text that is no boolean.
    func toggleState(for value: CellValue?, column: Int) -> GridCellView.Toggle? {
        guard case .boolean = columnEditors[column]?.kind, let value else { return nil }
        switch value {
        case .null: return .null
        case .text(let text): return BooleanStyle.parse(text).map { $0 ? .on : .off }
        case .missing, .bytes, .expression: return nil
        }
    }

    /// Space, or a click on the check box of the active cell: flips the selected boolean cells. They all take the
    /// opposite of the active cell (NULL turns true), in one undo step. False when the active cell is no boolean.
    @discardableResult
    func toggleBooleanCells() -> Bool {
        guard isEditable, let active = cellSelection.active, let activeColumn = dataColumn(atDisplayPosition: active.column),
              case .boolean = columnEditors[activeColumn]?.kind else { return false }
        let current = content.currentValue(row: active.row, column: activeColumn)?.textValue.flatMap(BooleanStyle.parse) ?? false
        let edits = targetCellsForEditing().compactMap { cell -> GridCellEdit? in
            guard case .boolean(let style) = columnEditors[cell.column]?.kind else { return nil }
            let value = CellValue.text(style.text(!current))
            return content.currentValue(row: cell.row, column: cell.column) == value ? nil : GridCellEdit(row: cell.row, column: cell.column, value: value)
        }
        guard !edits.isEmpty else {
            NSSound.beep()
            return true
        }
        delegate?.dataGrid(self, didEditCells: edits, actionName: "Toggle Value")
        return true
    }

    /// A click on a check box toggles only when its cell is already the one active cell; otherwise it selects.
    func toggleIfOnlyActiveCell(_ cell: GridCell) -> Bool {
        guard cellSelection.cellCount == 1, cellSelection.active == cell else { return false }
        return toggleBooleanCells()
    }

    // MARK: Scripted checks

    /// `kind: … | text: … | list: … | footer: …` for the cell being edited.
    var cellEditorDescription: String {
        guard isEditingCell else { return "not editing" }
        var parts = ["text: " + cellEditorText]
        guard let panel = cellEditorPanel else { return (parts + ["no panel"]).joined(separator: " | ") }
        if panel.temporalKind != nil {
            parts.append("picker: " + panel.pickerSummary)
        } else {
            parts.append("list: " + panel.listSummary)
            parts.append("footer: " + panel.footerText)
        }
        parts.append(panel.isVisible ? "panel shown" : "panel hidden")
        return parts.joined(separator: " | ")
    }
}

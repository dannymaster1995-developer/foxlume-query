import AppKit
import FoxlumeQueryCore

/// Copying a cell range or rows as an IN list or UPDATE statements, pasting a clipboard block and filling cells with one value. Pasted and filled values go to
/// the delegate as staged edits, so they are saved, undone and previewed like typed ones.
extension DataGridView {
    // MARK: Copy

    /// The selected cells as TSV, one line per row and one field per column the selection touches; cells of those
    /// columns that are not selected stay empty. A single cell copies its plain value, as Copy Cell Value does.
    func copyCellSelection(includeHeader: Bool) {
        guard let text = cellSelectionText(includeHeader: includeHeader) else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func cellSelectionText(includeHeader: Bool) -> String? {
        let rows = cellSelection.affectedRows.filter { $0 < content.displayRowCount }
        let positions = Array(cellSelection.affectedColumns)
        let columns = positions.compactMap { dataColumn(atDisplayPosition: $0) }
        guard !rows.isEmpty, columns.count == positions.count else { return nil }
        if cellSelection.cellCount == 1, !includeHeader, let row = rows.first, let column = columns.first {
            let value = content.currentValue(row: row, column: column) ?? .null
            return value.isNull ? "NULL" : value.displayString
        }
        let values = rows.map { row -> [CellValue] in
            let picked = cellSelection.columns(inRow: row)
            return zip(positions, columns).map { position, column in
                picked.contains(position) ? (content.currentValue(row: row, column: column) ?? .null) : .missing
            }
        }
        return ResultExporter.export(columns: columns.map { content.columns[$0] }, rows: values, format: .tsv, includeHeader: includeHeader)
            .trimmingCharacters(in: .newlines)
    }

    // MARK: Copy as IN list and UPDATE

    /// "Copy As ▸ IN List": `(1, 2, 3)` from one column. Opened on the cell selection, it takes the selected cells of
    /// the clicked column (of the only column, when the selection spans one); otherwise the clicked column of the rows.
    func copyInList() {
        guard let text = inListText() else { return NSSound.beep() }
        setPasteboard(text)
    }

    func inListText() -> String? {
        let column: Int
        let rows: [Int]
        if !cellSelection.isEmpty, contextRows == nil || contextCellIsSelected {
            let selected = cellSelection.affectedColumns
            let clicked = contextCell.flatMap { displayPosition(ofTableColumn: $0.tableColumn) }
            guard let position = selected.count == 1 ? selected.first : (clicked ?? cellSelection.active?.column),
                  let dataColumn = dataColumn(atDisplayPosition: position) else { return nil }
            column = dataColumn
            rows = cellSelection.affectedRows.filter { cellSelection.columns(inRow: $0).contains(position) }
        } else {
            guard let cell = targetCell, let dataColumn = dataColumnIndex(atTableColumn: cell.tableColumn) else { return nil }
            column = dataColumn
            rows = Array(targetRows())
        }
        let values = rows.filter { $0 < content.displayRowCount }.compactMap { content.currentValue(row: $0, column: column) }
        return SQLRowCopy.inList(values, column: content.columns[column], dialect: dialectForCopy)
    }

    /// Why SQL UPDATE is disabled in the cell menu, or nil when it can be used.
    var updateCopyUnavailableReason: String? {
        guard let target = updateCopyTarget else { return "Only rows of a table can be copied as UPDATE statements." }
        guard let primaryKey = target.primaryKey else { return "The primary key of “\(target.table.name)” is not known yet." }
        return SQLRowCopy.updateUnavailableReason(columns: content.columns.map(\.name), primaryKey: primaryKey)
    }

    /// "Copy As ▸ SQL UPDATE": one statement per selected row that is already in the table, with the values the row
    /// shows now, so a copied edited row applies the edits.
    func copyUpdates() {
        guard let text = updateText() else { return NSSound.beep() }
        setPasteboard(text)
    }

    func updateText() -> String? {
        guard updateCopyUnavailableReason == nil, let target = updateCopyTarget, let primaryKey = target.primaryKey else { return nil }
        let rows = targetRows().filter { $0 < content.rows.count }.map { row in
            SQLRowCopy.UpdateRow(
                current: (0..<content.columns.count).map { content.currentValue(row: row, column: $0) ?? .null },
                original: content.rows[row]
            )
        }
        guard !rows.isEmpty else { return nil }
        return SQLRowCopy.updates(table: target.table, columns: content.columns, primaryKey: primaryKey, rows: rows, dialect: dialectForCopy)
    }

    private func setPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Paste

    /// Pastes the clipboard (TSV, else CSV, else one value per line) as TablePro does: a block as wide as the table adds
    /// rows; any other block fills cells from the top left selected cell, clipped at the last row and column.
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return NSSound.beep() }
        pasteText(text)
    }

    /// The paste itself, separate from the pasteboard so scripted checks and tests can drive it.
    func pasteText(_ text: String) {
        lastRefusal = nil
        guard isEditable else { return refuse(readOnlyReason ?? "These rows are read-only.") }
        let anchor = cellSelection.topLeft.map { (row: $0.row, column: $0.column) }
            ?? tableView.selectedRowIndexes.first.map { (row: $0, column: 0) }
        let plan: GridPastePlan
        switch GridPastePlan.make(block: GridPasteParser.parse(text), anchor: anchor, rowCount: content.displayRowCount, columnNames: content.columns.map(\.name)) {
        case .success(let made): plan = made
        case .failure(.noAnchor): return refuse("Select the cell where the pasted values should start.")
        case .failure(.empty): return NSSound.beep()
        }
        var edits: [GridCellEdit] = []
        for cell in plan.cells {
            guard let column = dataColumn(atDisplayPosition: cell.column) else { continue }
            if isImmutable(column) {
                return refuse("“\(content.columns[column].name)” cannot be edited, so nothing was pasted.")
            }
            guard !content.changes.deletions.contains(cell.row) else { continue }
            edits.append(GridCellEdit(row: cell.row, column: column, value: pastedValue(cell.text, row: cell.row, column: column)))
        }
        // New rows: NULL is NULL, an empty field and a fixed column take the column default.
        let newRows = plan.newRows.map { fields in
            fields.enumerated().map { column, text -> CellValue? in
                text.isEmpty || isImmutable(column) ? nil : GridPastePlan.value(for: text)
            }
        }
        guard !edits.isEmpty || !newRows.isEmpty else { return NSSound.beep() }
        let firstNewRow = content.displayRowCount
        delegate?.dataGrid(self, paste: edits, newRows: newRows)
        // Leave the pasted block selected, so it is easy to see and to copy again.
        if let first = plan.cells.first, let last = plan.cells.last {
            var selection = GridSelection.single(GridCell(row: first.row, column: first.column))
            selection.extend(to: GridCell(row: last.row, column: last.column))
            setCellSelection(selection)
        } else if !newRows.isEmpty, content.displayRowCount > firstNewRow {
            tableView.scrollRowToVisible(content.displayRowCount - 1)
            tableView.selectRowIndexes(IndexSet(integersIn: firstNewRow..<content.displayRowCount), byExtendingSelection: false)
        }
    }

    /// Text for a cell as a typed edit would read it: the word NULL is NULL, a hex literal stays binary in a binary cell.
    private func pastedValue(_ text: String, row: Int, column: Int) -> CellValue {
        if case .bytes = content.currentValue(row: row, column: column) ?? .null, let data = Data(hexLiteral: text) {
            return .bytes(data)
        }
        return GridPastePlan.value(for: text)
    }

    private func refuse(_ message: String) {
        lastRefusal = message
        NSSound.beep()
        guard let window else { return }
        Alerts.showError(DatabaseError.unsupported(message), title: "Nothing was changed", in: window)
    }

    // MARK: Fill

    /// "Fill Column…" in the header menu: one value (or NULL) in every loaded row that is not marked for deletion.
    func fillColumn(_ column: Int) {
        guard isEditable else { return refuse(readOnlyReason ?? "These rows are read-only.") }
        guard !isImmutable(column), let name = content.columns[safe: column]?.name else { return NSSound.beep() }
        let rows = (0..<content.displayRowCount).filter { !content.changes.deletions.contains($0) }
        guard !rows.isEmpty else { return NSSound.beep() }
        askFillValue(title: "Fill column “\(name)”", count: rows.count) { [weak self] value in
            guard let self else { return }
            self.delegate?.dataGrid(self, didEditCells: rows.map { GridCellEdit(row: $0, column: column, value: value) }, actionName: "Fill Column")
        }
    }

    /// "Fill Selected Cells…" in the cell menu.
    @objc func fillSelectedCells(_ sender: Any?) {
        guard isEditable else { return refuse(readOnlyReason ?? "These rows are read-only.") }
        let cells = targetCellsForEditing()
        guard !cells.isEmpty else { return NSSound.beep() }
        askFillValue(title: cells.count == 1 ? "Fill cell" : "Fill \(cells.count) cells", count: cells.count) { [weak self] value in
            guard let self else { return }
            self.delegate?.dataGrid(self, didEditCells: cells.map { GridCellEdit(row: $0.row, column: $0.column, value: value) }, actionName: "Fill Cells")
        }
    }

    /// Asks for the value as a sheet: a text field and a "Set to NULL" box.
    private func askFillValue(title: String, count: Int, then apply: @escaping (CellValue) -> Void) {
        guard let window else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 26, width: 280, height: 24))
        field.placeholderString = "Value"
        field.font = Theme.monospaced(12)
        field.setAccessibilityIdentifier("fillValue")
        let nullBox = NSButton(checkboxWithTitle: "Set to NULL", target: nil, action: nil)
        nullBox.frame = NSRect(x: 0, y: 0, width: 280, height: 18)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 50))
        accessory.addSubview(field)
        accessory.addSubview(nullBox)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = count == 1 ? "The change is staged; review it and Save to apply." : "This sets \(count.groupedText) cells. The change is staged; review it and Save to apply."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Fill")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            apply(nullBox.state == .on ? .null : .text(field.stringValue))
        }
    }
}

import AppKit
import FoxlumeQueryCore

/// Cell range selection, as in TablePro: click a cell, drag or Shift-click for a rectangle, ⌘-click to add or remove
/// cells, Shift-arrows to extend. The table rows the cells touch stay selected, so every row command still works.
extension DataGridView {
    // MARK: Column positions

    /// Data column indexes in on-screen order (columns can be dragged around).
    var displayedDataColumns: [Int] {
        if let displayOrderCache { return displayOrderCache }
        let order = tableView.tableColumns.compactMap { dataColumnIndex($0) }
        displayOrderCache = order
        return order
    }

    func displayPosition(ofDataColumn column: Int) -> Int? {
        displayedDataColumns.firstIndex(of: column)
    }

    func displayPosition(ofTableColumn index: Int) -> Int? {
        dataColumnIndex(atTableColumn: index).flatMap(displayPosition(ofDataColumn:))
    }

    func dataColumn(atDisplayPosition position: Int) -> Int? {
        displayedDataColumns[safe: position]
    }

    func tableColumnIndex(ofDisplayPosition position: Int) -> Int? {
        guard let column = dataColumn(atDisplayPosition: position) else { return nil }
        return tableView.tableColumns.firstIndex { $0.identifier.rawValue == "c\(column)" }
    }

    // MARK: State

    /// Replaces the cell selection, selects the rows it touches and redraws the visible cells.
    func setCellSelection(_ selection: GridSelection, syncRows: Bool = true) {
        cellSelection = selection
        if syncRows {
            isSyncingRowSelection = true
            let rows = selection.isEmpty ? IndexSet() : selection.affectedRows
            if rows != tableView.selectedRowIndexes {
                tableView.selectRowIndexes(rows, byExtendingSelection: false)
            }
            isSyncingRowSelection = false
        }
        updateCellSelectionAppearance()
        updateHeaderIndicators()
        delegate?.dataGridSelectionDidChange(self)
    }

    func clearCellSelection() {
        guard !cellSelection.isEmpty else { return }
        setCellSelection(.empty)
    }

    func selectionMark(row: Int, tableColumn: NSTableColumn) -> GridCellView.SelectionMark {
        guard !cellSelection.isEmpty else { return .none }
        guard let column = dataColumnIndex(tableColumn) else {
            return cellSelection.affectedRows.contains(row) ? .row : .none
        }
        guard let position = displayPosition(ofDataColumn: column) else { return .none }
        let cell = GridCell(row: row, column: position)
        guard cellSelection.contains(cell) else { return .none }
        return cellSelection.active == cell ? .active : .selected
    }

    /// Repaints the rows on screen; cell views are reused, so each one is told its mark again.
    func updateCellSelectionAppearance() {
        let showsCells = !cellSelection.isEmpty
        tableView.enumerateAvailableRowViews { rowView, row in
            (rowView as? GridRowView)?.showsCellSelection = showsCells
            for index in 0..<self.tableView.numberOfColumns {
                guard let cell = rowView.view(atColumn: index) as? GridCellView else { continue }
                cell.backgroundStyle = rowView.interiorBackgroundStyle
                cell.setSelectionMark(self.selectionMark(row: row, tableColumn: self.tableView.tableColumns[index]))
            }
        }
    }

    /// The cells Set NULL, Fill and friends change: the selected cells, or the context-menu cell, or the cell the
    /// selected rows share in the clicked column. Data column indexes; deleted rows and fixed columns are left out.
    func targetCellsForEditing() -> [(row: Int, column: Int)] {
        let cells: [(row: Int, column: Int)]
        if !cellSelection.isEmpty, contextCell == nil || contextCellIsSelected {
            cells = cellSelection.affectedRows.flatMap { row in
                cellSelection.columns(inRow: row).compactMap { position in dataColumn(atDisplayPosition: position).map { (row, $0) } }
            }
        } else if let cell = targetCell, let column = dataColumnIndex(atTableColumn: cell.tableColumn) {
            cells = targetRows().map { ($0, column) }
        } else {
            cells = []
        }
        return cells.filter { !content.changes.deletions.contains($0.row) && !isImmutable($0.column) && $0.row < content.displayRowCount }
    }

    /// Figures for the status bar when two or more cells are selected.
    var selectionStatistics: SelectionStatistics? {
        guard cellSelection.cellCount >= 2 else { return nil }
        var cells: [(value: CellValue, numeric: Bool)] = []
        for row in cellSelection.affectedRows where row < content.displayRowCount {
            for position in cellSelection.columns(inRow: row) {
                guard let column = dataColumn(atDisplayPosition: position) else { continue }
                cells.append((content.currentValue(row: row, column: column) ?? .null, content.columns[safe: column]?.isNumeric == true))
            }
        }
        return SelectionStatistics(cells)
    }

    /// Selects a whole column (header ⌘-click, Select Column, scripts).
    func selectColumn(_ dataColumn: Int, adding: Bool) {
        guard let position = displayPosition(ofDataColumn: dataColumn), content.displayRowCount > 0 else { return }
        var selection = cellSelection
        selection.selectColumn(position, rowCount: content.displayRowCount, adding: adding)
        setCellSelection(selection)
        tableView.window?.makeFirstResponder(tableView)
    }

    /// Selects a rectangle by display rows and data columns. Used by scripted UI checks.
    func selectCells(rows: ClosedRange<Int>, columns: ClosedRange<Int>) {
        guard let first = displayPosition(ofDataColumn: columns.lowerBound), let last = displayPosition(ofDataColumn: columns.upperBound) else { return }
        var selection = GridSelection.single(GridCell(row: rows.lowerBound, column: first))
        selection.extend(to: GridCell(row: rows.upperBound, column: last))
        setCellSelection(selection)
    }

    // MARK: Mouse

    /// Handles a press in a data cell; false leaves it to the table (row numbers, the foreign key arrow, empty space).
    func handleCellMouseDown(_ event: NSEvent, at point: NSPoint) -> Bool {
        let row = tableView.row(at: point)
        let tableColumn = tableView.column(at: point)
        guard row >= 0, tableColumn >= 0, let position = displayPosition(ofTableColumn: tableColumn) else {
            clearCellSelection()
            return false
        }
        if let cellView = tableView.view(atColumn: tableColumn, row: row, makeIfNecessary: false) as? GridCellView,
           cellView.isReferenceButtonHit(at: cellView.convert(point, from: tableView)) {
            return false
        }
        tableView.window?.makeFirstResponder(tableView)
        if event.clickCount >= 2 {
            beginEditing(row: row, tableColumn: tableColumn)
            return true
        }
        let cell = GridCell(row: row, column: position)
        let flags = event.modifierFlags.intersection([.shift, .command, .option, .control])
        var selection = cellSelection
        if flags == [.shift] {
            if selection.isEmpty, tableView.selectedRow >= 0 {
                // From a row selection, the rectangle starts at the first selected row.
                selection = .single(GridCell(row: tableView.selectedRow, column: 0))
            }
            selection.extend(to: cell)
            setCellSelection(selection)
            trackDrag(from: selection.anchor ?? cell, base: .empty)
        } else if flags == [.command] {
            let base = selection
            trackDrag(from: cell, base: base, toggleOnClick: true)
        } else {
            setCellSelection(.single(cell))
            trackDrag(from: cell, base: .empty)
        }
        return true
    }

    /// Follows the pointer until the button is released. `base` is kept under a ⌘-drag; a ⌘-click that never moved
    /// toggles the cell instead.
    private func trackDrag(from origin: GridCell, base: GridSelection, toggleOnClick: Bool = false) {
        guard let window = tableView.window else { return }
        var moved = false
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { break }
            tableView.autoscroll(with: event)
            guard let cell = cell(near: tableView.convert(event.locationInWindow, from: nil)) else { continue }
            if cell != origin { moved = true }
            guard moved else { continue }
            var selection = cellSelection
            if toggleOnClick {
                selection.add(from: origin, to: cell, base: base)
            } else {
                selection.extend(to: cell)
            }
            if selection != cellSelection { setCellSelection(selection) }
        }
        if toggleOnClick, !moved {
            var selection = base
            if selection.isEmpty, tableView.selectedRowIndexes.count == 1, let row = tableView.selectedRowIndexes.first, row != origin.row {
                selection = .single(GridCell(row: row, column: origin.column))
            }
            selection.toggle(origin)
            setCellSelection(selection)
        }
    }

    /// The cell under a dragged pointer, clamped to the grid when it leaves it.
    private func cell(near point: NSPoint) -> GridCell? {
        let rowCount = tableView.numberOfRows
        let positions = displayedDataColumns.count
        guard rowCount > 0, positions > 0 else { return nil }
        var row = tableView.row(at: point)
        if row < 0 { row = point.y < 0 ? 0 : rowCount - 1 }
        var position = tableView.column(at: point) >= 0 ? displayPosition(ofTableColumn: tableView.column(at: point)) : nil
        if position == nil {
            let firstX = tableColumnIndex(ofDisplayPosition: 0).map { tableView.rect(ofColumn: $0).minX } ?? 0
            position = point.x < firstX ? 0 : positions - 1
        }
        return GridCell(row: min(max(row, 0), rowCount - 1), column: position ?? 0)
    }

    /// Before a context menu opens: a click outside both selections selects that cell.
    func prepareContextSelection(at point: NSPoint) {
        let row = tableView.row(at: point)
        let tableColumn = tableView.column(at: point)
        guard row >= 0, let position = displayPosition(ofTableColumn: tableColumn) else { return }
        let cell = GridCell(row: row, column: position)
        if cellSelection.contains(cell) { return }
        if cellSelection.isEmpty, tableView.selectedRowIndexes.contains(row) { return }
        setCellSelection(.single(cell))
    }

    // MARK: Keyboard

    /// Arrows move the active cell and Shift-arrows extend the range (⌘ goes to the edge), Escape ends the cell
    /// selection and Shift-Space widens it to whole rows. False leaves the key to the table.
    func handleCellKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.shift, .command, .option, .control])
        let direction: GridSelection.Direction?
        switch event.keyCode {
        case 123: direction = .left
        case 124: direction = .right
        case 125: direction = .down
        case 126: direction = .up
        case 53:
            guard !cellSelection.isEmpty else { return false }
            setCellSelection(.empty)
            return true
        case 49 where flags == [.shift]:
            guard !cellSelection.isEmpty else { return false }
            let rows = cellSelection.affectedRows
            setCellSelection(.empty, syncRows: false)
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            return true
        default:
            return false
        }
        guard let direction, flags.isSubset(of: [.shift, .command]) else { return false }
        var selection = cellSelection
        if selection.isEmpty {
            // From a single selected row, the arrows enter cell selection at its first (or clicked) column.
            guard direction == .left || direction == .right, tableView.selectedRowIndexes.count == 1, let row = tableView.selectedRowIndexes.first else { return false }
            let start = displayPosition(ofTableColumn: tableView.lastClickedColumn) ?? 0
            selection = .single(GridCell(row: row, column: start))
            if !flags.contains(.shift) {
                setCellSelection(selection)
                scrollToActiveCell()
                return true
            }
        }
        let rowCount = content.displayRowCount
        let columnCount = displayedDataColumns.count
        if flags.contains(.shift) {
            selection.extend(direction, toEdge: flags.contains(.command), rowCount: rowCount, columnCount: columnCount)
        } else {
            selection.move(direction, toEdge: flags.contains(.command), rowCount: rowCount, columnCount: columnCount)
        }
        setCellSelection(selection)
        scrollToActiveCell()
        return true
    }

    func scrollToActiveCell() {
        guard let active = cellSelection.active else { return }
        tableView.scrollRowToVisible(active.row)
        if let column = tableColumnIndex(ofDisplayPosition: active.column) { tableView.scrollColumnToVisible(column) }
    }
}

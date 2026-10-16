import AppKit
import FoxlumeQueryCore

/// Hiding and showing columns, Size to Fit, Jump to Column and the column layout a table tab remembers. Hidden columns
/// stay in the data: row copies, export, Save and Preview SQL see every column; only what the grid draws, and so the
/// cell selection and its copies, leaves them out.
extension DataGridView {
    /// Size to Fit never makes a column wider than this.
    static let fitMaximumWidth: CGFloat = 800
    /// Size to Fit measures at most this many rows, and this many characters of each value.
    static let fitRowLimit = 1_000
    static let fitCharacterLimit = 200

    // MARK: Layout

    /// The columns as arranged now: on-screen order, widths and the hidden ones.
    var columnLayout: GridColumnLayout {
        GridColumnLayout(columns: tableView.tableColumns.compactMap { tableColumn in
            guard let index = dataColumnIndex(tableColumn), let column = content.columns[safe: index] else { return nil }
            return GridColumnLayout.Column(name: column.name, width: Double(tableColumn.width), isHidden: tableColumn.isHidden)
        })
    }

    func tableColumn(forDataColumn column: Int) -> NSTableColumn? {
        tableView.tableColumns.first { $0.identifier.rawValue == "c\(column)" }
    }

    /// The table column index of the first data column on screen.
    var firstVisibleTableColumn: Int? { tableColumnIndex(ofDisplayPosition: 0) }

    func isColumnHidden(_ column: Int) -> Bool {
        tableColumn(forDataColumn: column)?.isHidden ?? false
    }

    /// Hiding a column needs another one left on screen.
    var canHideColumn: Bool { displayedDataColumns.count > 1 }

    /// After the user moved, resized, hid or showed columns: the delegate may remember the new arrangement.
    func columnLayoutDidChange() {
        displayOrderCache = nil
        delegate?.dataGrid(self, didChangeColumnLayout: columnLayout)
    }

    /// Reset Column Layout: result order, automatic widths and every column shown; a remembered layout is forgotten.
    func resetColumnLayout() {
        guard !content.columns.isEmpty else { return }
        cellSelection = .empty
        rebuildColumns(useSavedLayout: false)
        updateHeaderIndicators()
        tableView.reloadData()
        delegate?.dataGridSelectionDidChange(self)
        delegate?.dataGrid(self, didChangeColumnLayout: nil)
    }

    // MARK: Hide and show

    /// Hides or shows one column. The last column on screen cannot be hidden; returns whether anything changed.
    @discardableResult
    func setColumn(_ column: Int, hidden: Bool) -> Bool {
        guard let tableColumn = tableColumn(forDataColumn: column), tableColumn.isHidden != hidden else { return false }
        if hidden, !canHideColumn {
            NSSound.beep()
            return false
        }
        tableColumn.isHidden = hidden
        visibleColumnsChanged()
        return true
    }

    func showAllColumns() {
        let hidden = tableView.tableColumns.filter { $0.isHidden && dataColumnIndex($0) != nil }
        guard !hidden.isEmpty else { return }
        hidden.forEach { $0.isHidden = false }
        visibleColumnsChanged()
    }

    /// Display positions moved, so a cell selection would now point at other cells: it ends.
    private func visibleColumnsChanged() {
        displayOrderCache = nil
        if !cellSelection.isEmpty { setCellSelection(.empty) }
        updateHeaderIndicators()
        columnLayoutDidChange()
    }

    // MARK: Size to fit

    /// The width that shows the header and the loaded rows' values (edits included), up to `fitMaximumWidth`.
    func fitWidth(forDataColumn column: Int) -> CGFloat {
        guard column < content.columns.count else { return Self.minimumColumnWidth }
        let count = min(content.displayRowCount, Self.fitRowLimit)
        let values = (0..<count).map { content.currentValue(row: $0, column: column) ?? .text("DEFAULT") }
        var width = measuredWidth(column: column, values: values, characters: Self.fitCharacterLimit)
        if referenceColumns.contains(column) { width += 16 }
        return min(max(width, Self.minimumColumnWidth), Self.fitMaximumWidth)
    }

    func sizeColumnToFit(_ column: Int) {
        guard let tableColumn = tableColumn(forDataColumn: column) else { return }
        tableColumn.width = fitWidth(forDataColumn: column)
        columnLayoutDidChange()
    }

    /// Sizes every column on screen to fit.
    func sizeAllColumnsToFit() {
        guard !content.columns.isEmpty else { return }
        for tableColumn in tableView.tableColumns where !tableColumn.isHidden {
            guard let column = dataColumnIndex(tableColumn) else { continue }
            tableColumn.width = fitWidth(forDataColumn: column)
        }
        columnLayoutDidChange()
    }

    // MARK: Jump to column

    /// Scrolls to a column and selects its cell in the current row (the first row when nothing is selected). A hidden
    /// column is shown first.
    func jumpToColumn(_ column: Int) {
        guard let tableColumn = tableColumn(forDataColumn: column) else { return NSSound.beep() }
        let row = cellSelection.active?.row ?? (tableView.selectedRow >= 0 ? tableView.selectedRow : 0)
        if tableColumn.isHidden { setColumn(column, hidden: false) }
        if let index = tableView.tableColumns.firstIndex(of: tableColumn) { tableView.scrollColumnToVisible(index) }
        if row < content.displayRowCount, let position = displayPosition(ofDataColumn: column) {
            setCellSelection(.single(GridCell(row: row, column: position)))
            scrollToActiveCell()
        }
        window?.makeFirstResponder(tableView)
    }

    /// ⌃⌘J: a field over the header that filters the column names; Return jumps to the chosen one.
    func showJumpToColumn() {
        guard !content.columns.isEmpty else { return NSSound.beep() }
        showColumnPicker(.jump, near: nil)
    }

    /// The Columns list: a check box per column and Show All.
    func showColumnsList(near column: Int? = nil) {
        guard !content.columns.isEmpty else { return NSSound.beep() }
        showColumnPicker(.visibility, near: column)
    }

    private func showColumnPicker(_ mode: GridColumnPickerController.Mode, near column: Int?) {
        columnPicker?.close()
        let picker = GridColumnPickerController(mode: mode, grid: self)
        columnPicker = picker
        guard let header = tableView.headerView, header.window != nil else { return }
        var anchor = header.visibleRect
        if let column, let tableColumn = tableColumn(forDataColumn: column), let index = tableView.tableColumns.firstIndex(of: tableColumn) {
            anchor = header.headerRect(ofColumn: index).intersection(header.visibleRect)
        } else {
            anchor = NSRect(x: anchor.minX + 8, y: anchor.minY, width: min(220, anchor.width), height: anchor.height)
        }
        picker.show(relativeTo: anchor, of: header)
    }

    // MARK: Header menu actions

    @objc func hideColumnFromMenu(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? Int else { return }
        setColumn(column, hidden: true)
    }

    @objc func showColumnsFromMenu(_ sender: NSMenuItem) {
        showColumnsList(near: sender.representedObject as? Int)
    }

    @objc func jumpToColumnFromMenu(_ sender: NSMenuItem) {
        showJumpToColumn()
    }

    @objc func sizeColumnToFitFromMenu(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? Int else { return }
        sizeColumnToFit(column)
    }

    @objc func sizeAllColumnsToFitFromMenu(_ sender: NSMenuItem) {
        sizeAllColumnsToFit()
    }

    @objc func resetColumnLayoutFromMenu(_ sender: NSMenuItem) {
        resetColumnLayout()
    }

    /// The column items of the header menu; `column` is nil for the row number header and the empty strip.
    func addColumnItems(to menu: NSMenu, column: Int?) {
        func item(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = column
            return item
        }
        if column != nil {
            menu.addItem(item("Hide Column", #selector(hideColumnFromMenu(_:)), enabled: canHideColumn))
        }
        menu.addItem(item("Show Columns…", #selector(showColumnsFromMenu(_:))))
        let jump = item("Jump to Column…", #selector(jumpToColumnFromMenu(_:)))
        jump.keyEquivalent = "j"
        jump.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(jump)
        menu.addItem(.separator())
        if column != nil {
            menu.addItem(item("Size Column to Fit", #selector(sizeColumnToFitFromMenu(_:))))
        }
        menu.addItem(item("Size All Columns to Fit", #selector(sizeAllColumnsToFitFromMenu(_:))))
        menu.addItem(item("Reset Column Layout", #selector(resetColumnLayoutFromMenu(_:))))
    }

    /// The header menu for the row number header and the strip after the last column.
    func headerMenuWithoutColumn() -> NSMenu? {
        guard !content.columns.isEmpty else { return nil }
        let menu = NSMenu()
        addColumnItems(to: menu, column: nil)
        return menu
    }
}

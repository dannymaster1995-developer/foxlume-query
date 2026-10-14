import AppKit
import FoxlumeQueryCore

@MainActor
protocol DataGridViewDelegate: AnyObject {
    func dataGrid(_ grid: DataGridView, didEditRow row: Int, column: Int, value: CellValue)
    func dataGrid(_ grid: DataGridView, didChangeSort sort: [SortKey])
    func dataGridSelectionDidChange(_ grid: DataGridView)
    func dataGridDeleteSelectedRows(_ grid: DataGridView)
    func dataGrid(_ grid: DataGridView, extraMenuItemsFor rows: IndexSet) -> [NSMenuItem]
    /// The foreign key arrow in a cell was clicked.
    func dataGrid(_ grid: DataGridView, followReferenceAtRow row: Int, column: Int)
    /// "Search All Rows" in the find bar: filter on the server to rows where any column contains `text`.
    func dataGrid(_ grid: DataGridView, searchServerFor text: String)
}

extension DataGridViewDelegate {
    func dataGrid(_ grid: DataGridView, didEditRow row: Int, column: Int, value: CellValue) {}
    func dataGrid(_ grid: DataGridView, didChangeSort sort: [SortKey]) {}
    func dataGridSelectionDidChange(_ grid: DataGridView) {}
    func dataGridDeleteSelectedRows(_ grid: DataGridView) {}
    func dataGrid(_ grid: DataGridView, followReferenceAtRow row: Int, column: Int) {}
    func dataGrid(_ grid: DataGridView, searchServerFor text: String) {}
    func dataGrid(_ grid: DataGridView, extraMenuItemsFor rows: IndexSet) -> [NSMenuItem] { [] }
}

/// What the grid shows: loaded rows, plus unsaved edits drawn on top of them.
struct DataGridContent {
    var columns: [ResultColumn] = []
    var rows: [[CellValue]] = []
    var changes = PendingChanges()
    /// Index of the first row in the whole result, used for row numbers on later pages.
    var rowOffset = 0

    var displayRowCount: Int { rows.count + changes.insertions.count }

    func isInserted(_ row: Int) -> Bool { row >= rows.count }

    /// The value currently shown in a cell. For new rows, nil means DEFAULT.
    func currentValue(row: Int, column: Int) -> CellValue? {
        if row < rows.count {
            return changes.value(row: row, column: column) ?? rows[row][safe: column] ?? .null
        }
        let insertion = row - rows.count
        guard let values = changes.insertions[safe: insertion], let value = values[safe: column] else { return nil }
        if case .value(let cell) = value { return cell }
        return nil
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

final class DataGridView: NSView {
    weak var delegate: DataGridViewDelegate?

    private let scrollView = NSScrollView()
    let tableView = GridTableView()
    private(set) var content = DataGridContent()
    private var isLocalSortEnabled = false

    /// When false, header clicks do not sort (Redis key lists are always sorted by key).
    var allowsColumnSort = true
    /// Columns that are never editable, such as MongoDB `_id`.
    var immutableColumns: Set<String> = []

    /// When false, cells cannot be edited and edit actions are hidden.
    var isEditable = false {
        didSet {
            guard oldValue != isEditable, tableView.numberOfRows > 0 else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        }
    }

    /// Data columns that belong to a foreign key; their cells show an arrow to the referenced row.
    var referenceColumns: Set<Int> = [] {
        didSet { if referenceColumns != oldValue { tableView.reloadData() } }
    }

    // Find bar state (see DataGridView+Find.swift).
    let findBar = GridFindBar()
    var findBarHeight: NSLayoutConstraint?
    var findMatches: [GridCellKey] = []
    var findMatchSet: Set<GridCellKey> = []
    var currentFindMatch: Int?
    /// Offer "Search All Rows" in the find bar (table grids of SQL engines).
    var allowsServerSearch = false

    /// SQL tables accept written SQL such as CURRENT_TIMESTAMP as a new value; document stores do not.
    var allowsSQLExpressions = false
    /// The DEFAULT keyword works in UPDATE and INSERT on every SQL engine except SQLite.
    var allowsDefaultKeyword = false

    /// The cell and rows a context menu was opened on. Menu commands act on these; keyboard commands use the selection.
    private(set) var contextCell: (row: Int, tableColumn: Int)?
    private var contextRows: IndexSet?
    var showsRowNumbers = true {
        didSet { rowNumberColumn?.isHidden = !showsRowNumbers }
    }

    var font = Theme.monospaced(CGFloat(SettingsStore.shared.settings.gridFontSize)) {
        didSet {
            tableView.rowHeight = ceil(font.boundingRectForFont.height) + 6
            tableView.reloadData()
        }
    }

    /// Name used for `INSERT INTO` when copying rows as SQL.
    var tableNameForCopy = "table_name"
    var dialectForCopy: SQLDialect = .postgresql

    private static let rowNumberIdentifier = NSUserInterfaceItemIdentifier("eq.rownumber")
    private var rowNumberColumn: NSTableColumn? {
        tableView.tableColumns.first { $0.identifier == Self.rowNumberIdentifier }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        tableView.gridView = self
        tableView.dataSource = self
        tableView.delegate = self
        // Rows paint their own stripes so themes can color them.
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = Theme.gridBackground
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: ThemeManager.didChangeNotification, object: nil)
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = ceil(font.boundingRectForFont.height) + 6
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.target = self
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self
        tableView.setAccessibilityIdentifier("dataGrid")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(findBar)
        addSubview(scrollView)
        let height = findBar.heightAnchor.constraint(equalToConstant: 0)
        findBarHeight = height
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: topAnchor),
            findBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            height,
            scrollView.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        configureFindBar()
    }

    @objc private func themeChanged() {
        tableView.backgroundColor = Theme.gridBackground
        tableView.reloadData()
    }

    // MARK: - Content

    /// Replace everything. Columns are rebuilt only when they changed, so widths survive a refresh.
    func setContent(_ newContent: DataGridContent, localSort: Bool = false) {
        let columnsChanged = newContent.columns.map(\.name) != content.columns.map(\.name) || tableView.tableColumns.isEmpty
        content = newContent
        isLocalSortEnabled = localSort
        if columnsChanged { rebuildColumns() }
        refreshFindMatches(keepPosition: false)
        tableView.reloadData()
    }

    /// Update only the edit overlay, keeping selection and scroll position.
    func setChanges(_ changes: PendingChanges) {
        let oldCount = content.displayRowCount
        content.changes = changes
        if oldCount != content.displayRowCount {
            tableView.noteNumberOfRowsChanged()
        }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<content.displayRowCount), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    /// Shows the sort arrows without reporting a sort change back to the delegate.
    func setSortIndicator(_ sort: [SortKey]) {
        let descriptors = sort.compactMap { key -> NSSortDescriptor? in
            guard let index = content.columns.firstIndex(where: { $0.name == key.column }) else { return nil }
            return NSSortDescriptor(key: "c\(index)", ascending: key.ascending)
        }
        guard descriptors != tableView.sortDescriptors else { return }
        isApplyingSortIndicator = true
        tableView.sortDescriptors = descriptors
        isApplyingSortIndicator = false
    }

    private var isApplyingSortIndicator = false

    var selectedRows: IndexSet { tableView.selectedRowIndexes }

    func selectRow(_ row: Int) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func scrollToRow(_ row: Int) {
        guard row >= 0, row < content.displayRowCount else { return }
        tableView.scrollRowToVisible(row)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func rebuildColumns() {
        for column in tableView.tableColumns.reversed() {
            tableView.removeTableColumn(column)
        }
        let numberColumn = NSTableColumn(identifier: Self.rowNumberIdentifier)
        numberColumn.title = "#"
        numberColumn.width = rowNumberWidth()
        numberColumn.minWidth = 28
        numberColumn.isEditable = false
        numberColumn.isHidden = !showsRowNumbers
        numberColumn.headerCell.alignment = .right
        tableView.addTableColumn(numberColumn)

        for (index, column) in content.columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
            tableColumn.title = column.name
            tableColumn.headerToolTip = column.typeName.isEmpty ? column.name : "\(column.name) · \(column.typeName)"
            tableColumn.width = idealWidth(for: index)
            tableColumn.minWidth = 40
            tableColumn.maxWidth = 2000
            if allowsColumnSort {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: tableColumn.identifier.rawValue, ascending: true)
            }
            tableView.addTableColumn(tableColumn)
        }
    }

    private func rowNumberWidth() -> CGFloat {
        let digits = String(content.rowOffset + max(content.displayRowCount, 1)).count
        return CGFloat(max(3, digits)) * 8 + 16
    }

    private func idealWidth(for column: Int) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let header = (content.columns[column].name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)]).width + 28
        var widest = header
        for row in content.rows.prefix(60) {
            guard let value = row[safe: column] else { continue }
            let text = Self.displayText(value)
            let sample = text.count > 60 ? String(text.prefix(60)) : text
            widest = max(widest, (sample as NSString).size(withAttributes: attributes).width + 16)
        }
        return min(max(widest, 60), 360)
    }

    static func displayText(_ value: CellValue) -> String {
        switch value {
        case .missing:
            return "No Field"
        case .null:
            return "NULL"
        case .bytes(let data):
            let shown = data.prefix(64)
            return "0x" + Data(shown).hexString + (data.count > 64 ? "…" : "")
        case .text(let text):
            let limited = text.count > 500 ? String(text.prefix(500)) + "…" : text
            return limited.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        case .expression(let sql):
            return sql
        }
    }

    fileprivate func dataColumnIndex(_ tableColumn: NSTableColumn?) -> Int? {
        guard let identifier = tableColumn?.identifier.rawValue, identifier.hasPrefix("c") else { return nil }
        return Int(identifier.dropFirst())
    }

    /// Maps an NSTableView column index (which changes when columns are reordered) to a result column.
    func dataColumnIndex(atTableColumn index: Int) -> Int? {
        guard index >= 0, index < tableView.tableColumns.count else { return nil }
        return dataColumnIndex(tableView.tableColumns[index])
    }

    // MARK: - Editing

    @objc private func doubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        let column = tableView.clickedColumn
        guard row >= 0, column >= 0 else { return }
        beginEditing(row: row, tableColumn: column)
    }

    func beginEditing(row: Int, tableColumn: Int) {
        guard isEditable, let column = dataColumnIndex(atTableColumn: tableColumn), !isImmutable(column) else { return }
        guard !content.changes.deletions.contains(row) else { NSSound.beep(); return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard let cell = tableView.view(atColumn: tableColumn, row: row, makeIfNecessary: true) as? GridCellView else { return }
        cell.prepareForEditing()
        tableView.editColumn(tableColumn, row: row, with: nil, select: true)
    }

    fileprivate func commitEdit(row: Int, column: Int, text: String) {
        let previous = content.currentValue(row: row, column: column)
        let newValue: CellValue
        if case .bytes = previous ?? .null, let data = Data(hexLiteral: text) {
            newValue = .bytes(data)
        } else if (previous == nil || previous?.isAbsent == true) && text.isEmpty {
            return
        } else {
            newValue = .text(text)
        }
        if newValue == previous { return }
        delegate?.dataGrid(self, didEditRow: row, column: column, value: newValue)
    }

    fileprivate func setSelectedCells(to value: CellValue) {
        guard let cell = targetCell, let dataColumn = dataColumnIndex(atTableColumn: cell.tableColumn) else { return }
        for row in targetRows() {
            delegate?.dataGrid(self, didEditRow: row, column: dataColumn, value: value)
        }
    }

    // MARK: - Copy

    func targetRows() -> IndexSet {
        contextRows ?? tableView.selectedRowIndexes
    }

    /// Row and table column for single-cell commands: the context-menu cell, else the selection.
    private var targetCell: (row: Int, tableColumn: Int)? {
        if let contextCell { return contextCell }
        guard tableView.selectedRow >= 0 else { return nil }
        return (tableView.selectedRow, tableView.lastClickedColumn > 0 ? tableView.lastClickedColumn : 1)
    }

    private func rowsForCopy(_ indexes: IndexSet) -> [[CellValue]] {
        indexes.map { row in
            (0..<content.columns.count).map { content.currentValue(row: row, column: $0) ?? .null }
        }
    }

    func copyRows(format: ExportFormat, includeHeader: Bool = false) {
        let rows = rowsForCopy(targetRows())
        guard !rows.isEmpty else { return }
        let text = ResultExporter.export(columns: content.columns, rows: rows, format: format, includeHeader: includeHeader, tableName: tableNameForCopy, dialect: dialectForCopy)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(format == .csv || format == .tsv ? text.trimmingCharacters(in: .newlines) : text, forType: .string)
    }

    @objc func copy(_ sender: Any?) {
        copyRows(format: .tsv)
    }

    @objc private func copyCell(_ sender: Any?) {
        guard let cell = targetCell, let dataColumn = dataColumnIndex(atTableColumn: cell.tableColumn) else { return }
        let value = content.currentValue(row: cell.row, column: dataColumn) ?? .null
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value.isNull ? "NULL" : value.displayString, forType: .string)
    }

    /// Opens the multi-line value editor for the clicked (or selected) cell.
    @objc func openValueEditor(_ sender: Any?) {
        guard let cell = targetCell, let column = dataColumnIndex(atTableColumn: cell.tableColumn) else { return }
        presentValueEditor(row: cell.row, column: column)
    }

    func presentValueEditor(row: Int, column: Int) {
        guard let window, row < content.displayRowCount, column < content.columns.count else { return }
        let value = content.currentValue(row: row, column: column) ?? .null
        let editable = isEditable && !content.changes.deletions.contains(row) && !isImmutable(column)
        let editor = ValueEditorController(column: content.columns[column].name, value: value, editable: editable) { [weak self] edited in
            guard let self else { return }
            var newValue = edited
            if case .bytes = value, case .text(let text) = edited, let data = Data(hexLiteral: text) {
                newValue = .bytes(data)
            }
            if value.isAbsent, edited == .text("") { return }
            guard newValue != value else { return }
            self.delegate?.dataGrid(self, didEditRow: row, column: column, value: newValue)
        }
        editor.present(in: window)
    }

    @objc func copyWithHeader(_ sender: Any?) { copyRows(format: .tsv, includeHeader: true) }
    @objc private func copyAsCSV(_ sender: Any?) { copyRows(format: .csv, includeHeader: true) }
    @objc func copyAsJSON(_ sender: Any?) { copyRows(format: .json) }
    @objc private func copyAsSQL(_ sender: Any?) { copyRows(format: .sqlInsert) }
    @objc private func copyAsMarkdown(_ sender: Any?) { copyRows(format: .markdown) }
    @objc private func setNull(_ sender: Any?) { setSelectedCells(to: .null) }
    @objc private func setEmpty(_ sender: Any?) { setSelectedCells(to: .text("")) }
    @objc private func setDefault(_ sender: Any?) { setSelectedCells(to: .expression("DEFAULT")) }
    @objc private func setCurrentTimestamp(_ sender: Any?) { setSelectedCells(to: .expression("CURRENT_TIMESTAMP")) }
    @objc fileprivate func deleteRows(_ sender: Any?) { delegate?.dataGridDeleteSelectedRows(self) }

    // MARK: - Local sort (query results)

    private func applyLocalSort(column: Int, ascending: Bool) {
        guard content.columns.indices.contains(column) else { return }
        let numeric = content.columns[column].isNumeric
        content.rows.sort { lhs, rhs in
            let ordered = Self.compare(lhs[safe: column] ?? .null, rhs[safe: column] ?? .null, numeric: numeric)
            return ascending ? ordered == .orderedAscending : ordered == .orderedDescending
        }
        tableView.reloadData()
    }

    static func compare(_ lhs: CellValue, _ rhs: CellValue, numeric: Bool) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.null, .null): return .orderedSame
        case (.null, _): return .orderedAscending
        case (_, .null): return .orderedDescending
        default:
            let a = lhs.displayString
            let b = rhs.displayString
            if numeric, let x = Double(a), let y = Double(b) {
                return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
            }
            return a.localizedStandardCompare(b)
        }
    }
}

extension DataGridView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        content.displayRowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("eq.cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? GridCellView) ?? GridCellView(identifier: identifier)
        cell.textField?.delegate = self
        cell.textField?.font = font

        let deleted = content.changes.deletions.contains(row)
        let inserted = content.isInserted(row)
        var state: GridCellView.State = deleted ? .deleted : (inserted ? .inserted : .normal)

        if tableColumn.identifier == Self.rowNumberIdentifier {
            cell.configure(text: String(content.rowOffset + row + 1), style: .rowNumber, state: state, editable: false)
            cell.setReference(visible: false, action: nil)
            cell.setFindHighlight(.none)
            return cell
        }
        guard let column = dataColumnIndex(tableColumn) else { return nil }
        if !inserted, content.changes.isModified(row: row, column: column), !deleted {
            state = .modified
        }
        let editable = isEditable && !deleted && !isImmutable(column)
        if let value = content.currentValue(row: row, column: column) {
            let isExpression: Bool = { if case .expression = value { return true } else { return false } }()
            let style: GridCellView.Style = value.isAbsent || isExpression ? .null : (content.columns[safe: column]?.isNumeric == true ? .number : .text)
            cell.configure(text: Self.displayText(value), style: style, state: state, editable: editable)
            cell.editingText = value.isAbsent ? "" : value.displayString
            let key = GridCellKey(row: row, column: column)
            cell.setFindHighlight(currentFindMatch.flatMap { findMatches[safe: $0] } == key ? .current : (findMatchSet.contains(key) ? .match : .none))
            let followable = referenceColumns.contains(column) && !inserted && !value.isAbsent && !isExpression
            cell.setReference(visible: followable) { [weak self] in
                guard let self else { return }
                self.delegate?.dataGrid(self, followReferenceAtRow: row, column: column)
            }
        } else {
            cell.configure(text: "DEFAULT", style: .null, state: state, editable: editable)
            cell.editingText = ""
            cell.setReference(visible: false, action: nil)
            cell.setFindHighlight(.none)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = GridRowView()
        view.isAlternate = row % 2 == 1
        return view
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplyingSortIndicator else { return }
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
              key.hasPrefix("c"), let column = Int(key.dropFirst()), content.columns.indices.contains(column)
        else { return }
        if isLocalSortEnabled {
            applyLocalSort(column: column, ascending: descriptor.ascending)
        } else {
            delegate?.dataGrid(self, didChangeSort: [SortKey(column: content.columns[column].name, ascending: descriptor.ascending)])
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        delegate?.dataGridSelectionDidChange(self)
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        guard isEditable, let column = dataColumnIndex(tableColumn) else { return false }
        return !isImmutable(column)
    }

    func isImmutable(_ column: Int) -> Bool {
        guard let name = content.columns[safe: column]?.name else { return false }
        return immutableColumns.contains(name)
    }

}

extension DataGridView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = tableView.row(for: field)
        let tableColumn = tableView.column(for: field)
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        if let cell = field.superview as? GridCellView {
            cell.finishEditing()
        }
        guard row >= 0, let column = dataColumnIndex(atTableColumn: tableColumn) else { return }
        if movement == NSTextMovement.cancel.rawValue {
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: tableColumn))
            return
        }
        commitEdit(row: row, column: column, text: field.stringValue)
        if movement == NSTextMovement.tab.rawValue, tableColumn + 1 < tableView.numberOfColumns {
            DispatchQueue.main.async { self.beginEditing(row: row, tableColumn: tableColumn + 1) }
        } else {
            tableView.window?.makeFirstResponder(tableView)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            control.abortEditing()
            tableView.window?.makeFirstResponder(tableView)
            tableView.reloadData()
            return true
        }
        return false
    }
}

extension DataGridView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = tableView.clickedRow
        if clicked >= 0 {
            contextCell = (clicked, tableView.clickedColumn)
            contextRows = tableView.selectedRowIndexes.contains(clicked) ? tableView.selectedRowIndexes : IndexSet(integer: clicked)
        } else {
            contextCell = nil
            contextRows = nil
        }
        let rows = targetRows()
        guard !rows.isEmpty else { return }
        func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            return item
        }
        menu.addItem(item(isEditable ? "Edit Value…" : "View Value…", #selector(openValueEditor(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Copy", #selector(copy(_:))))
        menu.addItem(item("Copy Cell Value", #selector(copyCell(_:))))
        menu.addItem(item("Copy with Header", #selector(copyWithHeader(_:))))
        let copyAs = NSMenuItem(title: "Copy As", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(item("CSV", #selector(copyAsCSV(_:))))
        submenu.addItem(item("JSON", #selector(copyAsJSON(_:))))
        submenu.addItem(item("SQL INSERT", #selector(copyAsSQL(_:))))
        submenu.addItem(item("Markdown", #selector(copyAsMarkdown(_:))))
        copyAs.submenu = submenu
        menu.addItem(copyAs)

        if isEditable {
            menu.addItem(.separator())
            menu.addItem(item("Set NULL", #selector(setNull(_:))))
            menu.addItem(item("Set Empty String", #selector(setEmpty(_:))))
            if allowsDefaultKeyword {
                menu.addItem(item("Set DEFAULT", #selector(setDefault(_:))))
            }
            if allowsSQLExpressions {
                menu.addItem(item("Set Current Timestamp", #selector(setCurrentTimestamp(_:))))
            }
            menu.addItem(.separator())
            let allDeleted = rows.allSatisfy { content.changes.deletions.contains($0) }
            menu.addItem(item(allDeleted ? "Restore Row" : (rows.count > 1 ? "Delete \(rows.count) Rows" : "Delete Row"), #selector(deleteRows(_:))))
        }
        let extra = delegate?.dataGrid(self, extraMenuItemsFor: rows) ?? []
        if !extra.isEmpty {
            menu.addItem(.separator())
            extra.forEach(menu.addItem)
        }
    }

    /// The chosen item's action runs after the menu closes, so forget the target on the next turn of the run loop.
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in
            self?.contextCell = nil
            self?.contextRows = nil
        }
    }
}

/// NSTableView subclass that adds grid keyboard handling.
final class GridTableView: NSTableView {
    weak var gridView: DataGridView?
    private(set) var lastClickedColumn = -1

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastClickedColumn = column(at: point)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let grid = gridView else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76: // Return, Enter; Option-Return opens the value editor
            if selectedRow >= 0, event.modifierFlags.contains(.option) {
                grid.openValueEditor(nil)
                return
            }
            if selectedRow >= 0 {
                let column = lastClickedColumn > 0 ? lastClickedColumn : 1
                grid.beginEditing(row: selectedRow, tableColumn: column)
                return
            }
        case 51, 117: // Delete, Forward Delete
            if grid.isEditable, !selectedRowIndexes.isEmpty {
                grid.deleteRows(nil)
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        // Single clicks select rows; editing starts only on double click or Return.
        if responder is NSTextField, event?.type == .leftMouseDown, (event?.clickCount ?? 0) < 2 {
            return false
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

final class GridRowView: NSTableRowView {
    var isAlternate = false

    override func drawBackground(in dirtyRect: NSRect) {
        (isAlternate ? Theme.gridAlternateRow : Theme.gridBackground).setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        bounds.fill()
    }
}

extension Data {
    /// Parses `0x0aff` style hex literals typed into a binary cell.
    init?(hexLiteral text: String) {
        var hex = text.trimmingCharacters(in: .whitespaces)
        guard hex.lowercased().hasPrefix("0x") else { return nil }
        hex.removeFirst(2)
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

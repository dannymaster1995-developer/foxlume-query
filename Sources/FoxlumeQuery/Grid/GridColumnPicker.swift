import AppKit
import FoxlumeQueryCore

/// A popover over the grid's header listing its columns, filtered by what is typed in its search field. As the
/// Columns list it has a check box per column and Show All; as Jump to Column, Return (or a double-click) scrolls to
/// the chosen column.
@MainActor
final class GridColumnPickerController: NSViewController {
    enum Mode {
        case visibility
        case jump
    }

    static let rowHeight: CGFloat = 22
    static let maximumVisibleRows = 12
    static let width: CGFloat = 260

    let mode: Mode
    private weak var grid: DataGridView?
    let searchField = NSSearchField()
    let list = NSTableView()
    private let scroll = NSScrollView()
    private let popover = NSPopover()
    /// Data column indexes of the rows shown, in list order.
    private(set) var matches: [Int] = []

    init(mode: Mode, grid: DataGridView) {
        self.mode = mode
        self.grid = grid
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var names: [String] { grid?.content.columns.map(\.name) ?? [] }

    /// Every data column, hidden ones included, in on-screen order.
    private var orderedColumns: [Int] {
        grid.map { grid in grid.tableView.tableColumns.compactMap { grid.dataColumnIndex($0) } } ?? []
    }

    override func loadView() {
        searchField.placeholderString = mode == .jump ? "Jump to column" : "Filter columns"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityIdentifier(mode == .jump ? "jumpToColumnField" : "columnsFilterField")

        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        tableColumn.width = Self.width - 24
        list.addTableColumn(tableColumn)
        list.headerView = nil
        list.rowHeight = Self.rowHeight
        list.intercellSpacing = NSSize(width: 0, height: 0)
        list.style = .plain
        list.backgroundColor = .clear
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(listDoubleClicked(_:))
        list.allowsEmptySelection = mode == .visibility
        list.setAccessibilityIdentifier(mode == .jump ? "jumpToColumnList" : "columnsList")
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let visibleRows = CGFloat(min(max(names.count, 1), Self.maximumVisibleRows))
        var views: [NSView] = [searchField, scroll]
        if mode == .visibility {
            let showAll = NSButton(title: "Show All", target: self, action: #selector(showAll(_:)))
            showAll.controlSize = .small
            showAll.setAccessibilityIdentifier("showAllColumns")
            views.append(showAll)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            scroll.heightAnchor.constraint(equalToConstant: visibleRows * Self.rowHeight),
        ])
        view = stack
        refilter()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    func show(relativeTo rect: NSRect, of anchor: NSView) {
        popover.contentViewController = self
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.show(relativeTo: rect, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
    }

    func close() {
        if popover.isShown { popover.close() }
        if grid?.columnPicker === self { grid?.columnPicker = nil }
    }

    var isShown: Bool { popover.isShown }

    /// Replaces the search text, as typing would. Used by scripted checks and tests too.
    func filter(_ text: String) {
        _ = view
        searchField.stringValue = text
        refilter()
    }

    private func refilter() {
        let ordered = orderedColumns
        let allNames = names
        matches = ColumnNameMatch.rank(ordered.map { allNames[$0] }, query: searchField.stringValue).map { ordered[$0] }
        list.reloadData()
        if mode == .jump, !matches.isEmpty {
            list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            list.scrollRowToVisible(0)
        }
    }

    /// Titles of the rows shown; hidden columns are marked.
    var visibleTitles: [String] {
        matches.map { column in
            let name = names[safe: column] ?? ""
            return grid?.isColumnHidden(column) == true ? "\(name) (hidden)" : name
        }
    }

    /// Jump to Column: jumps to the selected row (the first match when none is selected) and closes.
    func chooseSelected() {
        guard mode == .jump else { return }
        let row = list.selectedRow >= 0 ? list.selectedRow : 0
        guard let column = matches[safe: row], let grid else { return NSSound.beep() }
        close()
        grid.jumpToColumn(column)
    }

    private func moveSelection(by offset: Int) {
        guard !matches.isEmpty else { return }
        let current = list.selectedRow >= 0 ? list.selectedRow : (offset > 0 ? -1 : matches.count)
        let next = min(max(current + offset, 0), matches.count - 1)
        list.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        list.scrollRowToVisible(next)
    }

    @objc private func listDoubleClicked(_ sender: Any?) {
        guard mode == .jump, list.clickedRow >= 0 else { return }
        list.selectRowIndexes(IndexSet(integer: list.clickedRow), byExtendingSelection: false)
        chooseSelected()
    }

    @objc private func toggleColumn(_ sender: NSButton) {
        guard let grid else { return }
        if !grid.setColumn(sender.tag, hidden: sender.state == .off) {
            sender.state = grid.isColumnHidden(sender.tag) ? .off : .on
        }
    }

    @objc private func showAll(_ sender: Any?) {
        grid?.showAllColumns()
        list.reloadData()
    }
}

extension GridColumnPickerController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        matches.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = matches[safe: row], let name = names[safe: column] else { return nil }
        let hidden = grid?.isColumnHidden(column) == true
        switch mode {
        case .visibility:
            let box = NSButton(checkboxWithTitle: name, target: self, action: #selector(toggleColumn(_:)))
            box.tag = column
            box.state = hidden ? .off : .on
            box.lineBreakMode = .byTruncatingTail
            return box
        case .jump:
            let label = NSTextField(labelWithString: hidden ? "\(name) (hidden)" : name)
            label.textColor = hidden ? .secondaryLabelColor : .labelColor
            label.lineBreakMode = .byTruncatingTail
            let cell = NSTableCellView()
            cell.textField = label
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        mode == .jump
    }
}

extension GridColumnPickerController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        refilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)) where mode == .jump:
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)) where mode == .jump:
            moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            if mode == .jump { chooseSelected() } else { close() }
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }
}

extension GridColumnPickerController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        if grid?.columnPicker === self { grid?.columnPicker = nil }
    }
}

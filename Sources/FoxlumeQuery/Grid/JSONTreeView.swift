import AppKit
import FoxlumeQueryCore

/// Read-only outline of a JSON object or array: key (or index), value and type per row. Children are read from the
/// text only when a row is expanded, so large documents open at once. The search field keeps only the rows that
/// match (and the path to them); Copy Value and Copy Path are in the row menu, ⌘C copies the selected values.
/// The search field lives in the value viewer's toolbar and calls `search(_:)`.
@MainActor
final class JSONTreeView: NSView {
    private(set) var document: JSONTreeDocument?
    private(set) var filter: JSONTreeFilter?
    let outline = JSONOutlineView()
    private(set) var query = ""
    private let scroll = NSScrollView()
    private let messageLabel = UI.label("", size: 12, color: .secondaryLabelColor)
    /// Children per node under the current filter; NSOutlineView asks for them often.
    private var filteredChildren: [ObjectIdentifier: [JSONTreeNode]] = [:]
    /// Called when the selected row changes, with its path (nil when nothing is selected).
    var onSelectionChange: ((String?) -> Void)?

    private static let keyColumn = NSUserInterfaceItemIdentifier("key")
    private static let valueColumn = NSUserInterfaceItemIdentifier("value")
    private static let typeColumn = NSUserInterfaceItemIdentifier("type")
    /// Long strings are cut in the value column; Copy Value still copies all of it.
    private static let summaryLimit = 500

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("jsonTree")
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (Self.keyColumn, "Key", 180), (Self.valueColumn, "Value", 300), (Self.typeColumn, "Type", 70),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = 50
            column.resizingMask = identifier == Self.valueColumn ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.allowsMultipleSelection = true
        outline.usesAlternatingRowBackgroundColors = true
        outline.style = .plain
        outline.rowHeight = 20
        outline.autosaveExpandedItems = false
        outline.dataSource = self
        outline.delegate = self
        outline.tree = self
        outline.setAccessibilityIdentifier("jsonOutline")
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Value", action: #selector(copyValue(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "").target = self
        outline.menu = menu

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        messageLabel.isHidden = true
        for view in [scroll, messageLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `document`, or `message` when there is none (text that is not a JSON object or array).
    func show(_ document: JSONTreeDocument?, message: String = "The text is not a JSON object or array.") {
        self.document = document
        messageLabel.stringValue = message
        messageLabel.isHidden = document != nil
        scroll.isHidden = document == nil
        applyFilter()
    }

    // MARK: Filter

    func search(_ text: String) {
        query = text.trimmingCharacters(in: .whitespaces)
        applyFilter()
    }

    private func applyFilter() {
        filter = query.isEmpty ? nil : document?.filter(query)
        filteredChildren = [:]
        outline.reloadData()
        if filter != nil {
            outline.expandItem(nil, expandChildren: true)
            if filter?.matchCount == 0 {
                messageLabel.stringValue = "No matches"
                messageLabel.isHidden = false
            }
        } else if document != nil {
            messageLabel.isHidden = true
        }
        onSelectionChange?(nil)
    }

    private func children(of item: Any?) -> [JSONTreeNode] {
        guard let node = (item as? JSONTreeNode) ?? document?.root else { return [] }
        guard let filter else { return node.children }
        let key = ObjectIdentifier(node)
        if let cached = filteredChildren[key] { return cached }
        let children = filter.children(of: node)
        filteredChildren[key] = children
        return children
    }

    // MARK: Expand and copy

    func expandAll() {
        outline.expandItem(nil, expandChildren: true)
    }

    func collapseAll() {
        outline.collapseItem(nil, collapseChildren: true)
    }

    /// The rows currently shown, as `indent label = summary (type)`, for scripted checks.
    func visibleRowDescriptions(limit: Int = 40) -> [String] {
        (0..<min(outline.numberOfRows, limit)).compactMap { row in
            guard let node = outline.item(atRow: row) as? JSONTreeNode else { return nil }
            return String(repeating: "  ", count: outline.level(forRow: row)) + "\(node.label) = \(Self.shortSummary(node)) (\(Self.typeName(node)))"
        }
    }

    /// The clicked row when the menu is open for one, else the selected rows.
    private var targetNodes: [JSONTreeNode] {
        if outline.clickedRow >= 0, !outline.selectedRowIndexes.contains(outline.clickedRow) {
            return [outline.item(atRow: outline.clickedRow) as? JSONTreeNode].compactMap { $0 }
        }
        return outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? JSONTreeNode }
    }

    @objc func copyValue(_ sender: Any?) {
        copy(targetNodes.map(\.copyText))
    }

    @objc func copyPath(_ sender: Any?) {
        copy(targetNodes.map(\.path))
    }

    private func copy(_ texts: [String]) {
        guard !texts.isEmpty else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(texts.joined(separator: "\n"), forType: .string)
    }

    func selectRow(_ row: Int) {
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    static func typeName(_ node: JSONTreeNode) -> String {
        node.kind.rawValue
    }

    static func shortSummary(_ node: JSONTreeNode) -> String {
        let summary = node.summary
        let cut = summary.count > summaryLimit ? String(summary.prefix(summaryLimit)) + "…" : summary
        return cut.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
    }
}

extension JSONTreeView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? JSONTreeNode, node.isContainer else { return false }
        return !children(of: node).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? JSONTreeNode, let identifier = tableColumn?.identifier else { return nil }
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? Self.makeCell(identifier)
        guard let field = cell.textField else { return cell }
        switch identifier {
        case Self.keyColumn:
            field.stringValue = node.label
            field.font = .systemFont(ofSize: 12, weight: node.kind == .object || node.kind == .array ? .medium : .regular)
            if case .index? = node.component { field.textColor = .secondaryLabelColor } else { field.textColor = .labelColor }
        case Self.valueColumn:
            field.stringValue = Self.shortSummary(node)
            field.textColor = node.isContainer || node.kind == .null ? .secondaryLabelColor : (node.kind == .string ? .labelColor : .systemBlue)
            if filter?.isMatch(node) == true { field.textColor = .controlAccentColor }
        default:
            field.stringValue = Self.typeName(node)
            field.textColor = .tertiaryLabelColor
        }
        return cell
    }

    private static func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.font = identifier == valueColumn ? Theme.monospaced(12) : .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let node = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? JSONTreeNode : nil
        onSelectionChange?(node?.path)
    }
}

/// The outline of the JSON tree: ⌘C copies the selected values.
@MainActor
final class JSONOutlineView: NSOutlineView {
    weak var tree: JSONTreeView?

    @objc func copy(_ sender: Any?) {
        tree?.copyValue(sender)
    }
}

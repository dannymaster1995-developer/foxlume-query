import AppKit
import FoxlumeQueryCore

/// The plan as an outline: one row per step, with its object, share of the work, cost, rows, time and loops.
/// Columns the plan has no values for are hidden. Sorting reorders siblings only; the tree keeps its shape.
@MainActor
final class QueryPlanOutlineView: NSView {
    enum Column: String, CaseIterable {
        case operation, object, share, cost, rows, actualRows, time, loops

        func title(metric: QueryPlanMetric?) -> String {
            switch self {
            case .operation: return "Operation"
            case .object: return "Object"
            case .share: return metric?.title ?? "Share"
            case .cost: return "Cost"
            case .rows: return "Rows"
            case .actualRows: return "Actual Rows"
            case .time: return "Time"
            case .loops: return "Loops"
            }
        }

        var width: CGFloat {
            switch self {
            case .operation: return 220
            case .object: return 150
            case .share: return 120
            case .cost: return 130
            case .rows, .actualRows: return 80
            case .time: return 80
            case .loops: return 50
            }
        }

        var minimumWidth: CGFloat {
            switch self {
            case .operation: return 130
            case .object: return 70
            case .share: return 80
            case .cost: return 70
            default: return 44
            }
        }

        var tooltip: String {
            switch self {
            case .operation: return "What the step does"
            case .object: return "The table the step reads, and the index it uses"
            case .share: return "The step's own part of the plan's work, without the steps below it"
            case .cost: return "Estimated startup and total cost, in planner units"
            case .rows: return "Estimated rows per loop"
            case .actualRows: return "Rows the step produced per loop"
            case .time: return "Measured time per loop, including the steps below"
            case .loops: return "How many times the step ran"
            }
        }

        func hasContent(in plan: QueryPlan, analysis: QueryPlanAnalysis) -> Bool {
            let nodes = plan.allNodes
            switch self {
            case .operation: return true
            case .object: return nodes.contains { $0.objectName != nil || $0.index != nil }
            case .share: return !analysis.availableMetrics.isEmpty
            case .cost: return nodes.contains { $0.estimatedTotalCost != nil }
            case .rows: return nodes.contains { $0.estimatedRows != nil }
            case .actualRows: return nodes.contains { $0.actualRows != nil }
            case .time: return nodes.contains { $0.actualTotalTime != nil || $0.neverExecuted }
            case .loops: return nodes.contains { $0.actualLoops != nil }
            }
        }
    }

    /// NSOutlineView holds its items by reference, so the value-typed plan tree is wrapped once per plan.
    final class Item: NSObject {
        let node: QueryPlanNode
        let children: [Item]

        init(_ node: QueryPlanNode, sortedBy order: ((QueryPlanNode, QueryPlanNode) -> Bool)? = nil) {
            self.node = node
            let children = order.map { node.children.sorted(by: $0) } ?? node.children
            self.children = children.map { Item($0, sortedBy: order) }
        }
    }

    var onSelect: ((Int?) -> Void)?

    private let scroll = NSScrollView()
    let outline = PlanOutline()
    private(set) var plan: QueryPlan?
    private(set) var analysis: QueryPlanAnalysis?
    private var root: Item?
    var metric: QueryPlanMetric? {
        didSet {
            guard metric != oldValue else { return }
            outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(Column.share.rawValue))?.title = Column.share.title(metric: metric)
            let selected = selectedNode?.id
            if outline.sortDescriptors.first?.key == Column.share.rawValue { applySort() }
            outline.reloadData()
            if let selected { select(nodeID: selected) }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup() {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title(metric: nil)
            tableColumn.width = column.width
            tableColumn.minWidth = column.minimumWidth
            tableColumn.headerToolTip = column.tooltip
            // Names read A to Z, numbers worst first.
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column == .operation || column == .object)
            if column != .operation, column != .object {
                tableColumn.headerCell.alignment = .right
            }
            outline.addTableColumn(tableColumn)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        // Every column stays in view: they share the width, down to their minimums, before a scroller appears.
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.style = .fullWidth
        outline.rowSizeStyle = .custom
        outline.rowHeight = 22
        outline.indentationPerLevel = 14
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.usesAlternatingRowBackgroundColors = false
        outline.backgroundColor = Theme.gridBackground
        outline.intercellSpacing = NSSize(width: 6, height: 0)
        outline.dataSource = self
        outline.delegate = self
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.owner = self
        outline.setAccessibilityIdentifier("queryPlanOutline")

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        addSubviewFilling(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: ThemeManager.didChangeNotification, object: nil)
    }

    @objc private func themeChanged() {
        outline.backgroundColor = Theme.gridBackground
        outline.reloadData()
    }

    // MARK: Content

    /// Shows a new plan fully expanded, with its root selected.
    func show(_ plan: QueryPlan, analysis: QueryPlanAnalysis, metric: QueryPlanMetric?) {
        self.plan = plan
        self.analysis = analysis
        self.metric = metric
        for tableColumn in outline.tableColumns {
            guard let column = Column(rawValue: tableColumn.identifier.rawValue) else { continue }
            tableColumn.title = column.title(metric: metric)
            tableColumn.isHidden = !column.hasContent(in: plan, analysis: analysis)
        }
        outline.sizeToFit()
        // The new tree is in plan order, so a sort left from the previous plan would advertise an order it is not in.
        outline.sortDescriptors = []
        root = Item(plan.root)
        outline.reloadData()
        expandAll()
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        onSelect?(selectedNode?.id)
    }

    var selectedNode: QueryPlanNode? {
        guard outline.selectedRow >= 0 else { return nil }
        return (outline.item(atRow: outline.selectedRow) as? Item)?.node
    }

    /// The right-clicked row, else the selected one.
    var clickedNode: QueryPlanNode? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0 else { return nil }
        return (outline.item(atRow: row) as? Item)?.node
    }

    func select(nodeID: Int) {
        guard let item = find(nodeID, in: root) else { return }
        var parents: [Item] = []
        var cursor = parent(of: item, in: root)
        while let found = cursor {
            parents.insert(found, at: 0)
            cursor = parent(of: found, in: root)
        }
        parents.forEach { outline.expandItem($0) }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    @objc func expandAll() {
        guard let root else { return }
        outline.expandItem(root, expandChildren: true)
    }

    @objc func collapseAll() {
        guard let root else { return }
        outline.collapseItem(root, collapseChildren: true)
    }

    /// The visible rows as text, indented by depth, for scripted checks.
    var rowDescriptions: [String] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let item = outline.item(atRow: row) as? Item else { return nil }
            let node = item.node
            var parts = [String(repeating: "  ", count: outline.level(forRow: row)) + node.operation]
            if let object = node.objectName { parts.append("on \(object)") }
            if let index = node.index { parts.append("using \(index)") }
            if let metric, let share = analysis?[node.id].share(metric) { parts.append(QueryPlanText.percent(share)) }
            if let severity = analysis?.severity(of: node.id, metric: metric), severity >= .high { parts.append("[\(severity.title.lowercased())]") }
            if let warnings = analysis?[node.id].warnings, !warnings.isEmpty { parts.append("[\(warnings.count) warning\(warnings.count == 1 ? "" : "s")]") }
            return parts.joined(separator: " ")
        }
    }

    var visibleColumnTitles: [String] {
        outline.tableColumns.filter { !$0.isHidden }.map(\.title)
    }

    private func find(_ id: Int, in item: Item?) -> Item? {
        guard let item else { return nil }
        if item.node.id == id { return item }
        for child in item.children {
            if let found = find(id, in: child) { return found }
        }
        return nil
    }

    private func parent(of target: Item, in item: Item?) -> Item? {
        guard let item else { return nil }
        for child in item.children {
            if child === target { return item }
            if let found = parent(of: target, in: child) { return found }
        }
        return nil
    }

    // MARK: Sorting

    private func applySort() {
        guard let plan else { return }
        let selected = selectedNode?.id
        if let descriptor = outline.sortDescriptors.first, let key = descriptor.key, let column = Column(rawValue: key) {
            let value = sortValue(column)
            let ascending = descriptor.ascending
            root = Item(plan.root) { lhs, rhs in
                if column == .operation || column == .object {
                    let left = column == .operation ? lhs.operation : (lhs.objectName ?? "")
                    let right = column == .operation ? rhs.operation : (rhs.objectName ?? "")
                    let order = left.localizedStandardCompare(right)
                    return ascending ? order == .orderedAscending : order == .orderedDescending
                }
                let left = value(lhs) ?? -1
                let right = value(rhs) ?? -1
                return ascending ? left < right : left > right
            }
        } else {
            root = Item(plan.root)
        }
        outline.reloadData()
        expandAll()
        if let selected { select(nodeID: selected) }
    }

    private func sortValue(_ column: Column) -> (QueryPlanNode) -> Double? {
        let analysis = self.analysis
        let metric = self.metric
        switch column {
        case .share: return { node in metric.flatMap { analysis?[node.id].value($0) } }
        case .cost: return { $0.estimatedTotalCost }
        case .rows: return { $0.estimatedRows }
        case .actualRows: return { $0.actualRows }
        case .time: return { $0.actualTotalTime }
        case .loops: return { $0.actualLoops.map(Double.init) }
        case .operation, .object: return { _ in nil }
        }
    }

    // MARK: Copy

    func copyDetails(of node: QueryPlanNode?) {
        guard let node else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(QueryPlanText.details(of: node, metrics: analysis?[node.id]), forType: .string)
    }

    @objc fileprivate func copyClickedDetails(_ sender: Any?) {
        copyDetails(of: clickedNode)
    }

    @objc fileprivate func copyClickedOperation(_ sender: Any?) {
        guard let node = clickedNode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.operation, forType: .string)
    }

    var contextMenuTitles: [String] {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        return menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }
}

/// Routes Edit › Copy (⌘C) to the selected step's details.
@MainActor
final class PlanOutline: NSOutlineView {
    weak var owner: QueryPlanOutlineView?

    @objc func copy(_ sender: Any?) {
        owner?.copyDetails(of: owner?.selectedNode)
    }
}

extension QueryPlanOutlineView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? Item else { return root == nil ? 0 : 1 }
        return item.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? Item else { return root as Any }
        return item.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Item)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applySort()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        onSelect?(selectedNode?.id)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item, let identifier = tableColumn?.identifier, let column = Column(rawValue: identifier.rawValue) else { return nil }
        let node = item.node
        let metrics = analysis?[node.id] ?? QueryPlanAnalysis.NodeMetrics()
        switch column {
        case .operation:
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? PlanOperationCell) ?? PlanOperationCell(identifier: identifier)
            cell.configure(node: node, severity: analysis?.severity(of: node.id, metric: metric), warnings: metrics.warnings)
            return cell
        case .share:
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? PlanShareCell) ?? PlanShareCell(identifier: identifier)
            let share = metric.flatMap { metrics.share($0) }
            let largest = metric.flatMap { metric in analysis?.metrics.values.compactMap { $0.share(metric) }.max() } ?? 0
            cell.configure(share: share, fill: largest > 0 ? (share ?? 0) / largest : 0, severity: analysis?.severity(of: node.id, metric: metric))
            return cell
        default:
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? PlanTextCell) ?? PlanTextCell(identifier: identifier, alignment: column == .object ? .left : .right)
            cell.configure(text(for: column, node: node, metrics: metrics))
            return cell
        }
    }

    private func text(for column: Column, node: QueryPlanNode, metrics: QueryPlanAnalysis.NodeMetrics) -> NSAttributedString {
        let numeric: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: Theme.gridText]
        let quiet: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        func plain(_ text: String?) -> NSAttributedString { NSAttributedString(string: text ?? "", attributes: numeric) }
        switch column {
        case .object:
            let text = NSMutableAttributedString(string: node.objectName ?? "", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.gridText])
            if let index = node.index {
                text.append(NSAttributedString(string: (text.length == 0 ? "" : " ") + "using \(index)", attributes: quiet))
            }
            return text
        case .cost:
            return plain(QueryPlanText.costRange(startup: node.estimatedStartupCost, total: node.estimatedTotalCost))
        case .rows:
            return plain(node.estimatedRows.map(QueryPlanText.rows))
        case .actualRows:
            guard let rows = node.actualRows else { return plain(nil) }
            // Rows far from the estimate are what misled the planner; they stand out in the warning color.
            let misestimated = metrics.warnings.contains { $0.kind == .rowEstimate }
            var attributes = numeric
            if misestimated { attributes[.foregroundColor] = NSColor.systemOrange }
            return NSAttributedString(string: QueryPlanText.rows(rows), attributes: attributes)
        case .time:
            if node.neverExecuted { return NSAttributedString(string: "never executed", attributes: quiet) }
            return plain(node.actualTotalTime.map(QueryPlanText.milliseconds))
        case .loops:
            return plain(node.actualLoops.map { $0.groupedText })
        case .operation, .share:
            return plain(nil)
        }
    }
}

extension QueryPlanOutlineView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard clickedNode != nil else { return }
        let items: [(String, Selector)] = [
            ("Copy Node Details", #selector(copyClickedDetails(_:))),
            ("Copy Operation", #selector(copyClickedOperation(_:))),
        ]
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action) in [("Expand All", #selector(expandAll)), ("Collapse All", #selector(collapseAll))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }
}

// MARK: Cells

/// Severity as a shape and a color, so it reads without color too: a circle, a diamond, a triangle, a warning sign.
extension QueryPlanSeverity {
    var color: NSColor {
        switch self {
        case .low: return .systemGreen
        case .moderate: return .systemYellow
        case .high: return .systemOrange
        case .critical: return .systemRed
        }
    }

    var symbolName: String {
        switch self {
        case .low: return "circle.fill"
        case .moderate: return "diamond.fill"
        case .high: return "triangle.fill"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
final class PlanOperationCell: NSTableCellView {
    private let glyph = NSImageView()
    private let warning = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        glyph.imageScaling = .scaleProportionallyDown
        warning.image = Theme.image("exclamationmark.triangle.fill", "Warning", size: 11)
        warning.contentTintColor = .systemOrange
        let stack = UI.hstack([glyph, label, warning, UI.flexibleSpace()], spacing: 5)
        addSubview(stack)
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 10),
            glyph.heightAnchor.constraint(equalToConstant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(node: QueryPlanNode, severity: QueryPlanSeverity?, warnings: [QueryPlanWarning]) {
        let text = NSMutableAttributedString(string: node.operation, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: severity == .critical ? .semibold : .medium),
            .foregroundColor: Theme.gridText,
        ])
        if let detail = node.detail {
            text.append(NSAttributedString(string: "  " + detail, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        label.attributedStringValue = text
        // Kept in place when the plan reports no cost for this step, so operation names keep one left edge.
        glyph.image = Theme.image((severity ?? .low).symbolName, severity.map { "\($0.title) share of the work" } ?? "", size: 9)
        glyph.contentTintColor = severity?.color
        glyph.alphaValue = severity == nil ? 0 : 1
        glyph.toolTip = severity.map { "\($0.title) share of the plan's work" }
        warning.isHidden = warnings.isEmpty
        warning.toolTip = warnings.map(\.message).joined(separator: "\n")
        toolTip = warnings.isEmpty ? nil : warnings.map(\.message).joined(separator: "\n")
    }
}

@MainActor
final class PlanTextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ text: NSAttributedString) {
        label.attributedStringValue = text
        label.toolTip = text.length > 24 ? text.string : nil
    }
}

/// A bar against the largest step, colored by the step's share of the whole plan, and that share in percent.
@MainActor
final class PlanShareCell: NSTableCellView {
    private let bar = PlanBarView()
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.alignment = .right
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        addSubview(label)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.widthAnchor.constraint(equalToConstant: 42),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(share: Double?, fill: Double, severity: QueryPlanSeverity?) {
        label.stringValue = share.map(QueryPlanText.percent) ?? ""
        bar.fraction = share == nil ? nil : fill
        bar.color = severity?.color ?? .controlAccentColor
        bar.needsDisplay = true
    }
}

@MainActor
final class PlanBarView: NSView {
    var fraction: Double?
    var color: NSColor = .controlAccentColor

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        guard let fraction, fraction > 0 else { return }
        // A step that did a sliver of the largest one's work still did some; keep it visible.
        var fill = track
        fill.size.width = max(2, min(track.width, track.width * CGFloat(fraction)))
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: track.height / 2, yRadius: track.height / 2).fill()
    }
}

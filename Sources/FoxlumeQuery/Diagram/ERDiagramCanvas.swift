import AppKit
import FoxlumeQueryCore

/// Sizes and fonts of a table box. Widths follow the longest name and type, within limits.
@MainActor
enum ERDiagramMetrics {
    static let headerHeight: CGFloat = 30
    static let rowHeight: CGFloat = 20
    static let bottomPadding: CGFloat = 5
    static let sidePadding: CGFloat = 9
    static let markerWidth: CGFloat = 16
    static let typeGap: CGFloat = 14
    static let minimumWidth: CGFloat = 170
    static let maximumWidth: CGFloat = 380
    static let headerFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let nameFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let keyNameFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
    static let typeFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)

    static func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func size(of table: ERDiagramTable, columns: [ERDiagramColumn], showTypes: Bool) -> CGSize {
        var boxWidth = width(of: table.name, font: headerFont) + sidePadding * 2 + 22
        for column in columns {
            var row = sidePadding + markerWidth + width(of: column.name, font: column.isPrimaryKey ? keyNameFont : nameFont) + sidePadding
            if showTypes { row += typeGap + width(of: column.dataType, font: typeFont) }
            boxWidth = max(boxWidth, row)
        }
        let rows = CGFloat(max(columns.count, 1))
        return CGSize(width: min(maximumWidth, max(minimumWidth, ceil(boxWidth))), height: headerHeight + rows * rowHeight + bottomPadding)
    }

    /// Hues for connected groups, so related tables read as one cluster at a glance.
    static let groupColors: [NSColor] = [
        .systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemTeal, .systemPink,
        .systemIndigo, .systemBrown, .systemMint, .systemRed, .systemCyan, .systemYellow,
    ]

    static func groupColor(_ group: Int?) -> NSColor? {
        guard let group, group >= 0 else { return nil }
        return groupColors[group % groupColors.count]
    }
}

/// The ER diagram's drawing surface: table boxes and the foreign key lines between their columns, drawn with AppKit
/// for whatever part is on screen. Tables are dragged to move them; dragging the background pans.
@MainActor
final class ERDiagramCanvas: NSView, DiagramExportable {
    private(set) var graph = ERDiagramGraph.empty
    private(set) var positions: [String: CGPoint] = [:]
    private(set) var sizes: [String: CGSize] = [:]
    private var tablesByID: [String: ERDiagramTable] = [:]
    private var displayedColumns: [String: [ERDiagramColumn]] = [:]
    /// Paint order: a table dragged last is drawn last, on top.
    private var drawOrder: [String] = []
    private(set) var selectedID: String?
    private(set) var matches: Set<String> = []
    private(set) var isFiltering = false
    var showTypes = true
    var keysOnly = false
    weak var scrollView: DiagramScrollView?

    var onOpenTable: ((TableRef) -> Void)?
    var onShowStructure: ((TableRef) -> Void)?
    /// A drag ended: every table's position, to save.
    var onPositionsChanged: (([String: CGPoint]) -> Void)?
    var onSelectionChange: ((String?) -> Void)?
    /// Background menu commands the controller owns.
    var backgroundMenuItems: (() -> [NSMenuItem])?

    private var press: (window: NSPoint, document: CGPoint, table: String?, origin: CGPoint?)?
    private var dragged = false
    private var panning = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel("ER diagram")
        setAccessibilityIdentifier("erDiagramCanvas")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Content

    /// The columns each table shows, and the box sizes that follow, for the current Types and Keys Only settings.
    static func boxSizes(for graph: ERDiagramGraph, showTypes: Bool, keysOnly: Bool) -> [String: CGSize] {
        Dictionary(uniqueKeysWithValues: graph.tables.map { table in
            (table.id, ERDiagramMetrics.size(of: table, columns: keysOnly ? table.keyColumns : table.columns, showTypes: showTypes))
        })
    }

    func show(_ graph: ERDiagramGraph, positions: [String: CGPoint], sizes: [String: CGSize]) {
        self.graph = graph
        self.positions = positions
        self.sizes = sizes
        tablesByID = Dictionary(uniqueKeysWithValues: graph.tables.map { ($0.id, $0) })
        displayedColumns = Dictionary(uniqueKeysWithValues: graph.tables.map { ($0.id, keysOnly ? $0.keyColumns : $0.columns) })
        let known = Set(graph.tables.map(\.id))
        drawOrder = drawOrder.filter { known.contains($0) } + graph.tables.map(\.id).filter { !drawOrder.contains($0) }
        if let selectedID, !known.contains(selectedID) { self.selectedID = nil }
        matches = matches.intersection(known)
        updateFrameSize(shrink: true)
        needsDisplay = true
    }

    func frame(of id: String) -> CGRect? {
        guard let origin = positions[id], let size = sizes[id] else { return nil }
        return CGRect(origin: origin, size: size)
    }

    var contentBounds: CGRect {
        drawOrder.compactMap(frame(of:)).reduce(CGRect.null) { $0.union($1) }
    }

    private func updateFrameSize(shrink: Bool) {
        let bounds = contentBounds
        let wanted = CGSize(width: max(400, (bounds.isNull ? 0 : bounds.maxX) + 60), height: max(300, (bounds.isNull ? 0 : bounds.maxY) + 60))
        let size = shrink ? wanted : CGSize(width: max(frame.width, wanted.width), height: max(frame.height, wanted.height))
        if size != frame.size { setFrameSize(size) }
    }

    func select(_ id: String?) {
        guard id != selectedID else { return }
        selectedID = id
        if let id { bringToFront(id) }
        needsDisplay = true
        onSelectionChange?(id)
    }

    /// Search: matching tables are outlined, the rest fade. An empty text clears it.
    func highlight(_ text: String) -> [String] {
        let query = text.trimmingCharacters(in: .whitespaces)
        isFiltering = !query.isEmpty
        matches = isFiltering ? Set(graph.tables.filter { $0.name.localizedCaseInsensitiveContains(query) }.map(\.id)) : []
        needsDisplay = true
        return graph.tables.map(\.id).filter { matches.contains($0) }
    }

    private func bringToFront(_ id: String) {
        drawOrder.removeAll { $0 == id }
        drawOrder.append(id)
    }

    func table(at point: CGPoint) -> String? {
        drawOrder.last { frame(of: $0)?.contains(point) == true }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        Theme.gridBackground.setFill()
        dirtyRect.fill()
        let detailed = (scrollView?.magnification ?? 1) >= 0.4
        drawDiagram(in: dirtyRect, detailed: detailed, interactive: true)
    }

    var exportSize: CGSize {
        let bounds = contentBounds
        return bounds.isNull ? .zero : CGSize(width: ceil(bounds.maxX + 40), height: ceil(bounds.maxY + 40))
    }

    var exportBackground: NSColor { Theme.gridBackground }

    func drawForExport(in rect: CGRect) {
        drawDiagram(in: rect, detailed: true, interactive: false)
    }

    private func drawDiagram(in rect: CGRect, detailed: Bool, interactive: Bool) {
        let emphasised: Set<String> = interactive ? Set([selectedID].compactMap { $0 }).union(matches) : []
        for relationship in graph.relationships {
            guard let route = route(for: relationship), route.bounds.insetBy(dx: -16, dy: -16).intersects(rect) else { continue }
            let strong = emphasised.contains(relationship.from) || emphasised.contains(relationship.to)
            let faded = interactive && isFiltering && !(matches.contains(relationship.from) || matches.contains(relationship.to))
            drawRelationship(relationship, route: route, strong: strong, faded: faded)
        }
        for id in drawOrder {
            guard let frame = frame(of: id), frame.insetBy(dx: -4, dy: -4).intersects(rect), let table = tablesByID[id] else { continue }
            let faded = interactive && isFiltering && !matches.contains(id)
            let state: BoxState = !interactive ? .normal : id == selectedID ? .selected : matches.contains(id) ? .matched : .normal
            drawTable(table, in: frame, state: state, detailed: detailed, faded: faded)
        }
    }

    enum BoxState {
        case normal
        case selected
        case matched
    }

    private func drawTable(_ table: ERDiagramTable, in frame: CGRect, state: BoxState, detailed: Bool, faded: Bool) {
        let context = NSGraphicsContext.current?.cgContext
        if faded {
            context?.saveGState()
            context?.setAlpha(0.28)
        }
        defer { if faded { context?.restoreGState() } }

        let box = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        Theme.gridBackground.setFill()
        box.fill()
        NSGraphicsContext.saveGraphicsState()
        box.addClip()
        let header = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: ERDiagramMetrics.headerHeight)
        // Related tables share a hue; a table with no relationship gets a neutral header.
        let tint = ERDiagramMetrics.groupColor(graph.groups[table.id]) ?? .secondaryLabelColor
        tint.withAlphaComponent(graph.groups[table.id] == nil ? 0.12 : 0.24).setFill()
        header.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.separatorColor.setStroke()
        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: frame.minX, y: header.maxY))
        divider.line(to: CGPoint(x: frame.maxX, y: header.maxY))
        divider.lineWidth = 1
        divider.stroke()

        switch state {
        case .selected:
            NSColor.controlAccentColor.setStroke()
            box.lineWidth = 2.5
        case .matched:
            NSColor.systemYellow.setStroke()
            box.lineWidth = 2.5
        case .normal:
            NSColor.tertiaryLabelColor.setStroke()
            box.lineWidth = 1
        }
        box.stroke()

        let pad = ERDiagramMetrics.sidePadding
        let icon = table.kind == .table ? "tablecells" : Theme.symbol(for: table.kind)
        QueryPlanDiagramCanvas.symbol(icon, color: .secondaryLabelColor, size: 10)?.draw(in: CGRect(x: frame.minX + pad, y: header.midY - 6, width: 14, height: 12))
        let name = NSAttributedString(string: table.name, attributes: [.font: ERDiagramMetrics.headerFont, .foregroundColor: Theme.gridText])
        Self.drawLine(name, in: CGRect(x: frame.minX + pad + 20, y: header.midY - 8.5, width: frame.width - pad * 2 - 20, height: 17))

        let columns = displayedColumns[table.id] ?? []
        guard !columns.isEmpty else {
            if detailed {
                let note = NSAttributedString(string: "No columns", attributes: [.font: ERDiagramMetrics.typeFont, .foregroundColor: NSColor.tertiaryLabelColor])
                Self.drawLine(note, in: CGRect(x: frame.minX + pad + ERDiagramMetrics.markerWidth, y: header.maxY + 3, width: frame.width - pad * 2, height: 15))
            }
            return
        }
        for (index, column) in columns.enumerated() {
            let rowTop = header.maxY + CGFloat(index) * ERDiagramMetrics.rowHeight
            let midY = rowTop + ERDiagramMetrics.rowHeight / 2
            guard detailed else {
                // Far out, rows are bars: the shape of the table without thousands of unreadable strings.
                let barWidth = min(frame.width - pad * 2 - ERDiagramMetrics.markerWidth, ERDiagramMetrics.width(of: column.name, font: ERDiagramMetrics.nameFont))
                (column.isPrimaryKey ? NSColor.systemYellow : column.isForeignKey ? NSColor.systemBlue : NSColor.tertiaryLabelColor).withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: CGRect(x: frame.minX + pad + ERDiagramMetrics.markerWidth, y: midY - 3, width: max(8, barWidth), height: 6), xRadius: 3, yRadius: 3).fill()
                continue
            }
            if column.isPrimaryKey {
                QueryPlanDiagramCanvas.symbol("key.fill", color: .systemYellow, size: 9)?.draw(in: CGRect(x: frame.minX + pad, y: midY - 6, width: 12, height: 12))
            } else if column.isForeignKey {
                QueryPlanDiagramCanvas.symbol("link", color: .systemBlue, size: 9)?.draw(in: CGRect(x: frame.minX + pad, y: midY - 6, width: 12, height: 12))
            }
            let nameX = frame.minX + pad + ERDiagramMetrics.markerWidth
            var available = frame.maxX - pad - nameX
            if showTypes {
                let type = NSAttributedString(string: column.dataType, attributes: [.font: ERDiagramMetrics.typeFont, .foregroundColor: NSColor.secondaryLabelColor])
                let nameWidth = ERDiagramMetrics.width(of: column.name, font: column.isPrimaryKey ? ERDiagramMetrics.keyNameFont : ERDiagramMetrics.nameFont)
                // The name comes first; the type keeps at least a few characters and takes what is left.
                let typeRoom = max(min(ceil(type.size().width), 70), available - nameWidth - ERDiagramMetrics.typeGap)
                let typeWidth = min(ceil(type.size().width), typeRoom)
                Self.drawLine(type, in: CGRect(x: frame.maxX - pad - typeWidth, y: midY - 7.5, width: typeWidth, height: 15), alignment: .right)
                available -= typeWidth + ERDiagramMetrics.typeGap
            }
            let nameText = NSAttributedString(string: column.name, attributes: [
                .font: column.isPrimaryKey ? ERDiagramMetrics.keyNameFont : ERDiagramMetrics.nameFont,
                .foregroundColor: Theme.gridText,
            ])
            Self.drawLine(nameText, in: CGRect(x: nameX, y: midY - 8, width: max(10, available), height: 16))
        }
    }

    private static func drawLine(_ text: NSAttributedString, in rect: CGRect, alignment: NSTextAlignment = .left) {
        let styled = NSMutableAttributedString(attributedString: text)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = alignment
        styled.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: styled.length))
        styled.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: Relationships

    struct Route {
        var start: CGPoint
        var control1: CGPoint
        var control2: CGPoint
        var end: CGPoint
        /// Direction a marker at each end points away from its table: -1 left, +1 right.
        var startDirection: CGFloat
        var endDirection: CGFloat

        var bounds: CGRect {
            let xs = [start.x, control1.x, control2.x, end.x], ys = [start.y, control1.y, control2.y, end.y]
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    /// The middle of a column's row, or of the header when the column is not shown.
    private func anchorY(table id: String, column: String?, frame: CGRect) -> CGFloat {
        if let column, let index = displayedColumns[id]?.firstIndex(where: { $0.name == column }) {
            return frame.minY + ERDiagramMetrics.headerHeight + (CGFloat(index) + 0.5) * ERDiagramMetrics.rowHeight
        }
        return frame.minY + ERDiagramMetrics.headerHeight / 2
    }

    /// From the referencing column to the referenced one, leaving and entering on the sides that face each other; a
    /// table that references itself, or two tables stacked one above the other, get a loop out of the right side.
    func route(for relationship: ERDiagramRelationship) -> Route? {
        guard let from = frame(of: relationship.from), let to = frame(of: relationship.to) else { return nil }
        let startY = anchorY(table: relationship.from, column: relationship.fromColumns.first, frame: from)
        let endY = anchorY(table: relationship.to, column: relationship.toColumns.first, frame: to)
        let gap: CGFloat = 24
        if !relationship.isSelfReference, from.maxX + gap <= to.minX || to.maxX + gap <= from.minX {
            let rightward = from.maxX + gap <= to.minX
            let start = CGPoint(x: rightward ? from.maxX : from.minX, y: startY)
            let end = CGPoint(x: rightward ? to.minX : to.maxX, y: endY)
            let reach = max(40, abs(end.x - start.x) / 2)
            let sign: CGFloat = rightward ? 1 : -1
            return Route(start: start, control1: CGPoint(x: start.x + sign * reach, y: start.y),
                         control2: CGPoint(x: end.x - sign * reach, y: end.y), end: end,
                         startDirection: sign, endDirection: -sign)
        }
        let edge = max(from.maxX, to.maxX)
        let start = CGPoint(x: from.maxX, y: startY)
        let end = CGPoint(x: to.maxX, y: relationship.isSelfReference && abs(endY - startY) < 1 ? endY - 10 : endY)
        let reach: CGFloat = relationship.isSelfReference ? 46 : 60
        return Route(start: start, control1: CGPoint(x: edge + reach, y: start.y), control2: CGPoint(x: edge + reach, y: end.y), end: end,
                     startDirection: 1, endDirection: 1)
    }

    private func drawRelationship(_ relationship: ERDiagramRelationship, route: Route, strong: Bool, faded: Bool) {
        let color: NSColor = strong ? .controlAccentColor : NSColor.secondaryLabelColor.withAlphaComponent(faded ? 0.18 : 0.62)
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = strong ? 2 : 1.3
        path.lineCapStyle = .round
        // Markers occupy the first 22 points at each end; the curve starts after the straight lead-in.
        let lead: CGFloat = 22
        let start = CGPoint(x: route.start.x + route.startDirection * lead, y: route.start.y)
        let end = CGPoint(x: route.end.x + route.endDirection * lead, y: route.end.y)
        path.move(to: route.start)
        path.line(to: start)
        path.curve(to: end, controlPoint1: route.control1, controlPoint2: route.control2)
        path.line(to: route.end)
        path.stroke()

        let markers = NSBezierPath()
        markers.lineWidth = path.lineWidth
        markers.lineCapStyle = .round
        let cardinality = relationship.cardinality
        // Referencing side: many (crow's foot) or one (bar), then mandatory (bar) or optional (circle).
        let origin = route.start, direction = route.startDirection
        if cardinality.isUnique {
            Self.bar(at: CGPoint(x: origin.x + direction * 6, y: origin.y), into: markers)
        } else {
            Self.crowsFoot(at: origin, direction: direction, into: markers)
        }
        if cardinality.isMandatory {
            Self.bar(at: CGPoint(x: origin.x + direction * 16, y: origin.y), into: markers)
            markers.stroke()
        } else {
            markers.stroke()
            let circle = NSBezierPath(ovalIn: CGRect(x: origin.x + direction * 17 - 3.5, y: origin.y - 3.5, width: 7, height: 7))
            circle.lineWidth = path.lineWidth
            Theme.gridBackground.setFill()
            circle.fill()
            circle.stroke()
        }
        // Referenced side: exactly one.
        let target = NSBezierPath()
        target.lineWidth = path.lineWidth
        Self.bar(at: CGPoint(x: route.end.x + route.endDirection * 7, y: route.end.y), into: target)
        Self.bar(at: CGPoint(x: route.end.x + route.endDirection * 12, y: route.end.y), into: target)
        target.stroke()
    }

    private static func bar(at point: CGPoint, into path: NSBezierPath) {
        path.move(to: CGPoint(x: point.x, y: point.y - 6))
        path.line(to: CGPoint(x: point.x, y: point.y + 6))
    }

    /// Three prongs spread at the table's edge and meeting a little way out.
    private static func crowsFoot(at point: CGPoint, direction: CGFloat, into path: NSBezierPath) {
        let tip = CGPoint(x: point.x + direction * 11, y: point.y)
        for offset in [-6.5, 0, 6.5] as [CGFloat] {
            path.move(to: CGPoint(x: point.x, y: point.y + offset))
            path.line(to: tip)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let hit = table(at: point)
        press = (event.locationInWindow, point, hit, hit.flatMap { positions[$0] })
        dragged = false
        panning = false
        select(hit)
        if event.clickCount == 2, let hit, let ref = tablesByID[hit]?.ref {
            press = nil
            onOpenTable?(ref)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press else { return }
        let distance = hypot(event.locationInWindow.x - press.window.x, event.locationInWindow.y - press.window.y)
        if !dragged, !panning, distance < 3 { return }
        if let id = press.table, let origin = press.origin {
            if !dragged { NSCursor.closedHand.push() }
            dragged = true
            let point = convert(event.locationInWindow, from: nil)
            positions[id] = CGPoint(x: max(0, origin.x + point.x - press.document.x), y: max(0, origin.y + point.y - press.document.y))
            updateFrameSize(shrink: false)
            autoscroll(with: event)
            needsDisplay = true
        } else {
            if !panning { NSCursor.closedHand.push() }
            panning = true
            scrollView?.pan(byWindowDelta: CGSize(width: event.locationInWindow.x - press.window.x, height: event.locationInWindow.y - press.window.y))
            self.press?.window = event.locationInWindow
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragged || panning { NSCursor.pop() }
        if dragged {
            updateFrameSize(shrink: true)
            onPositionsChanged?(positions)
        }
        dragged = false
        panning = false
        press = nil
    }

    /// Moves a table, for scripted checks and the keyboard.
    func move(_ id: String, to point: CGPoint) {
        guard positions[id] != nil else { return }
        positions[id] = CGPoint(x: max(0, point.x), y: max(0, point.y))
        bringToFront(id)
        updateFrameSize(shrink: true)
        needsDisplay = true
        onPositionsChanged?(positions)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let id = table(at: point), let table = tablesByID[id] {
            select(id)
            menu.items = tableMenuItems(table)
        } else {
            menu.items = backgroundMenuItems?() ?? []
        }
        return menu.items.isEmpty ? nil : menu
    }

    func tableMenuItems(_ table: ERDiagramTable) -> [NSMenuItem] {
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = table.id
            return item
        }
        return [
            item("Open Data", #selector(menuOpen(_:))),
            item("Show Structure", #selector(menuStructure(_:))),
            item("Copy Name", #selector(menuCopyName(_:))),
        ]
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let ref = tablesByID[id]?.ref else { return }
        onOpenTable?(ref)
    }

    @objc private func menuStructure(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let ref = tablesByID[id]?.ref else { return }
        onShowStructure?(ref)
    }

    @objc private func menuCopyName(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
    }

    // MARK: Keys

    /// ⌘C copies the diagram as an image.
    @objc func copy(_ sender: Any?) {
        DiagramImageExporter.copy(self, appearance: effectiveAppearance)
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .carriageReturn?, .enter?:
            if let selectedID, let ref = tablesByID[selectedID]?.ref { return onOpenTable?(ref) ?? () }
        default:
            if event.keyCode == 53 { return select(nil) } // Escape
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        DiagramKeys.handleZoomKey(event, in: self, scrollView: scrollView) || super.performKeyEquivalent(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

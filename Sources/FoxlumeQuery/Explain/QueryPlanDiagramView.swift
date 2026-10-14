import AppKit
import FoxlumeQueryCore

/// The plan as boxes and arrows (TablePro's Diagram mode): a top-down tree on a zoomable canvas with a floating zoom
/// bar. The selection is the plan view's: it shows in the same detail pane as the tree's.
@MainActor
final class QueryPlanDiagramView: NSView {
    let scrollView = DiagramScrollView()
    let canvas = QueryPlanDiagramCanvas()
    private(set) var zoomBar: DiagramZoomBar!
    private var needsFit = true

    var onSelect: ((Int?) -> Void)? {
        get { canvas.onSelect }
        set { canvas.onSelect = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("queryPlanDiagram")
        scrollView.documentView = canvas
        addSubviewFilling(scrollView)
        canvas.scrollView = scrollView
        let export = UI.iconButton("square.and.arrow.up", tooltip: "Export Plan as PNG…", target: self, action: #selector(exportPNG(_:)))
        let copy = UI.iconButton("doc.on.doc", tooltip: "Copy Plan as Image (⌘C)", target: self, action: #selector(copyImage(_:)))
        zoomBar = DiagramZoomBar(scrollView: scrollView, extras: [copy, export])
        zoomBar.place(in: self)
        scrollView.onZoomChange = { [weak self] in self?.zoomBar.update() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ plan: QueryPlan, analysis: QueryPlanAnalysis, metric: QueryPlanMetric?) {
        canvas.show(plan, analysis: analysis, metric: metric)
        needsFit = true
        needsLayout = true
    }

    var metric: QueryPlanMetric? {
        get { canvas.metric }
        set { canvas.metric = newValue }
    }

    /// Selects a step without reporting it back, and scrolls it into view.
    func select(nodeID: Int?) {
        canvas.setSelection(nodeID, notify: false)
        if let nodeID, let frame = canvas.layout?.frames[nodeID], !isHidden {
            scrollView.reveal(frame)
        }
    }

    /// A new plan fits the view once the view has a size; a two-step plan stays at 100 %.
    override func layout() {
        super.layout()
        guard needsFit, !isHidden, scrollView.frame.width > 50, canvas.layout != nil else { return }
        needsFit = false
        // Whole plan when it fits at a readable size, else 75 % from the root down.
        scrollView.fitToView(minimum: 0.75)
        if let root = canvas.plan?.root.id, let frame = canvas.layout?.frames[root] {
            scrollView.reveal(CGRect(x: frame.midX, y: 0, width: 1, height: 1), centre: true)
        }
        if let selected = canvas.selectedID, let frame = canvas.layout?.frames[selected] { scrollView.reveal(frame) }
    }

    func viewDidBecomeVisible() {
        needsLayout = true
    }

    @objc func exportPNG(_ sender: Any?) {
        DiagramImageExporter.save(canvas, format: .png, suggestedName: "query-plan", appearance: effectiveAppearance, in: window)
    }

    @objc func copyImage(_ sender: Any?) {
        DiagramImageExporter.copy(canvas, appearance: effectiveAppearance)
    }
}

/// Draws the plan with AppKit: only the boxes and arrows inside the dirty rect, so a plan of hundreds of steps pans
/// smoothly. Coordinates are the layout's (flipped, origin top left).
@MainActor
final class QueryPlanDiagramCanvas: NSView, DiagramExportable {
    private(set) var plan: QueryPlan?
    private(set) var analysis: QueryPlanAnalysis?
    private(set) var layout: QueryPlanDiagramLayout?
    private var nodes: [Int: QueryPlanNode] = [:]
    private var parents: [Int: Int] = [:]
    private(set) var selectedID: Int?
    weak var scrollView: DiagramScrollView?
    var onSelect: ((Int?) -> Void)?
    private var pressPoint: NSPoint?
    private var pressedNode: Int?
    private var isPanning = false
    var metric: QueryPlanMetric? {
        didSet { if metric != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel("Plan diagram")
        setAccessibilityIdentifier("queryPlanDiagramCanvas")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ plan: QueryPlan, analysis: QueryPlanAnalysis, metric: QueryPlanMetric?) {
        self.plan = plan
        self.analysis = analysis
        self.metric = metric
        let layout = QueryPlanDiagramLayout(plan: plan)
        self.layout = layout
        nodes = Dictionary(uniqueKeysWithValues: plan.allNodes.map { ($0.id, $0) })
        parents = plan.parentIDs
        selectedID = plan.root.id
        setFrameSize(layout.size)
        needsDisplay = true
    }

    func setSelection(_ id: Int?, notify: Bool) {
        guard id != selectedID else { return }
        if let old = selectedID, let frame = layout?.frames[old] { setNeedsDisplay(frame.insetBy(dx: -4, dy: -4)) }
        selectedID = id
        if let id, let frame = layout?.frames[id] { setNeedsDisplay(frame.insetBy(dx: -4, dy: -4)) }
        if notify { onSelect?(id) }
    }

    // MARK: Drawing

    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let detailFont = NSFont.systemFont(ofSize: 11)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    private static let shareFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)

    override func draw(_ dirtyRect: NSRect) {
        Theme.gridBackground.setFill()
        dirtyRect.fill()
        drawDiagram(in: dirtyRect, selected: selectedID)
    }

    var exportSize: CGSize { layout?.size ?? .zero }
    var exportBackground: NSColor { Theme.gridBackground }

    func drawForExport(in rect: CGRect) {
        drawDiagram(in: rect, selected: nil)
    }

    private func drawDiagram(in rect: CGRect, selected: Int?) {
        guard let layout else { return }
        // Arrows first, so boxes sit on top of their ends.
        let edgeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        edgeColor.setStroke()
        edgeColor.setFill()
        for edge in layout.edges {
            let bounds = CGRect(x: min(edge.start.x, edge.end.x), y: edge.end.y, width: abs(edge.start.x - edge.end.x), height: edge.start.y - edge.end.y)
            guard bounds.insetBy(dx: -8, dy: -8).intersects(rect) else { continue }
            let path = NSBezierPath()
            path.lineWidth = 1.2
            let middle = (edge.start.y + edge.end.y) / 2
            path.move(to: edge.start)
            path.curve(to: CGPoint(x: edge.end.x, y: edge.end.y + 6), controlPoint1: CGPoint(x: edge.start.x, y: middle), controlPoint2: CGPoint(x: edge.end.x, y: middle))
            path.stroke()
            // Rows flow up into the parent.
            let head = NSBezierPath()
            head.move(to: edge.end)
            head.line(to: CGPoint(x: edge.end.x - 4.5, y: edge.end.y + 7))
            head.line(to: CGPoint(x: edge.end.x + 4.5, y: edge.end.y + 7))
            head.close()
            head.fill()
        }
        for id in layout.order {
            guard let frame = layout.frames[id], frame.insetBy(dx: -4, dy: -4).intersects(rect), let node = nodes[id] else { continue }
            drawNode(node, in: frame, selected: id == selected)
        }
    }

    private func drawNode(_ node: QueryPlanNode, in frame: CGRect, selected: Bool) {
        let severity = analysis?.severity(of: node.id, metric: metric)
        let metrics = analysis?[node.id]
        let tint = severity?.color ?? NSColor.tertiaryLabelColor
        let box = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        Theme.gridBackground.setFill()
        box.fill()
        tint.withAlphaComponent(severity == nil ? 0.06 : 0.14).setFill()
        box.fill()
        if selected {
            NSColor.controlAccentColor.setStroke()
            box.lineWidth = 2.5
        } else {
            tint.withAlphaComponent(severity == nil ? 0.8 : 0.9).setStroke()
            box.lineWidth = 1
        }
        box.stroke()

        let dimmed = node.neverExecuted
        let primary = dimmed ? NSColor.tertiaryLabelColor : Theme.gridText
        let secondary = dimmed ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor
        let padding: CGFloat = 8
        var x = frame.minX + padding
        var right = frame.maxX - padding
        var y = frame.minY + padding

        // Title line: severity glyph, operation and detail, the share on the right, a warning sign before it.
        if let severity {
            Self.symbol(severity.symbolName, color: severity.color, size: 9)?.draw(in: CGRect(x: x, y: y + 3.5, width: 10, height: 10))
            x += 14
        }
        if let metric, let share = metrics?.share(metric) {
            let text = NSAttributedString(string: QueryPlanText.percent(share), attributes: [.font: Self.shareFont, .foregroundColor: severity.map { Self.readable($0.color) } ?? secondary])
            let width = ceil(text.size().width)
            text.draw(at: CGPoint(x: right - width, y: y + 2))
            right -= width + 6
        }
        if let warnings = metrics?.warnings, !warnings.isEmpty {
            Self.symbol("exclamationmark.triangle.fill", color: .systemOrange, size: 10)?.draw(in: CGRect(x: right - 12, y: y + 2.5, width: 12, height: 11))
            right -= 16
        }
        let title = NSMutableAttributedString(string: node.operation, attributes: [.font: Self.titleFont, .foregroundColor: primary])
        if let detail = node.detail, !detail.isEmpty {
            title.append(NSAttributedString(string: "  " + detail, attributes: [.font: Self.detailFont, .foregroundColor: secondary]))
        }
        Self.drawLine(title, in: CGRect(x: x, y: y, width: right - x, height: 17))
        y += 17

        x = frame.minX + padding
        right = frame.maxX - padding
        var lines: [NSAttributedString] = []
        if node.objectName != nil || node.index != nil {
            var text = node.objectName ?? ""
            if let index = node.index { text += text.isEmpty ? "using \(index)" : " using \(index)" }
            lines.append(NSAttributedString(string: text, attributes: [.font: Self.detailFont, .foregroundColor: secondary]))
        }
        if node.estimatedTotalCost != nil || node.estimatedRows != nil {
            var parts: [String] = []
            // The total only; the startup cost is in the details.
            if let cost = node.estimatedTotalCost { parts.append("cost \(QueryPlanText.cost(cost))") }
            if let rows = node.estimatedRows { parts.append("rows \(QueryPlanText.rows(rows))") }
            lines.append(NSAttributedString(string: parts.joined(separator: "  ·  "), attributes: [.font: Self.numberFont, .foregroundColor: secondary]))
        }
        if node.actualTotalTime != nil || node.actualRows != nil || node.neverExecuted {
            let text: NSMutableAttributedString
            if node.neverExecuted {
                text = NSMutableAttributedString(string: "never executed", attributes: [.font: Self.numberFont, .foregroundColor: secondary])
            } else {
                var parts: [String] = []
                if let time = node.actualTotalTime { parts.append(QueryPlanText.milliseconds(time)) }
                if let rows = node.actualRows { parts.append("actual \(QueryPlanText.rows(rows))") }
                if let loops = node.actualLoops, loops > 1 { parts.append("×\(loops) loops") }
                text = NSMutableAttributedString(string: parts.joined(separator: "  ·  "), attributes: [.font: Self.numberFont, .foregroundColor: primary])
                // Rows far from the estimate are what misled the planner; they stand out as in the tree.
                if let ratio = metrics?.rowEstimateRatio, ratio >= 10 || ratio <= 0.1, let rows = node.actualRows {
                    let range = (text.string as NSString).range(of: "actual \(QueryPlanText.rows(rows))")
                    if range.location != NSNotFound { text.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: range) }
                }
            }
            lines.append(text)
        }
        for line in lines {
            Self.drawLine(line, in: CGRect(x: x, y: y, width: right - x, height: 15))
            y += 15
        }
    }

    private static func drawLine(_ text: NSAttributedString, in rect: CGRect) {
        let truncated = NSMutableAttributedString(attributedString: text)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        truncated.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: truncated.length))
        truncated.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Severity hues as text: yellow and green are too pale on a light background, so they darken there.
    static func readable(_ color: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var resolved = color
            appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
            return dark ? resolved : (resolved.blended(withFraction: 0.35, of: .black) ?? resolved)
        }
    }

    private static var symbolCache: [String: NSImage] = [:]

    static func symbol(_ name: String, color: NSColor, size: CGFloat) -> NSImage? {
        let key = "\(name)|\(size)|\(color.description)"
        if let cached = symbolCache[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .bold).applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        symbolCache[key] = image
        return image
    }

    // MARK: Mouse and keys

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        pressPoint = event.locationInWindow
        pressedNode = layout?.node(at: point)
        isPanning = false
        if let pressedNode { setSelection(pressedNode, notify: true) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressPoint, pressedNode == nil else { return }
        let delta = CGSize(width: event.locationInWindow.x - start.x, height: event.locationInWindow.y - start.y)
        if !isPanning, hypot(delta.width, delta.height) < 3 { return }
        if !isPanning { NSCursor.closedHand.push() }
        isPanning = true
        scrollView?.pan(byWindowDelta: delta)
        pressPoint = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning { NSCursor.pop() }
        isPanning = false
        pressPoint = nil
        pressedNode = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let id = layout?.node(at: convert(event.locationInWindow, from: nil)) else { return nil }
        setSelection(id, notify: true)
        return contextMenu(for: id)
    }

    func contextMenu(for id: Int) -> NSMenu? {
        guard let node = nodes[id] else { return nil }
        let menu = NSMenu()
        let operation = NSMenuItem(title: "Copy Operation", action: #selector(copyOperation(_:)), keyEquivalent: "")
        operation.representedObject = node.operation
        let details = NSMenuItem(title: "Copy Node Details", action: #selector(copyOperation(_:)), keyEquivalent: "")
        details.representedObject = QueryPlanText.details(of: node, metrics: analysis?[id])
        let image = NSMenuItem(title: "Copy Plan as Image", action: #selector(copy(_:)), keyEquivalent: "")
        for item in [operation, details, image] { item.target = self }
        menu.items = [operation, details, .separator(), image]
        return menu
    }

    @objc private func copyOperation(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// ⌘C copies the diagram as an image, as TablePro does.
    @objc func copy(_ sender: Any?) {
        DiagramImageExporter.copy(self, appearance: effectiveAppearance)
    }

    /// Arrow keys walk the tree: up to the parent, down to the first child, left and right between siblings.
    override func keyDown(with event: NSEvent) {
        guard let plan, let selectedID else { return super.keyDown(with: event) }
        var target: Int?
        switch event.specialKey {
        case .upArrow?: target = parents[selectedID]
        case .downArrow?: target = nodes[selectedID]?.children.first?.id
        case .leftArrow?, .rightArrow?:
            if let parent = parents[selectedID], let siblings = nodes[parent]?.children.map(\.id), let index = siblings.firstIndex(of: selectedID) {
                let next = index + (event.specialKey == .leftArrow ? -1 : 1)
                if siblings.indices.contains(next) { target = siblings[next] }
            }
        default:
            return super.keyDown(with: event)
        }
        guard let target, plan.node(id: target) != nil else { return NSSound.beep() }
        setSelection(target, notify: true)
        if let frame = layout?.frames[target] { scrollView?.reveal(frame) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        DiagramKeys.handleZoomKey(event, in: self, scrollView: scrollView) || super.performKeyEquivalent(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

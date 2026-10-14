import AppKit
import FoxlumeQueryCore

/// Everything the selected step reports: estimates, measurements, its share of the work, conditions, buffers,
/// warnings and every other property in the server's order. Selectable, so any value can be copied.
@MainActor
final class QueryPlanDetailView: NSView {
    private let titleLabel = UI.label("", size: 13, weight: .semibold)
    private lazy var copyButton = UI.iconButton("doc.on.doc", tooltip: "Copy Node Details", target: self, action: #selector(copyDetails(_:)))
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private var node: QueryPlanNode?
    private var metrics: QueryPlanAnalysis.NodeMetrics?

    /// The label column; values wrap under themselves.
    private static let valueIndent: CGFloat = 104

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup() {
        setAccessibilityIdentifier("queryPlanDetails")
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyButton.setAccessibilityIdentifier("copyPlanNode")
        let header = UI.hstack([titleLabel, UI.flexibleSpace(), copyButton], spacing: 6)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.gridBackground
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: ThemeManager.didChangeNotification, object: nil)
        show(nil, metrics: nil, plan: nil)
    }

    @objc private func themeChanged() {
        textView.backgroundColor = Theme.gridBackground
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gridBackground.setFill()
        dirtyRect.fill()
    }

    var detailText: String { textView.string }
    var title: String { titleLabel.stringValue }

    /// `plan` adds the plan-wide values (triggers, JIT, planning buffers) under the root step.
    func show(_ node: QueryPlanNode?, metrics: QueryPlanAnalysis.NodeMetrics?, plan: QueryPlan?) {
        self.node = node
        self.metrics = metrics
        copyButton.isHidden = node == nil
        guard let node else {
            titleLabel.stringValue = "No Step Selected"
            titleLabel.textColor = .secondaryLabelColor
            textView.textStorage?.setAttributedString(NSAttributedString(string: "Select a step in the plan to see everything it reports.", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
            return
        }
        titleLabel.stringValue = node.operation
        titleLabel.textColor = Theme.gridText
        textView.textStorage?.setAttributedString(Self.describe(node, metrics: metrics, plan: node.id == 0 ? plan : nil))
        textView.scroll(.zero)
    }

    @objc private func copyDetails(_ sender: Any?) {
        guard let node else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(QueryPlanText.details(of: node, metrics: metrics), forType: .string)
    }

    static func describe(_ node: QueryPlanNode, metrics: QueryPlanAnalysis.NodeMetrics?, plan: QueryPlan?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: valueIndent)]
        paragraph.headIndent = valueIndent
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = 2
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: Theme.gridText, .paragraphStyle: paragraph]
        let headingStyle = NSMutableParagraphStyle()
        headingStyle.paragraphSpacingBefore = 7
        headingStyle.paragraphSpacing = 2

        var sectionOpen = false
        func section(_ title: String) {
            out.append(NSAttributedString(string: title.uppercased() + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: headingStyle,
            ]))
            sectionOpen = true
        }
        func row(_ label: String, _ value: String?, color: NSColor? = nil) {
            guard let value, !value.isEmpty else { return }
            var attributes = valueAttributes
            if let color { attributes[.foregroundColor] = color }
            out.append(NSAttributedString(string: label + "\t", attributes: labelAttributes))
            out.append(NSAttributedString(string: value + "\n", attributes: attributes))
        }

        if let detail = node.detail {
            out.append(NSAttributedString(string: detail + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        if node.objectName != nil || node.index != nil {
            section("Object")
            row("Table", node.objectName)
            row("Index", node.index)
        }
        if node.estimatedTotalCost != nil || node.estimatedRows != nil {
            section("Estimate")
            row("Cost", QueryPlanText.costRange(startup: node.estimatedStartupCost, total: node.estimatedTotalCost))
            row("Rows", node.estimatedRows.map(QueryPlanText.rows))
            row("Width", node.estimatedWidth.flatMap { $0 > 0 ? "\($0) bytes" : nil })
        }
        if node.neverExecuted || node.actualTotalTime != nil || node.actualRows != nil {
            section("Actual")
            if node.neverExecuted { row("Execution", "never executed", color: .secondaryLabelColor) }
            if let startup = node.actualStartupTime, let total = node.actualTotalTime {
                row("Time", "\(QueryPlanText.milliseconds(startup))..\(QueryPlanText.milliseconds(total)) per loop")
            } else {
                row("Time", node.actualTotalTime.map { QueryPlanText.milliseconds($0) + (node.actualLoops ?? 1 > 1 ? " per loop" : "") })
            }
            let misestimated = metrics?.warnings.contains { $0.kind == .rowEstimate } == true
            row("Rows", node.actualRows.map(QueryPlanText.rows), color: misestimated ? .systemOrange : nil)
            row("Loops", node.actualLoops.map { $0.groupedText })
            if let total = metrics?.totalTime, node.actualLoops ?? 1 > 1 { row("Total Time", QueryPlanText.milliseconds(total)) }
        }
        if let metrics, metrics.selfCost != nil || metrics.selfTime != nil {
            section("Share of the Plan")
            row("Self Cost", metrics.selfCost.map { QueryPlanText.cost($0) + (metrics.costShare.map { " (\(QueryPlanText.percent($0)))" } ?? "") })
            row("Self Time", metrics.selfTime.map { QueryPlanText.milliseconds($0) + (metrics.timeShare.map { " (\(QueryPlanText.percent($0)))" } ?? "") })
        }
        if node.filter != nil || node.joinCondition != nil || node.indexCondition != nil {
            section("Conditions")
            row("Filter", node.filter)
            row("Removed by Filter", node.rowsRemovedByFilter.map(QueryPlanText.rows))
            row("Join", node.joinCondition)
            row("Index", node.indexCondition)
        }
        if let buffers = node.buffers, !buffers.isEmpty {
            section("Buffers")
            row("Blocks", buffers.summary)
        }
        if let warnings = metrics?.warnings, !warnings.isEmpty {
            section("Warnings")
            for warning in warnings {
                out.append(NSAttributedString(string: "⚠︎ " + warning.message + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.systemOrange]))
            }
        }
        let properties = QueryPlanNodeProperties.visible(node)
        if !properties.isEmpty {
            section("Details")
            for property in properties { row(property.key, property.value) }
        }
        if let plan, plan.planningTime != nil || plan.executionTime != nil || !plan.properties.isEmpty {
            section("Plan")
            row("Planning", plan.planningTime.map(QueryPlanText.milliseconds))
            row("Execution", plan.executionTime.map(QueryPlanText.milliseconds))
            for property in plan.properties { row(property.key, property.value) }
        }
        if !sectionOpen, node.detail == nil {
            out.append(NSAttributedString(string: "This step reports nothing else.", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return out
    }
}

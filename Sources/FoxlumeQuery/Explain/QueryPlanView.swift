import AppKit
import FoxlumeQueryCore

/// One Explain result in the query tab's result area: a Tree | Raw switch, the share metric, the plan's timings,
/// Copy, then the outline beside the selected step's details, or the server's own output.
@MainActor
final class QueryPlanView: NSView {
    enum Mode: Int {
        case tree
        case raw
    }

    private let modePicker = NSSegmentedControl(labels: ["Tree", "Raw"], trackingMode: .selectOne, target: nil, action: nil)
    private let metricPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let summaryLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private lazy var copyButton = UI.button("Copy", symbol: "doc.on.doc", target: self, action: #selector(copyRaw(_:)))
    private let banner = NSView()
    private let bannerIcon = NSImageView()
    private let bannerLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let split = NSSplitView()
    let outlineView = QueryPlanOutlineView()
    let detailView = QueryPlanDetailView()
    private let rawText = NSTextView()
    private let rawScroll = NSScrollView()
    private var bannerHeight: NSLayoutConstraint?
    private var copyReset: DispatchWorkItem?
    private var didPlaceDivider = false

    private(set) var outcome: ExplainOutcome?
    private(set) var analysis: QueryPlanAnalysis?
    private(set) var mode: Mode = .tree

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup() {
        setAccessibilityIdentifier("queryPlan")
        modePicker.controlSize = .small
        modePicker.selectedSegment = 0
        modePicker.target = self
        modePicker.action = #selector(modeChanged(_:))
        modePicker.setToolTip("The plan as a tree of steps", forSegment: 0)
        modePicker.setToolTip("The output exactly as the server returned it", forSegment: 1)
        metricPopup.controlSize = .small
        metricPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        metricPopup.target = self
        metricPopup.action = #selector(metricChanged(_:))
        metricPopup.toolTip = "What the share column measures"
        summaryLabel.setAccessibilityIdentifier("queryPlanSummary")
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyButton.toolTip = "Copy the server's Explain output"
        copyButton.setAccessibilityIdentifier("copyPlan")

        let toolbar = UI.hstack([modePicker, metricPopup, summaryLabel, UI.flexibleSpace(), copyButton], spacing: 10)
        let toolbarContainer = NSView()
        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.addSubviewFilling(toolbar, insets: NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10))

        bannerIcon.image = Theme.image("arrow.uturn.backward.circle", "Rolled back", size: 12)
        bannerIcon.contentTintColor = .secondaryLabelColor
        bannerLabel.setAccessibilityIdentifier("queryPlanNote")
        bannerLabel.lineBreakMode = .byTruncatingTail
        bannerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubviewFilling(UI.hstack([bannerIcon, bannerLabel, UI.flexibleSpace()], spacing: 6), insets: NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 10))
        banner.wantsLayer = true
        banner.clipsToBounds = true

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(outlineView)
        split.addArrangedSubview(detailView)
        // The details keep their width when the window resizes; the outline takes the difference.
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 1)
        NSLayoutConstraint.activate([
            outlineView.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            detailView.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        outlineView.onSelect = { [weak self] id in self?.showDetails(of: id) }

        rawText.isEditable = false
        rawText.isSelectable = true
        rawText.font = Theme.monospaced(12)
        rawText.textColor = Theme.gridText
        rawText.backgroundColor = Theme.gridBackground
        rawText.textContainerInset = NSSize(width: 10, height: 8)
        rawText.autoresizingMask = [.width]
        rawText.setAccessibilityIdentifier("queryPlanRaw")
        rawScroll.documentView = rawText
        rawScroll.hasVerticalScroller = true
        rawScroll.hasHorizontalScroller = false
        rawScroll.autohidesScrollers = true
        rawScroll.borderType = .noBorder
        rawScroll.isHidden = true

        let topLine = UI.separator()
        let bannerLine = UI.separator()
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubviewFilling(split)
        content.addSubviewFilling(rawScroll)
        for view in [toolbarContainer, topLine, banner, bannerLine, content] { addSubview(view) }
        let bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        self.bannerHeight = bannerHeight
        NSLayoutConstraint.activate([
            toolbarContainer.topAnchor.constraint(equalTo: topAnchor),
            toolbarContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            topLine.topAnchor.constraint(equalTo: toolbarContainer.bottomAnchor),
            topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            banner.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor),
            bannerHeight,
            bannerLine.topAnchor.constraint(equalTo: banner.bottomAnchor),
            bannerLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            bannerLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: bannerLine.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        bannerLine.isHidden = true
        self.bannerLine = bannerLine
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: ThemeManager.didChangeNotification, object: nil)
    }

    private var bannerLine: NSView?

    @objc private func themeChanged() {
        rawText.backgroundColor = Theme.gridBackground
        rawText.textColor = Theme.gridText
    }

    /// The details start at about a third of the width, once the view has one.
    override func layout() {
        super.layout()
        guard !didPlaceDivider, split.frame.width > 500 else { return }
        didPlaceDivider = true
        split.setPosition((split.frame.width - min(320, split.frame.width * 0.32)).rounded(), ofDividerAt: 0)
    }

    // MARK: Content

    func show(_ outcome: ExplainOutcome) {
        self.outcome = outcome
        rawText.string = outcome.rawText
        guard let plan = outcome.plan else {
            analysis = nil
            modePicker.isHidden = true
            metricPopup.isHidden = true
            summaryLabel.stringValue = outcome.rawText.isEmpty ? "" : "\(outcome.request.mode.title) · \(outcome.elapsed.durationText)"
            setNote(outcome.rawText.isEmpty ? "The server returned no plan for this statement." : "This plan could not be read as a tree. Showing the server's output.", symbol: "info.circle")
            setMode(.raw)
            return
        }
        let analysis = QueryPlanAnalysis(plan: plan)
        self.analysis = analysis
        modePicker.isHidden = false
        metricPopup.removeAllItems()
        for metric in analysis.availableMetrics {
            metricPopup.addItem(withTitle: metric.title)
            metricPopup.lastItem?.representedObject = metric.rawValue
        }
        let metric = analysis.defaultMetric
        if let metric { metricPopup.selectItem(withTitle: metric.title) }
        metricPopup.isHidden = analysis.availableMetrics.count < 2
        summaryLabel.stringValue = Self.summary(plan, analysis: analysis)
        summaryLabel.toolTip = summaryLabel.stringValue
        if outcome.rolledBack {
            setNote("Explain Analyze ran the statement inside a transaction that was rolled back. No data was changed.", symbol: "arrow.uturn.backward.circle")
        } else if outcome.request.mode == .analyze {
            setNote("Explain Analyze ran the statement to measure it.", symbol: "stopwatch")
        } else {
            setNote(nil, symbol: nil)
        }
        outlineView.show(plan, analysis: analysis, metric: metric)
        setMode(mode)
    }

    /// `Planning 0.373 ms · Execution 0.053 ms · Cost 14.99 · 4 steps · 1 warning`
    static func summary(_ plan: QueryPlan, analysis: QueryPlanAnalysis) -> String {
        var parts: [String] = []
        if let planning = plan.planningTime { parts.append("Planning \(QueryPlanText.milliseconds(planning))") }
        if let execution = plan.executionTime { parts.append("Execution \(QueryPlanText.milliseconds(execution))") }
        if let cost = plan.root.estimatedTotalCost { parts.append("Cost \(QueryPlanText.cost(cost))") }
        let count = plan.nodeCount
        parts.append("\(count) step\(count == 1 ? "" : "s")")
        let warnings = analysis.warningCount
        if warnings > 0 { parts.append("\(warnings) warning\(warnings == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func setNote(_ text: String?, symbol: String?) {
        bannerLabel.stringValue = text ?? ""
        bannerLabel.toolTip = text
        if let symbol { bannerIcon.image = Theme.image(symbol, "", size: 12) }
        bannerHeight?.constant = text == nil ? 0 : 22
        bannerLine?.isHidden = text == nil
    }

    var note: String? { bannerLabel.stringValue.isEmpty ? nil : bannerLabel.stringValue }
    var summary: String { summaryLabel.stringValue }

    func setMode(_ newMode: Mode) {
        mode = outcome?.plan == nil ? .raw : newMode
        modePicker.selectedSegment = mode.rawValue
        split.isHidden = mode == .raw
        rawScroll.isHidden = mode == .tree
        metricPopup.isEnabled = mode == .tree
    }

    @objc private func modeChanged(_ sender: Any?) {
        setMode(Mode(rawValue: modePicker.selectedSegment) ?? .tree)
    }

    @objc private func metricChanged(_ sender: Any?) {
        guard let raw = metricPopup.selectedItem?.representedObject as? String, let metric = QueryPlanMetric(rawValue: raw) else { return }
        setMetric(metric)
    }

    func setMetric(_ metric: QueryPlanMetric) {
        guard analysis?.availableMetrics.contains(metric) == true else { return }
        metricPopup.selectItem(withTitle: metric.title)
        outlineView.metric = metric
    }

    private func showDetails(of id: Int?) {
        guard let id, let plan = outcome?.plan, let node = plan.node(id: id) else {
            return detailView.show(nil, metrics: nil, plan: nil)
        }
        detailView.show(node, metrics: analysis?[id], plan: plan)
    }

    @objc func copyRaw(_ sender: Any?) {
        guard let text = outcome?.rawText, !text.isEmpty else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyButton.title = "Copied"
        copyReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.copyButton.title = "Copy" }
        copyReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reset)
    }
}

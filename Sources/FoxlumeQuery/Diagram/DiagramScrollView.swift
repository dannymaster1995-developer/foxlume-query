import AppKit

/// The zoom steps the buttons and ⌘= / ⌘- land on. Pinch, ⌘-scroll and Fit can stop anywhere in between, down to
/// `minimum`, so a large diagram still fits a small window.
enum DiagramZoom {
    static let ladder: [CGFloat] = [0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3]
    static let minimum: CGFloat = 0.02
    static let maximum: CGFloat = 3

    static func clamped(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(maximum, max(minimum, value))
    }

    static func step(from value: CGFloat, up: Bool) -> CGFloat {
        let tolerance: CGFloat = 0.001
        if up { return ladder.first { $0 > value + tolerance } ?? maximum }
        return ladder.last { $0 < value - tolerance } ?? clamped(value)
    }

    static func percentText(_ value: CGFloat) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// A document smaller than the viewport sits in its middle rather than in the top-left corner.
final class DiagramClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// The viewport both diagrams use: AppKit's own magnification, so a trackpad pinch zooms at the pointer and a
/// two-finger double tap smart-magnifies; scrolling pans; ⌘ + scroll zooms at the pointer.
@MainActor
final class DiagramScrollView: NSScrollView {
    /// Called after every zoom change, for the zoom bar's percentage.
    var onZoomChange: (() -> Void)?
    /// A ⌘-scroll gesture on a trackpad is many events; the modifier is read once, at its start.
    private var commandScrollGesture = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = DiagramClipView()
        allowsMagnification = true
        minMagnification = DiagramZoom.minimum
        maxMagnification = DiagramZoom.maximum
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = Theme.gridBackground
        translatesAutoresizingMaskIntoConstraints = false
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: ThemeManager.didChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func liveMagnifyEnded() {
        onZoomChange?()
    }

    @objc private func themeChanged() {
        backgroundColor = Theme.gridBackground
        documentView?.needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onZoomChange?()
    }

    override func scrollWheel(with event: NSEvent) {
        let command = event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            commandScrollGesture = command
        }
        let zooming = event.phase.isEmpty && event.momentumPhase.isEmpty ? command : commandScrollGesture && event.momentumPhase.isEmpty
        guard zooming else {
            if !event.momentumPhase.isEmpty, commandScrollGesture { return }
            return super.scrollWheel(with: event)
        }
        // A wheel notch reports lines, a trackpad points; ten points to a line, as NSScrollView scrolls.
        let points = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        let physical = event.isDirectionInvertedFromDevice ? -points : points
        let factor = exp(max(-30, min(30, physical)) * 0.01)
        zoom(to: magnification * factor, around: contentView.convert(event.locationInWindow, from: nil))
    }

    /// Clicking the empty area around a small document still focuses the diagram.
    override func mouseDown(with event: NSEvent) {
        if let documentView, documentView.acceptsFirstResponder {
            window?.makeFirstResponder(documentView)
        }
        super.mouseDown(with: event)
    }

    // MARK: Zoom

    /// `point` is in the clip view's coordinates; nil zooms around the middle of what is shown.
    func zoom(to value: CGFloat, around point: CGPoint? = nil, animated: Bool = false) {
        let target = DiagramZoom.clamped(value)
        guard abs(target - magnification) > 0.0001 else { return }
        let centre = point ?? CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                animator().setMagnification(target, centeredAt: centre)
            }
        } else {
            setMagnification(target, centeredAt: centre)
        }
        onZoomChange?()
    }

    func zoomIn() { zoom(to: DiagramZoom.step(from: magnification, up: true), animated: true) }
    func zoomOut() { zoom(to: DiagramZoom.step(from: magnification, up: false), animated: true) }
    func actualSize() { zoom(to: 1, animated: true) }

    var canZoomIn: Bool { magnification < DiagramZoom.maximum - 0.001 }
    var canZoomOut: Bool { magnification > (DiagramZoom.ladder.first ?? DiagramZoom.minimum) + 0.001 }

    /// The whole drawing in view, never past 100 %: a small plan reads better at its own size. `minimum` keeps text
    /// readable when a diagram opens, at the cost of scrolling.
    func fitToView(minimum: CGFloat = 0) {
        guard let documentView else { return }
        // The document's own size: its frame is scaled by the magnification.
        let content = documentView.bounds.size
        let visible = frame.size
        guard content.width > 0, content.height > 0, visible.width > 0, visible.height > 0 else { return }
        let scale = min(1, max(minimum, min(visible.width / content.width, visible.height / content.height) * 0.98))
        magnification = DiagramZoom.clamped(scale)
        documentView.scroll(.zero)
        reflectScrolledClipView(contentView)
        onZoomChange?()
    }

    /// Scrolls the smallest distance that shows `rect` (document coordinates), or centres it when `centre` is set.
    func reveal(_ rect: CGRect, centre: Bool = false) {
        guard let documentView else { return }
        guard centre else {
            documentView.scrollToVisible(rect.insetBy(dx: -24, dy: -24))
            return
        }
        let visible = contentView.bounds.size
        let origin = CGPoint(x: rect.midX - visible.width / 2, y: rect.midY - visible.height / 2)
        let constrained = contentView.constrainBoundsRect(CGRect(origin: origin, size: visible)).origin
        contentView.scroll(to: constrained)
        reflectScrolledClipView(contentView)
    }

    /// Pans by a distance in window points, as dragging the background does.
    func pan(byWindowDelta delta: CGSize) {
        let scale = max(magnification, 0.01)
        let start = contentView.bounds.origin
        let proposed = CGRect(origin: CGPoint(x: start.x - delta.width / scale, y: start.y + delta.height / scale), size: contentView.bounds.size)
        contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
        reflectScrolledClipView(contentView)
    }
}

/// The floating capsule in the bottom-right corner of a diagram: Zoom Out, the zoom (click for 100 %), Zoom In,
/// Fit, and whatever buttons the diagram adds.
@MainActor
final class DiagramZoomBar: NSVisualEffectView {
    private weak var scrollView: DiagramScrollView?
    private lazy var zoomOutButton = UI.iconButton("minus.magnifyingglass", tooltip: "Zoom Out (⌘-)", target: self, action: #selector(zoomOut(_:)))
    private lazy var zoomInButton = UI.iconButton("plus.magnifyingglass", tooltip: "Zoom In (⌘=)", target: self, action: #selector(zoomIn(_:)))
    private lazy var fitButton = UI.iconButton("arrow.up.left.and.arrow.down.right", tooltip: "Fit to View", target: self, action: #selector(fit(_:)))
    private lazy var percentButton: NSButton = {
        let button = NSButton(title: "100%", target: self, action: #selector(actualSize(_:)))
        button.isBordered = false
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Actual Size"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 42).isActive = true
        button.setAccessibilityIdentifier("diagramZoom")
        return button
    }()

    init(scrollView: DiagramScrollView, extras: [NSView]) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        var views: [NSView] = [zoomOutButton, percentButton, zoomInButton, fitButton]
        if !extras.isEmpty {
            views.append(UI.separator(vertical: true))
            views += extras
        }
        let stack = UI.hstack(views, spacing: 6)
        for view in views where view is NSBox {
            view.heightAnchor.constraint(equalToConstant: 14).isActive = true
        }
        addSubviewFilling(stack, insets: NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10))
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    func update() {
        guard let scrollView else { return }
        percentButton.title = DiagramZoom.percentText(scrollView.magnification)
        zoomInButton.isEnabled = scrollView.canZoomIn
        zoomOutButton.isEnabled = scrollView.canZoomOut
    }

    var percentText: String { percentButton.title }

    @objc private func zoomOut(_ sender: Any?) { scrollView?.zoomOut() }
    @objc private func zoomIn(_ sender: Any?) { scrollView?.zoomIn() }
    @objc private func actualSize(_ sender: Any?) { scrollView?.actualSize() }
    @objc private func fit(_ sender: Any?) { scrollView?.fitToView() }

    /// Pins the bar to the bottom-right corner of `container`.
    func place(in container: NSView) {
        container.addSubview(self, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
    }
}

/// Keys every diagram canvas shares: ⌘= / ⌘+ and ⌘- zoom, ⌘0 is left to Toggle Sidebar.
@MainActor
enum DiagramKeys {
    static func handleZoomKey(_ event: NSEvent, in view: NSView, scrollView: DiagramScrollView?) -> Bool {
        guard view.window?.firstResponder === view, let scrollView,
              event.modifierFlags.intersection([.command, .control, .option]) == .command,
              let characters = event.charactersIgnoringModifiers
        else { return false }
        switch characters {
        case "=", "+":
            scrollView.zoomIn()
            return true
        case "-":
            scrollView.zoomOut()
            return true
        default:
            return false
        }
    }
}

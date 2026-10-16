import AppKit
import FoxlumeQueryCore

struct TabStripItem: Equatable {
    var id: UUID
    var title: String
    var symbol: String
    var isDirty: Bool
    /// Preview tabs are replaced by the next table opened with a single click.
    var isPreview: Bool
}

/// Horizontal strip of editor tabs with a trailing "+" button. Only the tabs that fit the strip's width show,
/// chosen by `TabStripLayout`: the selected one and the most recently used. A "+N" button after them lists the rest.
/// Tabs are placed by frame, so the strip never asks the window for more width than one tab and its buttons.
final class TabStripView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onAdd: (() -> Void)?
    var onPin: ((UUID) -> Void)?

    private static let metrics = TabStripLayout.Metrics()
    private static let leadingInset: CGFloat = 8
    /// The "+" button (24 pt) with its trailing inset and the gap before it.
    private static let trailingRoom: CGFloat = 8 + 24 + 6
    private static let tabHeight: CGFloat = 26

    private let addButton = UI.iconButton("plus", tooltip: "New Query Tab (⌘T)", target: nil, action: nil)
    private let overflowButton = NSButton(title: "", target: nil, action: nil)
    private var items: [TabStripItem] = []
    private var selectedID: UUID?
    private var recency: [UUID] = []
    private var tabViews: [TabButtonView] = []
    private var fit = TabStripLayout(visibleCount: 0, tabWidth: 0, hiddenCount: 0)
    /// Tabs shown in the strip, in tab order.
    private(set) var visibleIDs: [UUID] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addButton.target = self
        addButton.action = #selector(addClicked(_:))
        addButton.setAccessibilityIdentifier("newQueryTab")
        overflowButton.bezelStyle = .recessed
        overflowButton.showsBorderOnlyWhileMouseInside = true
        overflowButton.controlSize = .small
        overflowButton.font = .systemFont(ofSize: 12, weight: .medium)
        overflowButton.target = self
        overflowButton.action = #selector(overflowClicked(_:))
        overflowButton.setAccessibilityIdentifier("tabOverflow")
        overflowButton.isHidden = true
        addSubview(addButton)
        addSubview(overflowButton)
        let bottom = UI.separator()
        addSubview(bottom)
        NSLayoutConstraint.activate([
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 36),
        ])
        setAccessibilityIdentifier("tabStrip")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `recency` lists tab IDs most recently used first; it decides which tabs show when not all fit.
    func update(items: [TabStripItem], selectedID: UUID?, recency: [UUID]) {
        guard items != self.items || selectedID != self.selectedID || recency != self.recency else { return }
        self.items = items
        self.selectedID = selectedID
        self.recency = recency
        reflow(rebuild: true)
        isHidden = false
    }

    /// Tabs behind the "+N" button, in tab order.
    var hiddenIDs: [UUID] {
        let visible = Set(visibleIDs)
        return items.map(\.id).filter { !visible.contains($0) }
    }

    /// Width of each shown tab.
    var tabWidth: CGFloat { fit.tabWidth }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { reflow(rebuild: false) }
    }

    /// Works out which tabs fit and recreates the tab views when that set, or a tab, changed.
    private func reflow(rebuild: Bool) {
        let room = bounds.width - Self.leadingInset - Self.trailingRoom
        fit = TabStripLayout.fit(tabCount: items.count, width: room, metrics: Self.metrics)
        let visible = TabStripLayout.visibleTabs(items.map(\.id), recency: recency, selected: selectedID, limit: fit.visibleCount)
        if rebuild || visible != visibleIDs {
            visibleIDs = visible
            tabViews.forEach { $0.removeFromSuperview() }
            let shown = Set(visible)
            tabViews = items.filter { shown.contains($0.id) }.map { item in
                let tab = TabButtonView(item: item, selected: item.id == selectedID)
                tab.onSelect = { [weak self] in self?.onSelect?(item.id) }
                tab.onClose = { [weak self] in self?.onClose?(item.id) }
                tab.onDoubleClick = { [weak self] in self?.onPin?(item.id) }
                addSubview(tab)
                return tab
            }
        }
        overflowButton.isHidden = !fit.showsOverflow
        overflowButton.title = "+\(fit.hiddenCount)"
        overflowButton.toolTip = fit.hiddenCount == 1 ? "1 more tab" : "\(fit.hiddenCount) more tabs"
        overflowButton.setAccessibilityLabel(overflowButton.toolTip)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let step = fit.tabWidth + Self.metrics.spacing
        let y = ((bounds.height - Self.tabHeight) / 2).rounded()
        for (index, tab) in tabViews.enumerated() {
            tab.frame = NSRect(x: Self.leadingInset + CGFloat(index) * step, y: y, width: fit.tabWidth, height: Self.tabHeight)
        }
        let buttonHeight: CGFloat = 22
        overflowButton.frame = NSRect(x: Self.leadingInset + CGFloat(tabViews.count) * step,
                                      y: ((bounds.height - buttonHeight) / 2).rounded(),
                                      width: Self.metrics.overflowButtonWidth, height: buttonHeight)
    }

    /// The "+N" menu: every hidden tab, in tab order; choosing one selects it, which brings it into the strip.
    func overflowMenu() -> NSMenu {
        let menu = NSMenu(title: "Hidden Tabs")
        let hidden = Set(hiddenIDs)
        for item in items where hidden.contains(item.id) {
            let entry = NSMenuItem(title: item.title + (item.isDirty ? " •" : ""), action: #selector(overflowItemChosen(_:)), keyEquivalent: "")
            entry.target = self
            entry.image = Theme.image(item.symbol, "", size: 12)
            entry.representedObject = item.id
            entry.toolTip = item.title
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func overflowClicked(_ sender: NSButton) {
        overflowMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func overflowItemChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onSelect?(id)
    }

    @objc private func addClicked(_ sender: Any?) {
        onAdd?()
    }
}

private final class TabButtonView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private let item: TabStripItem
    private let selected: Bool
    private let closeButton = NSButton()
    private var hovering = false {
        didSet { updateAppearance() }
    }

    init(item: TabStripItem, selected: Bool) {
        self.item = item
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        toolTip = item.title

        let icon = NSImageView(image: Theme.image(item.symbol, "", size: 11) ?? NSImage())
        icon.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = UI.label(item.title + (item.isDirty ? " •" : ""), size: 12, weight: selected ? .medium : .regular, color: selected ? .labelColor : .secondaryLabelColor)
        if item.isPreview {
            title.font = NSFontManager.shared.convert(title.font ?? .systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let label = UI.hstack([icon, title], spacing: 5)

        closeButton.image = Theme.image("xmark", "Close Tab", size: 9, weight: .bold)
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.toolTip = "Close Tab (⌘W)"
        closeButton.setAccessibilityIdentifier("closeTab")

        addSubview(label)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            label.centerXAnchor.constraint(equalTo: centerXAnchor).withPriority(.defaultLow),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(item.title)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if selected {
                layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
                layer?.borderColor = NSColor.separatorColor.cgColor
                layer?.borderWidth = 1
            } else {
                layer?.backgroundColor = hovering ? NSColor.quaternaryLabelColor.cgColor : nil
                layer?.borderWidth = 0
            }
        }
        closeButton.isHidden = !(selected || hovering)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            onSelect?()
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        onClose?()
    }

    @objc private func closeClicked(_ sender: Any?) {
        onClose?()
    }
}

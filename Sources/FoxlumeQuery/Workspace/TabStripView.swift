import AppKit

struct TabStripItem: Equatable {
    var id: UUID
    var title: String
    var symbol: String
    var isDirty: Bool
    /// Preview tabs are replaced by the next table opened with a single click.
    var isPreview: Bool
}

/// Horizontal strip of editor tabs with a trailing "+" button.
final class TabStripView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onAdd: (() -> Void)?
    var onPin: ((UUID) -> Void)?

    private let stack = NSStackView()
    private let addButton = UI.iconButton("plus", tooltip: "New Query Tab (⌘T)", target: nil, action: nil)
    private var items: [TabStripItem] = []
    private var selectedID: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addButton.target = self
        addButton.action = #selector(addClicked(_:))
        addButton.setAccessibilityIdentifier("newQueryTab")
        addSubview(stack)
        addSubview(addButton)
        let bottom = UI.separator()
        addSubview(bottom)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -6),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 36),
        ])
        let stackWidth = stack.widthAnchor.constraint(equalTo: widthAnchor, constant: -48)
        stackWidth.priority = .defaultLow
        stackWidth.isActive = true
        setAccessibilityIdentifier("tabStrip")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(items: [TabStripItem], selectedID: UUID?) {
        guard items != self.items || selectedID != self.selectedID else { return }
        self.items = items
        self.selectedID = selectedID
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            let tab = TabButtonView(item: item, selected: item.id == selectedID)
            tab.onSelect = { [weak self] in self?.onSelect?(item.id) }
            tab.onClose = { [weak self] in self?.onClose?(item.id) }
            tab.onDoubleClick = { [weak self] in self?.onPin?(item.id) }
            let maxWidth = tab.widthAnchor.constraint(lessThanOrEqualToConstant: 240)
            maxWidth.priority = .required
            maxWidth.isActive = true
            stack.addArrangedSubview(tab)
        }
        isHidden = false
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
        translatesAutoresizingMaskIntoConstraints = false
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
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
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

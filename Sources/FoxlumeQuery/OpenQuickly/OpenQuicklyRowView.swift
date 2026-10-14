import AppKit
import FoxlumeQueryCore

/// One Open Quickly result: a tinted kind icon, the name with the matched characters in bold, an "Open" badge for
/// tables already in a tab, and the subtitle (or, on the selected row, what Return does).
final class OpenQuicklyRowView: NSTableCellView {
    private let tile = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let openBadge = OpenQuicklyBadge(text: "Open")
    private let subtitle = UI.label("", size: 11, color: .secondaryLabelColor)
    private let hint = UI.label("", size: 11, weight: .medium, color: .secondaryLabelColor)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 6
        tile.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        tile.addSubview(icon)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        subtitle.alignment = .right
        subtitle.lineBreakMode = .byTruncatingHead
        subtitle.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        hint.alignment = .right
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)
        openBadge.translatesAutoresizingMaskIntoConstraints = false
        let trailing = NSStackView(views: [openBadge, subtitle, hint])
        trailing.orientation = .horizontal
        trailing.spacing = 8
        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.setHuggingPriority(.required, for: .horizontal)
        addSubview(tile)
        addSubview(title)
        addSubview(trailing)
        textField = title
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 26),
            tile.heightAnchor.constraint(equalToConstant: 26),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ row: QuickOpenRow, selected: Bool) {
        let item = row.item
        let style = Self.style(for: item.kind)
        icon.image = Theme.image(style.symbol, item.kind.sectionTitle, size: 13, weight: .medium)
        icon.contentTintColor = style.color
        tile.layer?.backgroundColor = style.color.withAlphaComponent(0.16).cgColor

        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        let text = NSMutableAttributedString(string: item.title, attributes: base)
        for range in row.highlights where NSMaxRange(range) <= text.length {
            text.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .bold), range: range)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        title.attributedStringValue = text

        openBadge.isHidden = !item.isOpen
        subtitle.stringValue = item.subtitle
        // Paths keep their end (the schema or database); SQL previews keep their start.
        subtitle.lineBreakMode = item.kind.isQuery ? .byTruncatingTail : .byTruncatingHead
        let namesPlace = !item.isCurrentConnection || item.isOutsideCurrentScope
        subtitle.isHidden = item.subtitle.isEmpty || (selected && !namesPlace)
        hint.stringValue = "↩ " + Self.action(for: item)
        hint.isHidden = !selected
        toolTip = item.sql.map { String($0.prefix(600)) } ?? item.title
    }

    /// What Return does with the item.
    static func action(for item: QuickOpenItem) -> String {
        switch item.kind {
        case .table, .view, .systemTable: return item.isOpen ? "Switch to Tab" : "Open"
        case .database, .schema: return "Switch"
        case .savedQuery, .history: return "Open Query"
        }
    }

    static func style(for kind: QuickOpenKind) -> (symbol: String, color: NSColor) {
        switch kind {
        case .table: return ("tablecells", .systemBlue)
        case .view: return ("eye", .systemPurple)
        case .systemTable: return ("gearshape", .systemGray)
        case .database: return ("cylinder", .systemGreen)
        case .schema: return ("square.stack.3d.up", .systemTeal)
        case .savedQuery: return ("star.fill", .systemYellow)
        case .history: return ("clock.arrow.circlepath", .systemOrange)
        }
    }
}

/// A section title such as "Recent" or "Tables".
final class OpenQuicklyHeaderView: NSTableCellView {
    private let label = UI.label("", size: 11, weight: .semibold, color: .secondaryLabelColor)

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// A soft rounded highlight that reads the same whether or not the panel is key; group rows stay clear.
final class OpenQuicklyRowBackground: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 8, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.35 : 0.2).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    /// Labels keep their normal colors on the light highlight.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// A small capsule label.
final class OpenQuicklyBadge: NSView {
    private let label: NSTextField

    init(text: String) {
        label = UI.label(text, size: 10, weight: .semibold, color: .secondaryLabelColor)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.14).cgColor
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

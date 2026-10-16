import AppKit

/// One grid cell: a single-line label that becomes an editor on demand.
final class GridCellView: NSTableCellView {
    enum Style {
        case text
        case number
        case null
        case rowNumber
    }

    enum State {
        case normal
        case modified
        case inserted
        case deleted
    }

    /// Full value placed in the field when editing starts; the label may show a shortened form.
    var editingText = ""
    private var style: Style = .text
    private var state: State = .normal
    private let field = NSTextField(labelWithString: "")
    /// Arrow shown in foreign key cells; opens the referenced row.
    private lazy var referenceButton: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "arrow.right.circle.fill", accessibilityDescription: "Open referenced row") ?? NSImage(), target: self, action: #selector(followReference(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .tertiaryLabelColor
        button.toolTip = "Open the referenced row"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        button.setAccessibilityIdentifier("followReference")
        return button
    }()
    private var fieldToEdge: NSLayoutConstraint?
    private var fieldToButton: NSLayoutConstraint?
    var onFollowReference: (() -> Void)?
    /// Check box drawn before the text of boolean cells; clicks on it are handled by the grid.
    private lazy var toggleView: NSImageView = {
        let view = NSImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.imageScaling = .scaleProportionallyDown
        view.isHidden = true
        view.setAccessibilityIdentifier("booleanToggle")
        return view
    }()
    private var fieldToLeadingEdge: NSLayoutConstraint?
    private var fieldToToggle: NSLayoutConstraint?
    private var toggle: Toggle?

    /// The state a boolean cell's check box shows; NULL gets a dash.
    enum Toggle {
        case on
        case off
        case null
    }
    /// Find-bar highlight: every match is tinted, the current one more strongly.
    private var findHighlight: FindHighlight = .none

    enum FindHighlight {
        case none
        case match
        case current
    }

    /// Cell selection: selected cells are tinted, the active one also gets an outline; row numbers of rows that hold
    /// selected cells get a lighter tint.
    enum SelectionMark {
        case none
        case selected
        case active
        case row
    }

    private var selectionMark: SelectionMark = .none

    func setSelectionMark(_ mark: SelectionMark) {
        guard mark != selectionMark else { return }
        selectionMark = mark
        refreshColors()
    }

    func setFindHighlight(_ highlight: FindHighlight) {
        guard highlight != findHighlight else { return }
        findHighlight = highlight
        refreshColors()
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 1
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        addSubview(field)
        addSubview(referenceButton)
        addSubview(toggleView)
        textField = field
        fieldToEdge = field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5)
        fieldToButton = field.trailingAnchor.constraint(equalTo: referenceButton.leadingAnchor, constant: -2)
        fieldToLeadingEdge = field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5)
        fieldToToggle = field.leadingAnchor.constraint(equalTo: toggleView.trailingAnchor, constant: 3)
        fieldToLeadingEdge?.isActive = true
        NSLayoutConstraint.activate([
            toggleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            toggleView.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleView.widthAnchor.constraint(equalToConstant: 14),
            toggleView.heightAnchor.constraint(equalToConstant: 14),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            referenceButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            referenceButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            referenceButton.widthAnchor.constraint(equalToConstant: 14),
            referenceButton.heightAnchor.constraint(equalToConstant: 14),
        ])
        fieldToEdge?.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(text: String, style: Style, state: State, editable: Bool) {
        self.style = style
        self.state = state
        field.stringValue = text
        field.isEditable = editable
        field.isSelectable = editable
        field.alignment = style == .rowNumber ? .right : .left
        field.placeholderString = nil
        refreshColors()
    }

    /// Shows or hides the foreign key arrow. Cells are reused, so every configure call sets it.
    func setReference(visible: Bool, action: (() -> Void)?) {
        referenceButton.isHidden = !visible
        onFollowReference = visible ? action : nil
        fieldToButton?.isActive = false
        fieldToEdge?.isActive = false
        (visible ? fieldToButton : fieldToEdge)?.isActive = true
    }

    /// Whether a point (in this view) is on the visible foreign key arrow, which handles its own clicks.
    func isReferenceButtonHit(at point: NSPoint) -> Bool {
        !referenceButton.isHidden && referenceButton.frame.insetBy(dx: -2, dy: -2).contains(point)
    }

    /// Shows the check box of a boolean cell, or hides it (nil). Cells are reused, so every configure call sets it.
    func setToggle(_ toggle: Toggle?) {
        self.toggle = toggle
        toggleView.isHidden = toggle == nil
        fieldToToggle?.isActive = false
        fieldToLeadingEdge?.isActive = false
        (toggle == nil ? fieldToLeadingEdge : fieldToToggle)?.isActive = true
        guard let toggle else { return }
        let symbol: String
        switch toggle {
        case .on: symbol = "checkmark.square.fill"
        case .off: symbol = "square"
        case .null: symbol = "minus.square"
        }
        toggleView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toggle == .on ? "true" : (toggle == .off ? "false" : "NULL"))
        refreshColors()
    }

    var toggleState: Toggle? { toggle }

    /// Whether a point (in this view) is on the visible check box of a boolean cell.
    func isToggleHit(at point: NSPoint) -> Bool {
        !toggleView.isHidden && toggleView.frame.insetBy(dx: -3, dy: -3).contains(point)
    }

    @objc private func followReference(_ sender: Any?) {
        onFollowReference?()
    }

    func prepareForEditing() {
        field.stringValue = editingText
        field.placeholderString = style == .null ? "NULL" : nil
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .textColor
        field.font = field.font.map { NSFontManager.shared.convert($0, toNotHaveTrait: .italicFontMask) }
    }

    func finishEditing() {
        field.drawsBackground = false
        refreshColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refreshColors() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    /// Layer colors are resolved once, so resolve them against this view's appearance.
    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        switch state {
        case .normal: layer?.backgroundColor = nil
        case .modified: layer?.backgroundColor = selected ? nil : Theme.modifiedCell.cgColor
        case .inserted: layer?.backgroundColor = selected ? nil : Theme.insertedRow.cgColor
        case .deleted: layer?.backgroundColor = selected ? nil : Theme.deletedRow.cgColor
        }
        switch selectionMark {
        case .none:
            layer?.borderWidth = 0
        case .selected, .active:
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(state == .normal ? 0.24 : 0.36).cgColor
            layer?.borderWidth = selectionMark == .active ? 1.5 : 0
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        case .row:
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
            layer?.borderWidth = 0
        }
        switch findHighlight {
        case .none: break
        case .match: layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(selected ? 0.45 : 0.28).cgColor
        case .current: layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.7).cgColor
        }
        if let toggle {
            switch toggle {
            case .on: toggleView.contentTintColor = selected ? .alternateSelectedControlTextColor : .controlAccentColor
            case .off: toggleView.contentTintColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
            case .null: toggleView.contentTintColor = selected ? .alternateSelectedControlTextColor : Theme.nullText
            }
        }
        guard let baseFont = field.font else { return }
        switch style {
        case .null:
            field.textColor = selected ? .alternateSelectedControlTextColor : Theme.nullText
            field.font = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        case .rowNumber:
            field.textColor = selected ? .alternateSelectedControlTextColor : Theme.rowNumberText
            field.font = NSFontManager.shared.convert(baseFont, toNotHaveTrait: .italicFontMask)
        case .text, .number:
            field.textColor = selected ? .alternateSelectedControlTextColor : Theme.gridText
            field.font = NSFontManager.shared.convert(baseFont, toNotHaveTrait: .italicFontMask)
        }
        if state == .deleted, !selected {
            field.attributedStringValue = NSAttributedString(string: field.stringValue, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: field.font ?? baseFont,
            ])
        }
    }
}

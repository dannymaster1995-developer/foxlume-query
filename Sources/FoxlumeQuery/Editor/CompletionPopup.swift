import AppKit
import FoxlumeQueryCore

/// Where the list opens (spec 11.7): the caret at the token start and the editor, both in screen coordinates.
struct CompletionAnchor {
    var caretRect: NSRect
    /// The list never extends sideways past the editor, so it cannot cover the toolbar beside it.
    var editorFrame: NSRect
    /// The editor font: rows use it, and it sizes the badges and the width.
    var font: NSFont
}

@MainActor
protocol CompletionPopupOwner: AnyObject {
    func completionPopup(didAccept item: CompletionItem)
    /// The list closed on its own: a click elsewhere, or another editor took it.
    func completionPopupDidClose()
}

/// The suggestion list under the caret (spec 11). One panel serves the whole app and never takes focus:
/// the editor keeps the keyboard and forwards Up, Down, Return, Tab and Escape to it.
@MainActor
final class CompletionPopup: NSObject {
    static let shared = CompletionPopup()

    static let rowHeight: CGFloat = 26
    static let verticalPadding: CGFloat = 5
    /// The half row hints that the list scrolls.
    static let maximumVisibleRows: CGFloat = 8.5
    static let horizontalPadding: CGFloat = 13
    static let minimumWidth: CGFloat = 280
    static let maximumCharacters = 64
    static let screenMargin: CGFloat = 22
    static let cornerRadius: CGFloat = 8.5
    /// Below the caret needs at least this much room on screen, unless below still beats above.
    static let minimumRoomBelow: CGFloat = 90

    private let panel: CompletionPanel
    private let background = CompletionBackgroundView()
    private let scroll = NSScrollView()
    private let list = CompletionListView()
    private let divider = NSBox()
    private let preview = NSTextField(labelWithString: "")
    private(set) var items: [CompletionItem] = []
    private(set) var selectedIndex = 0
    private weak var owner: CompletionPopupOwner?
    private var anchor: CompletionAnchor?
    private var mouseMonitor: Any?
    private var showsPreview = false

    override private init() {
        panel = CompletionPanel(contentRect: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The editor ends the session when the app deactivates; hiding here would leave it believing the list is up.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.setAccessibilityIdentifier("completionList")

        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        background.listArea = scroll
        background.onClick = { [weak self] in self?.dismissFromPanel() }

        list.popup = self
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero

        divider.boxType = .separator
        preview.lineBreakMode = .byTruncatingTail
        preview.maximumNumberOfLines = 1
        preview.cell?.truncatesLastVisibleLine = true
        preview.textColor = .secondaryLabelColor

        for view in [scroll, divider, preview] as [NSView] {
            background.addSubview(view)
        }
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    func isShowing(for owner: CompletionPopupOwner) -> Bool {
        self.owner === owner && panel.isVisible
    }

    var selectedItem: CompletionItem? { items[safe: selectedIndex] }

    /// Screen frame of the visible list, for scripted checks of size and placement.
    var visibleFrame: NSRect? { panel.isVisible ? panel.frame : nil }

    /// Opens the list for `owner` with row 0 selected, taking it from any other editor.
    func show(_ items: [CompletionItem], owner: CompletionPopupOwner, anchor: CompletionAnchor, parent: NSWindow) {
        guard !items.isEmpty else { return close(for: owner) }
        if let previous = self.owner, previous !== owner {
            self.owner = nil
            previous.completionPopupDidClose()
        }
        self.owner = owner
        self.anchor = anchor
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        reload(items)
        panel.orderFront(nil)
        installMouseMonitor()
    }

    /// New rows for the same session: row 0 is selected again and the panel is placed from the same anchor.
    func update(_ items: [CompletionItem], for owner: CompletionPopupOwner) {
        guard isShowing(for: owner) else { return }
        guard !items.isEmpty else { return close(for: owner) }
        reload(items)
    }

    /// Places the open list from a new anchor, keeping its rows and selection.
    func move(to anchor: CompletionAnchor, for owner: CompletionPopupOwner) {
        guard isShowing(for: owner) else { return }
        self.anchor = anchor
        layoutPanel()
    }

    func close(for owner: CompletionPopupOwner) {
        guard self.owner === owner else { return }
        hide()
    }

    /// Moves the selection, clamped at the ends, and centers the selected row.
    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, selectedIndex + delta))
        guard row != selectedIndex else { return }
        select(row)
        scrollToCenter(row, animated: true)
    }

    private func hide() {
        removeMouseMonitor()
        owner = nil
        anchor = nil
        items = []
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// A click on the padding, the preview, a right click, or a click anywhere else in the app.
    fileprivate func dismissFromPanel() {
        let previous = owner
        hide()
        previous?.completionPopupDidClose()
    }

    fileprivate func clicked(row: Int, accept: Bool) {
        guard let item = items[safe: row] else { return dismissFromPanel() }
        if row != selectedIndex { select(row) }
        if accept { owner?.completionPopup(didAccept: item) }
    }

    private func select(_ row: Int) {
        let hadPreview = showsPreview
        selectedIndex = row
        list.needsDisplay = true
        // The panel only resizes when the preview strip appears or disappears, not on every arrow key.
        if hadPreview != (previewText != nil) {
            layoutPanel()
        } else {
            preview.stringValue = previewText ?? ""
        }
    }

    private func reload(_ items: [CompletionItem]) {
        self.items = items
        selectedIndex = 0
        layoutPanel()
        list.needsDisplay = true
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// First line of the selected item's documentation.
    private var previewText: String? {
        guard let documentation = selectedItem?.documentation else { return nil }
        let line = documentation.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Size and placement

    private func layoutPanel() {
        guard let anchor else { return }
        let font = anchor.font
        list.font = font
        preview.font = font
        let width = Self.width(for: items, font: font)
        let visibleRows = min(CGFloat(items.count), Self.maximumVisibleRows)
        let listHeight = (Self.rowHeight * visibleRows + 2 * Self.verticalPadding).rounded(.up)
        let text = previewText
        showsPreview = text != nil
        preview.stringValue = text ?? ""
        let lineHeight = Self.lineHeight(of: font)
        let previewHeight = showsPreview ? lineHeight + 16 : 0
        let dividerHeight: CGFloat = showsPreview ? 1 : 0
        let height = listHeight + dividerHeight + previewHeight

        // The background is not flipped: lay out from the bottom.
        preview.isHidden = !showsPreview
        divider.isHidden = !showsPreview
        preview.frame = NSRect(x: Self.horizontalPadding, y: 8, width: width - 2 * Self.horizontalPadding, height: lineHeight)
        divider.frame = NSRect(x: 0, y: previewHeight, width: width, height: 1)
        scroll.frame = NSRect(x: 0, y: height - listHeight, width: width, height: listHeight)
        list.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(items.count) * Self.rowHeight + 2 * Self.verticalPadding)
        panel.setFrame(placement(for: NSSize(width: width, height: height), anchor: anchor), display: true)
        panel.invalidateShadow()
    }

    /// Badge plus the longest label and detail over every item, in editor characters (spec 11.2).
    static func width(for items: [CompletionItem], font: NSFont) -> CGFloat {
        let characterWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        let longest = items.reduce(0) { widest, item in
            max(widest, item.label.utf16.count + (item.detail.map { $0.utf16.count + 1 } ?? 0))
        }
        let textWidth = CGFloat(min(longest + 2, maximumCharacters)) * characterWidth
        let badgeWidth = font.pointSize + 6
        return max(minimumWidth, (badgeWidth + textWidth + 2 * horizontalPadding).rounded(.up))
    }

    static func lineHeight(of font: NSFont) -> CGFloat {
        (font.ascender - font.descender + font.leading).rounded(.up)
    }

    /// Lines the label text up with the token, keeps clear of the screen and editor edges, and flips above the
    /// caret only when below is both short and smaller than above.
    private func placement(for size: NSSize, anchor: CompletionAnchor) -> NSRect {
        let caret = anchor.caretRect
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: caret.minX, y: caret.midY)) } ?? panel.parent?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? caret.insetBy(dx: -2000, dy: -2000)
        var limits = visible.intersection(anchor.editorFrame)
        if limits.isNull || limits.width <= 0 { limits = visible }
        let minX = limits.minX + Self.screenMargin
        let maxX = limits.maxX - size.width - Self.screenMargin
        var x = caret.minX - 5 - Self.horizontalPadding - anchor.font.pointSize
        x = maxX < minX ? minX : min(max(x, minX), maxX)
        let roomBelow = caret.minY - visible.minY
        let roomAbove = visible.maxY - caret.maxY
        let y = roomBelow >= Self.minimumRoomBelow || roomBelow >= roomAbove ? caret.minY - size.height : caret.maxY
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    private func scrollToCenter(_ row: Int, animated: Bool) {
        let clip = scroll.contentView
        let visibleHeight = clip.bounds.height
        let documentHeight = list.frame.height
        let rowMiddle = Self.verticalPadding + (CGFloat(row) + 0.5) * Self.rowHeight
        let y = max(0, min(rowMiddle - visibleHeight / 2, documentHeight - visibleHeight))
        let target = NSPoint(x: 0, y: y.rounded())
        guard target != clip.bounds.origin else { return }
        guard animated else {
            clip.setBoundsOrigin(target)
            scroll.reflectScrolledClipView(clip)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(target)
        } completionHandler: { [scroll] in
            MainActor.assumeIsolated { scroll.reflectScrolledClipView(clip) }
        }
    }

    // MARK: Clicks elsewhere

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                // The click still goes through, so clicking another control both closes the list and works.
                if let self, event.window !== self.panel { self.dismissFromPanel() }
            }
            return event
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    // MARK: Drawing helpers

    /// Badge colors from spec 4.1.
    static func tint(for kind: CompletionKind) -> NSColor {
        switch kind {
        case .favorite: return .systemYellow
        case .column: return .systemOrange
        case .alias: return .systemGray
        case .table: return .systemTeal
        case .view: return .systemPurple
        case .function: return .systemPink
        case .operator: return .systemIndigo
        case .keyword: return .systemBlue
        case .schema, .database: return .systemGreen
        case .key: return .systemOrange
        }
    }

    private static var badgeCache: [String: NSImage] = [:]

    /// White glyph on the kind's color; grey for deprecated items. Symbols without a circle are drawn in the color.
    static func badge(for kind: CompletionKind, deprecated: Bool, pointSize: CGFloat) -> NSImage? {
        let key = "\(kind.rawValue)|\(deprecated)|\(pointSize)"
        if let cached = badgeCache[key] { return cached }
        let tint = deprecated ? NSColor.systemGray : Self.tint(for: kind)
        let colors: [NSColor] = kind.symbolName.contains(".circle") ? [.white, tint] : [tint]
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        let image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: kind.rawValue)?.withSymbolConfiguration(configuration)
        badgeCache[key] = image
        return image
    }

    static func warningBadge(pointSize: CGFloat) -> NSImage? {
        let key = "warning|\(pointSize)"
        if let cached = badgeCache[key] { return cached }
        // Multicolor keeps the dark exclamation mark on the yellow triangle.
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.preferringMulticolor())
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Deprecated")?.withSymbolConfiguration(configuration)
        badgeCache[key] = image
        return image
    }

    /// The font manager only steps the system monospaced font up to semibold, which barely shows against the
    /// regular label, so that font is asked for by weight.
    static func boldFont(_ font: NSFont) -> NSFont {
        if font.fontName.hasPrefix(".AppleSystemUIFontMonospaced") {
            return NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
        }
        let converted = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        if converted.fontDescriptor.symbolicTraits.contains(.bold) { return converted }
        return NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Never key or main, so the editor keeps focus while the list is up.
private final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Menu material behind the rows. Clicks outside the list (padding, divider, preview) close the popup.
private final class CompletionBackgroundView: NSVisualEffectView {
    weak var listArea: NSView?
    var onClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return nil }
        if let listArea, listArea.frame.contains(local) { return super.hitTest(point) }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
    override func otherMouseDown(with event: NSEvent) { onClick?() }
}

/// Plain drawn rows, so nothing in the list can take focus (spec 11.3).
private final class CompletionListView: NSView {
    weak var popup: CompletionPopup?
    var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func row(at point: NSPoint) -> Int? {
        let offset = point.y - CompletionPopup.verticalPadding
        guard offset >= 0, let count = popup?.items.count else { return nil }
        let row = Int(offset / CompletionPopup.rowHeight)
        return row < count ? row : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let popup else { return }
        guard let row = row(at: convert(event.locationInWindow, from: nil)) else { return popup.dismissFromPanel() }
        popup.clicked(row: row, accept: event.clickCount >= 2)
    }

    override func rightMouseDown(with event: NSEvent) { popup?.dismissFromPanel() }
    override func otherMouseDown(with event: NSEvent) { popup?.dismissFromPanel() }

    override func draw(_ dirtyRect: NSRect) {
        guard let popup, !popup.items.isEmpty else { return }
        let height = CompletionPopup.rowHeight
        let first = max(0, Int((dirtyRect.minY - CompletionPopup.verticalPadding) / height))
        let last = min(popup.items.count - 1, Int((dirtyRect.maxY - CompletionPopup.verticalPadding) / height))
        guard first <= last else { return }
        let bold = CompletionPopup.boldFont(font)
        let lineHeight = CompletionPopup.lineHeight(of: font)
        for row in first...last {
            let rect = NSRect(x: 0, y: CompletionPopup.verticalPadding + CGFloat(row) * height, width: bounds.width, height: height)
            draw(popup.items[row], in: rect, selected: row == popup.selectedIndex, bold: bold, lineHeight: lineHeight)
        }
    }

    private func draw(_ item: CompletionItem, in rect: NSRect, selected: Bool, bold: NSFont, lineHeight: CGFloat) {
        if selected {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
        }
        let content = rect.insetBy(dx: CompletionPopup.horizontalPadding, dy: 3)
        let badgeWidth = font.pointSize + 6
        if let badge = CompletionPopup.badge(for: item.kind, deprecated: item.isDeprecated, pointSize: font.pointSize + 2) {
            let size = badge.size
            let frame = NSRect(x: content.minX + (badgeWidth - size.width) / 2, y: content.midY - size.height / 2, width: size.width, height: size.height)
            badge.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        var textRight = content.maxX
        if item.isDeprecated, let warning = CompletionPopup.warningBadge(pointSize: font.pointSize) {
            let size = warning.size
            let frame = NSRect(x: content.maxX - size.width, y: content.midY - size.height / 2, width: size.width, height: size.height)
            warning.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            textRight = frame.minX - 4
        }
        let textLeft = content.minX + badgeWidth + 2
        guard textRight > textLeft else { return }
        let text = attributedText(for: item, selected: selected, bold: bold)
        let frame = NSRect(x: textLeft, y: (content.midY - lineHeight / 2).rounded(), width: textRight - textLeft, height: lineHeight)
        text.draw(with: frame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Label in the editor font with the matched characters bold, then the detail one space after it.
    private func attributedText(for item: CompletionItem, selected: Bool, bold: NSFont) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let labelColor: NSColor = selected ? .alternateSelectedControlTextColor : (item.isDeprecated ? .secondaryLabelColor : .labelColor)
        let detailColor: NSColor = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.7) : .secondaryLabelColor
        let text = NSMutableAttributedString(string: item.label, attributes: [.font: font, .foregroundColor: labelColor, .paragraphStyle: paragraph])
        let length = (item.label as NSString).length
        for range in item.highlights where range.location != NSNotFound && NSMaxRange(range) <= length {
            text.addAttribute(.font, value: bold, range: range)
        }
        if let detail = item.detail, !detail.isEmpty {
            text.append(NSAttributedString(string: " " + detail, attributes: [.font: font, .foregroundColor: detailColor, .paragraphStyle: paragraph]))
        }
        return text
    }
}

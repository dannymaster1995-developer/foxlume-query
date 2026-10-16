import AppKit
import FoxlumeQueryCore

/// Read-only hex dump of a value: offset, 16 hex bytes and their ASCII per line. Only the visible lines are
/// formatted and drawn, so a blob of many megabytes opens at once. A drag over the hex or the ASCII column selects
/// bytes; Copy puts them on the clipboard as hex digits.
@MainActor
final class HexDumpView: NSView {
    let data: Data
    private let font: NSFont
    private let charWidth: CGFloat
    private let lineHeight: CGFloat
    private let offsetDigits: Int
    private let inset = NSSize(width: 8, height: 6)
    /// Selected bytes; empty when nothing is selected.
    private(set) var selection: Range<Int> = 0..<0
    private var anchor = 0
    var onSelectionChange: (() -> Void)?

    init(data: Data) {
        self.data = data
        font = Theme.monospaced(12)
        charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        lineHeight = ceil(font.ascender - font.descender + font.leading) + 2
        offsetDigits = HexDump.offsetDigits(byteCount: data.count)
        super.init(frame: .zero)
        setAccessibilityIdentifier("hexView")
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Hex dump, \(data.count) bytes")
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy as Hex", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        self.menu = menu
        frame.size = contentSize
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    var lineCount: Int { HexDump.lineCount(byteCount: data.count) }

    // Columns, in characters from the left inset.
    private var hexStart: Int { offsetDigits + 2 }
    private var asciiStart: Int { hexStart + HexDump.hexColumnWidth + 1 }
    private var totalColumns: Int { asciiStart + HexDump.bytesPerLine }

    private var contentSize: NSSize {
        NSSize(width: CGFloat(totalColumns) * charWidth + inset.width * 2, height: CGFloat(max(lineCount, 1)) * lineHeight + inset.height * 2)
    }

    /// Fills the scroll view's width; the height is one line per 16 bytes.
    func fit(width: CGFloat) {
        let size = NSSize(width: max(contentSize.width, width), height: contentSize.height)
        if frame.size != size { setFrameSize(size) }
    }

    private func x(column: Int) -> CGFloat { inset.width + CGFloat(column) * charWidth }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard lineCount > 0 else {
            ("Empty value" as NSString).draw(at: NSPoint(x: inset.width, y: inset.height), withAttributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
            return
        }
        let first = max(0, Int((dirtyRect.minY - inset.height) / lineHeight))
        let last = min(lineCount - 1, Int((dirtyRect.maxY - inset.height) / lineHeight))
        guard first <= last else { return }
        let offsetAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let textAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let highlight = window?.firstResponder === self ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor
        for index in first...last {
            let y = inset.height + CGFloat(index) * lineHeight
            drawSelection(line: index, y: y, color: highlight)
            let line = HexDump.line(index, of: data, offsetDigits: offsetDigits)
            (line.offset as NSString).draw(at: NSPoint(x: x(column: 0), y: y + 1), withAttributes: offsetAttributes)
            (line.hex as NSString).draw(at: NSPoint(x: x(column: hexStart), y: y + 1), withAttributes: textAttributes)
            (line.ascii as NSString).draw(at: NSPoint(x: x(column: asciiStart), y: y + 1), withAttributes: offsetAttributes)
        }
        NSColor.separatorColor.setFill()
        NSRect(x: x(column: asciiStart) - charWidth, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }

    private func drawSelection(line: Int, y: CGFloat, color: NSColor) {
        let lineStart = line * HexDump.bytesPerLine
        let selected = selection.clamped(to: lineStart..<(lineStart + HexDump.bytesPerLine))
        guard !selected.isEmpty else { return }
        let firstByte = selected.lowerBound - lineStart
        let lastByte = selected.upperBound - 1 - lineStart
        color.setFill()
        let hexLeft = x(column: hexStart + HexDump.hexColumn(ofByte: firstByte))
        let hexRight = x(column: hexStart + HexDump.hexColumn(ofByte: lastByte) + 2)
        NSRect(x: hexLeft, y: y, width: hexRight - hexLeft, height: lineHeight).fill()
        NSRect(x: x(column: asciiStart + firstByte), y: y, width: CGFloat(lastByte - firstByte + 1) * charWidth, height: lineHeight).fill()
    }

    // MARK: Selection

    /// The byte under a point of the hex or the ASCII column, clamped to the value.
    func byteIndex(at point: NSPoint) -> Int {
        guard !data.isEmpty else { return 0 }
        let line = min(max(0, Int((point.y - inset.height) / lineHeight)), lineCount - 1)
        let column = Int(floor((point.x - inset.width) / charWidth))
        let inLine: Int
        if column >= asciiStart - 1 {
            inLine = min(max(column - asciiStart, 0), HexDump.bytesPerLine - 1)
        } else {
            inLine = HexDump.byte(atHexColumn: column - hexStart)
        }
        return min(line * HexDump.bytesPerLine + inLine, data.count - 1)
    }

    func select(_ range: Range<Int>) {
        let clamped = range.clamped(to: 0..<data.count)
        guard clamped != selection else { return }
        selection = clamped
        needsDisplay = true
        onSelectionChange?()
    }

    func scrollToSelection() {
        guard !selection.isEmpty else { return }
        let line = selection.lowerBound / HexDump.bytesPerLine
        scrollToVisible(NSRect(x: 0, y: inset.height + CGFloat(line) * lineHeight, width: 1, height: lineHeight))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let index = byteIndex(at: convert(event.locationInWindow, from: nil))
        guard !data.isEmpty else { return }
        if event.modifierFlags.contains(.shift), !selection.isEmpty {
            extendSelection(to: index)
        } else {
            anchor = index
            select(index..<(index + 1))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !data.isEmpty else { return }
        autoscroll(with: event)
        extendSelection(to: byteIndex(at: convert(event.locationInWindow, from: nil)))
    }

    private func extendSelection(to index: Int) {
        select(min(anchor, index)..<(max(anchor, index) + 1))
    }

    override func selectAll(_ sender: Any?) {
        anchor = 0
        select(0..<data.count)
    }

    /// The selection as hex digits, or nil when nothing is selected.
    var selectedHex: String? {
        selection.isEmpty ? nil : HexDump.hexString(of: data, range: selection)
    }

    @objc func copy(_ sender: Any?) {
        guard let hex = selectedHex else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }
}

extension HexDumpView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return !selection.isEmpty }
        return true
    }
}

/// The hex view in a scroll view that keeps it as wide as the visible area.
@MainActor
final class HexDumpScrollView: NSScrollView {
    let hexView: HexDumpView

    init(data: Data) {
        hexView = HexDumpView(data: data)
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        documentView = hexView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func tile() {
        super.tile()
        hexView.fit(width: contentSize.width)
    }
}

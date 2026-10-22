import AppKit
import FoxlumeQueryCore

/// Draws the inline suggestion in grey after the caret. It is never part of the text storage, so it has no undo
/// entry and is not copied or saved. Later lines of a multi-line suggestion are drawn on the lines below, over a
/// patch of editor background, and the rest of the caret's line is drawn after the suggestion's end.
extension SQLTextView {
    /// The editor's text color faded toward its background: readable on light, dark and imported themes alike.
    static func ghostTextColor(foreground: NSColor, background: NSColor) -> NSColor {
        guard let text = foreground.usingColorSpace(.sRGB), let back = background.usingColorSpace(.sRGB) else {
            return NSColor.tertiaryLabelColor
        }
        let weight: CGFloat = 0.45
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a * weight + b * (1 - weight) }
        return NSColor(srgbRed: mix(text.redComponent, back.redComponent), green: mix(text.greenComponent, back.greenComponent),
                       blue: mix(text.blueComponent, back.blueComponent), alpha: 1)
    }

    /// Top-left of the caret at `location` and its line's height, in view coordinates.
    func caretOrigin(at location: Int) -> (point: NSPoint, lineHeight: CGFloat)? {
        guard let layoutManager, let textContainer else { return nil }
        let text = string as NSString
        let location = min(max(0, location), text.length)
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        let padding = textContainer.lineFragmentPadding
        if text.length == 0 || (location == text.length && text.character(at: text.length - 1) == 10) {
            var extra = layoutManager.extraLineFragmentRect
            if extra.isEmpty, text.length > 0 {
                let last = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: text.length - 1), effectiveRange: nil)
                extra = NSRect(x: 0, y: last.maxY, width: last.width, height: last.height)
            }
            let height = extra.height > 0 ? extra.height : layoutManager.defaultLineHeight(for: font ?? Theme.monospaced(12))
            return (NSPoint(x: origin.x + extra.minX + padding, y: origin.y + extra.minY), height)
        }
        if location == text.length {
            let glyph = layoutManager.glyphIndexForCharacter(at: text.length - 1)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let bounds = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            return (NSPoint(x: origin.x + bounds.maxX, y: origin.y + line.minY), line.height)
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let glyphPoint = layoutManager.location(forGlyphAt: glyph)
        return (NSPoint(x: origin.x + line.minX + glyphPoint.x, y: origin.y + line.minY), line.height)
    }

    /// Where each line of the ghost is drawn, for drawing and for tests.
    func ghostLineRects() -> [(text: String, rect: NSRect)] {
        guard let ghost = inlineSuggestions.ghost, let caret = caretOrigin(at: ghost.location) else { return [] }
        let attributes = ghostAttributes(color: .black)
        let leftEdge = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        var result: [(String, NSRect)] = []
        for (index, line) in ghost.text.components(separatedBy: "\n").enumerated() {
            let width = (line as NSString).size(withAttributes: attributes).width
            let x = index == 0 ? caret.point.x : leftEdge
            result.append((line, NSRect(x: x, y: caret.point.y + CGFloat(index) * caret.lineHeight, width: width, height: caret.lineHeight)))
        }
        return result
    }

    func drawInlineSuggestion(in dirtyRect: NSRect) {
        guard let ghost = inlineSuggestions.ghost else { return }
        let lines = ghostLineRects()
        guard let first = lines.first, let last = lines.last else { return }
        let color = Self.ghostTextColor(foreground: Theme.editorForeground, background: Theme.editorBackground)
        let attributes = ghostAttributes(color: color)
        // The rest of the caret's line moves after the ghost, as it would once the suggestion is accepted.
        let trailing = trailingLineText(from: ghost.location)
        let trailingWidth = (trailing as NSString).size(withAttributes: attributes).width
        let lineColor = window?.firstResponder === self ? (statementBandRange != nil ? Theme.currentLineInBand : Theme.currentLine) : Theme.editorBackground
        if trailingWidth > 0 {
            lineColor.setFill()
            NSRect(x: first.rect.minX, y: first.rect.minY, width: max(first.rect.width, trailingWidth) + 1, height: first.rect.height).fill()
        }
        for (index, line) in lines.enumerated() {
            var cover = line.rect
            if index == lines.count - 1 { cover.size.width += trailingWidth }
            guard cover.intersects(dirtyRect) else { continue }
            if index > 0 {
                Theme.editorBackground.setFill()
                cover.insetBy(dx: -1, dy: 0).fill()
            }
            (line.text as NSString).draw(at: line.rect.origin, withAttributes: attributes)
        }
        if !trailing.isEmpty {
            (trailing as NSString).draw(at: NSPoint(x: last.rect.maxX, y: last.rect.minY), withAttributes: ghostAttributes(color: Theme.editorForeground))
        }
    }

    /// The text from `location` to the end of its line, without the line break.
    private func trailingLineText(from location: Int) -> String {
        let text = string as NSString
        guard location < text.length else { return "" }
        var end = location
        while end < text.length, text.character(at: end) != 10, text.character(at: end) != 13 { end += 1 }
        return text.substring(with: NSRange(location: location, length: end - location))
    }

    private func ghostAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font ?? Theme.monospaced(12), .foregroundColor: color]
    }
}

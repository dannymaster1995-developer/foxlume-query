import AppKit

/// The app icon, drawn in code so the bundle needs no binary assets.
enum AppIcon {
    static func image(size: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    static func draw(in rect: NSRect) {
        let s = rect.width / 1024
        let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 24 * s
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.set()
        NSColor(srgbRed: 0.10, green: 0.20, blue: 0.45, alpha: 1).setFill()
        tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.20, green: 0.45, blue: 0.98, alpha: 1),
            NSColor(srgbRed: 0.05, green: 0.70, blue: 0.78, alpha: 1),
        ])
        gradient?.draw(in: tilePath, angle: -60)

        // Database cylinder: three stacked discs.
        let white = NSColor.white
        let body = NSRect(x: 292 * s, y: 300 * s, width: 440 * s, height: 420 * s)
        let ellipseHeight = 120 * s
        white.withAlphaComponent(0.95).setFill()
        let sides = NSBezierPath()
        sides.appendOval(in: NSRect(x: body.minX, y: body.minY - ellipseHeight / 2, width: body.width, height: ellipseHeight))
        sides.append(NSBezierPath(rect: NSRect(x: body.minX, y: body.minY, width: body.width, height: body.height)))
        sides.fill()

        let bands = [body.minY + body.height * 0.33, body.minY + body.height * 0.66]
        NSColor(srgbRed: 0.14, green: 0.52, blue: 0.92, alpha: 1).setStroke()
        for y in bands {
            let arc = NSBezierPath(ovalIn: NSRect(x: body.minX, y: y - ellipseHeight / 2, width: body.width, height: ellipseHeight))
            arc.lineWidth = 16 * s
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: body.minX - 10 * s, y: y - ellipseHeight, width: body.width + 20 * s, height: ellipseHeight)).addClip()
            arc.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        let top = NSBezierPath(ovalIn: NSRect(x: body.minX, y: body.maxY - ellipseHeight / 2, width: body.width, height: ellipseHeight))
        NSColor(srgbRed: 0.85, green: 0.95, blue: 1, alpha: 1).setFill()
        top.fill()

        // Query chevron on the front of the cylinder.
        let chevron = NSBezierPath()
        chevron.lineWidth = 34 * s
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.move(to: NSPoint(x: 420 * s, y: 560 * s))
        chevron.line(to: NSPoint(x: 500 * s, y: 500 * s))
        chevron.line(to: NSPoint(x: 420 * s, y: 440 * s))
        chevron.move(to: NSPoint(x: 530 * s, y: 430 * s))
        chevron.line(to: NSPoint(x: 610 * s, y: 430 * s))
        NSColor(srgbRed: 0.10, green: 0.36, blue: 0.85, alpha: 1).setStroke()
        chevron.stroke()
    }

    /// Writes a PNG of the icon, used by the bundle script to build `AppIcon.icns`.
    static func writePNG(to url: URL, size: Int) throws {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

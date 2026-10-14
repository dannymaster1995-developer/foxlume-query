import AppKit

/// The app icon, drawn in code from the brand artwork so the bundle needs no binary assets.
enum AppIcon {
    static func image(size: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    /// The Foxlume Query mark: a fox head on a dark tile with a small database badge. Coordinates follow the
    /// brand artwork's 1024-point grid, with y pointing down.
    static func draw(in rect: NSRect) {
        let s = rect.width / 1024
        NSGraphicsContext.saveGraphicsState()
        let grid = NSAffineTransform()
        grid.translateX(by: rect.minX, yBy: rect.maxY)
        grid.scaleX(by: s, yBy: -s)
        grid.concat()

        let ink = color(0x1F1A17)
        let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 24 * s
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.set()
        ink.setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()

        drawFox()
        drawDatabaseBadge()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawFox() {
        NSGraphicsContext.saveGraphicsState()
        let place = NSAffineTransform()
        place.translateX(by: 212, yBy: 128)
        place.scale(by: 3)
        place.concat()

        let head = NSBezierPath()
        head.move(to: NSPoint(x: 32, y: 96))
        head.line(to: NSPoint(x: 38, y: 36))
        quad(head, NSPoint(x: 40, y: 26), NSPoint(x: 49, y: 31))
        head.line(to: NSPoint(x: 86, y: 62))
        quad(head, NSPoint(x: 100, y: 57), NSPoint(x: 114, y: 62))
        head.line(to: NSPoint(x: 151, y: 31))
        quad(head, NSPoint(x: 160, y: 26), NSPoint(x: 162, y: 36))
        head.line(to: NSPoint(x: 168, y: 96))
        quad(head, NSPoint(x: 169, y: 108), NSPoint(x: 160, y: 118))
        head.line(to: NSPoint(x: 110, y: 167))
        quad(head, NSPoint(x: 100, y: 176), NSPoint(x: 90, y: 167))
        head.line(to: NSPoint(x: 40, y: 118))
        quad(head, NSPoint(x: 31, y: 108), NSPoint(x: 32, y: 96))
        head.close()
        color(0xF26A1B).setFill()
        head.fill()

        // Inner ears, with rounded corners.
        let earColor = color(0xB8450F)
        for points in [[(46, 46), (71, 63), (48, 76)], [(154, 46), (129, 63), (152, 76)]] {
            let ear = NSBezierPath()
            ear.move(to: NSPoint(x: points[0].0, y: points[0].1))
            ear.line(to: NSPoint(x: points[1].0, y: points[1].1))
            ear.line(to: NSPoint(x: points[2].0, y: points[2].1))
            ear.close()
            ear.lineWidth = 6
            ear.lineJoinStyle = .round
            earColor.set()
            ear.fill()
            ear.stroke()
        }

        // The four-pointed spark on the forehead.
        let spark = NSBezierPath()
        spark.move(to: NSPoint(x: 100, y: 70))
        quad(spark, NSPoint(x: 103, y: 85), NSPoint(x: 117, y: 88))
        quad(spark, NSPoint(x: 103, y: 91), NSPoint(x: 100, y: 106))
        quad(spark, NSPoint(x: 97, y: 91), NSPoint(x: 83, y: 88))
        quad(spark, NSPoint(x: 97, y: 85), NSPoint(x: 100, y: 70))
        spark.close()
        color(0xFFF4E8).setFill()
        spark.fill()

        let ink = color(0x1F1A17)
        ink.setFill()
        for (x, angle) in [(70.0, 24.0), (130.0, -24.0)] {
            NSGraphicsContext.saveGraphicsState()
            let eye = NSAffineTransform()
            eye.translateX(by: x, yBy: 112)
            eye.rotate(byDegrees: angle)
            eye.concat()
            NSBezierPath(ovalIn: NSRect(x: -9, y: -4.5, width: 18, height: 9)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let nose = NSBezierPath()
        nose.move(to: NSPoint(x: 90, y: 150))
        nose.line(to: NSPoint(x: 110, y: 150))
        quad(nose, NSPoint(x: 112, y: 152), NSPoint(x: 110, y: 155))
        nose.line(to: NSPoint(x: 102, y: 164))
        quad(nose, NSPoint(x: 100, y: 166), NSPoint(x: 98, y: 164))
        nose.line(to: NSPoint(x: 90, y: 155))
        quad(nose, NSPoint(x: 88, y: 152), NSPoint(x: 90, y: 150))
        nose.close()
        nose.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawDatabaseBadge() {
        color(0x1F1A17).setFill()
        NSBezierPath(ovalIn: NSRect(x: 752 - 132, y: 752 - 132, width: 264, height: 264)).fill()
        color(0x2E2621).setFill()
        NSBezierPath(ovalIn: NSRect(x: 752 - 112, y: 752 - 112, width: 224, height: 224)).fill()

        let strokes = NSBezierPath(ovalIn: NSRect(x: 752 - 58, y: 700 - 20, width: 116, height: 40))
        strokes.move(to: NSPoint(x: 694, y: 700))
        strokes.line(to: NSPoint(x: 694, y: 804))
        quad(strokes, NSPoint(x: 752, y: 828), NSPoint(x: 810, y: 804))
        strokes.line(to: NSPoint(x: 810, y: 700))
        strokes.move(to: NSPoint(x: 694, y: 752))
        quad(strokes, NSPoint(x: 752, y: 776), NSPoint(x: 810, y: 752))
        strokes.lineWidth = 16
        strokes.lineCapStyle = .round
        strokes.lineJoinStyle = .round
        color(0xFFE7D4).setStroke()
        strokes.stroke()
    }

    /// A quadratic Bézier segment, written as the equivalent cubic one.
    private static func quad(_ path: NSBezierPath, _ control: NSPoint, _ end: NSPoint) {
        let start = path.currentPoint
        let c1 = NSPoint(x: start.x + 2 / 3 * (control.x - start.x), y: start.y + 2 / 3 * (control.y - start.y))
        let c2 = NSPoint(x: end.x + 2 / 3 * (control.x - end.x), y: end.y + 2 / 3 * (control.y - end.y))
        path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
    }

    private static func color(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
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

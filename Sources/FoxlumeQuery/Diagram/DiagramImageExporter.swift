import AppKit
import UniformTypeIdentifiers

/// What a diagram canvas offers for export: its natural size and a way to draw itself, at scale 1, into the current
/// (flipped) graphics context, without selection or search highlights.
@MainActor
protocol DiagramExportable: AnyObject {
    var exportSize: CGSize { get }
    var exportBackground: NSColor { get }
    func drawForExport(in rect: CGRect)
}

/// Renders a diagram at its natural size, whatever the zoom and scroll, in the appearance the window shows: PNG at
/// twice the pixels (fewer for a drawing so large the bitmap would not fit), PDF as vectors, or an image on the
/// pasteboard.
@MainActor
enum DiagramImageExporter {
    static let preferredScale: CGFloat = 2
    /// Longest side and pixel count a PNG may have; a 200-table schema still exports, at a lower scale.
    static let maximumSide: CGFloat = 16_384
    static let maximumPixels: CGFloat = 160_000_000

    static func scale(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return preferredScale }
        let bySide = maximumSide / max(size.width, size.height)
        let byArea = (maximumPixels / (size.width * size.height)).squareRoot()
        return max(0.05, min(preferredScale, bySide, byArea))
    }

    static func bitmap(of diagram: DiagramExportable, appearance: NSAppearance) -> NSBitmapImageRep? {
        let size = diagram.exportSize
        guard size.width >= 1, size.height >= 1 else { return nil }
        let scale = scale(for: size)
        let pixelsWide = Int((size.width * scale).rounded(.up))
        let pixelsHigh = Int((size.height * scale).rounded(.up))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = size
        let cg = context.cgContext
        cg.translateBy(x: 0, y: CGFloat(pixelsHigh))
        cg.scaleBy(x: scale, y: -scale)
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        draw(diagram, size: size, appearance: appearance, in: flipped)
        return rep
    }

    static func pngData(of diagram: DiagramExportable, appearance: NSAppearance) -> Data? {
        bitmap(of: diagram, appearance: appearance)?.representation(using: .png, properties: [:])
    }

    static func pdfData(of diagram: DiagramExportable, appearance: NSAppearance) -> Data? {
        let size = diagram.exportSize
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard size.width >= 1, size.height >= 1,
              let consumer = CGDataConsumer(data: data as CFMutableData),
              let cg = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return nil }
        cg.beginPDFPage(nil)
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        draw(diagram, size: size, appearance: appearance, in: NSGraphicsContext(cgContext: cg, flipped: true))
        cg.endPDFPage()
        cg.closePDF()
        return data as Data
    }

    private static func draw(_ diagram: DiagramExportable, size: CGSize, appearance: NSAppearance, in context: NSGraphicsContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            let rect = CGRect(origin: .zero, size: size)
            diagram.exportBackground.setFill()
            rect.fill()
            diagram.drawForExport(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Puts the diagram on the pasteboard as PNG and TIFF, so it pastes into documents, chats and image editors.
    @discardableResult
    static func copy(_ diagram: DiagramExportable, appearance: NSAppearance) -> Bool {
        guard let rep = bitmap(of: diagram, appearance: appearance), let png = rep.representation(using: .png, properties: [:]) else {
            NSSound.beep()
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        return true
    }

    enum Format {
        case png
        case pdf

        var type: UTType { self == .png ? .png : .pdf }
        var fileExtension: String { self == .png ? "png" : "pdf" }
    }

    /// Asks where to save, then writes the file; failures are reported in the window.
    static func save(_ diagram: DiagramExportable, format: Format, suggestedName: String, appearance: NSAppearance, in window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = suggestedName + "." + format.fileExtension
        panel.message = format == .png ? "Save the diagram as a PNG image." : "Save the diagram as a PDF document."
        let write: (URL) -> Void = { url in
            let data = format == .png ? pngData(of: diagram, appearance: appearance) : pdfData(of: diagram, appearance: appearance)
            do {
                guard let data else { throw DiagramExportError.renderFailed }
                try data.write(to: url, options: .atomic)
            } catch {
                Alerts.showError(error, title: "Could not export the diagram", in: window)
            }
        }
        if let window {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                write(url)
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            write(url)
        }
    }

    /// The file names an export suggests: `er-diagram-public`, `query-plan`.
    static func fileName(_ base: String, _ qualifier: String?) -> String {
        let cleaned = qualifier.map { $0.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") }
        return [base, cleaned].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "-")
    }
}

enum DiagramExportError: LocalizedError {
    case renderFailed

    var errorDescription: String? { "The diagram could not be drawn as an image." }
}

import AppKit
import FoxlumeQueryCore
import ImageIO
import PDFKit

/// Preview of a binary value whose bytes are an image or a PDF, scaled down to fit (never up past its own size).
@MainActor
final class ImagePreviewView: NSView {
    let format: ImageFormat
    let byteCount: Int
    private let imageView = NSImageView()
    private let messageLabel = UI.label("", size: 12, color: .secondaryLabelColor)
    /// Pixel size of a bitmap, or the first page's size in points for a PDF; nil when the bytes do not decode.
    private(set) var pixelSize: CGSize?
    private(set) var pageCount: Int?

    init(data: Data, format: ImageFormat) {
        self.format = format
        byteCount = data.count
        super.init(frame: .zero)
        setAccessibilityIdentifier("imagePreview")
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.imageFrameStyle = .none
        imageView.setAccessibilityIdentifier("imagePreviewImage")
        messageLabel.isHidden = true
        for view in [imageView, messageLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.init(1), for: .horizontal)
        imageView.setContentHuggingPriority(.init(1), for: .vertical)
        load(data)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    private func load(_ data: Data) {
        if format == .pdf, let document = PDFDocument(data: data), let page = document.page(at: 0) {
            pageCount = document.pageCount
            pixelSize = page.bounds(for: .mediaBox).size
        } else if let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            pixelSize = CGSize(width: width, height: height)
        }
        if pixelSize != nil, let image = NSImage(data: data) {
            imageView.image = image
        } else {
            pixelSize = nil
            messageLabel.stringValue = "The \(format.displayName) data cannot be shown."
            messageLabel.isHidden = false
        }
    }

    /// `PNG · 64 × 48 px · 1,234 bytes`, or the page size and count for a PDF.
    var summary: String {
        var parts = [format.displayName]
        if let size = pixelSize {
            if format == .pdf {
                parts.append("\(Int(size.width.rounded())) × \(Int(size.height.rounded())) pt")
                if let pageCount { parts.append(pageCount == 1 ? "1 page" : "\(pageCount.groupedText) pages") }
            } else {
                parts.append("\(Int(size.width)) × \(Int(size.height)) px")
            }
        }
        parts.append(byteCount == 1 ? "1 byte" : "\(byteCount.groupedText) bytes")
        return parts.joined(separator: " · ")
    }

    var isDecoded: Bool { imageView.image != nil }
}

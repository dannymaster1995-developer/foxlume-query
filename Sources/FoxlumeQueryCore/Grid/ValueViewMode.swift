import Foundation

/// The ways the value viewer can show one cell.
public enum ValueViewMode: String, CaseIterable, Sendable {
    case text, json, image, hex

    public var title: String {
        switch self {
        case .text: return "Text"
        case .json: return "JSON"
        case .image: return "Image"
        case .hex: return "Hex"
        }
    }

    /// Binary values larger than this offer no Text mode: their hex literal would be too long for a text view.
    public static let textModeByteLimit = 1 << 20

    /// The modes a value offers, in segment order, and the one it opens in. Chosen by content: JSON for text that is
    /// a JSON object or array, Image for bytes with an image signature, Hex for any binary value and for text.
    public static func modes(for value: CellValue, typeName: String) -> (modes: [ValueViewMode], initial: ValueViewMode) {
        modes(for: value, binary: BinaryValue.data(of: value, typeName: typeName))
    }

    /// The same, for a caller that already has the value's bytes (`BinaryValue.data`).
    public static func modes(for value: CellValue, binary: Data?) -> (modes: [ValueViewMode], initial: ValueViewMode) {
        switch value {
        case .null, .missing, .expression:
            return ([.text], .text)
        case .bytes, .text:
            break
        }
        if let data = binary {
            let image = ImageFormat.detect(data) != nil
            var modes: [ValueViewMode] = data.count <= textModeByteLimit ? [.text] : []
            if image { modes.append(.image) }
            modes.append(.hex)
            return (modes, image ? .image : .hex)
        }
        guard case .text(let text) = value else { return ([.text], .text) }
        if mayBeJSON(text), JSONTreeDocument.isTree(text) {
            return ([.text, .json, .hex], .json)
        }
        return ([.text, .hex], .text)
    }

    /// A cheap first check: the first non-blank character opens an object or an array.
    public static func mayBeJSON(_ text: String) -> Bool {
        guard let first = text.utf8.first(where: { $0 != 0x20 && $0 != 0x0a && $0 != 0x0d && $0 != 0x09 }) else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }
}

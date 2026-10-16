import Foundation

/// Image and document formats the value viewer previews, recognised by their first bytes (never by column name).
public enum ImageFormat: String, CaseIterable, Sendable {
    case png, jpeg, gif, webp, heic, tiff, bmp, pdf

    public var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .gif: return "GIF"
        case .webp: return "WebP"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .bmp: return "BMP"
        case .pdf: return "PDF"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        default: return rawValue
        }
    }

    /// HEIF brands written by cameras and image tools (`ftyp` box at offset 4).
    private static let heifBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"]
    /// Sizes of the BMP info headers (core, v1 to v5), at offset 14.
    private static let bmpHeaderSizes: Set<UInt32> = [12, 40, 52, 56, 64, 108, 124]

    /// The format whose signature `data` starts with, or nil.
    public static func detect(_ data: Data) -> ImageFormat? {
        let head = [UInt8](data.prefix(32))
        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + signature.count && Array(head[offset..<offset + signature.count]) == signature
        }
        func ascii(_ text: String, at offset: Int = 0) -> Bool { starts(Array(text.utf8), at: offset) }

        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if ascii("GIF87a") || ascii("GIF89a") { return .gif }
        if ascii("RIFF"), ascii("WEBP", at: 8) { return .webp }
        if ascii("ftyp", at: 4), head.count >= 12, heifBrands.contains(String(decoding: head[8..<12], as: UTF8.self)) { return .heic }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if ascii("%PDF-") { return .pdf }
        if ascii("BM"), head.count >= 18 {
            let infoSize = UInt32(head[14]) | UInt32(head[15]) << 8 | UInt32(head[16]) << 16 | UInt32(head[17]) << 24
            if bmpHeaderSizes.contains(infoSize) { return .bmp }
        }
        return nil
    }
}

public enum BinaryValue {
    /// The bytes of a binary cell: raw bytes, or the `\x…` hex text PostgreSQL sends for a `bytea` column. Nil for
    /// anything else, text in other columns included.
    public static func data(of value: CellValue, typeName: String) -> Data? {
        switch value {
        case .bytes(let data):
            return data
        case .text(let text) where typeName.lowercased() == "bytea":
            return postgresHex(text)
        default:
            return nil
        }
    }

    /// Decodes PostgreSQL's hex output format, `\x` followed by two hex digits per byte.
    public static func postgresHex(_ text: String) -> Data? {
        var text = text
        // One pass over contiguous UTF-8 with a lookup table: a 10 MB bytea arrives as 20 MB of text.
        return text.withUTF8 { utf8 -> Data? in
            guard utf8.count >= 2, utf8.count % 2 == 0, utf8[0] == UInt8(ascii: "\\"), utf8[1] == UInt8(ascii: "x") else { return nil }
            let count = (utf8.count - 2) / 2
            var data = Data(count: count)
            let valid = nibbles.withUnsafeBufferPointer { table in
                data.withUnsafeMutableBytes { raw -> Bool in
                    guard let output = raw.baseAddress?.assumingMemoryBound(to: UInt8.self), let input = utf8.baseAddress else { return count == 0 }
                    guard let lookup = table.baseAddress else { return false }
                    // A plain while loop over pointers stays fast in debug builds too.
                    var source = input + 2
                    var target = output
                    let end = output + count
                    var invalid: UInt8 = 0
                    while target < end {
                        let high = lookup[Int(source.pointee)]
                        let low = lookup[Int(source.successor().pointee)]
                        invalid |= high | low
                        target.pointee = high &<< 4 | low
                        target = target.successor()
                        source = source.advanced(by: 2)
                    }
                    return invalid <= 0x0f
                }
            }
            return valid ? data : nil
        }
    }

    /// Hex digit values by byte; 0xff for anything that is not a hex digit.
    private static let nibbles: [UInt8] = (0...255).map { hexNibble(UInt8($0)) ?? 0xff }

    private static func hexNibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return character - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

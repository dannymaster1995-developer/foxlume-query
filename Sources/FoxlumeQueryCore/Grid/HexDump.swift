import Foundation

/// Classic hex dump lines for the value viewer: `offset | hex bytes | ASCII`, 16 bytes per line, with an extra space
/// after the eighth byte. Lines are formatted on demand, so a viewer only formats the lines it shows.
public enum HexDump {
    public static let bytesPerLine = 16
    /// Characters of a full line's hex column: two digits per byte, a space between bytes, two in the middle.
    public static let hexColumnWidth = bytesPerLine * 3

    public struct Line: Equatable, Sendable {
        public var offset: String
        public var hex: String
        public var ascii: String
    }

    public static func lineCount(byteCount: Int) -> Int {
        (byteCount + bytesPerLine - 1) / bytesPerLine
    }

    /// Hex digits of the offset column: 8, or more for values of 4 GB and over.
    public static func offsetDigits(byteCount: Int) -> Int {
        max(8, String(max(byteCount - 1, 0), radix: 16).count)
    }

    /// Line `index` of `data`; the last line is shorter when the length is not a multiple of 16.
    public static func line(_ index: Int, of data: Data, offsetDigits: Int = 8) -> Line {
        let start = index * bytesPerLine
        let end = min(start + bytesPerLine, data.count)
        let digits = Array("0123456789abcdef".utf8)
        var hex = [UInt8]()
        var ascii = [UInt8]()
        hex.reserveCapacity(hexColumnWidth)
        if start < end {
            let base = data.startIndex
            for position in start..<end {
                let byte = data[base + position]
                let inLine = position - start
                if inLine > 0 { hex.append(UInt8(ascii: " ")) }
                if inLine == bytesPerLine / 2 { hex.append(UInt8(ascii: " ")) }
                hex.append(digits[Int(byte >> 4)])
                hex.append(digits[Int(byte & 0x0f)])
                ascii.append((0x20...0x7e).contains(byte) ? byte : UInt8(ascii: "."))
            }
        }
        var offset = String(start, radix: 16)
        if offset.count < offsetDigits { offset = String(repeating: "0", count: offsetDigits - offset.count) + offset }
        return Line(offset: offset, hex: String(decoding: hex, as: UTF8.self), ascii: String(decoding: ascii, as: UTF8.self))
    }

    /// The character column where the byte at `position` (0 to 15) of a line starts in its hex text.
    public static func hexColumn(ofByte position: Int) -> Int {
        position * 3 + (position >= bytesPerLine / 2 ? 1 : 0)
    }

    /// The byte (0 to 15) under character column `column` of the hex text; a space belongs to the byte before it.
    public static func byte(atHexColumn column: Int) -> Int {
        guard column > 0 else { return 0 }
        let half = bytesPerLine / 2
        if column >= hexColumn(ofByte: half) { return min((column - 1) / 3, bytesPerLine - 1) }
        return min(column / 3, half - 1)
    }

    /// `range` of `data` as continuous lowercase hex digits, as a selection is copied.
    public static func hexString(of data: Data, range: Range<Int>) -> String {
        let clamped = range.clamped(to: 0..<data.count)
        return data[(data.startIndex + clamped.lowerBound)..<(data.startIndex + clamped.upperBound)].hexString
    }
}

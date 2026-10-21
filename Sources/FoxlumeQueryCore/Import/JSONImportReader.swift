import Foundation

/// Reads JSON for import: an array of objects, or objects one after another (NDJSON, as the app exports it,
/// or pretty-printed objects in a row). The file is streamed one object at a time, so its size does not matter.
///
/// Keys are the source fields: each record has one field per key, in the order the keys were first seen.
/// Strings are quoted fields, numbers keep their exact text, `true` and `false` become those words, `null`
/// and missing keys are NULL, and nested objects and arrays are compact JSON text.
public final class JSONImportReader: ImportRecordReader {
    public enum Layout: Equatable, Sendable {
        case array
        case objects
    }

    /// Nesting deeper than this is refused rather than risking the stack.
    static let maxDepth = 512
    static let maxStringBytes = 64 << 20

    private let source: TextChunkSource
    public private(set) var keys: [String]
    private var keyIndex: [String: Int]
    private var chunk: [UInt8] = []
    private var position = 0
    private var line = 1
    private var exhausted = false
    public private(set) var layout: Layout?
    private var finished = false
    private var expectsMore = false

    public var bytesRead: Int64 { source.bytesRead }
    public var totalBytes: Int64 { source.totalBytes }

    /// `keys` fixes the first fields' positions (from the preview), so the column mapping stays valid.
    public init(url: URL, keys: [String] = [], encoding: ImportTextEncoding = .automatic, chunkSize: Int = 1 << 16) throws {
        source = try TextChunkSource(url: url, encoding: encoding, chunkSize: chunkSize)
        self.keys = keys
        keyIndex = Dictionary(keys.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    public func snippet(_ record: CSVRecord) -> String {
        let pairs = record.fields.enumerated().compactMap { index, field -> String? in
            guard !field.isNull, index < keys.count else { return nil }
            return "\(keys[index]): \(field.text)"
        }
        return TransferText.snippet("{" + pairs.joined(separator: ", ") + "}")
    }

    // MARK: Bytes

    private func peek() throws -> UInt8? {
        while position >= chunk.count {
            guard !exhausted, let more = try source.next() else {
                exhausted = true
                return nil
            }
            chunk = more
            position = 0
        }
        return chunk[position]
    }

    private func advance() {
        if chunk[position] == 0x0A { line += 1 }
        position += 1
    }

    private func take() throws -> UInt8? {
        guard let byte = try peek() else { return nil }
        advance()
        return byte
    }

    private func skipWhitespace() throws {
        while let byte = try peek(), byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
            advance()
        }
    }

    private func fail(_ message: String) -> DatabaseError {
        DatabaseError.unsupported("Line \(line): \(message)")
    }

    private func expect(_ byte: UInt8, _ what: String) throws {
        guard try take() == byte else { throw fail("expected \(what).") }
    }

    // MARK: Records

    public func next() throws -> CSVRecord? {
        guard !finished else { return nil }
        try skipWhitespace()
        if layout == nil {
            switch try peek() {
            case 0x5B?:
                layout = .array
                advance()
                try skipWhitespace()
                if try peek() == 0x5D {
                    advance()
                    try finishDocument()
                    return nil
                }
            case 0x7B?:
                layout = .objects
            case nil:
                finished = true
                return nil
            default:
                throw fail("the file is not a JSON array of objects or one JSON object per line.")
            }
        }
        if layout == .objects, try peek() == nil {
            finished = true
            return nil
        }
        guard try peek() == 0x7B else {
            throw fail(layout == .array ? "every item of the array must be an object." : "expected a JSON object.")
        }
        let startLine = line
        let fields = try parseObject()
        if layout == .array {
            try skipWhitespace()
            switch try take() {
            case 0x2C?:
                try skipWhitespace()
            case 0x5D?:
                try finishDocument()
            default:
                throw fail("expected , or ] after an object of the array.")
            }
        }
        return CSVRecord(fields: fields, line: startLine)
    }

    /// Only whitespace may follow the closing bracket of the array.
    private func finishDocument() throws {
        finished = true
        try skipWhitespace()
        if try peek() != nil { throw fail("unexpected text after the end of the array.") }
    }

    private func parseObject() throws -> [CSVField] {
        try expect(0x7B, "{")
        var fields = Array(repeating: CSVField.null, count: keys.count)
        try skipWhitespace()
        if try peek() == 0x7D {
            advance()
            return fields
        }
        while true {
            try skipWhitespace()
            guard try peek() == 0x22 else { throw fail("expected a key in double quotes.") }
            let key = try parseString()
            try skipWhitespace()
            try expect(0x3A, ": after a key")
            try skipWhitespace()
            let value = try parseMember()
            let index: Int
            if let known = keyIndex[key] {
                index = known
            } else {
                index = keys.count
                keys.append(key)
                keyIndex[key] = index
            }
            if index >= fields.count { fields.append(contentsOf: Array(repeating: CSVField.null, count: index - fields.count + 1)) }
            fields[index] = value
            try skipWhitespace()
            switch try take() {
            case 0x2C?: continue
            case 0x7D?: return fields
            default: throw fail("expected , or } in an object.")
            }
        }
    }

    private func parseMember() throws -> CSVField {
        guard let byte = try peek() else { throw fail("the file ends inside an object.") }
        switch byte {
        case 0x22:
            return CSVField(try parseString(), quoted: true)
        case 0x7B, 0x5B:
            var text: [UInt8] = []
            try copyComposite(into: &text)
            return CSVField(String(decoding: text, as: UTF8.self), quoted: true)
        case 0x74:
            try word("true")
            return CSVField("true")
        case 0x66:
            try word("false")
            return CSVField("false")
        case 0x6E:
            try word("null")
            return .null
        case 0x2D, 0x30...0x39:
            return CSVField(try parseNumber())
        default:
            throw fail("unexpected character in a value.")
        }
    }

    private func word(_ text: String) throws {
        for expected in text.utf8 {
            guard try take() == expected else { throw fail("expected \(text).") }
        }
    }

    private func parseNumber() throws -> String {
        var bytes: [UInt8] = []
        while let byte = try peek(), byte == 0x2D || byte == 0x2B || byte == 0x2E || byte == 0x45 || byte == 0x65 || (0x30...0x39).contains(byte) {
            bytes.append(byte)
            advance()
        }
        let text = String(decoding: bytes, as: UTF8.self)
        guard ResultExporter.isJSONNumber(text) else { throw fail("\(text) is not a valid number.") }
        return text
    }

    /// A string value with its escapes decoded. Raw runs go through the file's encoding.
    private func parseString() throws -> String {
        try expect(0x22, "\"")
        var result = ""
        var raw: [UInt8] = []
        var total = 0
        func flushRaw() throws {
            guard !raw.isEmpty else { return }
            guard let text = source.decode(raw[...]) else { throw fail("the text is not valid \(source.encoding.title).") }
            result += text
            raw.removeAll(keepingCapacity: true)
        }
        var pendingHigh: UInt32?
        while true {
            guard let byte = try take() else { throw fail("a string is never closed.") }
            total += 1
            if total > Self.maxStringBytes { throw fail("a string is larger than 64 MB.") }
            if byte == 0x22 { break }
            if byte != 0x5C {
                if let high = pendingHigh {
                    result.unicodeScalars.append(Unicode.Scalar(high) ?? "\u{FFFD}")
                    pendingHigh = nil
                }
                raw.append(byte)
                continue
            }
            try flushRaw()
            guard let escape = try take() else { throw fail("a string is never closed.") }
            var scalar: UInt32?
            switch escape {
            case 0x22: scalar = 0x22
            case 0x5C: scalar = 0x5C
            case 0x2F: scalar = 0x2F
            case 0x62: scalar = 0x08
            case 0x66: scalar = 0x0C
            case 0x6E: scalar = 0x0A
            case 0x72: scalar = 0x0D
            case 0x74: scalar = 0x09
            case 0x75:
                var value: UInt32 = 0
                for _ in 0..<4 {
                    guard let digit = try take(), let nibble = Self.hexValue(digit) else { throw fail("bad \\u escape in a string.") }
                    value = value << 4 | nibble
                }
                if (0xD800...0xDBFF).contains(value) {
                    if pendingHigh != nil { result += "\u{FFFD}" }
                    pendingHigh = value
                    continue
                }
                if (0xDC00...0xDFFF).contains(value) {
                    if let high = pendingHigh {
                        pendingHigh = nil
                        scalar = 0x10000 + ((high - 0xD800) << 10) + (value - 0xDC00)
                    } else {
                        scalar = 0xFFFD
                    }
                } else {
                    scalar = value
                }
            default:
                throw fail("bad escape in a string.")
            }
            if pendingHigh != nil {
                result += "\u{FFFD}"
                pendingHigh = nil
            }
            if let scalar, let decoded = Unicode.Scalar(scalar) { result.unicodeScalars.append(decoded) }
        }
        if pendingHigh != nil { result += "\u{FFFD}" }
        try flushRaw()
        return result
    }

    private static func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30...0x39: return UInt32(byte - 0x30)
        case 0x41...0x46: return UInt32(byte - 0x41 + 10)
        case 0x61...0x66: return UInt32(byte - 0x61 + 10)
        default: return nil
        }
    }

    /// Copies a nested object or array as compact JSON: whitespace outside strings is dropped.
    private func copyComposite(into out: inout [UInt8]) throws {
        var stack: [UInt8] = []
        var inString = false
        var escaped = false
        repeat {
            guard let byte = try take() else { throw fail("the file ends inside a nested value.") }
            if out.count > Self.maxStringBytes { throw fail("a nested value is larger than 64 MB.") }
            if inString {
                out.append(byte)
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }
            switch byte {
            case 0x20, 0x0A, 0x0D, 0x09:
                continue
            case 0x22:
                inString = true
            case 0x7B, 0x5B:
                stack.append(byte == 0x7B ? 0x7D : 0x5D)
                if stack.count > Self.maxDepth { throw fail("values are nested too deeply.") }
            case 0x7D, 0x5D:
                guard stack.last == byte else { throw fail("brackets do not match in a nested value.") }
                stack.removeLast()
            default:
                break
            }
            out.append(byte)
        } while !stack.isEmpty
        // Single-byte encodings pass bytes through; nested text must end up as UTF-8.
        if source.encoding != .utf8, source.encoding != .automatic, !source.encoding.isUTF16, let text = source.decode(out[...]) {
            out = Array(text.utf8)
        }
    }

    // MARK: Preview

    /// The keys found in the first `scan` objects and the first `limit` records, padded to every key.
    public static func preview(url: URL, limit: Int, scan: Int = 1000) throws -> (keys: [String], records: [CSVRecord], layout: Layout) {
        let reader = try JSONImportReader(url: url)
        var records: [CSVRecord] = []
        var count = 0
        while count < max(limit, scan), let record = try reader.next() {
            if records.count < limit { records.append(record) }
            count += 1
        }
        let width = reader.keys.count
        records = records.map { record in
            var padded = record
            if padded.fields.count < width { padded.fields += Array(repeating: CSVField.null, count: width - padded.fields.count) }
            return padded
        }
        if count == 1, reader.layout == .objects, let only = records.first, !only.fields.isEmpty,
           only.fields.allSatisfy({ $0.wasQuoted && ($0.text.hasPrefix("[{") || $0.text == "[]") }), reader.finished {
            throw DatabaseError.unsupported("This file holds several tables (an export of several tables to one JSON file). Import a file with one table: an array of objects, or one object per line.")
        }
        return (reader.keys, records, reader.layout ?? .array)
    }
}

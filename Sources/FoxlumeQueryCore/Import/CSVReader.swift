import Foundation

/// One field of a CSV record. `wasQuoted` tells `""` (an empty string) from an empty field (no value).
public struct CSVField: Hashable, Sendable {
    public var text: String
    public var wasQuoted: Bool

    public init(_ text: String, quoted: Bool = false) {
        self.text = text
        self.wasQuoted = quoted
    }
}

/// A CSV record and the line it starts on (1-based, counting physical lines of the file).
public struct CSVRecord: Hashable, Sendable {
    public var fields: [CSVField]
    public var line: Int

    public var texts: [String] { fields.map(\.text) }
}

/// Field separators offered for CSV files.
public enum CSVDelimiter: String, CaseIterable, Sendable, Identifiable, Codable {
    case comma = ","
    case semicolon = ";"
    case tab = "\t"
    case pipe = "|"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .comma: return "Comma"
        case .semicolon: return "Semicolon"
        case .tab: return "Tab"
        case .pipe: return "Pipe"
        }
    }

    var byte: UInt8 { UInt8(ascii: rawValue.unicodeScalars.first ?? ",") }
}

/// Streaming RFC 4180 parser. Records may span lines inside quotes; CR, LF and CRLF all end a record.
/// The parser is lenient where real files are sloppy: a quote inside an unquoted field is kept as text,
/// and text after a closing quote is appended to the field.
public final class CSVReader {
    /// A single field larger than this almost always means a stray quote swallowed the rest of the file.
    static let maxFieldBytes = 64 << 20

    private let source: TextChunkSource
    private let delimiter: UInt8
    private var chunk: [UInt8] = []
    private var position = 0
    private var line = 1
    private var skipLineFeed = false
    private var atEnd = false

    public var encoding: ImportTextEncoding { source.encoding }
    public var bytesRead: Int64 { source.bytesRead }
    public var totalBytes: Int64 { source.totalBytes }

    public init(url: URL, delimiter: CSVDelimiter, encoding: ImportTextEncoding = .automatic, chunkSize: Int = 1 << 16) throws {
        self.source = try TextChunkSource(url: url, encoding: encoding, chunkSize: chunkSize)
        self.delimiter = delimiter.byte
    }

    private enum State {
        case fieldStart
        case unquoted
        case quoted
        case quoteInQuoted
    }

    /// The next record, or nil at the end of the file. Blank lines are skipped.
    public func next() throws -> CSVRecord? {
        while true {
            guard let record = try readRecord() else { return nil }
            if record.fields.count == 1, record.fields[0].text.isEmpty, !record.fields[0].wasQuoted { continue }
            return record
        }
    }

    private func nextByte() throws -> UInt8? {
        if position >= chunk.count {
            guard !atEnd, let more = try source.next() else {
                atEnd = true
                return nil
            }
            chunk = more
            position = 0
            if chunk.isEmpty { return try nextByte() }
        }
        defer { position += 1 }
        return chunk[position]
    }

    private func readRecord() throws -> CSVRecord? {
        var fields: [CSVField] = []
        var field: [UInt8] = []
        var quoted = false
        var state = State.fieldStart
        let startLine = line
        var sawAnything = false

        func finishField() throws {
            guard let text = source.decode(field[...]) else {
                throw DatabaseError.unsupported("Line \(line) is not valid \(source.encoding.title) text. Choose another encoding.")
            }
            fields.append(CSVField(text, quoted: quoted))
            field.removeAll(keepingCapacity: true)
            quoted = false
        }

        while let byte = try nextByte() {
            if skipLineFeed {
                skipLineFeed = false
                if byte == 0x0A { continue }
            }
            sawAnything = true
            if field.count > Self.maxFieldBytes {
                throw DatabaseError.unsupported("A field starting on line \(startLine) is larger than 64 MB. Check the quote character and delimiter.")
            }
            switch state {
            case .fieldStart:
                if byte == 0x22 {
                    quoted = true
                    state = .quoted
                } else if byte == delimiter {
                    try finishField()
                } else if byte == 0x0D || byte == 0x0A {
                    try endOfLine(byte)
                    try finishField()
                    return CSVRecord(fields: fields, line: startLine)
                } else {
                    field.append(byte)
                    state = .unquoted
                }
            case .unquoted:
                if byte == delimiter {
                    try finishField()
                    state = .fieldStart
                } else if byte == 0x0D || byte == 0x0A {
                    try endOfLine(byte)
                    try finishField()
                    return CSVRecord(fields: fields, line: startLine)
                } else {
                    field.append(byte)
                }
            case .quoted:
                if byte == 0x22 {
                    state = .quoteInQuoted
                } else {
                    countLineBreak(byte)
                    field.append(byte)
                }
            case .quoteInQuoted:
                if byte == 0x22 {
                    field.append(0x22)
                    state = .quoted
                } else if byte == delimiter {
                    try finishField()
                    state = .fieldStart
                } else if byte == 0x0D || byte == 0x0A {
                    try endOfLine(byte)
                    try finishField()
                    return CSVRecord(fields: fields, line: startLine)
                } else {
                    field.append(byte)
                    state = .unquoted
                }
            }
        }
        guard sawAnything else { return nil }
        if state == .quoted {
            throw DatabaseError.unsupported("The quoted field starting on line \(startLine) is never closed.")
        }
        try finishField()
        return CSVRecord(fields: fields, line: startLine)
    }

    /// A CR or LF that ends a record. CRLF counts once.
    private func endOfLine(_ byte: UInt8) throws {
        line += 1
        if byte == 0x0D { skipLineFeed = true }
    }

    /// Line breaks inside quoted fields still advance the physical line count used in messages; CRLF counts once.
    private var previousWasCR = false
    private func countLineBreak(_ byte: UInt8) {
        if byte == 0x0D {
            line += 1
        } else if byte == 0x0A, !previousWasCR {
            line += 1
        }
        previousWasCR = byte == 0x0D
    }
}

public extension CSVReader {
    /// Picks the delimiter whose count per line is the most consistent over the first lines of `sample`.
    /// Quoted text is ignored, so commas inside quoted values do not vote.
    static func detectDelimiter(in sample: String) -> CSVDelimiter {
        var best = CSVDelimiter.comma
        var bestScore = 0
        for candidate in CSVDelimiter.allCases {
            let counts = countsPerLine(sample, delimiter: Character(candidate.rawValue), maxLines: 50)
            guard let first = counts.first, first > 0 else { continue }
            // Lines agreeing with the header line count; more columns break ties.
            let agreeing = counts.filter { $0 == first }.count
            let score = agreeing * 1000 + min(first, 999)
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    private static func countsPerLine(_ sample: String, delimiter: Character, maxLines: Int) -> [Int] {
        var counts: [Int] = []
        var current = 0
        var inQuotes = false
        // Swift treats CRLF as one Character, so each line break is seen once.
        for character in sample {
            if character == "\"" {
                inQuotes.toggle()
            } else if !inQuotes, character == delimiter {
                current += 1
            } else if !inQuotes, character == "\n" || character == "\r" || character == "\r\n" {
                counts.append(current)
                current = 0
                if counts.count >= maxLines { return counts }
            }
        }
        if current > 0 { counts.append(current) }
        return counts
    }

    /// The first `limit` records of a file, for the import preview and the detected settings.
    static func preview(url: URL, delimiter: CSVDelimiter?, encoding: ImportTextEncoding, limit: Int) throws -> (records: [CSVRecord], delimiter: CSVDelimiter, encoding: ImportTextEncoding) {
        let source = try TextChunkSource(url: url, encoding: encoding)
        let sampleBytes = (try source.next()) ?? []
        let sampleText = source.decode(sampleBytes[...]) ?? String(decoding: sampleBytes, as: UTF8.self)
        let chosen = delimiter ?? detectDelimiter(in: sampleText)
        let reader = try CSVReader(url: url, delimiter: chosen, encoding: source.encoding)
        var records: [CSVRecord] = []
        while records.count < limit, let record = try reader.next() {
            records.append(record)
        }
        return (records, chosen, source.encoding)
    }
}

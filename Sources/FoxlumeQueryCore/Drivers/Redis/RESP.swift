import Foundation

/// One reply in the Redis serialization protocol, RESP2 or RESP3.
///
/// Bulk strings stay raw bytes so binary values survive; callers decide when to read them as text.
indirect enum RESPValue: Hashable, Sendable {
    /// `+OK`
    case simple(String)
    /// `-ERR message` and the RESP3 blob error `!`.
    case error(String)
    /// `:42`
    case integer(Int64)
    /// `$5\r\nhello`, and the RESP3 verbatim string `=` without its `txt:` prefix.
    case bulk(Data)
    /// `$-1`, `*-1` and the RESP3 `_`.
    case null
    case array([RESPValue])
    /// RESP3 `,3.14`
    case double(Double)
    /// RESP3 `#t`
    case boolean(Bool)
    /// RESP3 `(3492890328409238509324850943850943825024385`
    case bigNumber(String)
    /// RESP3 `%`, kept flat: key, value, key, value. The same shape RESP2 uses for HGETALL and CONFIG GET.
    case map([RESPValue])
    /// RESP3 `~`
    case set([RESPValue])
    /// RESP3 `>`: out-of-band data such as pub/sub messages or tracking invalidations.
    case push([RESPValue])

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .error(let message) = self { return message }
        return nil
    }

    /// The reply as text. Bytes that are not UTF-8 are decoded lossily; use `cell` to keep them.
    var string: String? {
        switch self {
        case .simple(let text), .bigNumber(let text): return text
        case .bulk(let data): return String(decoding: data, as: UTF8.self)
        case .integer(let value): return String(value)
        case .double(let value): return RESPValue.format(value)
        case .boolean(let value): return value ? "true" : "false"
        case .error, .null, .array, .map, .set, .push: return nil
        }
    }

    var data: Data? {
        switch self {
        case .bulk(let data): return data
        case .simple(let text), .bigNumber(let text): return Data(text.utf8)
        default: return string.map { Data($0.utf8) }
        }
    }

    var integer: Int64? {
        switch self {
        case .integer(let value): return value
        case .bulk, .simple, .bigNumber: return string.flatMap { Int64($0) }
        case .double(let value): return value.isFinite ? Int64(exactly: value.rounded()) : nil
        default: return nil
        }
    }

    /// Elements of an aggregate. Maps come back flat (key, value, …), which is what RESP2 sends for the same commands.
    var elements: [RESPValue]? {
        switch self {
        case .array(let items), .set(let items), .push(let items), .map(let items): return items
        default: return nil
        }
    }

    var isAggregate: Bool { elements != nil }

    /// Pairs from a flat list (RESP2 HGETALL), a map (RESP3 HGETALL) or a list of two-element arrays
    /// (RESP3 `ZRANGE … WITHSCORES`, `HRANDFIELD … WITHVALUES`).
    var pairs: [(RESPValue, RESPValue)] {
        guard let items = elements else { return [] }
        if case .map = self { return Self.flatPairs(items) }
        if !items.isEmpty, items.allSatisfy({ $0.elements?.count == 2 && !$0.isMap }) {
            return items.compactMap { item in
                guard let pair = item.elements else { return nil }
                return (pair[0], pair[1])
            }
        }
        return Self.flatPairs(items)
    }

    private var isMap: Bool {
        if case .map = self { return true }
        return false
    }

    private static func flatPairs(_ items: [RESPValue]) -> [(RESPValue, RESPValue)] {
        stride(from: 0, to: items.count - 1, by: 2).map { (items[$0], items[$0 + 1]) }
    }

    /// Map entries keyed by their text, for HELLO and similar replies.
    var dictionary: [String: RESPValue] {
        var result: [String: RESPValue] = [:]
        for (key, value) in pairs {
            if let name = key.string { result[name] = value }
        }
        return result
    }

    /// A grid cell. Bulk strings that are not UTF-8 become `.bytes`; aggregates become JSON text.
    var cell: CellValue {
        switch self {
        case .null: return .null
        case .bulk(let data): return CellValue.decode(data)
        case .error(let message): return .text("(error) " + message)
        case .array, .set, .push, .map: return .text(json)
        default: return .text(string ?? "")
        }
    }

    /// Text for a JSON preview or a cell; bytes that are not UTF-8 render as `0x…`.
    var displayText: String {
        switch self {
        case .bulk(let data): return CellValue.decode(data).textValue ?? ""
        case .null: return "null"
        case .error(let message): return "(error) " + message
        case .array, .set, .push, .map: return json
        default: return string ?? ""
        }
    }

    /// Foundation value for JSONSerialization.
    var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .integer(let value): return NSNumber(value: value)
        case .double(let value): return value.isFinite ? NSNumber(value: value) : RESPValue.format(value) as Any
        case .boolean(let value): return NSNumber(value: value)
        case .array(let items), .set(let items), .push(let items): return items.map(\.jsonObject)
        case .map:
            var object: [String: Any] = [:]
            for (key, value) in pairs { object[key.displayText] = value.jsonObject }
            return object
        default: return displayText
        }
    }

    var json: String {
        RESPValue.encodeJSON(jsonObject) ?? displayText
    }

    static func encodeJSON(_ object: Any) -> String? {
        let wrapped = JSONSerialization.isValidJSONObject(object) ? object : [object]
        guard JSONSerialization.isValidJSONObject(wrapped),
              let data = try? JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if !JSONSerialization.isValidJSONObject(object) {
            // A bare scalar was wrapped to satisfy JSONSerialization; drop the brackets again.
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    /// Scores and other doubles as redis-cli prints them: `1500`, `0.5`, `inf`.
    static func format(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        if value == value.rounded(), abs(value) < 1e17 { return String(Int64(value)) }
        return String(value)
    }
}

/// Encodes commands as RESP arrays of bulk strings, which every server version accepts.
enum RESPEncoder {
    static func command(_ arguments: [Data]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16 + arguments.reduce(0) { $0 + $1.count + 16 })
        bytes.append(UInt8(ascii: "*"))
        bytes.append(contentsOf: Array(String(arguments.count).utf8))
        bytes.append(contentsOf: crlf)
        for argument in arguments {
            bytes.append(UInt8(ascii: "$"))
            bytes.append(contentsOf: Array(String(argument.count).utf8))
            bytes.append(contentsOf: crlf)
            bytes.append(contentsOf: argument)
            bytes.append(contentsOf: crlf)
        }
        return bytes
    }

    static func command(_ arguments: [String]) -> [UInt8] {
        command(arguments.map { Data($0.utf8) })
    }

    static let crlf: [UInt8] = [0x0D, 0x0A]
}

/// A byte stream a RESP reader can pull from. `SocketTransport` in production, scripted bytes in tests.
protocol RedisByteChannel: AnyObject {
    func read(exactly count: Int) throws -> [UInt8]
    func write(_ bytes: [UInt8]) throws
}

extension SocketTransport: RedisByteChannel {}

/// Reads one RESP2 or RESP3 value at a time.
struct RESPReader {
    let channel: RedisByteChannel
    /// Deeper nesting than any real reply has; stops a hostile server from overflowing the stack.
    static let maximumDepth = 128

    init(channel: RedisByteChannel) {
        self.channel = channel
    }

    /// The next reply to a command. Push messages and attributes arriving in between are skipped.
    func readReply() throws -> RESPValue {
        while true {
            let value = try read()
            if case .push = value { continue }
            return value
        }
    }

    func read() throws -> RESPValue {
        try read(depth: 0)
    }

    private func read(depth: Int) throws -> RESPValue {
        guard depth < Self.maximumDepth else {
            throw DatabaseError.protocolViolation("Redis reply nested too deeply")
        }
        let type = try channel.read(exactly: 1)[0]
        let line = try readLine()
        switch type {
        case UInt8(ascii: "+"):
            return .simple(String(decoding: line, as: UTF8.self))
        case UInt8(ascii: "-"):
            return .error(String(decoding: line, as: UTF8.self))
        case UInt8(ascii: ":"):
            return .integer(try Self.integer(line))
        case UInt8(ascii: "$"):
            let length = try Self.integer(line)
            if length < 0 { return .null }
            return .bulk(Data(try readBlob(length)))
        case UInt8(ascii: "*"):
            let count = try Self.integer(line)
            if count < 0 { return .null }
            return .array(try readElements(Int(count), depth: depth))
        case UInt8(ascii: "_"):
            return .null
        case UInt8(ascii: ","):
            return .double(try Self.double(line))
        case UInt8(ascii: "#"):
            switch line {
            case [UInt8(ascii: "t")]: return .boolean(true)
            case [UInt8(ascii: "f")]: return .boolean(false)
            default: throw DatabaseError.protocolViolation("Invalid RESP3 boolean")
            }
        case UInt8(ascii: "("):
            return .bigNumber(String(decoding: line, as: UTF8.self))
        case UInt8(ascii: "!"):
            let length = try Self.integer(line)
            return .error(String(decoding: try readBlob(max(0, length)), as: UTF8.self))
        case UInt8(ascii: "="):
            let length = try Self.integer(line)
            let blob = try readBlob(max(0, length))
            // Verbatim strings start with a three-letter format and a colon, for example `txt:`.
            let body = blob.count >= 4 && blob[3] == UInt8(ascii: ":") ? Array(blob[4...]) : blob
            return .bulk(Data(body))
        case UInt8(ascii: "%"):
            let count = try Self.integer(line)
            if count < 0 { return .null }
            return .map(try readElements(Int(count) * 2, depth: depth))
        case UInt8(ascii: "~"):
            let count = try Self.integer(line)
            if count < 0 { return .null }
            return .set(try readElements(Int(count), depth: depth))
        case UInt8(ascii: ">"):
            let count = try Self.integer(line)
            return .push(try readElements(Int(max(0, count)), depth: depth))
        case UInt8(ascii: "|"):
            // Attributes describe the reply that follows; Foxlume Query has no use for them.
            let count = try Self.integer(line)
            _ = try readElements(Int(max(0, count)) * 2, depth: depth)
            return try read(depth: depth)
        default:
            throw DatabaseError.protocolViolation("Unexpected reply byte 0x\(String(type, radix: 16)). Is this a Redis server?")
        }
    }

    private func readElements(_ count: Int, depth: Int) throws -> [RESPValue] {
        guard count <= 1 << 31 else { throw DatabaseError.protocolViolation("Redis reply too large") }
        var items: [RESPValue] = []
        items.reserveCapacity(min(count, 1 << 16))
        for _ in 0..<count {
            items.append(try read(depth: depth + 1))
        }
        return items
    }

    private func readBlob(_ length: Int64) throws -> [UInt8] {
        guard length <= Int64(Int32.max) else { throw DatabaseError.protocolViolation("Redis bulk string too large") }
        let bytes = try channel.read(exactly: Int(length) + 2)
        guard bytes[bytes.count - 2] == 0x0D, bytes[bytes.count - 1] == 0x0A else {
            throw DatabaseError.protocolViolation("Bulk string not terminated by CRLF")
        }
        return Array(bytes.dropLast(2))
    }

    /// Header lines are short (a type byte was already consumed), so reading byte by byte is cheap.
    private func readLine() throws -> [UInt8] {
        var line: [UInt8] = []
        while true {
            let byte = try channel.read(exactly: 1)[0]
            if byte == 0x0D {
                let next = try channel.read(exactly: 1)[0]
                guard next == 0x0A else { throw DatabaseError.protocolViolation("Expected LF after CR. Is this a Redis server?") }
                return line
            }
            line.append(byte)
            if line.count > 64 * 1024 {
                throw DatabaseError.protocolViolation("Reply line too long. Is this a Redis server?")
            }
        }
    }

    private static func integer(_ line: [UInt8]) throws -> Int64 {
        guard let value = Int64(String(decoding: line, as: UTF8.self)) else {
            throw DatabaseError.protocolViolation("Invalid integer in reply. Is this a Redis server?")
        }
        return value
    }

    private static func double(_ line: [UInt8]) throws -> Double {
        let text = String(decoding: line, as: UTF8.self).lowercased()
        switch text {
        case "inf", "+inf": return .infinity
        case "-inf": return -.infinity
        case "nan", "-nan": return .nan
        default:
            guard let value = Double(text) else { throw DatabaseError.protocolViolation("Invalid double in reply") }
            return value
        }
    }
}

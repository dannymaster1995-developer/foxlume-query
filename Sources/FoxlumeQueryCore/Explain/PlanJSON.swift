import Foundation

/// A JSON value that keeps object keys in the order the server wrote them, so a plan node's details read the way
/// the database prints them. Numbers keep their original spelling for display.
public indirect enum PlanJSON: Hashable, Sendable {
    public struct Member: Hashable, Sendable {
        public var key: String
        public var value: PlanJSON
    }

    case object([Member])
    case array([PlanJSON])
    case string(String)
    case number(Double, text: String)
    case bool(Bool)
    case null

    /// Plans nest deeply, but not this deeply; anything beyond is refused rather than overflowing the stack.
    static let maximumDepth = 512

    public static func parse(_ text: String) -> PlanJSON? {
        var reader = Reader(bytes: Array(text.utf8))
        guard let value = try? reader.value(depth: 0) else { return nil }
        reader.skipWhitespace()
        return reader.isAtEnd ? value : nil
    }

    public subscript(key: String) -> PlanJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var members: [Member] {
        if case .object(let members) = self { return members }
        return []
    }

    public var elements: [PlanJSON] {
        if case .array(let elements) = self { return elements }
        return []
    }

    public var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    public var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// Numbers, and numbers MySQL and DuckDB send as strings (`"query_cost": "31.50"`, `"~20000"`).
    public var double: Double? {
        switch self {
        case .number(let value, _):
            return value
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "~"))
            return Double(trimmed)
        default:
            return nil
        }
    }

    public var int: Int? {
        guard let value = double, value.isFinite, value.rounded() == value, abs(value) < 1e15 else { return nil }
        return Int(value)
    }

    public var bool: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    /// The value as one line of text: scalars as written, lists of scalars joined with commas, anything nested as
    /// compact JSON.
    public var displayText: String {
        switch self {
        case .string(let text): return text
        case .number(_, let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .array(let elements) where elements.allSatisfy(\.isScalar):
            return elements.map(\.displayText).joined(separator: ", ")
        case .array, .object:
            return compactText
        }
    }

    public var isScalar: Bool {
        switch self {
        case .object, .array: return false
        default: return true
        }
    }

    public var compactText: String {
        switch self {
        case .string(let text): return Self.quoted(text)
        case .number(_, let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .array(let elements): return "[" + elements.map(\.compactText).joined(separator: ", ") + "]"
        case .object(let members):
            return "{" + members.map { Self.quoted($0.key) + ": " + $0.value.compactText }.joined(separator: ", ") + "}"
        }
    }

    /// Indented JSON, two spaces per level, for replies that arrive on one line.
    public var prettyText: String {
        var out = ""
        writePretty(into: &out, indent: 0)
        return out
    }

    private func writePretty(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent + 1)
        let closing = String(repeating: "  ", count: indent)
        switch self {
        case .object(let members) where !members.isEmpty:
            out += "{\n"
            for (index, member) in members.enumerated() {
                out += pad + Self.quoted(member.key) + ": "
                member.value.writePretty(into: &out, indent: indent + 1)
                out += index == members.count - 1 ? "\n" : ",\n"
            }
            out += closing + "}"
        case .array(let elements) where !elements.isEmpty:
            out += "[\n"
            for (index, element) in elements.enumerated() {
                out += pad
                element.writePretty(into: &out, indent: indent + 1)
                out += index == elements.count - 1 ? "\n" : ",\n"
            }
            out += closing + "]"
        default:
            out += compactText
        }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private struct Reader {
        struct Failure: Error {}

        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        var isAtEnd: Bool { index >= bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> PlanJSON {
            guard depth < PlanJSON.maximumDepth else { throw Failure() }
            skipWhitespace()
            guard index < bytes.count else { throw Failure() }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func object(depth: Int) throws -> PlanJSON {
            index += 1
            var members: [Member] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Failure() }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw Failure() }
                index += 1
                members.append(Member(key: key, value: try value(depth: depth + 1)))
                skipWhitespace()
                guard index < bytes.count else { throw Failure() }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return .object(members)
                } else {
                    throw Failure()
                }
            }
        }

        mutating func array(depth: Int) throws -> PlanJSON {
            index += 1
            var elements: [PlanJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(elements)
            }
            while true {
                elements.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw Failure() }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return .array(elements)
                } else {
                    throw Failure()
                }
            }
        }

        mutating func string() throws -> String {
            index += 1
            var out: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw Failure() }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "u"):
                        var scalar = try hex4()
                        // A surrogate pair spells one character outside the basic plane.
                        if (0xD800...0xDBFF).contains(scalar), index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            let low = try hex4()
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        }
                        out.append(contentsOf: Array(String(Character(Unicode.Scalar(scalar) ?? "\u{FFFD}")).utf8))
                    default:
                        out.append(escape)
                    }
                default:
                    out.append(byte)
                }
            }
            throw Failure()
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                throw Failure()
            }
            index += 4
            return value
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else { throw Failure() }
            index += expected.count
        }

        mutating func number() throws -> PlanJSON {
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard let value = Double(text) else { throw Failure() }
            return .number(value, text: text)
        }
    }
}

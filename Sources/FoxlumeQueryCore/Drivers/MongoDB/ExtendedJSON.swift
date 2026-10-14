import Foundation

/// MongoDB Extended JSON v2 printing, and parsing of Extended JSON plus mongosh literal syntax.
public enum ExtendedJSON {
    public enum Mode: Sendable {
        case canonical
        case relaxed
    }

    // MARK: Printing

    public static func string(_ document: BSONDocument, mode: Mode = .relaxed) -> String {
        var out = ""
        write(.document(document), mode: mode, into: &out)
        return out
    }

    public static func string(_ value: BSONValue, mode: Mode = .relaxed) -> String {
        var out = ""
        write(value, mode: mode, into: &out)
        return out
    }

    /// Relaxed dates cover years 1970 through 9999; others stay canonical.
    private static let relaxedDateRange: ClosedRange<Int64> = 0...253_402_300_799_999

    static func write(_ value: BSONValue, mode: Mode, into out: inout String) {
        switch value {
        case .double(let number):
            if mode == .relaxed, number.isFinite {
                out += doubleText(number)
            } else {
                out += #"{"$numberDouble":"# + quoted(doubleText(number)) + "}"
            }
        case .string(let text):
            out += quoted(text)
        case .document(let document):
            out += "{"
            for (index, element) in document.elements.enumerated() {
                if index > 0 { out += "," }
                out += quoted(element.key)
                out += ":"
                write(element.value, mode: mode, into: &out)
            }
            out += "}"
        case .array(let array):
            out += "["
            for (index, element) in array.enumerated() {
                if index > 0 { out += "," }
                write(element, mode: mode, into: &out)
            }
            out += "]"
        case let .binary(subtype, data):
            out += #"{"$binary":{"base64":"# + quoted(data.base64EncodedString()) + #","subType":"# + quoted(hexByte(subtype)) + "}}"
        case .undefined:
            out += #"{"$undefined":true}"#
        case .objectId(let id):
            out += #"{"$oid":"# + quoted(id.hex) + "}"
        case .bool(let flag):
            out += flag ? "true" : "false"
        case .date(let milliseconds):
            if mode == .relaxed, relaxedDateRange.contains(milliseconds) {
                out += #"{"$date":"# + quoted(isoDateText(milliseconds)) + "}"
            } else {
                out += #"{"$date":{"$numberLong":"# + quoted(String(milliseconds)) + "}}"
            }
        case .null:
            out += "null"
        case let .regex(pattern, options):
            out += #"{"$regularExpression":{"pattern":"# + quoted(pattern) + #","options":"# + quoted(String(options.sorted())) + "}}"
        case let .dbPointer(namespace, id):
            out += #"{"$dbPointer":{"$ref":"# + quoted(namespace) + #","$id":{"$oid":"# + quoted(id.hex) + "}}}"
        case .javascript(let code):
            out += #"{"$code":"# + quoted(code) + "}"
        case .symbol(let text):
            out += #"{"$symbol":"# + quoted(text) + "}"
        case let .javascriptWithScope(code, scope):
            out += #"{"$code":"# + quoted(code) + #","$scope":"#
            write(.document(scope), mode: mode, into: &out)
            out += "}"
        case .int32(let number):
            out += mode == .relaxed ? String(number) : #"{"$numberInt":"# + quoted(String(number)) + "}"
        case let .timestamp(seconds, increment):
            out += #"{"$timestamp":{"t":"# + String(seconds) + #","i":"# + String(increment) + "}}"
        case .int64(let number):
            out += mode == .relaxed ? String(number) : #"{"$numberLong":"# + quoted(String(number)) + "}"
        case .decimal128(let decimal):
            out += #"{"$numberDecimal":"# + quoted(decimal.description) + "}"
        case .minKey:
            out += #"{"$minKey":1}"#
        case .maxKey:
            out += #"{"$maxKey":1}"#
        }
    }

    /// Shortest text that reads back as the same double, with a point or exponent so it stays a double.
    static func doubleText(_ number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number.isInfinite { return number > 0 ? "Infinity" : "-Infinity" }
        return number.description
    }

    static func hexByte(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]])
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        out.unicodeScalars.reserveCapacity(text.unicodeScalars.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: Dates

    /// ISO 8601 in UTC, with milliseconds only when they are not zero: `2024-05-01T09:30:00Z`, `…:00.250Z`.
    public static func isoDateText(_ milliseconds: Int64, alwaysMilliseconds: Bool = false) -> String {
        var seconds = milliseconds / 1000
        var millis = milliseconds % 1000
        if millis < 0 {
            millis += 1000
            seconds -= 1
        }
        var time = time_t(seconds)
        var parts = tm()
        gmtime_r(&time, &parts)
        var text = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1, Int(parts.tm_mday), Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec))
        if millis != 0 || alwaysMilliseconds { text += String(format: ".%03d", Int(millis)) }
        return text + "Z"
    }

    private static let isoPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^([+-]?\d{4,6})-(\d{1,2})-(\d{1,2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?)?\s*(Z|z|[+-]\d{2}(?::?\d{2})?)?$"#
    )

    /// Parses ISO 8601 dates as mongosh's `ISODate` does. Text without a zone is UTC.
    public static func parseISODate(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let pattern = isoPattern, let match = pattern.firstMatch(in: trimmed, range: range) else { return nil }
        func group(_ index: Int) -> String? {
            guard let groupRange = Range(match.range(at: index), in: trimmed) else { return nil }
            return String(trimmed[groupRange])
        }
        guard let year = group(1).flatMap({ Int($0) }), let month = group(2).flatMap({ Int($0) }), let day = group(3).flatMap({ Int($0) }),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        let hour = group(4).flatMap { Int($0) } ?? 0
        let minute = group(5).flatMap { Int($0) } ?? 0
        let second = group(6).flatMap { Int($0) } ?? 0
        guard hour < 24, minute < 60, second < 61 else { return nil }
        var millis = 0
        if let fraction = group(7) {
            let padded = (fraction + "00").prefix(3)
            millis = Int(padded) ?? 0
        }
        var offsetSeconds = 0
        if let zone = group(8), zone != "Z", zone != "z" {
            let sign = zone.hasPrefix("-") ? -1 : 1
            let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
            let hours = Int(digits.prefix(2)) ?? 0
            let minutes = Int(digits.dropFirst(2)) ?? 0
            offsetSeconds = sign * (hours * 3600 + minutes * 60)
        }
        var parts = tm()
        parts.tm_year = Int32(year - 1900)
        parts.tm_mon = Int32(month - 1)
        parts.tm_mday = Int32(day)
        parts.tm_hour = Int32(hour)
        parts.tm_min = Int32(minute)
        parts.tm_sec = Int32(second)
        let seconds = Int64(timegm(&parts)) - Int64(offsetSeconds)
        return seconds * 1000 + Int64(millis)
    }

    // MARK: Parsing

    /// Parse Extended JSON (canonical or relaxed) or mongosh literal syntax into a document.
    public static func parseDocument(_ text: String) throws -> BSONDocument {
        guard case .document(let document) = try parseValue(text) else {
            throw MongoLiteralError.syntax("Expected a document such as { field: value }")
        }
        return document
    }

    public static func parseValue(_ text: String, template: BSONValue? = nil) throws -> BSONValue {
        try MongoLiteralParser.parse(text).bson(template: template)
    }
}

// MARK: - Literal tree

public enum MongoLiteralError: Error, LocalizedError, Equatable {
    case syntax(String)

    public var errorDescription: String? {
        switch self {
        case .syntax(let message): return message
        }
    }
}

/// A parsed JSON / shell value before Extended JSON wrappers are interpreted.
/// Numbers keep their source text so the BSON type can be chosen afterwards.
indirect enum MongoLiteral: Equatable {
    struct Member: Equatable {
        var key: String
        var value: MongoLiteral
    }

    case object([Member])
    case array([MongoLiteral])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
    case undefined
    case bson(BSONValue)

    /// Convert to BSON. `template` is the value previously stored at the same place; numbers keep its type.
    func bson(template: BSONValue? = nil) throws -> BSONValue {
        switch self {
        case .object(let members):
            if let wrapped = try Self.wrapper(members) { return wrapped }
            let templateDocument = template?.documentValue
            var document = BSONDocument()
            for member in members {
                document[member.key] = try member.value.bson(template: templateDocument?[member.key])
            }
            return .document(document)
        case .array(let elements):
            let templateArray = template?.arrayValue
            return .array(try elements.enumerated().map { index, element in
                let elementTemplate = templateArray.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                return try element.bson(template: elementTemplate)
            })
        case .string(let text): return .string(text)
        case .number(let text): return try Self.number(text, template: template)
        case .bool(let flag): return .bool(flag)
        case .null, .undefined: return .null
        case .bson(let value): return value
        }
    }

    static func number(_ text: String, template: BSONValue?) throws -> BSONValue {
        let lower = text.lowercased()
        let isSpecial = lower.contains("nan") || lower.contains("infinity")
        let isInteger = !isSpecial && !text.contains(".") && !lower.contains("e")
        switch template {
        case .int64?:
            if isInteger, let value = Int64(text) { return .int64(value) }
        case .double?:
            if let value = Double(text) { return .double(value) }
        case .decimal128?:
            if let value = BSONDecimal128(text) { return .decimal128(value) }
        default:
            break
        }
        if isInteger {
            if let value = Int32(text) { return .int32(value) }
            if let value = Int64(text) { return .int64(value) }
        }
        guard let value = Double(text) else { throw MongoLiteralError.syntax("Invalid number \(text)") }
        return .double(value)
    }

    private static func string(_ literal: MongoLiteral?) -> String? {
        if case .string(let text)? = literal { return text }
        return nil
    }

    private static func integer(_ literal: MongoLiteral?) -> Int64? {
        switch literal {
        case .number(let text)?: return Int64(text) ?? Double(text).flatMap { $0.rounded() == $0 ? Int64(exactly: $0) : nil }
        case .string(let text)?: return Int64(text)
        case .bson(let value)?: return value.int64Value
        default: return nil
        }
    }

    /// Interpret Extended JSON wrapper objects such as `{"$oid": "…"}`. Nil when the object is an ordinary document.
    private static func wrapper(_ members: [Member]) throws -> BSONValue? {
        guard let first = members.first, first.key.hasPrefix("$") else { return nil }
        var map: [String: MongoLiteral] = [:]
        for member in members { map[member.key] = member.value }
        let keys = Set(map.keys)
        func invalid(_ what: String) -> MongoLiteralError { .syntax("Invalid Extended JSON \(what)") }

        switch keys {
        case ["$oid"]:
            guard let text = string(map["$oid"]), let id = BSONObjectId(hex: text) else { throw invalid("$oid") }
            return .objectId(id)
        case ["$numberInt"]:
            guard let text = string(map["$numberInt"]), let value = Int32(text) else { throw invalid("$numberInt") }
            return .int32(value)
        case ["$numberLong"]:
            guard let text = string(map["$numberLong"]) ?? numberText(map["$numberLong"]), let value = Int64(text) else { throw invalid("$numberLong") }
            return .int64(value)
        case ["$numberDouble"]:
            guard let text = string(map["$numberDouble"]), let value = Double(text) else { throw invalid("$numberDouble") }
            return .double(value)
        case ["$numberDecimal"]:
            guard let text = string(map["$numberDecimal"]) ?? numberText(map["$numberDecimal"]), let value = BSONDecimal128(text) else {
                throw invalid("$numberDecimal")
            }
            return .decimal128(value)
        case ["$binary"]:
            guard case .object(let inner)? = map["$binary"] else { throw invalid("$binary") }
            let innerMap = Dictionary(inner.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            guard let base64 = string(innerMap["base64"]), let data = Data(base64Encoded: base64),
                  let subtypeText = string(innerMap["subType"]), let subtype = UInt8(subtypeText, radix: 16)
            else { throw invalid("$binary") }
            return .binary(subtype: subtype, data: data)
        case ["$binary", "$type"]:
            guard let base64 = string(map["$binary"]), let data = Data(base64Encoded: base64),
                  let typeText = string(map["$type"]), let subtype = UInt8(typeText, radix: 16)
            else { throw invalid("$binary") }
            return .binary(subtype: subtype, data: data)
        case ["$uuid"]:
            guard let text = string(map["$uuid"]), let data = uuidData(text) else { throw invalid("$uuid") }
            return .binary(subtype: 4, data: data)
        case ["$date"]:
            switch map["$date"] {
            case .string(let text)?:
                guard let milliseconds = ExtendedJSON.parseISODate(text) else { throw invalid("$date") }
                return .date(milliseconds)
            case .object(let inner)?:
                guard inner.count == 1, inner[0].key == "$numberLong", let text = string(inner[0].value), let value = Int64(text) else {
                    throw invalid("$date")
                }
                return .date(value)
            case .number(let text)?:
                guard let value = Int64(text) ?? Double(text).map({ Int64($0) }) else { throw invalid("$date") }
                return .date(value)
            case .bson(let value)?:
                guard let milliseconds = value.int64Value else { throw invalid("$date") }
                return .date(milliseconds)
            default:
                throw invalid("$date")
            }
        case ["$timestamp"]:
            guard case .object(let inner)? = map["$timestamp"] else { throw invalid("$timestamp") }
            let innerMap = Dictionary(inner.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            guard let seconds = integer(innerMap["t"]), let increment = integer(innerMap["i"]),
                  let t = UInt32(exactly: seconds), let i = UInt32(exactly: increment)
            else { throw invalid("$timestamp") }
            return .timestamp(seconds: t, increment: i)
        case ["$regularExpression"]:
            guard case .object(let inner)? = map["$regularExpression"] else { throw invalid("$regularExpression") }
            let innerMap = Dictionary(inner.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            guard let pattern = string(innerMap["pattern"]), let options = string(innerMap["options"]) else {
                throw invalid("$regularExpression")
            }
            return .regex(pattern: pattern, options: String(options.sorted()))
        case ["$regex", "$options"]:
            // The legacy form; as a query operator it means the same thing.
            guard let pattern = string(map["$regex"]), let options = string(map["$options"]) else { return nil }
            return .regex(pattern: pattern, options: String(options.sorted()))
        case ["$code"]:
            guard let code = string(map["$code"]) else { throw invalid("$code") }
            return .javascript(code)
        case ["$code", "$scope"]:
            guard let code = string(map["$code"]), case .document(let scope)? = try map["$scope"]?.bson() else { throw invalid("$code") }
            return .javascriptWithScope(code: code, scope: scope)
        case ["$symbol"]:
            guard let text = string(map["$symbol"]) else { throw invalid("$symbol") }
            return .symbol(text)
        case ["$dbPointer"]:
            guard case .document(let inner)? = try map["$dbPointer"]?.bson(),
                  case .string(let namespace)? = inner["$ref"], case .objectId(let id)? = inner["$id"]
            else { throw invalid("$dbPointer") }
            return .dbPointer(namespace: namespace, id: id)
        case ["$minKey"]:
            return .minKey
        case ["$maxKey"]:
            return .maxKey
        case ["$undefined"]:
            return .undefined
        default:
            return nil
        }
    }

    private static func numberText(_ literal: MongoLiteral?) -> String? {
        if case .number(let text)? = literal { return text }
        return nil
    }

    static func uuidData(_ text: String) -> Data? {
        let hex = text.replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces)
        guard hex.utf8.count == 32 else { return nil }
        return Data(hexString: hex)
    }
}

// MARK: - Parser

/// Parses JSON, Extended JSON and the literal subset of mongosh syntax: unquoted keys, single quotes,
/// comments, trailing commas, regex literals and constructors such as `ObjectId("…")` or `ISODate("…")`.
struct MongoLiteralParser {
    private let bytes: [UInt8]
    private var index = 0

    private init(_ text: String) {
        bytes = Array(text.utf8)
    }

    static func parse(_ text: String) throws -> MongoLiteral {
        var parser = MongoLiteralParser(text)
        let value = try parser.value()
        parser.skipTrivia()
        if parser.index < parser.bytes.count, parser.bytes[parser.index] == UInt8(ascii: ";") {
            parser.index += 1
            parser.skipTrivia()
        }
        guard parser.index >= parser.bytes.count else { throw parser.error("Unexpected text after the value") }
        return value
    }

    private func error(_ message: String) -> MongoLiteralError {
        let shown = index < bytes.count ? " near \"\(String(decoding: bytes[index..<min(bytes.count, index + 12)], as: UTF8.self))\"" : " at the end"
        return .syntax("\(message)\(shown) (position \(index + 1))")
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipTrivia() {
        while index < bytes.count {
            let c = bytes[index]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                index += 1
            } else if c == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "/") {
                while index < bytes.count, bytes[index] != 0x0A { index += 1 }
            } else if c == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "*") {
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) { index += 1 }
                index = min(bytes.count, index + 2)
            } else if c == 0xC2, index + 1 < bytes.count, bytes[index + 1] == 0xA0 {
                index += 2
            } else {
                return
            }
        }
    }

    private mutating func expect(_ char: Character) throws {
        skipTrivia()
        guard let ascii = char.asciiValue, current == ascii else { throw error("Expected \"\(char)\"") }
        index += 1
    }

    private static func isIdentifierStart(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == UInt8(ascii: "_") || c == UInt8(ascii: "$") || c >= 0x80
    }

    private static func isIdentifierPart(_ c: UInt8) -> Bool {
        isIdentifierStart(c) || (c >= 48 && c <= 57)
    }

    mutating func value() throws -> MongoLiteral {
        skipTrivia()
        guard let c = current else { throw error("Expected a value") }
        switch c {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "`"): return .string(try string())
        case UInt8(ascii: "/"): return try regex()
        case UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "."), 48...57: return try number()
        default:
            guard Self.isIdentifierStart(c) else { throw error("Unexpected character") }
            return try identifierValue()
        }
    }

    private mutating func object() throws -> MongoLiteral {
        index += 1
        var members: [MongoLiteral.Member] = []
        while true {
            skipTrivia()
            guard let c = current else { throw error("Unterminated object") }
            if c == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            let key: String
            if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") || c == UInt8(ascii: "`") {
                key = try string()
            } else if Self.isIdentifierStart(c) {
                key = identifier()
            } else if (c >= 48 && c <= 57) || c == UInt8(ascii: "-") {
                guard case .number(let text) = try number() else { throw error("Invalid key") }
                key = text
            } else {
                throw error("Expected a field name")
            }
            try expect(":")
            let value = try value()
            members.removeAll { $0.key == key }
            members.append(MongoLiteral.Member(key: key, value: value))
            skipTrivia()
            if current == UInt8(ascii: ",") {
                index += 1
            } else if current != UInt8(ascii: "}") {
                throw error("Expected \",\" or \"}\"")
            }
        }
    }

    private mutating func array() throws -> MongoLiteral {
        index += 1
        var elements: [MongoLiteral] = []
        while true {
            skipTrivia()
            guard let c = current else { throw error("Unterminated array") }
            if c == UInt8(ascii: "]") {
                index += 1
                return .array(elements)
            }
            elements.append(try value())
            skipTrivia()
            if current == UInt8(ascii: ",") {
                index += 1
            } else if current != UInt8(ascii: "]") {
                throw error("Expected \",\" or \"]\"")
            }
        }
    }

    private mutating func string() throws -> String {
        let quote = bytes[index]
        index += 1
        var out = [UInt8]()
        while true {
            guard let c = current else { throw error("Unterminated string") }
            index += 1
            if c == quote { break }
            guard c == UInt8(ascii: "\\") else {
                out.append(c)
                continue
            }
            guard let escaped = current else { throw error("Unterminated string") }
            index += 1
            switch escaped {
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "v"): out.append(0x0B)
            case UInt8(ascii: "0"): out.append(0x00)
            case 0x0A: break
            case UInt8(ascii: "x"):
                guard let value = hexDigits(2) else { throw error("Invalid \\x escape") }
                appendScalar(value, to: &out)
            case UInt8(ascii: "u"):
                var value: UInt32
                if current == UInt8(ascii: "{") {
                    index += 1
                    var digits = 0
                    value = 0
                    while let d = current, d != UInt8(ascii: "}") {
                        guard let nibble = Self.nibble(d) else { throw error("Invalid \\u escape") }
                        value = value << 4 | UInt32(nibble)
                        digits += 1
                        index += 1
                    }
                    index += 1
                    guard digits > 0 else { throw error("Invalid \\u escape") }
                } else {
                    guard let unit = hexDigits(4) else { throw error("Invalid \\u escape") }
                    value = unit
                    // Surrogate pair written as two escapes.
                    if (0xD800...0xDBFF).contains(value), index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        let saved = index
                        index += 2
                        if let low = hexDigits(4), (0xDC00...0xDFFF).contains(low) {
                            value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            index = saved
                        }
                    }
                }
                appendScalar(value, to: &out)
            default:
                out.append(escaped)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func appendScalar(_ value: UInt32, to out: inout [UInt8]) {
        let scalar = Unicode.Scalar(value) ?? "\u{FFFD}"
        out.append(contentsOf: Array(String(Character(scalar)).utf8))
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }

    private mutating func hexDigits(_ count: Int) -> UInt32? {
        guard index + count <= bytes.count else { return nil }
        var value: UInt32 = 0
        for offset in 0..<count {
            guard let nibble = Self.nibble(bytes[index + offset]) else { return nil }
            value = value << 4 | UInt32(nibble)
        }
        index += count
        return value
    }

    private mutating func number() throws -> MongoLiteral {
        let start = index
        var negative = false
        if current == UInt8(ascii: "-") || current == UInt8(ascii: "+") {
            negative = current == UInt8(ascii: "-")
            index += 1
            skipTrivia()
        }
        if let c = current, Self.isIdentifierStart(c) {
            let word = identifier()
            switch word {
            case "Infinity": return .number(negative ? "-Infinity" : "Infinity")
            case "NaN": return .number("NaN")
            default:
                index = start
                throw error("Invalid number")
            }
        }
        if current == UInt8(ascii: "0"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "x") || bytes[index + 1] == UInt8(ascii: "X") {
            index += 2
            let digitsStart = index
            while let c = current, Self.nibble(c) != nil { index += 1 }
            guard index > digitsStart, let value = Int64(String(decoding: bytes[digitsStart..<index], as: UTF8.self), radix: 16) else {
                throw error("Invalid hex number")
            }
            return .number(String(negative ? -value : value))
        }
        let digitsStart = index
        var sawDigit = false
        while let c = current, c >= 48 && c <= 57 { index += 1; sawDigit = true }
        if current == UInt8(ascii: ".") {
            index += 1
            while let c = current, c >= 48 && c <= 57 { index += 1; sawDigit = true }
        }
        guard sawDigit else { throw error("Invalid number") }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            index += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
            let exponentStart = index
            while let c = current, c >= 48 && c <= 57 { index += 1 }
            guard index > exponentStart else { throw error("Invalid exponent") }
        }
        var text = String(decoding: bytes[digitsStart..<index], as: UTF8.self)
        if text.hasPrefix(".") { text = "0" + text }
        if text.hasSuffix(".") { text += "0" }
        return .number(negative ? "-" + text : text)
    }

    private mutating func regex() throws -> MongoLiteral {
        index += 1
        var pattern = [UInt8]()
        var inClass = false
        while true {
            guard let c = current, c != 0x0A else { throw error("Unterminated regular expression") }
            index += 1
            if c == UInt8(ascii: "\\") {
                pattern.append(c)
                if let next = current {
                    pattern.append(next)
                    index += 1
                }
                continue
            }
            if c == UInt8(ascii: "[") { inClass = true }
            if c == UInt8(ascii: "]") { inClass = false }
            if c == UInt8(ascii: "/") && !inClass { break }
            pattern.append(c)
        }
        var flags = ""
        while let c = current, (c >= 97 && c <= 122) {
            flags.append(Character(Unicode.Scalar(c)))
            index += 1
        }
        // JavaScript-only flags have no BSON meaning.
        let options = String(flags.filter { "ilmsux".contains($0) }.sorted())
        return .bson(.regex(pattern: String(decoding: pattern, as: UTF8.self), options: options))
    }

    private mutating func identifier() -> String {
        let start = index
        while let c = current, Self.isIdentifierPart(c) { index += 1 }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func identifierValue() throws -> MongoLiteral {
        let start = index
        var name = identifier()
        if name == "new" {
            skipTrivia()
            name = identifier()
        }
        // Allow `Long.fromString("…")` style and `Decimal128.fromString("…")`.
        if current == UInt8(ascii: "."), ["Long", "NumberLong", "Decimal128", "Int32", "Double"].contains(name) {
            index += 1
            name += "." + identifier()
        }
        skipTrivia()
        var arguments: [MongoLiteral] = []
        var called = false
        if current == UInt8(ascii: "(") {
            called = true
            index += 1
            while true {
                skipTrivia()
                guard let c = current else { throw error("Unterminated call") }
                if c == UInt8(ascii: ")") {
                    index += 1
                    break
                }
                arguments.append(try value())
                skipTrivia()
                if current == UInt8(ascii: ",") {
                    index += 1
                } else if current != UInt8(ascii: ")") {
                    throw error("Expected \",\" or \")\"")
                }
            }
        }
        if !called {
            switch name {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            case "undefined": return .undefined
            case "NaN": return .number("NaN")
            case "Infinity": return .number("Infinity")
            case "MinKey": return .bson(.minKey)
            case "MaxKey": return .bson(.maxKey)
            default:
                index = start
                throw error("Unknown name \"\(name)\"")
            }
        }
        do {
            return .bson(try Self.construct(name, arguments))
        } catch let failure as MongoLiteralError {
            index = start
            throw failure
        }
    }

    private static func literalText(_ literal: MongoLiteral?) -> String? {
        switch literal {
        case .string(let text)?: return text
        case .number(let text)?: return text
        default: return nil
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func construct(_ name: String, _ arguments: [MongoLiteral]) throws -> BSONValue {
        func fail(_ message: String) -> MongoLiteralError { .syntax("\(name)(): \(message)") }
        let first = arguments.first
        switch name {
        case "ObjectId", "ObjectID":
            guard let first else { return .objectId(.generate()) }
            guard let hex = literalText(first), let id = BSONObjectId(hex: hex) else { throw fail("expected a 24 character hex string") }
            return .objectId(id)
        case "ISODate", "Date":
            guard let first else { return .date(Int64(Date().timeIntervalSince1970 * 1000)) }
            switch first {
            case .string(let text):
                guard let milliseconds = ExtendedJSON.parseISODate(text) else { throw fail("invalid date \"\(text)\"") }
                return .date(milliseconds)
            case .number(let text):
                if arguments.count >= 2 {
                    // new Date(year, monthIndex, day, …) in UTC.
                    let numbers = arguments.compactMap { literalText($0).flatMap { Int($0) } }
                    var parts = tm()
                    parts.tm_year = Int32((numbers.first ?? 1970) - 1900)
                    parts.tm_mon = Int32(numbers.count > 1 ? numbers[1] : 0)
                    parts.tm_mday = Int32(numbers.count > 2 ? numbers[2] : 1)
                    parts.tm_hour = Int32(numbers.count > 3 ? numbers[3] : 0)
                    parts.tm_min = Int32(numbers.count > 4 ? numbers[4] : 0)
                    parts.tm_sec = Int32(numbers.count > 5 ? numbers[5] : 0)
                    return .date(Int64(timegm(&parts)) * 1000 + Int64(numbers.count > 6 ? numbers[6] : 0))
                }
                guard let value = Double(text) else { throw fail("invalid milliseconds") }
                return .date(Int64(value))
            case .bson(.date(let value)):
                return .date(value)
            default:
                throw fail("expected a date string")
            }
        case "NumberLong", "Long", "Long.fromString", "NumberLong.fromString", "Long.fromNumber":
            guard let first else { return .int64(0) }
            guard let raw = literalText(first) else { throw fail("expected a number") }
            if let value = Int64(raw) { return .int64(value) }
            guard let value = Double(raw), value.isFinite, let integral = Int64(exactly: value.rounded(.towardZero)) else { throw fail("invalid value \(raw)") }
            return .int64(integral)
        case "NumberInt", "Int32", "Int32.fromString":
            guard let first else { return .int32(0) }
            guard let raw = literalText(first) else { throw fail("expected a number") }
            if let value = Int32(raw) { return .int32(value) }
            guard let value = Double(raw), value.isFinite, let integral = Int32(exactly: value.rounded(.towardZero)) else { throw fail("invalid value \(raw)") }
            return .int32(integral)
        case "Double", "Double.fromString":
            guard let raw = literalText(first), let value = Double(raw) else { throw fail("expected a number") }
            return .double(value)
        case "NumberDecimal", "Decimal128", "Decimal128.fromString":
            guard let first else { return .decimal128(BSONDecimal128("0") ?? .nan) }
            guard let raw = literalText(first), let value = BSONDecimal128(raw) else { throw fail("invalid decimal") }
            return .decimal128(value)
        case "UUID":
            guard let first else {
                var bytes = randomBytes(16)
                bytes[6] = (bytes[6] & 0x0F) | 0x40
                bytes[8] = (bytes[8] & 0x3F) | 0x80
                return .binary(subtype: 4, data: Data(bytes))
            }
            guard let raw = literalText(first), let data = MongoLiteral.uuidData(raw) else { throw fail("expected a UUID string") }
            return .binary(subtype: 4, data: data)
        case "BinData":
            guard arguments.count == 2, let subtypeText = literalText(arguments[0]), let subtype = UInt8(subtypeText),
                  let base64 = literalText(arguments[1]), let data = Data(base64Encoded: base64)
            else { throw fail("expected (subtype, base64)") }
            return .binary(subtype: subtype, data: data)
        case "HexData":
            guard arguments.count == 2, let subtypeText = literalText(arguments[0]), let subtype = UInt8(subtypeText),
                  let hex = literalText(arguments[1]), let data = Data(hexString: hex)
            else { throw fail("expected (subtype, hex)") }
            return .binary(subtype: subtype, data: data)
        case "MD5":
            guard let hex = literalText(first), hex.utf8.count == 32, let data = Data(hexString: hex) else { throw fail("expected 32 hex digits") }
            return .binary(subtype: 5, data: data)
        case "Timestamp":
            if case .object(let members)? = first {
                let map = Dictionary(members.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
                guard let t = literalText(map["t"]).flatMap({ UInt32($0) }), let i = literalText(map["i"]).flatMap({ UInt32($0) }) else {
                    throw fail("expected { t, i }")
                }
                return .timestamp(seconds: t, increment: i)
            }
            guard arguments.count == 2 || arguments.isEmpty else { throw fail("expected (t, i)") }
            let t = arguments.isEmpty ? 0 : literalText(arguments[0]).flatMap { UInt32($0) }
            let i = arguments.isEmpty ? 0 : literalText(arguments[1]).flatMap { UInt32($0) }
            guard let t, let i else { throw fail("expected (t, i)") }
            return .timestamp(seconds: t, increment: i)
        case "Code":
            guard let code = literalText(first) else { throw fail("expected code text") }
            if arguments.count > 1, case .document(let scope) = try arguments[1].bson() {
                return .javascriptWithScope(code: code, scope: scope)
            }
            return .javascript(code)
        case "DBRef":
            guard arguments.count >= 2, let collection = literalText(arguments[0]) else { throw fail("expected (collection, id)") }
            var document: BSONDocument = ["$ref": .string(collection), "$id": try arguments[1].bson()]
            if arguments.count > 2, let database = literalText(arguments[2]) { document["$db"] = .string(database) }
            return .document(document)
        case "BSONRegExp", "RegExp":
            guard let pattern = literalText(first) else { throw fail("expected a pattern") }
            let options = arguments.count > 1 ? (literalText(arguments[1]) ?? "") : ""
            return .regex(pattern: pattern, options: String(options.filter { "ilmsux".contains($0) }.sorted()))
        case "MinKey": return .minKey
        case "MaxKey": return .maxKey
        case "BSONSymbol", "Symbol":
            guard let value = literalText(first) else { throw fail("expected a string") }
            return .symbol(value)
        default:
            throw MongoLiteralError.syntax("Unsupported function \(name)()")
        }
    }
}

// MARK: - Shell formatting

/// Prints BSON in mongosh syntax, which the script runtime can read back with the same types.
enum MongoShellFormatter {
    static func format(_ value: BSONValue, pretty: Bool = false) -> String {
        var out = ""
        write(value, pretty: pretty, indent: 0, into: &out)
        return out
    }

    static func format(_ document: BSONDocument, pretty: Bool = false) -> String {
        format(.document(document), pretty: pretty)
    }

    private static func key(_ name: String) -> String {
        guard let first = name.unicodeScalars.first,
              CharacterSet.letters.contains(first) || first == "_" || first == "$",
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" }),
              name.unicodeScalars.allSatisfy(\.isASCII)
        else { return ExtendedJSON.quoted(name) }
        return name
    }

    private static func write(_ value: BSONValue, pretty: Bool, indent: Int, into out: inout String) {
        if pretty {
            // Short documents and arrays stay on one line, as mongosh prints them.
            let compact = format(value, pretty: false)
            if compact.count + indent * 2 <= 80 {
                out += compact
                return
            }
        }
        switch value {
        case .document(let document):
            guard !document.isEmpty else {
                out += "{}"
                return
            }
            if pretty {
                out += "{\n"
                for (index, element) in document.elements.enumerated() {
                    out += String(repeating: "  ", count: indent + 1) + key(element.key) + ": "
                    write(element.value, pretty: pretty, indent: indent + 1, into: &out)
                    out += index + 1 < document.count ? ",\n" : "\n"
                }
                out += String(repeating: "  ", count: indent) + "}"
            } else {
                out += "{ "
                for (index, element) in document.elements.enumerated() {
                    if index > 0 { out += ", " }
                    out += key(element.key) + ": "
                    write(element.value, pretty: pretty, indent: indent, into: &out)
                }
                out += " }"
            }
        case .array(let array):
            guard !array.isEmpty else {
                out += "[]"
                return
            }
            let nested = array.contains { if case .document = $0 { return true }; if case .array = $0 { return true }; return false }
            if pretty && nested {
                out += "[\n"
                for (index, element) in array.enumerated() {
                    out += String(repeating: "  ", count: indent + 1)
                    write(element, pretty: pretty, indent: indent + 1, into: &out)
                    out += index + 1 < array.count ? ",\n" : "\n"
                }
                out += String(repeating: "  ", count: indent) + "]"
            } else {
                out += "[ "
                for (index, element) in array.enumerated() {
                    if index > 0 { out += ", " }
                    write(element, pretty: pretty, indent: indent, into: &out)
                }
                out += " ]"
            }
        default:
            out += scalar(value)
        }
    }

    static func scalar(_ value: BSONValue) -> String {
        switch value {
        case .double(let number): return ExtendedJSON.doubleText(number)
        case .string(let text): return ExtendedJSON.quoted(text)
        case .document, .array: return format(value)
        case let .binary(subtype, data):
            if subtype == 4, data.count == 16 { return "UUID(\"\(uuidText(data))\")" }
            return "BinData(\(subtype), \"\(data.base64EncodedString())\")"
        case .undefined: return "undefined"
        case .objectId(let id): return "ObjectId(\"\(id.hex)\")"
        case .bool(let flag): return flag ? "true" : "false"
        case .date(let milliseconds):
            return "ISODate(\"\(ExtendedJSON.isoDateText(milliseconds, alwaysMilliseconds: true))\")"
        case .null: return "null"
        case let .regex(pattern, options): return "/\(pattern.replacingOccurrences(of: "/", with: "\\/"))/\(options)"
        case let .dbPointer(namespace, id): return "DBPointer(\(ExtendedJSON.quoted(namespace)), ObjectId(\"\(id.hex)\"))"
        case .javascript(let code): return "Code(\(ExtendedJSON.quoted(code)))"
        case .symbol(let text): return ExtendedJSON.quoted(text)
        case let .javascriptWithScope(code, scope): return "Code(\(ExtendedJSON.quoted(code)), \(format(.document(scope))))"
        case .int32(let number): return String(number)
        case let .timestamp(seconds, increment): return "Timestamp({ t: \(seconds), i: \(increment) })"
        case .int64(let number): return "NumberLong(\"\(number)\")"
        case .decimal128(let decimal): return "NumberDecimal(\"\(decimal)\")"
        case .minKey: return "MinKey()"
        case .maxKey: return "MaxKey()"
        }
    }

    static func uuidText(_ data: Data) -> String {
        let hex = data.hexString
        guard hex.count == 32 else { return hex }
        let chars = Array(hex)
        return [chars[0..<8], chars[8..<12], chars[12..<16], chars[16..<20], chars[20..<32]].map { String($0) }.joined(separator: "-")
    }
}

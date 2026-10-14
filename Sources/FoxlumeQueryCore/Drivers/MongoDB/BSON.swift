import Foundation
import Security

// MARK: - ObjectId

/// A 12-byte BSON ObjectId: 4-byte big-endian seconds, 5 random bytes per process, 3-byte counter.
public struct BSONObjectId: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 12 else { return nil }
        self.bytes = bytes
    }

    fileprivate init(validBytes: [UInt8]) {
        bytes = validBytes
    }

    public init?(hex: String) {
        let text = hex.trimmingCharacters(in: .whitespaces)
        guard text.utf8.count == 24, let decoded = Data(hexString: text) else { return nil }
        bytes = [UInt8](decoded)
    }

    public static func generate() -> BSONObjectId {
        ObjectIdGenerator.shared.next()
    }

    public var hex: String { Data(bytes).hexString }
    public var description: String { hex }

    public var timestamp: Date {
        let seconds = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// True for a string that would read as an ObjectId: exactly 24 hex digits.
    public static func looksLikeObjectId(_ text: String) -> Bool {
        text.utf8.count == 24 && text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) }
    }
}

private final class ObjectIdGenerator: @unchecked Sendable {
    static let shared = ObjectIdGenerator()
    private let lock = NSLock()
    private let processUnique: [UInt8]
    private var counter: UInt32

    private init() {
        processUnique = randomBytes(5)
        let seed = randomBytes(3)
        counter = UInt32(seed[0]) << 16 | UInt32(seed[1]) << 8 | UInt32(seed[2])
    }

    func next() -> BSONObjectId {
        lock.lock()
        counter = (counter + 1) & 0xFF_FFFF
        let value = counter
        lock.unlock()
        let seconds = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
        var bytes: [UInt8] = [UInt8(seconds >> 24), UInt8((seconds >> 16) & 0xff), UInt8((seconds >> 8) & 0xff), UInt8(seconds & 0xff)]
        bytes += processUnique
        bytes += [UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        return BSONObjectId(validBytes: bytes)
    }
}

func randomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
        var generator = SystemRandomNumberGenerator()
        bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
    return bytes
}

extension Data {
    /// Decode an even-length hex string. Nil for anything else.
    init?(hexString: String) {
        let utf8 = Array(hexString.utf8)
        guard utf8.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(utf8.count / 2)
        var index = 0
        while index < utf8.count {
            guard let high = Self.nibble(utf8[index]), let low = Self.nibble(utf8[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }
}

// MARK: - Decimal128

/// IEEE 754-2008 decimal128 in the binary integer decimal encoding BSON uses.
public struct BSONDecimal128: Hashable, Sendable, CustomStringConvertible {
    public var low: UInt64
    public var high: UInt64

    public init(low: UInt64, high: UInt64) {
        self.low = low
        self.high = high
    }

    static let exponentBias = 6176
    static let maxExponent = 6111
    static let minExponent = -6176
    static let maxDigits = 34

    public static let nan = BSONDecimal128(low: 0, high: 0x7C00_0000_0000_0000)
    public static let infinity = BSONDecimal128(low: 0, high: 0x7800_0000_0000_0000)
    public static let negativeInfinity = BSONDecimal128(low: 0, high: 0xF800_0000_0000_0000)

    /// Parse decimal text exactly. Fails for malformed text and for values that would need rounding.
    public init?(_ text: String) {
        var chars = Substring(text.trimmingCharacters(in: .whitespaces))
        var negative = false
        if chars.first == "-" || chars.first == "+" {
            negative = chars.first == "-"
            chars = chars.dropFirst()
        }
        let lower = chars.lowercased()
        if lower == "inf" || lower == "infinity" {
            self = negative ? .negativeInfinity : .infinity
            return
        }
        if lower == "nan" {
            self = .nan
            return
        }
        var digits: [UInt8] = []
        var sawPoint = false
        var fractionDigits = 0
        var sawDigit = false
        var index = chars.startIndex
        while index < chars.endIndex {
            let c = chars[index]
            if let value = c.wholeNumberValue, c.isASCII {
                sawDigit = true
                digits.append(UInt8(value))
                if sawPoint { fractionDigits += 1 }
            } else if c == "." && !sawPoint {
                sawPoint = true
            } else {
                break
            }
            index = chars.index(after: index)
        }
        guard sawDigit else { return nil }
        var exponent = 0
        if index < chars.endIndex {
            guard chars[index] == "e" || chars[index] == "E" else { return nil }
            let rest = chars[chars.index(after: index)...]
            guard !rest.isEmpty, let value = Int(rest), abs(value) < 100_000 else { return nil }
            exponent = value
        }
        exponent -= fractionDigits
        while digits.count > 1, digits.first == 0 { digits.removeFirst() }
        let isZero = digits.allSatisfy { $0 == 0 }
        if isZero { digits = [0] }
        while digits.count > Self.maxDigits {
            guard digits.last == 0 else { return nil }
            digits.removeLast()
            exponent += 1
        }
        while exponent > Self.maxExponent {
            if isZero {
                exponent = Self.maxExponent
            } else if digits.count < Self.maxDigits {
                digits.append(0)
                exponent -= 1
            } else {
                return nil
            }
        }
        while exponent < Self.minExponent {
            if isZero {
                exponent = Self.minExponent
            } else if digits.count > 1, digits.last == 0 {
                digits.removeLast()
                exponent += 1
            } else {
                return nil
            }
        }
        var coefficient = UInt128Parts(high: 0, low: 0)
        for digit in digits {
            coefficient = coefficient.timesTen(plus: UInt64(digit))
        }
        let biased = UInt64(exponent + Self.exponentBias)
        high = (negative ? 1 << 63 : 0) | (biased << 49) | coefficient.high
        low = coefficient.low
    }

    public var isNegative: Bool { high >> 63 == 1 }
    public var isNaN: Bool { (high >> 58) & 0x1F == 0x1F }
    public var isInfinite: Bool { (high >> 58) & 0x1F == 0x1E }

    public var description: String {
        let combination = (high >> 58) & 0x1F
        let sign = isNegative ? "-" : ""
        var exponent: Int
        var coefficient: UInt128Parts
        if combination >> 3 == 3 {
            if combination == 0x1E { return sign + "Infinity" }
            if combination == 0x1F { return "NaN" }
            // The implied 0b100 prefix makes the coefficient exceed 34 digits, which is non-canonical and reads as 0.
            exponent = Int((high >> 47) & 0x3FFF) - Self.exponentBias
            coefficient = UInt128Parts(high: 0, low: 0)
        } else {
            exponent = Int((high >> 49) & 0x3FFF) - Self.exponentBias
            coefficient = UInt128Parts(high: high & 0x1_FFFF_FFFF_FFFF, low: low)
            if coefficient.exceedsDecimal128Max { coefficient = UInt128Parts(high: 0, low: 0) }
        }
        let digits = coefficient.decimalString
        let adjusted = exponent + digits.count - 1
        var text: String
        if exponent > 0 || adjusted < -6 {
            text = String(digits.prefix(1))
            if digits.count > 1 { text += "." + digits.dropFirst() }
            text += "E" + (adjusted >= 0 ? "+" : "") + String(adjusted)
        } else if exponent == 0 {
            text = digits
        } else {
            let pointPosition = digits.count + exponent
            if pointPosition > 0 {
                let index = digits.index(digits.startIndex, offsetBy: pointPosition)
                text = digits[..<index] + "." + digits[index...]
            } else {
                text = "0." + String(repeating: "0", count: -pointPosition) + digits
            }
        }
        return sign + text
    }
}

/// Just enough 128-bit arithmetic for the decimal128 coefficient, which also builds on macOS 13.
struct UInt128Parts: Equatable {
    var high: UInt64
    var low: UInt64

    func timesTen(plus digit: UInt64) -> UInt128Parts {
        let lowProduct = low.multipliedFullWidth(by: 10)
        let (newLow, carry) = lowProduct.low.addingReportingOverflow(digit)
        let newHigh = high &* 10 &+ lowProduct.high &+ (carry ? 1 : 0)
        return UInt128Parts(high: newHigh, low: newLow)
    }

    func divided(by divisor: UInt64) -> (quotient: UInt128Parts, remainder: UInt64) {
        let quotientHigh = high / divisor
        let remainderHigh = high % divisor
        let (quotientLow, remainder) = divisor.dividingFullWidth((high: remainderHigh, low: low))
        return (UInt128Parts(high: quotientHigh, low: quotientLow), remainder)
    }

    var isZero: Bool { high == 0 && low == 0 }

    /// 10^34 - 1 is 0x1ED09BEAD87C0378D8E63FFFFFFFF.
    var exceedsDecimal128Max: Bool {
        let maxHigh: UInt64 = 0x1_ED09_BEAD_87C0
        let maxLow: UInt64 = 0x378D_8E63_FFFF_FFFF
        return high > maxHigh || (high == maxHigh && low > maxLow)
    }

    var decimalString: String {
        guard !isZero else { return "0" }
        var value = self
        var chunks: [UInt64] = []
        while !value.isZero {
            let (quotient, remainder) = value.divided(by: 1_000_000_000)
            chunks.append(remainder)
            value = quotient
        }
        var text = String(chunks.removeLast())
        for chunk in chunks.reversed() {
            let part = String(chunk)
            text += String(repeating: "0", count: 9 - part.count) + part
        }
        return text
    }
}

// MARK: - Values

public enum BSONValue: Hashable, Sendable {
    case double(Double)
    case string(String)
    case document(BSONDocument)
    case array([BSONValue])
    case binary(subtype: UInt8, data: Data)
    case undefined
    case objectId(BSONObjectId)
    case bool(Bool)
    /// Milliseconds since the Unix epoch.
    case date(Int64)
    case null
    case regex(pattern: String, options: String)
    case dbPointer(namespace: String, id: BSONObjectId)
    case javascript(String)
    case symbol(String)
    case javascriptWithScope(code: String, scope: BSONDocument)
    case int32(Int32)
    case timestamp(seconds: UInt32, increment: UInt32)
    case int64(Int64)
    case decimal128(BSONDecimal128)
    case minKey
    case maxKey

    public var typeByte: UInt8 {
        switch self {
        case .double: return 0x01
        case .string: return 0x02
        case .document: return 0x03
        case .array: return 0x04
        case .binary: return 0x05
        case .undefined: return 0x06
        case .objectId: return 0x07
        case .bool: return 0x08
        case .date: return 0x09
        case .null: return 0x0A
        case .regex: return 0x0B
        case .dbPointer: return 0x0C
        case .javascript: return 0x0D
        case .symbol: return 0x0E
        case .javascriptWithScope: return 0x0F
        case .int32: return 0x10
        case .timestamp: return 0x11
        case .int64: return 0x12
        case .decimal128: return 0x13
        case .minKey: return 0xFF
        case .maxKey: return 0x7F
        }
    }

    /// The `$type` alias the server uses, for example `objectId` or `long`.
    public var typeAlias: String {
        switch self {
        case .double: return "double"
        case .string: return "string"
        case .document: return "object"
        case .array: return "array"
        case .binary: return "binData"
        case .undefined: return "undefined"
        case .objectId: return "objectId"
        case .bool: return "bool"
        case .date: return "date"
        case .null: return "null"
        case .regex: return "regex"
        case .dbPointer: return "dbPointer"
        case .javascript: return "javascript"
        case .symbol: return "symbol"
        case .javascriptWithScope: return "javascriptWithScope"
        case .int32: return "int"
        case .timestamp: return "timestamp"
        case .int64: return "long"
        case .decimal128: return "decimal"
        case .minKey: return "minKey"
        case .maxKey: return "maxKey"
        }
    }

    public var documentValue: BSONDocument? {
        if case .document(let document) = self { return document }
        return nil
    }

    public var arrayValue: [BSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .int32, .int64, .double: return int64Value.map { $0 != 0 }
        default: return nil
        }
    }

    /// Integral value of any numeric type, when it is exactly an integer.
    public var int64Value: Int64? {
        switch self {
        case .int32(let value): return Int64(value)
        case .int64(let value): return value
        case .double(let value):
            guard value.isFinite, value.rounded() == value, abs(value) < 9.2e18 else { return nil }
            return Int64(value)
        case .decimal128(let value): return Int64(value.description)
        default: return nil
        }
    }

    public var intValue: Int? { int64Value.flatMap { Int(exactly: $0) } }

    public var doubleValue: Double? {
        switch self {
        case .int32(let value): return Double(value)
        case .int64(let value): return Double(value)
        case .double(let value): return value
        case .decimal128(let value): return Double(value.description)
        default: return nil
        }
    }

    public var isNumber: Bool {
        switch self {
        case .int32, .int64, .double, .decimal128: return true
        default: return false
        }
    }

    public var isNull: Bool { self == .null }
}

// MARK: - Documents

/// An ordered BSON document. Field order is kept exactly as stored or inserted.
public struct BSONDocument: Hashable, Sendable, ExpressibleByDictionaryLiteral {
    public struct Element: Hashable, Sendable {
        public var key: String
        public var value: BSONValue

        public init(key: String, value: BSONValue) {
            self.key = key
            self.value = value
        }
    }

    public private(set) var elements: [Element]

    public init() { elements = [] }

    public init(elements: [Element]) { self.elements = elements }

    public init(_ pairs: [(String, BSONValue)]) {
        elements = pairs.map { Element(key: $0.0, value: $0.1) }
    }

    public init(dictionaryLiteral pairs: (String, BSONValue)...) {
        elements = pairs.map { Element(key: $0.0, value: $0.1) }
    }

    public var keys: [String] { elements.map(\.key) }
    public var values: [BSONValue] { elements.map(\.value) }
    public var count: Int { elements.count }
    public var isEmpty: Bool { elements.isEmpty }
    public var first: Element? { elements.first }

    public func contains(_ key: String) -> Bool { elements.contains { $0.key == key } }

    /// Setting nil removes the field; setting an existing key replaces it in place.
    public subscript(key: String) -> BSONValue? {
        get { elements.first { $0.key == key }?.value }
        set {
            if let index = elements.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    elements[index].value = newValue
                } else {
                    elements.remove(at: index)
                }
            } else if let newValue {
                elements.append(Element(key: key, value: newValue))
            }
        }
    }

    public mutating func append(_ key: String, _ value: BSONValue) {
        elements.append(Element(key: key, value: value))
    }

    /// Put the field first, replacing an existing one with the same key.
    public mutating func prepend(_ key: String, _ value: BSONValue) {
        elements.removeAll { $0.key == key }
        elements.insert(Element(key: key, value: value), at: 0)
    }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> BSONValue? {
        guard let index = elements.firstIndex(where: { $0.key == key }) else { return nil }
        return elements.remove(at: index).value
    }

    /// Value at a dotted path such as `address.city`, following documents and array indexes.
    public func value(atPath path: String) -> BSONValue? {
        var current: BSONValue = .document(self)
        for component in path.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
            switch current {
            case .document(let document):
                guard let next = document[component] else { return nil }
                current = next
            case .array(let array):
                guard let index = Int(component), array.indices.contains(index) else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }
}

// MARK: - Encoding

public enum BSONError: Error, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return "Invalid BSON: \(message)"
        }
    }
}

struct BSONWriter {
    var bytes: [UInt8] = []

    mutating func int32(_ value: Int32) {
        let v = UInt32(bitPattern: value)
        bytes.append(UInt8(v & 0xff))
        bytes.append(UInt8((v >> 8) & 0xff))
        bytes.append(UInt8((v >> 16) & 0xff))
        bytes.append(UInt8((v >> 24) & 0xff))
    }

    mutating func uint32(_ value: UInt32) { int32(Int32(bitPattern: value)) }

    mutating func int64(_ value: Int64) { uint64(UInt64(bitPattern: value)) }

    mutating func uint64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    mutating func setInt32(_ value: Int32, at offset: Int) {
        let v = UInt32(bitPattern: value)
        bytes[offset] = UInt8(v & 0xff)
        bytes[offset + 1] = UInt8((v >> 8) & 0xff)
        bytes[offset + 2] = UInt8((v >> 16) & 0xff)
        bytes[offset + 3] = UInt8((v >> 24) & 0xff)
    }

    mutating func cString(_ string: String, what: String) throws {
        let utf8 = Array(string.utf8)
        guard !utf8.contains(0) else { throw BSONError.invalid("\(what) \"\(string)\" contains a NUL character") }
        bytes.append(contentsOf: utf8)
        bytes.append(0)
    }

    mutating func string(_ string: String) {
        let utf8 = Array(string.utf8)
        int32(Int32(utf8.count + 1))
        bytes.append(contentsOf: utf8)
        bytes.append(0)
    }

    mutating func document(_ document: BSONDocument, depth: Int = 0) throws {
        try container(document.elements.lazy.map { ($0.key, $0.value) }, depth: depth)
    }

    mutating func array(_ array: [BSONValue], depth: Int) throws {
        try container(array.enumerated().lazy.map { (String($0.offset), $0.element) }, depth: depth)
    }

    private mutating func container<S: Sequence>(_ elements: S, depth: Int) throws where S.Element == (String, BSONValue) {
        guard depth < 200 else { throw BSONError.invalid("nesting is too deep") }
        let start = bytes.count
        int32(0)
        for (key, value) in elements {
            bytes.append(value.typeByte)
            try cString(key, what: "Field name")
            try self.value(value, depth: depth)
        }
        bytes.append(0)
        setInt32(Int32(bytes.count - start), at: start)
    }

    mutating func value(_ value: BSONValue, depth: Int) throws {
        switch value {
        case .double(let number): uint64(number.bitPattern)
        case .string(let text), .javascript(let text), .symbol(let text): string(text)
        case .document(let document): try self.document(document, depth: depth + 1)
        case .array(let array): try self.array(array, depth: depth + 1)
        case let .binary(subtype, data):
            if subtype == 0x02 {
                // The deprecated "old binary" subtype repeats the length inside the payload.
                int32(Int32(data.count + 4))
                bytes.append(subtype)
                int32(Int32(data.count))
            } else {
                int32(Int32(data.count))
                bytes.append(subtype)
            }
            bytes.append(contentsOf: data)
        case .undefined, .null, .minKey, .maxKey: break
        case .objectId(let id): bytes.append(contentsOf: id.bytes)
        case .bool(let flag): bytes.append(flag ? 1 : 0)
        case .date(let milliseconds): int64(milliseconds)
        case let .regex(pattern, options):
            try cString(pattern, what: "Regular expression")
            try cString(String(options.sorted()), what: "Regular expression options")
        case let .dbPointer(namespace, id):
            string(namespace)
            bytes.append(contentsOf: id.bytes)
        case let .javascriptWithScope(code, scope):
            let start = bytes.count
            int32(0)
            string(code)
            try document(scope, depth: depth + 1)
            setInt32(Int32(bytes.count - start), at: start)
        case .int32(let number): int32(number)
        case let .timestamp(seconds, increment):
            uint32(increment)
            uint32(seconds)
        case .int64(let number): int64(number)
        case .decimal128(let decimal):
            uint64(decimal.low)
            uint64(decimal.high)
        }
    }
}

public extension BSONDocument {
    func encoded() throws -> [UInt8] {
        var writer = BSONWriter()
        try writer.document(self)
        return writer.bytes
    }

    init(bytes: [UInt8]) throws {
        var reader = BSONReader(bytes)
        self = try reader.document(depth: 0)
        guard reader.isAtEnd else { throw BSONError.invalid("trailing bytes after the document") }
    }
}

// MARK: - Decoding

struct BSONReader {
    let bytes: [UInt8]
    var offset: Int
    let end: Int

    init(_ bytes: [UInt8], offset: Int = 0, end: Int? = nil) {
        self.bytes = bytes
        self.offset = offset
        self.end = end ?? bytes.count
    }

    var isAtEnd: Bool { offset >= end }

    private func need(_ count: Int) throws {
        guard count >= 0, offset + count <= end else { throw BSONError.invalid("unexpected end of data") }
    }

    mutating func uint8() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func int32() throws -> Int32 {
        try need(4)
        defer { offset += 4 }
        let v = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        return Int32(bitPattern: v)
    }

    mutating func uint32() throws -> UInt32 { UInt32(bitPattern: try int32()) }

    mutating func uint64() throws -> UInt64 {
        try need(8)
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[offset + index]) << UInt64(index * 8) }
        offset += 8
        return value
    }

    mutating func raw(_ count: Int) throws -> [UInt8] {
        try need(count)
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func cString() throws -> String {
        var cursor = offset
        while cursor < end, bytes[cursor] != 0 { cursor += 1 }
        guard cursor < end else { throw BSONError.invalid("unterminated C string") }
        let text = String(decoding: bytes[offset..<cursor], as: UTF8.self)
        offset = cursor + 1
        return text
    }

    mutating func string() throws -> String {
        let length = Int(try int32())
        guard length >= 1 else { throw BSONError.invalid("bad string length") }
        try need(length)
        guard bytes[offset + length - 1] == 0 else { throw BSONError.invalid("string is not NUL terminated") }
        let text = String(decoding: bytes[offset..<(offset + length - 1)], as: UTF8.self)
        offset += length
        return text
    }

    mutating func document(depth: Int) throws -> BSONDocument {
        var elements: [BSONDocument.Element] = []
        try readContainer(depth: depth) { key, value in elements.append(BSONDocument.Element(key: key, value: value)) }
        return BSONDocument(elements: elements)
    }

    mutating func array(depth: Int) throws -> [BSONValue] {
        var values: [BSONValue] = []
        try readContainer(depth: depth) { _, value in values.append(value) }
        return values
    }

    private mutating func readContainer(depth: Int, _ body: (String, BSONValue) -> Void) throws {
        guard depth < 200 else { throw BSONError.invalid("nesting is too deep") }
        let start = offset
        let length = Int(try int32())
        guard length >= 5, start + length <= end else { throw BSONError.invalid("bad document length") }
        let containerEnd = start + length
        while true {
            guard offset < containerEnd else { throw BSONError.invalid("document is not terminated") }
            let type = try uint8()
            if type == 0 { break }
            let key = try cString()
            body(key, try value(type: type, depth: depth))
        }
        guard offset == containerEnd else { throw BSONError.invalid("document length does not match its content") }
    }

    mutating func value(type: UInt8, depth: Int) throws -> BSONValue {
        switch type {
        case 0x01: return .double(Double(bitPattern: try uint64()))
        case 0x02: return .string(try string())
        case 0x03: return .document(try document(depth: depth + 1))
        case 0x04: return .array(try array(depth: depth + 1))
        case 0x05:
            let length = Int(try int32())
            guard length >= 0 else { throw BSONError.invalid("negative binary length") }
            let subtype = try uint8()
            var data = try raw(length)
            if subtype == 0x02, data.count >= 4 { data.removeFirst(4) }
            return .binary(subtype: subtype, data: Data(data))
        case 0x06: return .undefined
        case 0x07: return .objectId(try objectId())
        case 0x08: return .bool(try uint8() != 0)
        case 0x09: return .date(Int64(bitPattern: try uint64()))
        case 0x0A: return .null
        case 0x0B:
            let pattern = try cString()
            return .regex(pattern: pattern, options: try cString())
        case 0x0C:
            let namespace = try string()
            return .dbPointer(namespace: namespace, id: try objectId())
        case 0x0D: return .javascript(try string())
        case 0x0E: return .symbol(try string())
        case 0x0F:
            _ = try int32()
            let code = try string()
            return .javascriptWithScope(code: code, scope: try document(depth: depth + 1))
        case 0x10: return .int32(try int32())
        case 0x11:
            let increment = try uint32()
            return .timestamp(seconds: try uint32(), increment: increment)
        case 0x12: return .int64(Int64(bitPattern: try uint64()))
        case 0x13:
            let low = try uint64()
            return .decimal128(BSONDecimal128(low: low, high: try uint64()))
        case 0xFF: return .minKey
        case 0x7F: return .maxKey
        default: throw BSONError.invalid("unknown element type 0x\(String(type, radix: 16))")
        }
    }

    private mutating func objectId() throws -> BSONObjectId {
        guard let id = BSONObjectId(bytes: try raw(12)) else { throw BSONError.invalid("bad ObjectId") }
        return id
    }
}

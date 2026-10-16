import Foundation

/// One step of a JSON path: an object key or an array index.
public enum JSONPathComponent: Hashable, Sendable {
    case key(String)
    case index(Int)
}

public enum JSONPath {
    /// The path in JSONPath notation, such as `$.items[2].name` or `$['first name']`.
    public static func string(_ components: [JSONPathComponent]) -> String {
        var path = "$"
        for component in components {
            switch component {
            case .index(let index):
                path += "[\(index)]"
            case .key(let key) where isIdentifier(key):
                path += "." + key
            case .key(let key):
                path += "['" + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "']"
            }
        }
        return path
    }

    /// Keys written with a dot: ASCII letters, digits, `_` and `$`, not starting with a digit.
    static func isIdentifier(_ key: String) -> Bool {
        guard let first = key.utf8.first, !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else { return false }
        return key.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$")
        }
    }
}

/// A JSON object or array for the value viewer's tree. The text is checked once; nodes keep byte ranges into it and
/// read their children only when asked, so a document of several megabytes opens without building the whole tree.
/// Keys keep the order of the text. Nodes point to their parent weakly: keep the document while using its nodes.
public final class JSONTreeDocument {
    public let root: JSONTreeNode
    public let byteCount: Int

    /// Nil unless `text` is valid JSON whose top level is an object or an array.
    public init?(text: String) {
        let source = JSONSource(bytes: Array(text.utf8))
        guard let range = source.validatedRoot() else { return nil }
        byteCount = source.bytes.count
        root = JSONTreeNode(source: source, range: range, component: nil, parent: nil)
    }

    /// True when `text` would open as a tree: a valid JSON object or array.
    public static func isTree(_ text: String) -> Bool {
        JSONSource(bytes: Array(text.utf8)).validatedRoot() != nil
    }

    /// Nodes whose key or value contains `query` (ignoring case), and the path to each.
    public func filter(_ query: String) -> JSONTreeFilter {
        var filter = JSONTreeFilter(query: query)
        _ = filter.visit(root, isRoot: true)
        return filter
    }
}

/// The result of a tree search. A matching node shows all of its children; any other node shows only the children
/// that lead to a match.
public struct JSONTreeFilter {
    public let query: String
    private var visible = Set<ObjectIdentifier>()
    private var matched = Set<ObjectIdentifier>()
    /// Matching nodes, not counting those inside another match.
    public private(set) var matchCount = 0

    init(query: String) {
        self.query = query
    }

    public func children(of node: JSONTreeNode) -> [JSONTreeNode] {
        if isInsideMatch(node) { return node.children }
        return node.children.filter { visible.contains(ObjectIdentifier($0)) }
    }

    public func isMatch(_ node: JSONTreeNode) -> Bool {
        matched.contains(ObjectIdentifier(node))
    }

    private func isInsideMatch(_ node: JSONTreeNode) -> Bool {
        var current: JSONTreeNode? = node
        while let checked = current {
            if matched.contains(ObjectIdentifier(checked)) { return true }
            current = checked.parent
        }
        return false
    }

    mutating func visit(_ node: JSONTreeNode, isRoot: Bool = false) -> Bool {
        if !isRoot, node.matches(query) {
            matched.insert(ObjectIdentifier(node))
            visible.insert(ObjectIdentifier(node))
            matchCount += 1
            return true
        }
        var keep = false
        for child in node.children where visit(child) {
            keep = true
        }
        if keep { visible.insert(ObjectIdentifier(node)) }
        return keep
    }
}

public final class JSONTreeNode {
    public enum Kind: String, Sendable {
        case object, array, string, number, boolean, null
    }

    public let kind: Kind
    /// The key or index in the parent; nil for the root.
    public let component: JSONPathComponent?
    public private(set) weak var parent: JSONTreeNode?
    private let source: JSONSource
    let range: Range<Int>
    private var loadedChildren: [JSONTreeNode]?

    fileprivate init(source: JSONSource, range: Range<Int>, component: JSONPathComponent?, parent: JSONTreeNode?) {
        self.source = source
        self.range = range
        self.component = component
        self.parent = parent
        switch source.bytes[range.lowerBound] {
        case UInt8(ascii: "{"): kind = .object
        case UInt8(ascii: "["): kind = .array
        case UInt8(ascii: "\""): kind = .string
        case UInt8(ascii: "t"), UInt8(ascii: "f"): kind = .boolean
        case UInt8(ascii: "n"): kind = .null
        default: kind = .number
        }
    }

    public var isContainer: Bool { kind == .object || kind == .array }

    /// Members of an object or elements of an array, read from the text the first time they are asked for.
    public var children: [JSONTreeNode] {
        if let loadedChildren { return loadedChildren }
        let children = isContainer ? source.children(of: self) : []
        loadedChildren = children
        return children
    }

    public var childCount: Int { isContainer ? children.count : 0 }

    public var pathComponents: [JSONPathComponent] {
        var components: [JSONPathComponent] = []
        var node: JSONTreeNode? = self
        while let current = node, let component = current.component {
            components.append(component)
            node = current.parent
        }
        return components.reversed()
    }

    public var path: String { JSONPath.string(pathComponents) }

    /// The key, `[index]` for array elements, `$` for the root.
    public var label: String {
        switch component {
        case .key(let key)?: return key
        case .index(let index)?: return "[\(index)]"
        case nil: return "$"
        }
    }

    /// The value's JSON text exactly as written.
    public var rawText: String {
        String(decoding: source.bytes[range], as: UTF8.self)
    }

    /// The decoded text of a string value.
    public var stringValue: String? {
        kind == .string ? JSONSource.unescape(source.bytes[(range.lowerBound + 1)..<(range.upperBound - 1)]) : nil
    }

    /// What Copy Value puts on the clipboard: a string's text, or the JSON of anything else.
    public var copyText: String { stringValue ?? rawText }

    /// The value column: a string's text, a number or literal, or the size of an object or array.
    public var summary: String {
        switch kind {
        case .object:
            let count = childCount
            return "{\(count) \(count == 1 ? "key" : "keys")}"
        case .array:
            let count = childCount
            return "[\(count) \(count == 1 ? "item" : "items")]"
        case .string:
            return stringValue ?? ""
        default:
            return rawText
        }
    }

    func matches(_ query: String) -> Bool {
        if case .key(let key)? = component, key.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
        guard !isContainer else { return false }
        return summary.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// The document's UTF-8 bytes, shared by its nodes, with the validating and the skipping scanners.
private final class JSONSource {
    let bytes: [UInt8]

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    // MARK: Validation

    /// The range of the top-level object or array when the whole text is valid JSON.
    func validatedRoot() -> Range<Int>? {
        bytes.withUnsafeBufferPointer { buffer in
            var validator = Validator(bytes: buffer)
            validator.skipWhitespace()
            let start = validator.index
            guard start < buffer.count, buffer[start] == UInt8(ascii: "{") || buffer[start] == UInt8(ascii: "[") else { return nil }
            guard validator.value(depth: 0) else { return nil }
            let end = validator.index
            validator.skipWhitespace()
            return validator.index == buffer.count ? start..<end : nil
        }
    }

    // MARK: Children

    /// Reads the members or elements of a container node. The text is already validated, so this only skips.
    func children(of node: JSONTreeNode) -> [JSONTreeNode] {
        let isObject = node.kind == .object
        let close = isObject ? UInt8(ascii: "}") : UInt8(ascii: "]")
        var ranges: [(JSONPathComponent, Range<Int>)] = []
        bytes.withUnsafeBufferPointer { buffer in
            var index = Self.skipWhitespace(buffer, node.range.lowerBound + 1)
            var position = 0
            while index < node.range.upperBound, buffer[index] != close {
                let component: JSONPathComponent
                if isObject {
                    let keyEnd = Self.skipString(buffer, index)
                    component = .key(Self.unescape(UnsafeBufferPointer(rebasing: buffer[(index + 1)..<(keyEnd - 1)])))
                    index = Self.skipWhitespace(buffer, keyEnd) + 1 // the colon
                    index = Self.skipWhitespace(buffer, index)
                } else {
                    component = .index(position)
                }
                let valueEnd = Self.skipValue(buffer, index)
                ranges.append((component, index..<valueEnd))
                position += 1
                index = Self.skipWhitespace(buffer, valueEnd)
                if index < buffer.count, buffer[index] == UInt8(ascii: ",") {
                    index = Self.skipWhitespace(buffer, index + 1)
                }
            }
        }
        return ranges.map { JSONTreeNode(source: self, range: $0.1, component: $0.0, parent: node) }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0a || byte == 0x0d || byte == 0x09
    }

    private static func skipWhitespace(_ buffer: UnsafeBufferPointer<UInt8>, _ start: Int) -> Int {
        var index = start
        while index < buffer.count, isWhitespace(buffer[index]) { index += 1 }
        return index
    }

    /// From the opening quote to just after the closing one.
    private static func skipString(_ buffer: UnsafeBufferPointer<UInt8>, _ start: Int) -> Int {
        var index = start + 1
        while index < buffer.count {
            switch buffer[index] {
            case UInt8(ascii: "\""): return index + 1
            case UInt8(ascii: "\\"): index += 2
            default: index += 1
            }
        }
        return buffer.count
    }

    private static func skipValue(_ buffer: UnsafeBufferPointer<UInt8>, _ start: Int) -> Int {
        switch buffer[start] {
        case UInt8(ascii: "\""):
            return skipString(buffer, start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var index = start
            while index < buffer.count {
                switch buffer[index] {
                case UInt8(ascii: "\""):
                    index = skipString(buffer, index)
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return index + 1 }
                default:
                    break
                }
                index += 1
            }
            return buffer.count
        default:
            var index = start
            while index < buffer.count {
                let byte = buffer[index]
                if byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") || isWhitespace(byte) { break }
                index += 1
            }
            return index
        }
    }

    // MARK: Strings

    static func unescape(_ slice: ArraySlice<UInt8>) -> String {
        slice.withUnsafeBufferPointer { unescape($0) }
    }

    /// The text of a JSON string's contents (between the quotes), with escapes resolved.
    static func unescape(_ buffer: UnsafeBufferPointer<UInt8>) -> String {
        guard buffer.contains(UInt8(ascii: "\\")) else { return String(decoding: buffer, as: UTF8.self) }
        var output = [UInt8]()
        output.reserveCapacity(buffer.count)
        var index = 0
        func hexValue(at position: Int) -> UInt32? {
            guard position + 4 <= buffer.count else { return nil }
            var value: UInt32 = 0
            for byte in buffer[position..<(position + 4)] {
                guard let digit = hexDigit(byte) else { return nil }
                value = value << 4 | UInt32(digit)
            }
            return value
        }
        while index < buffer.count {
            let byte = buffer[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < buffer.count else {
                output.append(byte)
                index += 1
                continue
            }
            let escape = buffer[index + 1]
            index += 2
            switch escape {
            case UInt8(ascii: "n"): output.append(0x0a)
            case UInt8(ascii: "t"): output.append(0x09)
            case UInt8(ascii: "r"): output.append(0x0d)
            case UInt8(ascii: "b"): output.append(0x08)
            case UInt8(ascii: "f"): output.append(0x0c)
            case UInt8(ascii: "u"):
                guard var code = hexValue(at: index) else { continue }
                index += 4
                if (0xD800...0xDBFF).contains(code), index + 1 < buffer.count, buffer[index] == UInt8(ascii: "\\"), buffer[index + 1] == UInt8(ascii: "u"),
                   let low = hexValue(at: index + 2), (0xDC00...0xDFFF).contains(low) {
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    index += 6
                }
                let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                output.append(contentsOf: Array(String(Character(scalar)).utf8))
            default:
                output.append(escape) // \" \\ \/
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

/// A strict JSON (RFC 8259) checker over UTF-8 bytes.
private struct Validator {
    let bytes: UnsafeBufferPointer<UInt8>
    var index = 0
    /// Deeper documents are refused rather than risking the stack.
    static let maximumDepth = 512

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x0a || byte == 0x0d || byte == 0x09 { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    mutating func value(depth: Int) -> Bool {
        guard depth < Self.maximumDepth, let byte = current else { return false }
        switch byte {
        case UInt8(ascii: "{"):
            return container(close: UInt8(ascii: "}"), depth: depth, keyed: true)
        case UInt8(ascii: "["):
            return container(close: UInt8(ascii: "]"), depth: depth, keyed: false)
        case UInt8(ascii: "\""):
            return string()
        case UInt8(ascii: "t"):
            return literal("true")
        case UInt8(ascii: "f"):
            return literal("false")
        case UInt8(ascii: "n"):
            return literal("null")
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return number()
        default:
            return false
        }
    }

    private mutating func container(close: UInt8, depth: Int, keyed: Bool) -> Bool {
        index += 1
        skipWhitespace()
        if consume(close) { return true }
        while true {
            if keyed {
                guard current == UInt8(ascii: "\""), string() else { return false }
                skipWhitespace()
                guard consume(UInt8(ascii: ":")) else { return false }
                skipWhitespace()
            }
            guard value(depth: depth + 1) else { return false }
            skipWhitespace()
            if consume(UInt8(ascii: ",")) {
                skipWhitespace()
                continue
            }
            return consume(close)
        }
    }

    private mutating func string() -> Bool {
        index += 1
        while let byte = current {
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return true
            case 0..<0x20:
                return false
            case UInt8(ascii: "\\"):
                index += 1
                guard let escape = current else { return false }
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"), UInt8(ascii: "f"),
                     UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                    index += 1
                case UInt8(ascii: "u"):
                    index += 1
                    for _ in 0..<4 {
                        guard let digit = current, JSONSource.hexDigit(digit) != nil else { return false }
                        index += 1
                    }
                default:
                    return false
                }
            default:
                index += 1
            }
        }
        return false
    }

    private mutating func literal(_ word: StaticString) -> Bool {
        let count = word.utf8CodeUnitCount
        guard index + count <= bytes.count else { return false }
        for offset in 0..<count where bytes[index + offset] != word.utf8Start[offset] {
            return false
        }
        index += count
        return true
    }

    private mutating func digits() -> Int {
        let start = index
        while let byte = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
        return index - start
    }

    private mutating func number() -> Bool {
        _ = consume(UInt8(ascii: "-"))
        if consume(UInt8(ascii: "0")) {
            // No leading zeros.
        } else if digits() == 0 {
            return false
        }
        if consume(UInt8(ascii: ".")), digits() == 0 { return false }
        if consume(UInt8(ascii: "e")) || consume(UInt8(ascii: "E")) {
            if !consume(UInt8(ascii: "+")) { _ = consume(UInt8(ascii: "-")) }
            if digits() == 0 { return false }
        }
        return true
    }
}

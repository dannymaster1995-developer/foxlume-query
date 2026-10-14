import Foundation

/// Filters suggestions by the typed prefix (spec 4.3): prefix match, then substring, then fuzzy subsequence.
/// Every step compares UTF-16 units literally, so highlight ranges always index the filter text.
public enum CompletionMatcher {
    public enum Kind: Sendable, Equatable {
        case prefix
        case substring
        case fuzzy
    }

    public struct Match: Sendable, Equatable {
        public var kind: Kind
        /// Added to the score; 0 for prefix and substring matches.
        public var penalty: Int
        /// Matched UTF-16 ranges of the filter text.
        public var ranges: [NSRange]
        /// The filter text equals the prefix.
        public var isExact = false
    }

    /// A typed prefix prepared once per request: lowercased and in composed form (NFC).
    public struct Needle: Sendable {
        let units: [UInt16]

        public init(_ prefix: String) {
            units = Array(prefix.lowercased().precomposedStringWithCanonicalMapping.utf16)
        }

        public var isEmpty: Bool { units.isEmpty }
    }

    /// Matches a lowercased `filterText` against `prefix` (lowercased here). An empty prefix keeps everything.
    public static func match(filterText: String, prefix: String) -> Match? {
        match(filterText: filterText, needle: Needle(prefix))
    }

    public static func match(filterText: String, needle: Needle) -> Match? {
        if needle.isEmpty { return Match(kind: .prefix, penalty: 0, ranges: []) }
        let text = Array(filterText.utf16)
        if let found = literal(text, needle.units) { return found }
        // A name stored decomposed (`e` + U+0301) still matches what was typed. Its units differ from the composed
        // form, so it gets no highlight rather than a wrong one.
        guard filterText.utf8.contains(where: { $0 >= 0x80 }) else { return nil }
        let composed = Array(filterText.precomposedStringWithCanonicalMapping.utf16)
        guard composed != text, var found = literal(composed, needle.units) else { return nil }
        found.ranges = []
        return found
    }

    private static func literal(_ text: [UInt16], _ needle: [UInt16]) -> Match? {
        guard needle.count <= text.count else { return nil }
        if text.starts(with: needle) {
            return Match(kind: .prefix, penalty: 0, ranges: [NSRange(location: 0, length: needle.count)], isExact: text.count == needle.count)
        }
        if let index = firstIndex(of: needle, in: text) {
            return Match(kind: .substring, penalty: 0, ranges: [NSRange(location: index, length: needle.count)])
        }
        return fuzzy(text, needle)
    }

    private static func firstIndex(of needle: [UInt16], in text: [UInt16]) -> Int? {
        guard let first = needle.first else { return 0 }
        var i = 0
        while i + needle.count <= text.count {
            if text[i] == first, text[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }

    /// Every needle unit in order, greedily. Penalty = max(0, 50 + 10 × gaps − 15 × longest run).
    static func fuzzy(_ text: [UInt16], _ needle: [UInt16]) -> Match? {
        guard needle.count <= text.count else { return nil }
        var positions: [Int] = []
        positions.reserveCapacity(needle.count)
        var j = 0
        for (i, unit) in text.enumerated() where j < needle.count && unit == needle[j] {
            positions.append(i)
            j += 1
        }
        guard j == needle.count, let first = positions.first, let last = positions.last else { return nil }
        let gaps = (last - first + 1) - positions.count
        var longestRun = 1
        var run = 1
        var ranges: [NSRange] = []
        var rangeStart = first
        for k in 1..<max(positions.count, 1) {
            if positions[k] == positions[k - 1] + 1 {
                run += 1
            } else {
                ranges.append(NSRange(location: rangeStart, length: positions[k - 1] - rangeStart + 1))
                rangeStart = positions[k]
                run = 1
            }
            longestRun = max(longestRun, run)
        }
        ranges.append(NSRange(location: rangeStart, length: last - rangeStart + 1))
        let penalty = max(0, 50 + 10 * gaps - 15 * longestRun)
        return Match(kind: .fuzzy, penalty: penalty, ranges: ranges)
    }

    /// Maps ranges of the filter text onto the label, which may differ by surrounding quotes (`'active'`). Nothing
    /// when lowercasing changed the label's length (`İ`), since positions would no longer line up.
    public static func highlights(label: String, filterText: String, ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let lowered = label.lowercased()
        let length = label.utf16.count
        guard lowered.utf16.count == length else { return [] }
        var offset = 0
        if !lowered.utf16.elementsEqual(filterText.utf16) {
            let found = (lowered as NSString).range(of: filterText, options: .literal)
            guard found.location != NSNotFound else { return [] }
            offset = found.location
        }
        let mapped = ranges.map { NSRange(location: $0.location + offset, length: $0.length) }
        return mapped.allSatisfy({ NSMaxRange($0) <= length }) ? mapped : []
    }
}

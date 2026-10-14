import Foundation

/// Scores how well a typed query matches a name, for Open Quickly. Every query character must appear in order,
/// ignoring case; the alignment with the best score wins. Matches at the start of the name or of a word (after `_`,
/// `.`, a space or a lowercase-to-uppercase change) and runs of adjacent characters score higher; skipped characters
/// cost a little. Ranges are UTF-16 ranges of the original text, for highlighting.
public enum FuzzyMatcher {
    public struct Match: Equatable, Sendable {
        public var score: Int
        public var ranges: [NSRange]
    }

    static let characterScore = 16
    static let startBonus = 32
    static let wordStartBonus = 24
    static let adjacentBonus = 18
    static let gapPenalty = 2
    static let leadingGapPenalty = 1
    static let maximumLeadingPenalty = 12
    static let exactBonus = 120
    static let prefixBonus = 48

    /// Nil when some query character is missing. An empty query matches everything with score 0.
    public static func match(_ query: String, in text: String) -> Match? {
        let needle = Array(query.lowercased().utf16).filter { $0 != 32 }
        guard !needle.isEmpty else { return Match(score: 0, ranges: []) }
        let original = Array(text.utf16)
        let lowered = Array(text.lowercased().utf16)
        // Lowercasing that changes the length (`İ`) would shift every position; compare the original then.
        let haystack = lowered.count == original.count ? lowered : original
        let n = haystack.count
        let m = needle.count
        guard m <= n, isSubsequence(needle, of: haystack) else { return nil }

        let bonus = (0..<n).map { boundaryBonus(at: $0, in: original) }
        let unset = Int.min / 4
        // score[i][j]: best total with needle[i] placed on haystack[j]; from[i][j]: where needle[i - 1] was placed.
        var score = [[Int]](repeating: [Int](repeating: unset, count: n), count: m)
        var from = [[Int]](repeating: [Int](repeating: -1, count: n), count: m)
        for j in 0..<n where haystack[j] == needle[0] {
            score[0][j] = characterScore + bonus[j] - min(maximumLeadingPenalty, j * leadingGapPenalty)
        }
        if m > 1 {
            for i in 1..<m {
                // Best earlier placement two or more positions back, with the gap cost folded in as `+ penalty * k`.
                var bestFar = unset
                var bestFarIndex = -1
                for j in 1..<n {
                    let far = j - 2
                    if far >= 0, score[i - 1][far] > unset {
                        let candidate = score[i - 1][far] + gapPenalty * far
                        if candidate > bestFar {
                            bestFar = candidate
                            bestFarIndex = far
                        }
                    }
                    guard haystack[j] == needle[i] else { continue }
                    var best = unset
                    var origin = -1
                    if score[i - 1][j - 1] > unset {
                        best = score[i - 1][j - 1] + adjacentBonus
                        origin = j - 1
                    }
                    if bestFarIndex >= 0 {
                        let gapped = bestFar - gapPenalty * (j - 1)
                        if gapped > best {
                            best = gapped
                            origin = bestFarIndex
                        }
                    }
                    guard origin >= 0 else { continue }
                    score[i][j] = best + characterScore + bonus[j]
                    from[i][j] = origin
                }
            }
        }

        var end = -1
        var total = unset
        for j in 0..<n where score[m - 1][j] > total {
            total = score[m - 1][j]
            end = j
        }
        guard end >= 0 else { return nil }
        var positions = [Int](repeating: 0, count: m)
        var j = end
        for i in stride(from: m - 1, through: 0, by: -1) {
            positions[i] = j
            j = from[i][j]
        }
        if positions.first == 0, positions.last == m - 1 {
            total += m == n ? exactBonus : prefixBonus
        }
        // Among equal matches the shorter name wins.
        total -= min(20, (n - m) / 4)
        return Match(score: total, ranges: ranges(of: positions))
    }

    private static func isSubsequence(_ needle: [UInt16], of haystack: [UInt16]) -> Bool {
        var i = 0
        for unit in haystack where i < needle.count && unit == needle[i] {
            i += 1
        }
        return i == needle.count
    }

    private static func boundaryBonus(at index: Int, in text: [UInt16]) -> Int {
        if index == 0 { return startBonus }
        let previous = text[index - 1]
        let current = text[index]
        if isSeparator(previous) { return wordStartBonus }
        if isLower(previous), isUpper(current) { return wordStartBonus }
        if isDigit(current), !isDigit(previous) { return wordStartBonus / 2 }
        return 0
    }

    private static func isSeparator(_ unit: UInt16) -> Bool {
        // space _ - . / : ( , "
        [32, 95, 45, 46, 47, 58, 40, 44, 34].contains(unit)
    }

    private static func isLower(_ unit: UInt16) -> Bool { unit >= 97 && unit <= 122 }
    private static func isUpper(_ unit: UInt16) -> Bool { unit >= 65 && unit <= 90 }
    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }

    private static func ranges(of positions: [Int]) -> [NSRange] {
        var ranges: [NSRange] = []
        for position in positions {
            if let last = ranges.last, NSMaxRange(last) == position {
                ranges[ranges.count - 1].length += 1
            } else {
                ranges.append(NSRange(location: position, length: 1))
            }
        }
        return ranges
    }
}

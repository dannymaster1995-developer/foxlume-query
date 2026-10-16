import Foundation

/// Type-to-filter over a grid's column names, for Jump to Column and the Columns list.
public enum ColumnNameMatch {
    /// Indexes of the names that contain `query` (case and diacritics ignored): exact matches first, then names that
    /// start with it, then names with a word (after `_`, a space or a case change) that starts with it, then the rest;
    /// each group keeps the given order. An empty query matches every name.
    public static func rank(_ names: [String], query: String) -> [Int] {
        let needle = fold(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return Array(names.indices) }
        var groups: [[Int]] = [[], [], [], []]
        for (index, name) in names.enumerated() {
            let folded = fold(name)
            guard folded.contains(needle) else { continue }
            if folded == needle {
                groups[0].append(index)
            } else if folded.hasPrefix(needle) {
                groups[1].append(index)
            } else if wordStarts(in: name).contains(where: { fold(String(name[$0...])).hasPrefix(needle) }) {
                groups[2].append(index)
            } else {
                groups[3].append(index)
            }
        }
        return groups.flatMap { $0 }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Where words begin inside a name: after a separator, or at an upper-case letter that follows a lower-case one.
    private static func wordStarts(in name: String) -> [String.Index] {
        var starts: [String.Index] = []
        var previous: Character?
        for index in name.indices {
            let character = name[index]
            if let previous {
                let afterSeparator = "_- .".contains(previous) && !"_- .".contains(character)
                let camel = previous.isLowercase && character.isUppercase
                if afterSeparator || camel { starts.append(index) }
            }
            previous = character
        }
        return starts
    }
}

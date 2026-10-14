import Foundation

/// Matching, ordering and favorite rows shared by the MongoDB and Redis completers. Both match the typed prefix
/// as a case-insensitive prefix or substring of the label, never fuzzily (spec 8.5).
enum ShellCompletionMatcher {
    enum Match: Int, Comparable {
        case exact
        case prefix
        case substring

        static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How `item` matches `prefix` (already lowercased), with the label range to draw bold.
    /// An empty prefix matches everything without a highlight.
    static func match(_ item: CompletionItem, lowercasedPrefix prefix: String) -> (match: Match, highlight: NSRange?)? {
        guard !prefix.isEmpty else { return (.prefix, nil) }
        let text = item.filterText as NSString
        let found = text.range(of: prefix, options: .literal)
        guard found.location != NSNotFound else { return nil }
        let match: Match = found.location > 0 ? .substring : (found.length == text.length ? .exact : .prefix)
        // Lowercasing can change the length of some scripts; then the offsets no longer fit the label.
        let highlight = (item.label as NSString).length == text.length ? found : nil
        return (match, highlight)
    }

    /// Keeps the items matching `prefix`, highlighted, as (item, match, generation index).
    static func matches(_ items: [CompletionItem], prefix: String) -> [(item: CompletionItem, match: Match, index: Int)] {
        let lowered = prefix.lowercased()
        var kept: [(item: CompletionItem, match: Match, index: Int)] = []
        for (index, original) in items.enumerated() {
            guard let found = match(original, lowercasedPrefix: lowered) else { continue }
            var item = original
            item.highlights = found.highlight.map { [$0] } ?? []
            kept.append((item, found.match, index))
        }
        return kept
    }

    /// Drops repeated (label, kind, insert text) rows, keeping the better priority in the first row's place (spec A.9).
    static func deduplicated(_ items: [CompletionItem]) -> [CompletionItem] {
        struct Key: Hashable {
            var label: String
            var kind: CompletionKind
            var insertText: String
        }
        var result: [CompletionItem] = []
        var positions: [Key: Int] = [:]
        for item in items {
            let key = Key(label: item.label, kind: item.kind, insertText: item.insertText)
            if let index = positions[key] {
                if item.priority < result[index].priority { result[index] = item }
                continue
            }
            positions[key] = result.count
            result.append(item)
        }
        return result
    }

    /// Plain code-point order, so uppercase letters sort before lowercase ones (`$geoIntersects` < `$geometry`).
    static func codePointPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars) { $0.value < $1.value }
    }

    /// A saved query as a row: label = keyword, detail = name, preview = start of the query.
    /// The first `;;` marks where the caret lands and is removed (spec 5.2, 7).
    static func favoriteItem(_ favorite: CompletionFavorite) -> CompletionItem {
        var query = favorite.query
        var caretFromEnd = 0
        if let marker = query.range(of: ";;") {
            caretFromEnd = query[marker.upperBound...].utf16.count
            query.removeSubrange(marker)
        } else if query.hasSuffix("()") {
            caretFromEnd = 1
        }
        return CompletionItem(
            label: favorite.keyword,
            kind: .favorite,
            detail: favorite.name,
            documentation: String(query.prefix(200)),
            insertText: query,
            caretOffsetFromEnd: caretFromEnd
        )
    }
}

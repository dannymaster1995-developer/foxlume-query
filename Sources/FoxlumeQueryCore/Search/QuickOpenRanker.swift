import Foundation

public struct QuickOpenRow: Sendable, Equatable {
    public var item: QuickOpenItem
    /// UTF-16 ranges of the title to draw in bold.
    public var highlights: [NSRange]
    public var score: Double
}

public struct QuickOpenSection: Sendable, Equatable {
    /// Nil for the single list shown while typing.
    public var title: String?
    public var rows: [QuickOpenRow]
}

/// Filters and orders Open Quickly rows. With nothing typed: "Recent" first, then a section per kind (in the All
/// scope only Recent, unless nothing was opened yet). While typing: one list, best match first.
public enum QuickOpenRanker {
    public static let recentLimit = 10
    public static let resultLimit = 200

    /// - Parameters:
    ///   - frecency: 0…1 per item key of the current connection (see `QuickOpenFrecencyStore`).
    ///   - recent: keys of the current connection, most recently opened first.
    public static func sections(items: [QuickOpenItem], query: String, scope: QuickOpenScope,
                                frecency: [String: Double] = [:], recent: [String] = []) -> [QuickOpenSection] {
        let candidates = items.filter(scope.includes)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty else {
            let rows = candidates.compactMap { row(for: $0, query: trimmed, frecency: frecency) }
            let sorted = rows.sorted(by: ranks).prefix(resultLimit)
            return sorted.isEmpty ? [] : [QuickOpenSection(title: nil, rows: Array(sorted))]
        }
        if scope == .connections {
            return connectionSections(candidates)
        }

        var sections: [QuickOpenSection] = []
        let current = candidates.filter(\.isCurrentConnection)
        var byKey: [String: QuickOpenItem] = [:]
        for item in current where byKey[item.key] == nil { byKey[item.key] = item }
        let recentItems = recent.compactMap { byKey[$0] }.prefix(recentLimit)
        if !recentItems.isEmpty {
            sections.append(QuickOpenSection(title: "Recent", rows: recentItems.map { QuickOpenRow(item: $0, highlights: [], score: 0) }))
            if scope == .all { return sections }
        }
        let shown = Set(recentItems.map(\.id))
        for kind in QuickOpenKind.allCases {
            var members = candidates.filter { $0.kind == kind && !shown.contains($0.id) }
            guard !members.isEmpty else { continue }
            if kind != .history {
                // History keeps its newest-first order; everything else lists the browsed schema first, then A–Z.
                members.sort { lhs, rhs in
                    if lhs.isCurrentConnection != rhs.isCurrentConnection { return lhs.isCurrentConnection }
                    if lhs.isOutsideCurrentScope != rhs.isOutsideCurrentScope { return !lhs.isOutsideCurrentScope }
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
            }
            sections.append(QuickOpenSection(title: kind.sectionTitle, rows: members.prefix(resultLimit).map { QuickOpenRow(item: $0, highlights: [], score: 0) }))
        }
        return sections
    }

    /// Every open connection's tables under its name, connections and tables A–Z.
    private static func connectionSections(_ items: [QuickOpenItem]) -> [QuickOpenSection] {
        let grouped = Dictionary(grouping: items.prefix(5_000), by: \.connectionID)
        var budget = resultLimit
        var sections: [QuickOpenSection] = []
        let ordered = grouped.values.sorted { lhs, rhs in
            let left = lhs.first!, right = rhs.first!
            if left.isCurrentConnection != right.isCurrentConnection { return left.isCurrentConnection }
            return left.connectionName.localizedStandardCompare(right.connectionName) == .orderedAscending
        }
        for members in ordered where budget > 0 {
            let sorted = members.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.prefix(budget)
            budget -= sorted.count
            sections.append(QuickOpenSection(title: members[0].connectionName, rows: sorted.map { QuickOpenRow(item: $0, highlights: [], score: 0) }))
        }
        return sections
    }

    /// Best score first; ties by kind, then the shorter title, then A–Z.
    private static func ranks(_ lhs: QuickOpenRow, _ rhs: QuickOpenRow) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.item.kind != rhs.item.kind { return lhs.item.kind < rhs.item.kind }
        if lhs.item.title.count != rhs.item.title.count { return lhs.item.title.count < rhs.item.title.count }
        return lhs.item.title.localizedStandardCompare(rhs.item.title) == .orderedAscending
    }

    /// The item's row for `query`, or nil when it does not match.
    public static func row(for item: QuickOpenItem, query: String, frecency: [String: Double] = [:]) -> QuickOpenRow? {
        guard let (base, highlights) = matchScore(item, query: query) else { return nil }
        var score = Double(max(1, base)) * item.kind.weight
        if item.isCurrentConnection { score *= 1 + 0.5 * min(1, max(0, frecency[item.key] ?? 0)) }
        if item.isOpen { score *= 1.2 }
        if item.isOutsideCurrentScope { score *= 0.97 }
        return QuickOpenRow(item: item, highlights: highlights, score: score)
    }

    /// The better of the plain reading and, for `schema.table`, the dotted one. Highlights are title ranges, and
    /// only when the title produced the score.
    static func matchScore(_ item: QuickOpenItem, query: String) -> (Int, [NSRange])? {
        var best: (Int, [NSRange])?
        func consider(_ score: Int, _ ranges: [NSRange]) {
            if best == nil || score > best!.0 { best = (score, ranges) }
        }
        if let title = FuzzyMatcher.match(query, in: item.title), item.kind != .history || !isScattered(title, query: query) {
            consider(title.score, title.ranges)
        }
        if let keyword = item.keyword, let match = FuzzyMatcher.match(query, in: keyword) {
            consider(match.score, [])
        }
        // Subtitles that name a place (schema, connection, folder); "Current schema" or a run time would only add noise.
        if item.kind.isTableLike || item.kind == .savedQuery, !item.subtitle.isEmpty, let match = FuzzyMatcher.match(query, in: item.subtitle) {
            consider(Int(Double(match.score) * 0.6), [])
        }
        if let dot = query.lastIndex(of: "."), let container = item.container {
            let containerPart = unquoted(String(query[..<dot]))
            let namePart = unquoted(String(query[query.index(after: dot)...]))
            let containerMatch = containerPart.isEmpty ? FuzzyMatcher.Match(score: 0, ranges: []) : FuzzyMatcher.match(containerPart, in: container)
            let nameMatch = namePart.isEmpty ? FuzzyMatcher.Match(score: 1, ranges: []) : FuzzyMatcher.match(namePart, in: item.title)
            if let containerMatch, let nameMatch {
                consider(nameMatch.score + containerMatch.score / 2, nameMatch.ranges)
            }
        }
        return best
    }

    /// A long statement contains almost any letters in order; a history match must come in a few runs.
    private static func isScattered(_ match: FuzzyMatcher.Match, query: String) -> Bool {
        match.ranges.count > max(2, query.filter { !$0.isWhitespace }.count / 3)
    }

    /// `"public"` → `public`: quotes typed around a name part are not part of it.
    private static func unquoted(_ text: String) -> String {
        let quotes = CharacterSet(charactersIn: "\"`[]")
        // A database-qualified search (`db.schema.`) matches the last container only.
        let last = text.split(separator: ".").last.map(String.init) ?? text
        return last.trimmingCharacters(in: quotes.union(.whitespaces))
    }
}

import Foundation

/// Scoring, de-duplication and limits (spec 4.4–4.5). Lower scores rank first; ties keep generation order.
enum SQLCompletionRanking {
    /// Clauses where table names get the typing bonus.
    static let objectClauses: Set<SQLClause> = [.from, .join, .into, .dropObject, .createIndex]
    /// Clauses where column names get the typing bonus.
    static let columnClauses: Set<SQLClause> = [.selectList, .whereClause, .and, .on, .having, .groupBy, .orderBy, .returning, .using, .window]
    /// Assignment-like clauses, where columns are almost always what comes next.
    static let assignmentClauses: Set<SQLClause> = [.set, .insertColumns]
    /// The schema-heavy clauses that show 40 rows; the rest show 20.
    static let wideClauses: Set<SQLClause> = [
        .from, .join, .into, .dropObject, .createIndex, .selectList, .whereClause, .and, .on, .having, .groupBy,
        .orderBy, .set, .insertColumns, .returning, .using,
    ]

    static func limit(for clause: SQLClause) -> Int {
        wideClauses.contains(clause) ? 40 : 20
    }

    private struct Key: Hashable {
        var label: String
        var kind: CompletionKind
        var insertText: String
    }

    private struct Scored {
        var item: CompletionItem
        var score: Int
        var order: Int
        var ranges: [NSRange]
    }

    /// Filters `items` by `prefix`, scores them, drops duplicates (same label, kind and insert text; the better
    /// score wins, spec A.9), sorts, and keeps the first `keep`. Highlights are set on the returned items only, since
    /// a large schema can produce thousands of rows that are never shown.
    static func rank(_ items: [CompletionItem], prefix: String, state: CompletionRefilterState, keep: Int = .max) -> [CompletionItem] {
        let clause = SQLClause(rawValue: state.context) ?? .unknown
        let needle = CompletionMatcher.Needle(prefix)
        var scored: [Scored] = []
        scored.reserveCapacity(items.count)
        var slots: [Key: Int] = [:]
        for (order, item) in items.enumerated() {
            guard let match = CompletionMatcher.match(filterText: item.filterText, needle: needle) else { continue }
            // Favorites are offered only while the token starts their keyword (spec 7), also when re-filtering.
            if item.kind == .favorite, !needle.isEmpty, match.kind != .prefix { continue }
            var score = item.priority + match.penalty
            if !needle.isEmpty, match.kind == .prefix {
                score -= 500
                if match.isExact { score -= 1000 }
            }
            score += adjustment(for: item.kind, clause: clause, prefixIsEmpty: needle.isEmpty, state: state)
            score += item.label.utf16.count

            let key = Key(label: item.label, kind: item.kind, insertText: item.insertText)
            guard let slot = slots[key] else {
                slots[key] = scored.count
                scored.append(Scored(item: item, score: score, order: order, ranges: match.ranges))
                continue
            }
            // Keep the better-scored copy, borrowing the other's detail or documentation when it has none.
            let other = scored[slot].item
            if score < scored[slot].score {
                var better = item
                if better.detail == nil { better.detail = other.detail }
                if better.documentation == nil { better.documentation = other.documentation }
                scored[slot] = Scored(item: better, score: score, order: order, ranges: match.ranges)
            } else {
                if other.detail == nil { scored[slot].item.detail = item.detail }
                if other.documentation == nil { scored[slot].item.documentation = item.documentation }
            }
        }
        scored.sort { $0.score != $1.score ? $0.score < $1.score : $0.order < $1.order }
        return scored.prefix(keep).map { entry in
            var item = entry.item
            item.highlights = CompletionMatcher.highlights(label: item.label, filterText: item.filterText, ranges: entry.ranges)
            return item
        }
    }

    /// Clause bonus (spec 4.4). With nothing typed and tables in scope, either object names (in a table slot) or
    /// clause keywords surface; otherwise the clause's natural kind leads.
    static func adjustment(for kind: CompletionKind, clause: SQLClause, prefixIsEmpty: Bool, state: CompletionRefilterState) -> Int {
        if prefixIsEmpty, state.hasTablesInScope, !state.isAfterComma {
            if state.expectsObjectName {
                return [.table, .view, .schema, .database].contains(kind) ? -300 : 0
            }
            return kind == .keyword ? -300 : 0
        }
        if objectClauses.contains(clause) { return kind == .table || kind == .view ? -200 : 0 }
        if columnClauses.contains(clause) { return kind == .column ? -200 : 0 }
        if assignmentClauses.contains(clause) { return kind == .column ? -300 : 0 }
        return 0
    }
}

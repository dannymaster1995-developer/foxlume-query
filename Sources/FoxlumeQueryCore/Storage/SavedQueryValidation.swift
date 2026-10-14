import Foundation

/// Checks for the Saved Query sheet. Errors block saving; warnings are only shown.
public enum SavedQueryValidation {
    public enum Field: Sendable, Equatable {
        case name
        case sql
        case keyword
    }

    public struct Issue: Sendable, Equatable {
        public var field: Field
        public var isError: Bool
        public var message: String
    }

    /// The keyword as stored: trimmed, nil when blank.
    public static func normalizedKeyword(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Everything wrong with these values. `scope` is the connection the query will belong to (nil: every
    /// connection); `editing` is the query being changed, which never clashes with itself.
    public static func issues(name: String, sql: String, keyword: String?, scope: UUID?, editing: UUID?, in library: SavedQueryLibrary) -> [Issue] {
        var issues: [Issue] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(Issue(field: .name, isError: true, message: "Enter a name."))
        }
        if sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(Issue(field: .sql, isError: true, message: "The query is empty."))
        }
        guard let keyword = normalizedKeyword(keyword) else { return issues }
        if keyword.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            issues.append(Issue(field: .keyword, isError: true, message: "A keyword cannot contain spaces."))
        } else if let owner = keywordOwner(keyword, scope: scope, editing: editing, in: library) {
            issues.append(Issue(field: .keyword, isError: true, message: "“\(owner.keyword ?? keyword)” is already the keyword of “\(owner.name)”."))
        } else if SQLCompletionReservedWords.isEngineReserved(keyword.uppercased(), family: nil) {
            issues.append(Issue(field: .keyword, isError: false, message: "“\(keyword)” is also an SQL keyword; typing it will offer this query too."))
        }
        return issues
    }

    public static func canSave(_ issues: [Issue]) -> Bool {
        !issues.contains { $0.isError }
    }

    /// The query that already uses `keyword` where this scope would see it, ignoring case: a query for one
    /// connection clashes with that connection's and with every-connection ones; an every-connection query
    /// clashes with all of them.
    public static func keywordOwner(_ keyword: String, scope: UUID?, editing: UUID?, in library: SavedQueryLibrary) -> SavedQuery? {
        let wanted = keyword.lowercased()
        return library.queries.first { query in
            guard query.id != editing, query.keyword?.lowercased() == wanted else { return false }
            return scope == nil || query.connectionID == nil || query.connectionID == scope
        }
    }

    /// A name for a new saved query: the first line with text, or the text of a leading `--` comment, cut to
    /// 50 characters. "Untitled" when there is nothing usable.
    public static func suggestedName(for sql: String) -> String {
        for rawLine in sql.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("--") {
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            return line.count > 50 ? String(line.prefix(50)).trimmingCharacters(in: .whitespaces) : line
        }
        return "Untitled"
    }
}

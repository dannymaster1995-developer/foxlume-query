import Foundation

/// Reserved words for alias rejection (spec A.4) and quoting on insert (spec A.2). The engines' own lists come from
/// the vocabulary; this adds the words that follow a table and open the next clause somewhere.
enum SQLCompletionReservedWords {
    /// Clause words that can never start or continue a table path.
    static let clauseWords: Set<String> = [
        "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS",
        "NATURAL", "ON", "USING", "UNION", "INTERSECT", "EXCEPT", "RETURNING", "SET", "WINDOW", "FETCH", "FOR",
        "SELECT", "FROM", "AS", "AND", "OR", "VALUES", "INTO",
    ]

    /// Words that can follow a table reference in some engine, so a bare one is never its alias, even where that
    /// engine does not reserve it (MySQL index hints, DuckDB joins and PIVOT, sampling, locking).
    static let tableFollowers: Set<String> = clauseWords.union([
        "OUTER", "LATERAL", "STRAIGHT_JOIN", "QUALIFY", "ASOF", "POSITIONAL", "SEMI", "ANTI", "PIVOT", "UNPIVOT",
        "SAMPLE", "TABLESAMPLE", "LOCK", "USE", "FORCE", "IGNORE", "PARTITION", "WITH",
    ])

    /// Every supported engine's reserved words, for when the engine is unknown.
    private static let anyEngine: Set<String> = [SQLDialect.Family.mysql, .postgresql, .sqlite, .duckdb]
        .reduce(into: Set<String>()) { $0.formUnion(SQLCompletionVocabulary.reservedWords($1)) }

    /// Reserved by this engine, or by any engine when it is unknown.
    static func isEngineReserved(_ uppercased: String, family: SQLDialect.Family?) -> Bool {
        guard let family else { return anyEngine.contains(uppercased) }
        return SQLCompletionVocabulary.reservedWords(family).contains(uppercased)
    }

    /// True when a bare `uppercased` word after a table is not its alias (spec A.4).
    static func rejectsAlias(_ uppercased: String, family: SQLDialect.Family?) -> Bool {
        tableFollowers.contains(uppercased) || isEngineReserved(uppercased, family: family)
    }

    /// Reserved in this engine, so the bare name would not parse (spec A.2). Without an engine, only the words
    /// every engine reserves.
    static func isReserved(_ uppercased: String, family: SQLDialect.Family?) -> Bool {
        SQLCompletionVocabulary.reservedWords(family).contains(uppercased)
    }
}

/// Identifier quoting on insert (spec 5.1 / A.2).
enum SQLIdentifierQuoting {
    /// ` for MySQL/MariaDB, " for PostgreSQL, SQLite and DuckDB; nil without a dialect.
    static func quoteCharacter(_ family: SQLDialect.Family?) -> Character? {
        switch family {
        case .mysql: return "`"
        case .postgresql, .sqlite, .duckdb: return "\""
        case nil: return nil
        }
    }

    /// True when the bare name would not parse as that identifier.
    static func needsQuoting(_ name: String, family: SQLDialect.Family?) -> Bool {
        guard !name.isEmpty else { return false }
        // ASCII names, nearly all of them, are checked byte by byte; schemas can hold tens of thousands.
        var hasUppercase = false
        var isASCII = true
        var isFirst = true
        for byte in name.utf8 {
            if byte >= 0x80 {
                isASCII = false
                break
            }
            let digit = byte >= 48 && byte <= 57
            if digit && isFirst { return true }
            isFirst = false
            if byte >= 65 && byte <= 90 {
                hasUppercase = true
            } else if !(digit || (byte >= 97 && byte <= 122) || byte == 95) {
                return true
            }
        }
        if !isASCII {
            guard let first = name.first, !first.isNumber else { return true }
            if name.contains(where: { $0 != "_" && !$0.isLetter && !$0.isNumber }) { return true }
            hasUppercase = name.contains { $0.isUppercase }
        }
        if SQLCompletionReservedWords.isReserved(name.uppercased(), family: family) { return true }
        // PostgreSQL folds bare names to lowercase, so any capital needs quotes to survive.
        return family == .postgresql && hasUppercase
    }

    static func quoted(_ name: String, with quote: Character) -> String {
        let q = String(quote)
        return q + name.replacingOccurrences(of: q, with: q + q) + q
    }

    /// The text to insert for a name. `typedQuote` is the quote the user opened the token with, if any.
    static func insertText(for name: String, family: SQLDialect.Family?, typedQuote: Character?) -> String {
        guard typedQuote != nil || needsQuoting(name, family: family) else { return name }
        // Without a dialect, reuse what the user typed; standard SQL double quotes otherwise.
        let quote: Character = quoteCharacter(family) ?? typedQuote ?? "\""
        return quoted(name, with: quote)
    }

    /// Quotes each segment of `a.b` as needed (labels such as `u.user_name`).
    static func insertText(forPath segments: [String], family: SQLDialect.Family?, typedQuote: Character?) -> String {
        segments.map { insertText(for: $0, family: family, typedQuote: typedQuote) }.joined(separator: ".")
    }
}

import Foundation

/// Text and pattern conditions of the filter bar, spelled for each engine.
extension SQLDialect {
    /// Where the value must appear for contains, starts with and ends with.
    public enum TextPosition: Sendable {
        case anywhere
        case start
        case end
    }

    /// `column` as text contains, starts or ends with `value`, which is matched literally.
    /// Without `matchCase` case is ignored on every engine (ILIKE, or LIKE under a case-insensitive collation).
    /// With it: LIKE on PostgreSQL and DuckDB, a binary collation on MySQL and MariaDB, GLOB on SQLite.
    public func textMatch(_ column: String, _ value: String, at position: TextPosition, negate: Bool, matchCase: Bool) -> String {
        let operand = textCast(column)
        let not = negate ? "NOT " : ""
        if matchCase, family == .sqlite {
            // GLOB is case-sensitive; its wildcards are escaped by putting them in brackets.
            let glob = Self.wrap(Self.escapeGlob(value), with: "*", at: position)
            return "\(operand) \(not)GLOB \(quoteString(glob))"
        }
        let pattern = Self.wrap(FilterRule.escapeLike(value), with: "%", at: position)
        let escape = family == .sqlite || family == .duckdb ? " ESCAPE '\\'" : ""
        switch (family, matchCase) {
        case (.mysql, true):
            // The connection speaks utf8mb4, so its binary collation applies to both MySQL and MariaDB.
            return "\(operand) \(not)LIKE \(quoteString(pattern)) COLLATE utf8mb4_bin"
        case (.postgresql, true), (.duckdb, true):
            return "\(operand) \(not)LIKE \(quoteString(pattern))\(escape)"
        default:
            return "\(operand) \(not)\(caseInsensitiveLike) \(quoteString(pattern))\(escape)"
        }
    }

    /// `column` as text matches the regular expression `pattern`, ignoring case unless `matchCase` is set.
    /// SQLite has no REGEXP of its own; Foxlume registers one on every SQLite connection (ICU syntax).
    public func regexMatch(_ column: String, pattern: String, matchCase: Bool) -> String {
        let operand = textCast(column)
        switch family {
        case .postgresql:
            return "\(operand) \(matchCase ? "~" : "~*") \(quoteString(pattern))"
        case .mysql:
            // REGEXP follows the collation: the connection's utf8mb4_general_ci ignores case, utf8mb4_bin does not.
            return matchCase ? "\(operand) COLLATE utf8mb4_bin REGEXP \(quoteString(pattern))" : "\(operand) REGEXP \(quoteString(pattern))"
        case .sqlite:
            return "\(operand) REGEXP \(quoteString(matchCase ? pattern : "(?i)" + pattern))"
        case .duckdb:
            return matchCase ? "regexp_matches(\(operand), \(quoteString(pattern)))" : "regexp_matches(\(operand), \(quoteString(pattern)), 'i')"
        }
    }

    private static func wrap(_ escaped: String, with wildcard: String, at position: TextPosition) -> String {
        switch position {
        case .anywhere: return wildcard + escaped + wildcard
        case .start: return escaped + wildcard
        case .end: return wildcard + escaped
        }
    }

    /// GLOB has no escape character: `*`, `?` and `[` become one-character classes.
    static func escapeGlob(_ value: String) -> String {
        var out = ""
        for character in value {
            switch character {
            case "*", "?", "[": out += "[\(character)]"
            default: out.append(character)
            }
        }
        return out
    }
}

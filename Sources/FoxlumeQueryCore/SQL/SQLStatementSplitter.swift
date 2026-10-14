import Foundation

/// One statement inside a larger SQL text. `range` is in UTF-16 units so editors can use it directly.
public struct SQLStatementRange: Hashable, Sendable {
    public var range: NSRange
    public var text: String
}

/// Splits SQL text on `;` while respecting quotes, comments and PostgreSQL dollar quoting.
public enum SQLStatementSplitter {
    public static func split(_ sql: String, family: SQLDialect.Family = .postgresql) -> [SQLStatementRange] {
        let units = Array(sql.utf16)
        var statements: [SQLStatementRange] = []
        var start = 0
        var index = 0
        let count = units.count

        func emit(upTo end: Int) {
            let range = NSRange(location: start, length: end - start)
            let text = (sql as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, !isOnlyComments(text, family: family) {
                statements.append(SQLStatementRange(range: trimmedRange(range, in: units), text: text))
            }
        }

        while index < count {
            let c = units[index]
            switch c {
            case 0x27, 0x22, 0x60: // ' " `
                index = skipQuoted(units, from: index, quote: c, backslash: family == .mysql && c != 0x60)
            case 0x2D where index + 1 < count && units[index + 1] == 0x2D: // --
                index = skipLine(units, from: index)
            case 0x23 where family == .mysql: // #
                index = skipLine(units, from: index)
            case 0x2F where index + 1 < count && units[index + 1] == 0x2A: // /*
                index = skipBlockComment(units, from: index, nested: family == .postgresql)
            case 0x24 where family == .postgresql || family == .duckdb: // $tag$
                if let end = skipDollarQuoted(units, from: index) {
                    index = end
                } else {
                    index += 1
                }
            case 0x3B: // ;
                emit(upTo: index)
                index += 1
                start = index
            default:
                index += 1
            }
        }
        emit(upTo: count)
        return statements
    }

    /// The statement containing `location` (a UTF-16 offset), or the closest one before it.
    public static func statement(at location: Int, in sql: String, family: SQLDialect.Family) -> SQLStatementRange? {
        let statements = split(sql, family: family)
        if let match = statements.first(where: { location >= $0.range.location && location <= NSMaxRange($0.range) }) {
            return match
        }
        return statements.last(where: { NSMaxRange($0.range) <= location }) ?? statements.first
    }

    private static func trimmedRange(_ range: NSRange, in units: [UInt16]) -> NSRange {
        var lower = range.location
        var upper = NSMaxRange(range)
        while lower < upper, isWhitespace(units[lower]) { lower += 1 }
        while upper > lower, isWhitespace(units[upper - 1]) { upper -= 1 }
        return NSRange(location: lower, length: upper - lower)
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }

    private static func isOnlyComments(_ text: String, family: SQLDialect.Family) -> Bool {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let c = units[index]
            if isWhitespace(c) {
                index += 1
            } else if c == 0x2D, index + 1 < units.count, units[index + 1] == 0x2D {
                index = skipLine(units, from: index)
            } else if c == 0x23, family == .mysql {
                index = skipLine(units, from: index)
            } else if c == 0x2F, index + 1 < units.count, units[index + 1] == 0x2A {
                // MySQL runs `/*! … */` (and MariaDB `/*M! … */`) as code; mysqldump wraps statements in them.
                if family == .mysql, isExecutableComment(units, at: index) { return false }
                index = skipBlockComment(units, from: index, nested: family == .postgresql)
            } else {
                return false
            }
        }
        return true
    }

    /// `/*!` or `/*M!` at `index`.
    private static func isExecutableComment(_ units: [UInt16], at index: Int) -> Bool {
        guard index + 2 < units.count else { return false }
        if units[index + 2] == 0x21 { return true }
        return units[index + 2] == 0x4D && index + 3 < units.count && units[index + 3] == 0x21
    }

    /// "UPDATE" or "DELETE" when the statement changes every row of its table: it has no WHERE
    /// at the top level (a WHERE inside a subquery does not count). Nil otherwise.
    public static func unboundedWrite(_ statement: String) -> String? {
        let code = strippingComments(statement)
        let units = Array(code.utf16)
        var words: [String] = []
        var depth = 0
        var index = 0
        var current = ""
        func flush() {
            if !current.isEmpty, depth == 0 { words.append(current.uppercased()) }
            current = ""
        }
        while index < units.count {
            let c = units[index]
            if c == 0x27 || c == 0x22 || c == 0x60 {
                flush()
                index = skipQuoted(units, from: index, quote: c, backslash: false)
                continue
            }
            if c == 0x28 { flush(); depth += 1 } else if c == 0x29 { flush(); depth = max(0, depth - 1) }
            else if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 { current.append(Character(UnicodeScalar(c)!)) }
            else { flush() }
            index += 1
        }
        flush()
        guard let first = words.first, first == "UPDATE" || first == "DELETE" else { return nil }
        return words.contains("WHERE") ? nil : first
    }

    /// Removes `--`, `#` and `/* */` comments outside quotes, so classification sees only SQL.
    static func strippingComments(_ sql: String) -> String {
        let units = Array(sql.utf16)
        var kept: [UInt16] = []
        var index = 0
        while index < units.count {
            let c = units[index]
            let next = index + 1 < units.count ? units[index + 1] : 0
            if c == 0x27 || c == 0x22 || c == 0x60 {
                let end = skipQuoted(units, from: index, quote: c, backslash: false)
                kept.append(contentsOf: units[index..<end])
                index = end
            } else if (c == 0x2D && next == 0x2D) || c == 0x23 {
                index = skipLine(units, from: index)
                kept.append(0x20)
            } else if c == 0x2F && next == 0x2A {
                index = skipBlockComment(units, from: index, nested: true)
                kept.append(0x20)
            } else {
                kept.append(c)
                index += 1
            }
        }
        return String(decoding: kept, as: UTF16.self)
    }

    static func skipQuoted(_ units: [UInt16], from start: Int, quote: UInt16, backslash: Bool) -> Int {
        var index = start + 1
        while index < units.count {
            let c = units[index]
            if backslash, c == 0x5C {
                index += 2
                continue
            }
            if c == quote {
                if index + 1 < units.count, units[index + 1] == quote {
                    index += 2
                    continue
                }
                return index + 1
            }
            index += 1
        }
        return units.count
    }

    static func skipLine(_ units: [UInt16], from start: Int) -> Int {
        var index = start
        while index < units.count, units[index] != 0x0A { index += 1 }
        return index
    }

    static func skipBlockComment(_ units: [UInt16], from start: Int, nested: Bool) -> Int {
        var depth = 0
        var index = start
        while index < units.count {
            if units[index] == 0x2F, index + 1 < units.count, units[index + 1] == 0x2A {
                depth += 1
                index += 2
                if !nested { depth = 1 }
                continue
            }
            if units[index] == 0x2A, index + 1 < units.count, units[index + 1] == 0x2F {
                depth -= 1
                index += 2
                if depth <= 0 { return index }
                continue
            }
            index += 1
        }
        return units.count
    }

    /// Returns the index after the closing tag, or nil when this `$` does not open a dollar quote.
    static func skipDollarQuoted(_ units: [UInt16], from start: Int) -> Int? {
        var tagEnd = start + 1
        while tagEnd < units.count {
            let c = units[tagEnd]
            if c == 0x24 { break }
            let isTagChar = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || (c >= 0x30 && c <= 0x39 && tagEnd > start + 1)
            guard isTagChar else { return nil }
            tagEnd += 1
        }
        guard tagEnd < units.count else { return nil }
        let tag = Array(units[start...tagEnd])
        var index = tagEnd + 1
        while index + tag.count <= units.count {
            if units[index] == 0x24, Array(units[index..<(index + tag.count)]) == tag {
                return index + tag.count
            }
            index += 1
        }
        return units.count
    }
}

public extension SQLStatementSplitter {
    private static let readOnlyKeywords: Set<String> = [
        "SELECT", "SHOW", "EXPLAIN", "DESCRIBE", "DESC", "PRAGMA", "VALUES", "TABLE", "WITH",
    ]

    /// Heuristic used for production safety prompts: true when the statement starts with a read-only keyword.
    /// `WITH` counts as read-only only when no data-modifying keyword follows.
    static func looksReadOnly(_ statement: String) -> Bool {
        let words = strippingComments(statement)
            .uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard let first = words.first, readOnlyKeywords.contains(first) else { return false }
        // EXPLAIN only plans the statement it describes; with ANALYZE it runs it, so it writes when that statement does.
        if first == "EXPLAIN", !words.contains("ANALYZE"), !words.contains("ANALYSE") {
            return true
        }
        if first == "WITH" || first == "EXPLAIN" {
            let writes: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE", "TRUNCATE", "DROP", "ALTER", "CREATE"]
            return !words.contains(where: writes.contains)
        }
        return true
    }
}

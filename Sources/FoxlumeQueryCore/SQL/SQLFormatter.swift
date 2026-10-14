import Foundation

/// Reformats SQL for reading: upper-case keywords, one clause per line, select lists and conditions
/// indented, subqueries nested. Strings, quoted identifiers and comments are kept byte for byte.
public enum SQLFormatter {
    public struct Options: Sendable {
        public var indent: String
        public var uppercaseKeywords: Bool

        public init(indent: String = "    ", uppercaseKeywords: Bool = true) {
            self.indent = indent
            self.uppercaseKeywords = uppercaseKeywords
        }
    }

    enum Token: Equatable {
        case word(String)
        case quoted(String)
        case comment(String, isLine: Bool)
        case punctuation(String)
        case number(String)
        case whitespace
    }

    static let keywords: Set<String> = [
        "SELECT", "DISTINCT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL", "LIKE", "ILIKE", "BETWEEN", "EXISTS",
        "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "FETCH", "FIRST", "NEXT", "ROWS", "ONLY", "UNION", "ALL", "EXCEPT",
        "INTERSECT", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "NATURAL", "LATERAL", "ON", "USING", "AS",
        "CASE", "WHEN", "THEN", "ELSE", "END", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "RETURNING", "WITH",
        "RECURSIVE", "CREATE", "TABLE", "VIEW", "INDEX", "DROP", "ALTER", "ADD", "COLUMN", "PRIMARY", "KEY", "FOREIGN",
        "REFERENCES", "DEFAULT", "CONSTRAINT", "UNIQUE", "CHECK", "ASC", "DESC", "NULLS", "LAST", "OVER", "PARTITION",
        "WINDOW", "FILTER", "CONFLICT", "DO", "NOTHING", "TRUE", "FALSE", "CAST", "BEGIN", "COMMIT", "ROLLBACK", "TRUNCATE",
        "IF", "REPLACE", "DUPLICATE", "IGNORE", "QUALIFY", "PIVOT", "UNPIVOT", "SIMILAR", "TO", "ANY", "SOME",
    ]

    /// Clauses that start on their own line at the current nesting level.
    static let clauseStarts: [[String]] = [
        ["WITH", "RECURSIVE"], ["WITH"],
        ["SELECT", "DISTINCT"], ["SELECT"], ["FROM"], ["WHERE"], ["GROUP", "BY"], ["HAVING"], ["QUALIFY"], ["WINDOW"],
        ["ORDER", "BY"], ["LIMIT"], ["OFFSET"], ["FETCH"], ["UNION", "ALL"], ["UNION"], ["EXCEPT"], ["INTERSECT"],
        ["INSERT", "INTO"], ["VALUES"], ["UPDATE"], ["SET"], ["DELETE", "FROM"], ["RETURNING"], ["ON", "CONFLICT"],
        ["LEFT", "OUTER", "JOIN"], ["RIGHT", "OUTER", "JOIN"], ["FULL", "OUTER", "JOIN"], ["LEFT", "JOIN"], ["RIGHT", "JOIN"],
        ["FULL", "JOIN"], ["INNER", "JOIN"], ["CROSS", "JOIN"], ["NATURAL", "JOIN"], ["JOIN"],
    ]

    /// Clauses whose comma-separated items go one per line.
    static let listClauses: Set<String> = ["SELECT", "SELECT DISTINCT", "GROUP BY", "ORDER BY", "SET", "RETURNING", "WITH", "WITH RECURSIVE", "VALUES"]

    public static func format(_ sql: String, dialect: SQLDialect = .postgresql, options: Options = Options()) -> String {
        let tokens = tokenize(sql, dialect: dialect)
        var output = ""
        var line = ""
        var lineLevel = 0
        /// Indent level of clause keywords in the current query block.
        var level = 0
        var clause = ""
        /// One entry per open parenthesis. Subquery parentheses remember the block they interrupt.
        var parens: [(subquery: Bool, savedLevel: Int, savedClause: String, lineLevel: Int)] = []
        var caseDepth = 0
        var pendingSpace = false
        var index = 0

        func flushLine() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let cleaned = line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
                output += (output.isEmpty || output.hasSuffix("\n\n") ? "" : "\n") + cleaned
            }
            line = ""
            pendingSpace = false
        }
        func startLine(_ newLevel: Int) {
            flushLine()
            lineLevel = max(0, newLevel)
            line = String(repeating: options.indent, count: lineLevel)
        }
        func append(_ text: String) {
            let lastChar = line.last
            let atLineStart = line.trimmingCharacters(in: .whitespaces).isEmpty
            let attaches = text == "," || text == ")" || text == "." || text == ";" || text == "::"
            if pendingSpace, !atLineStart, !attaches, lastChar != "(", lastChar != ".", lastChar != ":" {
                line += " "
            } else if !atLineStart, !attaches, lastChar == ",", text != " " {
                line += " "
            }
            line += text
            pendingSpace = false
        }
        func nextWords(_ count: Int, from start: Int) -> [String] {
            var words: [String] = []
            var cursor = start
            while cursor < tokens.count, words.count < count {
                switch tokens[cursor] {
                case .word(let word): words.append(word.uppercased())
                case .whitespace, .comment: break
                default: return words
                }
                cursor += 1
            }
            return words
        }
        func skipWords(_ count: Int, from start: Int) -> Int {
            var cursor = start
            var seen = 0
            while cursor < tokens.count, seen < count {
                if case .word = tokens[cursor] { seen += 1 }
                cursor += 1
            }
            return cursor
        }
        func keyword(_ word: String) -> String {
            options.uppercaseKeywords && keywords.contains(word.uppercased()) ? word.uppercased() : word
        }
        var insideValueList: Bool { parens.last.map { !$0.subquery } ?? false }

        while index < tokens.count {
            switch tokens[index] {
            case .whitespace:
                pendingSpace = true
                index += 1
            case .comment(let text, let isLine):
                append(text)
                if isLine { startLine(clause.isEmpty ? level : level + 1) } else { pendingSpace = true }
                index += 1
            case .quoted(let text), .number(let text):
                append(text)
                index += 1
            case .punctuation(let p):
                switch p {
                case "(":
                    let isSubquery = ["SELECT", "WITH"].contains(nextWords(1, from: index + 1).first ?? "")
                    append("(")
                    parens.append((isSubquery, level, clause, lineLevel))
                    if isSubquery {
                        level = lineLevel + 1
                        clause = ""
                    }
                case ")":
                    if let open = parens.popLast(), open.subquery {
                        startLine(open.lineLevel)
                        level = open.savedLevel
                        clause = open.savedClause
                    }
                    append(")")
                case ",":
                    append(",")
                    if !insideValueList, caseDepth == 0, listClauses.contains(clause) {
                        startLine(level + 1)
                    }
                case ";":
                    append(";")
                    flushLine()
                    output += "\n\n"
                    clause = ""
                    level = 0
                    parens.removeAll()
                    caseDepth = 0
                default:
                    append(p)
                }
                index += 1
            case .word(let word):
                let upper = word.uppercased()
                if !insideValueList, caseDepth == 0, let match = clauseStarts.first(where: { nextWords($0.count, from: index) == $0 }) {
                    let name = match.joined(separator: " ")
                    index = skipWords(match.count, from: index)
                    if name.hasSuffix("JOIN") {
                        // Joins sit under FROM, with their ON condition on the same line.
                        startLine(level + 1)
                        append(match.map(keyword).joined(separator: " "))
                        clause = name
                        continue
                    }
                    startLine(level)
                    append(match.map(keyword).joined(separator: " "))
                    clause = name
                    if !["LIMIT", "OFFSET", "FETCH", "UNION", "UNION ALL", "EXCEPT", "INTERSECT", "ON CONFLICT"].contains(name) {
                        startLine(level + 1)
                    }
                    continue
                }
                if !insideValueList, caseDepth == 0, upper == "AND" || upper == "OR",
                   ["WHERE", "HAVING", "QUALIFY"].contains(clause) || clause.hasSuffix("JOIN") {
                    startLine(clause.hasSuffix("JOIN") ? level + 2 : level + 1)
                    append(keyword(word))
                    index += 1
                    continue
                }
                if upper == "CASE" { caseDepth += 1 }
                if upper == "END", caseDepth > 0 { caseDepth -= 1 }
                append(keyword(word))
                index += 1
            }
        }
        flushLine()
        return output
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tokenize(_ sql: String, dialect: SQLDialect) -> [Token] {
        let units = Array(sql.utf16)
        var tokens: [Token] = []
        var index = 0
        func text(_ start: Int, _ end: Int) -> String { String(decoding: units[start..<end], as: UTF16.self) }
        func isWordChar(_ c: UInt16) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 36 || c > 127
        }
        while index < units.count {
            let c = units[index]
            let next = index + 1 < units.count ? units[index + 1] : 0
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                while index < units.count, [0x20, 0x09, 0x0A, 0x0D].contains(units[index]) { index += 1 }
                if tokens.last != .whitespace { tokens.append(.whitespace) }
            } else if (c == 0x2D && next == 0x2D) || (c == 0x23 && dialect.family == .mysql) {
                let end = SQLStatementSplitter.skipLine(units, from: index)
                tokens.append(.comment(text(index, end), isLine: true))
                index = end
            } else if c == 0x2F && next == 0x2A {
                let end = SQLStatementSplitter.skipBlockComment(units, from: index, nested: dialect.family == .postgresql)
                tokens.append(.comment(text(index, end), isLine: false))
                index = end
            } else if c == 0x27 || c == 0x22 || c == 0x60 {
                let end = SQLStatementSplitter.skipQuoted(units, from: index, quote: c, backslash: dialect.family == .mysql && c != 0x60)
                tokens.append(.quoted(text(index, end)))
                index = end
            } else if c == 0x24, dialect.family == .postgresql || dialect.family == .duckdb, let end = SQLStatementSplitter.skipDollarQuoted(units, from: index) {
                tokens.append(.quoted(text(index, end)))
                index = end
            } else if c >= 48 && c <= 57 {
                var end = index
                while end < units.count, isWordChar(units[end]) || units[end] == 0x2E { end += 1 }
                tokens.append(.number(text(index, end)))
                index = end
            } else if isWordChar(c) {
                var end = index
                while end < units.count, isWordChar(units[end]) { end += 1 }
                tokens.append(.word(text(index, end)))
                index = end
            } else {
                // Keep multi-character operators together: <=, >=, <>, !=, ::, ||, ->, ->>.
                let pair = text(index, min(index + 2, units.count))
                let triple = text(index, min(index + 3, units.count))
                if triple == "->>" {
                    tokens.append(.punctuation(triple))
                    index += 3
                } else if ["<=", ">=", "<>", "!=", "::", "||", "->", ":="].contains(pair) {
                    tokens.append(.punctuation(pair))
                    index += 2
                } else {
                    tokens.append(.punctuation(text(index, index + 1)))
                    index += 1
                }
            }
        }
        return tokens
    }
}

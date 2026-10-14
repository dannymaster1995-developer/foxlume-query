import AppKit
import FoxlumeQueryCore

enum SQLVocabulary {
    static let keywords: [String] = [
        "ADD", "ALL", "ALTER", "ANALYZE", "AND", "ANY", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASCADE", "CASE",
        "CAST", "CHECK", "COLLATE", "COLUMN", "COMMENT", "COMMIT", "CONSTRAINT", "CREATE", "CROSS", "CURRENT_DATE",
        "CURRENT_TIME", "CURRENT_TIMESTAMP", "DATABASE", "DEFAULT", "DELETE", "DESC", "DESCRIBE", "DISTINCT", "DO",
        "DROP", "ELSE", "END", "ESCAPE", "EXCEPT", "EXISTS", "EXPLAIN", "FALSE", "FETCH", "FILTER", "FIRST", "FOR",
        "FOREIGN", "FROM", "FULL", "FUNCTION", "GRANT", "GROUP", "HAVING", "IF", "ILIKE", "IN", "INDEX", "INNER",
        "INSERT", "INTERSECT", "INTERVAL", "INTO", "IS", "JOIN", "KEY", "LAST", "LATERAL", "LEFT", "LIKE", "LIMIT",
        "MATERIALIZED", "MERGE", "NATURAL", "NOT", "NULL", "NULLS", "OFFSET", "ON", "OR", "ORDER", "OUTER", "OVER",
        "PARTITION", "PRAGMA", "PRIMARY", "PROCEDURE", "RECURSIVE", "REFERENCES", "RENAME", "REPLACE", "RETURNING",
        "REVOKE", "RIGHT", "ROLLBACK", "ROW", "ROWS", "SAVEPOINT", "SCHEMA", "SELECT", "SET", "SHOW", "TABLE",
        "TEMP", "TEMPORARY", "THEN", "TO", "TRANSACTION", "TRIGGER", "TRUE", "TRUNCATE", "UNION", "UNIQUE",
        "UPDATE", "USE", "USING", "VACUUM", "VALUES", "VIEW", "WHEN", "WHERE", "WINDOW", "WITH", "WITHOUT",
        "AUTO_INCREMENT", "SERIAL", "UNSIGNED", "ENGINE", "CHARSET", "START",
    ]

    static let types: [String] = [
        "BIGINT", "BIGSERIAL", "BINARY", "BIT", "BLOB", "BOOL", "BOOLEAN", "BYTEA", "CHAR", "CHARACTER", "DATE",
        "DATETIME", "DECIMAL", "DOUBLE", "ENUM", "FLOAT", "INT", "INTEGER", "JSON", "JSONB", "LONGTEXT", "MEDIUMINT",
        "MEDIUMTEXT", "MONEY", "NUMERIC", "REAL", "SMALLINT", "TEXT", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "TINYINT",
        "TINYTEXT", "UUID", "VARBINARY", "VARCHAR", "YEAR",
    ]

    static let functions: [String] = [
        "ABS", "AVG", "COALESCE", "CONCAT", "COUNT", "DATE_TRUNC", "EXTRACT", "FLOOR", "CEIL", "GREATEST",
        "IFNULL", "LEAST", "LENGTH", "LOWER", "MAX", "MIN", "NOW", "NULLIF", "ROUND", "ROW_NUMBER", "RANK",
        "SUBSTRING", "SUM", "TRIM", "UPPER", "STRING_AGG", "GROUP_CONCAT", "ARRAY_AGG", "JSON_EXTRACT",
        "TO_CHAR", "DATE_FORMAT", "STRFTIME", "RANDOM", "RAND", "REPLACE", "POSITION", "LAG", "LEAD",
    ]

    static let keywordSet = Set(keywords + types)
    static let functionSet = Set(functions)
}

/// Colors SQL text with layout-manager temporary attributes, which never touch the text storage or undo stack.
final class SQLHighlighter {
    enum Token {
        case keyword, string, number, comment, quotedIdentifier, function
    }

    static let maximumLength = 300_000

    static func tokenizeSQL(_ text: NSString) -> [(NSRange, Token)] {
        var tokens: [(NSRange, Token)] = []
        let length = text.length
        var index = 0

        func isIdentifierStart(_ c: unichar) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
        }
        func isIdentifierPart(_ c: unichar) -> Bool {
            isIdentifierStart(c) || (c >= 48 && c <= 57) || c == 36
        }
        func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }

        while index < length {
            let c = text.character(at: index)
            let next = index + 1 < length ? text.character(at: index + 1) : 0
            if (c == 45 && next == 45) || c == 35 { // -- or #
                var end = index
                while end < length, text.character(at: end) != 10 { end += 1 }
                tokens.append((NSRange(location: index, length: end - index), .comment))
                index = end
            } else if c == 47, next == 42 { // /*
                var end = index + 2
                while end + 1 < length, !(text.character(at: end) == 42 && text.character(at: end + 1) == 47) { end += 1 }
                end = min(end + 2, length)
                tokens.append((NSRange(location: index, length: end - index), .comment))
                index = end
            } else if c == 39 || c == 34 || c == 96 { // ' " `
                var end = index + 1
                while end < length {
                    let d = text.character(at: end)
                    if d == 92, c == 39 { end += 2; continue }
                    if d == c {
                        if end + 1 < length, text.character(at: end + 1) == c { end += 2; continue }
                        end += 1
                        break
                    }
                    end += 1
                }
                end = min(end, length)
                tokens.append((NSRange(location: index, length: end - index), c == 39 ? .string : .quotedIdentifier))
                index = end
            } else if c == 36, next == 36 { // $$ body $$
                var end = index + 2
                while end + 1 < length, !(text.character(at: end) == 36 && text.character(at: end + 1) == 36) { end += 1 }
                end = min(end + 2, length)
                tokens.append((NSRange(location: index, length: end - index), .string))
                index = end
            } else if isDigit(c) {
                var end = index
                while end < length, isDigit(text.character(at: end)) || text.character(at: end) == 46 { end += 1 }
                let previous = index > 0 ? text.character(at: index - 1) : 32
                if !isIdentifierPart(previous) {
                    tokens.append((NSRange(location: index, length: end - index), .number))
                }
                index = end
            } else if isIdentifierStart(c) {
                var end = index
                while end < length, isIdentifierPart(text.character(at: end)) { end += 1 }
                let range = NSRange(location: index, length: end - index)
                let word = text.substring(with: range).uppercased()
                var lookahead = end
                while lookahead < length, text.character(at: lookahead) == 32 { lookahead += 1 }
                let isCall = lookahead < length && text.character(at: lookahead) == 40
                let previous = index > 0 ? text.character(at: index - 1) : 32
                if previous != 46 {
                    if SQLVocabulary.keywordSet.contains(word) {
                        tokens.append((range, .keyword))
                    } else if isCall, SQLVocabulary.functionSet.contains(word) {
                        tokens.append((range, .function))
                    }
                }
                index = end
            } else {
                index += 1
            }
        }
        return tokens
    }

    static func tokenize(_ text: NSString, language: QueryLanguage) -> [(NSRange, Token)] {
        switch language {
        case .sql: return tokenizeSQL(text)
        case .mongo: return tokenizeMongo(text)
        case .redis: return tokenizeRedis(text)
        }
    }

    static let mongoKeywords: Set<String> = ["db", "use", "show", "true", "false", "null", "undefined", "new", "var", "let", "const", "function", "return", "if", "else", "for", "of", "in", "this"]
    static let mongoHelpers: Set<String> = ["ObjectId", "ISODate", "Date", "NumberLong", "NumberInt", "NumberDecimal", "Decimal128", "Int32", "Double", "UUID", "BinData", "HexData", "Timestamp", "Code", "DBRef", "BSONRegExp", "print", "printjson", "MinKey", "MaxKey"]

    /// JavaScript-style coloring for MongoDB shell input: strings, numbers, comments, keywords,
    /// `$operators`, BSON helpers and method calls.
    static func tokenizeMongo(_ text: NSString) -> [(NSRange, Token)] {
        var tokens: [(NSRange, Token)] = []
        let length = text.length
        var index = 0
        func isIdentifierStart(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c > 127 }
        func isIdentifierPart(_ c: unichar) -> Bool { isIdentifierStart(c) || (c >= 48 && c <= 57) }
        while index < length {
            let c = text.character(at: index)
            let next = index + 1 < length ? text.character(at: index + 1) : 0
            if c == 47, next == 47 {
                var end = index
                while end < length, text.character(at: end) != 10 { end += 1 }
                tokens.append((NSRange(location: index, length: end - index), .comment))
                index = end
            } else if c == 47, next == 42 {
                var end = index + 2
                while end + 1 < length, !(text.character(at: end) == 42 && text.character(at: end + 1) == 47) { end += 1 }
                end = min(end + 2, length)
                tokens.append((NSRange(location: index, length: end - index), .comment))
                index = end
            } else if c == 39 || c == 34 || c == 96 {
                var end = index + 1
                while end < length {
                    let d = text.character(at: end)
                    if d == 92 { end += 2; continue }
                    end += 1
                    if d == c { break }
                }
                end = min(end, length)
                tokens.append((NSRange(location: index, length: end - index), .string))
                index = end
            } else if c >= 48 && c <= 57 {
                var end = index
                while end < length, (text.character(at: end) >= 48 && text.character(at: end) <= 57) || text.character(at: end) == 46 { end += 1 }
                let previous = index > 0 ? text.character(at: index - 1) : 32
                if !isIdentifierPart(previous) { tokens.append((NSRange(location: index, length: end - index), .number)) }
                index = end
            } else if isIdentifierStart(c) {
                var end = index
                while end < length, isIdentifierPart(text.character(at: end)) { end += 1 }
                let range = NSRange(location: index, length: end - index)
                let word = text.substring(with: range)
                let previous = index > 0 ? text.character(at: index - 1) : 32
                var lookahead = end
                while lookahead < length, text.character(at: lookahead) == 32 { lookahead += 1 }
                let isCall = lookahead < length && text.character(at: lookahead) == 40
                if word.hasPrefix("$") {
                    tokens.append((range, .keyword))
                } else if previous != 46, mongoKeywords.contains(word) {
                    tokens.append((range, .keyword))
                } else if mongoHelpers.contains(word) || (isCall && previous == 46) {
                    tokens.append((range, .function))
                }
                index = end
            } else {
                index += 1
            }
        }
        return tokens
    }

    /// Redis: the command (first word of each line or after `;`) is a keyword; quoted arguments are strings.
    static func tokenizeRedis(_ text: NSString) -> [(NSRange, Token)] {
        var tokens: [(NSRange, Token)] = []
        let length = text.length
        var index = 0
        var expectCommand = true
        var afterDBPrefix = false
        while index < length {
            let c = text.character(at: index)
            if c == 10 || c == 59 {
                expectCommand = true
                afterDBPrefix = false
                index += 1
            } else if c == 32 || c == 9 || c == 13 {
                index += 1
            } else if expectCommand && (c == 35 || (c == 47 && index + 1 < length && text.character(at: index + 1) == 47)) {
                var end = index
                while end < length, text.character(at: end) != 10 { end += 1 }
                tokens.append((NSRange(location: index, length: end - index), .comment))
                index = end
            } else if c == 34 || c == 39 {
                var end = index + 1
                while end < length {
                    let d = text.character(at: end)
                    if d == 92 { end += 2; continue }
                    end += 1
                    if d == c { break }
                }
                end = min(end, length)
                tokens.append((NSRange(location: index, length: end - index), .string))
                index = end
                expectCommand = false
            } else {
                var end = index
                while end < length {
                    let d = text.character(at: end)
                    if d == 32 || d == 9 || d == 10 || d == 13 || d == 59 { break }
                    end += 1
                }
                let range = NSRange(location: index, length: end - index)
                let word = text.substring(with: range)
                if afterDBPrefix, Int(word) != nil {
                    // `DB n CMD`: the index is a number and the real command follows.
                    tokens.append((range, .number))
                    afterDBPrefix = false
                    expectCommand = true
                } else if expectCommand {
                    tokens.append((range, .keyword))
                    afterDBPrefix = word.uppercased() == "DB"
                    expectCommand = false
                } else if Double(word) != nil {
                    tokens.append((range, .number))
                }
                index = end
            }
        }
        return tokens
    }

    static func apply(to textView: NSTextView, language: QueryLanguage = .sql(.postgresql)) {
        guard let layoutManager = textView.layoutManager else { return }
        let text = textView.string as NSString
        let full = NSRange(location: 0, length: text.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        guard text.length <= maximumLength else { return }
        for (range, token) in tokenize(text, language: language) {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: color(for: token), forCharacterRange: range)
        }
    }

    static func color(for token: Token) -> NSColor {
        switch token {
        case .keyword: return Theme.keyword
        case .string: return Theme.string
        case .number: return Theme.number
        case .comment: return Theme.comment
        case .quotedIdentifier: return Theme.identifier
        case .function: return Theme.function
        }
    }

    /// Highlighted copy of `text` for read-only displays such as DDL.
    static func attributedString(_ text: String, font: NSFont, language: QueryLanguage = .sql(.postgresql)) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        guard (text as NSString).length <= maximumLength else { return result }
        for (range, token) in tokenize(text as NSString, language: language) {
            result.addAttribute(.foregroundColor, value: color(for: token), range: range)
        }
        return result
    }
}

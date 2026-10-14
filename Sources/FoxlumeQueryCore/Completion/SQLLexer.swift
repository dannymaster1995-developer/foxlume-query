import Foundation

/// One lexical token of SQL text, with its UTF-16 range in the text it came from.
public struct SQLToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A bare word: keyword or unquoted identifier.
        case word
        /// `"x"`, `` `x` `` or `[x]`; `value` holds the name without quotes.
        case quotedIdentifier
        case string
        case number
        /// `--`, `#` (MySQL) or `/* */`.
        case comment
        /// One of `( ) , . ; [ ]`.
        case punctuation
        /// Operators such as `=`, `<>`, `::`, `||`.
        case symbol
        /// `?`, `$1`, `:name`, `@var`.
        case parameter
    }

    public var kind: Kind
    public var range: NSRange
    /// The source text of the token.
    public var text: String
    /// Identifiers without their quotes; otherwise the same as `text`.
    public var value: String
    /// True when a string, quoted identifier or block comment reaches the end of the text without closing.
    public var isUnterminated: Bool

    public var upper: String { value.uppercased() }

    public func isWord(_ keyword: String) -> Bool {
        kind == .word && value.caseInsensitiveCompare(keyword) == .orderedSame
    }

    public func isPunctuation(_ character: String) -> Bool {
        kind == .punctuation && text == character
    }

    /// A name: a bare word or a quoted identifier.
    public var isIdentifier: Bool { kind == .word || kind == .quotedIdentifier }
}

/// Tokenizer used by completion. It never fails: unterminated quotes and comments run to the end of the text.
public enum SQLLexer {
    public static func tokenize(_ text: String, family: SQLDialect.Family) -> [SQLToken] {
        tokenize(text as NSString, family: family)
    }

    public static func tokenize(_ text: NSString, family: SQLDialect.Family) -> [SQLToken] {
        var tokens: [SQLToken] = []
        let length = text.length
        var index = 0

        func char(_ i: Int) -> unichar { i < length ? text.character(at: i) : 0 }
        func add(_ kind: SQLToken.Kind, _ start: Int, _ end: Int, value: String? = nil, unterminated: Bool = false) {
            let range = NSRange(location: start, length: end - start)
            let raw = text.substring(with: range)
            tokens.append(SQLToken(kind: kind, range: range, text: raw, value: value ?? raw, isUnterminated: unterminated))
        }

        while index < length {
            let c = char(index)
            let start = index
            // Whitespace
            if c == 32 || c == 9 || c == 10 || c == 13 || c == 12 {
                index += 1
                continue
            }
            // Line comments: -- always, # in MySQL.
            if (c == 45 && char(index + 1) == 45) || (c == 35 && family == .mysql) {
                while index < length, char(index) != 10 { index += 1 }
                add(.comment, start, index)
                continue
            }
            // Block comment
            if c == 47 && char(index + 1) == 42 {
                index += 2
                var closed = false
                while index < length {
                    if char(index) == 42 && char(index + 1) == 47 {
                        index += 2
                        closed = true
                        break
                    }
                    index += 1
                }
                add(.comment, start, index, unterminated: !closed)
                continue
            }
            // String literals: '...' with '' escapes (and backslash escapes in MySQL); E'...' handled as word + string.
            if c == 39 {
                index += 1
                var closed = false
                while index < length {
                    let d = char(index)
                    if d == 92 && family == .mysql {
                        index += 2
                        continue
                    }
                    if d == 39 {
                        if char(index + 1) == 39 {
                            index += 2
                            continue
                        }
                        index += 1
                        closed = true
                        break
                    }
                    index += 1
                }
                add(.string, start, min(index, length), unterminated: !closed)
                continue
            }
            // MySQL also accepts "..." as a string unless ANSI_QUOTES is on; completion treats it as an identifier
            // only for the other dialects.
            if c == 34 && family == .mysql {
                index += 1
                var closed = false
                while index < length {
                    let d = char(index)
                    if d == 92 {
                        index += 2
                        continue
                    }
                    if d == 34 {
                        index += 1
                        closed = true
                        break
                    }
                    index += 1
                }
                add(.string, start, min(index, length), unterminated: !closed)
                continue
            }
            // Quoted identifiers: "x" (standard), `x` (MySQL, SQLite, DuckDB accept it), [x] (SQLite).
            if c == 34 || c == 96 || (c == 91 && family == .sqlite) {
                let close: unichar = c == 91 ? 93 : c
                index += 1
                var value = ""
                var closed = false
                var segmentStart = index
                while index < length {
                    let d = char(index)
                    if d == close {
                        if close != 93 && char(index + 1) == close {
                            value += text.substring(with: NSRange(location: segmentStart, length: index - segmentStart + 1))
                            index += 2
                            segmentStart = index
                            continue
                        }
                        value += text.substring(with: NSRange(location: segmentStart, length: index - segmentStart))
                        index += 1
                        closed = true
                        break
                    }
                    index += 1
                }
                if !closed {
                    value += text.substring(with: NSRange(location: segmentStart, length: min(index, length) - segmentStart))
                }
                add(.quotedIdentifier, start, min(index, length), value: value, unterminated: !closed)
                continue
            }
            // PostgreSQL / DuckDB dollar quoting: $$...$$ or $tag$...$tag$; $1 is a parameter.
            if c == 36 && (family == .postgresql || family == .duckdb) {
                var tagEnd = index + 1
                // A tag is letters, digits and underscores, and cannot start with a digit ($1 is a parameter).
                while tagEnd < length, !isDigit(char(index + 1)), isIdentifierStart(char(tagEnd)) || isDigit(char(tagEnd)) { tagEnd += 1 }
                if char(tagEnd) == 36 {
                    let tag = text.substring(with: NSRange(location: index, length: tagEnd - index + 1))
                    let bodyStart = tagEnd + 1
                    let found = text.range(of: tag, options: [], range: NSRange(location: bodyStart, length: length - bodyStart))
                    if found.location != NSNotFound {
                        index = NSMaxRange(found)
                        add(.string, start, index)
                    } else {
                        index = length
                        add(.string, start, index, unterminated: true)
                    }
                    continue
                }
                if isDigit(char(index + 1)) {
                    index += 1
                    while isDigit(char(index)) { index += 1 }
                    add(.parameter, start, index)
                    continue
                }
            }
            // Numbers
            if isDigit(c) || (c == 46 && isDigit(char(index + 1)) && !(tokens.last.map { $0.isIdentifier || $0.isPunctuation(")") } ?? false)) {
                index += 1
                while index < length {
                    let d = char(index)
                    if isDigit(d) || d == 46 || d == 95 {
                        index += 1
                    } else if (d == 101 || d == 69), isDigit(char(index + 1)) || ((char(index + 1) == 43 || char(index + 1) == 45) && isDigit(char(index + 2))) {
                        index += 2
                    } else if (d == 120 || d == 88), index == start + 1, c == 48 {
                        index += 1
                    } else if isHexLetter(d), text.substring(with: NSRange(location: start, length: min(2, length - start))).lowercased() == "0x" {
                        index += 1
                    } else {
                        break
                    }
                }
                add(.number, start, index)
                continue
            }
            // Words
            if isIdentifierStart(c) {
                index += 1
                while index < length, isIdentifierPart(char(index)) { index += 1 }
                add(.word, start, index)
                continue
            }
            // Parameters: ?, :name, @var
            if c == 63 {
                index += 1
                add(.parameter, start, index)
                continue
            }
            if (c == 58 && isIdentifierStart(char(index + 1))) || (c == 64 && (isIdentifierStart(char(index + 1)) || char(index + 1) == 64)) {
                index += 1
                while index < length, isIdentifierPart(char(index)) || char(index) == 64 { index += 1 }
                add(.parameter, start, index)
                continue
            }
            // Punctuation
            if c == 40 || c == 41 || c == 44 || c == 46 || c == 59 || c == 91 || c == 93 {
                index += 1
                add(.punctuation, start, index)
                continue
            }
            // Operators, greedily: :: <= >= <> != || -> ->> etc.
            index += 1
            while index < length, isOperatorCharacter(char(index)), !(char(index) == 45 && char(index + 1) == 45), !(char(index) == 47 && char(index + 1) == 42) {
                index += 1
            }
            add(.symbol, start, index)
        }
        return tokens
    }

    static func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
    static func isHexLetter(_ c: unichar) -> Bool { (c >= 97 && c <= 102) || (c >= 65 && c <= 70) }
    static func isIdentifierStart(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127 }
    static func isIdentifierPart(_ c: unichar) -> Bool { isIdentifierStart(c) || isDigit(c) || c == 36 }
    static func isOperatorCharacter(_ c: unichar) -> Bool {
        // = < > ! | & + - * / % ^ ~ : #
        [61, 60, 62, 33, 124, 38, 43, 45, 42, 47, 37, 94, 126, 58].contains(c)
    }
}

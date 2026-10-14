import Foundation

/// Where strings, quoted names and comments start and end in one dialect (spec 1.3, 2.2). The caret scan and the
/// window tokenizer both use it, so suppression, statement splitting and table discovery always agree.
struct SQLLiteralRules {
    typealias Kind = SQLCaretScanner.State

    struct Span {
        var kind: Kind
        var start: Int
        /// Exclusive.
        var end: Int
        /// Ended by its own closing delimiter.
        var closed: Bool
        /// Still open at the scan limit.
        var reachesLimit: Bool
    }

    /// MySQL, and unknown engines like TablePro: `"…"` is a string, `'…'` honors backslash escapes, `#` comments.
    private let mysqlLike: Bool
    private let dollarQuotes: Bool
    private let brackets: Bool

    init(family: SQLDialect.Family?) {
        mysqlLike = family == .mysql || family == nil
        dollarQuotes = family == .postgresql || family == .duckdb
        brackets = family == .sqlite
    }

    /// The literal or comment opening at `i`, read no further than `limit`; nil when `chars[i]` opens none.
    func span(_ chars: [unichar], at i: Int, limit: Int) -> Span? {
        func at(_ k: Int) -> unichar { k < limit ? chars[k] : 0 }
        switch chars[i] {
        case 39:
            let escapes = mysqlLike || (dollarQuotes && isEscapeStringPrefix(chars, before: i))
            return quoted(.singleQuoted, chars, i, limit, close: 39, backslash: escapes, endsAtLineBreak: false)
        case 34:
            if mysqlLike { return quoted(.doubleQuotedString, chars, i, limit, close: 34, backslash: true, endsAtLineBreak: false) }
            return quoted(.doubleQuotedIdentifier, chars, i, limit, close: 34, backslash: false, endsAtLineBreak: true)
        case 96:
            return quoted(.backtickIdentifier, chars, i, limit, close: 96, backslash: false, endsAtLineBreak: true)
        case 91 where brackets:
            return quoted(.bracketIdentifier, chars, i, limit, close: 93, backslash: false, endsAtLineBreak: true)
        case 47 where at(i + 1) == 42:
            return blockComment(chars, i, limit)
        case 45 where at(i + 1) == 45:
            return lineComment(chars, i, limit)
        case 35 where mysqlLike:
            return lineComment(chars, i, limit)
        case 36 where dollarQuotes:
            // `a$b$` is a name with dollars in it, not a tag.
            if i > 0, Self.isWordUnit(chars[i - 1]) { return nil }
            return dollarQuoted(chars, i, limit)
        default:
            return nil
        }
    }

    /// Letters, digits, `_`, `$` and anything non-ASCII: the units a bare name is made of.
    static func isWordUnit(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 36 || c > 127
    }

    /// PostgreSQL `E'…'`: a standalone `E` right before the quote turns on backslash escapes.
    private func isEscapeStringPrefix(_ chars: [unichar], before i: Int) -> Bool {
        guard i >= 1, chars[i - 1] == 69 || chars[i - 1] == 101 else { return false }
        return i == 1 || !Self.isWordUnit(chars[i - 2])
    }

    /// Quoted text closed by `close` (doubled to escape it, except `]`). Quoted names end at a line break when
    /// unterminated, so a stray quote never swallows the lines below it.
    private func quoted(_ kind: Kind, _ chars: [unichar], _ i: Int, _ limit: Int, close: unichar, backslash: Bool, endsAtLineBreak: Bool) -> Span {
        var j = i + 1
        while j < limit {
            let c = chars[j]
            if backslash && c == 92 {
                j += 2
                continue
            }
            if c == close {
                if close != 93, j + 1 < limit, chars[j + 1] == close {
                    j += 2
                    continue
                }
                return Span(kind: kind, start: i, end: j + 1, closed: true, reachesLimit: false)
            }
            if endsAtLineBreak, c == 10 || c == 13 {
                return Span(kind: kind, start: i, end: j, closed: false, reachesLimit: false)
            }
            j += 1
        }
        return Span(kind: kind, start: i, end: limit, closed: false, reachesLimit: true)
    }

    /// `/* … */`, with nesting counted (spec 1.3).
    private func blockComment(_ chars: [unichar], _ i: Int, _ limit: Int) -> Span {
        var depth = 1
        var j = i + 2
        while j + 1 < limit {
            if chars[j] == 47 && chars[j + 1] == 42 {
                depth += 1
                j += 2
            } else if chars[j] == 42 && chars[j + 1] == 47 {
                depth -= 1
                j += 2
                if depth == 0 { return Span(kind: .blockComment, start: i, end: j, closed: true, reachesLimit: false) }
            } else {
                j += 1
            }
        }
        return Span(kind: .blockComment, start: i, end: limit, closed: false, reachesLimit: true)
    }

    /// Up to the line break, which stays code.
    private func lineComment(_ chars: [unichar], _ i: Int, _ limit: Int) -> Span {
        var j = i + 1
        while j < limit, chars[j] != 10, chars[j] != 13 { j += 1 }
        return Span(kind: .lineComment, start: i, end: j, closed: true, reachesLimit: j == limit)
    }

    /// `$$…$$` or `$tag$…$tag$`; `$1` is a parameter, not a tag.
    private func dollarQuoted(_ chars: [unichar], _ i: Int, _ limit: Int) -> Span? {
        var j = i + 1
        var tagEnd = -1
        while j < limit {
            let c = chars[j]
            if c == 36 {
                tagEnd = j
                break
            }
            let letter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
            let digit = c >= 48 && c <= 57
            if !(letter || (digit && j > i + 1)) { return nil }
            j += 1
        }
        guard tagEnd > i else { return nil }
        let tag = chars[i...tagEnd]
        var k = tagEnd + 1
        while k + tag.count <= limit {
            if chars[k] == 36, chars[k..<(k + tag.count)].elementsEqual(tag) {
                return Span(kind: .dollarQuoted, start: i, end: k + tag.count, closed: true, reachesLimit: false)
            }
            k += 1
        }
        return Span(kind: .dollarQuoted, start: i, end: limit, closed: false, reachesLimit: true)
    }
}

/// Tokens of the analysis window. Literals and comments are cut by `SQLLiteralRules`; the code between them goes
/// through `SQLLexer`, which then never meets a quote or comment it could read differently.
enum SQLWindowLexer {
    /// `freshQuote`: the start of a quote typed in front of existing text. Its name ends at `caret` and lexing goes
    /// on after it, so the tables named later in the statement stay in scope (spec 3.4, A.1, A.2).
    static func tokenize(_ chars: [unichar], family: SQLDialect.Family?, freshQuote: Int?, caret: Int) -> [SQLToken] {
        let rules = SQLLiteralRules(family: family)
        let codeFamily: SQLDialect.Family = family ?? .mysql
        var tokens: [SQLToken] = []
        var codeStart = 0
        var i = 0
        chars.withUnsafeBufferPointer { buffer in
            func lexCode(_ start: Int, _ end: Int) {
                guard end > start, let base = buffer.baseAddress else { return }
                let run = NSString(characters: base + start, length: end - start)
                for var token in SQLLexer.tokenize(run, family: codeFamily) {
                    token.range.location += start
                    tokens.append(token)
                }
            }
            while i < chars.count {
                guard var span = rules.span(chars, at: i, limit: chars.count) else {
                    i += 1
                    continue
                }
                if span.start == freshQuote, span.end > caret {
                    span.end = caret
                    span.closed = false
                }
                lexCode(codeStart, i)
                tokens.append(token(span, buffer))
                i = span.end
                codeStart = i
            }
            lexCode(codeStart, chars.count)
        }
        return tokens
    }

    private static func token(_ span: SQLLiteralRules.Span, _ buffer: UnsafeBufferPointer<unichar>) -> SQLToken {
        let range = NSRange(location: span.start, length: span.end - span.start)
        let text = String(utf16CodeUnits: buffer.baseAddress! + span.start, count: range.length)
        switch span.kind {
        case .doubleQuotedIdentifier, .backtickIdentifier, .bracketIdentifier:
            let innerEnd = span.closed ? span.end - 1 : span.end
            var value = String(utf16CodeUnits: buffer.baseAddress! + span.start + 1, count: max(0, innerEnd - span.start - 1))
            if span.kind != .bracketIdentifier {
                let quote = String(utf16CodeUnits: [buffer[span.start]], count: 1)
                value = value.replacingOccurrences(of: quote + quote, with: quote)
            }
            return SQLToken(kind: .quotedIdentifier, range: range, text: text, value: value, isUnterminated: !span.closed)
        case .blockComment, .lineComment:
            return SQLToken(kind: .comment, range: range, text: text, value: text, isUnterminated: !span.closed)
        default:
            return SQLToken(kind: .string, range: range, text: text, value: text, isUnterminated: !span.closed)
        }
    }
}

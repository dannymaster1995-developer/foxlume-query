import Foundation

/// Character-level scanning around the caret: string/comment state (spec 1.3) and token boundaries (spec 2.3).
enum SQLCaretScanner {
    enum State: Equatable {
        case code
        case singleQuoted
        /// `"…"` where the dialect reads it as a string (MySQL, or no dialect).
        case doubleQuotedString
        /// `"…"` where the dialect reads it as an identifier (spec A.1).
        case doubleQuotedIdentifier
        case backtickIdentifier
        /// SQLite `[…]`.
        case bracketIdentifier
        case blockComment
        case lineComment
        case dollarQuoted

        /// No completion inside strings and comments; identifiers being typed are fine.
        var suppresses: Bool {
            switch self {
            case .code, .doubleQuotedIdentifier, .backtickIdentifier, .bracketIdentifier: return false
            default: return true
            }
        }
    }

    struct Result {
        var state: State
        /// Where an unterminated `"…` or `` `… `` open at the caret starts.
        var openQuoteStart: Int?
    }

    /// Walks `chars[from..<to]` starting outside any literal and reports the state at `to`. Nothing past `to` is
    /// read, so only the text before the caret decides (`'it'|'s'` is outside a string).
    static func scan(_ chars: [unichar], from: Int, to: Int, family: SQLDialect.Family?) -> Result {
        let rules = SQLLiteralRules(family: family)
        var i = from
        while i < to {
            guard let span = rules.span(chars, at: i, limit: to) else {
                i += 1
                continue
            }
            if span.reachesLimit {
                let quoted = span.kind == .doubleQuotedIdentifier || span.kind == .backtickIdentifier
                return Result(state: span.kind, openQuoteStart: quoted ? span.start : nil)
            }
            i = span.end
        }
        return Result(state: .code, openQuoteStart: nil)
    }

    /// True when the quoted name open at the caret is an existing one being edited (`"na|me"`): only name
    /// characters lie between the caret and its closing quote. Otherwise the quote was just typed in front of
    /// existing text and names only what precedes the caret.
    static func continuesQuotedName(_ chars: [unichar], from caret: Int, close: unichar) -> Bool {
        var i = caret
        while i < chars.count {
            if chars[i] == close { return true }
            guard SQLLiteralRules.isWordUnit(chars[i]) else { return false }
            i += 1
        }
        return false
    }

    // MARK: Token boundaries

    private static let doubleQuote: unichar = 34, backtick: unichar = 96

    /// Start of the identifier fragment that ends at `caret`, never before `lowerBound` (spec 2.3).
    static func tokenStart(_ text: NSString, caret: Int, lowerBound: Int) -> Int {
        var index = caret
        while index > lowerBound {
            let range = text.rangeOfComposedCharacterSequence(at: index - 1)
            guard range.location >= lowerBound, isIdentifierCharacter(text, range) else { break }
            index = range.location
        }
        return index
    }

    /// ASCII letters, digits, `_` and the identifier quotes, plus any non-ASCII letter, digit or combining mark.
    static func isIdentifierCharacter(_ text: NSString, _ range: NSRange) -> Bool {
        if range.length == 1 {
            let c = text.character(at: range.location)
            if c < 128 {
                return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == backtick || c == doubleQuote
            }
        }
        let scalars = text.substring(with: range).unicodeScalars
        guard let first = scalars.first, isWordScalar(first, allowMark: false) else { return false }
        return scalars.dropFirst().allSatisfy { isWordScalar($0, allowMark: true) }
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar, allowMark: Bool) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return allowMark
        default:
            return false
        }
    }

    static func stripQuotes(_ token: String) -> String {
        let quotes: Set<Character> = ["`", "\""]
        var result = Substring(token)
        while let first = result.first, quotes.contains(first) { result = result.dropFirst() }
        while let last = result.last, quotes.contains(last) { result = result.dropLast() }
        return String(result)
    }

    /// `x` in `x.pre|`: the name right before the dot that precedes the token, quotes stripped. One level only.
    /// Empty when the dot has no name before it (`SELECT .|`), nil when there is no dot.
    static func qualifier(_ text: NSString, tokenStart: Int, lowerBound: Int) -> String? {
        let dot = tokenStart - 1
        guard dot >= lowerBound, text.character(at: dot) == 46 else { return nil }
        let end = dot
        guard end > lowerBound else { return "" }
        let last = text.character(at: end - 1)
        if last == backtick || last == doubleQuote {
            // A quoted segment may contain spaces and dots: find its opening quote.
            var index = end - 2
            while index >= lowerBound {
                if text.character(at: index) == last {
                    if index - 1 >= lowerBound, text.character(at: index - 1) == last {
                        index -= 2
                        continue
                    }
                    let inner = NSRange(location: index + 1, length: end - 1 - (index + 1))
                    let doubled = String(utf16CodeUnits: [last, last], count: 2)
                    return text.substring(with: inner).replacingOccurrences(of: doubled, with: String(utf16CodeUnits: [last], count: 1))
                }
                index -= 1
            }
        }
        let start = Self.tokenStart(text, caret: end, lowerBound: lowerBound)
        return stripQuotes(text.substring(with: NSRange(location: start, length: end - start)))
    }
}

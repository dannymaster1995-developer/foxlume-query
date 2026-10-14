import Foundation

/// Finds the statement, token and clause at the caret (spec 2–3). Pure function of the text.
public enum SQLContextAnalyzer {
    /// UTF-16 units kept on each side of the caret (spec 2.1).
    static let windowRadius = 5000

    /// Nil means "no completion here": inside a string or comment, or right after a statement break (spec 1.3).
    public static func analyze(text: String, caret: Int, family: SQLDialect.Family?) -> SQLCompletionContext? {
        let source = text as NSString
        let caret = min(max(caret, 0), source.length)
        if isStatementBreak(source, caret: caret) { return nil }

        let window = Window(source, caret: caret)
        let local = window.caret
        let scan = SQLCaretScanner.scan(window.chars, from: 0, to: local, family: family)
        if scan.state.suppresses { return nil }
        var freshQuote: Int?
        if let start = scan.openQuoteStart, !SQLCaretScanner.continuesQuotedName(window.chars, from: local, close: window.chars[start]) {
            freshQuote = start
        }
        let lexed = SQLWindowLexer.tokenize(window.chars, family: family, freshQuote: freshQuote, caret: local)
        let statement = statementSpan(lexed, caret: local, length: window.text.length)

        // An unterminated quoted identifier is one token even with spaces in it (spec A.1).
        let tokenStart = scan.openQuoteStart ?? SQLCaretScanner.tokenStart(window.text, caret: local, lowerBound: statement.start)
        let token = window.text.substring(with: NSRange(location: tokenStart, length: local - tokenStart))
        let prefix = SQLCaretScanner.stripQuotes(token)
        let isCast = tokenStart - 2 >= statement.start && window.chars[tokenStart - 1] == 58 && window.chars[tokenStart - 2] == 58
        let qualifier = isCast ? nil : SQLCaretScanner.qualifier(window.text, tokenStart: tokenStart, lowerBound: statement.start)

        // Clause detection sees only what precedes the token; table discovery sees the whole statement but the token.
        let before = SQLScanTokens(statement.tokens.filter { NSMaxRange($0.range) <= tokenStart }, family: family)
        let around = SQLScanTokens(statement.tokens.filter { NSMaxRange($0.range) <= tokenStart || $0.range.location >= local }, family: family)
        var detected = SQLClauseDetector.detect(before)
        if qualifier != nil {
            // `x.|` completes members of x, like a SELECT list would (spec 2.4 step 1).
            detected.clause = .selectList
            detected.expectsObjectName = false
        }
        if isCast {
            detected.clause = .castTarget
            detected.expectsObjectName = false
        }
        let tables = SQLTableExtractor.extract(around)

        return SQLCompletionContext(
            statementRange: NSRange(location: window.start + statement.start, length: statement.end - statement.start),
            replacementRange: NSRange(location: window.start + tokenStart, length: local - tokenStart),
            token: token,
            prefix: prefix,
            qualifier: qualifier,
            clause: detected.clause,
            expectsObjectName: detected.expectsObjectName,
            isAfterComma: token.isEmpty && isAfterComma(window.chars, before: tokenStart, lowerBound: statement.start),
            currentFunction: detected.currentFunction,
            comparisonColumn: detected.comparisonColumn,
            nestingLevel: detected.nestingLevel,
            insideCreateTableColumns: detected.insideCreateTableColumns,
            references: tables.references,
            cteNames: tables.cteNames,
            targetTable: tables.target
        )
    }

    /// The text around the caret as UTF-16, so scanning is cheap on large documents.
    struct Window {
        let start: Int
        let chars: [unichar]
        let text: NSString
        let caret: Int

        init(_ source: NSString, caret: Int) {
            var start = max(0, caret - SQLContextAnalyzer.windowRadius)
            if start > 0 {
                // Begin at a line start so the window rarely opens inside a literal.
                let newline = source.range(of: "\n", options: .literal, range: NSRange(location: start, length: caret - start))
                if newline.location != NSNotFound { start = newline.location + 1 }
            }
            let end = min(source.length, caret + SQLContextAnalyzer.windowRadius)
            var chars = [unichar](repeating: 0, count: end - start)
            source.getCharacters(&chars, range: NSRange(location: start, length: end - start))
            self.start = start
            self.chars = chars
            self.text = NSString(characters: chars, length: chars.count)
            self.caret = caret - start
        }
    }

    /// `;` or a newline right before the caret with nothing but whitespace after it.
    static func isStatementBreak(_ source: NSString, caret: Int) -> Bool {
        guard caret > 0 else { return false }
        let before = source.character(at: caret - 1)
        guard before == 59 || before == 10 || before == 13 else { return false }
        var index = caret
        while index < source.length {
            switch source.character(at: index) {
            case 32, 9, 10, 13, 12: index += 1
            default: return false
            }
        }
        return true
    }

    struct StatementSpan {
        var start: Int
        var end: Int
        /// Comments and the closing `;` removed.
        var tokens: [SQLToken]
    }

    /// The statement containing `caret`, split at top-level `;`. Routine bodies (`CREATE PROCEDURE … BEGIN … END`)
    /// do not split. A caret right after a `;` belongs to the statement it ends (spec 2.1).
    static func statementSpan(_ tokens: [SQLToken], caret: Int, length: Int) -> StatementSpan {
        var start = 0
        var first = 0
        var blockDepth = 0
        var firstWord: String?
        var isRoutine = false
        var skipNext = false
        for (index, token) in tokens.enumerated() {
            if token.kind == .word {
                let word = token.upper
                if skipNext {
                    skipNext = false
                    continue
                }
                if firstWord == nil { firstWord = word }
                if firstWord == "CREATE", ["PROCEDURE", "FUNCTION", "TRIGGER", "EVENT"].contains(word) { isRoutine = true }
                if isRoutine {
                    if word == "BEGIN" || (word == "CASE" && blockDepth > 0) {
                        blockDepth += 1
                    } else if word == "END", blockDepth > 0 {
                        let next = tokens[(index + 1)...].first { $0.kind != .comment }
                        let closer = next?.kind == .word ? next?.upper : nil
                        if let closer, ["IF", "LOOP", "WHILE", "REPEAT"].contains(closer) { continue }
                        blockDepth -= 1
                        skipNext = closer == "CASE"
                    }
                }
                continue
            }
            guard token.isPunctuation(";"), blockDepth == 0 else { continue }
            let end = NSMaxRange(token.range)
            if caret <= token.range.location || caret == end {
                return StatementSpan(start: start, end: end, tokens: significant(tokens[first..<index]))
            }
            start = end
            first = index + 1
            firstWord = nil
            isRoutine = false
        }
        return StatementSpan(start: start, end: length, tokens: significant(tokens[first...]))
    }

    private static func significant(_ tokens: ArraySlice<SQLToken>) -> [SQLToken] {
        tokens.filter { $0.kind != .comment }
    }

    /// The last non-blank character before the token is a comma.
    private static func isAfterComma(_ chars: [unichar], before index: Int, lowerBound: Int) -> Bool {
        var i = index - 1
        while i >= lowerBound {
            switch chars[i] {
            case 32, 9, 10, 13, 12: i -= 1
            case 44: return true
            default: return false
            }
        }
        return false
    }
}

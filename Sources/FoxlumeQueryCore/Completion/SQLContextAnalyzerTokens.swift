import Foundation

/// Significant tokens of one statement (comments dropped) with precomputed uppercase words and paren matches,
/// shared by clause detection and table extraction.
struct SQLScanTokens {
    let items: [SQLToken]
    /// Uppercased value for bare words; "" for every other kind, so keyword checks never match quoted names.
    let upper: [String]
    /// Index of the matching paren for `(` and `)`; -1 when unmatched.
    let match: [Int]
    /// Decides which words are reserved; nil means any supported engine.
    let family: SQLDialect.Family?

    init(_ tokens: [SQLToken], family: SQLDialect.Family? = nil) {
        items = tokens
        self.family = family
        upper = tokens.map { $0.kind == .word ? $0.value.uppercased() : "" }
        var match = [Int](repeating: -1, count: tokens.count)
        var stack: [Int] = []
        for (index, token) in tokens.enumerated() where token.kind == .punctuation {
            if token.text == "(" {
                stack.append(index)
            } else if token.text == ")", let open = stack.popLast() {
                match[open] = index
                match[index] = open
            }
        }
        self.match = match
    }

    var count: Int { items.count }

    func isWord(_ index: Int, _ word: String) -> Bool {
        index >= 0 && index < items.count && upper[index] == word
    }

    func isAnyWord(_ index: Int, _ words: Set<String>) -> Bool {
        index >= 0 && index < items.count && !upper[index].isEmpty && words.contains(upper[index])
    }

    func isPunct(_ index: Int, _ text: String) -> Bool {
        index >= 0 && index < items.count && items[index].kind == .punctuation && items[index].text == text
    }

    /// A name usable as a path segment: bare word, quoted identifier, or a string (MySQL "x" lexes as one).
    func isName(_ index: Int) -> Bool {
        guard index >= 0 && index < items.count else { return false }
        switch items[index].kind {
        case .word, .quotedIdentifier: return true
        case .string: return !items[index].isUnterminated
        default: return false
        }
    }

    /// The name with quotes removed.
    func name(_ index: Int) -> String {
        let token = items[index]
        guard token.kind == .string else { return token.value }
        return String(token.text.dropFirst().dropLast())
    }

    /// `(` tokens still open at `end`, outermost first.
    func unclosedParens(before end: Int) -> [Int] {
        var stack: [Int] = []
        for index in 0..<min(end, items.count) where items[index].kind == .punctuation {
            if items[index].text == "(" {
                stack.append(index)
            } else if items[index].text == ")" {
                _ = stack.popLast()
            }
        }
        return stack
    }

    /// Parses `a`, `a.b` or `a.b.c` at `index` (bare or quoted segments). Nil when no name starts there or a dot
    /// is not followed by a name. An unquoted clause word after a dot makes the path invalid (`sales.|WHERE`).
    func path(at index: Int, end: Int? = nil) -> (segments: [String], next: Int)? {
        let limit = min(end ?? items.count, items.count)
        guard index < limit, isName(index) else { return nil }
        var segments = [name(index)]
        var next = index + 1
        while next < limit, isPunct(next, ".") {
            let segment = next + 1
            guard segment < limit, isName(segment) else { return nil }
            if items[segment].kind == .word, SQLCompletionReservedWords.clauseWords.contains(upper[segment]) { return nil }
            segments.append(name(segment))
            next = segment + 1
        }
        return (segments, next)
    }

    /// A path ending at `last`, read backwards; returns its first token index.
    func pathStart(endingAt last: Int) -> Int? {
        guard isName(last) else { return nil }
        var start = last
        while isPunct(start - 1, "."), isName(start - 2) {
            start -= 2
        }
        return start
    }

    /// A table alias candidate: a quoted name, or a bare word that is not reserved (spec A.4).
    func isAliasCandidate(_ index: Int) -> Bool {
        guard index >= 0 && index < items.count else { return false }
        switch items[index].kind {
        case .quotedIdentifier: return true
        case .word: return !isReservedWord(index)
        default: return false
        }
    }

    /// A bare word that cannot name a table or alias here: reserved by the engine, or a word that opens the next
    /// clause after a table in some engine.
    func isReservedWord(_ index: Int) -> Bool {
        index >= 0 && index < items.count && items[index].kind == .word
            && SQLCompletionReservedWords.rejectsAlias(upper[index], family: family)
    }

    /// A bare word the engine reserves (any engine when unknown).
    func isEngineReserved(_ index: Int) -> Bool {
        index >= 0 && index < items.count && items[index].kind == .word
            && SQLCompletionReservedWords.isEngineReserved(upper[index], family: family)
    }

    /// A `'…'` literal, which is a value even where `"…"` lexes as a string too (MySQL).
    func isStringLiteral(_ index: Int) -> Bool {
        index >= 0 && index < items.count && items[index].kind == .string && items[index].text.hasPrefix("'")
    }
}

extension SQLTableReference {
    /// Builds a reference from path segments: the last is the table, the second-to-last the schema (spec 3.1).
    init(segments: [String], alias: String?) {
        let schema = segments.count >= 2 ? segments[segments.count - 2] : nil
        self.init(schema: schema, table: segments.last ?? "", alias: alias)
    }
}

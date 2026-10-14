import Foundation

/// Redis command completion: commands at the start of a line (after an optional `DB n`), key names for arguments.
/// Replaces the SQL-service route TablePro takes for Redis (spec 9, A.14). Commands, subcommands and option words
/// are fixed case, canonical upper case (spec 5.3: plugin statement completions never follow the keyword case).
@MainActor
public final class RedisCompletionEngine: CompletionEngine {
    public weak var schema: CompletionSchemaProvider?

    static let keyLimit = 200
    static let maxRefilterToken = 500
    /// Leading arguments kept as text: `DB n`, the command and enough for a `numkeys` count.
    nonisolated static let keptWords = 8
    /// Units of one argument kept for matching; a longer argument at the caret is a value, never a name.
    nonisolated static let maxArgument = 1_024

    public init(schema: CompletionSchemaProvider?) {
        self.schema = schema
    }

    public var triggerCharacters: Set<Character> { [" "] }

    /// What is being typed at the caret.
    enum Slot: Equatable {
        case command
        /// Argument `index` (1-based) of `command` (upper-cased).
        case argument(command: String, index: Int)
    }

    struct Analysis: Equatable {
        /// The argument being typed, opening quote included.
        var tokenRange: NSRange
        var token: String
        /// The argument's text without quotes; what matching uses.
        var prefix: String
        /// `"` or `'` when the user opened a quoted argument.
        var quote: Character?
        /// Nil inside a comment line, while typing the index of `DB n`, or in an over-long argument.
        var slot: Slot?
        /// The command's leading arguments as typed, `words[0]` being the command (at most `keptWords`).
        var words: [String] = []
        /// Index of a bare `STREAMS` argument before the caret (XREAD).
        var streamsAt: Int?
    }

    /// The argument at the caret and the command it belongs to, splitting the line like redis-cli does
    /// (whitespace between arguments, `"…"` / `'…'` quoting, `;` between commands). One pass over the line that
    /// keeps only the first few arguments, so a long pasted value costs no more than walking over it.
    nonisolated static func analyze(_ text: String, caret rawCaret: Int) -> Analysis {
        let units = Array(text.utf16)
        let caret = min(max(0, rawCaret), units.count)
        var lineStart = caret
        while lineStart > 0, units[lineStart - 1] != 0x0A { lineStart -= 1 }

        var words: [String] = []
        var count = 0
        var streamsAt: Int?
        var current: [UInt16] = []
        var inArgument = false
        var currentStart = caret
        var quote: UInt16?
        var index = lineStart
        while index < caret {
            let c = units[index]
            if inArgument, current.count >= maxArgument {
                // Past what matching needs: skip to whatever can end the argument or change the quoting.
                let start = index
                if let open = quote {
                    while index < caret, units[index] != open, units[index] != 0x5C { index += 1 }
                } else {
                    while index < caret {
                        let u = units[index]
                        if u == 0x20 || u == 0x09 || u == 0x0D || u == 0x3B || u == 0x22 || u == 0x27 { break }
                        index += 1
                    }
                }
                if index > start { continue }
            }
            if let open = quote {
                var unit = c
                if c == 0x5C, index + 1 < caret, open == 0x22 || units[index + 1] == 0x27 {
                    index += 1
                    unit = units[index]
                } else if c == open {
                    quote = nil
                    index += 1
                    continue
                }
                if current.count < maxArgument { current.append(unit) }
                index += 1
                continue
            }
            switch c {
            case 0x20, 0x09, 0x0D:
                guard inArgument else { break }
                if count < keptWords { words.append(String(decoding: current, as: UTF16.self)) }
                if current.count == 7, String(decoding: current, as: UTF16.self).uppercased() == "STREAMS" { streamsAt = count }
                count += 1
                inArgument = false
            case 0x3B:
                words = []
                count = 0
                streamsAt = nil
                inArgument = false
            default:
                if !inArgument {
                    inArgument = true
                    currentStart = index
                    current.removeAll(keepingCapacity: true)
                }
                if c == 0x22 || c == 0x27 {
                    quote = c
                } else if current.count < maxArgument {
                    current.append(c)
                }
            }
            index += 1
        }

        let start = inArgument ? currentStart : caret
        let token = String(decoding: units[start..<caret], as: UTF16.self)
        var analysis = Analysis(
            tokenRange: NSRange(location: start, length: caret - start),
            token: token,
            prefix: inArgument ? String(decoding: current, as: UTF16.self) : "",
            quote: token.first.flatMap { $0 == "\"" || $0 == "'" ? $0 : nil }
        )
        guard current.count < maxArgument || !inArgument else { return analysis }
        let firstWord = words.first ?? token
        guard !firstWord.hasPrefix("#"), !firstWord.hasPrefix("//") else { return analysis }
        if words.first?.uppercased() == "DB" {
            // `DB n <command>`: nothing to offer for the index itself.
            guard count >= 2, Int(words[1]) != nil else { return analysis }
            words.removeFirst(2)
            count -= 2
            streamsAt = streamsAt.map { $0 - 2 }
        }
        analysis.words = words
        analysis.streamsAt = streamsAt
        analysis.slot = count == 0 ? .command : .argument(command: words[0].uppercased(), index: count)
        return analysis
    }

    /// The argument an accepted item replaces, opening quote included.
    nonisolated public static func tokenRange(in text: String, caret: Int) -> NSRange {
        analyze(text, caret: caret).tokenRange
    }

    public func complete(text: String, caret: Int, manual: Bool, keywordCase: KeywordCase) async -> CompletionResult? {
        let analysis = Self.analyze(text, caret: caret)
        guard let slot = analysis.slot else { return nil }
        let typed = manual || !analysis.token.isEmpty
        let items: [CompletionItem]
        switch slot {
        case .command:
            guard typed else { return nil }
            items = commandItems()
        case let .argument(name, index):
            guard let command = RedisCompletionVocabulary.command(named: name) else { return nil }
            let role = command.keyRole(at: index, words: analysis.words, streamsAt: analysis.streamsAt)
            // A possible key (BLPOP's timeout, an XREAD id) is offered once a name is being typed.
            let takesKey = role == .yes || (role == .maybe && typed && !Self.looksLikeValue(analysis.prefix))
            let takesSubcommand = index == 1 && !command.subcommands.isEmpty
            // Keys and subcommands open on the space after the command; option words wait for a letter.
            guard typed || role == .yes || takesSubcommand else { return nil }
            var words = takesSubcommand ? command.subcommands : []
            if command.offersOptions(at: index, words: analysis.words, streamsAt: analysis.streamsAt) { words += command.options }
            let keys = takesKey ? await keyItems(prefix: analysis.prefix, quote: analysis.quote) : []
            items = words.map { CompletionItem(label: $0, kind: .keyword) } + keys
        }
        let pool = ShellCompletionMatcher.deduplicated(items)
        let shown = Self.rank(pool, prefix: analysis.prefix)
        guard !shown.isEmpty else { return nil }
        return CompletionResult(
            items: shown,
            pool: pool,
            replacementRange: analysis.tokenRange,
            token: analysis.token,
            prefix: analysis.prefix,
            limit: .max,
            refilterState: CompletionRefilterState(context: slot == .command ? "command" : "argument")
        )
    }

    /// Commands keep their case, so `keywordCase` is ignored. Keys are re-quoted for the live token: the pool may
    /// have been built before the user typed an opening quote.
    public func refilter(_ result: CompletionResult, token: String, keywordCase: KeywordCase) -> [CompletionItem] {
        guard !token.isEmpty, token.utf16.count <= Self.maxRefilterToken,
              !token.contains(where: { $0.isWhitespace || $0 == ";" }) else { return [] }
        let quote = token.first.flatMap { $0 == "\"" || $0 == "'" ? $0 : nil }
        return Self.rank(result.pool, prefix: Self.unquoted(token)).map { item in
            guard item.kind == .key else { return item }
            var keyed = item
            keyed.insertText = Self.keyInsertText(item.label, quote: quote)
            return keyed
        }
    }

    // MARK: - Items

    /// Every command, then every favorite (A-Z); ranking keeps a favorite only when its keyword starts with the
    /// typed text (spec 7).
    private func commandItems() -> [CompletionItem] {
        // The detail is the reference syntax, `HGET key field`.
        let commands = RedisCompletionVocabulary.commands.map { command in
            CompletionItem(label: command.name, kind: .keyword, detail: command.arguments.map { command.name + " " + $0 } ?? command.name,
                           documentation: command.summary)
        }
        let favorites = (schema?.favorites() ?? [])
            .sorted { $0.keyword.lowercased() < $1.keyword.lowercased() }
            .map(ShellCompletionMatcher.favoriteItem)
        return commands + favorites
    }

    private func keyItems(prefix: String, quote: Character?) async -> [CompletionItem] {
        let names = await schema?.keyNames(prefix: prefix, limit: Self.keyLimit) ?? []
        return names.map { CompletionItem(label: $0, kind: .key, insertText: Self.keyInsertText($0, quote: quote)) }
    }

    /// Numbers, stream ids and `$` / `>` / `+` / `-` / `*` markers: values where a key might also fit.
    static func looksLikeValue(_ prefix: String) -> Bool {
        guard let first = prefix.unicodeScalars.first else { return false }
        return first.properties.numericType != nil || "$>+-*.".unicodeScalars.contains(first)
    }

    /// Keys go in bare unless the user opened a quote or the name would split or break the line. Single quotes
    /// only escape `'`, so a key with a backslash or a control character switches to the double-quoted form,
    /// where redis-cli reads `\\`, `\"`, `\n`, `\r`, `\t` and `\xHH`.
    static func keyInsertText(_ key: String, quote: Character?) -> String {
        let hasControl = key.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        if quote == "'", !hasControl, !key.contains("\\") {
            return "'" + key.replacingOccurrences(of: "'", with: "\\'") + "'"
        }
        let needsQuotes = key.isEmpty || hasControl || key.contains { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\" || $0 == ";" }
        guard quote != nil || needsQuotes else { return key }
        var quoted = "\""
        for scalar in key.unicodeScalars {
            switch scalar {
            case "\\": quoted += "\\\\"
            case "\"": quoted += "\\\""
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: quoted += String(format: "\\x%02x", scalar.value)
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }

    // MARK: - Matching

    /// Exact, then prefix, then substring matches; within a group by priority (favorites lead, then keys, then
    /// words), then list order. Favorites match only by prefix (spec 7).
    static func rank(_ items: [CompletionItem], prefix: String) -> [CompletionItem] {
        ShellCompletionMatcher.matches(items, prefix: prefix)
            .filter { $0.item.kind != .favorite || $0.match != .substring }
            .sorted { lhs, rhs in
                if lhs.match != rhs.match { return lhs.match < rhs.match }
                if lhs.item.priority != rhs.item.priority { return lhs.item.priority < rhs.item.priority }
                return lhs.index < rhs.index
            }
            .map(\.item)
    }

    static func unquoted(_ token: String) -> String {
        guard let first = token.first, first == "\"" || first == "'" else { return token }
        var text = token.dropFirst()
        if text.last == first { text = text.dropLast() }
        return String(text)
    }
}

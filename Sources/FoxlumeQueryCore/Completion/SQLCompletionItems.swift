import Foundation

/// Builds SQL suggestion rows: labels, details, documentation, insert text and casing behavior (spec 4.2, 5.1–5.2).
struct SQLCompletionItemBuilder {
    let family: SQLDialect.Family?
    /// The quote the user opened the token with; names are then inserted quoted (spec A.2).
    let typedQuote: Character?
    let keywordDocumentation: [String: String]

    init(family: SQLDialect.Family?, token: String) {
        self.family = family
        let first = token.first
        typedQuote = first == "`" || first == "\"" ? first : nil
        keywordDocumentation = SQLCompletionVocabulary.keywordDocumentation
    }

    /// Insert text for a dotted name, quoting segments that need it.
    func insertText(_ segments: [String]) -> String {
        SQLIdentifierQuoting.insertText(forPath: segments, family: family, typedQuote: typedQuote)
    }

    // MARK: Words

    /// Words written with lowercase letters carry a value (`ENGINE=InnoDB`, `CHARSET=utf8mb4`) and keep their spelling.
    func keyword(_ text: String, priority: Int? = nil) -> CompletionItem {
        let followsCase = !text.contains { $0.isLowercase }
        return CompletionItem(label: text, kind: .keyword, documentation: keywordDocumentation[text], priority: priority, followsKeywordCase: followsCase)
    }

    func keywords(_ list: [String], priority: Int? = nil) -> [CompletionItem] {
        list.map { keyword($0, priority: priority) }
    }

    /// `NAME()` with the caret inside, or the bare name for SQL-standard niladic functions (spec A.3).
    func function(_ entry: SQLFunctionEntry) -> CompletionItem {
        // A mixed-case name comes from an engine with case-sensitive function names; keep it as written.
        let caseInsensitive = entry.name == entry.name.uppercased() || entry.name == entry.name.lowercased()
        return CompletionItem(
            label: entry.name,
            kind: .function,
            detail: entry.signature.isEmpty ? "\(entry.name)(…)" : entry.signature,
            documentation: entry.summary,
            insertText: entry.isNiladic ? entry.name : entry.name + "()",
            caretOffsetFromEnd: entry.isNiladic ? 0 : 1,
            followsKeywordCase: caseInsensitive
        )
    }

    func `operator`(_ entry: SQLOperatorEntry) -> CompletionItem {
        CompletionItem(label: entry.symbol, kind: .operator, detail: entry.types, documentation: entry.summary, followsKeywordCase: true)
    }

    /// Types in CREATE TABLE and column definitions keep their spelling and follow the case setting.
    func dataType(_ name: String) -> CompletionItem {
        CompletionItem(label: name, kind: .keyword, priority: 380, followsKeywordCase: true)
    }

    /// Cast targets are always lowercase (spec 2.5).
    func castType(_ name: String) -> CompletionItem {
        CompletionItem(label: name, kind: .keyword, priority: 300)
    }

    func star(priority: Int, documentation: String? = nil) -> CompletionItem {
        CompletionItem(label: "*", kind: .keyword, detail: "All columns", documentation: documentation, priority: priority)
    }

    func tableStar(_ ref: SQLTableReference) -> CompletionItem {
        CompletionItem(
            label: "\(ref.identifier).*",
            kind: .keyword,
            detail: "All columns from \(ref.table)",
            insertText: insertText([ref.identifier]) + ".*",
            priority: 60
        )
    }

    // MARK: Names

    func table(_ info: TableInfo) -> CompletionItem {
        let isView = info.kind == .view || info.kind == .materializedView
        return CompletionItem(label: info.name, kind: isView ? .view : .table, detail: isView ? "View" : "Table", insertText: insertText([info.name]))
    }

    func schema(_ name: String) -> CompletionItem {
        CompletionItem(label: name, kind: .schema, detail: "Schema", insertText: insertText([name]))
    }

    func database(_ name: String) -> CompletionItem {
        CompletionItem(label: name, kind: .database, detail: "Database", insertText: insertText([name]))
    }

    /// A column row; `segments` is what gets inserted (`[col]` or `[ref, col]`).
    func column(_ info: ColumnInfo, table: String, segments: [String], priority: Int? = nil, withDetail: Bool = true) -> CompletionItem {
        var detail: [String] = []
        if info.isPrimaryKey { detail.append("PK") }
        if !info.isNullable { detail.append("NOT NULL") }
        if !info.dataType.isEmpty { detail.append(info.dataType) }
        var documentation = ["Column from \(table)"]
        if let value = info.defaultValue { documentation.append("Default: \(value)") }
        if let comment = info.comment, !comment.isEmpty { documentation.append(comment) }
        return CompletionItem(
            label: segments.joined(separator: "."),
            kind: .column,
            detail: withDetail && !detail.isEmpty ? detail.joined(separator: ", ") : nil,
            documentation: documentation.joined(separator: "\n"),
            insertText: insertText(segments),
            priority: priority
        )
    }

    /// A column of a derived table or CTE: no type is known.
    func derivedColumn(_ segments: [String], from source: String) -> CompletionItem {
        CompletionItem(label: segments.joined(separator: "."), kind: .column, documentation: "Column from \(source)", insertText: insertText(segments))
    }

    // MARK: Values and favorites

    /// `'active'` for a column restricted to a closed set of values (spec 3.6).
    func value(_ raw: String, column: String) -> CompletionItem {
        let literal = "'" + raw.replacingOccurrences(of: "'", with: "''") + "'"
        return CompletionItem(label: literal, kind: .keyword, detail: column, priority: 10, filterText: raw.lowercased())
    }

    /// The favorite's query; the first `;;` marks the caret and is removed (spec 5.2).
    func favorite(_ favorite: CompletionFavorite) -> CompletionItem {
        var insert = favorite.query
        var caretOffset = 0
        if let marker = favorite.query.range(of: ";;") {
            let after = favorite.query[marker.upperBound...]
            insert = String(favorite.query[..<marker.lowerBound]) + after
            caretOffset = after.utf16.count
        } else if insert.hasSuffix("()") {
            caretOffset = 1
        }
        return CompletionItem(
            label: favorite.keyword,
            kind: .favorite,
            detail: favorite.name,
            documentation: String(favorite.query.prefix(200)),
            insertText: insert,
            caretOffsetFromEnd: caretOffset
        )
    }

    // MARK: Allowed values

    /// Values of MySQL `enum(…)`/`set(…)` types and of `CHECK (col IN ('a', 'b'))` constraints found in the type or extra text.
    static func allowedValues(of column: ColumnInfo) -> [String] {
        let type = column.dataType.trimmingCharacters(in: .whitespaces)
        let lowered = type.lowercased()
        if lowered.hasPrefix("enum(") || lowered.hasPrefix("enum (") || lowered.hasPrefix("set(") || lowered.hasPrefix("set (") {
            return quotedStrings(in: type)
        }
        for source in [type, column.extra ?? ""] {
            let text = source as NSString
            let check = text.range(of: "check", options: .caseInsensitive)
            guard check.location != NSNotFound else { continue }
            let tail = text.substring(from: NSMaxRange(check))
            let upper = tail.uppercased()
            guard upper.range(of: #"\bIN\s*\("#, options: .regularExpression) != nil || upper.contains("ANY") else { continue }
            let values = quotedStrings(in: tail)
            if !values.isEmpty { return values }
        }
        return []
    }

    /// Every `'…'` literal in order (`''` and backslash escapes honored), de-duplicated.
    static func quotedStrings(in text: String) -> [String] {
        var values: [String] = []
        var current = ""
        var inside = false
        var iterator = Array(text).makeIterator()
        var pending: Character? = nil
        while let character = pending ?? iterator.next() {
            pending = nil
            if !inside {
                if character == "'" {
                    inside = true
                    current = ""
                }
                continue
            }
            if character == "\\" {
                if let escaped = iterator.next() { current.append(escaped) }
                continue
            }
            if character == "'" {
                if let next = iterator.next() {
                    if next == "'" {
                        current.append("'")
                        continue
                    }
                    pending = next
                }
                inside = false
                if !current.isEmpty, !values.contains(current) { values.append(current) }
                continue
            }
            current.append(character)
        }
        return values
    }
}

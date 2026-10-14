import Foundation

/// Table references of a whole statement (spec 3.1–3.2): FROM lists, joins, DML/DDL targets, derived tables and CTEs.
enum SQLTableExtractor {
    struct Result {
        var references: [SQLTableReference] = []
        var cteNames: [String] = []
        var target: SQLTableReference?
    }

    /// Words that end a FROM list.
    private static let fromListEnd: Set<String> = [
        "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS",
        "NATURAL", "ON", "USING", "UNION", "INTERSECT", "EXCEPT", "RETURNING", "SET", "WINDOW", "FETCH", "FOR",
        "STRAIGHT_JOIN",
    ]
    /// `… UPDATE` that is not an UPDATE statement (`ON DUPLICATE KEY UPDATE`, `DO UPDATE`, `FOR UPDATE`, grants, triggers).
    private static let notUpdateStatement: Set<String> = ["KEY", "DO", "FOR", "ON", "OF", "BEFORE", "AFTER", "INSTEAD", "GRANT", "REVOKE"]
    /// Words that end a SELECT list.
    private static let selectListEnd: Set<String> = [
        "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "UNION", "INTERSECT", "EXCEPT", "WINDOW",
        "FETCH", "INTO", "FOR",
    ]

    static func extract(_ t: SQLScanTokens) -> Result {
        let owner = enclosingParens(t)
        var refs: [SQLTableReference] = []
        var target: SQLTableReference?

        // 1. FROM lists. A FROM inside a function call (EXTRACT(… FROM x), TRIM(… FROM x)) names no table.
        for i in 0..<t.count where t.upper[i] == "FROM" {
            if owner[i] >= 0, !t.isWord(owner[i] + 1, "SELECT") { continue }
            // A derived table or table function is stepped over whole, so the entries after it are still read.
            var end = i + 1
            while end < t.count, !t.isPunct(end, ")"), !t.isPunct(end, ";"), !t.isAnyWord(end, fromListEnd) {
                if t.isPunct(end, "(") {
                    guard t.match[end] > end else { break }
                    end = t.match[end]
                }
                end += 1
            }
            var start = i + 1
            var j = i + 1
            while j <= end {
                if j < end, t.isPunct(j, "("), t.match[j] > j {
                    j = t.match[j] + 1
                    continue
                }
                if j == end || t.isPunct(j, ",") {
                    if let ref = entry(t, from: start, to: j) { refs.append(ref) }
                    start = j + 1
                }
                j += 1
            }
        }
        // 2. Joins.
        for i in 0..<t.count where t.upper[i] == "JOIN" {
            var j = i + 1
            if t.isWord(j, "LATERAL") { j += 1 }
            if let ref = entry(t, from: j, to: t.count) { refs.append(ref) }
        }
        // 3. UPDATE target.
        for i in 0..<t.count where t.upper[i] == "UPDATE" {
            if t.isAnyWord(i - 1, notUpdateStatement) || t.isPunct(i - 1, ",") { continue }
            var j = i + 1
            while t.isAnyWord(j, ["LOW_PRIORITY", "IGNORE", "ONLY"]) { j += 1 }
            if let ref = entry(t, from: j, to: t.count) {
                refs.append(ref)
                target = target ?? ref
            }
        }
        // 4. INSERT INTO target (no alias).
        for i in 0..<t.count where t.upper[i] == "INTO" {
            let isInsert = stride(from: i - 1, through: max(0, i - 3), by: -1).contains { t.isAnyWord($0, ["INSERT", "REPLACE"]) }
            guard isInsert, let path = t.path(at: i + 1) else { continue }
            let ref = SQLTableReference(segments: path.segments, alias: nil)
            refs.append(ref)
            target = target ?? ref
        }
        // 5. CREATE [UNIQUE] INDEX … ON target.
        if t.isWord(0, "CREATE"), t.isWord(1, "INDEX") || (t.isWord(1, "UNIQUE") && t.isWord(2, "INDEX")) {
            if let on = (0..<t.count).first(where: { t.upper[$0] == "ON" && owner[$0] < 0 }) {
                let j = t.isWord(on + 1, "ONLY") ? on + 2 : on + 1
                if let path = t.path(at: j) {
                    let ref = SQLTableReference(segments: path.segments, alias: nil)
                    refs.append(ref)
                    target = target ?? ref
                }
            }
        }

        // 6–7. Derived tables and CTEs attach their columns to references naming them, or join the scope themselves.
        let (derived, ctes) = derivedTables(t)
        for (alias, columns) in derived + ctes.map({ ($0.name, $0.columns) }) {
            let key = alias.lowercased()
            var attached = false
            for index in refs.indices where refs[index].table.lowercased() == key || refs[index].identifier.lowercased() == key {
                attached = true
                if !columns.isEmpty { refs[index].derivedColumns = columns }
            }
            if !attached { refs.append(SQLTableReference(table: alias, derivedColumns: columns)) }
        }

        // 8. ALTER TABLE target.
        if t.isWord(0, "ALTER"), t.isWord(1, "TABLE") {
            var j = 2
            if t.isWord(j, "IF"), t.isWord(j + 1, "EXISTS") { j += 2 }
            if t.isWord(j, "ONLY") { j += 1 }
            if let path = t.path(at: j) {
                let ref = SQLTableReference(segments: path.segments, alias: nil)
                refs.append(ref)
                target = target ?? ref
            }
        }

        var seen = Set<String>()
        let unique = refs.filter { ref in
            seen.insert("\(ref.schema?.lowercased() ?? "")\u{1}\(ref.table.lowercased())\u{1}\(ref.alias?.lowercased() ?? "")").inserted
        }
        return Result(references: unique, cteNames: ctes.map(\.name), target: target)
    }

    /// One FROM/JOIN/UPDATE entry: `path [AS] [alias]`. Anything that is not a plain path (a derived table) is skipped.
    private static func entry(_ t: SQLScanTokens, from start: Int, to end: Int) -> SQLTableReference? {
        var i = start
        while i < end, t.isAnyWord(i, ["ONLY", "LATERAL"]) { i += 1 }
        guard i < end, !t.isAnyWord(i, SQLCompletionReservedWords.clauseWords), let path = t.path(at: i, end: end) else { return nil }
        var k = path.next
        if k < end, t.isWord(k, "AS") { k += 1 }
        let alias = k < end && t.isAliasCandidate(k) ? t.name(k) : nil
        return SQLTableReference(segments: path.segments, alias: alias)
    }

    /// For each token, the index of the innermost `(` around it, or -1.
    private static func enclosingParens(_ t: SQLScanTokens) -> [Int] {
        var owner = [Int](repeating: -1, count: t.count)
        var stack: [Int] = []
        for i in 0..<t.count {
            if t.isPunct(i, ")") { _ = stack.popLast() }
            owner[i] = stack.last ?? -1
            if t.isPunct(i, "(") { stack.append(i) }
        }
        return owner
    }

    struct CTE {
        var name: String
        var columns: [String]
    }

    /// Derived tables `[LATERAL] (SELECT …) alias` after FROM/JOIN/a FROM-list comma, and CTEs `name [(cols)] AS (…)` (spec 3.2).
    static func derivedTables(_ t: SQLScanTokens) -> (derived: [(String, [String])], ctes: [CTE]) {
        var derived: [(String, [String])] = []
        var ctes: [CTE] = []
        var p = 0
        while p < t.count {
            guard t.isPunct(p, "(") else {
                p += 1
                continue
            }
            let close = t.match[p]
            let bodyEnd = close > p ? close : t.count
            let isQuery = t.isWord(p + 1, "SELECT")
            let lead = t.isWord(p - 1, "LATERAL") ? p - 2 : p - 1
            if isQuery, t.isAnyWord(lead, ["FROM", "JOIN"]) || (t.isPunct(lead, ",") && commaContinuesFromList(t, comma: lead)) {
                guard close > p else {
                    p += 1
                    continue
                }
                var k = close + 1
                if t.isWord(k, "AS") { k += 1 }
                if t.isAliasCandidate(k) {
                    derived.append((t.name(k), outputColumns(t, from: p + 1, to: bodyEnd)))
                }
                // A derived table nested inside this one is not visible outside it.
                p = close + 1
                continue
            }
            if let header = cteHeader(t, paren: p) {
                let columns = header.columns ?? (isQuery ? outputColumns(t, from: p + 1, to: bodyEnd) : [])
                ctes.append(CTE(name: header.name, columns: columns))
            }
            p += 1
        }
        return (derived, ctes)
    }

    /// `name [(a, b)] AS [[NOT] MATERIALIZED] (` right before `paren`, where `name` follows WITH, RECURSIVE or a comma.
    private static func cteHeader(_ t: SQLScanTokens, paren: Int) -> (name: String, columns: [String]?)? {
        var j = paren - 1
        if t.isWord(j, "MATERIALIZED") {
            j -= 1
            if t.isWord(j, "NOT") { j -= 1 }
        }
        guard t.isWord(j, "AS") else { return nil }
        j -= 1
        var columns: [String]?
        if t.isPunct(j, ")") {
            let open = t.match[j]
            guard open >= 0 else { return nil }
            columns = (open + 1..<j).filter { t.isName($0) && !t.isStringLiteral($0) }.map { t.name($0) }
            j = open - 1
        }
        guard t.isName(j), t.isWord(j - 1, "WITH") || t.isWord(j - 1, "RECURSIVE") || t.isPunct(j - 1, ",") else { return nil }
        return (t.name(j), columns)
    }

    /// Whether the comma at `comma` separates FROM-list entries, by finding the clause keyword that governs it.
    private static func commaContinuesFromList(_ t: SQLScanTokens, comma: Int) -> Bool {
        var j = comma - 1
        while j >= 0 {
            if t.isPunct(j, ")") {
                guard t.match[j] >= 0 else { return false }
                j = t.match[j] - 1
                continue
            }
            if t.isPunct(j, "(") { return false }
            if t.isAnyWord(j, ["FROM", "JOIN"]) { return true }
            if t.isAnyWord(j, ["SELECT", "WHERE", "ON", "SET", "VALUES", "BY", "HAVING", "INTO", "RETURNING", "USING", "WITH", "UNION", "INTERSECT", "EXCEPT"]) {
                return false
            }
            j -= 1
        }
        return false
    }

    /// Output column names of the SELECT at `start` (spec 3.2): aliases, bare column paths, and (beyond TablePro)
    /// implicit aliases such as `count(*) n`. Expressions without a name and stars are skipped.
    static func outputColumns(_ t: SQLScanTokens, from start: Int, to end: Int) -> [String] {
        guard t.isWord(start, "SELECT") else { return [] }
        var i = start + 1
        while i < end, t.isAnyWord(i, ["DISTINCT", "ALL"]) {
            if t.isWord(i, "DISTINCT"), t.isWord(i + 1, "ON"), t.isPunct(i + 2, "("), t.match[i + 2] > i + 2 {
                i = t.match[i + 2] + 1
            } else {
                i += 1
            }
        }
        var items: [(Int, Int)] = []
        var itemStart = i
        var depth = 0
        var j = i
        while j < end {
            if t.isPunct(j, "(") {
                depth += 1
            } else if t.isPunct(j, ")") {
                depth -= 1
                if depth < 0 { break }
            } else if depth == 0 {
                if t.isAnyWord(j, selectListEnd) { break }
                if t.isPunct(j, ",") {
                    items.append((itemStart, j))
                    itemStart = j + 1
                }
            }
            j += 1
        }
        items.append((itemStart, j))

        var names: [String] = []
        var seen = Set<String>()
        for (a, b) in items where b > a {
            guard let name = itemName(t, from: a, to: b), seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names
    }

    private static func itemName(_ t: SQLScanTokens, from a: Int, to b: Int) -> String? {
        var depth = 0
        for k in a..<b {
            if t.isPunct(k, "(") { depth += 1 }
            if t.isPunct(k, ")") { depth -= 1 }
            if depth == 0, t.isWord(k, "AS") {
                return k + 1 < b && t.isName(k + 1) ? t.name(k + 1) : nil
            }
        }
        if let path = t.path(at: a, end: b), path.next == b {
            // A lone literal or reserved word (`'hello'`, `NULL`, `CURRENT_DATE`) is an expression, not a column.
            if path.segments.count == 1, t.isEngineReserved(a) || t.isStringLiteral(a) { return nil }
            return path.segments.last
        }
        let last = b - 1
        guard b - a >= 2, t.isAliasCandidate(last) else { return nil }
        let before = t.items[last - 1]
        switch before.kind {
        case .number, .string, .quotedIdentifier: return t.name(last)
        case .word: return t.isEngineReserved(last - 1) && t.upper[last - 1] != "END" ? nil : t.name(last)
        case .punctuation: return before.text == ")" ? t.name(last) : nil
        default: return nil
        }
    }
}

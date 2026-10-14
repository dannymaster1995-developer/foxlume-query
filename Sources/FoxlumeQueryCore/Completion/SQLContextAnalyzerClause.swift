import Foundation

/// Clause detection (spec 2.4) over the significant tokens that precede the typed token.
enum SQLClauseDetector {
    struct Result {
        var clause: SQLClause = .unknown
        var expectsObjectName = false
        var insideCreateTableColumns = false
        var nestingLevel = 0
        var currentFunction: String?
        var comparisonColumn: String?
    }

    static func detect(_ t: SQLScanTokens) -> Result {
        var result = Result()
        let unclosed = t.unclosedParens(before: t.count)
        result.nestingLevel = unclosed.count
        result.currentFunction = currentFunction(t, unclosed: unclosed)
        result.comparisonColumn = comparisonColumn(t)

        // Step 0: inside a parenthesized subquery only its own text decides the clause.
        var scope = 0
        for paren in unclosed.reversed() where t.isAnyWord(paren + 1, subqueryStarts) {
            scope = paren + 1
            break
        }
        // CREATE VIEW … AS <query>: the query is analyzed like any other (spec A.7).
        switch createView(t, from: scope, unclosed: unclosed) {
        case .context:
            result.clause = .createView
            return result
        case .body(let start):
            scope = start
        case nil:
            break
        }
        let open = unclosed.filter { $0 >= scope }
        if let structural = structuralRule(t, from: scope, unclosed: open, result: &result) {
            result.clause = structural
            return result
        }
        if let (clause, expects) = nearestKeyword(t, from: scope) {
            result.clause = clause
            result.expectsObjectName = expects
            return result
        }
        if result.currentFunction != nil {
            result.clause = .functionArgument
        }
        return result
    }

    static let subqueryStarts: Set<String> = ["SELECT", "INSERT", "UPDATE", "DELETE"]

    // MARK: Structural rules (spec 2.4 step 2, rules 1–25)

    private static func structuralRule(_ t: SQLScanTokens, from s: Int, unclosed: [Int], result: inout Result) -> SQLClause? {
        if let clause = alterTable(t, from: s) { return clause }
        if let inside = createTable(t, from: s, unclosed: unclosed) {
            result.insideCreateTableColumns = inside
            return .createTable
        }
        if dropObject(t, from: s) {
            result.expectsObjectName = true
            return .dropObject
        }
        if let expectsTable = createIndex(t, from: s, unclosed: unclosed) {
            result.expectsObjectName = expectsTable
            return .createIndex
        }
        let innermost = unclosed.last
        if let u = innermost, t.isWord(u - 1, "USING") { return .using }
        if let u = innermost, t.isWord(u - 1, "OVER") { return .window }
        if partitionByStillOpen(t, from: s) { return .window }
        if let u = innermost, t.isWord(u - 1, "IN") { return .inList }
        if t.count - 1 >= s, t.isAnyWord(t.count - 1, ["LIMIT", "OFFSET"]) { return .limit }
        if valuesTuplesThenEnd(t, from: s) { return .values }
        // Any open tuple counts, so `VALUES (lower(|` stays VALUES.
        if unclosed.contains(where: { isValuesTuple(t, paren: $0, from: s) }) { return .values }
        if let u = innermost, isInsertColumnList(t, paren: u, from: s) { return .insertColumns }
        return nil
    }

    /// Words that cannot be the column name in `ADD <name> <type>`.
    private static let notColumnNames: Set<String> = [
        "INDEX", "KEY", "CONSTRAINT", "PRIMARY", "UNIQUE", "FOREIGN", "CHECK", "FULLTEXT", "SPATIAL", "COLUMN", "PARTITION",
    ]
    private static let columnModifiers: Set<String> = ["NULL", "AUTO_INCREMENT", "UNSIGNED"]

    /// Rules 1–9.
    private static func alterTable(_ t: SQLScanTokens, from s: Int) -> SQLClause? {
        guard t.isWord(s, "ALTER") else { return nil }
        let last = t.count - 1
        // Rules 1–3, kept to ALTER statements so `NULLS FIRST` elsewhere stays a normal clause.
        if last > s, t.isAnyWord(last, ["AFTER", "BEFORE"]) { return .alterTableColumn }
        if last > s, t.isWord(last, "FIRST") { return .alterTable }
        guard t.isWord(s + 1, "TABLE") else { return nil }
        var i = s + 2
        if t.isWord(i, "IF"), t.isWord(i + 1, "EXISTS") { i += 2 }
        if t.isWord(i, "ONLY") { i += 1 }
        guard let target = t.path(at: i) else { return nil }
        // Several actions may be chained with commas; only the one being typed matters.
        var start = target.next
        var depth = 0
        for j in target.next..<t.count {
            if t.isPunct(j, "(") { depth += 1 }
            if t.isPunct(j, ")") { depth = max(0, depth - 1) }
            if depth == 0, t.isPunct(j, ",") { start = j + 1 }
        }
        let length = t.count - start
        if length == 0 { return .alterTable }
        if length == 2, t.isWord(start, "ADD"), t.isWord(start + 1, "CONSTRAINT") { return .alterTable }
        if length == 1, t.isWord(start, "ADD") { return .alterTable }
        if isColumnDefinition(t, from: start) { return .columnDefinition }
        // PostgreSQL's `ALTER [COLUMN] x` names a column the same way.
        if t.isAnyWord(start, ["DROP", "MODIFY", "CHANGE", "RENAME", "ALTER"]) {
            if length == 1 || (length == 2 && t.isWord(start + 1, "COLUMN")) { return .alterTableColumn }
        }
        return nil
    }

    /// Rules 6–7: `ADD|MODIFY|CHANGE [COLUMN] <name> [<type>[(…)] [modifiers…]]` up to the caret.
    private static func isColumnDefinition(_ t: SQLScanTokens, from start: Int) -> Bool {
        guard t.isAnyWord(start, ["ADD", "MODIFY", "CHANGE"]) else { return false }
        var i = start + 1
        if t.isWord(i, "COLUMN") { i += 1 }
        guard i < t.count, t.isName(i), !t.isAnyWord(i, notColumnNames) else { return false }
        i += 1
        if i == t.count { return true }
        guard t.items[i].kind == .word else { return false }
        i += 1
        if t.isPunct(i, "(") {
            let close = t.match[i]
            guard close > i else { return false }
            i = close + 1
        }
        while i < t.count {
            if t.isWord(i, "NOT"), t.isWord(i + 1, "NULL") {
                i += 2
            } else if t.isAnyWord(i, columnModifiers) {
                i += 1
            } else if t.isWord(i, "DEFAULT"), i + 1 < t.count {
                i += 2
            } else if t.isWord(i, "COMMENT"), i + 1 < t.count, t.items[i + 1].kind == .string {
                i += 2
            } else {
                return false
            }
        }
        return true
    }

    /// Rules 10–12. Returns whether the caret is inside the column list, or nil when this is not a CREATE TABLE
    /// position. The column-list paren is tracked even after nested parens close (spec A.5).
    private static func createTable(_ t: SQLScanTokens, from s: Int, unclosed: [Int]) -> Bool? {
        guard t.isWord(s, "CREATE") else { return nil }
        var i = s + 1
        if t.isWord(i, "OR"), t.isWord(i + 1, "REPLACE") { i += 2 }
        while t.isAnyWord(i, ["TEMPORARY", "TEMP", "GLOBAL", "LOCAL", "UNLOGGED"]) { i += 1 }
        guard t.isWord(i, "TABLE") else { return nil }
        i += 1
        if t.isWord(i, "IF"), t.isWord(i + 1, "NOT"), t.isWord(i + 2, "EXISTS") { i += 3 }
        if i == t.count { return false }
        guard let name = t.path(at: i), t.isPunct(name.next, "(") else { return nil }
        let paren = name.next
        if unclosed.contains(paren) { return true }
        let close = t.match[paren]
        guard close > paren else { return nil }
        // After the column list come table options, unless the statement goes on with a query.
        for j in (close + 1)..<max(close + 1, t.count) where t.isAnyWord(j, ["AS", "SELECT"]) { return nil }
        return false
    }

    /// Rule 13, also after a comma-separated list of names (`DROP TABLE a, |`).
    private static func dropObject(_ t: SQLScanTokens, from s: Int) -> Bool {
        guard t.isWord(s, "DROP") else { return false }
        var i = s + 1
        if t.isWord(i, "MATERIALIZED") { i += 1 }
        guard t.isAnyWord(i, ["TABLE", "VIEW", "INDEX"]) else { return false }
        i += 1
        if t.isWord(i, "IF"), t.isWord(i + 1, "EXISTS") { i += 2 }
        while i < t.count {
            guard let name = t.path(at: i), t.isPunct(name.next, ",") else { return false }
            i = name.next + 1
        }
        return true
    }

    /// Rules 14–15. Returns whether a table name is expected (true before the table, false in its column list),
    /// or nil when this is not a CREATE INDEX position. `CREATE INDEX idx ON |` offers tables (spec A.6).
    private static func createIndex(_ t: SQLScanTokens, from s: Int, unclosed: [Int]) -> Bool? {
        guard t.isWord(s, "CREATE") else { return nil }
        var i = s + 1
        if t.isWord(i, "UNIQUE") { i += 1 }
        guard t.isWord(i, "INDEX") else { return nil }
        i += 1
        if t.isWord(i, "CONCURRENTLY") { i += 1 }
        if t.isWord(i, "IF"), t.isWord(i + 1, "NOT"), t.isWord(i + 2, "EXISTS") { i += 3 }
        if i == t.count { return true }
        if !t.isWord(i, "ON") {
            guard let name = t.path(at: i) else { return nil }
            if name.next == t.count { return true }
            guard t.isWord(name.next, "ON") else { return nil }
            i = name.next
        }
        i += 1
        if t.isWord(i, "ONLY") { i += 1 }
        if i == t.count { return true }
        guard let table = t.path(at: i) else { return nil }
        var paren = table.next
        if t.isWord(paren, "USING"), paren + 1 < t.count { paren += 2 }
        guard t.isPunct(paren, "("), unclosed.contains(paren) else { return nil }
        return false
    }

    enum ViewShape: Equatable {
        /// Before the body: offer `AS`, `SELECT` and tables.
        case context
        /// The body's first token.
        case body(Int)
    }

    /// Rules 16–17, with the body after `AS` analyzed as a query.
    static func createView(_ t: SQLScanTokens, from s: Int, unclosed: [Int]) -> ViewShape? {
        guard t.isWord(s, "CREATE") else { return nil }
        var i = s + 1
        if t.isWord(i, "OR"), t.isWord(i + 1, "REPLACE") { i += 2 }
        while t.isAnyWord(i, ["TEMPORARY", "TEMP", "MATERIALIZED", "RECURSIVE"]) { i += 1 }
        guard t.isWord(i, "VIEW") else { return nil }
        i += 1
        if t.isWord(i, "IF"), t.isWord(i + 1, "NOT"), t.isWord(i + 2, "EXISTS") { i += 3 }
        if i == t.count { return .context }
        guard let name = t.path(at: i) else { return nil }
        var k = name.next
        if k == t.count { return .context }
        if t.isPunct(k, "(") {
            if unclosed.contains(k) { return .context }
            k = t.match[k] + 1
        }
        if t.isWord(k, "WITH"), t.isPunct(k + 1, "("), t.match[k + 1] > k + 1 { k = t.match[k + 1] + 1 }
        guard t.isWord(k, "AS") else { return nil }
        return k + 1 == t.count ? .context : .body(k + 1)
    }

    /// Rule 20: `PARTITION BY` with no `)` after it.
    private static func partitionByStillOpen(_ t: SQLScanTokens, from s: Int) -> Bool {
        var j = t.count - 2
        while j >= s {
            if t.isPunct(j + 1, ")") { return false }
            if t.isWord(j, "PARTITION"), t.isWord(j + 1, "BY") { return true }
            j -= 1
        }
        return false
    }

    /// Rule 23: `VALUES (…)[, (…)]` and then nothing but the typed word.
    private static func valuesTuplesThenEnd(_ t: SQLScanTokens, from s: Int) -> Bool {
        var values = -1
        for j in stride(from: t.count - 1, through: s, by: -1) where t.isWord(j, "VALUES") {
            values = j
            break
        }
        guard values >= 0 else { return false }
        var k = values + 1
        var tuples = 0
        while k < t.count {
            if t.isPunct(k, "(") {
                let close = t.match[k]
                guard close > k else { return false }
                k = close + 1
                tuples += 1
            } else if t.isPunct(k, ",") {
                k += 1
            } else {
                return false
            }
        }
        return tuples > 0
    }

    /// Rule 24: the open paren is a VALUES tuple (`VALUES (|` or `VALUES (1), (|`).
    private static func isValuesTuple(_ t: SQLScanTokens, paren: Int, from s: Int) -> Bool {
        var j = paren - 1
        while j >= s {
            if t.isWord(j, "VALUES") { return true }
            if t.isPunct(j, ",") {
                j -= 1
            } else if t.isPunct(j, ")"), t.match[j] >= 0, t.isPunct(j + 1, ",") {
                // A finished tuple before this one.
                j = t.match[j] - 1
            } else {
                return false
            }
        }
        return false
    }

    /// Rule 25: `INSERT INTO <path> (`; schema-qualified names count too (spec A.8).
    private static func isInsertColumnList(_ t: SQLScanTokens, paren: Int, from s: Int) -> Bool {
        guard let start = t.pathStart(endingAt: paren - 1), start - 1 >= s, t.isWord(start - 1, "INTO") else { return false }
        for j in stride(from: start - 2, through: max(s, start - 4), by: -1) where t.isAnyWord(j, ["INSERT", "REPLACE"]) {
            return true
        }
        return false
    }

    // MARK: Nearest clause keyword (step 3)

    static func nearestKeyword(_ t: SQLScanTokens, from lower: Int) -> (SQLClause, Bool)? {
        var depth = 0
        var pendingCase = 0
        var sawObject = false
        var slotClosed = false
        var i = t.count - 1
        while i >= lower {
            let token = t.items[i]
            let index = i
            i -= 1
            if token.kind == .punctuation {
                switch token.text {
                case ")": depth += 1
                case "(": if depth > 0 { depth -= 1 }
                case ",": if depth == 0, pendingCase == 0, !sawObject { slotClosed = true }
                default: break
                }
                continue
            }
            guard depth == 0 else { continue }
            if token.kind == .quotedIdentifier {
                if pendingCase == 0, !slotClosed { sawObject = true }
                continue
            }
            guard token.kind == .word else { continue }
            let word = t.upper[index]
            if pendingCase > 0 {
                if word == "END" { pendingCase += 1 } else if word == "CASE" { pendingCase -= 1 }
                continue
            }
            switch word {
            case "END": pendingCase = 1
            case "CASE", "WHEN", "THEN", "ELSE": return (.caseExpression, false)
            case "SELECT": return (.selectList, false)
            case "FROM": return (.from, !sawObject)
            case "JOIN": return (.join, !sawObject)
            case "INTO": return (.into, !sawObject)
            case "ON": return (.on, false)
            case "WHERE": return (.whereClause, false)
            case "AND", "OR": return (.and, false)
            case "HAVING": return (.having, false)
            case "SET": return (.set, false)
            case "RETURNING": return (.returning, false)
            case "UNION", "INTERSECT", "EXCEPT": return (.union, false)
            case "BY":
                if t.isWord(index - 1, "GROUP") { return (.groupBy, false) }
                if t.isWord(index - 1, "ORDER") { return (.orderBy, false) }
                if t.isWord(index - 1, "PARTITION") { return (.window, false) }
                if !slotClosed { sawObject = true }
            default:
                if !slotClosed { sawObject = true }
            }
        }
        return nil
    }

    // MARK: Other facts

    /// Words that open a paren without being a function call.
    private static let notFunctions: Set<String> = [
        "SELECT", "FROM", "WHERE", "IN", "EXISTS", "NOT", "VALUES", "USING", "OVER", "ON", "AS", "AND", "OR", "INTO",
        "JOIN", "TABLE", "WITH", "RECURSIVE", "RETURNING", "BY", "WHEN", "THEN", "ELSE", "CASE", "HAVING", "SET",
        "UNION", "INTERSECT", "EXCEPT", "ALL", "ANY", "SOME", "LATERAL", "REFERENCES", "KEY", "INDEX", "UNIQUE",
        "PRIMARY", "CHECK", "CONSTRAINT", "FOREIGN", "VIEW", "LIKE", "ILIKE", "IS", "BETWEEN", "DISTINCT", "OF", "TO",
    ]

    /// The function whose `(` is the innermost open one. Only the token right before the paren counts, so
    /// `SELECT a, (|` has none (spec A.12).
    private static func currentFunction(_ t: SQLScanTokens, unclosed: [Int]) -> String? {
        guard let paren = unclosed.last, paren > 0 else { return nil }
        let before = paren - 1
        switch t.items[before].kind {
        case .quotedIdentifier: return t.items[before].value
        case .word: return notFunctions.contains(t.upper[before]) ? nil : t.items[before].value
        default: return nil
        }
    }

    private static let comparisonSymbols: Set<String> = ["<>", "!=", "<=", ">=", "=", "<", ">"]
    private static let notComparedNames: Set<String> = [
        "AND", "OR", "NOT", "WHERE", "ON", "HAVING", "SELECT", "SET", "WHEN", "THEN", "ELSE", "BY",
    ]

    /// `status` in `WHERE status = |`, `u.status IN |` or `status NOT LIKE |`.
    private static func comparisonColumn(_ t: SQLScanTokens) -> String? {
        let last = t.count - 1
        guard last >= 1 else { return nil }
        let op = t.items[last]
        let wordOperator = t.isAnyWord(last, ["IN", "LIKE", "ILIKE"])
        guard (op.kind == .symbol && comparisonSymbols.contains(op.text)) || wordOperator else { return nil }
        var j = last - 1
        if wordOperator, t.isWord(j, "NOT") { j -= 1 }
        guard j >= 0 else { return nil }
        switch t.items[j].kind {
        case .quotedIdentifier: return t.items[j].value
        case .word: return notComparedNames.contains(t.upper[j]) ? nil : t.items[j].value
        default: return nil
        }
    }
}

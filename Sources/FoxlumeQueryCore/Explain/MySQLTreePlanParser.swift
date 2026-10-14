import Foundation

/// Reads the indented `->` tree MySQL prints for `EXPLAIN ANALYZE` and `EXPLAIN FORMAT=TREE`:
///
///     -> Nested loop inner join  (cost=31.5 rows=50) (actual time=0.346..0.431 rows=50 loops=1)
///         -> Index lookup on o using orders_status_idx (status='paid')  (cost=14 rows=50) (actual time=…)
public enum MySQLTreePlanParser {
    static let maximumNodes = 20_000

    public static func parse(_ text: String) -> QueryPlan? {
        var lines: [(indent: Int, text: String)] = []
        for line in text.components(separatedBy: .newlines) {
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let rest = line.dropFirst(leading.count)
            if rest.hasPrefix("->") {
                let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                lines.append((indent, rest.dropFirst(2).trimmingCharacters(in: .whitespaces)))
                guard lines.count <= maximumNodes else { return nil }
            } else if !lines.isEmpty, !rest.trimmingCharacters(in: .whitespaces).isEmpty {
                // A literal in the query can break a node's text over several lines.
                lines[lines.count - 1].text += " " + rest.trimmingCharacters(in: .whitespaces)
            }
        }
        guard !lines.isEmpty else { return nil }

        var index = 0
        func children(deeperThan indent: Int) -> [QueryPlanNode] {
            var nodes: [QueryPlanNode] = []
            while index < lines.count, lines[index].indent > indent {
                let line = lines[index]
                index += 1
                var node = parseNode(line.text)
                node.children = children(deeperThan: line.indent)
                nodes.append(node)
            }
            return nodes
        }
        let roots = children(deeperThan: -1)
        guard let root = QueryPlan.singleRoot(roots) else { return nil }
        let execution = roots.count == 1 ? root.actualTotalTime.map { $0 * Double(max(root.actualLoops ?? 1, 1)) } : nil
        return QueryPlan(format: .mysqlTree, root: root, executionTime: execution, rawText: text)
    }

    static func parseNode(_ text: String) -> QueryPlanNode {
        var remaining = text.trimmingCharacters(in: .whitespaces)
        var groups: [[(String, String)]] = []
        var neverExecuted = false
        // The measurement groups sit at the end, two spaces after the description.
        while remaining.hasSuffix(")"), let open = matchingOpen(in: remaining) {
            let group = String(remaining[remaining.index(after: open)..<remaining.index(before: remaining.endIndex)])
            if group == "never executed" {
                neverExecuted = true
            } else if let pairs = keyValuePairs(group) {
                groups.insert(pairs, at: 0)
            } else {
                break
            }
            remaining = String(remaining[..<open]).trimmingCharacters(in: .whitespaces)
        }

        var node = describe(remaining)
        node.neverExecuted = neverExecuted
        for group in groups {
            // `rows` is an estimate in the cost group and a measured count in the actual group.
            let measured = group.contains { $0.0 == "actual time" || $0.0 == "loops" || $0.0 == "actual rows" }
            for (key, value) in group {
                let (low, high) = range(value)
                switch key {
                case "cost":
                    if let high {
                        node.estimatedStartupCost = low
                        node.estimatedTotalCost = high
                    } else {
                        node.estimatedTotalCost = low
                    }
                case "rows", "actual rows":
                    if measured { node.actualRows = low } else { node.estimatedRows = low }
                case "actual time":
                    node.actualStartupTime = high == nil ? nil : low
                    node.actualTotalTime = high ?? low
                case "loops":
                    node.actualLoops = low.map { Int($0.rounded()) }
                default:
                    node.properties.append(QueryPlanProperty(key.capitalized, value))
                }
            }
        }
        return node
    }

    /// Splits `actual time=0.346..0.431 rows=50 loops=1` into pairs; nil when the group is not measurements.
    static func keyValuePairs(_ group: String) -> [(String, String)]? {
        let pattern = #"(actual time|actual rows|[a-z_]+)=(\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: group, range: NSRange(group.startIndex..., in: group))
        guard !matches.isEmpty else { return nil }
        // Every word of the group must belong to a pair, or this is part of the description, such as `(id=o.user_id)`.
        let covered = matches.reduce(0) { $0 + $1.range.length } + matches.count - 1
        guard covered == (group as NSString).length else { return nil }
        let pairs = matches.compactMap { match -> (String, String)? in
            guard let key = Range(match.range(at: 1), in: group), let value = Range(match.range(at: 2), in: group) else { return nil }
            return (String(group[key]), String(group[value]))
        }
        // Only these keys are measurements; `(id=5)` is a lookup condition that happens to look like one.
        guard pairs.allSatisfy({ ["cost", "rows", "actual time", "actual rows", "loops"].contains($0.0) }) else { return nil }
        return pairs
    }

    /// `0.346..0.431` → (0.346, 0.431); `50` → (50, nil). Engineering notation (`372e-6`, `1.99e+6`) is allowed.
    static func range(_ text: String) -> (Double?, Double?) {
        let parts = text.components(separatedBy: "..")
        if parts.count == 2 { return (Double(parts[0]), Double(parts[1])) }
        return (Double(text), nil)
    }

    /// The `(` that opens the group closing at the end of `text`.
    private static func matchingOpen(in text: String) -> String.Index? {
        var depth = 0
        var index = text.endIndex
        while index > text.startIndex {
            index = text.index(before: index)
            switch text[index] {
            case ")": depth += 1
            case "(":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    /// Reads the operation, table, index and condition out of a step's description:
    /// `Index lookup on o using orders_status_idx (status='paid')`, `Filter: (orders.total > 10.00)`,
    /// `Inner hash join (<hash>(u.full_name)=<hash>(o.notes))`, `Sort: n DESC`.
    static func describe(_ text: String) -> QueryPlanNode {
        let lower = text.lowercased()
        if let onRange = text.range(of: " on "), isAccess(String(lower[..<onRange.lowerBound])) {
            var node = QueryPlanNode(operation: String(text[..<onRange.lowerBound]))
            var rest = String(text[onRange.upperBound...])
            node.relation = leadingIdentifier(&rest)
            if rest.hasPrefix("using ") {
                rest.removeFirst("using ".count)
                node.index = leadingIdentifier(&rest)
            }
            if rest.hasPrefix("over ") { rest.removeFirst("over ".count) }
            let condition = rest.trimmingCharacters(in: .whitespaces)
            if !condition.isEmpty { node.indexCondition = condition }
            let operation = lower[..<onRange.lowerBound]
            if operation.hasPrefix("table scan") {
                node.access = .fullScan
            } else if operation.contains("index scan") {
                node.access = .indexScan
            } else {
                node.access = .indexLookup
            }
            return node
        }
        if let colon = text.range(of: ": "), !text[..<colon.lowerBound].contains("(") {
            var node = QueryPlanNode(operation: String(text[..<colon.lowerBound]))
            let detail = String(text[colon.upperBound...])
            if node.operation == "Filter" {
                node.filter = detail
            } else {
                node.detail = detail
            }
            return node
        }
        if text.hasSuffix(")"), let open = matchingOpen(in: text), open > text.startIndex {
            var node = QueryPlanNode(operation: text[..<open].trimmingCharacters(in: .whitespaces))
            let condition = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            if lower.contains("join") {
                node.joinCondition = condition
            } else {
                node.detail = condition
            }
            return node
        }
        return QueryPlanNode(operation: text)
    }

    private static func isAccess(_ operation: String) -> Bool {
        operation.contains("scan") || operation.contains("lookup") || operation.contains("search")
    }

    /// A table or index name: backquoted, `<temporary>`-style, or up to the next space.
    private static func leadingIdentifier(_ text: inout String) -> String? {
        text = text.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return nil }
        let close: Character? = first == "`" ? "`" : first == "<" ? ">" : nil
        let end: String.Index
        if let close, let found = text.dropFirst().firstIndex(of: close) {
            end = text.index(after: found)
        } else {
            end = text.firstIndex { $0 == " " || $0 == "(" } ?? text.endIndex
        }
        let name = String(text[..<end])
        text = String(text[end...]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

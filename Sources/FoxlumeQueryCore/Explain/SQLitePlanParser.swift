import Foundation

/// Reads SQLite's `EXPLAIN QUERY PLAN` rows (id, parent, notused, detail), one per tab-separated line.
/// SQLite reports no costs or row counts, only the shape of the plan and how each table is reached.
public enum SQLitePlanParser {
    public static func parse(_ text: String) -> QueryPlan? {
        struct Row {
            var id: Int
            var parent: Int
            var detail: String
        }
        var rows: [Row] = []
        for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let fields = line.components(separatedBy: "\t")
            if fields.count >= 4, let id = Int(fields[0].trimmingCharacters(in: .whitespaces)), let parent = Int(fields[1].trimmingCharacters(in: .whitespaces)) {
                rows.append(Row(id: id, parent: parent, detail: fields[3...].joined(separator: "\t").trimmingCharacters(in: .whitespaces)))
            } else {
                // Output from before SQLite 3.24 has no parent column; keep its lines flat, in order.
                rows.append(Row(id: Int.min + rows.count, parent: Int.min, detail: fields.last?.trimmingCharacters(in: .whitespaces) ?? line))
            }
        }
        guard !rows.isEmpty else { return nil }
        let ids = Set(rows.map(\.id))

        func children(of parent: Int) -> [QueryPlanNode] {
            rows.filter { $0.parent == parent && $0.id != parent }.map { row in
                var node = describe(row.detail)
                node.children = children(of: row.id)
                return node
            }
        }
        // Top-level rows name a parent that is not itself a row (0 in current SQLite).
        let roots = rows.filter { !ids.contains($0.parent) }.map(\.parent)
        var seen = Set<Int>()
        var forest = roots.filter { seen.insert($0).inserted }.flatMap(children(of:))
        if forest.isEmpty {
            // Older SQLite's selectid/order/from columns do not form a tree; list the rows as they came.
            forest = rows.map { describe($0.detail) }
        }
        guard let root = QueryPlan.singleRoot(forest) else { return nil }
        return QueryPlan(format: .sqliteQueryPlan, root: root, rawText: text)
    }

    /// `SEARCH al USING INTEGER PRIMARY KEY (rowid=?)` → operation SEARCH, table `al`, the key, the condition.
    /// Other rows (`USE TEMP B-TREE FOR ORDER BY`, `LIST SUBQUERY 1`) keep their text as the operation.
    static func describe(_ detail: String) -> QueryPlanNode {
        var words = detail.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let verb = words.first, verb == "SCAN" || verb == "SEARCH", words.count >= 2 else {
            return QueryPlanNode(operation: detail)
        }
        var node = QueryPlanNode(operation: verb)
        words.removeFirst()
        // Before SQLite 3.36 the table name followed the word TABLE.
        if words.first == "TABLE", words.count >= 2 { words.removeFirst() }
        node.relation = words.removeFirst()
        if words.first == "AS", words.count >= 2 {
            words.removeFirst()
            node.alias = words.removeFirst()
        }
        var rest = words.joined(separator: " ")
        if let open = rest.firstIndex(of: "(") {
            node.indexCondition = String(rest[open...])
            rest = rest[..<open].trimmingCharacters(in: .whitespaces)
        }
        if rest.hasPrefix("USING ") {
            let using = String(rest.dropFirst("USING ".count))
            for prefix in ["COVERING INDEX ", "INDEX ", "AUTOMATIC COVERING INDEX ", "AUTOMATIC PARTIAL COVERING INDEX "] where using.hasPrefix(prefix) {
                node.index = String(using.dropFirst(prefix.count))
                if prefix.contains("COVERING") { node.properties.append(QueryPlanProperty("Covering Index", "true")) }
                if prefix.contains("AUTOMATIC") { node.properties.append(QueryPlanProperty("Automatic Index", "true")) }
                break
            }
            if node.index == nil { node.index = using }
        }
        node.access = verb == "SEARCH" ? .indexLookup : (node.index == nil ? .fullScan : .indexScan)
        node.properties.insert(QueryPlanProperty("Detail", detail), at: 0)
        return node
    }
}

import Foundation

/// Reads DuckDB's `EXPLAIN (FORMAT JSON)` (an array of operators) and `EXPLAIN (ANALYZE, FORMAT JSON)` (a profile
/// whose operators carry their own timing and cardinality).
public enum DuckDBPlanParser {
    public static func parse(_ text: String) -> QueryPlan? {
        guard let json = PlanJSON.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        if json.isObject {
            // A profile: the query's totals, then the operators under the EXPLAIN_ANALYZE wrapper.
            var operators = json["children"]?.elements ?? []
            while operators.count == 1, operatorName(operators[0]) == "EXPLAIN_ANALYZE" {
                operators = operators[0]["children"]?.elements ?? []
            }
            guard let root = QueryPlan.singleRoot(operators.map(node(from:))) else { return nil }
            var properties: [QueryPlanProperty] = []
            for key in ["rows_returned", "cpu_time", "total_memory_allocated", "total_bytes_read", "total_bytes_written", "cumulative_rows_scanned"] {
                if let value = json[key] { properties.append(QueryPlanProperty(MySQLJSONPlanParser.title(key), value.displayText)) }
            }
            return QueryPlan(format: .duckdbJSON, root: root, executionTime: json["latency"]?.double.map { $0 * 1000 }, properties: properties, rawText: text)
        }
        guard case .array(let operators) = json, let root = QueryPlan.singleRoot(operators.map(node(from:))) else { return nil }
        return QueryPlan(format: .duckdbJSON, root: root, rawText: text)
    }

    private static func operatorName(_ json: PlanJSON) -> String {
        json["operator_name"]?.string ?? json["name"]?.string ?? json["operator_type"]?.string ?? "OPERATOR"
    }

    private static let profileKeys: Set<String> = [
        "name", "operator_name", "operator_type", "children", "extra_info", "operator_timing", "operator_cardinality",
        "operator_rows_scanned",
    ]

    private static func node(from json: PlanJSON) -> QueryPlanNode {
        let name = operatorName(json)
        var node = QueryPlanNode(operation: name.replacingOccurrences(of: "_", with: " "))
        let info = json["extra_info"] ?? .object([])
        node.relation = info["Table"]?.string
        node.filter = info["Filters"]?.displayText
        node.joinCondition = info["Conditions"]?.displayText
        node.detail = info["Join Type"]?.string ?? info["Type"]?.string.flatMap { $0 == "Sequential Scan" ? nil : $0 }
        node.estimatedRows = info["Estimated Cardinality"]?.double
        if name == "SEQ_SCAN" || name == "TABLE_SCAN" {
            node.access = info["Type"]?.string == "Sequential Scan" || info["Type"] == nil ? .fullScan : .indexScan
        } else if name.contains("INDEX") {
            node.access = .indexLookup
        }
        for member in info.members where !["Table", "Filters", "Conditions", "Estimated Cardinality"].contains(member.key) {
            node.properties.append(QueryPlanProperty(member.key, member.value.displayText))
        }
        if let rowsScanned = json["operator_rows_scanned"]?.double, rowsScanned > 0 {
            node.properties.append(QueryPlanProperty("Rows Scanned", MySQLJSONPlanParser.format(rowsScanned)))
        }
        node.children = (json["children"]?.elements ?? []).map(node(from:))
        // A profile times each operator on its own; the plan model's time includes the operators below.
        if let own = json["operator_timing"]?.double {
            node.actualTotalTime = own * 1000 + node.children.compactMap(\.actualTotalTime).reduce(0, +)
            node.actualRows = json["operator_cardinality"]?.double
            node.actualLoops = 1
            if node.filter != nil, let scanned = json["operator_rows_scanned"]?.double, let kept = node.actualRows, scanned > 0 {
                node.rowsRemovedByFilter = max(0, scanned - kept)
            }
        }
        for member in json.members where !profileKeys.contains(member.key) && member.value.isScalar {
            node.properties.append(QueryPlanProperty(MySQLJSONPlanParser.title(member.key), member.value.displayText))
        }
        return node
    }
}

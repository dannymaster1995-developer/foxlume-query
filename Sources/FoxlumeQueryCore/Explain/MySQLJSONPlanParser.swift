import Foundation

/// Reads `EXPLAIN FORMAT=JSON` from MySQL (format version 1, the default, and version 2 from 8.3) and MariaDB, and
/// MariaDB's `ANALYZE FORMAT=JSON`, whose `r_` fields are the measured values.
public enum MySQLJSONPlanParser {
    public static func parse(_ text: String) -> QueryPlan? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let json = PlanJSON.parse(trimmed) else { return nil }
        if json["operation"] != nil {
            return QueryPlan(format: .mysqlJSON, root: versionTwoNode(json), properties: versionTwoPlanProperties(json), rawText: text)
        }
        guard let block = json["query_block"] else { return nil }
        let root = queryBlock(block, operation: "Query Block")
        var properties: [QueryPlanProperty] = []
        if let cost = blockCost(block) { properties.append(QueryPlanProperty("Query Cost", format(cost))) }
        if let optimization = json["query_optimization"]?["r_total_time_ms"]?.displayText {
            properties.append(QueryPlanProperty("Optimization Time", "\(optimization) ms"))
        }
        return QueryPlan(
            format: .mysqlJSON,
            root: root,
            planningTime: json["query_optimization"]?["r_total_time_ms"]?.double,
            executionTime: block["r_total_time_ms"]?.double,
            properties: properties,
            rawText: text
        )
    }

    // MARK: Format version 1 and MariaDB

    /// Object keys that become child nodes, with the operation they stand for.
    private static let operationKeys: [String: String] = [
        "ordering_operation": "Sort",
        "grouping_operation": "Group",
        "duplicates_removal": "Remove Duplicates",
        "windowing": "Window",
        "buffer_result": "Buffer Result",
        "union_result": "Union",
        "materialized_from_subquery": "Materialize",
        "filesort": "Sort",
        "temporary_table": "Temporary Table",
        "read_sorted_file": "Read Sorted File",
        "block-nl-join": "Block Nested Loop",
        "expression_cache": "Expression Cache",
    ]

    /// Array keys whose elements are subqueries.
    private static let subqueryKeys: Set<String> = [
        "attached_subqueries", "optimized_away_subqueries", "order_by_subqueries", "group_by_subqueries",
        "having_subqueries", "select_list_subqueries", "update_value_subqueries", "subqueries", "query_specifications",
    ]

    private static func blockCost(_ block: PlanJSON) -> Double? {
        block["cost_info"]?["query_cost"]?.double ?? block["cost"]?.double
    }

    private static func queryBlock(_ block: PlanJSON, operation: String) -> QueryPlanNode {
        var node = QueryPlanNode(operation: operation)
        if let id = block["select_id"]?.displayText { node.detail = "#\(id)" }
        node.estimatedTotalCost = blockCost(block)
        applyMeasurements(block, to: &node)
        fill(&node, from: block, skipping: ["select_id", "cost_info", "cost"])
        return node
    }

    /// Adds the children and properties an object describes: nested operations become nodes, scalars properties.
    private static func fill(_ node: inout QueryPlanNode, from object: PlanJSON, skipping: Set<String>) {
        for member in object.members where !skipping.contains(member.key) && !member.key.hasPrefix("r_") {
            switch member.key {
            case "query_block":
                node.children.append(queryBlock(member.value, operation: "Query Block"))
            case "table":
                node.children.append(table(member.value))
            case "nested_loop":
                var loop = QueryPlanNode(operation: "Nested Loop")
                for element in member.value.elements {
                    var holder = QueryPlanNode(operation: "")
                    fill(&holder, from: element, skipping: [])
                    loop.children += holder.children
                    loop.properties += holder.properties
                }
                let costs = loop.children.compactMap(\.estimatedTotalCost)
                loop.estimatedTotalCost = costs.isEmpty ? nil : costs.reduce(0, +)
                node.children.append(loop)
            case _ where subqueryKeys.contains(member.key):
                for element in member.value.elements {
                    var subquery = QueryPlanNode(operation: member.key == "query_specifications" ? "Union Member" : "Subquery")
                    for flag in ["dependent", "cacheable"] where element[flag]?.bool == true {
                        subquery.properties.append(QueryPlanProperty(flag.capitalized, "true"))
                    }
                    fill(&subquery, from: element, skipping: ["dependent", "cacheable"])
                    // A subquery wrapper around a single query block reads better as that block.
                    if subquery.children.count == 1, subquery.children[0].operation == "Query Block" {
                        var block = subquery.children[0]
                        block.operation = subquery.operation
                        block.properties = subquery.properties + block.properties
                        node.children.append(block)
                    } else {
                        node.children.append(subquery)
                    }
                }
            case _ where operationKeys[member.key] != nil && member.value.isObject:
                node.children.append(operation(member.key, member.value))
            case "having_condition":
                node.properties.append(QueryPlanProperty("Having", member.value.displayText))
            case "message":
                node.detail = member.value.displayText
                node.properties.append(QueryPlanProperty("Message", member.value.displayText))
            default:
                if member.value.isObject || (!member.value.elements.isEmpty && !member.value.elements.allSatisfy(\.isScalar)) {
                    // Something this parser does not model: keep its contents as a node so nothing is lost.
                    var other = QueryPlanNode(operation: title(member.key))
                    if member.value.isObject {
                        fill(&other, from: member.value, skipping: [])
                    } else {
                        for element in member.value.elements { fill(&other, from: element, skipping: []) }
                    }
                    node.children.append(other)
                } else {
                    node.properties.append(QueryPlanProperty(title(member.key), member.value.displayText))
                }
            }
        }
        // A wrapper without its own cost costs what its inputs cost, so its own share comes out as zero.
        if node.estimatedTotalCost == nil {
            let costs = node.children.compactMap(\.estimatedTotalCost)
            if !costs.isEmpty { node.estimatedTotalCost = costs.reduce(0, +) }
        }
    }

    private static func operation(_ key: String, _ value: PlanJSON) -> QueryPlanNode {
        var node = QueryPlanNode(operation: operationKeys[key] ?? title(key))
        var notes: [String] = []
        if value["using_filesort"]?.bool == true { notes.append("filesort") }
        if value["using_temporary_table"]?.bool == true { notes.append("temporary table") }
        if let sortKey = value["sort_key"]?.displayText { node.detail = sortKey }
        if !notes.isEmpty, node.detail == nil { node.detail = notes.joined(separator: ", ") }
        if key == "union_result", let table = value["table_name"]?.string { node.relation = table }
        node.estimatedTotalCost = value["cost_info"]?["query_cost"]?.double
        applyMeasurements(value, to: &node)
        fill(&node, from: value, skipping: ["using_filesort", "using_temporary_table", "sort_key", "cost_info", "table_name"])
        if let sortCost = value["cost_info"]?["sort_cost"]?.double {
            node.properties.append(QueryPlanProperty("Sort Cost", format(sortCost)))
        }
        return node
    }

    private static let accessLabels: [String: (String, QueryPlanAccess?)] = [
        "ALL": ("Full Table Scan", .fullScan),
        "index": ("Full Index Scan", .indexScan),
        "range": ("Index Range Scan", .indexLookup),
        "ref": ("Index Lookup", .indexLookup),
        "eq_ref": ("Unique Index Lookup", .indexLookup),
        "const": ("Constant Row", .indexLookup),
        "system": ("System Row", nil),
        "fulltext": ("Full-Text Search", .indexLookup),
        "ref_or_null": ("Index Lookup or NULL", .indexLookup),
        "index_merge": ("Index Merge", .indexLookup),
        "unique_subquery": ("Unique Subquery Lookup", .indexLookup),
        "index_subquery": ("Subquery Index Lookup", .indexLookup),
    ]

    private static let tableKeys: Set<String> = [
        "table_name", "access_type", "key", "rows_examined_per_scan", "rows", "attached_condition", "index_condition",
        "cost_info", "cost", "filtered", "update", "insert", "delete", "materialized_from_subquery",
    ]

    private static func table(_ value: PlanJSON) -> QueryPlanNode {
        let accessType = value["access_type"]?.string
        let label = accessType.flatMap { accessLabels[$0] }
        var name = label?.0 ?? accessType?.uppercased() ?? "Table"
        for (flag, verb) in [("update", "Update"), ("insert", "Insert"), ("delete", "Delete")] where value[flag]?.bool == true {
            name = verb
        }
        var node = QueryPlanNode(operation: name)
        node.access = label?.1
        node.relation = value["table_name"]?.string
        node.index = value["key"]?.string
        node.estimatedRows = value["rows_examined_per_scan"]?.double ?? value["rows"]?.double
        node.filter = value["attached_condition"]?.string
        node.indexCondition = value["index_condition"]?.string
        if let filtered = value["filtered"]?.double {
            node.filteredFraction = min(max(filtered / 100, 0), 1)
            node.properties.append(QueryPlanProperty("Filtered", "\(value["filtered"]?.displayText ?? format(filtered))%"))
        }
        if let accessType { node.properties.append(QueryPlanProperty("Access Type", accessType)) }
        // MySQL splits a table's cost into reading the rows and evaluating conditions on them; MariaDB reports one cost.
        if let costInfo = value["cost_info"], let read = costInfo["read_cost"]?.double {
            node.estimatedTotalCost = read + (costInfo["eval_cost"]?.double ?? 0)
            for member in costInfo.members {
                node.properties.append(QueryPlanProperty(title(member.key), member.value.displayText))
            }
        } else if let cost = value["cost"]?.double {
            node.estimatedTotalCost = cost
        }
        applyMeasurements(value, to: &node)
        fill(&node, from: value, skipping: tableKeys)
        if let materialized = value["materialized_from_subquery"] {
            node.children.append(operation("materialized_from_subquery", materialized))
        }
        // A table read through a materialized subquery costs what the subquery cost on top of its own reads.
        if let own = node.estimatedTotalCost {
            node.estimatedTotalCost = own + node.children.compactMap(\.estimatedTotalCost).reduce(0, +)
        }
        return node
    }

    /// MariaDB's ANALYZE: loops, rows and time actually measured. Its time is the total over all loops.
    private static func applyMeasurements(_ value: PlanJSON, to node: inout QueryPlanNode) {
        let loops = value["r_loops"]?.double
        if let loops { node.actualLoops = Int(loops) }
        if let rows = value["r_rows"]?.double { node.actualRows = rows }
        if let time = value["r_total_time_ms"]?.double {
            node.actualTotalTime = time / max(loops ?? 1, 1)
        }
        if loops == 0 { node.neverExecuted = true }
        if let filtered = value["r_filtered"]?.displayText {
            node.properties.append(QueryPlanProperty("Actual Filtered", "\(filtered)%"))
        }
        for member in value.members where member.key.hasPrefix("r_") && !["r_loops", "r_rows", "r_total_time_ms", "r_filtered"].contains(member.key) {
            node.properties.append(QueryPlanProperty(title(member.key), member.value.displayText))
        }
    }

    // MARK: Format version 2

    private static func versionTwoPlanProperties(_ json: PlanJSON) -> [QueryPlanProperty] {
        var properties: [QueryPlanProperty] = []
        if let query = json["query"]?.string { properties.append(QueryPlanProperty("Query", query)) }
        if let type = json["query_type"]?.string { properties.append(QueryPlanProperty("Query Type", type)) }
        return properties
    }

    private static let versionTwoKeys: Set<String> = [
        "operation", "inputs", "table_name", "schema_name", "alias", "index_name", "estimated_rows", "estimated_total_cost",
        "estimated_first_row_cost", "condition", "lookup_condition", "join_type", "query", "query_type",
        "actual_rows", "actual_loops", "actual_first_row_ms", "actual_last_row_ms",
    ]

    private static func versionTwoNode(_ json: PlanJSON) -> QueryPlanNode {
        let text = json["operation"]?.string ?? "Operation"
        var node = MySQLTreePlanParser.describe(text)
        node.relation = json["table_name"]?.string ?? node.relation
        node.schema = json["schema_name"]?.string
        node.alias = json["alias"]?.string ?? node.alias
        node.index = json["index_name"]?.string ?? node.index
        node.estimatedRows = json["estimated_rows"]?.double
        node.estimatedTotalCost = json["estimated_total_cost"]?.double
        node.estimatedStartupCost = json["estimated_first_row_cost"]?.double
        if let condition = json["condition"]?.string {
            if json["join_type"] != nil || json["join_algorithm"] != nil { node.joinCondition = condition } else { node.filter = condition }
        }
        if let lookup = json["lookup_condition"]?.string { node.indexCondition = lookup }
        node.actualRows = json["actual_rows"]?.double
        node.actualLoops = json["actual_loops"]?.int
        node.actualStartupTime = json["actual_first_row_ms"]?.double
        node.actualTotalTime = json["actual_last_row_ms"]?.double
        if node.actualLoops == 0 { node.neverExecuted = true }
        if json["access_type"]?.string == "table", node.access == nil { node.access = .fullScan }
        for member in json.members where !versionTwoKeys.contains(member.key) {
            if member.value.isObject || member.value.elements.contains(where: \.isObject) {
                let objects = member.value.isObject ? [member.value] : member.value.elements.filter(\.isObject)
                node.children += objects.filter { $0["operation"] != nil }.map(versionTwoNode)
            } else {
                node.properties.append(QueryPlanProperty(title(member.key), member.value.displayText))
            }
        }
        node.children = (json["inputs"]?.elements ?? []).map(versionTwoNode) + node.children
        return node
    }

    // MARK: Helpers

    /// `rows_examined_per_scan` → `Rows Examined Per Scan`.
    static func title(_ key: String) -> String {
        key.replacingOccurrences(of: "r_", with: "actual_", options: .anchored)
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(format: "%.2f", value)
    }
}

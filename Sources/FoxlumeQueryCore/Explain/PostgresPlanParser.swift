import Foundation

/// Reads `EXPLAIN (FORMAT JSON)` output, with or without ANALYZE and BUFFERS.
public enum PostgresPlanParser {
    public static func parse(_ text: String) -> QueryPlan? {
        guard let json = PlanJSON.parse(text) else { return nil }
        // The reply is an array with one entry per explained statement; only one is ever sent.
        let entry = json.elements.first ?? json
        guard let planJSON = entry["Plan"], planJSON.isObject else { return nil }

        var properties: [QueryPlanProperty] = []
        if let planning = entry["Planning"], let buffers = buffers(in: planning), !buffers.isEmpty {
            properties.append(QueryPlanProperty("Planning Buffers", buffers.summary))
        }
        for trigger in entry["Triggers"]?.elements ?? [] {
            let name = trigger["Trigger Name"]?.displayText ?? trigger["Constraint Name"]?.displayText ?? "Trigger"
            var value = trigger["Time"].map { "\($0.displayText) ms" } ?? ""
            if let calls = trigger["Calls"]?.displayText { value += value.isEmpty ? "\(calls) calls" : ", \(calls) calls" }
            let relation = trigger["Relation"].map { " on \($0.displayText)" } ?? ""
            properties.append(QueryPlanProperty("Trigger \(name)\(relation)", value))
        }
        if let jit = entry["JIT"] {
            properties.append(QueryPlanProperty("JIT", jit.displayText))
        }
        for key in ["Settings", "Query Identifier"] {
            if let value = entry[key] { properties.append(QueryPlanProperty(key, value.displayText)) }
        }
        return QueryPlan(
            format: .postgresJSON,
            root: node(from: planJSON),
            planningTime: entry["Planning Time"]?.double,
            executionTime: (entry["Execution Time"] ?? entry["Total Runtime"])?.double,
            properties: properties,
            rawText: text
        )
    }

    /// Keys read into the node's own fields; everything else becomes a property.
    private static let knownKeys: Set<String> = [
        "Node Type", "Relation Name", "Schema", "Alias", "Index Name", "Startup Cost", "Total Cost", "Plan Rows",
        "Plan Width", "Actual Startup Time", "Actual Total Time", "Actual Rows", "Actual Loops", "Plans", "Filter",
        "Rows Removed by Filter", "Hash Cond", "Merge Cond", "Index Cond", "Subplan Name",
    ]

    private static func node(from json: PlanJSON) -> QueryPlanNode {
        let nodeType = json["Node Type"]?.string ?? "Unknown"
        var node = QueryPlanNode(operation: displayName(nodeType: nodeType, json: json))
        node.relation = json["Relation Name"]?.string ?? json["CTE Name"]?.string ?? json["Function Name"]?.string
        node.schema = json["Schema"]?.string
        node.alias = json["Alias"]?.string
        node.index = json["Index Name"]?.string
        node.access = access(nodeType: nodeType)
        node.detail = json["Subplan Name"]?.string
        node.estimatedStartupCost = json["Startup Cost"]?.double
        node.estimatedTotalCost = json["Total Cost"]?.double
        node.estimatedRows = json["Plan Rows"]?.double
        node.estimatedWidth = json["Plan Width"]?.int
        node.actualStartupTime = json["Actual Startup Time"]?.double
        node.actualTotalTime = json["Actual Total Time"]?.double
        node.actualRows = json["Actual Rows"]?.double
        node.actualLoops = json["Actual Loops"]?.int
        // ANALYZE reports a node that never ran with zero loops (and no times since PostgreSQL 13).
        node.neverExecuted = node.actualLoops == 0
        node.filter = json["Filter"]?.string
        node.rowsRemovedByFilter = json["Rows Removed by Filter"]?.double
        node.joinCondition = json["Hash Cond"]?.string ?? json["Merge Cond"]?.string
        node.indexCondition = json["Index Cond"]?.string
        // A join without a hash or merge condition joins on its Join Filter; otherwise that stays a property.
        if node.joinCondition == nil, let joinFilter = json["Join Filter"]?.string {
            node.joinCondition = joinFilter
        }
        if node.indexCondition == nil, let recheck = json["Recheck Cond"]?.string {
            node.indexCondition = recheck
        }
        node.buffers = buffers(in: json)

        let consumed: Set<String> = {
            var keys = knownKeys
            if node.joinCondition != nil, json["Hash Cond"] == nil, json["Merge Cond"] == nil { keys.insert("Join Filter") }
            if node.indexCondition != nil, json["Index Cond"] == nil { keys.insert("Recheck Cond") }
            return keys
        }()
        for member in json.members where !consumed.contains(member.key) && !Self.bufferKeys.contains(member.key) {
            // An empty Workers list carries nothing.
            if case .array(let elements) = member.value, elements.isEmpty { continue }
            node.properties.append(QueryPlanProperty(member.key, member.value.displayText))
        }
        node.children = (json["Plans"]?.elements ?? []).map(Self.node(from:))
        return node
    }

    /// The name PostgreSQL's text format prints, which is what people know: `Parallel Seq Scan`, `HashAggregate`,
    /// `Hash Left Join`, `Index Scan Backward`, `Update`.
    static func displayName(nodeType: String, json: PlanJSON) -> String {
        var name = nodeType
        switch nodeType {
        case "Aggregate":
            switch json["Strategy"]?.string {
            case "Sorted": name = "GroupAggregate"
            case "Hashed": name = "HashAggregate"
            case "Mixed": name = "MixedAggregate"
            default: break
            }
            switch json["Partial Mode"]?.string {
            case "Partial": name = "Partial " + name
            case "Finalize": name = "Finalize " + name
            default: break
            }
        case "Nested Loop", "Hash Join", "Merge Join":
            if let joinType = json["Join Type"]?.string, joinType != "Inner" {
                name = nodeType == "Nested Loop" ? "Nested Loop \(joinType) Join" : nodeType.replacingOccurrences(of: " Join", with: " \(joinType) Join")
            }
        case "ModifyTable":
            if let operation = json["Operation"]?.string { name = operation }
        case "Index Scan", "Index Only Scan":
            if json["Scan Direction"]?.string == "Backward" { name += " Backward" }
        case "SetOp":
            if let command = json["Command"]?.string { name = (json["Strategy"]?.string == "Hashed" ? "HashSetOp " : "SetOp ") + command }
        default:
            break
        }
        if json["Parallel Aware"]?.bool == true { name = "Parallel " + name }
        return name
    }

    private static func access(nodeType: String) -> QueryPlanAccess? {
        switch nodeType {
        case "Seq Scan": return .fullScan
        case "Index Scan", "Index Only Scan", "Bitmap Index Scan", "Bitmap Heap Scan": return .indexLookup
        default: return nil
        }
    }

    private static let bufferKeys: Set<String> = [
        "Shared Hit Blocks", "Shared Read Blocks", "Shared Dirtied Blocks", "Shared Written Blocks",
        "Local Hit Blocks", "Local Read Blocks", "Local Dirtied Blocks", "Local Written Blocks",
        "Temp Read Blocks", "Temp Written Blocks",
    ]

    private static func buffers(in json: PlanJSON) -> QueryPlanBuffers? {
        guard json["Shared Hit Blocks"] != nil || json["Temp Read Blocks"] != nil || json["Local Hit Blocks"] != nil else { return nil }
        var buffers = QueryPlanBuffers()
        buffers.sharedHit = json["Shared Hit Blocks"]?.int ?? 0
        buffers.sharedRead = json["Shared Read Blocks"]?.int ?? 0
        buffers.sharedDirtied = json["Shared Dirtied Blocks"]?.int ?? 0
        buffers.sharedWritten = json["Shared Written Blocks"]?.int ?? 0
        buffers.localHit = json["Local Hit Blocks"]?.int ?? 0
        buffers.localRead = json["Local Read Blocks"]?.int ?? 0
        buffers.localDirtied = json["Local Dirtied Blocks"]?.int ?? 0
        buffers.localWritten = json["Local Written Blocks"]?.int ?? 0
        buffers.tempRead = json["Temp Read Blocks"]?.int ?? 0
        buffers.tempWritten = json["Temp Written Blocks"]?.int ?? 0
        return buffers
    }
}

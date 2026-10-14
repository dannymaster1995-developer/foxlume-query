import Foundation

/// Reads the reply of MongoDB's `explain` for find and aggregate, in queryPlanner or executionStats verbosity.
/// Stages become nodes; with executionStats they carry returned documents and time estimates.
public enum MongoPlanParser {
    public static func parse(_ text: String) -> QueryPlan? {
        guard let json = PlanJSON.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)), json.isObject else { return nil }
        var properties: [QueryPlanProperty] = []
        let root: QueryPlanNode
        if let stages = json["stages"]?.elements, !stages.isEmpty {
            // An aggregation that was not pushed down: the $cursor stage holds the query plan, then one node per stage.
            var pipeline = QueryPlanNode(operation: "Pipeline")
            var input: QueryPlanNode?
            for stage in stages {
                guard let member = stage.members.first else { continue }
                var node: QueryPlanNode
                if member.key == "$cursor" {
                    node = planTree(member.value, properties: &properties) ?? QueryPlanNode(operation: "$cursor")
                } else {
                    node = QueryPlanNode(operation: member.key)
                    node.detail = member.value.compactText
                    node.actualRows = stage["nReturned"]?.double
                    node.actualTotalTime = stage["executionTimeMillisEstimate"]?.double
                    if let previous = input { node.children = [previous] }
                }
                input = node
            }
            pipeline.children = input.map { [$0] } ?? []
            root = pipeline.children.count == 1 ? pipeline.children[0] : pipeline
        } else if let tree = planTree(json, properties: &properties) {
            root = tree
        } else {
            return nil
        }
        let stats = json["executionStats"] ?? json["stages"]?.elements.first?["$cursor"]?["executionStats"]
        return QueryPlan(format: .mongoExplain, root: root, executionTime: stats?["executionTimeMillis"]?.double, properties: properties, rawText: text)
    }

    /// The executed stages when the reply has them, otherwise the winning plan.
    private static func planTree(_ explain: PlanJSON, properties: inout [QueryPlanProperty]) -> QueryPlanNode? {
        let planner = explain["queryPlanner"]
        if let namespace = planner?["namespace"]?.string { properties.append(QueryPlanProperty("Namespace", namespace)) }
        if let rejected = planner?["rejectedPlans"]?.elements { properties.append(QueryPlanProperty("Rejected Plans", String(rejected.count))) }
        let stats = explain["executionStats"]
        for key in ["nReturned", "totalKeysExamined", "totalDocsExamined", "executionTimeMillis"] {
            if let value = stats?[key] { properties.append(QueryPlanProperty(label(key), value.displayText)) }
        }
        let collection = planner?["namespace"]?.string.map { $0.split(separator: ".", maxSplits: 1).last.map(String.init) ?? $0 }
        if let executed = stats?["executionStages"] {
            return stage(executed, collection: collection)
        }
        guard let winning = planner?["winningPlan"] else { return nil }
        // Slot-based plans (MongoDB 7 and later) wrap the classic stage tree in queryPlan.
        return stage(winning["queryPlan"] ?? winning, collection: collection)
    }

    private static let consumed: Set<String> = [
        "stage", "inputStage", "inputStages", "innerStage", "outerStage", "thenStage", "elseStage", "indexName", "filter",
        "indexBounds", "nReturned", "executionTimeMillisEstimate", "docsExamined", "keysExamined",
    ]

    private static func stage(_ json: PlanJSON, collection: String?) -> QueryPlanNode {
        let name = json["stage"]?.string ?? "STAGE"
        var node = QueryPlanNode(operation: name)
        node.index = json["indexName"]?.string
        node.filter = json["filter"]?.compactText
        node.indexCondition = json["indexBounds"]?.compactText
        switch name {
        case "COLLSCAN":
            node.access = .fullScan
            node.relation = collection
        case "IXSCAN", "COUNT_SCAN", "DISTINCT_SCAN":
            node.access = .indexScan
            node.relation = collection
        case "IDHACK", "EXPRESS_IXSCAN", "EXPRESS_CLUSTERED_IXSCAN":
            node.access = .indexLookup
            node.relation = collection
        default:
            break
        }
        node.actualRows = json["nReturned"]?.double
        node.actualTotalTime = json["executionTimeMillisEstimate"]?.double
        if node.actualRows != nil { node.actualLoops = 1 }
        if let examined = json["docsExamined"]?.double ?? json["keysExamined"]?.double, let returned = node.actualRows, node.filter != nil {
            node.rowsRemovedByFilter = max(0, examined - returned)
        }
        for key in ["docsExamined", "keysExamined"] {
            if let value = json[key] { node.properties.append(QueryPlanProperty(label(key), value.displayText)) }
        }
        for member in json.members where !consumed.contains(member.key) {
            node.properties.append(QueryPlanProperty(member.key, member.value.displayText))
        }
        let single = ["inputStage", "outerStage", "innerStage", "thenStage", "elseStage"].compactMap { json[$0] }
        node.children = (single + (json["inputStages"]?.elements ?? [])).map { stage($0, collection: collection) }
        return node
    }

    /// `totalKeysExamined` → `Total Keys Examined`.
    static func label(_ key: String) -> String {
        var out = ""
        for character in key {
            if character.isUppercase, !out.isEmpty { out += " " }
            out.append(out.isEmpty ? Character(character.uppercased()) : character)
        }
        return out
    }
}

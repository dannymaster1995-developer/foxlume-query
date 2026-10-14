import Foundation

/// How much of the plan's work one node does. The bands follow TablePro's: more than half is critical, more than a
/// fifth high, more than a twentieth moderate.
public enum QueryPlanSeverity: Int, Comparable, Sendable, CaseIterable {
    case low
    case moderate
    case high
    case critical

    public static func forShare(_ share: Double) -> QueryPlanSeverity {
        guard share.isFinite else { return .low }
        let bounded = min(max(share, 0), 1)
        if bounded > 0.5 { return .critical }
        if bounded > 0.2 { return .high }
        if bounded > 0.05 { return .moderate }
        return .low
    }

    public static func < (lhs: QueryPlanSeverity, rhs: QueryPlanSeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .low: return "Low"
        case .moderate: return "Moderate"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }
}

/// What the share column measures.
public enum QueryPlanMetric: String, CaseIterable, Sendable {
    /// The node's own estimated cost: its total minus its inputs' totals.
    case selfCost
    /// The node's own measured time, over all loops, corrected for parallel workers.
    case selfTime

    public var title: String {
        switch self {
        case .selfCost: return "Self Cost"
        case .selfTime: return "Self Time"
        }
    }
}

/// Something in a node worth a second look. TablePro shows none of these; they follow what plan visualizers such as
/// pev2 point out.
public struct QueryPlanWarning: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case rowEstimate
        case largeScan
        case diskSort
        case hashBatches
        case workersNotLaunched
    }

    public var kind: Kind
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Numbers derived from a plan once, so views never walk the tree per cell.
public struct QueryPlanAnalysis: Sendable {
    public struct NodeMetrics: Hashable, Sendable {
        public var selfCost: Double?
        public var costShare: Double?
        /// Milliseconds over all loops, including the nodes below, corrected for parallel workers.
        public var totalTime: Double?
        public var selfTime: Double?
        public var timeShare: Double?
        /// Actual rows over estimated rows, per loop; above 1 the planner expected too few.
        public var rowEstimateRatio: Double?
        public var warnings: [QueryPlanWarning] = []

        public init() {}

        public func share(_ metric: QueryPlanMetric) -> Double? {
            metric == .selfCost ? costShare : timeShare
        }

        public func value(_ metric: QueryPlanMetric) -> Double? {
            metric == .selfCost ? selfCost : selfTime
        }
    }

    public let metrics: [Int: NodeMetrics]
    /// The metrics this plan can show, cost before time.
    public let availableMetrics: [QueryPlanMetric]
    /// Sum of every node's own cost: the plan's real total, which a Limit's cheap top node understates.
    public let totalSelfCost: Double?

    /// Rows are only worth a warning when there are enough of them to matter.
    static let largeScanRows: Double = 10_000
    static let misestimateFactor: Double = 10
    static let misestimateMinimumRows: Double = 100
    /// A full scan of a table this expensive is a large one, when the plan does not say how many rows it read.
    static let largeScanCost: Double = 10_000

    public init(plan: QueryPlan) {
        var metrics: [Int: NodeMetrics] = [:]
        let parents = plan.parentIDs
        let nodes = plan.allNodes
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

        // Processes that ran each node: one outside a Gather, its launched workers plus the leader below one.
        var processes: [Int: Int] = [:]
        func assignProcesses(_ node: QueryPlanNode, _ inherited: Int) {
            processes[node.id] = inherited
            var below = inherited
            if node.operation.hasPrefix("Gather"), let launched = node.property("Workers Launched").flatMap(Int.init), launched > 0 {
                below = launched + 1
            }
            node.children.forEach { assignProcesses($0, below) }
        }
        assignProcesses(plan.root, 1)

        func totalTime(_ node: QueryPlanNode) -> Double? {
            guard let perLoop = node.actualTotalTime else { return nil }
            let loops = Double(max(node.actualLoops ?? 1, 1))
            return perLoop * loops / Double(max(processes[node.id] ?? 1, 1))
        }

        for node in nodes {
            var entry = NodeMetrics()
            if let total = node.estimatedTotalCost {
                let inputs = node.children.reduce(0.0) { $0 + ($1.estimatedTotalCost ?? 0) }
                entry.selfCost = max(0, total - inputs)
            }
            if let total = totalTime(node) {
                entry.totalTime = total
                // A child that reported no time adds nothing, so a never-executed branch cannot inflate its parent.
                let inputs = node.children.reduce(0.0) { $0 + (totalTime($1) ?? 0) }
                entry.selfTime = max(0, total - inputs)
            }
            if let actual = node.actualRows, let estimate = node.estimatedRows, !node.neverExecuted {
                entry.rowEstimateRatio = max(actual, 1) / max(estimate, 1)
            }
            entry.warnings = Self.warnings(for: node, parent: parents[node.id].flatMap { byID[$0] }, ratio: entry.rowEstimateRatio)
            metrics[node.id] = entry
        }

        let costs = metrics.values.compactMap(\.selfCost)
        let times = metrics.values.compactMap(\.selfTime)
        let costTotal = costs.reduce(0, +)
        let timeTotal = times.reduce(0, +)
        for id in metrics.keys {
            if costTotal > 0, let own = metrics[id]?.selfCost { metrics[id]?.costShare = own / costTotal }
            if timeTotal > 0, let own = metrics[id]?.selfTime { metrics[id]?.timeShare = own / timeTotal }
        }
        self.metrics = metrics
        self.totalSelfCost = costs.isEmpty ? nil : costTotal
        var available: [QueryPlanMetric] = []
        if costTotal > 0 { available.append(.selfCost) }
        if timeTotal > 0 { available.append(.selfTime) }
        self.availableMetrics = available
    }

    public subscript(id: Int) -> NodeMetrics {
        metrics[id] ?? NodeMetrics()
    }

    /// Measured time is the truth when the plan has it; estimates stand in otherwise.
    public var defaultMetric: QueryPlanMetric? {
        availableMetrics.contains(.selfTime) ? .selfTime : availableMetrics.first
    }

    public func severity(of id: Int, metric: QueryPlanMetric?) -> QueryPlanSeverity? {
        guard let metric, let share = self[id].share(metric) else { return nil }
        return QueryPlanSeverity.forShare(share)
    }

    public var warningCount: Int {
        metrics.values.reduce(0) { $0 + $1.warnings.count }
    }

    // MARK: Warnings

    static func warnings(for node: QueryPlanNode, parent: QueryPlanNode?, ratio: Double?) -> [QueryPlanWarning] {
        var warnings: [QueryPlanWarning] = []
        if let ratio, let actual = node.actualRows, let estimate = node.estimatedRows,
           ratio >= misestimateFactor || ratio <= 1 / misestimateFactor,
           max(actual, estimate) * Double(max(node.actualLoops ?? 1, 1)) >= misestimateMinimumRows {
            let factor = ratio >= 1 ? ratio : 1 / ratio
            let direction = ratio >= 1 ? "more" : "fewer"
            warnings.append(QueryPlanWarning(.rowEstimate, "The planner expected \(QueryPlanText.rows(estimate)) rows but got \(QueryPlanText.rows(actual)), \(QueryPlanText.factor(factor)) \(direction). Fresh statistics (ANALYZE) may give a better plan."))
        }
        if let scan = largeScanWarning(node, parent: parent) { warnings.append(scan) }
        let sortSpace = node.property("Sort Space Type")
        let sortMethod = node.property("Sort Method") ?? ""
        if sortSpace == "Disk" || sortMethod.hasPrefix("external") {
            let used = node.property("Sort Space Used").map { " (\($0) kB)" } ?? ""
            warnings.append(QueryPlanWarning(.diskSort, "The sort spilled to disk\(used). A larger work_mem would keep it in memory."))
        }
        if let batches = node.property("Hash Batches").flatMap(Int.init), batches > 1 {
            warnings.append(QueryPlanWarning(.hashBatches, "The hash table did not fit in memory and was split into \(batches) batches on disk."))
        }
        if let planned = node.property("Workers Planned").flatMap(Int.init), let launched = node.property("Workers Launched").flatMap(Int.init), launched < planned {
            warnings.append(QueryPlanWarning(.workersNotLaunched, "Only \(launched) of \(planned) planned parallel workers started."))
        }
        return warnings
    }

    /// A full scan that reads many rows to keep few of them, where an index on the filtered columns would help.
    static func largeScanWarning(_ node: QueryPlanNode, parent: QueryPlanNode?) -> QueryPlanWarning? {
        guard node.access == .fullScan, !node.neverExecuted else { return nil }
        // MySQL's tree format puts the filter in its own node right above the scan.
        let filterAbove = parent.map { $0.operation == "Filter" && $0.children.count == 1 } ?? false
        guard node.filter != nil || node.rowsRemovedByFilter != nil || filterAbove else { return nil }
        let name = node.objectName ?? "a table"
        var read: Double?
        var kept: Double?
        if let actual = node.actualRows {
            let loops = Double(max(node.actualLoops ?? 1, 1))
            read = (actual + (node.rowsRemovedByFilter ?? 0)) * loops
            if filterAbove, let parent, let parentRows = parent.actualRows {
                kept = parentRows * Double(max(parent.actualLoops ?? 1, 1))
            } else if node.rowsRemovedByFilter != nil || node.filter != nil {
                kept = actual * loops
            }
        } else if let examined = node.estimatedRows, let fraction = node.filteredFraction {
            read = examined
            kept = examined * fraction
        } else if filterAbove, let examined = node.estimatedRows, let parentRows = parent?.estimatedRows {
            read = examined
            kept = parentRows
        }
        if let read, let kept {
            guard read >= largeScanRows, kept <= read / 4 else { return nil }
            return QueryPlanWarning(.largeScan, "Reads \(QueryPlanText.rows(read.rounded())) rows of \(name) to keep \(QueryPlanText.rows(kept.rounded())). An index on the filtered columns may avoid the full scan.")
        }
        // PostgreSQL without ANALYZE reports only the rows kept; a high cost says the table is large.
        if let cost = node.estimatedTotalCost, cost >= largeScanCost, node.filter != nil {
            return QueryPlanWarning(.largeScan, "Reads all of \(name), a large table, to apply a filter. An index on the filtered columns may avoid the full scan.")
        }
        return nil
    }
}

/// The spellings used in plan text: copied node details, warnings and the summary line.
public enum QueryPlanText {
    /// `1,234`, or `66,666.33` for PostgreSQL 18's averaged row counts.
    public static func rows(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = value.rounded() == value || abs(value) >= 1_000_000 ? 0 : 2
        formatter.minimumFractionDigits = 0
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Costs keep two decimals as PostgreSQL prints them: `0.15..14.99`.
    public static func cost(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    public static func costRange(startup: Double?, total: Double?) -> String? {
        guard let total else { return nil }
        guard let startup else { return cost(total) }
        return "\(cost(startup))..\(cost(total))"
    }

    /// `0.030 ms`, `21.4 ms`, `1.23 s`.
    public static func milliseconds(_ value: Double) -> String {
        if value >= 1_000 { return String(format: "%.2f s", value / 1_000) }
        if value >= 100 { return String(format: "%.0f ms", value) }
        if value >= 10 { return String(format: "%.1f ms", value) }
        return String(format: "%.3f ms", value)
    }

    public static func percent(_ share: Double) -> String {
        let value = share * 100
        if value > 0, value < 0.1 { return "<0.1%" }
        return String(format: value >= 10 || value == 0 ? "%.0f%%" : "%.1f%%", value)
    }

    /// `12×`, `1.5×`.
    public static func factor(_ value: Double) -> String {
        value >= 10 ? "\(rows(value.rounded()))×" : String(format: "%.1f×", value)
    }

    /// The whole node as `Label: value` lines, for copying.
    public static func details(of node: QueryPlanNode, metrics: QueryPlanAnalysis.NodeMetrics? = nil) -> String {
        var lines = [node.detail.map { "\(node.operation) (\($0))" } ?? node.operation]
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { lines.append("\(label): \(value)") }
        }
        add("Object", node.objectName)
        add("Index", node.index)
        add("Cost", costRange(startup: node.estimatedStartupCost, total: node.estimatedTotalCost))
        add("Rows", node.estimatedRows.map(rows))
        add("Width", node.estimatedWidth.flatMap { $0 > 0 ? "\($0) bytes" : nil })
        if node.neverExecuted { lines.append("Never executed") }
        if let startup = node.actualStartupTime, let total = node.actualTotalTime {
            add("Actual Time", "\(milliseconds(startup))..\(milliseconds(total))")
        } else {
            add("Actual Time", node.actualTotalTime.map(milliseconds))
        }
        add("Actual Rows", node.actualRows.map(rows))
        add("Loops", node.actualLoops.map { String($0) })
        add("Filter", node.filter)
        add("Rows Removed by Filter", node.rowsRemovedByFilter.map(rows))
        add("Join Condition", node.joinCondition)
        add("Index Condition", node.indexCondition)
        if let buffers = node.buffers, !buffers.isEmpty { add("Buffers", buffers.summary) }
        if let metrics {
            add("Self Cost", metrics.selfCost.map(cost))
            add("Self Time", metrics.selfTime.map(milliseconds))
            for warning in metrics.warnings { add("Warning", warning.message) }
        }
        for property in QueryPlanNodeProperties.visible(node) { add(property.key, property.value) }
        return lines.joined(separator: "\n")
    }
}

/// Which of a node's extra properties are worth showing.
public enum QueryPlanNodeProperties {
    /// Flags PostgreSQL reports on every node that say nothing about this plan.
    static let hiddenKeys: Set<String> = ["Parallel Aware", "Async Capable", "Disabled", "Inner Unique"]
    /// Properties whose zero is the answer: two workers planned and none launched is why a query was slow.
    static let significantZeroKeys: Set<String> = ["Workers Launched", "Heap Fetches"]

    public static func visible(_ node: QueryPlanNode) -> [QueryPlanProperty] {
        node.properties.filter { property in
            guard !hiddenKeys.contains(property.key) else { return false }
            if significantZeroKeys.contains(property.key) { return true }
            return property.value != "false" && property.value != "0" && !property.value.isEmpty
        }
    }
}

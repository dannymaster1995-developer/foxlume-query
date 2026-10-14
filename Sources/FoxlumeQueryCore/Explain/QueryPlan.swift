import Foundation

/// The shape of what a server returned for EXPLAIN, which decides the parser.
public enum QueryPlanFormat: String, Sendable, Hashable, CaseIterable {
    /// `EXPLAIN (FORMAT JSON)`, with or without ANALYZE.
    case postgresJSON
    /// `EXPLAIN FORMAT=JSON` on MySQL (format versions 1 and 2) and MariaDB, and MariaDB's `ANALYZE FORMAT=JSON`.
    case mysqlJSON
    /// The indented `->` tree of MySQL's `EXPLAIN ANALYZE` and `EXPLAIN FORMAT=TREE`.
    case mysqlTree
    /// SQLite's `EXPLAIN QUERY PLAN` rows: id, parent, notused, detail.
    case sqliteQueryPlan
    /// DuckDB's `EXPLAIN (FORMAT JSON)` and `EXPLAIN (ANALYZE, FORMAT JSON)`.
    case duckdbJSON
    /// MongoDB's `explain` command reply.
    case mongoExplain
}

/// One named value of a node or plan, in the order the server reported it.
public struct QueryPlanProperty: Hashable, Sendable {
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

/// How a node reaches its rows, where the plan says so. Drives warnings now and node icons in a later diagram.
public enum QueryPlanAccess: String, Hashable, Sendable {
    /// Reads every row of a table: PostgreSQL Seq Scan, MySQL full table scan, SQLite SCAN without an index.
    case fullScan
    /// Walks a whole index.
    case indexScan
    /// Looks rows up through an index or key.
    case indexLookup
}

/// Block counts PostgreSQL reports with BUFFERS.
public struct QueryPlanBuffers: Hashable, Sendable {
    public var sharedHit = 0
    public var sharedRead = 0
    public var sharedDirtied = 0
    public var sharedWritten = 0
    public var localHit = 0
    public var localRead = 0
    public var localDirtied = 0
    public var localWritten = 0
    public var tempRead = 0
    public var tempWritten = 0

    public init() {}

    public var isEmpty: Bool { self == QueryPlanBuffers() }

    /// `shared hit=6 read=2, temp written=10`, the way PostgreSQL's text format prints it; zero counts are left out.
    public var summary: String {
        func group(_ name: String, _ counts: [(String, Int)]) -> String? {
            let shown = counts.filter { $0.1 > 0 }.map { "\($0.0)=\($0.1)" }
            return shown.isEmpty ? nil : name + " " + shown.joined(separator: " ")
        }
        return [
            group("shared", [("hit", sharedHit), ("read", sharedRead), ("dirtied", sharedDirtied), ("written", sharedWritten)]),
            group("local", [("hit", localHit), ("read", localRead), ("dirtied", localDirtied), ("written", localWritten)]),
            group("temp", [("read", tempRead), ("written", tempWritten)]),
        ].compactMap { $0 }.joined(separator: ", ")
    }

    /// Blocks read from outside the shared buffer cache.
    public var blocksRead: Int { sharedRead + localRead + tempRead }
}

/// One step of a plan. Numbers keep the units the server used: costs are planner units, times are milliseconds,
/// and actual times and rows are per loop, as PostgreSQL and MySQL report them.
public struct QueryPlanNode: Identifiable, Hashable, Sendable {
    /// Position in a pre-order walk of the plan, assigned when the plan is built. Stable for one plan.
    public var id: Int = 0
    public var operation: String
    /// A short qualifier the server attaches to the operation, such as a sort key or a subplan name.
    public var detail: String?
    public var relation: String?
    public var schema: String?
    public var alias: String?
    public var index: String?
    public var access: QueryPlanAccess?

    public var estimatedStartupCost: Double?
    public var estimatedTotalCost: Double?
    public var estimatedRows: Double?
    public var estimatedWidth: Int?

    public var actualStartupTime: Double?
    /// Time spent in this node and everything below it, per loop.
    public var actualTotalTime: Double?
    public var actualRows: Double?
    public var actualLoops: Int?
    /// The plan was measured, but this node never ran (an empty outer side, a branch that was not needed).
    public var neverExecuted = false
    public var buffers: QueryPlanBuffers?

    public var filter: String?
    public var joinCondition: String?
    public var indexCondition: String?
    /// Rows the filter discarded, per loop (PostgreSQL's "Rows Removed by Filter").
    public var rowsRemovedByFilter: Double?
    /// The share of examined rows the planner expects the filter to keep, 0…1 (MySQL's `filtered`).
    public var filteredFraction: Double?

    /// Everything else the server reported for this node, in its order.
    public var properties: [QueryPlanProperty] = []
    public var children: [QueryPlanNode] = []

    public init(operation: String) {
        self.operation = operation
    }

    /// The table or other object the node reads: `orders o` when aliased, schema-qualified when the plan names one.
    public var objectName: String? {
        guard let relation else { return alias }
        var name = schema.map { "\($0).\(relation)" } ?? relation
        if let alias, alias != relation { name += " \(alias)" }
        return name
    }

    public func property(_ key: String) -> String? {
        properties.first { $0.key == key }?.value
    }

    /// Every node of this subtree in pre-order.
    public var allNodes: [QueryPlanNode] {
        var out: [QueryPlanNode] = []
        func walk(_ node: QueryPlanNode) {
            out.append(node)
            node.children.forEach(walk)
        }
        walk(self)
        return out
    }
}

/// A parsed EXPLAIN result.
public struct QueryPlan: Sendable {
    public var format: QueryPlanFormat
    public var root: QueryPlanNode
    /// Milliseconds, when the server reports them.
    public var planningTime: Double?
    public var executionTime: Double?
    /// Plan-wide values: triggers, JIT, planning buffers, MySQL's query cost and the like.
    public var properties: [QueryPlanProperty]
    public var rawText: String

    public init(format: QueryPlanFormat, root: QueryPlanNode, planningTime: Double? = nil, executionTime: Double? = nil, properties: [QueryPlanProperty] = [], rawText: String) {
        self.format = format
        self.root = Self.numbered(root)
        self.planningTime = planningTime
        self.executionTime = executionTime
        self.properties = properties
        self.rawText = rawText
    }

    /// The plan reports measured values (ANALYZE), not only estimates.
    public var isAnalyzed: Bool {
        executionTime != nil || allNodes.contains { $0.actualLoops != nil || $0.actualTotalTime != nil || $0.actualRows != nil || $0.neverExecuted }
    }

    public var allNodes: [QueryPlanNode] { root.allNodes }

    public var nodeCount: Int { allNodes.count }

    public func node(id: Int) -> QueryPlanNode? {
        allNodes.first { $0.id == id }
    }

    /// The parent of every node but the root, keyed by node id.
    public var parentIDs: [Int: Int] {
        var parents: [Int: Int] = [:]
        func walk(_ node: QueryPlanNode) {
            for child in node.children {
                parents[child.id] = node.id
                walk(child)
            }
        }
        walk(root)
        return parents
    }

    public func property(_ key: String) -> String? {
        properties.first { $0.key == key }?.value
    }

    static func numbered(_ root: QueryPlanNode) -> QueryPlanNode {
        var next = 0
        func number(_ node: inout QueryPlanNode) {
            node.id = next
            next += 1
            for index in node.children.indices {
                number(&node.children[index])
            }
        }
        var copy = root
        number(&copy)
        return copy
    }

    /// One root for a forest: the only tree as is, or several under a synthetic node whose cost is their sum.
    static func singleRoot(_ roots: [QueryPlanNode], operation: String = "Query Plan") -> QueryPlanNode? {
        guard roots.count != 1 else { return roots.first }
        guard !roots.isEmpty else { return nil }
        var root = QueryPlanNode(operation: operation)
        let costs = roots.compactMap(\.estimatedTotalCost)
        root.estimatedTotalCost = costs.isEmpty ? nil : costs.reduce(0, +)
        root.children = roots
        return root
    }
}

/// Reads EXPLAIN output in any supported format.
public enum QueryPlanParser {
    /// Nil when the text is not a plan in that format; the raw text is still worth showing then.
    public static func parse(_ rawText: String, format: QueryPlanFormat) -> QueryPlan? {
        switch format {
        case .postgresJSON: return PostgresPlanParser.parse(rawText)
        case .mysqlJSON: return MySQLJSONPlanParser.parse(rawText)
        case .mysqlTree: return MySQLTreePlanParser.parse(rawText)
        case .sqliteQueryPlan: return SQLitePlanParser.parse(rawText)
        case .duckdbJSON: return DuckDBPlanParser.parse(rawText)
        case .mongoExplain: return MongoPlanParser.parse(rawText)
        }
    }

    /// The server's rows as the text a parser reads: one-column output line by line, SQLite's id/parent/detail rows
    /// tab-separated, and DuckDB's key/value rows by their value.
    public static func rawText(of results: [StatementResult], format: QueryPlanFormat) -> String {
        guard let result = results.last(where: \.hasResultSet) else { return "" }
        switch format {
        case .sqliteQueryPlan:
            return result.rows.map { row in row.map { $0.textValue ?? "" }.joined(separator: "\t") }.joined(separator: "\n")
        case .duckdbJSON:
            return result.rows.compactMap { $0.last?.textValue }.joined(separator: "\n")
        case .postgresJSON, .mysqlJSON, .mysqlTree, .mongoExplain:
            return result.rows.map { row in row.compactMap(\.textValue).joined(separator: "\t") }.joined(separator: "\n")
        }
    }
}

import Foundation
import Testing
@testable import FoxlumeQueryCore

private func postgres(_ planJSON: String) throws -> QueryPlan {
    try #require(PostgresPlanParser.parse(#"[{"Plan": \#(planJSON)}]"#))
}

@Suite("Plan analysis")
struct QueryPlanAnalysisTests {
    @Test func costSharesAddUpAndACheapLimitDoesNotGoNegative() throws {
        let join = try #require(PostgresPlanParser.parse(ExplainFixtures.postgresJoin))
        let analysis = QueryPlanAnalysis(plan: join)
        let shares = join.allNodes.compactMap { analysis[$0.id].costShare }
        #expect(shares.count == join.nodeCount)
        #expect(abs(shares.reduce(0, +) - 1) < 1e-9)
        #expect(analysis.availableMetrics == [.selfCost])
        #expect(analysis.defaultMetric == .selfCost)

        // PostgreSQL prices a Limit below its input on purpose.
        let limit = try postgres(#"{"Node Type": "Limit", "Total Cost": 0.5, "Plans": [{"Node Type": "Sort", "Total Cost": 120.0, "Plans": [{"Node Type": "Seq Scan", "Relation Name": "t", "Total Cost": 100.0}]}]}"#)
        let limitAnalysis = QueryPlanAnalysis(plan: limit)
        #expect(limitAnalysis[0].selfCost == 0)
        #expect(limitAnalysis[1].selfCost == 20)
        #expect(limitAnalysis[2].selfCost == 100)
        #expect(limitAnalysis.totalSelfCost == 120)
        #expect(limitAnalysis.severity(of: 2, metric: .selfCost) == .critical)
        #expect(limitAnalysis.severity(of: 1, metric: .selfCost) == .moderate)
        #expect(limitAnalysis.severity(of: 0, metric: .selfCost) == .low)
    }

    @Test func severityBands() {
        #expect(QueryPlanSeverity.forShare(0.51) == .critical)
        #expect(QueryPlanSeverity.forShare(0.5) == .high)
        #expect(QueryPlanSeverity.forShare(0.21) == .high)
        #expect(QueryPlanSeverity.forShare(0.2) == .moderate)
        #expect(QueryPlanSeverity.forShare(0.051) == .moderate)
        #expect(QueryPlanSeverity.forShare(0.05) == .low)
        #expect(QueryPlanSeverity.forShare(3) == .critical)
        #expect(QueryPlanSeverity.forShare(.nan) == .low)
    }

    /// Times are per loop; under a Gather the loops are processes running at the same time.
    @Test func selfTimeIsCorrectedForLoopsAndWorkers() throws {
        let plan = try #require(PostgresPlanParser.parse(ExplainFixtures.postgresParallelAnalyze))
        let analysis = QueryPlanAnalysis(plan: plan)
        #expect(analysis.availableMetrics == [.selfCost, .selfTime])
        #expect(analysis.defaultMetric == .selfTime)
        let scan = analysis[3]
        #expect(scan.totalTime.map { abs($0 - 19.149) < 1e-9 } == true, "3 loops over 3 processes")
        let gather = analysis[1]
        #expect(gather.selfTime.map { abs($0 - (21.411 - 19.162)) < 1e-9 } == true)
        #expect(analysis.severity(of: 3, metric: .selfTime) == .critical)
        let times = plan.allNodes.compactMap { analysis[$0.id].timeShare }
        #expect(abs(times.reduce(0, +) - 1) < 1e-9)

        // A nested loop's inner side runs once per outer row: 0.5 ms × 40 loops.
        let loops = try postgres(#"{"Node Type": "Nested Loop", "Actual Total Time": 25.0, "Actual Loops": 1, "Plans": [{"Node Type": "Seq Scan", "Actual Total Time": 4.0, "Actual Loops": 1}, {"Node Type": "Index Scan", "Actual Total Time": 0.5, "Actual Loops": 40}]}"#)
        let loopAnalysis = QueryPlanAnalysis(plan: loops)
        #expect(loopAnalysis[2].totalTime == 20)
        #expect(loopAnalysis[0].selfTime == 1)
    }

    @Test func warnsAboutALargeFilteredScan() throws {
        let parallel = QueryPlanAnalysis(plan: try #require(PostgresPlanParser.parse(ExplainFixtures.postgresParallelAnalyze)))
        let warning = try #require(parallel[3].warnings.first)
        #expect(warning.kind == .largeScan)
        #expect(warning.message.contains("2,000,000 rows of perf_big to keep 476"))
        #expect(parallel.warningCount == 1)

        // MySQL's tree puts the filter right above the scan.
        let tree = try #require(MySQLTreePlanParser.parse(ExplainFixtures.mysqlLargeScanAnalyze))
        let treeAnalysis = QueryPlanAnalysis(plan: tree)
        #expect(treeAnalysis[2].warnings.map(\.kind) == [.largeScan])
        #expect(treeAnalysis[2].warnings.first?.message.contains("2,000,000 rows of perf_big to keep 476") == true)

        // MySQL's JSON: rows examined and the expected filtered share.
        let json = #"{"query_block": {"select_id": 1, "table": {"table_name": "perf_big", "access_type": "ALL", "rows_examined_per_scan": 1990785, "filtered": "11.11", "attached_condition": "(payload like 'abc%')"}}}"#
        let jsonPlan = try #require(MySQLJSONPlanParser.parse(json))
        #expect(QueryPlanAnalysis(plan: jsonPlan)[1].warnings.map(\.kind) == [.largeScan])

        // PostgreSQL without ANALYZE only knows the table is expensive to read.
        let estimate = try postgres(#"{"Node Type": "Seq Scan", "Relation Name": "perf_big", "Total Cost": 29168.67, "Plan Rows": 83, "Filter": "(payload ~~ 'abc%'::text)"}"#)
        #expect(QueryPlanAnalysis(plan: estimate)[0].warnings.first?.message.hasPrefix("Reads all of perf_big") == true)

        // Small tables, scans without a filter and scans that keep most rows are fine.
        let small = try postgres(#"{"Node Type": "Seq Scan", "Relation Name": "t", "Total Cost": 7.12, "Filter": "(a = 1)"}"#)
        #expect(QueryPlanAnalysis(plan: small).warningCount == 0)
        let unfiltered = try postgres(#"{"Node Type": "Seq Scan", "Relation Name": "t", "Total Cost": 50000, "Actual Rows": 2000000, "Actual Loops": 1}"#)
        #expect(QueryPlanAnalysis(plan: unfiltered).warningCount == 0)
        let mostKept = try postgres(#"{"Node Type": "Seq Scan", "Relation Name": "t", "Actual Rows": 90000, "Actual Loops": 1, "Filter": "(a > 1)", "Rows Removed by Filter": 10000}"#)
        #expect(QueryPlanAnalysis(plan: mostKept).warningCount == 0)
    }

    @Test func warnsAboutMisestimatesSpillsAndMissingWorkers() throws {
        let plan = try postgres(#"""
        {"Node Type": "Gather", "Workers Planned": 2, "Workers Launched": 0, "Plan Rows": 10, "Actual Rows": 5000, "Actual Loops": 1,
         "Plans": [{"Node Type": "Sort", "Sort Method": "external merge", "Sort Space Used": 12345, "Sort Space Type": "Disk", "Plan Rows": 100, "Actual Rows": 120, "Actual Loops": 1,
           "Plans": [{"Node Type": "Hash", "Hash Batches": 4, "Plan Rows": 1, "Actual Rows": 0, "Actual Loops": 1}]}]}
        """#)
        let analysis = QueryPlanAnalysis(plan: plan)
        #expect(analysis[0].warnings.map(\.kind) == [.rowEstimate, .workersNotLaunched])
        #expect(analysis[0].warnings[0].message.hasPrefix("The planner expected 10 rows but got 5,000, 500× more."))
        #expect(analysis[0].rowEstimateRatio == 500)
        #expect(analysis[1].warnings.map(\.kind) == [.diskSort])
        #expect(analysis[1].warnings[0].message.contains("12345 kB"))
        // One row expected and none found is not worth a warning; a spilled hash is.
        #expect(analysis[2].warnings.map(\.kind) == [.hashBatches])
        #expect(analysis.warningCount == 4)
    }

    @Test func plansWithoutCostsHaveNoSeverity() throws {
        let plan = try #require(SQLitePlanParser.parse(ExplainFixtures.sqliteQueryPlan))
        let analysis = QueryPlanAnalysis(plan: plan)
        #expect(analysis.availableMetrics.isEmpty)
        #expect(analysis.defaultMetric == nil)
        #expect(analysis.severity(of: 1, metric: analysis.defaultMetric) == nil)
    }
}

@Suite("Plan text")
struct QueryPlanTextTests {
    @Test func formatsNumbers() {
        #expect(QueryPlanText.rows(1234) == "1,234")
        #expect(QueryPlanText.rows(66666.33) == "66,666.33")
        #expect(QueryPlanText.rows(1_990_000) == "1,990,000")
        #expect(QueryPlanText.costRange(startup: 0.15, total: 14.99) == "0.15..14.99")
        #expect(QueryPlanText.costRange(startup: nil, total: 31.5) == "31.50")
        #expect(QueryPlanText.costRange(startup: 1, total: nil) == nil)
        #expect(QueryPlanText.milliseconds(0.03) == "0.030 ms")
        #expect(QueryPlanText.milliseconds(21.428) == "21.4 ms")
        #expect(QueryPlanText.milliseconds(294) == "294 ms")
        #expect(QueryPlanText.milliseconds(1234) == "1.23 s")
        #expect(QueryPlanText.percent(0.894) == "89%")
        #expect(QueryPlanText.percent(0.0612) == "6.1%")
        #expect(QueryPlanText.percent(0.0001) == "<0.1%")
        #expect(QueryPlanText.percent(0) == "0%")
    }

    @Test func copiesNodeDetailsAndHidesNoise() throws {
        let plan = try #require(PostgresPlanParser.parse(ExplainFixtures.postgresJoinAnalyze))
        let scan = plan.allNodes[1]
        let analysis = QueryPlanAnalysis(plan: plan)
        let text = QueryPlanText.details(of: scan, metrics: analysis[scan.id])
        let lines = text.components(separatedBy: "\n")
        #expect(lines.first == "Seq Scan")
        #expect(lines.contains("Object: orders o"))
        #expect(lines.contains("Cost: 0.00..7.12"))
        #expect(lines.contains("Filter: (status = 'paid'::text)"))
        #expect(lines.contains("Rows Removed by Filter: 200"))
        #expect(lines.contains("Buffers: shared hit=4"))
        #expect(lines.contains("Parent Relationship: Outer"))
        #expect(!text.contains("Parallel Aware"))
        #expect(!text.contains("Disabled"))

        var node = QueryPlanNode(operation: "Gather")
        node.properties = [QueryPlanProperty("Workers Launched", "0"), QueryPlanProperty("Single Copy", "false"), QueryPlanProperty("Async Capable", "true"), QueryPlanProperty("Heap Fetches", "0"), QueryPlanProperty("Cache Evictions", "0")]
        #expect(QueryPlanNodeProperties.visible(node).map(\.key) == ["Workers Launched", "Heap Fetches"])
    }
}

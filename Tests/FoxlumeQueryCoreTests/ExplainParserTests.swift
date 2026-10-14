import Foundation
import Testing
@testable import FoxlumeQueryCore

private func operations(_ plan: QueryPlan) -> [String] {
    plan.allNodes.map(\.operation)
}

@Suite("Plan JSON reader")
struct PlanJSONTests {
    @Test func keepsKeyOrderAndNumberSpelling() throws {
        let json = try #require(PlanJSON.parse(#"{"b": 1, "a": 0.00, "c": [true, null, "x"]}"#))
        #expect(json.members.map(\.key) == ["b", "a", "c"])
        #expect(json["a"]?.displayText == "0.00")
        #expect(json["a"]?.double == 0)
        #expect(json["c"]?.displayText == "true, null, x")
        #expect(json["missing"] == nil)
    }

    @Test func readsEscapesAndSurrogatePairs() throws {
        let json = try #require(PlanJSON.parse(#"{"k": "a\"b\\c\né😀"}"#))
        #expect(json["k"]?.string == "a\"b\\c\né😀")
    }

    @Test func numbersSentAsStringsStillRead() throws {
        let json = try #require(PlanJSON.parse(#"{"query_cost": "31.50", "rows": "~20000", "n": 3}"#))
        #expect(json["query_cost"]?.double == 31.5)
        #expect(json["rows"]?.double == 20000)
        #expect(json["n"]?.int == 3)
    }

    @Test func rejectsMalformedAndTooDeepInput() {
        #expect(PlanJSON.parse("") == nil)
        #expect(PlanJSON.parse("{\"a\": }") == nil)
        #expect(PlanJSON.parse("[1, 2") == nil)
        #expect(PlanJSON.parse("{} trailing") == nil)
        #expect(PlanJSON.parse(String(repeating: "[", count: 600) + String(repeating: "]", count: 600)) == nil)
        #expect(PlanJSON.parse(String(repeating: "[", count: 100) + String(repeating: "]", count: 100)) != nil)
    }

    @Test func printsIndentedJSON() throws {
        let json = try #require(PlanJSON.parse(#"{"a":{"b":[1,2]},"c":{}}"#))
        #expect(json.prettyText == "{\n  \"a\": {\n    \"b\": [\n      1,\n      2\n    ]\n  },\n  \"c\": {}\n}")
    }
}

@Suite("PostgreSQL plan parser")
struct PostgresPlanParserTests {
    @Test func readsAJoinPlan() throws {
        let plan = try #require(PostgresPlanParser.parse(ExplainFixtures.postgresJoin))
        #expect(plan.format == .postgresJSON)
        #expect(!plan.isAnalyzed)
        #expect(plan.planningTime == nil && plan.executionTime == nil)
        let scans = plan.allNodes.filter { $0.relation != nil }
        #expect(Set(scans.map(\.relation)) == ["orders", "users"])
        let orders = try #require(scans.first { $0.relation == "orders" })
        #expect(orders.operation == "Seq Scan")
        #expect(orders.alias == "o")
        #expect(orders.objectName == "orders o")
        #expect(orders.filter == "(status = 'paid'::text)")
        #expect(orders.access == .fullScan)
        #expect(orders.estimatedStartupCost == 0)
        #expect(orders.estimatedTotalCost == 7.12)
        #expect(orders.estimatedRows == 50)
        #expect(orders.estimatedWidth == 10)
        #expect(plan.root.id == 0)
        #expect(plan.allNodes.map(\.id) == Array(0..<plan.nodeCount))
    }

    @Test func readsAnAnalyzedPlanWithBuffers() throws {
        let plan = try #require(PostgresPlanParser.parse(ExplainFixtures.postgresJoinAnalyze))
        #expect(plan.isAnalyzed)
        #expect(plan.planningTime == 1.442)
        #expect(plan.executionTime == 0.167)
        #expect(operations(plan) == ["Nested Loop", "Seq Scan", "Memoize", "Index Scan"])
        #expect(plan.root.actualRows == 50)
        #expect(plan.root.actualLoops == 1)
        #expect(plan.root.buffers?.sharedHit == 6)
        #expect(plan.root.buffers?.summary == "shared hit=6")
        let memoize = plan.allNodes[2]
        #expect(memoize.actualLoops == 50)
        #expect(memoize.property("Cache Hits") == "49")
        let index = plan.allNodes[3]
        #expect(index.index == "users_pkey")
        #expect(index.indexCondition == "(id = o.user_id)")
        #expect(index.access == .indexLookup)
        #expect(plan.allNodes[1].rowsRemovedByFilter == 200)
        #expect(plan.property("Planning Buffers") == "shared hit=262")
        // Buffer counts live in `buffers`, not among the properties; the order of the rest is the server's.
        #expect(!plan.root.properties.contains { $0.key.hasSuffix("Blocks") })
        #expect(plan.root.properties.map(\.key).prefix(3) == ["Parallel Aware", "Async Capable", "Join Type"])
    }

    @Test func namesNodesTheWayTheTextFormatDoes() throws {
        let plan = try #require(PostgresPlanParser.parse(ExplainFixtures.postgresParallelAnalyze))
        #expect(operations(plan) == ["Finalize Aggregate", "Gather", "Partial Aggregate", "Parallel Seq Scan"])
        let gather = plan.allNodes[1]
        #expect(gather.property("Workers Launched") == "2")
        // An empty Workers list is dropped.
        #expect(plan.allNodes[2].property("Workers") == nil)
        // PostgreSQL 18 averages actual rows over loops.
        #expect(plan.allNodes[3].actualRows == 158.67)

        func name(_ json: String) -> String? {
            PostgresPlanParser.parse(#"[{"Plan": \#(json)}]"#)?.root.operation
        }
        #expect(name(#"{"Node Type": "Hash Join", "Join Type": "Left"}"#) == "Hash Left Join")
        #expect(name(#"{"Node Type": "Nested Loop", "Join Type": "Anti"}"#) == "Nested Loop Anti Join")
        #expect(name(#"{"Node Type": "Merge Join", "Join Type": "Inner"}"#) == "Merge Join")
        #expect(name(#"{"Node Type": "Aggregate", "Strategy": "Hashed"}"#) == "HashAggregate")
        #expect(name(#"{"Node Type": "Aggregate", "Strategy": "Sorted"}"#) == "GroupAggregate")
        #expect(name(#"{"Node Type": "Index Scan", "Scan Direction": "Backward"}"#) == "Index Scan Backward")
        #expect(name(#"{"Node Type": "ModifyTable", "Operation": "Update"}"#) == "Update")
        #expect(name(#"{"Plan Rows": 1}"#) == "Unknown")
    }

    @Test func keepsTriggersSubplansAndOldRuntimeKey() throws {
        let json = #"""
        [{"Plan": {"Node Type": "ModifyTable", "Operation": "Delete", "Relation Name": "t", "Actual Total Time": 1.5, "Actual Loops": 1,
          "Plans": [{"Node Type": "Seq Scan", "Subplan Name": "InitPlan 1", "Actual Loops": 0, "Relation Name": "u"}]},
          "Triggers": [{"Trigger Name": "audit", "Relation": "t", "Time": 0.25, "Calls": 3}],
          "Total Runtime": 2.5}]
        """#
        let plan = try #require(PostgresPlanParser.parse(json))
        #expect(plan.executionTime == 2.5)
        #expect(plan.property("Trigger audit on t") == "0.25 ms, 3 calls")
        let child = try #require(plan.root.children.first)
        #expect(child.detail == "InitPlan 1")
        #expect(child.neverExecuted)
    }

    @Test func rejectsWhatIsNotAPlan() {
        #expect(PostgresPlanParser.parse("") == nil)
        #expect(PostgresPlanParser.parse("Seq Scan on t  (cost=0.00..1.00 rows=1 width=4)") == nil)
        #expect(PostgresPlanParser.parse(#"[{"NotAPlan": {}}]"#) == nil)
        #expect(PostgresPlanParser.parse(#"[{"Plan": "x"}]"#) == nil)
    }
}

@Suite("MySQL plan parsers")
struct MySQLPlanParserTests {
    @Test func readsAJSONJoin() throws {
        let plan = try #require(MySQLJSONPlanParser.parse(ExplainFixtures.mysqlJoin))
        #expect(operations(plan) == ["Query Block", "Nested Loop", "Index Lookup", "Unique Index Lookup"])
        #expect(plan.root.detail == "#1")
        #expect(plan.root.estimatedTotalCost == 31.5)
        #expect(plan.property("Query Cost") == "31.50")
        let orders = plan.allNodes[2]
        #expect(orders.relation == "o")
        #expect(orders.index == "orders_status_idx")
        #expect(orders.estimatedRows == 50)
        // A table costs its reads plus evaluating its conditions.
        #expect(orders.estimatedTotalCost == 14)
        #expect(orders.property("Ref") == "const")
        #expect(orders.property("Possible Keys") == "orders_user_id_idx, orders_status_idx")
        let users = plan.allNodes[3]
        #expect(users.estimatedTotalCost == 17.5)
        #expect(plan.allNodes[1].estimatedTotalCost == 31.5)
    }

    @Test func readsSortAndGroupWrappers() throws {
        let plan = try #require(MySQLJSONPlanParser.parse(ExplainFixtures.mysqlGroup))
        #expect(operations(plan) == ["Query Block", "Sort", "Group", "Full Index Scan"])
        #expect(plan.allNodes[1].detail == "filesort, temporary table")
        let table = plan.allNodes[3]
        #expect(table.access == .indexScan)
        #expect(table.filter == "(`foxlume`.`orders`.`total` > 10.00)")
        #expect(table.filteredFraction.map { abs($0 - 0.3333) < 0.0001 } == true)
        #expect(table.property("Filtered") == "33.33%")
    }

    @Test func readsUnionsDerivedTablesAndSubqueries() throws {
        let plan = try #require(MySQLJSONPlanParser.parse(ExplainFixtures.mysqlUnion))
        #expect(plan.root.operation == "Query Block")
        let union = try #require(plan.root.children.first)
        #expect(union.operation == "Union")
        #expect(union.children.map(\.operation) == ["Union Member", "Union Member"])
        #expect(union.children.map(\.detail) == ["#1", "#3"])
        let derived = try #require(union.children[0].children.first)
        #expect(derived.relation == "t")
        #expect(derived.children.first?.operation == "Materialize")
        #expect(derived.children.first?.children.first?.detail == "#2")
        let semiJoin = union.children[1].allNodes
        #expect(semiJoin.contains { $0.relation == "<subquery4>" && $0.index == "<auto_distinct_key>" })
        #expect(semiJoin.contains { $0.relation == "orders" && $0.access == .fullScan && $0.filter == "(`foxlume`.`orders`.`total` > 100.00)" })
    }

    @Test func readsAnUpdate() throws {
        let plan = try #require(MySQLJSONPlanParser.parse(ExplainFixtures.mysqlUpdate))
        let table = try #require(plan.root.children.first)
        #expect(table.operation == "Update")
        #expect(table.relation == "orders")
        #expect(table.index == "PRIMARY")
        #expect(table.property("Access Type") == "range")
    }

    @Test func readsFormatVersionTwo() throws {
        let plan = try #require(MySQLJSONPlanParser.parse(ExplainFixtures.mysqlVersionTwo))
        #expect(operations(plan) == ["Nested loop inner join", "Index lookup", "Single-row index lookup"])
        #expect(plan.root.estimatedTotalCost == 25.5)
        let orders = plan.allNodes[1]
        #expect(orders.relation == "orders")
        #expect(orders.alias == "o")
        #expect(orders.schema == "foxlume")
        #expect(orders.index == "orders_status_idx")
        #expect(orders.indexCondition == "status='paid'")
        #expect(plan.property("Query Type") == "select")
    }

    @Test func readsMariaDBAnalyze() throws {
        // MariaDB's ANALYZE FORMAT=JSON: estimates beside r_ measurements, time totalled over loops.
        let json = #"""
        {"query_optimization": {"r_total_time_ms": 0.12},
         "query_block": {"select_id": 1, "cost": 1.0089884, "r_loops": 1, "r_total_time_ms": 0.9,
          "nested_loop": [
            {"table": {"table_name": "u", "access_type": "ALL", "loops": 1, "r_loops": 1, "rows": 5, "r_rows": 5, "cost": 0.0923548,
                       "r_table_time_ms": 0.01, "filtered": 100, "r_filtered": 100}},
            {"block-nl-join": {"table": {"table_name": "o", "access_type": "ALL", "r_loops": 2, "rows": 250, "r_rows": 250, "cost": 0.9166336,
                       "r_total_time_ms": 0.6, "filtered": 10, "r_filtered": 20, "attached_condition": "o.user_id = u.id"},
                       "buffer_type": "flat", "join_type": "BNL"}}
          ]}}
        """#
        let plan = try #require(MySQLJSONPlanParser.parse(json))
        #expect(plan.isAnalyzed)
        #expect(plan.planningTime == 0.12)
        #expect(plan.executionTime == 0.9)
        #expect(plan.root.estimatedTotalCost == 1.0089884)
        let users = try #require(plan.allNodes.first { $0.relation == "u" })
        #expect(users.actualRows == 5)
        #expect(users.estimatedRows == 5)
        let orders = try #require(plan.allNodes.first { $0.relation == "o" })
        #expect(orders.actualLoops == 2)
        #expect(orders.actualTotalTime == 0.3)
        #expect(orders.property("Actual Filtered") == "20%")
        #expect(plan.allNodes.contains { $0.operation == "Block Nested Loop" && $0.property("Join Type") == "BNL" })
    }

    @Test func readsTheAnalyzeTree() throws {
        let plan = try #require(MySQLTreePlanParser.parse(ExplainFixtures.mysqlJoinAnalyze))
        #expect(plan.format == .mysqlTree)
        #expect(operations(plan) == ["Nested loop inner join", "Index lookup", "Single-row index lookup"])
        #expect(plan.root.estimatedTotalCost == 31.5)
        #expect(plan.root.estimatedRows == 50)
        #expect(plan.root.actualStartupTime == 0.346)
        #expect(plan.root.actualTotalTime == 0.431)
        #expect(plan.root.actualRows == 50)
        #expect(plan.root.actualLoops == 1)
        #expect(plan.executionTime == 0.431)
        let lookup = plan.allNodes[1]
        #expect(lookup.relation == "o")
        #expect(lookup.index == "orders_status_idx")
        #expect(lookup.indexCondition == "(status='paid')")
        #expect(lookup.access == .indexLookup)
        let inner = plan.allNodes[2]
        #expect(inner.actualLoops == 50)
        // Engineering notation: 372e-6 ms.
        #expect(inner.actualTotalTime.map { abs($0 - 387e-6) < 1e-12 } == true)
        #expect(inner.indexCondition == "(id=o.user_id)")
    }

    @Test func readsFiltersSortsHashJoinsAndStepsWithoutCost() throws {
        let group = try #require(MySQLTreePlanParser.parse(ExplainFixtures.mysqlHashJoinAnalyze))
        #expect(operations(group).prefix(3) == ["Limit", "Sort", "Table scan"])
        #expect(group.root.detail == "10 row(s)")
        #expect(group.root.estimatedTotalCost == nil)
        #expect(group.allNodes[2].relation == "<temporary>")
        let join = try #require(group.allNodes.first { $0.operation == "Inner hash join" })
        #expect(join.joinCondition == "<hash>(u.full_name)=<hash>(o.notes)")
        let filter = try #require(group.allNodes.first { $0.operation == "Filter" })
        #expect(filter.filter == "(u.full_name = o.notes)")
        #expect(group.allNodes.last?.operation == "Table scan")
        #expect(group.allNodes.last?.relation == "u")
        #expect(group.allNodes.contains { $0.operation == "Hash" && $0.children.count == 1 })
    }

    @Test func marksStepsThatNeverRan() throws {
        let plan = try #require(MySQLTreePlanParser.parse(ExplainFixtures.mysqlNeverExecuted))
        let lookup = try #require(plan.allNodes.last)
        #expect(lookup.neverExecuted)
        #expect(lookup.estimatedTotalCost == 8)
        #expect(lookup.actualTotalTime == nil)
        #expect(lookup.index == "orders_user_id_idx")
    }

    @Test func treeEdgeCases() throws {
        // A lookup condition that looks like a measurement stays part of the description.
        let node = MySQLTreePlanParser.parseNode("Single-row index lookup on t using PRIMARY (id=5)  (cost=0.35 rows=1)")
        #expect(node.indexCondition == "(id=5)")
        #expect(node.estimatedTotalCost == 0.35)
        #expect(node.estimatedRows == 1)
        // Startup and total cost, and FORMAT=TREE without measurements.
        let ranged = MySQLTreePlanParser.parseNode("Filter: (`<subquery2>`.b is not null)  (cost=2.83..1.80 rows=9)")
        #expect(ranged.estimatedStartupCost == 2.83)
        #expect(ranged.estimatedTotalCost == 1.8)
        #expect(ranged.actualRows == nil)
        // A literal that breaks the node over two lines is joined back; rows written as 1.99e+6.
        let text = "-> Filter: (t.note = 'a\nb')  (cost=10 rows=1.99e+6)\n    -> Table scan on t  (cost=5 rows=2e+6)\n"
        let plan = try #require(MySQLTreePlanParser.parse(text))
        #expect(plan.root.filter == "(t.note = 'a b')")
        #expect(plan.root.estimatedRows == 1_990_000)
        #expect(plan.root.children.first?.estimatedRows == 2_000_000)
        #expect(plan.root.children.first?.access == .fullScan)
        #expect(MySQLTreePlanParser.parse("not a tree") == nil)
        // Two top-level iterators get one synthetic root that sums their costs.
        let forest = try #require(MySQLTreePlanParser.parse("-> Rows fetched before execution  (cost=1 rows=1)\n-> Table scan on x  (cost=2 rows=3)"))
        #expect(forest.root.operation == "Query Plan")
        #expect(forest.root.estimatedTotalCost == 3)
    }
}

@Suite("SQLite, DuckDB and MongoDB plan parsers")
struct OtherPlanParserTests {
    @Test func readsSQLiteQueryPlanRows() throws {
        let plan = try #require(SQLitePlanParser.parse(ExplainFixtures.sqliteQueryPlan))
        #expect(plan.root.operation == "Query Plan")
        #expect(plan.root.children.map(\.operation) == ["SEARCH", "LIST SUBQUERY 1", "SEARCH", "USE TEMP B-TREE FOR GROUP BY", "USE TEMP B-TREE FOR ORDER BY"])
        let search = plan.root.children[0]
        #expect(search.relation == "al")
        #expect(search.index == "INTEGER PRIMARY KEY")
        #expect(search.indexCondition == "(rowid=?)")
        #expect(search.access == .indexLookup)
        let subquery = plan.root.children[1]
        #expect(subquery.children.map(\.operation) == ["SCAN", "CREATE BLOOM FILTER"])
        #expect(subquery.children[0].relation == "Track")
        #expect(subquery.children[0].access == .fullScan)
        #expect(plan.root.estimatedTotalCost == nil)
    }

    @Test func sqliteEdgeCases() throws {
        let covering = SQLitePlanParser.describe("SCAN t USING COVERING INDEX t_idx")
        #expect(covering.relation == "t")
        #expect(covering.index == "t_idx")
        #expect(covering.access == .indexScan)
        #expect(covering.property("Covering Index") == "true")
        let old = SQLitePlanParser.describe("SEARCH TABLE t AS x USING INDEX i (a=? AND b>?)")
        #expect(old.relation == "t")
        #expect(old.alias == "x")
        #expect(old.index == "i")
        #expect(old.indexCondition == "(a=? AND b>?)")
        // A single row is its own root.
        #expect(SQLitePlanParser.parse("2\t0\t0\tSCAN t")?.root.operation == "SCAN")
        #expect(SQLitePlanParser.parse("") == nil)
    }

    @Test func readsDuckDBPlans() throws {
        let plan = try #require(DuckDBPlanParser.parse(ExplainFixtures.duckdbPlan))
        #expect(plan.root.operation == "PROJECTION")
        let scan = try #require(plan.allNodes.last)
        #expect(scan.operation == "SEQ SCAN")
        #expect(scan.relation == "fq_explain.main.t")
        #expect(scan.filter == "id>10")
        #expect(scan.estimatedRows == 20000)
        #expect(scan.access == .fullScan)
        #expect(!plan.isAnalyzed)

        let analyzed = try #require(DuckDBPlanParser.parse(ExplainFixtures.duckdbAnalyze))
        #expect(analyzed.isAnalyzed)
        #expect(analyzed.root.operation == "PROJECTION", "the EXPLAIN_ANALYZE wrapper is skipped")
        #expect(analyzed.executionTime.map { abs($0 - 3.73175) < 0.000001 } == true)
        let join = try #require(analyzed.allNodes.first { $0.operation == "HASH JOIN" })
        #expect(join.joinCondition == "g = g")
        #expect(join.detail == "INNER")
        #expect(join.actualRows == 99989)
        // Operators are timed on their own; the model's time includes what is below.
        let childTime = join.children.compactMap(\.actualTotalTime).reduce(0, +)
        #expect((join.actualTotalTime ?? 0) > childTime)
        let analyzedScan = try #require(analyzed.allNodes.first { $0.relation == "fq_explain.main.t" })
        #expect(analyzedScan.rowsRemovedByFilter == 11)
    }

    @Test func readsMongoExplainReplies() throws {
        let planner = #"""
        {"queryPlanner": {"namespace": "foxlume.orders", "rejectedPlans": [],
          "winningPlan": {"stage": "FETCH", "filter": {"total": {"$gt": 10}},
            "inputStage": {"stage": "IXSCAN", "indexName": "status_1", "keyPattern": {"status": 1}, "indexBounds": {"status": ["[\"paid\", \"paid\"]"]}}}}}
        """#
        let plan = try #require(MongoPlanParser.parse(planner))
        #expect(operations(plan) == ["FETCH", "IXSCAN"])
        #expect(plan.root.filter == #"{"total": {"$gt": 10}}"#)
        #expect(plan.allNodes[1].index == "status_1")
        #expect(plan.allNodes[1].relation == "orders")
        #expect(plan.property("Namespace") == "foxlume.orders")
        #expect(!plan.isAnalyzed)

        let stats = #"""
        {"queryPlanner": {"namespace": "foxlume.orders", "winningPlan": {"queryPlan": {"stage": "COLLSCAN"}}},
         "executionStats": {"nReturned": 3, "executionTimeMillis": 4, "totalKeysExamined": 0, "totalDocsExamined": 250,
           "executionStages": {"stage": "COLLSCAN", "filter": {"status": {"$eq": "x"}}, "nReturned": 3, "executionTimeMillisEstimate": 2, "docsExamined": 250}}}
        """#
        let measured = try #require(MongoPlanParser.parse(stats))
        #expect(measured.executionTime == 4)
        #expect(measured.root.access == .fullScan)
        #expect(measured.root.actualRows == 3)
        #expect(measured.root.rowsRemovedByFilter == 247)
        #expect(measured.property("Total Docs Examined") == "250")
        #expect(MongoPlanParser.parse("[]") == nil)
    }

    @Test func dispatchesByFormatAndFlattensRows() {
        let sqliteRows = [StatementResult(columns: [ResultColumn(name: "id"), ResultColumn(name: "parent"), ResultColumn(name: "notused"), ResultColumn(name: "detail")],
                                          rows: [[.text("2"), .text("0"), .text("0"), .text("SCAN t")]])]
        #expect(QueryPlanParser.rawText(of: sqliteRows, format: .sqliteQueryPlan) == "2\t0\t0\tSCAN t")
        let duckRows = [StatementResult(columns: [ResultColumn(name: "explain_key"), ResultColumn(name: "explain_value")], rows: [[.text("physical_plan"), .text("[]")]])]
        #expect(QueryPlanParser.rawText(of: duckRows, format: .duckdbJSON) == "[]")
        let message = [StatementResult(message: "BEGIN"), StatementResult(columns: [ResultColumn(name: "QUERY PLAN")], rows: [[.text("[1]")]])]
        #expect(QueryPlanParser.rawText(of: message, format: .postgresJSON) == "[1]")
        #expect(QueryPlanParser.parse(ExplainFixtures.postgresJoin, format: .postgresJSON) != nil)
        #expect(QueryPlanParser.parse(ExplainFixtures.postgresJoin, format: .mysqlJSON) == nil)
    }
}

import Foundation
import Testing
@testable import FoxlumeQueryCore

private func request(_ kind: DatabaseKind, _ statement: String, _ mode: ExplainMode = .plan, version: String = "", readOnly: Bool = false) throws -> ExplainRequest {
    try ExplainRequest.make(kind: kind, serverVersion: version, statement: statement, mode: mode, readOnly: readOnly)
}

private func failure(_ kind: DatabaseKind, _ statement: String, _ mode: ExplainMode = .plan, version: String = "", readOnly: Bool = false) -> ExplainError? {
    do {
        _ = try request(kind, statement, mode, version: version, readOnly: readOnly)
        return nil
    } catch {
        return error as? ExplainError
    }
}

@Suite("Explain statements per engine")
struct ExplainRequestTests {
    @Test func postgresql() throws {
        let plan = try request(.postgresql, "SELECT * FROM orders WHERE id = 1;")
        #expect(plan.sql == "EXPLAIN (FORMAT JSON) SELECT * FROM orders WHERE id = 1")
        #expect(plan.format == .postgresJSON)
        #expect(!plan.rollsBack)
        #expect(!plan.executesStatement)
        let analyze = try request(.postgresql, "UPDATE orders SET notes = 'x' WHERE id = 1", .analyze)
        #expect(analyze.sql == "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) UPDATE orders SET notes = 'x' WHERE id = 1")
        #expect(analyze.rollsBack)
        #expect(analyze.statementWrites)
        #expect(analyze.isWrite)
    }

    @Test func mysql() throws {
        let plan = try request(.mysql, "SELECT 1", version: "8.4.9")
        #expect(plan.sql == "EXPLAIN FORMAT=JSON SELECT 1")
        #expect(plan.format == .mysqlJSON)
        let analyze = try request(.mysql, "SELECT * FROM t", .analyze, version: "8.0.18")
        #expect(analyze.sql == "EXPLAIN ANALYZE SELECT * FROM t")
        #expect(analyze.format == .mysqlTree)
        #expect(!analyze.rollsBack)
        #expect(failure(.mysql, "SELECT 1", .analyze, version: "8.0.17-log") == .unsupported("Explain Analyze needs MySQL 8.0.18 or later."))
        #expect(failure(.mysql, "SELECT 1", .analyze, version: "5.7.44") != nil)
        #expect(ExplainRequest.availability(kind: .mysql, serverVersion: "8.0.36").analyze)
        #expect(!ExplainRequest.availability(kind: .mysql, serverVersion: "8.0.9").analyze)
    }

    @Test func mariadbByKindOrByServerVersion() throws {
        for (kind, version) in [(DatabaseKind.mariadb, "11.4.2"), (.mysql, "10.11.6-MariaDB-log")] {
            let plan = try request(kind, "SELECT 1", version: version)
            #expect(plan.sql == "EXPLAIN FORMAT=JSON SELECT 1")
            let analyze = try request(kind, "SELECT 1", .analyze, version: version)
            #expect(analyze.sql == "ANALYZE FORMAT=JSON SELECT 1")
            #expect(analyze.format == .mysqlJSON)
        }
    }

    @Test func sqliteDuckDBMongoAndRedis() throws {
        #expect(try request(.sqlite, "SELECT * FROM t").sql == "EXPLAIN QUERY PLAN SELECT * FROM t")
        #expect(failure(.sqlite, "SELECT 1", .analyze) == .unsupported("SQLite has no Explain Analyze."))
        #expect(try request(.duckdb, "SELECT 1").sql == "EXPLAIN (FORMAT JSON) SELECT 1")
        #expect(try request(.duckdb, "SELECT 1", .analyze).sql == "EXPLAIN (ANALYZE, FORMAT JSON) SELECT 1")
        #expect(try request(.mongodb, #"db.orders.find({ status: "paid" }).sort({ _id: -1 });"#).sql
            == #"EJSON.stringify((db.orders.find({ status: "paid" }).sort({ _id: -1 })).explain("queryPlanner"))"#)
        #expect(try request(.mongodb, "db.getCollection('orders').aggregate([{ $match: {} }])", .analyze).sql
            == #"EJSON.stringify((db.getCollection('orders').aggregate([{ $match: {} }])).explain("executionStats"))"#)
        #expect(failure(.mongodb, "db.orders.insertOne({ a: 1 })") != nil)
        #expect(failure(.redis, "GET x") == .unsupported("Redis has no query plans to explain."))
        #expect(ExplainRequest.availability(kind: .redis, serverVersion: "8.0") == ExplainAvailability(plan: false, analyze: false, analyzeNote: "Redis has no query plans."))
    }

    @Test func explainsOneStatementOnly() throws {
        // A COMMIT after an analyzed write would run outside the rolled-back transaction.
        let first = try request(.postgresql, "UPDATE t SET a = 1; COMMIT;", .analyze)
        #expect(first.statement == "UPDATE t SET a = 1")
        #expect(first.sql == "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) UPDATE t SET a = 1")
        #expect(try request(.postgresql, "-- recent orders\nSELECT 1").statement == "-- recent orders\nSELECT 1")
        #expect(try request(.mysql, "SELECT ';' AS x;; SELECT 2", version: "8.4.9").statement == "SELECT ';' AS x")
    }

    @Test func refusesNothingAndExplainsOfExplains() {
        #expect(failure(.postgresql, "  ;  ") != nil)
        #expect(failure(.postgresql, "-- only a comment") != nil)
        #expect(failure(.postgresql, "EXPLAIN SELECT 1") == .unsupported("This statement is already an EXPLAIN. Run it with ⌘↩ to see its output."))
        #expect(failure(.mariadb, "ANALYZE SELECT 1") != nil)
    }
}

@Suite("Explain and Safe Mode")
struct ExplainSafeModeTests {
    @Test func explainWithoutAnalyzeIsARead() {
        #expect(SQLStatementSplitter.looksReadOnly("EXPLAIN UPDATE t SET a = 1"))
        #expect(SQLStatementSplitter.looksReadOnly("EXPLAIN (FORMAT JSON) DELETE FROM t"))
        #expect(SQLStatementSplitter.looksReadOnly("EXPLAIN FORMAT=JSON INSERT INTO t VALUES (1)"))
        #expect(!SQLStatementSplitter.looksReadOnly("EXPLAIN ANALYZE DELETE FROM t"))
        #expect(!SQLStatementSplitter.looksReadOnly("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) UPDATE t SET a = 1"))
        #expect(!SQLStatementSplitter.looksReadOnly("explain analyse insert into t values (1)"))
        #expect(SQLStatementSplitter.looksReadOnly("EXPLAIN ANALYZE SELECT * FROM t"))
        #expect(!SQLStatementSplitter.looksReadOnly("ANALYZE FORMAT=JSON UPDATE t SET a = 1"))
    }

    @Test func onlyAnAnalyzedWriteIsGatedAsAWrite() throws {
        let planOfWrite = try request(.postgresql, "DELETE FROM orders")
        let analyzedRead = try request(.postgresql, "SELECT * FROM orders", .analyze)
        let analyzedWrite = try request(.postgresql, "DELETE FROM orders", .analyze)
        #expect(!planOfWrite.isWrite)
        #expect(!analyzedRead.isWrite)
        #expect(analyzedWrite.isWrite)
        #expect(planOfWrite.safeModeDetail == nil)
        #expect(analyzedWrite.safeModeDetail?.contains("rolls it back") == true)

        // Silent never asks; Alert asks only for the analyzed write; the Full levels ask for every statement.
        #expect(!SafeModeLevel.silent.gates(writes: analyzedWrite.isWrite))
        #expect(SafeModeLevel.alert.gates(writes: analyzedWrite.isWrite))
        #expect(!SafeModeLevel.alert.gates(writes: planOfWrite.isWrite))
        #expect(!SafeModeLevel.alert.gates(writes: analyzedRead.isWrite))
        #expect(SafeModeLevel.safeMode.gates(writes: analyzedWrite.isWrite))
        #expect(SafeModeLevel.alertFull.gates(writes: planOfWrite.isWrite))
    }

    @Test func readOnlyConnectionsExplainAnythingButAnalyzeOnlyReads() throws {
        #expect(try request(.postgresql, "UPDATE t SET a = 1", readOnly: true).sql.hasPrefix("EXPLAIN (FORMAT JSON) UPDATE"))
        // MySQL itself refuses to plan a write in a read-only session.
        #expect(failure(.mysql, "DELETE FROM t", version: "8.4.9", readOnly: true) != nil)
        #expect(try request(.mysql, "SELECT * FROM t", version: "8.4.9", readOnly: true).sql == "EXPLAIN FORMAT=JSON SELECT * FROM t")
        #expect(try request(.postgresql, "SELECT 1", .analyze, readOnly: true).executesStatement)
        let refusal = failure(.postgresql, "UPDATE t SET a = 1", .analyze, readOnly: true)
        guard case .refused(let message)? = refusal else {
            Issue.record("expected a refusal, got \(String(describing: refusal))")
            return
        }
        #expect(message.hasPrefix("This connection is read-only."))
    }

    @Test func enginesThatCannotUndoRefuseAnalyzedWrites() throws {
        for kind in [DatabaseKind.mysql, .mariadb, .duckdb] {
            let refusal = failure(kind, "UPDATE t SET a = 1", .analyze, version: "8.4.9")
            guard case .refused(let message)? = refusal else {
                Issue.record("\(kind) should refuse, got \(String(describing: refusal))")
                continue
            }
            #expect(message.contains("only runs it for statements that read data"))
        }
        #expect(failure(.mongodb, "db.orders.aggregate([{ $out: \"copy\" }])", .analyze) != nil)
        #expect(try request(.mysql, "UPDATE t SET a = 1", version: "8.4.9").sql == "EXPLAIN FORMAT=JSON UPDATE t SET a = 1")
        #expect(try request(.mysql, "SELECT * FROM t", .analyze, version: "8.4.9").sql == "EXPLAIN ANALYZE SELECT * FROM t")
    }
}

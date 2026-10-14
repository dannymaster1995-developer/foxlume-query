import Foundation
import Testing
@testable import FoxlumeQueryCore

/// Scratch tables for the live Explain tests. Every test creates and drops its own `fq_explain_` tables.
private func scratchName(_ label: String) -> String {
    "fq_explain_\(label)_" + UUID().uuidString.prefix(8).lowercased()
}

private func scalar(_ connection: DatabaseConnection, _ sql: String) throws -> String? {
    try connection.execute(sql, rowLimit: nil).last { $0.hasResultSet }?.rows.first?.first?.textValue
}

private func explain(_ connection: DatabaseConnection, _ kind: DatabaseKind, _ statement: String, _ mode: ExplainMode = .plan, readOnly: Bool = false) throws -> ExplainOutcome {
    let request = try ExplainRequest.make(kind: kind, serverVersion: connection.serverVersion, statement: statement, mode: mode, readOnly: readOnly)
    return try ExplainRunner.run(request, on: connection)
}

@Suite("Explain on PostgreSQL", .serialized, .enabled(if: PostgresTestServer.isAvailable, "needs the PostgreSQL test server"))
struct PostgresExplainLiveTests {
    /// Items with an index on their group, and the groups they belong to.
    private func makeTables(_ connection: PostgresConnection) throws -> (items: String, groups: String) {
        let items = scratchName("items")
        let groups = scratchName("groups")
        _ = try connection.execute("""
            CREATE TABLE \(groups) (id integer PRIMARY KEY, name text NOT NULL);
            INSERT INTO \(groups) SELECT g, 'g' || g FROM generate_series(1, 50) g;
            CREATE TABLE \(items) (id integer PRIMARY KEY, grp integer NOT NULL REFERENCES \(groups)(id), note text);
            INSERT INTO \(items) SELECT i, 1 + i % 50, 'n' || i FROM generate_series(1, 20000) i;
            CREATE INDEX \(items)_grp_idx ON \(items) (grp);
            ANALYZE \(groups);
            ANALYZE \(items);
            """, rowLimit: nil)
        return (items, groups)
    }

    private func drop(_ connection: PostgresConnection, _ tables: (items: String, groups: String)) {
        _ = try? connection.execute("DROP TABLE IF EXISTS \(tables.items), \(tables.groups)", rowLimit: nil)
    }

    @Test func plansAJoinAndAnIndexLookup() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let tables = try makeTables(connection)
        defer { drop(connection, tables) }

        let join = try explain(connection, .postgresql, "SELECT i.id, g.name FROM \(tables.items) i JOIN \(tables.groups) g ON g.id = i.grp WHERE g.name = 'g7'")
        let plan = try #require(join.plan)
        #expect(!plan.isAnalyzed)
        #expect(plan.allNodes.contains { ["Hash Join", "Nested Loop", "Merge Join"].contains($0.operation) })
        #expect(Set(plan.allNodes.compactMap(\.relation)) == [tables.items, tables.groups])
        #expect(plan.allNodes.contains { $0.joinCondition != nil || $0.indexCondition != nil })
        #expect(plan.root.estimatedTotalCost != nil)
        #expect(!join.rolledBack)

        let lookup = try #require(try explain(connection, .postgresql, "SELECT * FROM \(tables.items) WHERE id = 42;").plan)
        let scan = try #require(lookup.allNodes.first { $0.relation == tables.items })
        #expect(scan.operation.hasPrefix("Index"))
        #expect(scan.index == "\(tables.items)_pkey")
        #expect(scan.indexCondition == "(id = 42)")
        #expect(scan.access == .indexLookup)
    }

    @Test func analyzeMeasuresAndRollsBackAWrite() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let tables = try makeTables(connection)
        defer { drop(connection, tables) }
        let before = try scalar(connection, "SELECT count(*) FILTER (WHERE note = 'changed') || '/' || count(*) FROM \(tables.items)")
        #expect(before == "0/20000")

        let outcome = try explain(connection, .postgresql, "UPDATE \(tables.items) SET note = 'changed' WHERE grp = 3", .analyze)
        #expect(outcome.rolledBack)
        let plan = try #require(outcome.plan)
        #expect(plan.isAnalyzed)
        #expect(plan.executionTime != nil && plan.planningTime != nil)
        #expect(plan.root.operation == "Update")
        #expect(plan.allNodes.contains { $0.actualRows == 400 })
        #expect(plan.allNodes.contains { $0.buffers.map { !$0.isEmpty } == true })

        // Nothing the UPDATE did is left, and the session is out of the transaction again.
        #expect(try scalar(connection, "SELECT count(*) FILTER (WHERE note = 'changed') || '/' || count(*) FROM \(tables.items)") == "0/20000")
        #expect(connection.transactionStatus == "I")

        // A DELETE of every row, analyzed: the rows are all still there.
        _ = try explain(connection, .postgresql, "DELETE FROM \(tables.items)", .analyze)
        #expect(try scalar(connection, "SELECT count(*) FROM \(tables.items)") == "20000")
    }

    @Test func analyzeInsideTheUsersTransactionUndoesOnlyItsOwnWork() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let tables = try makeTables(connection)
        defer { drop(connection, tables) }

        _ = try connection.execute("BEGIN; INSERT INTO \(tables.items) VALUES (99999, 1, 'mine')", rowLimit: nil)
        #expect(connection.transactionStatus == "T")
        let outcome = try explain(connection, .postgresql, "DELETE FROM \(tables.items) WHERE grp = 1", .analyze)
        #expect(outcome.rolledBack)
        // Still inside the user's transaction, with their insert and without the analyzed delete.
        #expect(connection.transactionStatus == "T")
        #expect(try scalar(connection, "SELECT count(*) FROM \(tables.items) WHERE grp = 1") == "401")
        _ = try connection.execute("ROLLBACK", rowLimit: nil)
        #expect(try scalar(connection, "SELECT count(*) FROM \(tables.items)") == "20000")

        // A failed transaction must be rolled back by its owner first.
        _ = try connection.execute("BEGIN", rowLimit: nil)
        _ = try? connection.execute("SELECT 1 / 0", rowLimit: nil)
        #expect(connection.transactionStatus == "E")
        #expect(throws: ExplainError.self) { try explain(connection, .postgresql, "SELECT 1", .analyze) }
        _ = try connection.execute("ROLLBACK", rowLimit: nil)
    }

    @Test func aFailingAnalyzeStillRollsBack() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let tables = try makeTables(connection)
        defer { drop(connection, tables) }
        // The UPDATE fails half way on the foreign key; nothing stays and the session is usable.
        #expect(throws: DatabaseError.self) { try explain(connection, .postgresql, "UPDATE \(tables.items) SET grp = grp + 100 WHERE id > 19990", .analyze) }
        #expect(connection.transactionStatus == "I")
        #expect(try scalar(connection, "SELECT max(grp) FROM \(tables.items)") == "50")
    }

    @Test func readOnlySessionsExplainWritesWithoutRunningThem() async throws {
        let config = ConnectionConfig(kind: .postgresql, host: PostgresTestServer.host, port: PostgresTestServer.port, user: "postgres", database: "foxlume", readOnly: true)
        let session = DatabaseSession(parameters: ConnectionParameters(config: config, password: "postgres"))
        try await session.connect()
        _ = try await session.execute("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY")
        defer { Task { await session.close() } }

        let request = try ExplainRequest.make(kind: .postgresql, serverVersion: session.serverVersion, statement: "DELETE FROM orders WHERE id = 1", mode: .plan, readOnly: true)
        let outcome = try await session.explain(request, token: QueryToken())
        #expect(outcome.plan?.root.operation == "Delete")
        #expect(throws: ExplainError.self) {
            try ExplainRequest.make(kind: .postgresql, serverVersion: session.serverVersion, statement: "DELETE FROM orders WHERE id = 1", mode: .analyze, readOnly: true)
        }
        let read = try ExplainRequest.make(kind: .postgresql, serverVersion: session.serverVersion, statement: "SELECT count(*) FROM orders", mode: .analyze, readOnly: true)
        let measured = try await session.explain(read)
        #expect(measured.plan?.isAnalyzed == true)
    }
}

@Suite("Explain on MySQL", .serialized, .enabled(if: MySQLTestServer.isAvailable, "needs the MySQL test server"))
struct MySQLExplainLiveTests {
    private func makeTables(_ connection: MySQLConnection) throws -> (items: String, groups: String) {
        let items = scratchName("items")
        let groups = scratchName("groups")
        _ = try connection.execute("CREATE TABLE \(groups) (id INT PRIMARY KEY, name VARCHAR(20) NOT NULL) ENGINE=InnoDB", rowLimit: nil)
        _ = try connection.execute("CREATE TABLE \(items) (id INT PRIMARY KEY, grp INT NOT NULL, note VARCHAR(20), KEY \(items)_grp_idx (grp)) ENGINE=InnoDB", rowLimit: nil)
        _ = try connection.execute("INSERT INTO \(groups) WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 50) SELECT n, CONCAT('g', n) FROM s", rowLimit: nil)
        _ = try connection.execute("SET SESSION cte_max_recursion_depth = 5000; INSERT INTO \(items) WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 2000) SELECT n, 1 + n % 50, CONCAT('n', n) FROM s; ANALYZE TABLE \(groups), \(items)", rowLimit: nil)
        return (items, groups)
    }

    private func drop(_ connection: MySQLConnection, _ tables: (items: String, groups: String)) {
        _ = try? connection.execute("DROP TABLE IF EXISTS \(tables.items), \(tables.groups)", rowLimit: nil)
    }

    @Test func plansAJoinAndAnIndexLookup() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        let tables = try makeTables(connection)
        defer { drop(connection, tables) }

        let join = try #require(try explain(connection, .mysql, "SELECT i.id, g.name FROM \(tables.items) i JOIN \(tables.groups) g ON g.id = i.grp WHERE g.name = 'g7'").plan)
        #expect(join.format == .mysqlJSON)
        #expect(join.root.operation == "Query Block")
        #expect(join.allNodes.contains { $0.operation == "Nested Loop" })
        #expect(Set(join.allNodes.compactMap(\.relation)) == ["i", "g"])
        #expect(join.root.estimatedTotalCost != nil)

        let lookup = try #require(try explain(connection, .mysql, "SELECT * FROM \(tables.items) WHERE grp = 7").plan)
        let table = try #require(lookup.allNodes.first { $0.relation == tables.items })
        #expect(table.index == "\(tables.items)_grp_idx")
        #expect(table.access == .indexLookup)
        #expect(table.property("Ref") == "const")
    }

    @Test func analyzeMeasuresReadsAndRefusesWrites() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        let tables = try makeTables(connection)
        defer { drop(connection, tables) }

        let outcome = try explain(connection, .mysql, "SELECT g.name, count(*) FROM \(tables.items) i JOIN \(tables.groups) g ON g.id = i.grp GROUP BY g.name", .analyze)
        #expect(!outcome.rolledBack)
        let plan = try #require(outcome.plan)
        #expect(plan.format == .mysqlTree)
        #expect(plan.isAnalyzed)
        #expect(plan.executionTime != nil)
        #expect(plan.allNodes.contains { $0.relation == "i" || $0.relation == "g" })
        #expect(plan.allNodes.contains { $0.actualRows == 2000 })

        #expect(throws: ExplainError.self) { try explain(connection, .mysql, "UPDATE \(tables.items) SET note = 'changed'", .analyze) }
        #expect(try scalar(connection, "SELECT count(*) FROM \(tables.items) WHERE note = 'changed'") == "0")
        // Explain without ANALYZE plans the write and leaves the rows alone.
        let update = try #require(try explain(connection, .mysql, "UPDATE \(tables.items) SET note = 'changed' WHERE id = 5").plan)
        #expect(update.allNodes.contains { $0.operation == "Update" })
        #expect(try scalar(connection, "SELECT note FROM \(tables.items) WHERE id = 5") == "n5")
    }

    /// MySQL will not even plan a write inside a read-only transaction; reads explain and analyze as usual.
    @Test func readOnlySessionsExplainReads() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        _ = try connection.execute("SET SESSION TRANSACTION READ ONLY", rowLimit: nil)
        #expect(throws: DatabaseError.self) { try connection.execute("EXPLAIN FORMAT=JSON DELETE FROM orders WHERE id = 1", rowLimit: nil) }
        #expect(throws: ExplainError.self) { try explain(connection, .mysql, "DELETE FROM orders WHERE id = 1", readOnly: true) }
        #expect(throws: ExplainError.self) { try explain(connection, .mysql, "DELETE FROM orders WHERE id = 1", .analyze, readOnly: true) }
        #expect(try explain(connection, .mysql, "SELECT * FROM orders WHERE id = 1", readOnly: true).plan != nil)
        #expect(try explain(connection, .mysql, "SELECT * FROM orders WHERE id = 1", .analyze, readOnly: true).plan?.isAnalyzed == true)
    }
}

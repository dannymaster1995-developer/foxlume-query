import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct TableOperationTests {
    let orders = TableRef(schema: "public", name: "orders")

    @Test func postgresTruncateAndDropHonourCascade() {
        let sql = TableOperationSQL(kind: .postgresql)
        #expect(sql.truncateStatements(orders) == [#"TRUNCATE TABLE "public"."orders""#])
        #expect(sql.truncateStatements(orders, options: TableOperationOptions(cascade: true)) == [#"TRUNCATE TABLE "public"."orders" CASCADE"#])
        #expect(sql.dropStatement(orders, objectKind: .materializedView, options: TableOperationOptions(cascade: true)) == #"DROP MATERIALIZED VIEW "public"."orders" CASCADE"#)
        #expect(sql.renameStatement(orders, objectKind: .view, to: "orders_v2") == #"ALTER VIEW "public"."orders" RENAME TO "orders_v2""#)
    }

    @Test func mysqlIgnoresCascadeAndRenamesWithRenameTable() {
        let sql = TableOperationSQL(kind: .mysql)
        let table = TableRef(name: "order`s")
        #expect(sql.truncateStatements(table, options: TableOperationOptions(cascade: true)) == ["TRUNCATE TABLE `order``s`"])
        #expect(sql.dropStatement(table, objectKind: .view) == "DROP VIEW `order``s`")
        #expect(sql.renameStatement(table, objectKind: .table, to: "archive") == "RENAME TABLE `order``s` TO `archive`")
        #expect(!sql.supportsCascade(.drop))
        #expect(sql.supportsForeignKeyToggle)
    }

    @Test func sqliteTruncatesWithDeleteAndCannotRenameViews() {
        let sql = TableOperationSQL(kind: .sqlite)
        #expect(sql.truncateStatements(TableRef(name: "t")) == [#"DELETE FROM "t""#])
        #expect(sql.renameStatement(TableRef(name: "v"), objectKind: .view, to: "w") == nil)
        #expect(!sql.canTruncate(.view))
        #expect(!sql.canDrop(.systemTable))
    }

    @Test func duckdbCascadesOnlyOnDrop() {
        let sql = TableOperationSQL(kind: .duckdb)
        let table = TableRef(schema: "main", name: "t")
        #expect(sql.truncateStatements(table, options: TableOperationOptions(cascade: true)) == [#"TRUNCATE "main"."t""#])
        #expect(sql.dropStatement(table, objectKind: .table, options: TableOperationOptions(cascade: true)) == #"DROP TABLE "main"."t" CASCADE"#)
        #expect(!sql.supportsForeignKeyToggle)
    }

    @Test func mongoUsesShellCallsWithEscapedNames() {
        let sql = TableOperationSQL(kind: .mongodb)
        let table = TableRef(name: "a\"b\nc")
        #expect(sql.truncateStatements(table) == [#"db.getCollection("a\"b\nc").deleteMany({})"#])
        #expect(sql.dropStatement(table, objectKind: .view) == #"db.getCollection("a\"b\nc").drop()"#)
        #expect(sql.renameStatement(TableRef(name: "orders"), objectKind: .table, to: "orders_old") == #"db.getCollection("orders").renameCollection("orders_old")"#)
        #expect(sql.renameStatement(TableRef(name: "order_summary"), objectKind: .view, to: "x") == nil)
    }

    @Test func planOrdersTruncatesBeforeDropsAndWrapsForeignKeyToggle() {
        let sql = TableOperationSQL(kind: .mysql)
        let plan = sql.plan([
            PendingTableOperation(table: TableRef(name: "b"), objectKind: .table, operation: .drop),
            PendingTableOperation(table: TableRef(name: "z"), objectKind: .table, operation: .truncate, options: TableOperationOptions(ignoreForeignKeys: true)),
            PendingTableOperation(table: TableRef(name: "a"), objectKind: .table, operation: .truncate),
        ])
        #expect(plan.setup == ["SET FOREIGN_KEY_CHECKS = 0"])
        #expect(plan.statements == ["TRUNCATE TABLE `a`", "TRUNCATE TABLE `z`", "DROP TABLE `b`"])
        #expect(plan.restore == ["SET FOREIGN_KEY_CHECKS = 1"])
        #expect(sql.plan([PendingTableOperation(table: TableRef(name: "a"), objectKind: .table, operation: .drop)]).setup.isEmpty)
    }

    @Test func sqlitePlanRunsAndRestoresForeignKeysAfterFailure() async throws {
        let url = TestFiles.url("table-ops-\(UUID().uuidString).sqlite")
        defer { TestFiles.removeDatabase(url) }
        let session = DatabaseSession(parameters: ConnectionParameters(config: ConnectionConfig(kind: .sqlite, filePath: url.path), password: ""))
        try await session.connect()
        defer { Task { await session.close() } }
        _ = try await session.execute("""
            PRAGMA foreign_keys = ON;
            CREATE TABLE parent (id INTEGER PRIMARY KEY);
            CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id));
            CREATE VIEW child_ids AS SELECT id FROM child;
            INSERT INTO parent VALUES (1), (2);
            INSERT INTO child VALUES (10, 1);
            """)
        let sql = TableOperationSQL(kind: .sqlite)

        // Emptying the parent breaks the reference, so it needs the foreign key toggle.
        let blocked = sql.plan([PendingTableOperation(table: TableRef(name: "parent"), objectKind: .table, operation: .truncate)])
        await #expect(throws: (any Error).self) { try await session.run(blocked) }

        let plan = sql.plan([
            PendingTableOperation(table: TableRef(name: "parent"), objectKind: .table, operation: .truncate, options: TableOperationOptions(ignoreForeignKeys: true)),
            PendingTableOperation(table: TableRef(name: "child_ids"), objectKind: .view, operation: .drop),
        ])
        try await session.run(plan)
        let counts = try await session.execute("SELECT (SELECT COUNT(*) FROM parent), (SELECT COUNT(*) FROM sqlite_master WHERE name = 'child_ids'); PRAGMA foreign_keys")
        #expect(counts[0].rows.first?.map(\.displayString) == ["0", "0"])
        #expect(counts[1].rows.first?.first?.displayString == "1")

        // A failing statement still switches the checks back on.
        let failing = TableOperationPlan(setup: sql.foreignKeyDisableStatements, statements: ["DROP TABLE missing_table"], restore: sql.foreignKeyEnableStatements)
        await #expect(throws: (any Error).self) { try await session.run(failing) }
        let after = try await session.execute("PRAGMA foreign_keys")
        #expect(after[0].rows.first?.first?.displayString == "1")

        let rename = try #require(sql.renameStatement(TableRef(name: "child"), objectKind: .table, to: "kids"))
        _ = try await session.execute(rename)
        let tables = try await session.run { try $0.tables(schema: nil) }.map(\.name)
        #expect(tables.contains("kids") && !tables.contains("child"))
    }
}

@Suite struct DatabaseObjectTests {
    @Test func statementsPerEngine() {
        let postgres = DatabaseObjectSQL(kind: .postgresql)
        #expect(postgres.createDatabase("Sales 2026") == #"CREATE DATABASE "Sales 2026""#)
        #expect(postgres.dropSchema("audit", cascade: true) == #"DROP SCHEMA "audit" CASCADE"#)
        let mysql = DatabaseObjectSQL(kind: .mysql)
        #expect(mysql.createDatabase("shop`x") == "CREATE DATABASE `shop``x` CHARACTER SET utf8mb4")
        #expect(mysql.createSchema("x") == nil)
        #expect(DatabaseObjectSQL(kind: .sqlite).createDatabase("x") == nil)
        #expect(DatabaseObjectSQL(kind: .mariadb).dropDatabase("old") == "DROP DATABASE `old`")
    }
}

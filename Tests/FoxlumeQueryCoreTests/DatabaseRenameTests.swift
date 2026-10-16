import CoreGraphics
import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct DatabaseRenameSQLTests {
    @Test func renameAndCopyStatementsArePostgresOnly() {
        let postgres = DatabaseObjectSQL(kind: .postgresql)
        #expect(postgres.renameSchema("sales", to: "Sales 2026") == #"ALTER SCHEMA "sales" RENAME TO "Sales 2026""#)
        #expect(postgres.renameDatabase("shop", to: "shop_old") == #"ALTER DATABASE "shop" RENAME TO "shop_old""#)
        #expect(postgres.copyDatabase("shop", to: "shop_copy") == #"CREATE DATABASE "shop_copy" TEMPLATE "shop""#)
        #expect(postgres.copyDatabase("shop", to: "shop_copy", owner: "app\"owner") == #"CREATE DATABASE "shop_copy" TEMPLATE "shop" OWNER "app""owner""#)
        #expect(postgres.copyDatabase("shop", to: "shop_copy", owner: "") == #"CREATE DATABASE "shop_copy" TEMPLATE "shop""#)
        // Same name or no name: nothing to run.
        #expect(postgres.renameSchema("sales", to: "sales") == nil)
        #expect(postgres.renameDatabase("shop", to: "") == nil)
        #expect(postgres.copyDatabase("shop", to: "shop") == nil)

        for kind in [DatabaseKind.mysql, .mariadb, .sqlite, .duckdb, .mongodb, .redis] {
            let sql = DatabaseObjectSQL(kind: kind)
            #expect(!sql.canRenameSchemas && !sql.canRenameDatabases && !sql.canCopyDatabases, "\(kind)")
            #expect(sql.renameSchema("a", to: "b") == nil)
            #expect(sql.renameDatabase("a", to: "b") == nil)
            #expect(sql.copyDatabase("a", to: "b") == nil)
            #expect(sql.databaseRenameUnavailableReason != nil && sql.databaseCopyUnavailableReason != nil)
        }
        #expect(postgres.databaseRenameUnavailableReason == nil)
        #expect(DatabaseObjectSQL(kind: .mysql).databaseRenameUnavailableReason == "MySQL has no RENAME DATABASE")
        #expect(DatabaseObjectSQL(kind: .mysql).databaseCopyUnavailableReason == "MySQL has no statement that copies a database")
        #expect(postgres.databaseCopyUnavailableReason == nil)
    }

    @Test func systemSchemasAreRefused() {
        for name in ["pg_catalog", "pg_toast", "pg_temp_3", "PG_CATALOG", "information_schema"] {
            #expect(DatabaseObjectSQL.isSystemSchema(name), "\(name)")
            #expect(DatabaseObjectSQL(kind: .postgresql).renameSchema(name, to: "x") == nil)
        }
        for name in ["public", "shop", "pgx", "information"] {
            #expect(!DatabaseObjectSQL.isSystemSchema(name), "\(name)")
        }
    }

    @Test func otherSessionsQueryAndGroups() throws {
        let sql = DatabaseObjectSQL(kind: .postgresql)
        let query = try #require(sql.otherSessionsQuery(on: "it's", excluding: [42, 7]))
        #expect(query.contains("datname = 'it''s'"))
        #expect(query.contains("pid <> pg_backend_pid() AND pid NOT IN (42, 7)"))
        #expect(sql.otherSessionsQuery(on: "x")?.contains("NOT IN") == false)
        #expect(DatabaseObjectSQL(kind: .mysql).otherSessionsQuery(on: "x") == nil)

        let groups = DatabaseObjectSQL.sessionGroups([
            [.text("psql"), .text("alice"), .text("2")],
            [.text("Foxlume Query"), .null, .text("1")],
            [.text("broken"), .text("bob")],
        ])
        #expect(groups == [
            DatabaseSessionGroup(application: "psql", user: "alice", count: 2),
            DatabaseSessionGroup(application: "Foxlume Query", user: "", count: 1),
        ])
        let error = DatabaseChangeError.otherSessions(database: "shop", groups: groups)
        #expect(error.total == 3)
        #expect(error.localizedDescription.hasPrefix("“shop” has 3 other sessions: psql (alice) × 2, Foxlume Query (unknown user)."))
    }

    @Test func maintenanceDatabasePrefersPostgres() {
        #expect(DatabaseObjectSQL.maintenanceDatabase(for: "shop", among: ["shop", "app", "postgres", "template1"]) == "postgres")
        #expect(DatabaseObjectSQL.maintenanceDatabase(for: "postgres", among: ["postgres", "template0", "template1", "app"]) == "app")
        #expect(DatabaseObjectSQL.maintenanceDatabase(for: "shop", target: "app", among: ["shop", "app", "template0", "template1"]) == "template1")
        #expect(DatabaseObjectSQL.maintenanceDatabase(for: "shop", among: ["shop"]) == nil)
    }

    @Test func changeNamesItsStatementAndWhereTheSessionReturns() {
        let sql = DatabaseObjectSQL(kind: .postgresql)
        let rename = DatabaseChange.rename(from: "a", to: "b")
        #expect(rename.statement(sql) == #"ALTER DATABASE "a" RENAME TO "b""#)
        #expect(rename.returnDatabase == "b")
        let copy = DatabaseChange.copy(from: "a", to: "b", owner: "o")
        #expect(copy.statement(sql) == #"CREATE DATABASE "b" TEMPLATE "a" OWNER "o""#)
        #expect(copy.returnDatabase == "a")
        #expect((copy.source, copy.target) == ("a", "b"))
    }
}

@Suite struct StoredStateRenameTests {
    private let connection = UUID()
    private let other = UUID()

    private func url(_ name: String) -> URL {
        TestFiles.url("state-rename-\(name)-\(UUID().uuidString).json")
    }

    @Test func scopesFollowASchemaRenameInItsDatabaseOnly() {
        let rename = StoredStateRename.schema(connectionID: connection, database: "shop", from: "sales", to: "revenue")
        let layout = GridColumnLayoutScope(connectionID: connection, database: "shop", schema: "sales", table: "orders")
        #expect(rename.renamed(layout) == GridColumnLayoutScope(connectionID: connection, database: "shop", schema: "revenue", table: "orders"))
        #expect(rename.renamed(GridColumnLayoutScope(connectionID: connection, database: "other", schema: "sales", table: "orders")) == nil)
        #expect(rename.renamed(GridColumnLayoutScope(connectionID: other, database: "shop", schema: "sales", table: "orders")) == nil)
        #expect(rename.renamed(ERDiagramScope(connectionID: connection, database: "shop", schema: "sales")) == ERDiagramScope(connectionID: connection, database: "shop", schema: "revenue"))
        #expect(rename.renamed(FilterPresetScope(connectionID: connection, database: "shop", schema: "public", table: "orders")) == nil)
        #expect(rename.renamed(TableRef(schema: "sales", name: "orders")) == TableRef(schema: "revenue", name: "orders"))
        #expect(rename.renamed(TableRef(schema: "public", name: "orders")) == nil)
    }

    @Test func scopesFollowADatabaseRename() {
        let rename = StoredStateRename.database(connectionID: connection, from: "shop", to: "store")
        #expect(rename.renamed(FilterPresetScope(connectionID: connection, database: "shop", schema: "public", table: "t"))
            == FilterPresetScope(connectionID: connection, database: "store", schema: "public", table: "t"))
        #expect(rename.renamed(ERDiagramScope(connectionID: connection, database: "shopping", schema: "public")) == nil)
        // Table refs carry no database.
        #expect(rename.renamed(TableRef(schema: "public", name: "t")) == nil)
    }

    @Test func quickOpenKeys() {
        let schema = StoredStateRename.schema(connectionID: connection, database: "shop", from: "sales", to: "revenue")
        #expect(schema.renamedQuickOpenKey("table:sales.orders") == "table:revenue.orders")
        #expect(schema.renamedQuickOpenKey("table:salesx.orders") == nil)
        #expect(schema.renamedQuickOpenKey("schema:sales") == "schema:revenue")
        #expect(schema.renamedQuickOpenKey("database:sales") == nil)
        let object = SchemaObject(kind: .function, schema: "sales", name: "total", identityArguments: "integer")
        let moved = SchemaObject(kind: .function, schema: "revenue", name: "total", identityArguments: "integer")
        #expect(schema.renamedQuickOpenKey(QuickOpenItem.objectKey(object)) == QuickOpenItem.objectKey(moved))
        #expect(schema.renamedQuickOpenKey(QuickOpenItem.objectKey(moved)) == nil)

        let database = StoredStateRename.database(connectionID: connection, from: "shop", to: "store")
        #expect(database.renamedQuickOpenKey("database:shop") == "database:store")
        #expect(database.renamedQuickOpenKey("table:shop.orders") == nil)
    }

    @Test func storesMoveTheirEntries() throws {
        let rename = StoredStateRename.schema(connectionID: connection, database: "shop", from: "sales", to: "revenue")
        let layoutURL = url("layouts"), diagramURL = url("diagrams"), presetURL = url("presets")
        defer { for file in [layoutURL, diagramURL, presetURL] { try? FileManager.default.removeItem(at: file) } }

        let layouts = GridColumnLayoutStore(url: layoutURL)
        let old = GridColumnLayoutScope(connectionID: connection, database: "shop", schema: "sales", table: "orders")
        let new = GridColumnLayoutScope(connectionID: connection, database: "shop", schema: "revenue", table: "orders")
        let untouched = GridColumnLayoutScope(connectionID: other, database: "shop", schema: "sales", table: "orders")
        try layouts.setLayout(GridColumnLayout(columns: [.init(name: "id", width: 80)]), for: old)
        // Left behind by an earlier schema of the new name: replaced.
        try layouts.setLayout(GridColumnLayout(columns: [.init(name: "stale")]), for: new)
        try layouts.setLayout(GridColumnLayout(columns: [.init(name: "other")]), for: untouched)
        try layouts.apply(rename)
        #expect(layouts.layout(for: old) == nil)
        #expect(layouts.layout(for: new)?.columns.map(\.name) == ["id"])
        #expect(layouts.layout(for: untouched)?.columns.map(\.name) == ["other"])
        // Read back from the file.
        #expect(GridColumnLayoutStore(url: layoutURL).layout(for: new)?.columns.first?.width == 80)

        let diagrams = ERDiagramLayoutStore(url: diagramURL)
        try diagrams.setPositions(["orders": CGPoint(x: 10, y: 20)], for: ERDiagramScope(connectionID: connection, database: "shop", schema: "sales"))
        try diagrams.apply(rename)
        #expect(ERDiagramLayoutStore(url: diagramURL).positions(for: ERDiagramScope(connectionID: connection, database: "shop", schema: "revenue"))["orders"] == CGPoint(x: 10, y: 20))
        #expect(diagrams.positions(for: ERDiagramScope(connectionID: connection, database: "shop", schema: "sales")).isEmpty)

        let presets = FilterPresetStore(url: presetURL)
        let presetScope = FilterPresetScope(connectionID: connection, database: "shop", schema: "sales", table: "orders")
        try presets.save(name: "Open", rules: [FilterRule(column: "status", value: "open")], logic: .and, rawWhere: "", for: presetScope)
        try presets.apply(rename)
        #expect(presets.presets(for: presetScope).isEmpty)
        #expect(FilterPresetStore(url: presetURL).presets(for: FilterPresetScope(connectionID: connection, database: "shop", schema: "revenue", table: "orders")).map(\.name) == ["Open"])
    }

    @Test func frecencyMovesAndMergesVisits() {
        let file = url("frecency")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = QuickOpenFrecencyStore(url: file)
        let start = Date(timeIntervalSince1970: 1_000_000)
        store.record("table:sales.orders", connection: connection, at: start)
        store.record("table:sales.orders", connection: connection, at: start.addingTimeInterval(100))
        store.record("table:revenue.orders", connection: connection, at: start.addingTimeInterval(200))
        store.record("table:sales.orders", connection: other, at: start)
        store.apply(.schema(connectionID: connection, database: nil, from: "sales", to: "revenue"))
        let scores = store.scores(for: connection, now: start.addingTimeInterval(300))
        #expect(scores["table:sales.orders"] == nil)
        #expect(abs((scores["table:revenue.orders"] ?? 0) - 0.6) < 0.01, "three visits merged under the new key")
        #expect(store.scores(for: other)["table:sales.orders"] != nil)
        #expect(QuickOpenFrecencyStore(url: file).recentKeys(for: connection) == ["table:revenue.orders"])
    }
}

/// Live checks against the PostgreSQL test server, on scratch schemas and databases named fq110_*.
@Suite("Rename and copy live", .serialized, .enabled(if: PostgresTestServer.isAvailable, "needs the PostgreSQL test server"))
struct DatabaseRenameLiveTests {
    private func session(_ database: String) async throws -> DatabaseSession {
        let config = ConnectionConfig(kind: .postgresql, host: PostgresTestServer.host, port: PostgresTestServer.port, user: "postgres", database: database, sslMode: .prefer)
        let session = DatabaseSession(parameters: ConnectionParameters(config: config, password: "postgres"))
        try await session.connect()
        return session
    }

    private func dropDatabases(_ names: [String], on admin: DatabaseSession) async {
        for name in names {
            _ = try? await admin.run { try $0.execute("DROP DATABASE IF EXISTS \(SQLDialect.postgresql.quoteIdentifier(name))", rowLimit: nil) }
        }
    }

    @Test func renameSchemaKeepsItsTablesAndMovesTheLayout() async throws {
        let session = try await session("foxlume")
        let sql = DatabaseObjectSQL(kind: .postgresql)
        for name in ["fq110_schema", "fq110_schema_renamed"] {
            _ = try await session.run { try $0.execute("DROP SCHEMA IF EXISTS \(name) CASCADE", rowLimit: nil) }
        }
        _ = try await session.run { try $0.execute("CREATE SCHEMA fq110_schema; CREATE TABLE fq110_schema.items (id int PRIMARY KEY, label text)", rowLimit: nil) }
        let file = TestFiles.url("fq110-layouts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let connection = UUID()
        let layouts = GridColumnLayoutStore(url: file)
        let old = GridColumnLayoutScope(connectionID: connection, database: "foxlume", schema: "fq110_schema", table: "items")
        try layouts.setLayout(GridColumnLayout(columns: [.init(name: "label", width: 140), .init(name: "id", isHidden: true)]), for: old)

        _ = try await session.run { try $0.execute(try #require(sql.renameSchema("fq110_schema", to: "fq110_schema_renamed")), rowLimit: nil) }
        try layouts.apply(.schema(connectionID: connection, database: "foxlume", from: "fq110_schema", to: "fq110_schema_renamed"))

        let schemas = try await session.run { try $0.schemas() }
        #expect(schemas.contains("fq110_schema_renamed") && !schemas.contains("fq110_schema"))
        let tables = try await session.run { try $0.tables(schema: "fq110_schema_renamed") }.map(\.name)
        #expect(tables == ["items"])
        let moved = GridColumnLayoutScope(connectionID: connection, database: "foxlume", schema: "fq110_schema_renamed", table: "items")
        #expect(layouts.layout(for: moved)?.columns.map(\.name) == ["label", "id"])
        #expect(layouts.layout(for: old) == nil)

        // Other refusals come from the server, such as a new name with the reserved pg_ prefix. Never try renaming a
        // system schema here: a superuser may rename pg_catalog, which breaks the test server.
        await #expect(throws: DatabaseError.self) {
            _ = try await session.run { try $0.execute(try #require(sql.renameSchema("fq110_schema_renamed", to: "pg_fq110")), rowLimit: nil) }
        }
        _ = try await session.run { try $0.execute("DROP SCHEMA fq110_schema_renamed CASCADE", rowLimit: nil) }
        await session.close()
    }

    @Test func renameAndCopyTheDatabaseTheSessionUses() async throws {
        let admin = try await session("postgres")
        await dropDatabases(["fq110_db", "fq110_db_renamed", "fq110_db_copy"], on: admin)
        _ = try await admin.run { try $0.execute("CREATE DATABASE fq110_db", rowLimit: nil) }

        // The workspace's own session sits on the database being renamed.
        let own = try await session("fq110_db")
        _ = try await own.run { try $0.execute("CREATE TABLE marker (id int); INSERT INTO marker VALUES (1)", rowLimit: nil) }
        let maintenance = try await session("postgres")

        let renamed = try await DatabaseChangeRunner(change: .rename(from: "fq110_db", to: "fq110_db_renamed"))
            .run(own: own, maintenance: maintenance, waitDatabase: "postgres")
        #expect(renamed.statement == #"ALTER DATABASE "fq110_db" RENAME TO "fq110_db_renamed""#)
        #expect(renamed.ownDatabase == "fq110_db_renamed")
        #expect(await own.currentDatabase() == "fq110_db_renamed")
        // Reconnects open the new name once the session is told about it.
        own.setDefaultDatabase("fq110_db_renamed")
        try await own.reconnect()
        #expect(await own.currentDatabase() == "fq110_db_renamed")

        let copied = try await DatabaseChangeRunner(change: .copy(from: "fq110_db_renamed", to: "fq110_db_copy", owner: "postgres"))
            .run(own: own, maintenance: maintenance, waitDatabase: "postgres")
        #expect(copied.ownDatabase == "fq110_db_renamed", "a copy returns to the source")
        #expect(await own.currentDatabase() == "fq110_db_renamed")
        let databases = try await admin.run { try $0.databases() }
        #expect(databases.contains("fq110_db_renamed") && databases.contains("fq110_db_copy") && !databases.contains("fq110_db"))

        // The copy has the source's rows; a session elsewhere is not moved.
        let copySession = try await session("fq110_db_copy")
        let rows = try await copySession.run { try $0.execute("SELECT count(*) FROM marker", rowLimit: nil) }
        #expect(rows.first?.rows.first?.first?.displayString == "1")
        await copySession.close()
        let elsewhere = try await DatabaseChangeRunner(change: .rename(from: "fq110_db_copy", to: "fq110_db_copy2"))
            .run(own: own, maintenance: maintenance, waitDatabase: "postgres")
        #expect(elsewhere.ownDatabase == nil)
        #expect(await own.currentDatabase() == "fq110_db_renamed")

        await own.close()
        await maintenance.close()
        await dropDatabases(["fq110_db_renamed", "fq110_db_copy", "fq110_db_copy2"], on: admin)
        await admin.close()
    }

    @Test func otherSessionsStopTheChangeBeforeAnythingMoves() async throws {
        let admin = try await session("postgres")
        await dropDatabases(["fq110_busy", "fq110_busy_renamed", "fq110_busy_copy"], on: admin)
        _ = try await admin.run { try $0.execute("CREATE DATABASE fq110_busy", rowLimit: nil) }
        let own = try await session("fq110_busy")
        let someoneElse = try await session("fq110_busy")
        let maintenance = try await session("postgres")

        for change in [DatabaseChange.rename(from: "fq110_busy", to: "fq110_busy_renamed"), .copy(from: "fq110_busy", to: "fq110_busy_copy", owner: nil)] {
            do {
                _ = try await DatabaseChangeRunner(change: change).run(own: own, maintenance: maintenance, waitDatabase: "postgres")
                Issue.record("\(change) ran with another session connected")
            } catch let error as DatabaseChangeError {
                guard case .otherSessions(let database, let groups) = error else { return }
                #expect(database == "fq110_busy")
                #expect(error.total == 1, "the app's own session is not counted")
                #expect(groups.first?.application == "Foxlume Query")
                #expect(groups.first?.user == "postgres")
            }
            // The own session stayed where it was.
            #expect(await own.currentDatabase() == "fq110_busy")
        }
        let databases = try await admin.run { try $0.databases() }
        #expect(databases.contains("fq110_busy") && !databases.contains("fq110_busy_renamed") && !databases.contains("fq110_busy_copy"))

        // Once the other session is gone, the rename goes through.
        await someoneElse.close()
        let outcome = try await DatabaseChangeRunner(change: .rename(from: "fq110_busy", to: "fq110_busy_renamed"))
            .run(own: own, maintenance: maintenance, waitDatabase: "postgres")
        #expect(outcome.ownDatabase == "fq110_busy_renamed")

        await own.close()
        await maintenance.close()
        await dropDatabases(["fq110_busy", "fq110_busy_renamed", "fq110_busy_copy"], on: admin)
        await admin.close()
    }
}

@Suite struct DuckDBSchemaRenameTests {
    /// Rename Schema stays hidden for DuckDB while the bundled library refuses it; this fails once an update allows it.
    @Test func bundledDuckDBCannotRenameSchemas() async throws {
        let session = try await DuckDBTests.open()
        _ = try await session.execute("CREATE SCHEMA fq110_s")
        await #expect(throws: (any Error).self) {
            _ = try await session.execute("ALTER SCHEMA fq110_s RENAME TO fq110_t")
        }
        #expect(!DatabaseObjectSQL(kind: .duckdb).canRenameSchemas)
        await session.close()
    }
}

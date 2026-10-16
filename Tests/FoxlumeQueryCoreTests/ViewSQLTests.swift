import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct ViewSQLTests {
    @Test func enginesWithViews() {
        for kind in [DatabaseKind.postgresql, .mysql, .mariadb, .sqlite, .duckdb] {
            #expect(ViewSQL(kind: kind).supportsViews)
            #expect(ViewSQL(kind: kind).canEdit(.view))
            #expect(!ViewSQL(kind: kind).canEdit(.table))
        }
        #expect(!ViewSQL(kind: .mongodb).supportsViews)
        #expect(!ViewSQL(kind: .redis).canEdit(.view))
        #expect(ViewSQL(kind: .postgresql).canEdit(.materializedView))
        #expect(!ViewSQL(kind: .mysql).canEdit(.materializedView))
        #expect(ViewSQL(kind: .postgresql).runsScriptsInTransaction)
        #expect(ViewSQL(kind: .sqlite).runsScriptsInTransaction)
        #expect(!ViewSQL(kind: .mysql).runsScriptsInTransaction)
    }

    @Test func templatesQuotePerDialect() {
        #expect(ViewSQL(kind: .postgresql).template(name: "active \"orders\"", schema: "sales")
            == "CREATE VIEW \"sales\".\"active \"\"orders\"\"\" AS\nSELECT\n    *\nFROM \"table_name\";")
        #expect(ViewSQL(kind: .postgresql).template(name: "v", schema: "public", source: TableRef(schema: "public", name: "orders"))?
            .hasSuffix("FROM \"public\".\"orders\";") == true)
        // MySQL and SQLite have no schemas, so the name stays unqualified (the current database).
        #expect(ViewSQL(kind: .mysql).template(name: "v`1", schema: "shop")?.hasPrefix("CREATE VIEW `v``1` AS\n") == true)
        #expect(ViewSQL(kind: .sqlite).template(name: "v", schema: "main")?.hasPrefix("CREATE VIEW \"v\" AS\n") == true)
        #expect(ViewSQL(kind: .duckdb).template(name: "v", schema: "main")?.hasPrefix("CREATE VIEW \"main\".\"v\" AS\n") == true)
        #expect(ViewSQL(kind: .mongodb).template(name: "v", schema: nil) == nil)
        #expect(ViewSQL(kind: .postgresql).template(name: "", schema: "public") == nil)
    }

    @Test func readsTheHeadOfCreateView() throws {
        let plain = try #require(ViewSQL.head(of: "-- note\nCREATE VIEW Sales.Active_Orders AS SELECT 1", family: .postgresql))
        #expect(plain.view == TableRef(schema: "sales", name: "active_orders"))
        #expect(!plain.isOrReplace && !plain.isMaterialized && plain.options.isEmpty)

        let quoted = try #require(ViewSQL.head(of: "create or replace temp view \"My Schema\".\"V x\" (a) as select 1", family: .postgresql))
        #expect(quoted.view == TableRef(schema: "My Schema", name: "V x"))
        #expect(quoted.isOrReplace)
        #expect(quoted.options == "temp")

        let materialized = try #require(ViewSQL.head(of: "CREATE MATERIALIZED VIEW IF NOT EXISTS mv AS SELECT 1", family: .postgresql))
        #expect(materialized.isMaterialized)
        #expect(materialized.view == TableRef(name: "mv"))

        let mysql = try #require(ViewSQL.head(of: "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY INVOKER VIEW `shop`.`Paid` AS select 1 AS `a`", family: .mysql))
        #expect(mysql.options == "ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY INVOKER")
        #expect(mysql.view == TableRef(schema: "shop", name: "Paid"))
        #expect(ViewSQL.head(of: "CREATE DEFINER = CURRENT_USER() VIEW v AS SELECT 1", family: .mysql)?.options == "DEFINER = CURRENT_USER()")

        // Other CREATE statements are not views, even when a name contains the word.
        #expect(ViewSQL.head(of: "CREATE TABLE view_copy AS SELECT 1 AS view", family: .postgresql) == nil)
        #expect(ViewSQL.head(of: "CREATE INDEX view_idx ON t (view)", family: .postgresql) == nil)
        #expect(ViewSQL.head(of: "CREATE FUNCTION f(view integer) RETURNS integer RETURN 1", family: .postgresql) == nil)
        #expect(ViewSQL.head(of: "SELECT * FROM v", family: .postgresql) == nil)
        #expect(ViewSQL.head(of: "CREATE VIEW AS SELECT 1", family: .postgresql) == nil)
    }

    @Test func createdViewIsTheLastCreateViewOfTheScript() {
        let sql = ViewSQL(kind: .postgresql)
        #expect(sql.createdView(in: "DROP VIEW IF EXISTS a;\nCREATE VIEW public.\"B\" AS SELECT 1;\nCOMMENT ON VIEW public.\"B\" IS 'x';") == TableRef(schema: "public", name: "B"))
        #expect(sql.createdView(in: "SELECT 1; CREATE TABLE t (id int);") == nil)
        #expect(ViewSQL(kind: .mysql).createdView(in: "CREATE OR REPLACE VIEW `Paid` AS SELECT 1") == TableRef(name: "Paid"))
        #expect(ViewSQL(kind: .sqlite).createdView(in: "create view Mixed as select 1") == TableRef(name: "Mixed"))
    }

    @Test func postgresEditScripts() {
        let sql = ViewSQL(kind: .postgresql)
        let view = ViewDefinition(
            view: TableRef(schema: "public", name: "paid"),
            statement: "CREATE VIEW \"public\".\"paid\" WITH (security_barrier=true) AS\n SELECT orders.id\n   FROM orders;",
            attachedStatements: ["COMMENT ON VIEW \"public\".\"paid\" IS 'Paid orders'"]
        )
        // OR REPLACE keeps comments and grants, so they are not repeated.
        #expect(sql.editScript(view) == "CREATE OR REPLACE VIEW \"public\".\"paid\" WITH (security_barrier=true) AS\n SELECT orders.id\n   FROM orders;")

        let materialized = ViewDefinition(
            view: TableRef(schema: "public", name: "totals"),
            isMaterialized: true,
            statement: "CREATE MATERIALIZED VIEW \"public\".\"totals\" AS\n SELECT 1 AS n\nWITH NO DATA",
            attachedStatements: ["COMMENT ON MATERIALIZED VIEW \"public\".\"totals\" IS 'x';", "CREATE INDEX totals_n ON public.totals USING btree (n);"]
        )
        #expect(sql.editScript(materialized) == """
            \(ViewSQL.materializedViewWarning)
            DROP MATERIALIZED VIEW "public"."totals";

            CREATE MATERIALIZED VIEW "public"."totals" AS
             SELECT 1 AS n
            WITH NO DATA;

            COMMENT ON MATERIALIZED VIEW "public"."totals" IS 'x';

            CREATE INDEX totals_n ON public.totals USING btree (n);
            """)
        #expect(sql.refreshStatement(TableRef(schema: "public", name: "totals")) == "REFRESH MATERIALIZED VIEW \"public\".\"totals\"")
        #expect(ViewSQL(kind: .mysql).refreshStatement(TableRef(name: "v")) == nil)
    }

    @Test func otherEnginesEditScripts() {
        let mysql = ViewDefinition(
            view: TableRef(name: "paid"),
            statement: "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `paid` AS select `orders`.`id` AS `id` from `orders`"
        )
        #expect(ViewSQL(kind: .mysql).editScript(mysql) == "CREATE OR REPLACE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `paid` AS select `orders`.`id` AS `id` from `orders`;")
        #expect(ViewSQL(kind: .mariadb).editScript(mysql).hasPrefix("CREATE OR REPLACE ALGORITHM=UNDEFINED"))

        let sqlite = ViewDefinition(
            view: TableRef(name: "paid"),
            statement: "create view paid(id) as select id from orders",
            attachedStatements: ["CREATE TRIGGER paid_insert INSTEAD OF INSERT ON paid BEGIN INSERT INTO orders (id) VALUES (NEW.id); END"]
        )
        #expect(ViewSQL(kind: .sqlite).editScript(sqlite) == """
            DROP VIEW IF EXISTS "paid";

            CREATE VIEW "paid"(id) as select id from orders;

            CREATE TRIGGER paid_insert INSTEAD OF INSERT ON paid BEGIN INSERT INTO orders (id) VALUES (NEW.id); END;
            """)

        let duckdb = ViewDefinition(view: TableRef(schema: "main", name: "paid"), statement: "CREATE VIEW paid AS SELECT id FROM orders;")
        #expect(ViewSQL(kind: .duckdb).editScript(duckdb) == "CREATE OR REPLACE VIEW \"main\".\"paid\" AS SELECT id FROM orders;")
    }

    @Test func postgresColumnChangesNeedDropAndCreate() throws {
        #expect(ViewSQL.needsRecreate(DatabaseError.server(message: "cannot drop columns from view", code: "42P16")))
        #expect(ViewSQL.needsRecreate(DatabaseError.server(message: "cannot change name of view column \"a\" to \"b\"", code: "42P16")))
        #expect(ViewSQL.needsRecreate(DatabaseError.server(message: "cannot change data type of view column \"a\" from integer to text", code: "42P16")))
        #expect(!ViewSQL.needsRecreate(DatabaseError.server(message: "syntax error at or near \"SELEC\"", code: "42601")))
        #expect(!ViewSQL.needsRecreate(DatabaseError.cancelled))
        #expect(!ViewSQL.needsRecreate(CocoaError(.fileNoSuchFile)))

        let sql = ViewSQL(kind: .postgresql)
        let definition = ViewDefinition(
            view: TableRef(schema: "public", name: "paid"),
            statement: "CREATE VIEW \"public\".\"paid\" AS SELECT 1 AS a",
            attachedStatements: ["COMMENT ON VIEW \"public\".\"paid\" IS 'Paid';", "COMMENT ON COLUMN \"public\".\"paid\".\"a\" IS 'gone';"]
        )
        let edited = "CREATE OR REPLACE VIEW \"public\".\"paid\" AS\n SELECT 2 AS b;\n"
        let script = try #require(sql.recreateScript(replacing: edited, definition: definition))
        #expect(script == """
            DROP VIEW "public"."paid";

            CREATE VIEW "public"."paid" AS
             SELECT 2 AS b;

            COMMENT ON VIEW "public"."paid" IS 'Paid';
            """)
        // A script that sets the comment itself keeps its own; other views get no comment.
        #expect(sql.recreateScript(replacing: edited + "COMMENT ON VIEW public.paid IS 'New';", definition: definition)?.hasSuffix("COMMENT ON VIEW public.paid IS 'New';") == true)
        #expect(sql.recreateScript(replacing: "CREATE OR REPLACE VIEW other AS SELECT 1", definition: definition) == "DROP VIEW \"other\";\n\nCREATE VIEW \"other\" AS SELECT 1;")
        #expect(sql.recreateScript(replacing: "SELECT 1") == nil)
        #expect(sql.recreateScript(replacing: "CREATE MATERIALIZED VIEW mv AS SELECT 1") == nil)
        #expect(ViewSQL(kind: .mysql).recreateScript(replacing: edited) == nil)
    }
}

/// SQLite and DuckDB views in scratch files, through the same calls the app makes.
@Suite("Views on SQLite and DuckDB", .serialized)
struct LocalViewTests {
    @Test func sqliteEditsInOneTransaction() async throws {
        let url = TestFiles.url("fq_vw_\(UUID().uuidString.prefix(8)).sqlite")
        defer { TestFiles.removeDatabase(url) }
        let session = DatabaseSession(parameters: ConnectionParameters(config: ConnectionConfig(kind: .sqlite, filePath: url.path), password: ""))
        try await session.connect()
        _ = try await session.execute("""
            CREATE TABLE fq_vw_items (id INTEGER PRIMARY KEY, qty INTEGER, note TEXT);
            INSERT INTO fq_vw_items VALUES (1, 5, 'a'), (2, 0, 'b');
            """)
        let sql = ViewSQL(kind: .sqlite)

        // New View: the template with a source table runs as it is.
        let template = try #require(sql.template(name: "fq_vw_all", schema: nil, source: TableRef(name: "fq_vw_items")))
        _ = try await session.execute(template)
        #expect(sql.createdView(in: template) == TableRef(name: "fq_vw_all"))

        _ = try await session.execute("""
            CREATE VIEW fq_vw_stock AS SELECT id, qty FROM fq_vw_items WHERE qty > 0;
            CREATE TRIGGER fq_vw_stock_insert INSTEAD OF INSERT ON fq_vw_stock BEGIN INSERT INTO fq_vw_items (id, qty) VALUES (NEW.id, NEW.qty); END;
            """)
        let view = TableRef(name: "fq_vw_stock")
        let definition = try await session.run { try $0.viewDefinition(of: view) }
        #expect(definition.statement == "CREATE VIEW fq_vw_stock AS SELECT id, qty FROM fq_vw_items WHERE qty > 0")
        #expect(definition.attachedStatements.count == 1)
        #expect(definition.attachedStatements.first?.hasPrefix("CREATE TRIGGER fq_vw_stock_insert") == true)

        // Edit View: a column more; the trigger is created again after the view.
        let script = sql.editScript(definition).replacingOccurrences(of: "SELECT id, qty", with: "SELECT id, qty, note")
        let statements = QueryLanguage.sql(.sqlite).split(script).map(\.text)
        #expect(statements.count == 3)
        _ = try await session.executeTransaction(statements)
        let columns = try await session.run { try $0.structure(of: view).columns.map(\.name) }
        #expect(columns == ["id", "qty", "note"])
        #expect(try await session.run { try $0.viewDefinition(of: view).attachedStatements.count } == 1)

        // A failing CREATE rolls the DROP back: the view is still there. (SQLite only checks the tables a view reads
        // when it is used, so the failure here is a syntax error.)
        let broken = sql.editScript(definition).replacingOccurrences(of: "SELECT id, qty", with: "SELEC id, qty")
        await #expect(throws: DatabaseError.self) {
            _ = try await session.executeTransaction(QueryLanguage.sql(.sqlite).split(broken).map(\.text))
        }
        let after = try await session.run { try $0.viewDefinition(of: view) }
        #expect(after.statement.contains("note"))
        #expect(try await session.run { try $0.tables(schema: nil).filter { $0.kind == .view }.map(\.name) } == ["fq_vw_all", "fq_vw_stock"])

        await #expect(throws: DatabaseError.self) { try await session.run { try $0.viewDefinition(of: TableRef(name: "fq_vw_items")) } }
        await session.close()
    }

    @Test func duckdbReplacesInPlace() throws {
        let url = TestFiles.url("fq_vw_\(UUID().uuidString.prefix(8)).duckdb")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(atPath: url.path + ".wal") }
        let connection = DuckDBConnection(parameters: ConnectionParameters(config: ConnectionConfig(kind: .duckdb, filePath: url.path), password: ""))
        try connection.connect()
        defer { connection.close() }
        _ = try connection.execute("""
            CREATE SCHEMA fq_vw;
            CREATE TABLE fq_vw.items (id INTEGER, qty INTEGER, note VARCHAR);
            CREATE VIEW fq_vw.stock AS SELECT id, qty FROM fq_vw.items;
            """, rowLimit: nil)
        let sql = ViewSQL(kind: .duckdb)
        let view = TableRef(schema: "fq_vw", name: "stock")
        let definition = try connection.viewDefinition(of: view)
        #expect(definition.view == view)
        #expect(definition.statement.hasPrefix("CREATE VIEW"))
        #expect(!definition.statement.hasSuffix(";"))

        // The rewritten head names the view's schema, so the edit lands there and not in the current schema (main).
        let script = sql.editScript(definition)
        #expect(script.hasPrefix("CREATE OR REPLACE VIEW \"fq_vw\".\"stock\" AS"))
        _ = try connection.execute(script.replacingOccurrences(of: "SELECT id, qty", with: "SELECT id"), rowLimit: nil)
        #expect(try connection.structure(of: view).columns.map(\.name) == ["id"])
        #expect(try connection.tables(schema: "main").isEmpty)

        let template = try #require(sql.template(name: "fresh", schema: "fq_vw", source: TableRef(schema: "fq_vw", name: "items")))
        _ = try connection.execute(template, rowLimit: nil)
        #expect(try connection.tables(schema: "fq_vw").filter { $0.kind == .view }.map(\.name) == ["fresh", "stock"])
        #expect(throws: DatabaseError.self) { try connection.viewDefinition(of: TableRef(schema: "fq_vw", name: "items")) }
    }
}

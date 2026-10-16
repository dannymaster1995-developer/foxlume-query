import Foundation
import Testing
@testable import FoxlumeQueryCore

/// New View and Edit View against the local test servers. Every object is a scratch `fq_vw_<random>_…` object that
/// the test drops again.
private func scratchPrefix() -> String {
    "fq_vw_" + UUID().uuidString.prefix(6).lowercased()
}

@Suite("Views on PostgreSQL", .serialized, .enabled(if: PostgresTestServer.isAvailable, "needs the PostgreSQL test server"))
struct PostgresViewLiveTests {
    @Test func createsEditsRecreatesAndDropsViews() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let p = scratchPrefix()
        let items = TableRef(schema: "public", name: "\(p)_items")
        let stock = TableRef(schema: "public", name: "\(p)_stock")
        defer { _ = try? connection.execute("DROP TABLE IF EXISTS public.\(p)_items CASCADE", rowLimit: nil) }
        _ = try connection.execute("""
            CREATE TABLE public.\(p)_items (id integer PRIMARY KEY, qty integer, note text);
            INSERT INTO public.\(p)_items VALUES (1, 5, 'a'), (2, 0, 'b');
            """, rowLimit: nil)
        let sql = ViewSQL(kind: .postgresql)
        let operations = TableOperationSQL(kind: .postgresql)

        // New View: the template runs and names the view it makes.
        let template = try #require(sql.template(name: "\(p)_all", schema: "public", source: items))
        _ = try connection.execute(template, rowLimit: nil)
        #expect(sql.createdView(in: template) == TableRef(schema: "public", name: "\(p)_all"))
        #expect(try connection.structure(of: TableRef(schema: "public", name: "\(p)_all")).columns.map(\.name) == ["id", "qty", "note"])
        _ = try connection.execute("""
            CREATE VIEW public.\(p)_stock WITH (security_barrier = true) AS SELECT id, qty FROM public.\(p)_items WHERE qty > 0;
            COMMENT ON VIEW public.\(p)_stock IS 'In stock';
            """, rowLimit: nil)

        // Edit View: the definition keeps the options; the script runs unchanged and with a column added at the end.
        let definition = try connection.viewDefinition(of: stock)
        #expect(definition.view == stock)
        #expect(!definition.isMaterialized)
        #expect(definition.statement.hasPrefix("CREATE VIEW \"public\".\"\(p)_stock\" WITH (security_barrier=true) AS\n"))
        #expect(definition.attachedStatements.first == "COMMENT ON VIEW \"public\".\"\(p)_stock\" IS 'In stock';")
        let script = sql.editScript(definition)
        #expect(script.hasPrefix("CREATE OR REPLACE VIEW"))
        _ = try connection.execute(script, rowLimit: nil)
        let head = try #require(script.components(separatedBy: " AS\n").first)
        _ = try connection.execute(head + " AS\nSELECT id, qty, note FROM public.\(p)_items WHERE qty > 0;", rowLimit: nil)
        #expect(try connection.structure(of: stock).columns.map(\.name) == ["id", "qty", "note"])

        // Dropping a column is refused by OR REPLACE; DROP + CREATE in one transaction does it and keeps the comment.
        let narrowed = "CREATE OR REPLACE VIEW public.\(p)_stock AS SELECT id FROM public.\(p)_items"
        do {
            _ = try connection.execute(narrowed, rowLimit: nil)
            Issue.record("CREATE OR REPLACE VIEW dropped a column")
        } catch {
            #expect(ViewSQL.needsRecreate(error))
        }
        let recreate = try #require(sql.recreateScript(replacing: narrowed, definition: definition))
        _ = try connection.execute("BEGIN;\n" + recreate + "\nCOMMIT;", rowLimit: nil)
        #expect(try connection.structure(of: stock).columns.map(\.name) == ["id"])
        #expect(try connection.tables(schema: "public").first { $0.ref == stock }?.comment == "In stock")

        // A dependent view makes the DROP fail; the transaction leaves both views as they were.
        _ = try connection.execute("CREATE VIEW public.\(p)_child AS SELECT id FROM public.\(p)_stock", rowLimit: nil)
        let blocked = try #require(sql.recreateScript(replacing: "CREATE OR REPLACE VIEW public.\(p)_stock AS SELECT qty FROM public.\(p)_items"))
        #expect(throws: DatabaseError.self) { _ = try connection.execute("BEGIN;\n" + blocked + "\nCOMMIT;", rowLimit: nil) }
        _ = try? connection.execute("ROLLBACK", rowLimit: nil)
        #expect(try connection.structure(of: stock).columns.map(\.name) == ["id"])

        // Materialized view: WITH NO DATA, an index and a comment survive DROP + CREATE; Refresh fills it.
        let totals = TableRef(schema: "public", name: "\(p)_totals")
        _ = try connection.execute("""
            CREATE MATERIALIZED VIEW public.\(p)_totals AS SELECT id, qty FROM public.\(p)_items WITH NO DATA;
            CREATE INDEX \(p)_totals_id ON public.\(p)_totals (id);
            COMMENT ON MATERIALIZED VIEW public.\(p)_totals IS 'Totals';
            """, rowLimit: nil)
        let materialized = try connection.viewDefinition(of: totals)
        #expect(materialized.isMaterialized)
        #expect(materialized.statement.hasSuffix("\nWITH NO DATA"))
        #expect(materialized.attachedStatements.contains { $0.hasPrefix("CREATE INDEX \(p)_totals_id") })
        let matScript = sql.editScript(materialized)
        #expect(matScript.hasPrefix(ViewSQL.materializedViewWarning + "\nDROP MATERIALIZED VIEW"))
        _ = try connection.execute("BEGIN;\n" + matScript + "\nCOMMIT;", rowLimit: nil)
        let reread = try connection.viewDefinition(of: totals)
        #expect(reread.statement == materialized.statement)
        #expect(reread.attachedStatements == materialized.attachedStatements)
        _ = try connection.execute(try #require(sql.refreshStatement(totals)), rowLimit: nil)
        #expect(!(try connection.viewDefinition(of: totals).statement.contains("WITH NO DATA")))
        #expect(try connection.execute("SELECT count(*) FROM public.\(p)_totals", rowLimit: nil).first?.rows.first?.first?.textValue == "2")

        // Drop through the sidebar's statements; a table is not a view.
        _ = try connection.execute(try #require(operations.dropStatement(totals, objectKind: .materializedView)), rowLimit: nil)
        _ = try connection.execute(try #require(operations.dropStatement(stock, objectKind: .view, options: TableOperationOptions(cascade: true))), rowLimit: nil)
        #expect(try connection.tables(schema: "public").filter { $0.name.hasPrefix(p) }.map(\.name) == ["\(p)_all", "\(p)_items"])
        #expect(throws: DatabaseError.self) { try connection.viewDefinition(of: items) }
    }
}

@Suite("Views on MySQL", .serialized, .enabled(if: MySQLTestServer.isAvailable, "needs the MySQL test server"))
struct MySQLViewLiveTests {
    @Test func createsEditsAndDropsViews() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        let p = scratchPrefix()
        let items = TableRef(name: "\(p)_items")
        let stock = TableRef(name: "\(p)_stock")
        defer { _ = try? connection.execute("DROP VIEW IF EXISTS \(p)_stock; DROP TABLE IF EXISTS \(p)_items", rowLimit: nil) }
        _ = try connection.execute("CREATE TABLE \(p)_items (id INT PRIMARY KEY, qty INT, note TEXT); INSERT INTO \(p)_items VALUES (1, 5, 'a')", rowLimit: nil)
        let sql = ViewSQL(kind: .mysql)

        let template = try #require(sql.template(name: stock.name, schema: nil, source: items))
        _ = try connection.execute(template, rowLimit: nil)
        #expect(sql.createdView(in: template) == stock)
        _ = try connection.execute("CREATE OR REPLACE SQL SECURITY INVOKER VIEW \(p)_stock AS SELECT id, qty FROM \(p)_items WHERE qty > 0", rowLimit: nil)

        // SHOW CREATE VIEW keeps ALGORITHM, DEFINER and SQL SECURITY; OR REPLACE keeps them and may change columns.
        let definition = try connection.viewDefinition(of: stock)
        #expect(definition.statement.hasPrefix("CREATE ALGORITHM="))
        #expect(definition.statement.contains("DEFINER="))
        #expect(definition.statement.contains("SQL SECURITY INVOKER VIEW `\(p)_stock`"))
        let script = sql.editScript(definition)
        #expect(script.hasPrefix("CREATE OR REPLACE ALGORITHM="))
        _ = try connection.execute(script, rowLimit: nil)
        let narrowed = script.replacingOccurrences(of: ",`\(p)_items`.`qty` AS `qty`", with: "")
        #expect(narrowed != script)
        _ = try connection.execute(narrowed, rowLimit: nil)
        #expect(try connection.structure(of: stock).columns.map(\.name) == ["id"])
        #expect(try connection.viewDefinition(of: stock).statement.contains("SQL SECURITY INVOKER"))

        let drop = try #require(TableOperationSQL(kind: .mysql).dropStatement(stock, objectKind: .view))
        _ = try connection.execute(drop, rowLimit: nil)
        #expect(try connection.tables(schema: nil).filter { $0.name.hasPrefix(p) }.map(\.name) == ["\(p)_items"])
        #expect(throws: DatabaseError.self) { try connection.viewDefinition(of: items) }
    }
}

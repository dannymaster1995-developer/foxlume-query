import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct SchemaObjectSQLTests {
    private let pgFunction = SchemaObject(kind: .function, schema: "my \"schema\"", name: "add", arguments: "a integer, b text",
                                          identityArguments: "integer, text", returnType: "integer", detail: "sql")

    @Test func kindsPerEngine() {
        #expect(SchemaObjectKind.kinds(for: .postgresql) == [.procedure, .function, .trigger, .type])
        #expect(SchemaObjectKind.kinds(for: .mysql) == [.procedure, .function, .trigger])
        #expect(SchemaObjectKind.kinds(for: .mariadb) == [.procedure, .function, .trigger])
        #expect(SchemaObjectKind.kinds(for: .sqlite) == [.trigger])
        #expect(SchemaObjectKind.kinds(for: .duckdb) == [.function])
        #expect(SchemaObjectKind.kinds(for: .mongodb).isEmpty)
        #expect(SchemaObjectKind.kinds(for: .redis).isEmpty)
    }

    @Test func postgresDropStatementsQuoteAndNameTheOverload() {
        let sql = SchemaObjectSQL(kind: .postgresql)
        #expect(sql.dropStatement(pgFunction) == "DROP FUNCTION IF EXISTS \"my \"\"schema\"\"\".\"add\"(integer, text)")
        var procedure = pgFunction
        procedure.kind = .procedure
        procedure.identityArguments = ""
        #expect(sql.dropStatement(procedure) == "DROP PROCEDURE IF EXISTS \"my \"\"schema\"\"\".\"add\"()")
        let trigger = SchemaObject(kind: .trigger, schema: "public", name: "trg\"x", table: "items")
        #expect(sql.dropStatement(trigger) == "DROP TRIGGER IF EXISTS \"trg\"\"x\" ON \"public\".\"items\"")
        #expect(sql.dropStatement(SchemaObject(kind: .type, schema: "public", name: "mood", detail: "enum")) == "DROP TYPE IF EXISTS \"public\".\"mood\"")
        #expect(sql.dropStatement(SchemaObject(kind: .type, schema: "public", name: "positive", detail: "domain")) == "DROP DOMAIN IF EXISTS \"public\".\"positive\"")
        #expect(sql.dropStatement(SchemaObject(kind: .trigger, schema: "public", name: "no_table")) == nil)
    }

    @Test func otherEnginesDropStatements() {
        #expect(SchemaObjectSQL(kind: .mysql).dropStatement(SchemaObject(kind: .procedure, schema: "shop", name: "re`fund")) == "DROP PROCEDURE IF EXISTS `shop`.`re``fund`")
        #expect(SchemaObjectSQL(kind: .mariadb).dropStatement(SchemaObject(kind: .trigger, schema: nil, name: "t", table: "items")) == "DROP TRIGGER IF EXISTS `t`")
        #expect(SchemaObjectSQL(kind: .mysql).dropStatement(SchemaObject(kind: .type, name: "x")) == nil)
        #expect(SchemaObjectSQL(kind: .sqlite).dropStatement(SchemaObject(kind: .trigger, name: "a\"b", table: "t")) == "DROP TRIGGER IF EXISTS \"a\"\"b\"")
        #expect(SchemaObjectSQL(kind: .duckdb).dropStatement(SchemaObject(kind: .function, schema: "main", name: "m", detail: "macro")) == "DROP MACRO IF EXISTS \"main\".\"m\"")
        #expect(SchemaObjectSQL(kind: .duckdb).dropStatement(SchemaObject(kind: .function, schema: "main", name: "m", detail: "table_macro")) == "DROP MACRO TABLE IF EXISTS \"main\".\"m\"")
        #expect(SchemaObjectSQL(kind: .redis).dropStatement(SchemaObject(kind: .trigger, name: "x", table: "y")) == nil)
    }

    @Test func editScripts() {
        let pg = SchemaObjectSQL(kind: .postgresql)
        let functionDefinition = SchemaObjectDefinition(statement: "CREATE OR REPLACE FUNCTION public.f()\n RETURNS integer\n LANGUAGE sql\nAS $function$ SELECT 1 $function$\n")
        #expect(pg.editScript(for: pgFunction, definition: functionDefinition) == "CREATE OR REPLACE FUNCTION public.f()\n RETURNS integer\n LANGUAGE sql\nAS $function$ SELECT 1 $function$;")

        let trigger = SchemaObject(kind: .trigger, schema: "public", name: "trg", table: "items")
        let triggerDefinition = SchemaObjectDefinition(
            statement: "CREATE TRIGGER trg BEFORE INSERT ON public.items FOR EACH ROW EXECUTE FUNCTION fn()",
            triggerFunction: "CREATE OR REPLACE FUNCTION public.fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$",
            canReplaceTrigger: true
        )
        #expect(pg.editScript(for: trigger, definition: triggerDefinition) == """
            CREATE OR REPLACE FUNCTION public.fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;

            CREATE OR REPLACE TRIGGER trg BEFORE INSERT ON public.items FOR EACH ROW EXECUTE FUNCTION fn();
            """)
        var old = triggerDefinition
        old.canReplaceTrigger = false
        #expect(pg.editScript(for: trigger, definition: old).contains("DROP TRIGGER IF EXISTS \"trg\" ON \"public\".\"items\";\n\nCREATE TRIGGER trg"))
        #expect(pg.displayText(triggerDefinition) == """
            CREATE TRIGGER trg BEFORE INSERT ON public.items FOR EACH ROW EXECUTE FUNCTION fn();

            -- Trigger function
            CREATE OR REPLACE FUNCTION public.fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;
            """)

        let mysql = SchemaObjectSQL(kind: .mysql)
        let procedure = SchemaObject(kind: .procedure, schema: "foxlume", name: "p")
        let script = mysql.editScript(for: procedure, definition: SchemaObjectDefinition(statement: "CREATE DEFINER=`root`@`%` PROCEDURE `p`()\nBEGIN SELECT 1; SELECT 2; END"))
        #expect(script == "DROP PROCEDURE IF EXISTS `foxlume`.`p`;\n\nCREATE DEFINER=`root`@`%` PROCEDURE `p`()\nBEGIN SELECT 1; SELECT 2; END;")
        // The query runner splits it into the DROP and the whole CREATE, without DELIMITER.
        #expect(SQLStatementSplitter.split(script, family: .mysql).count == 2)

        let sqlite = SchemaObjectSQL(kind: .sqlite)
        #expect(sqlite.editScript(for: SchemaObject(kind: .trigger, name: "t", table: "x"), definition: SchemaObjectDefinition(statement: "CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT 1; END")) == "DROP TRIGGER IF EXISTS \"t\";\n\nCREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT 1; END;")
    }

    @Test func orReplaceRewritesOnlyALeadingCreateTrigger() {
        #expect(SchemaObjectSQL.orReplaceTrigger("create  trigger x after insert") == "CREATE OR REPLACE TRIGGER x after insert")
        #expect(SchemaObjectSQL.orReplaceTrigger("CREATE CONSTRAINT TRIGGER x") == nil)
    }

    @Test func labelsShowSignaturesOnlyForOverloads() {
        let objects = [
            SchemaObject(kind: .function, schema: "public", name: "add", arguments: "a integer, b integer", identityArguments: "integer, integer"),
            SchemaObject(kind: .function, schema: "public", name: "add", arguments: "a text, b text", identityArguments: "text, text"),
            SchemaObject(kind: .function, schema: "public", name: "solo", arguments: "x integer", identityArguments: "integer"),
            SchemaObject(kind: .procedure, schema: "public", name: "solo", arguments: "", identityArguments: ""),
            SchemaObject(kind: .trigger, schema: "public", name: "trg", table: "items"),
        ]
        let labels = SchemaObject.labels(for: objects)
        #expect(objects.map { labels[$0.id] } == ["add(a integer, b integer)", "add(a text, b text)", "solo", "solo", "trg"])
        #expect(Set(objects.map(\.id)).count == objects.count)
        #expect(objects[0].qualifiedSignature == "public.add(a integer, b integer)")
        #expect(objects[4].qualifiedSignature == "public.trg on items")
        #expect(objects[4].searchText == "trg items")
    }

    @Test func tooltipListsReturnLanguageAndAttributes() {
        var object = pgFunction
        object.attributes = [SchemaObjectAttribute("Volatility", "IMMUTABLE")]
        #expect(object.tooltip == "my \"schema\".add(a integer, b text)\nReturns integer\nLanguage sql\nVolatility: IMMUTABLE")
    }

    @Test func triggerTemplates() {
        let table = TableRef(schema: "public", name: "items")
        let pg = SchemaObjectSQL(kind: .postgresql).triggerTemplate(table: table) ?? ""
        #expect(pg.contains("CREATE OR REPLACE FUNCTION \"public\".\"items_before_insert_fn\"()"))
        #expect(pg.contains("CREATE OR REPLACE TRIGGER \"items_before_insert\"\n    BEFORE INSERT ON \"public\".\"items\""))
        #expect(SQLStatementSplitter.split(pg, family: .postgresql).count == 2)
        #expect(!(SchemaObjectSQL(kind: .postgresql).triggerTemplate(table: table, replaceable: false) ?? "").contains("OR REPLACE TRIGGER"))
        let mysql = SchemaObjectSQL(kind: .mysql).triggerTemplate(table: TableRef(name: "items")) ?? ""
        #expect(mysql.hasPrefix("CREATE TRIGGER `items_before_insert`\n    BEFORE INSERT ON `items`"))
        #expect(SQLStatementSplitter.split(mysql, family: .mysql).count == 1)
        let sqlite = SchemaObjectSQL(kind: .sqlite).triggerTemplate(table: nil) ?? ""
        #expect(sqlite.contains("AFTER INSERT ON \"table_name\""))
        #expect(SchemaObjectSQL(kind: .duckdb).triggerTemplate(table: table) == nil)
    }

    @Test func sqliteTriggerHeaders() {
        #expect(SQLiteConnection.triggerHeader("CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT 1; END") == ("AFTER", "INSERT"))
        #expect(SQLiteConnection.triggerHeader("create temp trigger if not exists \"t\"\n  update of a, b on x begin select 1; end") == ("BEFORE", "UPDATE of a, b"))
        #expect(SQLiteConnection.triggerHeader("CREATE TRIGGER v INSTEAD OF DELETE ON vw BEGIN SELECT 1; END") == ("INSTEAD OF", "DELETE"))
        #expect(SQLiteConnection.triggerBody("CREATE TRIGGER t AFTER INSERT ON x BEGIN\n  SELECT 1;\nEND") == "SELECT 1;")
    }

    @Test func mysqlHelpers() {
        #expect(MySQLConnection.definerClause("root@%") == " DEFINER=`root`@`%`")
        #expect(MySQLConnection.definerClause("we`ird@local@host") == " DEFINER=`we``ird@local`@`host`")
        #expect(MySQLConnection.definerClause(nil) == "")
        #expect(MySQLConnection.version("8.4.9", atLeast: [8, 0, 16]))
        #expect(!MySQLConnection.version("8.0.15", atLeast: [8, 0, 16]))
        #expect(MySQLConnection.version("10.11.6-MariaDB-log", atLeast: [10, 2, 1]))
        #expect(!MySQLConnection.version("10.1.48-MariaDB", atLeast: [10, 2, 1]))
    }
}

@Suite("SQLite triggers", .serialized)
struct SQLiteTriggerTests {
    @Test func listsDefinesAndDropsTriggers() throws {
        let url = TestFiles.url("fq_rt_\(UUID().uuidString.prefix(8)).sqlite")
        defer { TestFiles.removeDatabase(url) }
        let connection = SQLiteConnection(parameters: ConnectionParameters(config: ConnectionConfig(kind: .sqlite, filePath: url.path), password: ""))
        try connection.connect()
        defer { connection.close() }
        let script = """
            CREATE TABLE fq_rt_items (id INTEGER PRIMARY KEY, qty INTEGER CHECK (qty >= 0), touched INTEGER DEFAULT 0);
            CREATE TABLE fq_rt_log (msg TEXT);
            CREATE TRIGGER fq_rt_after_insert AFTER INSERT ON fq_rt_items BEGIN INSERT INTO fq_rt_log VALUES ('end; of insert'); UPDATE fq_rt_items SET touched = 1 WHERE id = NEW.id; END;
            CREATE TRIGGER fq_rt_before_update BEFORE UPDATE OF qty ON fq_rt_items BEGIN SELECT 1; END;
            """
        // The splitter keeps each trigger body whole, as the query runner needs.
        #expect(SQLStatementSplitter.split(script, family: .sqlite).count == 4)
        _ = try connection.execute(script, rowLimit: nil)

        let objects = try connection.schemaObjects(.trigger, schema: nil)
        #expect(objects.map(\.name) == ["fq_rt_after_insert", "fq_rt_before_update"])
        #expect(objects.map(\.table) == ["fq_rt_items", "fq_rt_items"])
        #expect(objects.map(\.detail) == ["AFTER INSERT", "BEFORE UPDATE OF qty"])
        #expect(try connection.schemaObjects(.function, schema: nil).isEmpty)

        let definition = try connection.definition(of: objects[0])
        #expect(definition.statement.hasPrefix("CREATE TRIGGER fq_rt_after_insert AFTER INSERT"))

        let tableTriggers = try connection.triggers(of: TableRef(name: "fq_rt_items"))
        #expect(tableTriggers.map(\.name) == ["fq_rt_after_insert", "fq_rt_before_update"])
        #expect(tableTriggers.first?.action.hasPrefix("INSERT INTO fq_rt_log") == true)

        // Edit in Query Tab's script runs as it is, then Drop removes the trigger.
        let sql = SchemaObjectSQL(kind: .sqlite)
        _ = try connection.execute(sql.editScript(for: objects[0], definition: definition), rowLimit: nil)
        #expect(try connection.schemaObjects(.trigger, schema: nil).count == 2)
        _ = try connection.execute(try #require(sql.dropStatement(objects[0])), rowLimit: nil)
        #expect(try connection.schemaObjects(.trigger, schema: nil).map(\.name) == ["fq_rt_before_update"])
        #expect(throws: DatabaseError.self) { try connection.definition(of: objects[0]) }
    }
}

@Suite("DuckDB macros", .serialized)
struct DuckDBMacroTests {
    @Test func listsAndDefinesMacrosAndChecks() throws {
        let url = TestFiles.url("fq_rt_\(UUID().uuidString.prefix(8)).duckdb")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(atPath: url.path + ".wal") }
        let connection = DuckDBConnection(parameters: ConnectionParameters(config: ConnectionConfig(kind: .duckdb, filePath: url.path), password: ""))
        try connection.connect()
        defer { connection.close() }
        _ = try connection.execute("""
            CREATE MACRO fq_rt_add(a, b) AS a + b;
            CREATE MACRO fq_rt_rows(n) AS TABLE SELECT * FROM range(n);
            CREATE TABLE fq_rt_items (qty INTEGER CONSTRAINT fq_rt_qty CHECK (qty >= 0));
            """, rowLimit: nil)
        let macros = try connection.schemaObjects(.function, schema: nil)
        #expect(macros.map(\.name) == ["fq_rt_add", "fq_rt_rows"])
        #expect(macros.map(\.arguments) == ["a, b", "n"])
        let definition = try connection.definition(of: macros[1])
        #expect(definition.statement.hasPrefix("CREATE OR REPLACE MACRO \"main\".\"fq_rt_rows\"(n) AS TABLE "))
        // The rebuilt statement runs again unchanged.
        _ = try connection.execute(definition.statement, rowLimit: nil)
        _ = try connection.execute(try #require(SchemaObjectSQL(kind: .duckdb).dropStatement(macros[1])), rowLimit: nil)
        #expect(try connection.schemaObjects(.function, schema: nil).map(\.name) == ["fq_rt_add"])
        let checks = try connection.checkConstraints(of: TableRef(schema: "main", name: "fq_rt_items"))
        #expect(checks.map(\.expression) == ["(qty >= 0)"])
        #expect(checks.first?.columns == ["qty"])
    }
}

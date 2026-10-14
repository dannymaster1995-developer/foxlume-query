import Foundation
import Testing
@testable import FoxlumeQueryCore

/// Routines, triggers, types and CHECK constraints against the local test servers. Every object is a scratch
/// `fq_rt_<random>_…` object that the test drops again.
private func scratchPrefix() -> String {
    "fq_rt_" + UUID().uuidString.prefix(6).lowercased()
}

@Suite("Schema objects on PostgreSQL", .serialized, .enabled(if: PostgresTestServer.isAvailable, "needs the PostgreSQL test server"))
struct PostgresSchemaObjectLiveTests {
    @Test func listsDefinesEditsAndDropsObjects() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let p = scratchPrefix()
        let items = "\(p)_items"
        defer {
            _ = try? connection.execute("""
                DROP TABLE IF EXISTS \(items);
                DROP FUNCTION IF EXISTS \(p)_add(integer, integer);
                DROP FUNCTION IF EXISTS \(p)_add(text, text);
                DROP PROCEDURE IF EXISTS \(p)_proc(integer, integer);
                DROP FUNCTION IF EXISTS \(p)_trgfn();
                DROP AGGREGATE IF EXISTS \(p)_sum(integer);
                DROP TYPE IF EXISTS \(p)_mood;
                DROP TYPE IF EXISTS \(p)_pair;
                DROP DOMAIN IF EXISTS \(p)_positive;
                """, rowLimit: nil)
        }
        _ = try connection.execute("""
            CREATE TABLE \(items) (id integer PRIMARY KEY, qty integer CONSTRAINT \(p)_qty_check CHECK (qty >= 0), note text);
            ALTER TABLE \(items) ADD CONSTRAINT \(p)_note_check CHECK (note <> '') NOT VALID;
            CREATE FUNCTION \(p)_add(a integer, b integer) RETURNS integer LANGUAGE sql IMMUTABLE RETURN a + b;
            CREATE FUNCTION \(p)_add(a text, b text) RETURNS text LANGUAGE sql BEGIN ATOMIC SELECT a || b; END;
            CREATE PROCEDURE \(p)_proc(IN x integer, INOUT y integer) LANGUAGE plpgsql AS $$ BEGIN y := x + 1; END $$;
            CREATE FUNCTION \(p)_trgfn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.qty := coalesce(NEW.qty, 0); RETURN NEW; END $$;
            CREATE TRIGGER \(p)_trg BEFORE INSERT OR UPDATE OF qty ON \(items) FOR EACH ROW WHEN (NEW.id > 0) EXECUTE FUNCTION \(p)_trgfn();
            CREATE AGGREGATE \(p)_sum(integer) (SFUNC = int4pl, STYPE = integer);
            CREATE TYPE \(p)_mood AS ENUM ('sad', 'it''s ok', 'happy');
            CREATE TYPE \(p)_pair AS (left_value integer, right_value text);
            CREATE DOMAIN \(p)_positive AS integer NOT NULL CHECK (VALUE > 0);
            """, rowLimit: nil)

        // Functions: both overloads, no aggregate, no extension members; labels tell the overloads apart.
        let functions = try connection.schemaObjects(.function, schema: "public").filter { $0.name.hasPrefix(p) }
        #expect(functions.map(\.name) == ["\(p)_add", "\(p)_add", "\(p)_trgfn"])
        #expect(functions.map(\.identityArguments) == ["integer, integer", "text, text", ""])
        #expect(functions.first?.returnType == "integer")
        #expect(functions.first?.detail == "sql")
        #expect(functions.first?.attributes.contains(SchemaObjectAttribute("Volatility", "IMMUTABLE")) == true)
        let labels = SchemaObject.labels(for: functions)
        #expect(functions.map { labels[$0.id] } == ["\(p)_add(a integer, b integer)", "\(p)_add(a text, b text)", "\(p)_trgfn"])
        // Extension members are left out: plpgsql's handler belongs to the plpgsql extension.
        let catalogFunctions = try connection.schemaObjects(.function, schema: "pg_catalog").map(\.name)
        #expect(catalogFunctions.contains("lower"))
        #expect(!catalogFunctions.contains("plpgsql_call_handler"))

        let procedures = try connection.schemaObjects(.procedure, schema: "public").filter { $0.name.hasPrefix(p) }
        #expect(procedures.map(\.name) == ["\(p)_proc"])
        #expect(procedures.first?.arguments == "IN x integer, INOUT y integer")

        let triggers = try connection.schemaObjects(.trigger, schema: nil).filter { $0.name.hasPrefix(p) }
        #expect(triggers.map(\.name) == ["\(p)_trg"])
        #expect(triggers.first?.table == items)
        #expect(triggers.first?.detail == "BEFORE INSERT OR UPDATE")

        let types = try connection.schemaObjects(.type, schema: "public").filter { $0.name.hasPrefix(p) }
        #expect(types.map(\.name) == ["\(p)_mood", "\(p)_pair", "\(p)_positive"])
        #expect(types.map(\.detail) == ["enum", "composite", "domain"])
        #expect(try connection.schemaObjects(.type, schema: "public").contains { $0.name == items } == false, "a table's row type is not listed")

        // Definitions.
        let textAdd = try connection.definition(of: functions[1])
        #expect(textAdd.statement.hasPrefix("CREATE OR REPLACE FUNCTION public.\(p)_add(a text, b text)"))
        #expect(textAdd.statement.contains("BEGIN ATOMIC"))
        let procedureDefinition = try connection.definition(of: procedures[0])
        #expect(procedureDefinition.statement.hasPrefix("CREATE OR REPLACE PROCEDURE public.\(p)_proc(IN x integer, INOUT y integer)"))
        let triggerDefinition = try connection.definition(of: triggers[0])
        #expect(triggerDefinition.statement.hasPrefix("CREATE TRIGGER \(p)_trg BEFORE INSERT OR UPDATE OF qty ON public.\(items)"))
        #expect(triggerDefinition.triggerFunction?.hasPrefix("CREATE OR REPLACE FUNCTION public.\(p)_trgfn()") == true)
        #expect(triggerDefinition.canReplaceTrigger == (connection.serverVersionNumber >= 140_000))
        #expect(try connection.definition(of: types[0]).statement == "CREATE TYPE \"public\".\"\(p)_mood\" AS ENUM (\n    'sad',\n    'it''s ok',\n    'happy'\n)")
        #expect(try connection.definition(of: types[1]).statement == "CREATE TYPE \"public\".\"\(p)_pair\" AS (\n    \"left_value\" integer,\n    \"right_value\" text\n)")
        let domain = try connection.definition(of: types[2]).statement
        #expect(domain.hasPrefix("CREATE DOMAIN \"public\".\"\(p)_positive\" AS integer\n    NOT NULL\n    CONSTRAINT"))
        #expect(domain.hasSuffix("CHECK (VALUE > 0)"))

        // Edit in Query Tab scripts run as they are and leave every object in place.
        let sql = SchemaObjectSQL(kind: .postgresql)
        for object in [functions[0], functions[1], procedures[0], triggers[0]] {
            _ = try connection.execute(sql.editScript(for: object, definition: try connection.definition(of: object)), rowLimit: nil)
        }
        #expect(try connection.schemaObjects(.trigger, schema: "public").filter { $0.name.hasPrefix(p) }.count == 1)
        #expect(try connection.schemaObjects(.function, schema: "public").filter { $0.name.hasPrefix(p) }.count == 3)

        // Structure: the table's trigger and CHECK constraints.
        let tableTriggers = try connection.triggers(of: TableRef(schema: "public", name: items))
        #expect(tableTriggers.count == 1)
        #expect(tableTriggers.first?.timing == "BEFORE")
        #expect(tableTriggers.first?.events == ["INSERT", "UPDATE"])
        #expect(tableTriggers.first?.orientation == "ROW")
        #expect(tableTriggers.first?.isEnabled == true)
        #expect(tableTriggers.first?.action == "\(p)_trgfn()")
        #expect(tableTriggers.first?.condition?.contains("id > 0") == true)
        let checks = try connection.checkConstraints(of: TableRef(schema: "public", name: items))
        #expect(checks.map(\.name) == ["\(p)_note_check", "\(p)_qty_check"])
        #expect(checks.map(\.expression) == ["(note <> ''::text)", "(qty >= 0)"])
        #expect(checks.map(\.isEnforced) == [false, true])
        #expect(checks.map(\.columns) == [["note"], ["qty"]])

        // Drop removes exactly the chosen overload, the trigger and the types.
        _ = try connection.execute(try #require(sql.dropStatement(functions[0])), rowLimit: nil)
        #expect(try connection.schemaObjects(.function, schema: "public").filter { $0.name == "\(p)_add" }.map(\.identityArguments) == ["text, text"])
        for object in [triggers[0], procedures[0]] + types {
            _ = try connection.execute(try #require(sql.dropStatement(object)), rowLimit: nil)
        }
        #expect(try connection.schemaObjects(.trigger, schema: "public").filter { $0.name.hasPrefix(p) }.isEmpty)
        #expect(try connection.schemaObjects(.type, schema: "public").filter { $0.name.hasPrefix(p) }.isEmpty)
        #expect(throws: DatabaseError.self) { try connection.definition(of: functions[0]) }
    }
}

@Suite("Schema objects on MySQL", .serialized, .enabled(if: MySQLTestServer.isAvailable, "needs the MySQL test server"))
struct MySQLSchemaObjectLiveTests {
    @Test func listsDefinesEditsAndDropsObjects() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        let p = scratchPrefix()
        let items = "\(p)_items"
        defer {
            _ = try? connection.execute("""
                DROP TABLE IF EXISTS \(items);
                DROP FUNCTION IF EXISTS \(p)_add;
                DROP PROCEDURE IF EXISTS \(p)_proc;
                """, rowLimit: nil)
        }
        // One request, as the query tab sends it: the server reads the BEGIN … END bodies without DELIMITER.
        let script = """
            CREATE TABLE \(items) (id INT PRIMARY KEY, qty INT, CONSTRAINT \(p)_qty_check CHECK (qty >= 0), CONSTRAINT \(p)_id_check CHECK (id > 0) NOT ENFORCED);
            CREATE FUNCTION \(p)_add(a INT, b INT) RETURNS INT DETERMINISTIC COMMENT 'adds' RETURN a + b;
            CREATE PROCEDURE \(p)_proc(IN x INT, OUT y INT)
            BEGIN
              DECLARE i INT DEFAULT 0;
              WHILE i < 3 DO SET i = i + 1; END WHILE;
              IF x > 0 THEN SET y = x + i; ELSE SET y = 0; END IF;
            END;
            CREATE TRIGGER \(p)_trg BEFORE INSERT ON \(items) FOR EACH ROW BEGIN IF NEW.qty IS NULL THEN SET NEW.qty = 0; END IF; END;
            """
        #expect(SQLStatementSplitter.split(script, family: .mysql).count == 4)
        _ = try connection.execute(script, rowLimit: nil)

        let functions = try connection.schemaObjects(.function, schema: nil).filter { $0.name.hasPrefix(p) }
        #expect(functions.map(\.name) == ["\(p)_add"])
        #expect(functions.first?.arguments == "a int, b int")
        #expect(functions.first?.returnType == "int")
        #expect(functions.first?.schema == "foxlume")
        #expect(functions.first?.attributes.contains(SchemaObjectAttribute("Deterministic", "YES")) == true)
        let procedures = try connection.schemaObjects(.procedure, schema: nil).filter { $0.name.hasPrefix(p) }
        #expect(procedures.map(\.name) == ["\(p)_proc"])
        #expect(procedures.first?.arguments == "IN x int, OUT y int")
        let triggers = try connection.schemaObjects(.trigger, schema: "foxlume").filter { $0.name.hasPrefix(p) }
        #expect(triggers.map(\.name) == ["\(p)_trg"])
        #expect(triggers.first?.table == items)
        #expect(triggers.first?.detail == "BEFORE INSERT")
        #expect(try connection.schemaObjects(.type, schema: nil).isEmpty)
        // System routines of the sys database are not part of the current database.
        #expect(try connection.schemaObjects(.procedure, schema: nil).allSatisfy { $0.schema == "foxlume" })

        let function = try connection.definition(of: functions[0])
        #expect(function.statement.contains("FUNCTION `\(p)_add`(a INT, b INT) RETURNS int"))
        let procedure = try connection.definition(of: procedures[0])
        #expect(procedure.statement.contains("PROCEDURE `\(p)_proc`(IN x INT, OUT y INT)"))
        #expect(procedure.statement.hasSuffix("END"))
        let trigger = try connection.definition(of: triggers[0])
        #expect(trigger.statement.contains("TRIGGER `\(p)_trg` BEFORE INSERT ON `\(items)` FOR EACH ROW"))

        // Edit in Query Tab: DROP + CREATE in one request, run twice to show it replaces.
        let sql = SchemaObjectSQL(kind: .mysql)
        for object in [functions[0], procedures[0], triggers[0]] {
            let edit = sql.editScript(for: object, definition: try connection.definition(of: object))
            #expect(SQLStatementSplitter.split(edit, family: .mysql).count == 2)
            _ = try connection.execute(edit, rowLimit: nil)
            _ = try connection.execute(edit, rowLimit: nil)
        }
        _ = try connection.execute("SET @y = NULL; CALL \(p)_proc(4, @y)", rowLimit: nil)
        #expect(try connection.execute("SELECT @y", rowLimit: nil).last?.rows.first?.first?.textValue == "7")

        let tableTriggers = try connection.triggers(of: TableRef(name: items))
        #expect(tableTriggers.map(\.name) == ["\(p)_trg"])
        #expect(tableTriggers.first?.events == ["INSERT"])
        #expect(tableTriggers.first?.action.hasPrefix("BEGIN IF NEW.qty IS NULL") == true)
        let checks = try connection.checkConstraints(of: TableRef(name: items))
        #expect(checks.map(\.name) == ["\(p)_id_check", "\(p)_qty_check"])
        #expect(checks.map(\.expression) == ["(`id` > 0)", "(`qty` >= 0)"])
        #expect(checks.map(\.isEnforced) == [false, true])

        for object in [triggers[0], procedures[0], functions[0]] {
            _ = try connection.execute(try #require(sql.dropStatement(object)), rowLimit: nil)
        }
        for kind in [SchemaObjectKind.function, .procedure, .trigger] {
            #expect(try connection.schemaObjects(kind, schema: nil).filter { $0.name.hasPrefix(p) }.isEmpty)
        }
        #expect(throws: DatabaseError.self) { try connection.definition(of: functions[0]) }
    }
}

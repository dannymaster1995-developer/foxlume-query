import Foundation
import Testing
@testable import FoxlumeQueryCore

/// Scratch names for live reorder tests. Every test creates and drops its own `fq_reorder_` objects.
private func scratchName(_ label: String) -> String {
    "fq_reorder_\(label)_" + UUID().uuidString.prefix(8).lowercased()
}

/// Every row of a query as text, NULL as `∅`, one string per row.
private func lines(_ connection: DatabaseConnection, _ sql: String) throws -> [String] {
    let result = try connection.execute(sql, rowLimit: nil).last { $0.hasResultSet }
    return result?.rows.map { row in row.map { $0.textValue ?? "∅" }.joined(separator: "|") } ?? []
}

private func scalar(_ connection: DatabaseConnection, _ sql: String) throws -> String? {
    try connection.execute(sql, rowLimit: nil).last { $0.hasResultSet }?.rows.first?.first?.textValue
}

@Suite("Column reorder on PostgreSQL", .serialized, .enabled(if: PostgresTestServer.isAvailable, "needs the PostgreSQL test server"))
struct PostgresColumnReorderLiveTests {
    let generator = TableDDLGenerator(dialect: .postgresql)

    @Test func rebuildKeepsDataKeysIndexesSequencesGrantsAndComments() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let parentName = scratchName("parent")
        let name = scratchName("lines")
        let role = scratchName("reader")
        let table = TableRef(schema: "public", name: name)
        let qualified = SQLDialect.postgresql.qualifiedName(table)
        defer {
            _ = try? connection.execute("DROP TABLE IF EXISTS \(qualified), public.\"\(parentName)\"", rowLimit: nil)
            _ = try? connection.execute("DROP ROLE IF EXISTS \"\(role)\"", rowLimit: nil)
        }
        try connection.applySchemaStatements([
            "CREATE ROLE \"\(role)\"",
            "CREATE TABLE public.\"\(parentName)\" (id integer PRIMARY KEY)",
            "INSERT INTO public.\"\(parentName)\" VALUES (1), (2)",
            """
            CREATE TABLE \(qualified) (
                id bigint GENERATED ALWAYS AS IDENTITY (START WITH 10 INCREMENT BY 5) PRIMARY KEY,
                line_no serial NOT NULL,
                note varchar(20) COLLATE "C" CONSTRAINT \(name)_note_check CHECK (note <> ''),
                parent_id integer REFERENCES public."\(parentName)" (id) ON DELETE CASCADE,
                doubled bigint GENERATED ALWAYS AS (id * 2) STORED,
                code text UNIQUE
            ) WITH (fillfactor = 80)
            """,
            "CREATE INDEX \(name)_note_idx ON \(qualified) (lower(note)) WHERE note IS NOT NULL",
            "COMMENT ON TABLE \(qualified) IS 'scratch lines'",
            "COMMENT ON COLUMN \(qualified).note IS 'free text'",
            "COMMENT ON INDEX public.\(name)_note_idx IS 'partial'",
            "COMMENT ON CONSTRAINT \(name)_note_check ON \(qualified) IS 'no empty notes'",
            "INSERT INTO \(qualified) (note, parent_id, code) VALUES ('a', 1, 'x'), ('b', 2, 'y'), (NULL, NULL, 'z')",
            "GRANT SELECT, INSERT ON \(qualified) TO \"\(role)\"",
            "GRANT UPDATE (note) ON \(qualified) TO \"\(role)\"",
        ], transactional: true)

        let dataQuery = "SELECT id, line_no, note, parent_id, doubled, code FROM \(qualified) ORDER BY id"
        let indexQuery = "SELECT indexname, regexp_replace(indexdef, '^.* USING ', '') FROM pg_indexes WHERE schemaname = 'public' AND tablename = '\(name)' ORDER BY indexname"
        let constraintQuery = "SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = '\(qualified)'::regclass ORDER BY conname"
        let sequenceQuery = "SELECT pg_get_serial_sequence('\(qualified)', 'id'), pg_get_serial_sequence('\(qualified)', 'line_no')"
        let dataBefore = try lines(connection, dataQuery)
        let indexesBefore = try lines(connection, indexQuery)
        let constraintsBefore = try lines(connection, constraintQuery)
        let sequencesBefore = try lines(connection, sequenceQuery)
        #expect(dataBefore.count == 3)

        let info = try connection.tableRebuildInfo(of: table)
        #expect(info.blockers.isEmpty)
        #expect(info.columns.map(\.name) == ["id", "line_no", "note", "parent_id", "doubled", "code"])

        // code, note, then the rest in their order.
        var draft = StructureDraft(structure: try connection.structure(of: table), family: .postgresql)
        draft.moveColumns(IndexSet([5, 2]), to: 0)
        #expect(draft.columns.map(\.current.name) == ["note", "code", "id", "line_no", "parent_id", "doubled"])
        let statements = try generator.alterStatements(draft, rebuild: info)
        try connection.applySchemaStatements(statements, transactional: true)

        #expect(try lines(connection, "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '\(name)' ORDER BY ordinal_position")
                == ["note", "code", "id", "line_no", "parent_id", "doubled"])
        #expect(try lines(connection, dataQuery) == dataBefore)
        #expect(try lines(connection, indexQuery) == indexesBefore)
        #expect(try lines(connection, constraintQuery) == constraintsBefore)
        #expect(try lines(connection, sequenceQuery) == sequencesBefore)
        #expect(try scalar(connection, "SELECT attidentity FROM pg_attribute WHERE attrelid = '\(qualified)'::regclass AND attname = 'id'") == "a")
        #expect(try scalar(connection, "SELECT array_to_string(reloptions, ',') FROM pg_class WHERE oid = '\(qualified)'::regclass") == "fillfactor=80")
        #expect(try scalar(connection, "SELECT obj_description('\(qualified)'::regclass, 'pg_class')") == "scratch lines")
        #expect(try scalar(connection, "SELECT col_description('\(qualified)'::regclass, 3)") == nil)
        #expect(try scalar(connection, "SELECT col_description('\(qualified)'::regclass, attnum) FROM pg_attribute WHERE attrelid = '\(qualified)'::regclass AND attname = 'note'") == "free text")
        #expect(try scalar(connection, "SELECT obj_description('public.\(name)_note_idx'::regclass, 'pg_class')") == "partial")
        #expect(try scalar(connection, "SELECT obj_description(oid, 'pg_constraint') FROM pg_constraint WHERE conname = '\(name)_note_check'") == "no empty notes")
        #expect(try scalar(connection, "SELECT has_table_privilege('\(role)', '\(qualified)', 'INSERT')") == "t")
        #expect(try scalar(connection, "SELECT has_table_privilege('\(role)', '\(qualified)', 'UPDATE')") == "f")
        #expect(try scalar(connection, "SELECT has_column_privilege('\(role)', '\(qualified)', 'note', 'UPDATE')") == "t")
        #expect(try scalar(connection, "SELECT collation_name FROM information_schema.columns WHERE table_name = '\(name)' AND column_name = 'note'") == "C")
        if (try scalar(connection, "SHOW server_version_num")).flatMap(Int.init) ?? 0 >= 180_000 {
            #expect(try scalar(connection, "SELECT count(*) FROM pg_constraint WHERE conrelid = '\(qualified)'::regclass AND contype = 'n' AND conname = '\(name)_line_no_not_null'") == "1")
        }

        // The sequences carry on where they were, and the checks and the foreign key still hold.
        _ = try connection.execute("INSERT INTO \(qualified) (note) VALUES ('d')", rowLimit: nil)
        #expect(try lines(connection, "SELECT id, line_no, doubled FROM \(qualified) WHERE note = 'd'") == ["25|4|50"])
        #expect(throws: (any Error).self) { try connection.execute("INSERT INTO \(qualified) (note) VALUES ('')", rowLimit: nil) }
        #expect(throws: (any Error).self) { try connection.execute("INSERT INTO \(qualified) (parent_id) VALUES (99)", rowLimit: nil) }
        #expect(throws: (any Error).self) { try connection.execute("INSERT INTO \(qualified) (id) VALUES (1)", rowLimit: nil) }
        _ = try connection.execute("DELETE FROM public.\"\(parentName)\" WHERE id = 2", rowLimit: nil)
        #expect(try scalar(connection, "SELECT count(*) FROM \(qualified) WHERE code = 'y'") == "0", "ON DELETE CASCADE survives")

        // A second save moves again, renames, drops a column and adds one at the end in the same script.
        var edit = StructureDraft(structure: try connection.structure(of: table), family: .postgresql)
        edit.updateColumn(at: 0) { $0.name = "remark" }
        edit.toggleDeletion(.columns, rows: IndexSet(integer: 5))
        edit.moveColumns(IndexSet(integer: 0), to: 4)
        edit.addColumn(ColumnDefinition(name: "qty", dataType: "integer", isNullable: false, defaultValue: "1"))
        try connection.applySchemaStatements(try generator.alterStatements(edit, rebuild: try connection.tableRebuildInfo(of: table)), transactional: true)
        #expect(try lines(connection, "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '\(name)' ORDER BY ordinal_position")
                == ["code", "id", "line_no", "remark", "parent_id", "qty"])
        #expect(try lines(connection, "SELECT id, remark, qty FROM \(qualified) ORDER BY id") == ["10|a|1", "20|∅|1", "25|d|1"])
        #expect(try scalar(connection, "SELECT pg_get_indexdef('public.\(name)_note_idx'::regclass)")?.contains("lower((remark)::text)") == true)
    }

    @Test func dependentObjectsBlockTheRebuild() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let name = scratchName("base")
        let child = scratchName("child")
        let view = scratchName("view")
        let function = scratchName("touch")
        let table = TableRef(schema: "public", name: name)
        defer {
            _ = try? connection.execute("DROP VIEW IF EXISTS public.\"\(view)\"; DROP TABLE IF EXISTS public.\"\(child)\", public.\"\(name)\"; DROP FUNCTION IF EXISTS public.\"\(function)\"()", rowLimit: nil)
        }
        try connection.applySchemaStatements([
            "CREATE TABLE public.\"\(name)\" (id integer PRIMARY KEY, label text)",
            "CREATE TABLE public.\"\(child)\" (id integer PRIMARY KEY, base_id integer REFERENCES public.\"\(name)\" (id))",
            "CREATE VIEW public.\"\(view)\" AS SELECT label FROM public.\"\(name)\"",
            "CREATE FUNCTION public.\"\(function)\"() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$",
            "CREATE TRIGGER audit BEFORE INSERT ON public.\"\(name)\" FOR EACH ROW EXECUTE FUNCTION public.\"\(function)\"()",
        ], transactional: true)

        let info = try connection.tableRebuildInfo(of: table)
        #expect(info.blockers == [
            "views depend on it (\(view))",
            "other tables reference it with foreign keys (\(child) (\(child)_base_id_fkey))",
            "it has triggers (audit)",
        ])
        var draft = StructureDraft(structure: try connection.structure(of: table), family: .postgresql)
        draft.moveColumns(IndexSet(integer: 1), to: 0)
        #expect(throws: StructureChangeError.self) { try generator.alterStatements(draft, rebuild: info) }

        // Without them the table can be rebuilt.
        _ = try connection.execute("DROP VIEW public.\"\(view)\"; DROP TABLE public.\"\(child)\"; DROP TRIGGER audit ON public.\"\(name)\"", rowLimit: nil)
        let clear = try connection.tableRebuildInfo(of: table)
        #expect(clear.blockers.isEmpty)
        try connection.applySchemaStatements(try generator.alterStatements(draft, rebuild: clear), transactional: true)
        #expect(try connection.structure(of: table).columns.map(\.name) == ["label", "id"])
    }
}

@Suite("Column reorder on MySQL", .serialized, .enabled(if: MySQLTestServer.isAvailable, "needs the MySQL test server"))
struct MySQLColumnReorderLiveTests {
    let generator = TableDDLGenerator(dialect: .mysql)

    @Test func movedColumnsKeepTheirWholeDefinitionDataAndIndexes() throws {
        let connection = try MySQLTestServer.connect(ssl: .disable)
        defer { connection.close() }
        let name = scratchName("items")
        let table = TableRef(name: name)
        defer { _ = try? connection.execute("DROP TABLE IF EXISTS `\(name)`", rowLimit: nil) }
        try connection.applySchemaStatements([
            """
            CREATE TABLE `\(name)` (
                id int NOT NULL AUTO_INCREMENT PRIMARY KEY,
                name varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL DEFAULT 'x' COMMENT 'display name',
                touched timestamp NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                qty int NOT NULL DEFAULT 1,
                doubled int GENERATED ALWAYS AS (qty * 2) VIRTUAL,
                token char(36) DEFAULT (uuid()),
                KEY \(name)_name_idx (name)
            ) COMMENT = 'scratch items'
            """,
            "INSERT INTO `\(name)` (name, qty, token) VALUES ('a', 2, 't1'), ('b', 3, 't2')",
            "DELETE FROM `\(name)` WHERE name = 'b'",
            "INSERT INTO `\(name)` (name, qty, token) VALUES ('c', 4, 't3')",
        ], transactional: false)

        let detailQuery = """
            SELECT column_name, column_type, is_nullable, IFNULL(column_default, '∅'), extra, IFNULL(collation_name, '∅'),
                   column_comment, generation_expression
            FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = '\(name)' ORDER BY column_name
            """
        let dataQuery = "SELECT id, name, qty, doubled, token FROM `\(name)` ORDER BY id"
        let detailsBefore = try lines(connection, detailQuery)
        let dataBefore = try lines(connection, dataQuery)

        // qty first, name last, id after touched: three moves for six columns.
        var draft = StructureDraft(structure: try connection.structure(of: table), family: .mysql)
        draft.moveColumns(IndexSet(integer: 3), to: 0)
        draft.moveColumns(IndexSet(integer: 2), to: 6)
        draft.moveColumns(IndexSet(integer: 1), to: 3)
        #expect(draft.columns.map(\.current.name) == ["qty", "touched", "id", "doubled", "token", "name"])
        let statements = try generator.alterStatements(draft)
        #expect(statements.count == 1)
        #expect(statements.first?.components(separatedBy: "MODIFY COLUMN").count == 4)
        try connection.applySchemaStatements(statements, transactional: false)

        #expect(try lines(connection, "SELECT column_name FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = '\(name)' ORDER BY ordinal_position")
                == ["qty", "touched", "id", "doubled", "token", "name"])
        #expect(try lines(connection, detailQuery) == detailsBefore)
        #expect(try lines(connection, dataQuery) == dataBefore)
        let structure = try connection.structure(of: table)
        #expect(structure.indexes.contains { $0.name == "\(name)_name_idx" && $0.columns == ["name"] })
        #expect(structure.primaryKey == ["id"])
        #expect(structure.comment == "scratch items")
        _ = try connection.execute("INSERT INTO `\(name)` (name) VALUES ('d')", rowLimit: nil)
        #expect(try scalar(connection, "SELECT id FROM `\(name)` WHERE name = 'd'") == "4", "AUTO_INCREMENT carries on")

        // Moving back with a type change and a new column in the middle.
        var back = StructureDraft(structure: structure, family: .mysql)
        back.updateColumn(at: 0) { $0.dataType = "bigint" }
        back.moveColumns(IndexSet([2, 5]), to: 0)
        let added = back.addColumn(ColumnDefinition(name: "note", dataType: "varchar(10)"))
        back.moveColumns(IndexSet(integer: added), to: 2)
        try connection.applySchemaStatements(try generator.alterStatements(back), transactional: false)
        #expect(try lines(connection, "SELECT column_name, column_type FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = '\(name)' ORDER BY ordinal_position")
                == ["id|int", "name|varchar(50)", "note|varchar(10)", "qty|bigint", "touched|timestamp", "doubled|int", "token|char(36)"])
    }
}

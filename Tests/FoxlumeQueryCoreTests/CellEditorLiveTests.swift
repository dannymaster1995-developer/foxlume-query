import Foundation
import Testing
@testable import FoxlumeQueryCore

/// The cell editors against the local test servers: each column gets the right editor from the structure the driver
/// reads, the values the editors write save and load back unchanged, and the foreign key picker finds referenced rows.
/// Scratch `fq_cell_` tables are dropped again by every test.
private func scratchName() -> String {
    "fq_cell_" + UUID().uuidString.prefix(8).lowercased()
}

/// Stages `values` (column name to new value) on row 0 of `table`, saves them as the grid would, and returns row 0
/// read back.
private func saveRowZero(_ connection: DatabaseConnection, _ table: TableRef, _ values: [String: CellValue]) throws -> [String: CellValue] {
    let page = try connection.fetchRows(TableQuery(table: table, sort: [SortKey(column: "id", ascending: true)], pageSize: 10))
    var changes = PendingChanges()
    for (name, value) in values {
        let column = try #require(page.columns.firstIndex { $0.name == name })
        changes.setValue(value, row: 0, column: column, original: page.rows[0][column])
    }
    try connection.applyChanges(ChangeBatch(table: table, columns: page.columns, primaryKey: ["id"], originalRows: page.rows, changes: changes))
    let reloaded = try connection.fetchRows(TableQuery(table: table, sort: [SortKey(column: "id", ascending: true)], pageSize: 10))
    return Dictionary(uniqueKeysWithValues: zip(reloaded.columns.map(\.name), reloaded.rows[0]))
}

@Suite("Cell editors on PostgreSQL", .serialized, .enabled(if: PostgresTestServer.isAvailable, "needs the PostgreSQL test server"))
struct PostgresCellEditorLiveTests {
    @Test func editorsAndRoundTrip() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let name = scratchName()
        let parent = name + "_p"
        let mood = name + "_mood"
        defer { _ = try? connection.execute("DROP TABLE IF EXISTS \(name); DROP TABLE IF EXISTS \(parent); DROP TYPE IF EXISTS \(mood)", rowLimit: nil) }
        _ = try connection.execute("CREATE TYPE \(mood) AS ENUM ('sad', 'it''s ok', 'happy')", rowLimit: nil)
        // Before PostgreSQL 12, ADD VALUE cannot share a transaction (or a multi-statement query) with other statements.
        _ = try connection.execute("ALTER TYPE \(mood) ADD VALUE 'meh' BEFORE 'it''s ok'", rowLimit: nil)
        _ = try connection.execute("""
            CREATE TABLE \(parent) (id integer PRIMARY KEY, code integer, title text);
            INSERT INTO \(parent) VALUES (1, 10, 'Alpha'), (2, 20, 'Beta'), (3, 30, 'Gamma_1');
            CREATE TABLE \(name) (id integer PRIMARY KEY, flag boolean, born date, at_local timestamp(6), at_zone timestamptz,
                                  clock time, feeling \(mood) NOT NULL DEFAULT 'sad', parent_id integer REFERENCES \(parent)(id), note text);
            INSERT INTO \(name) VALUES (1, true, '2024-03-05', '2024-03-05 14:07:09.123456', '2024-03-05 14:07:09.5+00', '08:30:00', 'happy', 1, 'x');
            """, rowLimit: nil)
        _ = try connection.execute("SET TIME ZONE 'UTC'", rowLimit: nil)
        let table = TableRef(schema: "public", name: name)
        let structure = try connection.structure(of: table)
        func editor(_ column: String) throws -> CellEditorKind {
            CellEditorKind.classify(try #require(structure.columns.first { $0.name == column }), kind: .postgresql)
        }
        #expect(try editor("flag") == .boolean(.letters))
        #expect(try editor("born") == .temporal(.date))
        #expect(try editor("at_local") == .temporal(.timestamp(withTimeZone: false)))
        #expect(try editor("at_zone") == .temporal(.timestamp(withTimeZone: true)))
        #expect(try editor("clock") == .temporal(.time(withTimeZone: false)))
        #expect(try editor("feeling") == .choice(["sad", "meh", "it's ok", "happy"]), "labels in sort order")
        #expect(try editor("note") == .text)
        #expect(ReferencePicker.foreignKey(forColumn: "parent_id", in: structure)?.referencedTable.name == parent)

        // What the editors write: the toggled spelling, a picked date with fraction and zone kept, a label, a key.
        let atLocal = try #require(TemporalText.parse("2024-03-05 14:07:09.123456", kind: .timestamp(withTimeZone: false)))
        let atZone = try #require(TemporalText.parse("2024-03-05 14:07:09.5+00", kind: .timestamp(withTimeZone: true)))
        let newDay = TemporalText.Day(year: 2025, month: 1, day: 31)
        let saved = try saveRowZero(connection, table, [
            "flag": .text(BooleanStyle.letters.text(false)),
            "born": .text("2025-01-31"),
            "at_local": .text(atLocal.replacing(day: newDay, clock: atLocal.clock).text),
            "at_zone": .text(atZone.replacing(day: newDay, clock: atZone.clock).text),
            "clock": .text("23:59:30"),
            "feeling": .text("it's ok"),
            "parent_id": .text("3"),
        ])
        #expect(saved["flag"] == .text("f"))
        #expect(saved["born"] == .text("2025-01-31"))
        #expect(saved["at_local"] == .text("2025-01-31 14:07:09.123456"))
        #expect(saved["at_zone"] == .text("2025-01-31 14:07:09.5+00"))
        #expect(saved["clock"] == .text("23:59:30"))
        #expect(saved["feeling"] == .text("it's ok"))
        #expect(saved["parent_id"] == .text("3"))
        let cleared = try saveRowZero(connection, table, ["flag": .null, "at_zone": .null, "parent_id": .null])
        #expect(cleared["flag"] == .null && cleared["at_zone"] == .null && cleared["parent_id"] == .null)

        // The foreign key picker: first rows by key, then a search on key or label.
        let parentStructure = try connection.structure(of: TableRef(schema: "public", name: parent))
        let label = ReferenceCandidates.labelColumn(in: parentStructure, key: "id")
        #expect(label == "title")
        let all = try connection.referenceCandidates(ReferenceCandidateRequest(table: TableRef(schema: "public", name: parent), keyColumn: "id", labelColumn: label))
        #expect(all.map(\.key) == [.text("1"), .text("2"), .text("3")])
        #expect(all.first?.label == "Alpha")
        let searched = try connection.referenceCandidates(ReferenceCandidateRequest(table: TableRef(schema: "public", name: parent), keyColumn: "id", labelColumn: label, search: "a_1"))
        #expect(searched.map(\.label) == ["Gamma_1"], "the underscore is literal")
        let byKey = try connection.referenceCandidates(ReferenceCandidateRequest(table: TableRef(schema: "public", name: parent), keyColumn: "id", labelColumn: label, search: "2", limit: 1))
        #expect(byKey.map(\.key) == [.text("2")])
    }
}

@Suite("Cell editors on MySQL", .serialized, .enabled(if: MySQLTestServer.isAvailable, "needs the MySQL test server"))
struct MySQLCellEditorLiveTests {
    @Test func editorsAndRoundTrip() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        let name = scratchName()
        let parent = name + "_p"
        defer { _ = try? connection.execute("DROP TABLE IF EXISTS \(name)", rowLimit: nil); _ = try? connection.execute("DROP TABLE IF EXISTS \(parent)", rowLimit: nil) }
        _ = try connection.execute("CREATE TABLE \(parent) (id int PRIMARY KEY, title varchar(40))", rowLimit: nil)
        _ = try connection.execute("INSERT INTO \(parent) VALUES (1, 'Alpha'), (2, 'Beta'), (3, 'Gamma_1')", rowLimit: nil)
        _ = try connection.execute("""
            CREATE TABLE \(name) (id int PRIMARY KEY, flag tinyint(1), active BOOLEAN NOT NULL DEFAULT 0, born date, at_local datetime(6),
                                  stamp timestamp NULL, clock time, size enum('small','it''s medium','large') NULL, tags set('a','b'),
                                  parent_id int, CONSTRAINT \(name)_fk FOREIGN KEY (parent_id) REFERENCES \(parent)(id))
            """, rowLimit: nil)
        _ = try connection.execute("INSERT INTO \(name) VALUES (1, 1, 1, '2024-03-05', '2024-03-05 14:07:09.123456', '2024-03-05 14:07:09', '08:30:00', 'large', 'a', 1)", rowLimit: nil)
        let table = TableRef(name: name)
        let structure = try connection.structure(of: table)
        func editor(_ column: String) throws -> CellEditorKind {
            CellEditorKind.classify(try #require(structure.columns.first { $0.name == column }), kind: .mysql)
        }
        #expect(try editor("flag") == .boolean(.numeric))
        #expect(try editor("active") == .boolean(.numeric), "BOOLEAN is tinyint(1)")
        #expect(try editor("born") == .temporal(.date))
        #expect(try editor("at_local") == .temporal(.timestamp(withTimeZone: false)))
        #expect(try editor("stamp") == .temporal(.timestamp(withTimeZone: false)))
        #expect(try editor("clock") == .temporal(.time(withTimeZone: false)))
        #expect(try editor("size") == .choice(["small", "it's medium", "large"]))
        #expect(try editor("tags") == .text)
        #expect(ReferencePicker.foreignKey(forColumn: "parent_id", in: structure)?.referencedColumns == ["id"])

        let atLocal = try #require(TemporalText.parse("2024-03-05 14:07:09.123456", kind: .timestamp(withTimeZone: false)))
        let saved = try saveRowZero(connection, table, [
            "flag": .text(BooleanStyle.numeric.text(false)),
            "active": .text(BooleanStyle.numeric.text(false)),
            "at_local": .text(atLocal.replacing(day: TemporalText.Day(year: 2025, month: 1, day: 31), clock: atLocal.clock).text),
            "stamp": .text("2025-01-31 23:00:00"),
            "size": .text("it's medium"),
            "parent_id": .text("3"),
        ])
        #expect(saved["flag"] == .text("0"))
        #expect(saved["active"] == .text("0"))
        #expect(saved["at_local"] == .text("2025-01-31 14:07:09.123456"))
        #expect(saved["stamp"] == .text("2025-01-31 23:00:00"))
        #expect(saved["size"] == .text("it's medium"))
        #expect(saved["parent_id"] == .text("3"))
        let cleared = try saveRowZero(connection, table, ["size": .null, "flag": .null])
        #expect(cleared["size"] == .null && cleared["flag"] == .null)

        let parentStructure = try connection.structure(of: TableRef(name: parent))
        let label = ReferenceCandidates.labelColumn(in: parentStructure, key: "id")
        #expect(label == "title")
        let searched = try connection.referenceCandidates(ReferenceCandidateRequest(table: TableRef(name: parent), keyColumn: "id", labelColumn: label, search: "BETA"))
        #expect(searched == [ReferenceCandidate(key: .text("2"), label: "Beta")])
        let all = try connection.referenceCandidates(ReferenceCandidateRequest(table: TableRef(name: parent), keyColumn: "id", labelColumn: label, limit: 2))
        #expect(all.map(\.key) == [.text("1"), .text("2")])
    }
}

@Suite("Cell editors on SQLite")
struct LocalCellEditorTests {
    @Test func sqliteBooleanAndDates() throws {
        let url = TestFiles.url("fq_cell_\(UUID().uuidString).sqlite")
        defer { TestFiles.removeDatabase(url) }
        let connection = SQLiteConnection(parameters: ConnectionParameters(config: ConnectionConfig(kind: .sqlite, filePath: url.path), password: ""))
        try connection.connect()
        defer { connection.close() }
        _ = try connection.execute("CREATE TABLE p (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO p VALUES (1, 'one'), (2, 'two')", rowLimit: nil)
        _ = try connection.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, flag BOOLEAN, born DATE, p_id INTEGER REFERENCES p(id)); INSERT INTO t VALUES (1, 1, '2024-03-05', 1)", rowLimit: nil)
        let structure = try connection.structure(of: TableRef(name: "t"))
        #expect(CellEditorKind.classify(try #require(structure.columns.first { $0.name == "flag" }), kind: .sqlite) == .boolean(.numeric))
        #expect(CellEditorKind.classify(try #require(structure.columns.first { $0.name == "born" }), kind: .sqlite) == .temporal(.date))
        let saved = try saveRowZero(connection, TableRef(name: "t"), ["flag": .text("0"), "born": .text("2025-01-31")])
        #expect(saved["flag"] == .text("0"))
        #expect(saved["born"] == .text("2025-01-31"))
        let candidates = try connection.referenceCandidates(ReferenceCandidateRequest(table: TableRef(name: "p"), keyColumn: "id", labelColumn: "name", search: "TW"))
        #expect(candidates == [ReferenceCandidate(key: .text("2"), label: "two")])
    }
}

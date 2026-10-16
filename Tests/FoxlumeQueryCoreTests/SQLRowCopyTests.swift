import Foundation
import Testing
@testable import FoxlumeQueryCore

/// "Copy As ▸ IN List" and "Copy As ▸ SQL UPDATE" from the grid's cell menu.
@Suite struct SQLRowCopyTests {
    static let dialects: [(SQLDialect, String)] = [(.postgresql, "PostgreSQL"), (.mysql, "MySQL"), (.sqlite, "SQLite"), (.duckdb, "DuckDB")]

    let id = ResultColumn(name: "id", typeName: "int4", isNumeric: true)
    let name = ResultColumn(name: "name", typeName: "text")

    // MARK: IN list

    @Test func inListOfNumbersKeepsOrderDropsDuplicatesAndNulls() {
        for (dialect, label) in Self.dialects {
            let list = SQLRowCopy.inList([.text("3"), .null, .text("1"), .text("3"), .missing, .text("2.5")], column: id, dialect: dialect)
            #expect(list == "(3, 1, 2.5)", "\(label)")
        }
    }

    @Test func inListQuotesTextPerDialect() {
        let values: [CellValue] = [.text("O'Brien"), .text(#"C:\temp"#), .text("O'Brien"), .text("")]
        #expect(SQLRowCopy.inList(values, column: name, dialect: .postgresql) == #"('O''Brien', 'C:\temp', '')"#)
        #expect(SQLRowCopy.inList(values, column: name, dialect: .sqlite) == #"('O''Brien', 'C:\temp', '')"#)
        #expect(SQLRowCopy.inList(values, column: name, dialect: .duckdb) == #"('O''Brien', 'C:\temp', '')"#)
        #expect(SQLRowCopy.inList(values, column: name, dialect: .mysql) == #"('O''Brien', 'C:\\temp', '')"#)
    }

    @Test func inListOfOnlyNullsIsNil() {
        #expect(SQLRowCopy.inList([.null, .missing], column: name, dialect: .postgresql) == nil)
        #expect(SQLRowCopy.inList([], column: id, dialect: .mysql) == nil)
    }

    @Test func inListNumbersOfTextColumnsStayQuotedAndBooleansAndBinaryUseTheDialect() {
        #expect(SQLRowCopy.inList([.text("007"), .text("12")], column: name, dialect: .postgresql) == "('007', '12')")
        let flag = ResultColumn(name: "flag", typeName: "bool")
        #expect(SQLRowCopy.inList([.text("t"), .text("f"), .text("t")], column: flag, dialect: .postgresql) == "('t', 'f')")
        let blob = ResultColumn(name: "data", typeName: "bytea")
        let bytes: [CellValue] = [.bytes(Data([0x01, 0xAB])), .bytes(Data([0x01, 0xAB]))]
        #expect(SQLRowCopy.inList(bytes, column: blob, dialect: .postgresql) == "(decode('01ab', 'hex'))")
        #expect(SQLRowCopy.inList(bytes, column: blob, dialect: .mysql) == "(X'01ab')")
        #expect(SQLRowCopy.inList(bytes, column: blob, dialect: .sqlite) == "(X'01ab')")
        #expect(SQLRowCopy.inList(bytes, column: blob, dialect: .duckdb) == "(from_hex('01ab'))")
    }

    // MARK: UPDATE

    @Test func updatePerDialectSetsEveryNonKeyColumn() {
        let columns = [id, name, ResultColumn(name: "score", typeName: "numeric", isNumeric: true), ResultColumn(name: "note", typeName: "text")]
        let rows = [
            SQLRowCopy.UpdateRow(current: [.text("1"), .text("it's"), .text("2.5"), .null], original: [.text("1"), .text("it's"), .text("2.5"), .null]),
            SQLRowCopy.UpdateRow(current: [.text("2"), .text(#"a\b"#), .null, .text("x")], original: [.text("2"), .text("old"), .null, .text("x")]),
        ]
        let table = TableRef(schema: "public", name: "people")
        #expect(SQLRowCopy.updates(table: table, columns: columns, primaryKey: ["id"], rows: rows, dialect: .postgresql) == """
        UPDATE "public"."people" SET "name" = 'it''s', "score" = 2.5, "note" = NULL WHERE "id" = 1;
        UPDATE "public"."people" SET "name" = 'a\\b', "score" = NULL, "note" = 'x' WHERE "id" = 2;

        """)
        #expect(SQLRowCopy.updates(table: TableRef(name: "people"), columns: columns, primaryKey: ["id"], rows: rows, dialect: .mysql) == """
        UPDATE `people` SET `name` = 'it''s', `score` = 2.5, `note` = NULL WHERE `id` = 1;
        UPDATE `people` SET `name` = 'a\\\\b', `score` = NULL, `note` = 'x' WHERE `id` = 2;

        """)
        for dialect in [SQLDialect.sqlite, .duckdb] {
            #expect(SQLRowCopy.updates(table: TableRef(name: "people"), columns: columns, primaryKey: ["id"], rows: rows, dialect: dialect) == """
            UPDATE "people" SET "name" = 'it''s', "score" = 2.5, "note" = NULL WHERE "id" = 1;
            UPDATE "people" SET "name" = 'a\\b', "score" = NULL, "note" = 'x' WHERE "id" = 2;

            """)
        }
    }

    @Test func updateWithCompositeKeyMatchesTheLoadedKeyAndSetsAnEditedKeyColumn() {
        let columns = [ResultColumn(name: "order_id", isNumeric: true), ResultColumn(name: "line", isNumeric: true), ResultColumn(name: "sku")]
        let unchanged = SQLRowCopy.UpdateRow(current: [.text("7"), .text("1"), .text("A-1")], original: [.text("7"), .text("1"), .text("A-1")])
        let rekeyed = SQLRowCopy.UpdateRow(current: [.text("7"), .text("3"), .text("B")], original: [.text("7"), .text("2"), .text("B")])
        let sql = SQLRowCopy.updates(table: TableRef(name: "lines"), columns: columns, primaryKey: ["order_id", "line"], rows: [unchanged, rekeyed], dialect: .mysql)
        #expect(sql == """
        UPDATE `lines` SET `sku` = 'A-1' WHERE `order_id` = 7 AND `line` = 1;
        UPDATE `lines` SET `line` = 3, `sku` = 'B' WHERE `order_id` = 7 AND `line` = 2;

        """)
    }

    @Test func updateWritesBinaryBooleansAndExpressionsAsInsertCopyDoes() {
        let columns = [id, ResultColumn(name: "flag", typeName: "bool"), ResultColumn(name: "data", typeName: "bytea"), ResultColumn(name: "touched")]
        let row = SQLRowCopy.UpdateRow(
            current: [.text("1"), .text("t"), .bytes(Data([0xDE, 0xAD])), .expression("CURRENT_TIMESTAMP")],
            original: [.text("1"), .text("f"), .bytes(Data()), .null]
        )
        let pg = SQLRowCopy.updates(table: TableRef(name: "t"), columns: columns, primaryKey: ["id"], rows: [row], dialect: .postgresql)
        #expect(pg == "UPDATE \"t\" SET \"flag\" = 't', \"data\" = decode('dead', 'hex'), \"touched\" = CURRENT_TIMESTAMP WHERE \"id\" = 1;\n")
        let duck = SQLRowCopy.updates(table: TableRef(name: "t"), columns: columns, primaryKey: ["id"], rows: [row], dialect: .duckdb)
        #expect(duck.contains("\"data\" = from_hex('dead')"))
        let insert = ResultExporter.export(columns: columns, rows: [row.current], format: .sqlInsert, tableName: "t", dialect: .postgresql)
        #expect(insert == "INSERT INTO \"t\" (\"id\", \"flag\", \"data\", \"touched\") VALUES (1, 't', decode('dead', 'hex'), CURRENT_TIMESTAMP);\n")
    }

    @Test func updateKeyThatWasNullUsesIsNull() {
        let columns = [ResultColumn(name: "code"), name]
        let row = SQLRowCopy.UpdateRow(current: [.null, .text("x")], original: [.null, .text("y")])
        #expect(SQLRowCopy.updates(table: TableRef(name: "t"), columns: columns, primaryKey: ["code"], rows: [row], dialect: .sqlite)
            == "UPDATE \"t\" SET \"name\" = 'x' WHERE \"code\" IS NULL;\n")
    }

    @Test func updateIsUnavailableWithoutAUsableKey() {
        #expect(SQLRowCopy.updateUnavailableReason(columns: ["id", "name"], primaryKey: ["id"]) == nil)
        #expect(SQLRowCopy.updateUnavailableReason(columns: ["id", "name"], primaryKey: [])?.contains("no primary key") == true)
        #expect(SQLRowCopy.updateUnavailableReason(columns: ["name"], primaryKey: ["id"])?.contains("“id”") == true)
        #expect(SQLRowCopy.updateUnavailableReason(columns: ["a", "b"], primaryKey: ["a", "b"])?.contains("nothing to set") == true)
        let row = SQLRowCopy.UpdateRow(current: [.text("1")], original: [.text("1")])
        #expect(SQLRowCopy.updates(table: TableRef(name: "t"), columns: [id], primaryKey: [], rows: [row], dialect: .postgresql) == "")
    }

    // MARK: Running the copied SQL

    @Test func copiedSQLRunsOnSQLite() async throws {
        let url = TestFiles.url("eq-copy-\(UUID().uuidString).sqlite")
        defer { TestFiles.removeDatabase(url) }
        let session = DatabaseSession(parameters: ConnectionParameters(config: ConnectionConfig(kind: .sqlite, filePath: url.path), password: ""))
        try await session.connect()
        try await Self.roundTrip(session, dialect: .sqlite, create: "CREATE TABLE copy_probe (a INTEGER, b TEXT, note TEXT, data BLOB, PRIMARY KEY (a, b))")
    }

    @Test func copiedSQLRunsOnDuckDB() async throws {
        let session = try await DuckDBTests.open()
        try await Self.roundTrip(session, dialect: .duckdb, create: "CREATE TABLE copy_probe (a INTEGER, b VARCHAR, note VARCHAR, flag BOOLEAN, PRIMARY KEY (a, b))")
    }

    /// Edits row 1 of `copy_probe` (composite key a, b), runs its copied UPDATE and checks the stored row, then finds
    /// the rows again through copied IN lists.
    /// Closes the session afterwards.
    static func roundTrip(_ session: DatabaseSession, dialect: SQLDialect, create: String) async throws {
        do {
            try await checkRoundTrip(session, dialect: dialect, create: create)
        } catch {
            await session.close()
            throw error
        }
        await session.close()
    }

    private static func checkRoundTrip(_ session: DatabaseSession, dialect: SQLDialect, create: String) async throws {
        _ = try await session.execute(create)
        let hasFlag = create.contains("flag")
        let hasData = create.contains("data")
        let extra = (hasFlag ? ", false" : "") + (hasData ? ", X'0102'" : "")
        _ = try await session.execute("INSERT INTO copy_probe VALUES (1, 'x''y', 'old'\(extra)), (2, 'z', NULL\(extra))")
        let loaded = try await session.execute("SELECT * FROM copy_probe ORDER BY a")[0]
        var current = loaded.rows[0]
        current[2] = .text(#"it's a \ test"#)
        if hasFlag { current[3] = .text("true") }
        if hasData { current[3] = .bytes(Data([0xCA, 0xFE])) }
        let sql = SQLRowCopy.updates(table: TableRef(name: "copy_probe"), columns: loaded.columns, primaryKey: ["a", "b"],
                                     rows: [SQLRowCopy.UpdateRow(current: current, original: loaded.rows[0])], dialect: dialect)
        _ = try await session.execute(sql)
        let stored = try await session.execute("SELECT * FROM copy_probe ORDER BY a")[0].rows
        #expect(stored[0] == current)
        #expect(stored[1] == loaded.rows[1])

        let keys = try #require(SQLRowCopy.inList(stored.map { $0[0] }, column: loaded.columns[0], dialect: dialect))
        let names = try #require(SQLRowCopy.inList(stored.map { $0[1] } + [.null], column: loaded.columns[1], dialect: dialect))
        let found = try await session.execute("SELECT COUNT(*) FROM copy_probe WHERE a IN \(keys) AND b IN \(names)")[0].rows
        #expect(found.first?.first?.displayString == "2")
    }
}

extension SQLRowCopyTests {
    /// The live PostgreSQL and MySQL check: `copy_probe` has a composite key (a, b) and the columns note, flag and
    /// score. Row 1 is edited as the grid would hold it; the UPDATE copied for both rows must store exactly that.
    static func liveRoundTrip(_ connection: DatabaseConnection, dialect: SQLDialect, trueText: String) throws {
        _ = try connection.execute("INSERT INTO copy_probe VALUES (1, 'x''y', 'old', false, 1.50), (2, 'z', NULL, true, NULL)", rowLimit: nil)
        let loaded = try connection.execute("SELECT * FROM copy_probe ORDER BY a", rowLimit: nil)[0]
        var edited = loaded.rows[0]
        edited[2] = .text(#"it's a \ test"#)
        edited[3] = .text(trueText)
        edited[4] = .text("2.25")
        let rows = [SQLRowCopy.UpdateRow(current: edited, original: loaded.rows[0]), SQLRowCopy.UpdateRow(current: loaded.rows[1], original: loaded.rows[1])]
        let sql = SQLRowCopy.updates(table: TableRef(name: "copy_probe"), columns: loaded.columns, primaryKey: ["a", "b"], rows: rows, dialect: dialect)
        #expect(sql.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 2)
        _ = try connection.execute(sql, rowLimit: nil)
        let stored = try connection.execute("SELECT * FROM copy_probe ORDER BY a", rowLimit: nil)[0].rows
        #expect(stored == [edited, loaded.rows[1]])

        let names = try #require(SQLRowCopy.inList(stored.map { $0[1] }, column: loaded.columns[1], dialect: dialect))
        let notes = try #require(SQLRowCopy.inList(stored.map { $0[2] }, column: loaded.columns[2], dialect: dialect))
        let scores = try #require(SQLRowCopy.inList(stored.map { $0[4] }, column: loaded.columns[4], dialect: dialect))
        #expect(scores == "(2.25)")
        let found = try connection.execute("SELECT a FROM copy_probe WHERE b IN \(names) AND (note IN \(notes) OR score IN \(scores)) ORDER BY a", rowLimit: nil)[0]
        #expect(found.rows.map { $0[0].displayString } == ["1"])
    }
}

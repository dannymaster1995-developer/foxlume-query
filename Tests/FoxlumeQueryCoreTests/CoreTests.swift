import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct SQLDialectTests {
    @Test func quotesIdentifiersPerEngine() {
        #expect(SQLDialect.postgresql.quoteIdentifier("we\"ird") == "\"we\"\"ird\"")
        #expect(SQLDialect.mysql.quoteIdentifier("we`ird") == "`we``ird`")
        #expect(SQLDialect.postgresql.qualifiedName(TableRef(schema: "shop", name: "products")) == "\"shop\".\"products\"")
    }

    @Test func quotesStringsPerEngine() {
        #expect(SQLDialect.postgresql.quoteString("it's \\ ok") == "'it''s \\ ok'")
        #expect(SQLDialect.mysql.quoteString("it's \\ ok") == "'it''s \\\\ ok'")
        #expect(SQLDialect(family: .mysql, backslashEscapes: false).quoteString("a\\b") == "'a\\b'")
    }

    @Test func literalsForBytesAndNull() {
        #expect(SQLDialect.postgresql.literal(.bytes(Data([0xde, 0xad]))) == "decode('dead', 'hex')")
        #expect(SQLDialect.mysql.literal(.bytes(Data([0x01]))) == "X'01'")
        #expect(SQLDialect.sqlite.literal(.null) == "NULL")
    }
}

@Suite struct SplitterTests {
    @Test func splitsOnSemicolonsOutsideQuotesAndComments() {
        let sql = "SELECT ';' AS a; -- comment; here\nSELECT \"x;y\" FROM t /* ; */;\n\nSELECT 3"
        let parts = SQLStatementSplitter.split(sql, family: .postgresql).map(\.text)
        #expect(parts == ["SELECT ';' AS a", "-- comment; here\nSELECT \"x;y\" FROM t /* ; */", "SELECT 3"])
    }

    @Test func respectsDollarQuoting() {
        let sql = "CREATE FUNCTION f() RETURNS int AS $body$ SELECT 1; $body$ LANGUAGE sql; SELECT f()"
        let parts = SQLStatementSplitter.split(sql, family: .postgresql)
        #expect(parts.count == 2)
        #expect(parts[1].text == "SELECT f()")
    }

    @Test func mysqlBackslashAndHashComments() {
        let sql = "SELECT 'a\\';b'; # skip; this\nSELECT 2"
        let parts = SQLStatementSplitter.split(sql, family: .mysql).map(\.text)
        #expect(parts == ["SELECT 'a\\';b'", "# skip; this\nSELECT 2"])
    }

    @Test func dropsCommentOnlyStatements() {
        #expect(SQLStatementSplitter.split("-- only a comment\n;  ; SELECT 1", family: .sqlite).map(\.text) == ["SELECT 1"])
    }

    @Test func findsStatementAtCursor() {
        let sql = "SELECT 1;\nSELECT 2;\nSELECT 3"
        let location = (sql as NSString).range(of: "2").location
        #expect(SQLStatementSplitter.statement(at: location, in: sql, family: .postgresql)?.text == "SELECT 2")
        #expect(SQLStatementSplitter.statement(at: (sql as NSString).length, in: sql, family: .postgresql)?.text == "SELECT 3")
    }

    @Test func readOnlyHeuristic() {
        #expect(SQLStatementSplitter.looksReadOnly("select * from t"))
        #expect(SQLStatementSplitter.looksReadOnly("WITH x AS (SELECT 1) SELECT * FROM x"))
        #expect(!SQLStatementSplitter.looksReadOnly("WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x"))
        #expect(!SQLStatementSplitter.looksReadOnly("UPDATE t SET a = 1"))
    }

    @Test func detectsUpdatesAndDeletesWithoutWhere() {
        #expect(SQLStatementSplitter.unboundedWrite("DELETE FROM orders") == "DELETE")
        #expect(SQLStatementSplitter.unboundedWrite("update t set a = (select x from y where y.id = 1)") == "UPDATE")
        #expect(SQLStatementSplitter.unboundedWrite("UPDATE t SET a = 'where' WHERE id = 1") == nil)
        #expect(SQLStatementSplitter.unboundedWrite("-- where\nDELETE FROM t") == "DELETE")
        #expect(SQLStatementSplitter.unboundedWrite("SELECT * FROM t") == nil)
    }

    @Test func leadingCommentsDoNotHideWrites() {
        #expect(!SQLStatementSplitter.looksReadOnly("-- select stale rows\nDELETE FROM orders"))
        #expect(!SQLStatementSplitter.looksReadOnly("/* SELECT */ UPDATE t SET a = 1"))
        #expect(!SQLStatementSplitter.looksReadOnly("# select\nDROP TABLE t"))
        #expect(SQLStatementSplitter.looksReadOnly("-- just reading\nSELECT '-- DELETE' AS x"))
    }
}

@Suite struct TableQueryTests {
    @Test func buildsFilteredSortedPage() {
        var query = TableQuery(table: TableRef(schema: "public", name: "orders"), pageSize: 100, page: 2)
        query.filters = [
            FilterRule(column: "status", op: .equals, value: "paid"),
            FilterRule(column: "notes", op: .contains, value: "50%_off"),
            FilterRule(column: "paid_at", op: .isNull),
            FilterRule(column: "ignored", op: .equals, value: "x", isEnabled: false),
        ]
        query.sort = [SortKey(column: "id", ascending: false)]
        let sql = query.selectSQL(dialect: .postgresql)
        #expect(sql == "SELECT * FROM \"public\".\"orders\" WHERE \"status\" = 'paid' AND \"notes\"::text ILIKE '%50\\%\\_off%' AND \"paid_at\" IS NULL ORDER BY \"id\" DESC LIMIT 100 OFFSET 200")
        #expect(query.countSQL(dialect: .postgresql) == "SELECT COUNT(*) FROM \"public\".\"orders\" WHERE \"status\" = 'paid' AND \"notes\"::text ILIKE '%50\\%\\_off%' AND \"paid_at\" IS NULL")
    }

    @Test func sqliteLikeDeclaresEscape() {
        let rule = FilterRule(column: "name", op: .startsWith, value: "a_")
        #expect(rule.sql(dialect: .sqlite) == "CAST(\"name\" AS TEXT) LIKE 'a\\_%' ESCAPE '\\'")
    }

    @Test func inListAndRawWhere() {
        var query = TableQuery(table: TableRef(name: "t"), pageSize: 10)
        query.filters = [FilterRule(column: "id", op: .inList, value: "1, 2,3")]
        query.rawWhere = "a > 1 OR b < 2"
        #expect(query.selectSQL(dialect: .mysql) == "SELECT * FROM `t` WHERE `id` IN ('1', '2', '3') AND (a > 1 OR b < 2) LIMIT 10")
    }
}

@Suite struct StatementGeneratorTests {
    let columns = ["id", "name", "note"]
    let rows: [[CellValue]] = [
        [.text("1"), .text("Alice"), .null],
        [.text("2"), .text("Bob"), .text("x")],
    ]

    @Test func generatesUpdateDeleteInsertByPrimaryKey() throws {
        var changes = PendingChanges()
        changes.setValue(.text("Alicia"), row: 0, column: 1, original: rows[0][1])
        changes.setValue(.null, row: 0, column: 2, original: rows[0][2])
        changes.markDeleted(rows: [1])
        changes.addInsertion([.useDefault, .value(.text("Carol")), .value(.null)])
        let statements = try SQLStatementGenerator.statements(
            table: TableRef(schema: "public", name: "people"), columns: columns, primaryKey: ["id"],
            originalRows: rows, changes: changes, dialect: .postgresql
        )
        #expect(statements == [
            "DELETE FROM \"public\".\"people\" WHERE \"id\" = '2'",
            "UPDATE \"public\".\"people\" SET \"name\" = 'Alicia' WHERE \"id\" = '1'",
            "INSERT INTO \"public\".\"people\" (\"name\", \"note\") VALUES ('Carol', NULL)",
        ])
    }

    @Test func withoutPrimaryKeyMatchesAllColumns() throws {
        var changes = PendingChanges()
        changes.setValue(.text("B"), row: 1, column: 1, original: rows[1][1])
        let statements = try SQLStatementGenerator.statements(
            table: TableRef(name: "people"), columns: columns, primaryKey: [],
            originalRows: rows, changes: changes, dialect: .mysql
        )
        #expect(statements == ["UPDATE `people` SET `name` = 'B' WHERE `id` = '2' AND `name` = 'Bob' AND `note` = 'x' LIMIT 1"])
    }

    @Test func revertingAValueClearsTheEdit() {
        var changes = PendingChanges()
        changes.setValue(.text("X"), row: 0, column: 1, original: .text("Alice"))
        changes.setValue(.text("Alice"), row: 0, column: 1, original: .text("Alice"))
        #expect(changes.isEmpty)
    }

    @Test func allDefaultInsert() throws {
        var changes = PendingChanges()
        changes.addInsertion(columnCount: 3)
        let pg = try SQLStatementGenerator.statements(table: TableRef(name: "t"), columns: columns, primaryKey: ["id"], originalRows: [], changes: changes, dialect: .postgresql)
        let my = try SQLStatementGenerator.statements(table: TableRef(name: "t"), columns: columns, primaryKey: ["id"], originalRows: [], changes: changes, dialect: .mysql)
        #expect(pg == ["INSERT INTO \"t\" DEFAULT VALUES"])
        #expect(my == ["INSERT INTO `t` () VALUES ()"])
    }
}

@Suite struct ExporterTests {
    let columns = [ResultColumn(name: "id", isNumeric: true), ResultColumn(name: "name")]
    let rows: [[CellValue]] = [[.text("1"), .text("a,\"b\"")], [.text("2"), .null]]

    @Test func csvQuotesWhenNeeded() {
        #expect(ResultExporter.export(columns: columns, rows: rows, format: .csv) == "id,name\r\n1,\"a,\"\"b\"\"\"\r\n2,\r\n")
    }

    @Test func jsonKeepsNumbersAndNulls() {
        let json = ResultExporter.export(columns: columns, rows: rows, format: .json)
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        #expect(parsed?.count == 2)
        #expect(parsed?[0]["id"] as? Int == 1)
        #expect(parsed?[0]["name"] as? String == "a,\"b\"")
        #expect(parsed?[1]["name"] is NSNull)
    }

    @Test func sqlInserts() {
        let sql = ResultExporter.export(columns: columns, rows: rows, format: .sqlInsert, tableName: "people", dialect: .mysql)
        #expect(sql == "INSERT INTO `people` (`id`, `name`) VALUES (1, 'a,\"b\"');\nINSERT INTO `people` (`id`, `name`) VALUES (2, NULL);\n")
    }
}

@Suite struct SQLiteDriverTests {
    func makeSession() async throws -> (DatabaseSession, URL) {
        let url = TestFiles.url("eq-\(UUID().uuidString).sqlite")
        let config = ConnectionConfig(kind: .sqlite, filePath: url.path)
        let session = DatabaseSession(parameters: ConnectionParameters(config: config, password: ""))
        try await session.connect()
        return (session, url)
    }

    @Test func roundTripsEditsThroughGeneratedStatements() async throws {
        let (session, url) = try await makeSession()
        defer { TestFiles.removeDatabase(url) }
        _ = try await session.execute("""
        CREATE TABLE people (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, note TEXT, score REAL);
        INSERT INTO people (name, note, score) VALUES ('Alice', NULL, 1.5), ('Bob', 'it''s', 2);
        """)
        let table = TableRef(name: "people")
        let structure = try await session.run { try $0.structure(of: table) }
        #expect(structure.primaryKey == ["id"])
        #expect(structure.columns.first?.isAutoIncrement == true)

        let query = TableQuery(table: table, sort: [SortKey(column: "id", ascending: true)])
        let loaded = try await session.execute(query.selectSQL(dialect: .sqlite))[0]
        #expect(loaded.rows.count == 2)
        #expect(loaded.rows[1][2] == .text("it's"))

        var changes = PendingChanges()
        changes.setValue(.text("Alicia"), row: 0, column: 1, original: loaded.rows[0][1])
        changes.markDeleted(rows: [1])
        changes.addInsertion([.useDefault, .value(.text("Carol")), .value(.text("new")), .useDefault])
        let statements = try SQLStatementGenerator.statements(
            table: table, columns: loaded.columns.map(\.name), primaryKey: structure.primaryKey,
            originalRows: loaded.rows, changes: changes, dialect: .sqlite
        )
        _ = try await session.execute((["BEGIN"] + statements + ["COMMIT"]).joined(separator: ";\n"))

        let after = try await session.execute("SELECT name, note FROM people ORDER BY id")[0]
        #expect(after.rows == [[.text("Alicia"), .null], [.text("Carol"), .text("new")]])
        await session.close()
    }

    @Test func reportsErrorsAndStaysUsable() async throws {
        let (session, url) = try await makeSession()
        defer { TestFiles.removeDatabase(url) }
        await #expect(throws: DatabaseError.self) {
            _ = try await session.execute("SELEC 1")
        }
        let result = try await session.execute("SELECT 1 + 1 AS two")
        #expect(result[0].rows == [[.text("2")]])
        #expect(result[0].columns[0].isNumeric)
        await session.close()
    }

    @Test func transactionRollsBackOnFailure() async throws {
        let (session, url) = try await makeSession()
        defer { TestFiles.removeDatabase(url) }
        _ = try await session.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL)")
        await #expect(throws: DatabaseError.self) {
            _ = try await session.executeTransaction(["INSERT INTO t VALUES (1, 'a')", "INSERT INTO t VALUES (2, NULL)"])
        }
        let count = try await session.execute("SELECT COUNT(*) FROM t")
        #expect(count[0].rows == [[.text("0")]])
        _ = try await session.executeTransaction(["INSERT INTO t VALUES (1, 'a')"])
        #expect(try await session.execute("SELECT v FROM t")[0].rows == [[.text("a")]])
        await session.close()
    }

    @Test func cancellingAQueuedTokenSkipsOnlyThatStatement() async throws {
        let (session, url) = try await makeSession()
        defer { TestFiles.removeDatabase(url) }
        let token = QueryToken()
        session.cancel(token)
        await #expect(throws: DatabaseError.self) {
            _ = try await session.execute("SELECT 1", token: token)
        }
        let other = try await session.execute("SELECT 2", token: QueryToken())
        #expect(other[0].rows == [[.text("2")]])
        await session.close()
    }

    @Test func rowLimitTruncates() async throws {
        let (session, url) = try await makeSession()
        defer { TestFiles.removeDatabase(url) }
        let result = try await session.execute("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000) SELECT x FROM c", rowLimit: 10)
        #expect(result[0].rows.count == 10)
        #expect(result[0].truncated)
        await session.close()
    }
}

@Suite struct HistoryStoreTests {
    @Test func storesAndSearches() {
        let url = TestFiles.url("history-\(UUID().uuidString).sqlite")
        defer { TestFiles.removeDatabase(url) }
        let store = QueryHistoryStore(url: url)
        let id = UUID()
        store.add(sql: "SELECT * FROM orders WHERE status = 'paid'", connectionID: id, database: "shop", duration: 0.01, rowCount: 3, error: nil)
        store.add(sql: "UPDATE users SET name = 'x'", connectionID: id, database: "shop", duration: 0.02, rowCount: nil, error: "denied")
        store.add(sql: "SELECT 1", connectionID: UUID(), database: nil, duration: 0, rowCount: 1, error: nil)
        store.flush()
        #expect(store.search("").count == 3)
        #expect(store.search("ord").map(\.sql) == ["SELECT * FROM orders WHERE status = 'paid'"])
        #expect(store.search("", connectionID: id).count == 2)
        #expect(store.search("users")[0].errorMessage == "denied")
        store.clear()
        #expect(store.search("").isEmpty)
    }
}

@Suite struct ConnectionStoreTests {
    @Test func damagedFileIsSetAsideAndReadableConnectionsSurvive() throws {
        let folder = TestFiles.url("connections-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("connections.json")

        let good = ConnectionConfig(name: "Kept", kind: .postgresql, host: "db.example.com")
        let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        try "[\(goodJSON), {\"kind\": \"not-an-engine\"}]".write(to: file, atomically: true, encoding: .utf8)

        let store = ConnectionStore(url: file)
        #expect(store.all().map(\.name) == ["Kept"])
        let aside = try #require(store.setAsideFile)
        #expect(FileManager.default.fileExists(atPath: aside.path))
        #expect(try String(contentsOf: aside, encoding: .utf8).contains("not-an-engine"))

        // Saving now writes a fresh file and leaves the set-aside copy alone.
        try store.save(ConnectionConfig(name: "New", kind: .sqlite, filePath: "/tmp/x.db"))
        #expect(ConnectionStore(url: file).all().map(\.name) == ["Kept", "New"])
        #expect(FileManager.default.fileExists(atPath: aside.path))
    }

    @Test func missingFileMeansNoConnectionsAndNothingSetAside() {
        let store = ConnectionStore(url: TestFiles.url("absent-\(UUID().uuidString).json"))
        #expect(store.all().isEmpty)
        #expect(store.setAsideFile == nil)
    }
}

@Suite struct SaveSafetyTests {
    func session() async throws -> (DatabaseSession, URL) {
        let url = TestFiles.url("save-safety-\(UUID().uuidString).sqlite")
        let session = DatabaseSession(parameters: ConnectionParameters(config: ConnectionConfig(kind: .sqlite, filePath: url.path), password: ""))
        try await session.connect()
        _ = try await session.execute("CREATE TABLE log (message TEXT, level INTEGER); INSERT INTO log VALUES ('same', 1), ('same', 1), ('other', 2)")
        return (session, url)
    }

    @Test func editThatMatchesIdenticalRowsSavesNothing() async throws {
        let (session, url) = try await session()
        defer { TestFiles.removeDatabase(url) }
        let page = try await session.fetchRows(TableQuery(table: TableRef(name: "log"), pageSize: 100))
        var changes = PendingChanges()
        changes.setValue(.text("edited"), row: 0, column: 0, original: page.rows[0][0])
        let batch = ChangeBatch(table: TableRef(name: "log"), columns: page.columns, primaryKey: [], originalRows: page.rows, changes: changes)
        await #expect(throws: (any Error).self) { try await session.applyChanges(batch) }
        let rows = try await session.execute("SELECT message FROM log ORDER BY rowid")
        #expect(rows[0].rows.map { $0[0].displayString } == ["same", "same", "other"])
        await session.close()
    }

    @Test func rowDeletedElsewhereRollsTheSaveBack() async throws {
        let (session, url) = try await session()
        defer { TestFiles.removeDatabase(url) }
        let page = try await session.fetchRows(TableQuery(table: TableRef(name: "log"), pageSize: 100))
        _ = try await session.execute("DELETE FROM log WHERE message = 'other'")
        var changes = PendingChanges()
        changes.addInsertion([.value(.text("new")), .value(.text("3"))])
        changes.setValue(.text("9"), row: 2, column: 1, original: page.rows[2][1])
        let batch = ChangeBatch(table: TableRef(name: "log"), columns: page.columns, primaryKey: [], originalRows: page.rows, changes: changes)
        await #expect(throws: (any Error).self) { try await session.applyChanges(batch) }
        let count = try await session.execute("SELECT COUNT(*) FROM log WHERE message = 'new'")
        #expect(count[0].rows.first?.first?.displayString == "0")
        await session.close()
    }

    @Test func mysqlUpdateThatChangesNothingIsAllowed() throws {
        try SQLiteConnection.checkSingleRow(statement: "UPDATE `t` SET `a` = 1 WHERE `id` = 1", affected: 0, family: .mysql)
        #expect(throws: (any Error).self) { try SQLiteConnection.checkSingleRow(statement: "DELETE FROM t WHERE id = 1", affected: 0, family: .mysql) }
        #expect(throws: (any Error).self) { try SQLiteConnection.checkSingleRow(statement: "UPDATE t SET a = 1", affected: 2, family: .postgresql) }
        try SQLiteConnection.checkSingleRow(statement: "INSERT INTO t VALUES (1)", affected: 5, family: .postgresql)
    }
}

@Suite struct SQLExpressionEditTests {
    @Test func expressionsAreWrittenAsIs() throws {
        let columns = ["id", "status", "updated_at"]
        var changes = PendingChanges()
        changes.setValue(.expression("DEFAULT"), row: 0, column: 1, original: .text("x"))
        changes.setValue(.expression("CURRENT_TIMESTAMP"), row: 0, column: 2, original: .null)
        changes.addInsertion([.value(.text("9")), .value(.expression("DEFAULT")), .useDefault])
        let statements = try SQLStatementGenerator.statements(
            table: TableRef(name: "t"), columns: columns, primaryKey: ["id"],
            originalRows: [[.text("1"), .text("x"), .null]], changes: changes, dialect: .postgresql
        )
        #expect(statements.contains { $0.contains(#""status" = DEFAULT"#) && $0.contains(#""updated_at" = CURRENT_TIMESTAMP"#) })
        #expect(statements.contains { $0.hasPrefix("INSERT") && $0.contains("'9'") && $0.contains("DEFAULT") })
        #expect(CellValue.expression("DEFAULT").displayString == "DEFAULT")
        #expect(SQLDialect.mysql.literal(.expression("CURRENT_TIMESTAMP")) == "CURRENT_TIMESTAMP")
    }
}

@Suite struct SafeModeTests {
    @Test func levelsGateWritesOrEverything() {
        #expect(!SafeModeLevel.silent.gates(writes: true))
        #expect(SafeModeLevel.alert.gates(writes: true) && !SafeModeLevel.alert.gates(writes: false))
        #expect(SafeModeLevel.alertFull.gates(writes: false))
        #expect(SafeModeLevel.safeMode.requiresAuthentication && !SafeModeLevel.alert.requiresAuthentication)
        #expect(SafeModeLevel.readOnly.blocksAllWrites && !SafeModeLevel.readOnly.gates(writes: true))
        #expect(SafeModeLevel.allCases.map(\.strictness) == Array(0...5))
    }

    @Test func readOnlyStaysTheSourceOfTruthAndOldConnectionsDecode() throws {
        var config = ConnectionConfig(kind: .postgresql, host: "db")
        #expect(config.safeModeLevel == .silent)
        config.safeModeLevel = .readOnly
        #expect(config.readOnly)
        config.safeModeLevel = .safeMode
        #expect(!config.readOnly && config.safeModeLevel == .safeMode)
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.safeModeLevel == .safeMode)

        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConnectionConfig(kind: .mysql, host: "db"))) as? [String: Any] ?? [:]
        legacy.removeValue(forKey: "safeMode")
        legacy["readOnly"] = true
        let old = try JSONDecoder().decode(ConnectionConfig.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.safeModeLevel == .readOnly)
    }
}

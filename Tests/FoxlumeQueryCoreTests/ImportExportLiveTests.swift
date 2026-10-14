import Foundation
import Testing
@testable import FoxlumeQueryCore

/// Shared steps of the live round trips: export, recreate, import, compare.
enum TransferRoundTrip {
    static func rows(_ connection: DatabaseConnection, _ table: String, orderBy: String = "id") throws -> [[CellValue]] {
        try connection.execute("SELECT * FROM \(table) ORDER BY \(orderBy)", rowLimit: nil).last { $0.hasResultSet }?.rows ?? []
    }

    static func scalar(_ connection: DatabaseConnection, _ sql: String) throws -> String? {
        try connection.execute(sql, rowLimit: nil).last { $0.hasResultSet }?.rows.first?.first?.textValue
    }

    static func export(_ connection: DatabaseConnection, _ items: [TableExportItem], options: TableExportOptions, to destination: TableExportDestination, progress: @escaping (TableExportProgress) -> Void = { _ in }) throws -> TableExportReport {
        try TableExporter(connection: connection, options: options).export(items, to: destination, progress: progress)
    }

    /// Imports `file` into `table`, mapping header names to the table's insertable columns.
    static func importCSV(_ connection: DatabaseConnection, file: URL, into table: TableRef, options: CSVImportOptions = CSVImportOptions()) throws -> CSVImportReport {
        let structure = try connection.structure(of: table)
        let preview = try CSVReader.preview(url: file, delimiter: options.delimiter, encoding: options.encoding, limit: 1)
        let header = CSVImportMapping.headerNames(preview.records.first?.texts ?? [])
        let insertable = structure.columns.filter {
            !TableExporter.isGenerated($0, family: connection.dialect.family)
        }.map(\.name)
        let mapping = CSVImportMapping.byName(sources: header, columns: insertable)
        return try CSVImporter(connection: connection, table: table, structure: structure, mapping: mapping, options: options).run(file: file)
    }
}

@Suite("Import and export against PostgreSQL", .serialized, .enabled(if: PostgresTestServer.isAvailable, "needs the PostgreSQL test server"))
struct PostgresTransferLiveTests {
    static let source = "fq_io_pg_src"

    /// A table with awkward values: quotes, backslashes, line breaks, commas, tabs, emoji, empty strings,
    /// NULLs, big numbers, booleans, JSON, arrays, bytea, a serial key and a generated column.
    func makeSource(_ connection: PostgresConnection, bulkRows: Int = 1500) throws {
        _ = try connection.execute("""
            DROP TABLE IF EXISTS \(Self.source) CASCADE;
            CREATE TABLE \(Self.source) (
                id serial PRIMARY KEY,
                small smallint,
                big bigint,
                real_value real,
                double_value double precision,
                amount numeric(14,4),
                flag boolean,
                day date,
                moment timestamp(3),
                moment_tz timestamptz,
                doc jsonb,
                tags text[],
                raw bytea,
                uid uuid,
                note text,
                big_plus bigint GENERATED ALWAYS AS (big + 1) STORED
            );
            INSERT INTO \(Self.source) (small, big, real_value, double_value, amount, flag, day, moment, moment_tz, doc, tags, raw, uid, note) VALUES
              (7, 9007199254740993, 1.5, 3.141592653589793, 1234.5678, true, '2026-10-13', '2026-10-13 08:30:00.125', '2026-10-13 08:30:00+02',
               '{"a": 1, "b": [true, null], "s": "q\\"uote"}', '{red,"gr een","a,b"}', '\\xdeadbeef00', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
               'It''s a "quote" \\ backslash, comma'),
              (NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
              (-32768, -9223372036854775808, -0.25, 1e-300, -0.0001, false, '0001-01-01', '1999-12-31 23:59:59', now(), '[]', '{}', '\\x', NULL, ''),
              (1, 1, 0, 0, 0, true, '2000-02-29', '2000-02-29 00:00:00', '2000-02-29 00:00:00+00', '{"emoji": "😀"}', '{"Zoë"}', '\\x00ff', NULL,
               E'line1\\nline2\\r\\nline3\\ttab ; semicolon -- not a comment /* nor this */ $$ dollar $$ Zoë 😀 漢字');
            INSERT INTO \(Self.source) (small, big, amount, flag, note)
            SELECT g % 100, g * 1000003, g / 7.0, g % 2 = 0, 'bulk row ' || g || repeat(' x', g % 5) FROM generate_series(1, \(bulkRows)) AS g;
            """, rowLimit: nil)
    }

    func dropScratch(_ connection: PostgresConnection) {
        _ = try? connection.execute("DROP TABLE IF EXISTS fq_io_pg_src, fq_io_pg_csv, fq_io_pg_strict, fq_io_pg_empty, fq_io_pg_log CASCADE", rowLimit: nil)
    }

    @Test(arguments: [false, true])
    func sqlRoundTrip(compress: Bool) throws {
        let connection = try PostgresTestServer.connect()
        defer { dropScratch(connection); connection.close() }
        try makeSource(connection)
        let before = try TransferRoundTrip.rows(connection, Self.source)
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var options = TableExportOptions()
        options.format = .sql
        options.rowsPerInsert = 7
        options.fetchSize = 100
        options.compress = compress
        let file = folder.appendingPathComponent("dump." + options.fileExtension())
        var pages = 0
        let report = try TransferRoundTrip.export(connection, [TableExportItem(table: TableRef(schema: "public", name: Self.source))], options: options, to: .file(file)) { _ in pages += 1 }
        #expect(report.totalRows == before.count)
        #expect(pages > before.count / 100)

        if !compress {
            let sql = try TransferFiles.read(file)
            #expect(sql.contains("SET standard_conforming_strings = on;"))
            #expect(sql.contains("DROP TABLE IF EXISTS \"public\".\"fq_io_pg_src\" CASCADE;"))
            #expect(sql.contains("CREATE SEQUENCE IF NOT EXISTS fq_io_pg_src_id_seq;"))
            #expect(!sql.contains("\"big_plus\")"), "generated columns stay out of INSERT")
        }

        _ = try connection.execute("DROP TABLE \(Self.source)", rowLimit: nil)
        let run = try SQLFileRunner(connection: connection, options: SQLFileRunOptions()).run(file: file)
        #expect(run.failure == nil, "\(String(describing: run.failure))")
        #expect(try TransferRoundTrip.rows(connection, Self.source) == before)
        // The serial sequence was moved past the imported keys.
        let next = try TransferRoundTrip.scalar(connection, "INSERT INTO \(Self.source) (note) VALUES ('after') RETURNING id")
        #expect(next == String(before.count + 1))
    }

    @Test func identityColumnsRoundTrip() throws {
        let connection = try PostgresTestServer.connect()
        defer { _ = try? connection.execute("DROP TABLE IF EXISTS fq_io_pg_ident, fq_io_pg_ident_copy", rowLimit: nil); connection.close() }
        _ = try connection.execute("""
            DROP TABLE IF EXISTS fq_io_pg_ident, fq_io_pg_ident_copy;
            CREATE TABLE fq_io_pg_ident (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, v text);
            INSERT INTO fq_io_pg_ident (v) VALUES ('a'), ('b'), ('c');
            DELETE FROM fq_io_pg_ident WHERE v = 'b';
            CREATE TABLE fq_io_pg_ident_copy (LIKE fq_io_pg_ident INCLUDING ALL);
            """, rowLimit: nil)
        let before = try TransferRoundTrip.rows(connection, "fq_io_pg_ident")
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = TableExportItem(table: TableRef(schema: "public", name: "fq_io_pg_ident"))
        var options = TableExportOptions()
        options.format = .sql
        let sqlFile = folder.appendingPathComponent("ident.sql")
        _ = try TransferRoundTrip.export(connection, [item], options: options, to: .file(sqlFile))
        #expect(try TransferFiles.read(sqlFile).contains("OVERRIDING SYSTEM VALUE"))
        _ = try connection.execute("DROP TABLE fq_io_pg_ident", rowLimit: nil)
        let run = try SQLFileRunner(connection: connection, options: SQLFileRunOptions()).run(file: sqlFile)
        #expect(run.failure == nil, "\(String(describing: run.failure))")
        #expect(try TransferRoundTrip.rows(connection, "fq_io_pg_ident") == before)
        #expect(try TransferRoundTrip.scalar(connection, "INSERT INTO fq_io_pg_ident (v) VALUES ('d') RETURNING id") == "4")

        options.format = .csv
        let csvFile = folder.appendingPathComponent("ident.csv")
        _ = try TransferRoundTrip.export(connection, [item], options: options, to: .file(csvFile))
        let report = try TransferRoundTrip.importCSV(connection, file: csvFile, into: TableRef(schema: "public", name: "fq_io_pg_ident_copy"))
        #expect(report.failure == nil, "\(String(describing: report.failure))")
        #expect(try TransferRoundTrip.rows(connection, "fq_io_pg_ident_copy") == TransferRoundTrip.rows(connection, "fq_io_pg_ident"))
    }

    @Test func csvRoundTrip() throws {
        let connection = try PostgresTestServer.connect()
        defer { dropScratch(connection); connection.close() }
        try makeSource(connection)
        _ = try connection.execute("CREATE TABLE fq_io_pg_csv (LIKE \(Self.source) INCLUDING ALL)", rowLimit: nil)
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("src.csv")
        var options = TableExportOptions()
        options.format = .csv
        options.fetchSize = 64
        _ = try TransferRoundTrip.export(connection, [TableExportItem(table: TableRef(schema: "public", name: Self.source))], options: options, to: .file(file))

        var importOptions = CSVImportOptions()
        importOptions.rowsPerInsert = 100
        let report = try TransferRoundTrip.importCSV(connection, file: file, into: TableRef(schema: "public", name: "fq_io_pg_csv"), options: importOptions)
        #expect(report.failure == nil, "\(String(describing: report.failure))")
        #expect(report.rowsImported == 1504)
        #expect(try TransferRoundTrip.rows(connection, "fq_io_pg_csv") == TransferRoundTrip.rows(connection, Self.source))
    }

    @Test func jsonAndNDJSONValues() throws {
        let connection = try PostgresTestServer.connect()
        defer { dropScratch(connection); connection.close() }
        try makeSource(connection, bulkRows: 0)
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = TableExportItem(table: TableRef(schema: "public", name: Self.source))
        var options = TableExportOptions()
        options.format = .json
        _ = try TransferRoundTrip.export(connection, [item], options: options, to: .file(folder.appendingPathComponent("rows.json")))
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("rows.json"))) as? [[String: Any]]
        #expect(parsed?.count == 4)
        #expect(parsed?[0]["flag"] as? Bool == true)
        #expect(parsed?[0]["big"] as? NSNumber == NSNumber(value: 9007199254740993 as Int64))
        #expect(parsed?[0]["note"] as? String == "It's a \"quote\" \\ backslash, comma")
        #expect(parsed?[1]["note"] is NSNull)
        #expect((parsed?[3]["note"] as? String)?.hasSuffix("Zoë 😀 漢字") == true)

        options.format = .ndjson
        _ = try TransferRoundTrip.export(connection, [item], options: options, to: .file(folder.appendingPathComponent("rows.ndjson")))
        let lines = try TransferFiles.read(folder.appendingPathComponent("rows.ndjson")).split(separator: "\n")
        #expect(lines.count == 4)
        for line in lines {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) is [String: Any])
        }
    }

    @Test func multipleTablesFiltersAndDependencyOrder() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let users = TableExportItem(table: TableRef(schema: "public", name: "users"), whereClause: "country = 'DE';")
        let orders = TableExportItem(table: TableRef(schema: "public", name: "orders"), rowLimit: 10)
        var options = TableExportOptions()
        options.format = .sql
        let file = folder.appendingPathComponent("two.sql")
        let report = try TransferRoundTrip.export(connection, [orders, users], options: options, to: .file(file))
        #expect(report.tables.map(\.table.name) == ["users", "orders"])
        #expect(report.tables.map(\.rows) == [1, 10])
        let sql = try TransferFiles.read(file)
        let createUsers = sql.range(of: "CREATE TABLE \"public\".\"users\"")
        let createOrders = sql.range(of: "CREATE TABLE \"public\".\"orders\"")
        #expect(createUsers != nil && createOrders != nil)
        if let createUsers, let createOrders { #expect(createUsers.lowerBound < createOrders.lowerBound) }
        #expect(sql.contains("-- Rows: WHERE country = 'DE'"))

        options.format = .csv
        let csvReport = try TransferRoundTrip.export(connection, [users, orders], options: options, to: .directory(folder))
        #expect(Set(csvReport.files.map(\.lastPathComponent)) == ["users.csv", "orders.csv"])
        #expect(try TransferFiles.read(folder.appendingPathComponent("orders.csv")).split(separator: "\n").count == 11)
    }

    @Test func badFilterIsReportedAndLeavesNothing() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = TableExportItem(table: TableRef(schema: "public", name: "users"), whereClause: "no_such_column = 1")
        #expect(throws: DatabaseError.self) {
            _ = try TransferRoundTrip.export(connection, [item], options: TableExportOptions(), to: .file(folder.appendingPathComponent("x.csv")))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        // The snapshot transaction was rolled back, so the session is usable.
        #expect(connection.transactionStatus == "I")
        #expect(try TransferRoundTrip.scalar(connection, "SELECT 1") == "1")
    }

    @Test func emptyTableStillGetsItsHeader() throws {
        let connection = try PostgresTestServer.connect()
        defer { dropScratch(connection); connection.close() }
        _ = try connection.execute("DROP TABLE IF EXISTS fq_io_pg_empty; CREATE TABLE fq_io_pg_empty (id int, name text)", rowLimit: nil)
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("empty.csv")
        _ = try TransferRoundTrip.export(connection, [TableExportItem(table: TableRef(schema: "public", name: "fq_io_pg_empty"))], options: TableExportOptions(), to: .file(file))
        #expect(try TransferFiles.read(file) == "id,name\n")
    }

    /// perf_big has two million rows; a row cap keeps the test short while still crossing many pages.
    @Test func streamsLargeTableInPages() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = TableExportOptions()
        options.format = .ndjson
        options.fetchSize = 1000
        var largestStep = 0
        var last = 0
        var total: Int?
        let file = folder.appendingPathComponent("big.ndjson")
        let report = try TransferRoundTrip.export(connection, [TableExportItem(table: TableRef(schema: "public", name: "perf_big"), rowLimit: 25_000)], options: options, to: .file(file)) { progress in
            largestStep = max(largestStep, progress.tableRows - last)
            last = progress.tableRows
            total = progress.tableTotal
        }
        #expect(report.totalRows == 25_000)
        #expect(total == 25_000)
        #expect(largestStep <= 1000)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(((attributes[.size] as? NSNumber)?.intValue ?? 0) > 25_000)
    }

    @Test func cancelStopsAndKeepsTheSessionUsable() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cancellation = OperationCancellation()
        var options = TableExportOptions()
        options.fetchSize = 500
        let exporter = TableExporter(connection: connection, options: options, cancellation: cancellation)
        let item = TableExportItem(table: TableRef(schema: "public", name: "perf_big"), rowLimit: 200_000)
        let error = #expect(throws: DatabaseError.self) {
            _ = try exporter.export([item], to: .file(folder.appendingPathComponent("big.csv"))) { progress in
                if progress.tableRows >= 1000 { cancellation.cancel() }
            }
        }
        if case .cancelled? = error {} else { Issue.record("expected cancelled, got \(String(describing: error))") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(connection.transactionStatus == "I")
    }

    @Test func csvImportErrorPolicies() throws {
        let connection = try PostgresTestServer.connect()
        defer { dropScratch(connection); connection.close() }
        _ = try connection.execute("DROP TABLE IF EXISTS fq_io_pg_strict; CREATE TABLE fq_io_pg_strict (id int PRIMARY KEY, qty int NOT NULL, note text)", rowLimit: nil)
        let file = try TransferFiles.write("id,qty,note\n1,10,a\n2,abc,bad number\n3,30,c\n1,40,duplicate\n4,,null qty\n5,50,\"\"\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let table = TableRef(schema: "public", name: "fq_io_pg_strict")
        func count() throws -> String? { try TransferRoundTrip.scalar(connection, "SELECT COUNT(*) FROM fq_io_pg_strict") }

        var options = CSVImportOptions()
        var report = try TransferRoundTrip.importCSV(connection, file: file, into: table, options: options)
        #expect(report.rolledBack)
        #expect(report.failure?.message.contains("integer") == true)
        #expect(report.failure?.line == 3)
        #expect(try count() == "0")
        #expect(connection.transactionStatus == "I")

        options.errorPolicy = .stopAndKeep
        report = try TransferRoundTrip.importCSV(connection, file: file, into: table, options: options)
        #expect(report.failure?.line == 3)
        #expect(try count() == "1")

        options.errorPolicy = .skipAndContinue
        options.deleteExistingRows = true
        options.rowsPerInsert = 2
        report = try TransferRoundTrip.importCSV(connection, file: file, into: table, options: options)
        #expect(report.rowsImported == 3)
        #expect(report.issues.map(\.line) == [3, 5, 6])
        #expect(try TransferRoundTrip.rows(connection, "fq_io_pg_strict") == [
            [.text("1"), .text("10"), .text("a")],
            [.text("3"), .text("30"), .text("c")],
            [.text("5"), .text("50"), .text("")],
        ])
    }

    @Test func sqlFileSkipModeKeepsGoingAfterErrors() throws {
        let connection = try PostgresTestServer.connect()
        defer { dropScratch(connection); connection.close() }
        let file = try TransferFiles.write("""
            DROP TABLE IF EXISTS fq_io_pg_log;
            CREATE TABLE fq_io_pg_log (id int PRIMARY KEY, body text);
            INSERT INTO fq_io_pg_log VALUES (1, $body$semi; colon$body$);
            INSERT INTO fq_io_pg_log VALUES (1, 'duplicate');
            INSERT INTO fq_io_pg_log VALUES (2, E'tab\\there');
            SELECT * FROM fq_io_pg_log;
            """, name: "fq-io-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: file) }
        var options = SQLFileRunOptions()
        options.errorPolicy = .skipAndContinue
        let report = try SQLFileRunner(connection: connection, options: options).run(file: file)
        #expect(report.statementsRun == 5)
        #expect(report.statementsFailed == 1)
        #expect(report.issues.first?.line == 4)
        #expect(try TransferRoundTrip.rows(connection, "fq_io_pg_log") == [[.text("1"), .text("semi; colon")], [.text("2"), .text("tab\there")]])

        options.errorPolicy = .stopAndRollBack
        _ = try connection.execute("DROP TABLE fq_io_pg_log", rowLimit: nil)
        let stopped = try SQLFileRunner(connection: connection, options: options).run(file: file)
        #expect(stopped.rolledBack)
        #expect(stopped.failure?.line == 4)
        #expect(try TransferRoundTrip.scalar(connection, "SELECT to_regclass('fq_io_pg_log') IS NULL") == "t")
    }
}

@Suite("Import and export against MySQL", .serialized, .enabled(if: MySQLTestServer.isAvailable))
struct MySQLTransferLiveTests {
    static let source = "fq_io_my_src"

    func makeSource(_ connection: MySQLConnection, bulkRows: Int = 1500) throws {
        _ = try connection.execute("""
            SET SESSION cte_max_recursion_depth = 100000;
            DROP TABLE IF EXISTS \(Self.source);
            CREATE TABLE \(Self.source) (
                id int NOT NULL AUTO_INCREMENT PRIMARY KEY,
                small smallint,
                big bigint,
                real_value float,
                double_value double,
                amount decimal(14,4),
                flag tinyint(1),
                bits bit(3),
                day date,
                moment datetime(3),
                doc json,
                raw varbinary(16),
                blob_value blob,
                mood enum('happy','sad'),
                note text,
                big_plus bigint GENERATED ALWAYS AS (big + 1) STORED
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
            INSERT INTO \(Self.source) (small, big, real_value, double_value, amount, flag, bits, day, moment, doc, raw, blob_value, mood, note) VALUES
              (7, 9007199254740993, 1.5, 3.141592653589793, 1234.5678, 1, b'101', '2026-10-13', '2026-10-13 08:30:00.125',
               '{"a": 1, "b": [true, null], "s": "q\\\\"uote"}', X'DEADBEEF00', X'00FF10', 'happy', 'It''s a "quote" \\\\ backslash, comma'),
              (NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
              (-32768, -9223372036854775808, -0.25, 1e-300, -0.0001, 0, b'0', '1000-01-01', '1999-12-31 23:59:59', '[]', X'', X'', 'sad', ''),
              (1, 1, 0, 0, 0, 1, b'1', '2000-02-29', '2000-02-29 00:00:00', '{"emoji": "😀"}', X'00', NULL, NULL,
               'line1\\nline2\\r\\nline3\\ttab ; semicolon -- not a comment /* nor this */ # hash Zoë 😀 漢字 nul\\0byte');
            INSERT INTO \(Self.source) (small, big, amount, flag, note)
            WITH RECURSIVE seq(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM seq WHERE g < \(max(bulkRows, 1)))
            SELECT g % 100, g * 1000003, g / 7.0, g % 2, CONCAT('bulk row ', g, REPEAT(' x', g % 5)) FROM seq WHERE \(bulkRows) > 0;
            """, rowLimit: nil)
    }

    func dropScratch(_ connection: MySQLConnection) {
        _ = try? connection.execute("DROP TABLE IF EXISTS fq_io_my_src, fq_io_my_csv, fq_io_my_strict, fq_io_my_comp, fq_io_my_empty, fq_io_my_log", rowLimit: nil)
    }

    @Test(arguments: [false, true])
    func sqlRoundTrip(compress: Bool) throws {
        let connection = try MySQLTestServer.connect()
        defer { dropScratch(connection); connection.close() }
        try makeSource(connection)
        let before = try TransferRoundTrip.rows(connection, Self.source)
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = TableExportOptions()
        options.format = .sql
        options.rowsPerInsert = 7
        options.fetchSize = 100
        options.compress = compress
        let file = folder.appendingPathComponent("dump." + options.fileExtension())
        let report = try TransferRoundTrip.export(connection, [TableExportItem(table: TableRef(name: Self.source))], options: options, to: .file(file))
        #expect(report.totalRows == before.count)
        if !compress {
            let sql = try TransferFiles.read(file)
            #expect(sql.contains("SET NAMES utf8mb4;"))
            #expect(!sql.contains("AUTO_INCREMENT="))
            #expect(sql.contains("'It''s a \"quote\" \\\\ backslash, comma'"))
        }
        _ = try connection.execute("DROP TABLE \(Self.source)", rowLimit: nil)
        let run = try SQLFileRunner(connection: connection, options: SQLFileRunOptions()).run(file: file)
        #expect(run.failure == nil, "\(String(describing: run.failure))")
        #expect(try TransferRoundTrip.rows(connection, Self.source) == before)
        #expect(try TransferRoundTrip.scalar(connection, "SELECT @@FOREIGN_KEY_CHECKS") == "1")
    }

    @Test func csvRoundTrip() throws {
        let connection = try MySQLTestServer.connect()
        defer { dropScratch(connection); connection.close() }
        try makeSource(connection)
        _ = try connection.execute("CREATE TABLE fq_io_my_csv LIKE \(Self.source)", rowLimit: nil)
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("src.csv")
        var options = TableExportOptions()
        options.format = .csv
        options.fetchSize = 64
        options.csvDelimiter = .semicolon
        options.csvLineEnding = .crlf
        _ = try TransferRoundTrip.export(connection, [TableExportItem(table: TableRef(name: Self.source))], options: options, to: .file(file))
        let report = try TransferRoundTrip.importCSV(connection, file: file, into: TableRef(name: "fq_io_my_csv"))
        #expect(report.failure == nil, "\(String(describing: report.failure))")
        #expect(report.rowsImported == 1504)
        #expect(try TransferRoundTrip.rows(connection, "fq_io_my_csv") == TransferRoundTrip.rows(connection, Self.source))
    }

    @Test func compositeKeyPagesCoverEveryRow() throws {
        let connection = try MySQLTestServer.connect()
        defer { dropScratch(connection); connection.close() }
        _ = try connection.execute("""
            DROP TABLE IF EXISTS fq_io_my_comp;
            CREATE TABLE fq_io_my_comp (a int NOT NULL, b varchar(10) NOT NULL, v text, PRIMARY KEY (a, b));
            INSERT INTO fq_io_my_comp
            WITH RECURSIVE seq(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM seq WHERE g < 250)
            SELECT g % 10, CONCAT('k', g), CONCAT('v', g) FROM seq;
            """, rowLimit: nil)
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = TableExportOptions()
        options.format = .ndjson
        options.fetchSize = 7
        let file = folder.appendingPathComponent("comp.ndjson")
        let report = try TransferRoundTrip.export(connection, [TableExportItem(table: TableRef(name: "fq_io_my_comp"))], options: options, to: .file(file))
        #expect(report.totalRows == 250)
        let lines = try TransferFiles.read(file).split(separator: "\n")
        #expect(Set(lines).count == 250)
    }

    @Test func multipleTablesAndViews() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = TableExportOptions()
        options.format = .sql
        let items = [
            TableExportItem(table: TableRef(name: "order_summary"), kind: .view),
            TableExportItem(table: TableRef(name: "orders"), whereClause: "id <= 5"),
            TableExportItem(table: TableRef(name: "users")),
        ]
        let file = folder.appendingPathComponent("all.sql")
        let report = try TransferRoundTrip.export(connection, items, options: options, to: .file(file))
        #expect(report.tables.map(\.table.name) == ["users", "orders", "order_summary"])
        #expect(report.tables.map(\.rows) == [5, 5, 0])
        let sql = try TransferFiles.read(file)
        #expect(sql.contains("DROP VIEW IF EXISTS `order_summary`;"))
        #expect(!sql.contains("DEFINER="))
        #expect(sql.contains("SET FOREIGN_KEY_CHECKS = @FOXLUME_DUMP_FOREIGN_KEY_CHECKS;"))

        options.format = .json
        let json = folder.appendingPathComponent("all.json")
        _ = try TransferRoundTrip.export(connection, Array(items.dropFirst()), options: options, to: .file(json))
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: [[String: Any]]]
        #expect(parsed?["users"]?.count == 5)
        #expect(parsed?["orders"]?.count == 5)
    }

    @Test func streamsLargeTableByKey() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = TableExportOptions()
        options.format = .csv
        options.fetchSize = 1000
        var largestStep = 0
        var last = 0
        let file = folder.appendingPathComponent("big.csv")
        let report = try TransferRoundTrip.export(connection, [TableExportItem(table: TableRef(name: "perf_big"), rowLimit: 25_000)], options: options, to: .file(file)) { progress in
            largestStep = max(largestStep, progress.tableRows - last)
            last = progress.tableRows
        }
        #expect(report.totalRows == 25_000)
        #expect(largestStep <= 1000)
        #expect(try TransferFiles.records(file).count == 25_001)
    }

    @Test func emptyTableStillGetsItsHeader() throws {
        let connection = try MySQLTestServer.connect()
        defer { dropScratch(connection); connection.close() }
        _ = try connection.execute("DROP TABLE IF EXISTS fq_io_my_empty; CREATE TABLE fq_io_my_empty (id int PRIMARY KEY, name text)", rowLimit: nil)
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("empty.csv")
        _ = try TransferRoundTrip.export(connection, [TableExportItem(table: TableRef(name: "fq_io_my_empty"))], options: TableExportOptions(), to: .file(file))
        #expect(try TransferFiles.read(file) == "id,name\n")
    }

    @Test func csvImportErrorPolicies() throws {
        let connection = try MySQLTestServer.connect()
        defer { dropScratch(connection); connection.close() }
        _ = try connection.execute("DROP TABLE IF EXISTS fq_io_my_strict; CREATE TABLE fq_io_my_strict (id int PRIMARY KEY, qty int NOT NULL, flag tinyint(1), note text)", rowLimit: nil)
        let file = try TransferFiles.write("id,qty,flag,note\n1,10,true,a\n2,abc,false,bad number\n3,30,FALSE,c\n1,40,,duplicate\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let table = TableRef(name: "fq_io_my_strict")
        var options = CSVImportOptions()
        var report = try TransferRoundTrip.importCSV(connection, file: file, into: table, options: options)
        #expect(report.rolledBack)
        #expect(try TransferRoundTrip.scalar(connection, "SELECT COUNT(*) FROM fq_io_my_strict") == "0")

        options.errorPolicy = .skipAndContinue
        report = try TransferRoundTrip.importCSV(connection, file: file, into: table, options: options)
        #expect(report.rowsImported == 2)
        #expect(report.issues.map(\.line) == [3, 5])
        #expect(try TransferRoundTrip.rows(connection, "fq_io_my_strict") == [
            [.text("1"), .text("10"), .text("1"), .text("a")],
            [.text("3"), .text("30"), .text("0"), .text("c")],
        ])
    }

    @Test func sqlFileRestoresForeignKeyChecksAfterFailure() throws {
        let connection = try MySQLTestServer.connect()
        defer { dropScratch(connection); connection.close() }
        let file = try TransferFiles.write("""
            DROP TABLE IF EXISTS fq_io_my_log;
            CREATE TABLE fq_io_my_log (id int PRIMARY KEY, body text);
            INSERT INTO fq_io_my_log VALUES (1, 'back\\\\slash; semi');
            INSERT INTO fq_io_my_log VALUES (1, 'duplicate');
            # a hash comment
            INSERT INTO fq_io_my_log VALUES (2, 'two');
            """, name: "fq-io-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: file) }
        var options = SQLFileRunOptions()
        options.errorPolicy = .stopAndKeep
        let report = try SQLFileRunner(connection: connection, options: options).run(file: file)
        #expect(report.failure?.line == 4)
        #expect(report.statementsRun == 3)
        #expect(try TransferRoundTrip.scalar(connection, "SELECT @@FOREIGN_KEY_CHECKS") == "1")
        #expect(try TransferRoundTrip.rows(connection, "fq_io_my_log") == [[.text("1"), .text("back\\slash; semi")]])
    }
}

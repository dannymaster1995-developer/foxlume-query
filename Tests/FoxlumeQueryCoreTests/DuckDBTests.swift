import Foundation
import Testing
@testable import FoxlumeQueryCore

/// DuckDB is embedded, so these tests need no server and always run.
@Suite("DuckDB driver", .serialized)
struct DuckDBTests {
    // MARK: - Helpers

    /// `FileManager.temporaryDirectory` ignores `TMPDIR` on macOS; `fqtest` points `TMPDIR` inside the project.
    static let scratchDirectory: URL = {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TMPDIR"] ?? environment["FOXLUME_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }()

    static func temporaryURL(_ name: String) -> URL {
        let directory = scratchDirectory.appendingPathComponent("eq-duckdb-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    static func open(_ path: String = "", readOnly: Bool = false) async throws -> DatabaseSession {
        let config = ConnectionConfig(kind: .duckdb, filePath: path, readOnly: readOnly)
        let session = DatabaseSession(parameters: ConnectionParameters(config: config, password: ""))
        try await session.connect()
        return session
    }

    static func expectCancelled(_ body: () async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            try await body()
            Issue.record("The statement was not cancelled.", sourceLocation: sourceLocation)
        } catch DatabaseError.cancelled {
        } catch {
            Issue.record("Expected cancellation, got \(error)", sourceLocation: sourceLocation)
        }
    }

    static func texts(_ result: StatementResult) -> [[String?]] {
        result.rows.map { $0.map(\.textValue) }
    }

    // MARK: - Connecting

    @Test func opensInMemoryForEmptyPathAndMemoryKeyword() async throws {
        for path in ["", ":memory:"] {
            let session = try await Self.open(path)
            #expect(session.serverVersion.hasPrefix("1."))
            #expect(!session.serverVersion.hasPrefix("v"))
            let result = try await session.execute("SELECT 42 AS answer, 'Zoë ✓' AS name")
            #expect(Self.texts(result[0]) == [["42", "Zoë ✓"]])
            #expect(result[0].columns.map(\.typeName) == ["INTEGER", "VARCHAR"])
            #expect(result[0].columns[0].isNumeric)
            #expect(await session.currentDatabase() == "memory")
            #expect(await session.defaultSchema() == "main")
            await session.close()
        }
    }

    @Test func createsMissingDatabaseFileAndReopensIt() async throws {
        let url = Self.temporaryURL("new.duckdb")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = try await Self.open(url.path)
        _ = try await session.execute("CREATE TABLE t AS SELECT 1 AS x")
        await session.close()
        #expect(FileManager.default.fileExists(atPath: url.path))
        let again = try await Self.open(url.path)
        #expect(Self.texts(try await again.execute("SELECT x FROM t")[0]) == [["1"]])
        #expect(await again.currentDatabase() == "new")
        await again.close()
    }

    @Test func readOnlyFileRefusesWrites() async throws {
        let url = Self.temporaryURL("ro.duckdb")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try await Self.open(url.path)
        _ = try await writer.execute("CREATE TABLE t (id INTEGER); INSERT INTO t VALUES (1)")
        await writer.close()

        let reader = try await Self.open(url.path, readOnly: true)
        let error = await #expect(throws: DatabaseError.self) {
            _ = try await reader.execute("INSERT INTO t VALUES (2)")
        }
        #expect(error?.localizedDescription.contains("read-only") == true)
        #expect(Self.texts(try await reader.execute("SELECT count(*) FROM t")[0]) == [["1"]])
        await reader.close()
    }

    @Test func readOnlyMemoryDatabaseRefusesWrites() async throws {
        let session = try await Self.open(":memory:", readOnly: true)
        await #expect(throws: DatabaseError.self) {
            _ = try await session.execute("CREATE TABLE t (id INTEGER)")
        }
        #expect(Self.texts(try await session.execute("SELECT 1")[0]) == [["1"]])
        await session.close()
    }

    @Test func dataFilesOpenAsReadOnlyViews() async throws {
        let directory = Self.temporaryURL("x").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let csv = directory.appendingPathComponent("people.csv")
        try "id,name\n1,An\n2,Björn\n".write(to: csv, atomically: true, encoding: .utf8)
        let tsv = directory.appendingPathComponent("scores.tsv")
        try "id\tscore\n1\t9.5\n2\t7\n".write(to: tsv, atomically: true, encoding: .utf8)
        let json = directory.appendingPathComponent("items.json")
        try #"[{"id": 1, "tags": ["a", "b"]}, {"id": 2, "tags": []}]"#.write(to: json, atomically: true, encoding: .utf8)
        let ndjson = directory.appendingPathComponent("events.ndjson")
        try "{\"id\": 1, \"kind\": \"open\"}\n{\"id\": 2, \"kind\": \"close\"}\n".write(to: ndjson, atomically: true, encoding: .utf8)
        let parquet = directory.appendingPathComponent("orders.parquet")
        let writer = try await Self.open()
        _ = try await writer.execute("COPY (SELECT range AS id, range * 1.5 AS amount FROM range(3)) TO \(SQLDialect.duckdb.quoteString(parquet.path)) (FORMAT parquet)")
        await writer.close()

        let expectations: [(URL, String, [[String?]])] = [
            (csv, "SELECT * FROM people ORDER BY id", [["1", "An"], ["2", "Björn"]]),
            (tsv, "SELECT * FROM scores ORDER BY id", [["1", "9.5"], ["2", "7.0"]]),
            (json, "SELECT * FROM items ORDER BY id", [["1", "[a, b]"], ["2", "[]"]]),
            (ndjson, "SELECT * FROM events ORDER BY id", [["1", "open"], ["2", "close"]]),
            (parquet, "SELECT * FROM orders ORDER BY id", [["0", "0.0"], ["1", "1.5"], ["2", "3.0"]]),
        ]
        for (url, sql, rows) in expectations {
            let session = try await Self.open(url.path)
            #expect(Self.texts(try await session.execute(sql)[0]) == rows, "\(url.lastPathComponent)")
            let stem = url.deletingPathExtension().lastPathComponent
            let tables = try await session.run { try $0.tables(schema: nil) }
            #expect(tables.map(\.name) == [stem])
            #expect(tables.first?.kind == .view)
            await #expect(throws: DatabaseError.self) {
                _ = try await session.execute("INSERT INTO \(stem) SELECT * FROM \(stem)")
            }
            await #expect(throws: DatabaseError.self) {
                _ = try await session.execute("CREATE TABLE copy AS SELECT 1")
            }
            await session.close()
        }

        let missing = DatabaseSession(parameters: ConnectionParameters(config: ConnectionConfig(kind: .duckdb, filePath: directory.appendingPathComponent("gone.parquet").path), password: ""))
        let error = await #expect(throws: DatabaseError.self) { try await missing.connect() }
        #expect(error?.localizedDescription.contains("File not found") == true)
    }

    @Test func sessionsOnOneFileShareTheDatabase() async throws {
        let url = Self.temporaryURL("shared.duckdb")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try await Self.open(url.path)
        let second = try await Self.open(url.path)
        _ = try await first.execute("CREATE TABLE t AS SELECT 1 AS x")
        _ = try await second.execute("INSERT INTO t VALUES (2)")
        #expect(Self.texts(try await first.execute("SELECT sum(x) FROM t")[0]) == [["3"]])

        let reader = DatabaseSession(parameters: ConnectionParameters(config: ConnectionConfig(kind: .duckdb, filePath: url.path, readOnly: true), password: ""))
        let error = await #expect(throws: DatabaseError.self) { try await reader.connect() }
        #expect(error?.localizedDescription == "shared.duckdb is already open in Foxlume Query with a different read-only setting. Close that connection first.")
        await second.close()
        #expect(Self.texts(try await first.execute("SELECT count(*) FROM t")[0]) == [["2"]])
        await first.close()
    }

    @Test func lockConflictNamesTheFileAndSuggestsReadOnly() {
        let message = "IO Error: Could not set lock on file \"/data/sample.duckdb\": Conflicting lock is held in /Applications/Foxlume Query.app/Contents/MacOS/Foxlume Query (PID 4242) by user me. See also https://duckdb.org/docs/stable/connect/concurrency"
        #expect(DuckDBConnection.openFailure(message, path: "/data/sample.duckdb", readOnly: false)
            == "sample.duckdb is in use by Foxlume Query (PID 4242). Close it there, or open the file read-only.")
        #expect(DuckDBConnection.openFailure(message, path: "/data/sample.duckdb", readOnly: true)
            == "sample.duckdb is in use by Foxlume Query (PID 4242), which has it open for writing. Close it there and try again.")
        #expect(DuckDBConnection.openFailure("IO Error: disk", path: "/x.duckdb", readOnly: false) == "Cannot open /x.duckdb: IO Error: disk")
    }

    // MARK: - Statements

    @Test func multiStatementBatchReportsEachResult() async throws {
        let session = try await Self.open()
        let results = try await session.execute("""
            CREATE TABLE t (id INTEGER PRIMARY KEY, v VARCHAR);
            INSERT INTO t VALUES (1, 'a'), (2, 'b'), (3, 'c');
            UPDATE t SET v = upper(v) WHERE id >= 2;
            DELETE FROM t WHERE id = 1;
            SELECT * FROM t ORDER BY id;
            DROP TABLE t
            """)
        #expect(results.map(\.message) == ["CREATE TABLE", "INSERT 3", "UPDATE 2", "DELETE 1", nil, "DROP TABLE"])
        #expect(results.map(\.affectedRows) == [nil, 3, 2, 1, nil, nil])
        #expect(Self.texts(results[4]) == [["2", "B"], ["3", "C"]])
        await session.close()
    }

    @Test func errorsAreServerErrorsAndTheSessionStaysUsable() async throws {
        let session = try await Self.open()
        let parse = await #expect(throws: DatabaseError.self) { _ = try await session.execute("SELEC 1") }
        #expect(parse?.localizedDescription.contains("syntax error") == true)
        let binder = await #expect(throws: DatabaseError.self) { _ = try await session.execute("SELECT * FROM nowhere") }
        #expect(binder?.localizedDescription.contains("nowhere") == true)
        let runtime = await #expect(throws: DatabaseError.self) { _ = try await session.execute("SELECT error('boom') FROM range(5000)") }
        #expect(runtime?.localizedDescription.contains("boom") == true)
        #expect(Self.texts(try await session.execute("SELECT 1 + 1")[0]) == [["2"]])
        await session.close()
    }

    @Test func rowLimitStopsALargeQueryEarly() async throws {
        let session = try await Self.open()
        let began = Date()
        let result = try await session.execute("SELECT range AS n FROM range(1000000)", rowLimit: 5)
        #expect(Date().timeIntervalSince(began) < 2)
        #expect(Self.texts(result[0]) == [["0"], ["1"], ["2"], ["3"], ["4"]])
        #expect(result[0].truncated)
        let exact = try await session.execute("SELECT range FROM range(2048)", rowLimit: 2048)
        #expect(exact[0].rows.count == 2048)
        #expect(!exact[0].truncated)
        await session.close()
    }

    @Test func cancelInterruptsAndTheSessionStaysUsable() async throws {
        let session = try await Self.open()
        // A cancel while idle must not leak into the next statement.
        session.cancel()
        #expect(Self.texts(try await session.execute("SELECT 7")[0]) == [["7"]])

        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { session.cancel() }
        let began = Date()
        await Self.expectCancelled {
            _ = try await session.execute("SELECT sum(hash(range)) FROM range(100000000000)")
        }
        let elapsed = Date().timeIntervalSince(began)
        #expect(elapsed > 0.9 && elapsed < 3, "cancelled after \(elapsed) s")
        #expect(Self.texts(try await session.execute("SELECT 'alive'")[0]) == [["alive"]])

        // Cancelling a materialized (non-SELECT) statement works the same way.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { session.cancel() }
        await Self.expectCancelled {
            _ = try await session.execute("CREATE TABLE big AS SELECT sum(hash(range)) AS h FROM range(100000000000)")
        }
        #expect(Self.texts(try await session.execute("SELECT count(*) FROM duckdb_tables() WHERE table_name = 'big'")[0]) == [["0"]])
        await session.close()
    }

    // MARK: - Values

    /// Every scalar Foxlume Query formats itself must read exactly like DuckDB's `CAST(x AS VARCHAR)`.
    @Test(arguments: [
        "(true), (false)",
        "((-128)::TINYINT), (127::TINYINT), (0::TINYINT)",
        "((-32768)::SMALLINT), (32767::SMALLINT)",
        "((-2147483648)::INTEGER), (2147483647)",
        "((-9223372036854775808)::BIGINT), (9223372036854775807::BIGINT)",
        "(255::UTINYINT), (65535::USMALLINT), (4294967295::UINTEGER)",
        "(18446744073709551615::UBIGINT), (0::UBIGINT)",
        "('170141183460469231731687303715884105727'::HUGEINT), ('-170141183460469231731687303715884105728'::HUGEINT), (-1::HUGEINT), (18446744073709551616::HUGEINT), ((-18446744073709551616)::HUGEINT), (10000000000000000000::HUGEINT), (0::HUGEINT), (1::HUGEINT)",
        "('340282366920938463463374607431768211455'::UHUGEINT), (18446744073709551616::UHUGEINT), (0::UHUGEINT)",
        "(1.0::DOUBLE), (0.1), (1e15), (1e16), (123456789012345678.0), (1e-4), (1e-5), (0.00012345), ((-0.0)::DOUBLE), ('inf'::DOUBLE), ('-inf'::DOUBLE), ('nan'::DOUBLE), (1.7976931348623157e308), (5e-324), (2.5), (100.0), (1e21), (0.1::DOUBLE + 0.2::DOUBLE), (-123.456e-7), (9007199254740993.0)",
        "(1.0::FLOAT), (0.1::FLOAT), (16777216::FLOAT), (1e8::FLOAT), (1e15::FLOAT), (1e16::FLOAT), (3.4e38::FLOAT), (1e-5::FLOAT), (1.17549435e-38::FLOAT), (123456.7::FLOAT), ((-0.0)::FLOAT), ('nan'::FLOAT), (3.14::FLOAT)",
        "(1.5::DECIMAL(4,1)), ((-0.05)::DECIMAL(4,3)), (0::DECIMAL(4,2)), (12::DECIMAL(4,0)), ((-99.99)::DECIMAL(4,2))",
        "(123456789.1234::DECIMAL(18,4)), ((-0.000000001)::DECIMAL(18,9)), (0.5::DECIMAL(9,1))",
        "('12345678901234567890123456.123456789012'::DECIMAL(38,12)), ('-0.000000000001'::DECIMAL(38,12)), ('-99999999999999999999999999.999999999999'::DECIMAL(38,12))",
        "('-0.00000000000000000000000000000000000001'::DECIMAL(38,38)), ('0.1'::DECIMAL(38,38)), (0::DECIMAL(38,38))",
        "(0.5::DECIMAL(4,4)), ((-0.5)::DECIMAL(4,4)), (0::DECIMAL(1,1)), (0.000001::DECIMAL(9,9)), (0.5::DECIMAL(18,18))",
        "('a'), (''), ('Zoë ✓'), ('multi\nline')",
        "('{\"json\": true}'::JSON), ('[1, 2]'::JSON)",
        "(DATE '2024-02-29'), (DATE '0001-01-01'), (DATE '0001-01-01' - 1), (DATE '-0044-03-15'), ('infinity'::DATE), ('-infinity'::DATE), (DATE '9999-12-31'), (DATE '12345-06-07'), (DATE '1970-01-01')",
        "(TIME '00:00:00'), (TIME '12:34:56.5'), (TIME '23:59:59.999999'), (TIME '24:00:00'), (TIME '01:02:03.000120')",
        "(TIMESTAMP '2024-02-29 12:34:56.789'), (TIMESTAMP '0001-01-01 00:00:00' - INTERVAL 1 DAY), ('infinity'::TIMESTAMP), ('-infinity'::TIMESTAMP), (TIMESTAMP '1969-12-31 23:59:59.999999'), (TIMESTAMP '294247-01-01 00:00:00'), (TIMESTAMP '-290308-12-22 00:00:00')",
        "(INTERVAL '1 year 2 months 3 days 04:05:06.789'), (INTERVAL '-1 year'), (INTERVAL '1 month'), (INTERVAL '-1 day'), (INTERVAL '0 seconds'), (INTERVAL '-36 hours 30 minutes'), (INTERVAL '1000 hours'), (INTERVAL '-14 months'), (INTERVAL '1 microsecond'), (to_microseconds(-9223372036854775807)), (INTERVAL '2 days -3 hours'), (INTERVAL '25 months -1 day')",
    ])
    func nativeTextMatchesDuckDBCast(values: String) async throws {
        let session = try await Self.open()
        let result = try await session.execute("SELECT v, CAST(v AS VARCHAR) FROM (VALUES \(values)) AS t(v)")[0]
        #expect(!result.rows.isEmpty)
        for row in result.rows {
            #expect(row[0].textValue == row[1].textValue)
        }
        await session.close()
    }

    static let typesDemo = """
        CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy');
        CREATE TABLE demo (
            id INTEGER PRIMARY KEY, tstz TIMESTAMPTZ, ttz TIMETZ, ts_s TIMESTAMP_S, ts_ms TIMESTAMP_MS, ts_ns TIMESTAMP_NS,
            bits BIT, u UUID, e mood, l INTEGER[], ls VARCHAR[], arr DOUBLE[3], st STRUCT(a INTEGER, "my key" VARCHAR),
            m MAP(VARCHAR, INTEGER), un UNION(num INTEGER, str VARCHAR), bn BIGNUM, nested STRUCT(x INTEGER[], y MAP(INTEGER, VARCHAR))[],
            tns TIME_NS, bl BLOB, dec DECIMAL(12,4), j JSON
        );
        INSERT INTO demo VALUES
            (1, TIMESTAMPTZ '2024-02-29 13:45:30.25+00', TIMETZ '13:45:30.5+05:30', TIMESTAMP_S '2024-02-29 13:45:30',
             TIMESTAMP_MS '2024-02-29 13:45:30.123', TIMESTAMP_NS '2024-02-29 13:45:30.123456789', '10110',
             '550e8400-e29b-41d4-a716-446655440000', 'happy', [1, NULL, 3], ['a b', 'it''s', NULL, '', 'NULL', '[x]', ' lead', 'x,y'],
             [1.5, -0.0, 1e20], {'a': 1, 'my key': 'x, y'}, MAP {'k1': 1, 'k 2': NULL}, union_value(str := 'hi'),
             -123456789012345678901234567890, [{'x': [1, 2], 'y': MAP {1: 'one'}}, NULL], TIME_NS '12:00:00.123456789',
             '\\xDE\\xAD'::BLOB, 12345678.9012, '{"k": [1, null]}'),
            (2, 'infinity'::TIMESTAMPTZ, TIMETZ '00:00:00-03:30', TIMESTAMP_S '1970-01-01 00:00:00', TIMESTAMP_MS '0001-01-01 00:00:00' - INTERVAL 1 DAY,
             TIMESTAMP_NS '1970-01-01 00:00:00.000000001', '0', '00000000-0000-0000-0000-000000000000', 'sad', [], [],
             [0.0, 0.1, 2.5], {'a': NULL, 'my key': NULL}, MAP {}, union_value(num := 42), 0, [], TIME_NS '00:00:00', ''::BLOB, -0.0001, '[]'),
            (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
        """

    /// Types DuckDB renders itself (through the VARCHAR projection) read exactly like an explicit cast.
    @Test func castRenderedTypesMatchExplicitCasts() async throws {
        let session = try await Self.open()
        _ = try await session.execute(Self.typesDemo)
        let plain = try await session.execute("SELECT * FROM demo ORDER BY id")[0]
        let names = plain.columns.map(\.name)
        let casts = names.map { "CAST(\(SQLDialect.duckdb.quoteIdentifier($0)) AS VARCHAR)" }.joined(separator: ", ")
        let cast = try await session.execute("SELECT \(casts) FROM demo ORDER BY id")[0]
        let blob = try #require(names.firstIndex(of: "bl"))
        for (row, expected) in zip(plain.rows, cast.rows) {
            for column in names.indices where column != blob {
                #expect(row[column].textValue == expected[column].textValue, "\(names[column])")
            }
        }
        #expect(plain.rows[0][blob] == .bytes(Data([0xDE, 0xAD])))
        #expect(plain.rows[1][blob] == .bytes(Data()))
        #expect(plain.rows[2].dropFirst().allSatisfy { $0.isNull })
        #expect(plain.rows[0][names.firstIndex(of: "tstz") ?? 0].textValue?.hasPrefix("2024-02-29") == true)

        // The projection keeps the inner query's order and paging.
        let page = try await session.fetchRows(TableQuery(table: TableRef(schema: "main", name: "demo"), sort: [SortKey(column: "id", ascending: false)], pageSize: 1, page: 1))
        #expect(page.rows.count == 1)
        #expect(page.rows.first?.first == .text("2"))
        #expect(page.rows.first?[names.firstIndex(of: "l") ?? 0] == .text("[]"))
        await session.close()
    }

    /// Statements that cannot be wrapped in a projection (DML with RETURNING) fall back to DuckDB's value API,
    /// which gives the same text except for TIMESTAMPTZ, shown in UTC there.
    @Test func valueAPIFallbackMatchesExplicitCasts() async throws {
        let session = try await Self.open()
        _ = try await session.execute(Self.typesDemo)
        _ = try await session.execute("CREATE TABLE copy AS SELECT * FROM demo WITH NO DATA")
        let returned = try await session.execute("INSERT INTO copy SELECT * FROM demo ORDER BY id RETURNING *")[0]
        let names = returned.columns.map(\.name)
        let casts = names.map { "CAST(\(SQLDialect.duckdb.quoteIdentifier($0)) AS VARCHAR)" }.joined(separator: ", ")
        let cast = try await session.execute("SELECT \(casts) FROM demo ORDER BY id")[0]
        #expect(returned.rows.count == 3)
        for (row, expected) in zip(returned.rows, cast.rows) {
            for column in names.indices where !["bl", "tstz"].contains(names[column]) {
                #expect(row[column].textValue == expected[column].textValue, "\(names[column])")
            }
        }
        let utc = try await session.execute("SET TimeZone = 'UTC'; SELECT CAST(tstz AS VARCHAR) FROM demo ORDER BY id")[1]
        let tstz = try #require(names.firstIndex(of: "tstz"))
        #expect(returned.rows.map { $0[tstz].textValue } == utc.rows.map { $0[0].textValue })
        await session.close()
    }

    @Test func statementsTheSplitterCannotAlignStillRender() async throws {
        let session = try await Self.open()
        // `$$` strings are DuckDB syntax the shared splitter does not know, so no projection is used here.
        let results = try await session.execute("SELECT $$a;b$$ AS s, [1, 2] AS l, {'k': 'v w'} AS st; SELECT MAP {'x': 1} AS m")
        #expect(results.count == 2)
        #expect(Self.texts(results[0]) == [["a;b", "[1, 2]", "{'k': v w}"]])
        #expect(Self.texts(results[1]) == [["{x=1}"]])
        await session.close()
    }

    @Test func typeNamesMatchTypeof() async throws {
        let session = try await Self.open()
        _ = try await session.execute(Self.typesDemo)
        let plain = try await session.execute("SELECT * FROM demo LIMIT 1")[0]
        let typeofs = plain.columns.map { "typeof(\(SQLDialect.duckdb.quoteIdentifier($0.name)))" }.joined(separator: ", ")
        let expected = try await session.execute("SELECT \(typeofs) FROM demo LIMIT 1")[0].rows[0].map(\.textValue)
        #expect(plain.columns.map(\.typeName) == expected)
        let numeric = plain.columns.filter(\.isNumeric).map(\.name)
        #expect(numeric == ["id", "bn", "dec"])

        let keywords = try await session.execute("SELECT {'year': 1, 'Ab': 2, 'select': 3, '9x': 4, 'plain_1': 5} AS s, 1.5::DECIMAL(12,4) AS d, [[1]] AS ll, [1,2]::INTEGER[2] AS a")[0]
        #expect(keywords.columns.map(\.typeName) == [
            "STRUCT(\"year\" INTEGER, Ab INTEGER, \"select\" INTEGER, \"9x\" INTEGER, plain_1 INTEGER)",
            "DECIMAL(12,4)", "INTEGER[][]", "INTEGER[2]",
        ])
        await session.close()
    }

    // MARK: - Metadata

    @Test func metadataCoversSchemasTablesConstraintsAndDDL() async throws {
        let session = try await Self.open()
        _ = try await session.execute("""
            CREATE SCHEMA sales;
            CREATE SEQUENCE user_ids;
            CREATE TABLE main.users (id INTEGER PRIMARY KEY DEFAULT nextval('user_ids'), email VARCHAR NOT NULL UNIQUE, name VARCHAR);
            COMMENT ON TABLE main.users IS 'People';
            COMMENT ON COLUMN main.users.email IS 'Login';
            CREATE TABLE sales.customers (id INTEGER, region VARCHAR, PRIMARY KEY (id, region));
            CREATE TABLE sales.orders (id INTEGER PRIMARY KEY, customer INTEGER, region VARCHAR, total DECIMAL(10,2) DEFAULT 0,
                FOREIGN KEY (customer, region) REFERENCES sales.customers (id, region));
            CREATE INDEX orders_total ON sales.orders (total, (id + 1));
            CREATE VIEW sales.big_orders AS SELECT * FROM sales.orders WHERE total > 100;
            INSERT INTO main.users (email) SELECT 'u' || range || '@x' FROM range(25);
            """)
        let schemas = try await session.run { try $0.schemas() }
        #expect(schemas == ["main", "sales"])
        #expect(try await session.run { try $0.databases() } == ["memory"])

        let main = try await session.run { try $0.tables(schema: nil) }
        #expect(main.map(\.ref) == [TableRef(schema: "main", name: "users")])
        #expect(main.first?.estimatedRows == 25)
        #expect(main.first?.comment == "People")
        let sales = try await session.run { try $0.tables(schema: "sales") }
        #expect(sales.map(\.name) == ["big_orders", "customers", "orders"])
        #expect(sales.map(\.kind) == [.view, .table, .table])

        let users = try await session.run { try $0.structure(of: TableRef(schema: "main", name: "users")) }
        #expect(users.columns.map(\.name) == ["id", "email", "name"])
        #expect(users.columns.map(\.isNullable) == [false, false, true])
        #expect(users.columns[0].isAutoIncrement)
        #expect(users.columns[0].isPrimaryKey)
        #expect(users.columns[1].comment == "Login")
        #expect(users.primaryKey == ["id"])
        #expect(users.indexes.contains { $0.isUnique && !$0.isPrimary && $0.columns == ["email"] })

        let orders = try await session.run { try $0.structure(of: TableRef(schema: "sales", name: "orders")) }
        #expect(orders.columns.map(\.dataType) == ["INTEGER", "INTEGER", "VARCHAR", "DECIMAL(10,2)"])
        #expect(orders.columns[3].defaultValue == "0")
        #expect(orders.foreignKeys.count == 1)
        #expect(orders.foreignKeys.first?.columns == ["customer", "region"])
        #expect(orders.foreignKeys.first?.referencedTable == TableRef(schema: "sales", name: "customers"))
        #expect(orders.foreignKeys.first?.referencedColumns == ["id", "region"])
        #expect(orders.indexes.contains { $0.name == "orders_total" && $0.columns == ["total", "((id + 1))"] && !$0.isUnique })

        let customers = try await session.run { try $0.structure(of: TableRef(schema: "sales", name: "customers")) }
        #expect(customers.primaryKey == ["id", "region"])
        #expect(customers.foreignKeys.isEmpty)

        let view = try await session.run { try $0.structure(of: TableRef(schema: "sales", name: "big_orders")) }
        #expect(view.columns.map(\.name) == ["id", "customer", "region", "total"])
        #expect(view.primaryKey.isEmpty)

        let ddl = try await session.run { try $0.ddl(of: TableRef(schema: "sales", name: "orders")) }
        #expect(ddl.hasPrefix("CREATE TABLE sales.orders("))
        #expect(ddl.contains("CREATE INDEX orders_total ON sales.orders"))
        let viewDDL = try await session.run { try $0.ddl(of: TableRef(schema: "sales", name: "big_orders")) }
        #expect(viewDDL.hasPrefix("CREATE VIEW sales.big_orders AS SELECT"))
        await session.close()
    }

    @Test func indexExpressionTextParses() {
        #expect(DuckDBConnection.indexExpressions("[user_id, '((ua + 1))']") == ["user_id", "((ua + 1))"])
        #expect(DuckDBConnection.indexExpressions("[a]") == ["a"])
        #expect(DuckDBConnection.indexExpressions("['it\\'s, odd', b]") == ["it's, odd", "b"])
        #expect(DuckDBConnection.indexExpressions("[]") == [])
    }

    @Test func useDatabaseSwitchesTheCatalog() async throws {
        let session = try await Self.open()
        _ = try await session.execute("ATTACH ':memory:' AS scratch; CREATE TABLE scratch.main.t (x INTEGER)")
        #expect(try await session.run { try $0.databases() } == ["memory", "scratch"])
        try await session.run { try $0.useDatabase("scratch") }
        #expect(await session.currentDatabase() == "scratch")
        #expect(try await session.run { try $0.tables(schema: nil) }.map(\.name) == ["t"])
        await session.close()
    }

    // MARK: - Grid edits through the default SQL implementations

    @Test func editsRoundTripOnATableWithAPrimaryKey() async throws {
        let session = try await Self.open()
        _ = try await session.execute("""
            CREATE TABLE people (id INTEGER PRIMARY KEY, name VARCHAR NOT NULL, score DECIMAL(6,2), tags VARCHAR[], info STRUCT(city VARCHAR, zip INTEGER));
            INSERT INTO people VALUES (1, 'An', 9.50, ['a'], {'city': 'Zürich', 'zip': 100000}), (2, 'Björn', NULL, [], NULL), (3, 'Chi', 7.25, NULL, NULL);
            """)
        let table = TableRef(schema: "main", name: "people")
        let structure = try await session.run { try $0.structure(of: table) }
        let query = TableQuery(table: table, sort: [SortKey(column: "id", ascending: true)], pageSize: 2)
        let page = try await session.fetchRows(query)
        #expect(Self.texts(page) == [["1", "An", "9.50", "[a]", "{'city': Zürich, 'zip': 100000}"], ["2", "Björn", nil, "[]", nil]])
        #expect(try await session.countRows(query) == 3)

        var changes = PendingChanges()
        changes.setValue(.text("An Müller"), row: 0, column: 1, original: page.rows[0][1])
        changes.setValue(.text("10.75"), row: 0, column: 2, original: page.rows[0][2])
        changes.setValue(.text("[a, b c]"), row: 0, column: 3, original: page.rows[0][3])
        changes.setValue(.text("{'city': Genève, 'zip': 530000}"), row: 0, column: 4, original: page.rows[0][4])
        changes.markDeleted(rows: [1])
        changes.addInsertion([.value(.text("4")), .value(.text("Zoë")), .useDefault, .value(.text("['x']")), .value(.null)])
        try await session.applyChanges(ChangeBatch(table: table, columns: page.columns, primaryKey: structure.primaryKey, originalRows: page.rows, changes: changes))

        let after = try await session.execute("SELECT * FROM people ORDER BY id")[0]
        #expect(Self.texts(after) == [
            ["1", "An Müller", "10.75", "[a, b c]", "{'city': Genève, 'zip': 530000}"],
            ["3", "Chi", "7.25", nil, nil],
            ["4", "Zoë", nil, "[x]", nil],
        ])
        await session.close()
    }

    @Test func editsRoundTripOnATableWithoutAPrimaryKey() async throws {
        let session = try await Self.open()
        _ = try await session.execute("""
            CREATE TABLE log (logged_at TIMESTAMP, level VARCHAR, ratio DOUBLE, payload BLOB);
            INSERT INTO log VALUES (TIMESTAMP '2024-05-01 10:00:00.5', 'info', 0.1, '\\x01\\x02'::BLOB), (TIMESTAMP '2024-05-01 10:05:00', 'warn', NULL, NULL);
            """)
        let table = TableRef(schema: "main", name: "log")
        let page = try await session.fetchRows(TableQuery(table: table, sort: [SortKey(column: "logged_at", ascending: true)]))
        #expect(page.rows[0][3] == .bytes(Data([1, 2])))

        var changes = PendingChanges()
        changes.setValue(.text("debug"), row: 0, column: 1, original: page.rows[0][1])
        changes.setValue(.text("error"), row: 1, column: 1, original: page.rows[1][1])
        changes.addInsertion([.value(.text("2024-05-02 00:00:00")), .value(.text("info")), .value(.text("2.5")), .value(.bytes(Data([0xFF])))])
        try await session.applyChanges(ChangeBatch(table: table, columns: page.columns, primaryKey: [], originalRows: page.rows, changes: changes))

        let after = try await session.execute("SELECT level, ratio, payload FROM log ORDER BY logged_at")[0]
        #expect(after.rows == [
            [.text("debug"), .text("0.1"), .bytes(Data([1, 2]))],
            [.text("error"), .null, .null],
            [.text("info"), .text("2.5"), .bytes(Data([0xFF]))],
        ])

        var deletion = PendingChanges()
        let reloaded = try await session.fetchRows(TableQuery(table: table, sort: [SortKey(column: "logged_at", ascending: true)]))
        deletion.markDeleted(rows: [0])
        try await session.applyChanges(ChangeBatch(table: table, columns: reloaded.columns, primaryKey: [], originalRows: reloaded.rows, changes: deletion))
        #expect(Self.texts(try await session.execute("SELECT level FROM log ORDER BY logged_at")[0]) == [["error"], ["info"]])
        await session.close()
    }

    @Test func editsOnAViewFailCleanlyAndRollBack() async throws {
        let session = try await Self.open()
        _ = try await session.execute("""
            CREATE TABLE base (id INTEGER PRIMARY KEY, name VARCHAR);
            INSERT INTO base VALUES (1, 'a'), (2, 'b');
            CREATE VIEW names AS SELECT id, name FROM base;
            """)
        let table = TableRef(schema: "main", name: "names")
        let page = try await session.fetchRows(TableQuery(table: table, sort: [SortKey(column: "id", ascending: true)]))
        var changes = PendingChanges()
        changes.setValue(.text("z"), row: 0, column: 1, original: page.rows[0][1])
        let error = await #expect(throws: DatabaseError.self) {
            try await session.applyChanges(ChangeBatch(table: table, columns: page.columns, primaryKey: [], originalRows: page.rows, changes: changes))
        }
        #expect(error?.localizedDescription.isEmpty == false)
        #expect(Self.texts(try await session.execute("SELECT name FROM base ORDER BY id")[0]) == [["a"], ["b"]])
        // The failed transaction was rolled back, so new work runs normally.
        _ = try await session.execute("INSERT INTO base VALUES (3, 'c')")
        #expect(Self.texts(try await session.execute("SELECT count(*) FROM names")[0]) == [["3"]])
        await session.close()
    }
}


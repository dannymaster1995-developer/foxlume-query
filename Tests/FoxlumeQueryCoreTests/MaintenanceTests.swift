import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct MaintenanceTests {
    private func table(_ name: String, schema: String? = nil, kind: TableKind = .table, engine: String? = nil) -> TableInfo {
        TableInfo(ref: TableRef(schema: schema, name: name), kind: kind, engine: engine)
    }

    @Test func postgresStatementsQuoteAndRunOncePerTable() {
        let sql = MaintenanceSQL(kind: .postgresql)
        let tables = [table("Order Lines", schema: "sales"), table("totals", schema: "public", kind: .materializedView)]
        #expect(sql.steps(.vacuum, tables: tables).map(\.statement) == [#"VACUUM "sales"."Order Lines""#, #"VACUUM "public"."totals""#])
        #expect(sql.steps(.vacuumAnalyze, tables: tables).first?.statement == #"VACUUM ANALYZE "sales"."Order Lines""#)
        #expect(sql.steps(.vacuumFull, tables: tables).first?.statement == #"VACUUM FULL "sales"."Order Lines""#)
        #expect(sql.steps(.analyze, tables: tables).first?.statement == #"ANALYZE "sales"."Order Lines""#)
        #expect(sql.steps(.reindex, tables: tables).first?.statement == #"REINDEX TABLE "sales"."Order Lines""#)
        #expect(sql.steps(.vacuum, tables: tables).map(\.table) == tables.map(\.ref))
        #expect(sql.statement(.vacuum, table: TableRef(schema: "a", name: #"x"y"#)) == #"VACUUM "a"."x""y""#)
        // No database-wide VACUUM: the menu works on tables only.
        #expect(sql.statement(.vacuum, table: nil) == nil)
        #expect(sql.statement(.optimize, table: TableRef(name: "t")) == nil)
    }

    @Test func postgresMenuSkipsViewsSystemAndForeignTables() {
        let sql = MaintenanceSQL(kind: .postgresql)
        #expect(sql.operationGroups(for: [table("t")]) == [[.vacuum, .vacuumAnalyze, .analyze], [.vacuumFull, .reindex]])
        #expect(sql.operationGroups(for: [table("v", kind: .view)]).isEmpty)
        #expect(sql.operationGroups(for: [table("pg_class", kind: .systemTable)]).isEmpty)
        #expect(sql.operationGroups(for: []).isEmpty)
        let mixed = [table("t"), table("v", kind: .view), table("f", kind: .foreignTable), table("s", kind: .systemTable)]
        #expect(sql.steps(.analyze, tables: mixed).map(\.statement) == [#"ANALYZE "t""#])
        #expect(sql.title(.vacuumFull) == "Vacuum Full…")
        #expect(sql.name(.vacuumFull) == "Vacuum Full")
    }

    @Test func mysqlStatementsAndRepairOnlyForMyISAMAndAria() {
        let sql = MaintenanceSQL(kind: .mysql)
        let innodb = table("order`s", schema: "shop", engine: "InnoDB")
        let myisam = table("log", schema: "shop", engine: "MyISAM")
        let aria = table("cache", schema: "shop", engine: "Aria")
        #expect(sql.steps(.optimize, tables: [innodb]).map(\.statement) == ["OPTIMIZE TABLE `shop`.`order``s`"])
        #expect(sql.steps(.analyze, tables: [innodb]).map(\.statement) == ["ANALYZE TABLE `shop`.`order``s`"])
        #expect(sql.steps(.check, tables: [myisam]).map(\.statement) == ["CHECK TABLE `shop`.`log`"])
        #expect(sql.steps(.checkQuick, tables: [myisam]).map(\.statement) == ["CHECK TABLE `shop`.`log` QUICK"])
        #expect(sql.steps(.checkExtended, tables: [myisam]).map(\.statement) == ["CHECK TABLE `shop`.`log` EXTENDED"])
        #expect(sql.steps(.repair, tables: [myisam, innodb, aria]).map(\.statement) == ["REPAIR TABLE `shop`.`log`", "REPAIR TABLE `shop`.`cache`"])
        #expect(sql.operationGroups(for: [innodb]) == [[.optimize, .analyze], [.check, .checkQuick, .checkExtended]])
        #expect(sql.operationGroups(for: [myisam, aria]).last == [.repair])
        #expect(sql.operationGroups(for: [myisam, innodb]).last != [.repair])
        #expect(sql.title(.analyze) == "Analyze Table")
        #expect(MaintenanceSQL(kind: .mariadb).operationGroups(for: [aria]).last == [.repair])
    }

    @Test func sqliteAndDuckDBHaveDatabaseWideCommands() {
        let sqlite = MaintenanceSQL(kind: .sqlite)
        let tracks = table("my tracks")
        #expect(sqlite.operationGroups(for: [tracks]) == [[.analyze, .integrityCheck], [.vacuumDatabase]])
        #expect(sqlite.operationGroups(for: []) == [[.integrityCheck], [.vacuumDatabase]])
        #expect(sqlite.steps(.analyze, tables: [tracks]).map(\.statement) == [#"ANALYZE "my tracks""#])
        #expect(sqlite.steps(.integrityCheck, tables: [tracks]).map(\.statement) == [#"PRAGMA integrity_check("my tracks")"#])
        #expect(sqlite.statement(.integrityCheck, table: TableRef(schema: "main", name: "t")) == #"PRAGMA "main".integrity_check("t")"#)
        #expect(sqlite.steps(.integrityCheck, tables: []) == [MaintenanceStep(table: nil, statement: "PRAGMA integrity_check")])
        // VACUUM runs once for the database, whatever is selected.
        #expect(sqlite.steps(.vacuumDatabase, tables: [tracks, table("b")]) == [MaintenanceStep(table: nil, statement: "VACUUM")])

        let duckdb = MaintenanceSQL(kind: .duckdb)
        let items = table("items", schema: "main")
        #expect(duckdb.operationGroups(for: [items]) == [[.analyze], [.checkpoint]])
        #expect(duckdb.operationGroups(for: []) == [[.checkpoint]])
        #expect(duckdb.steps(.analyze, tables: [items]).map(\.statement) == [#"ANALYZE "main"."items""#])
        #expect(duckdb.steps(.checkpoint, tables: [items]).map(\.statement) == ["CHECKPOINT"])
        #expect(duckdb.statement(.vacuum, table: items.ref) == nil)
    }

    @Test func mongoAndRedisHaveNone() {
        for kind in [DatabaseKind.mongodb, .redis] {
            let sql = MaintenanceSQL(kind: kind)
            #expect(!sql.isSupported)
            #expect(sql.operationGroups(for: [table("c")]).isEmpty)
            #expect(sql.steps(.analyze, tables: [table("c")]).isEmpty)
        }
    }

    @Test func onlyIntegrityCheckIsARead() {
        #expect(!MaintenanceSQL.writes(MaintenanceSQL(kind: .sqlite).steps(.integrityCheck, tables: [table("t")])))
        #expect(!MaintenanceSQL.writes(MaintenanceSQL(kind: .sqlite).steps(.integrityCheck, tables: [])))
        #expect(MaintenanceSQL.writes(MaintenanceSQL(kind: .mysql).steps(.check, tables: [table("t")])))
        #expect(MaintenanceSQL.writes(MaintenanceSQL(kind: .postgresql).steps(.analyze, tables: [table("t")])))
        #expect(MaintenanceSQL.writes(MaintenanceSQL(kind: .duckdb).steps(.checkpoint, tables: [])))
        #expect(MaintenanceOperation.vacuumFull.warning != nil)
        #expect(MaintenanceOperation.optimize.warning != nil)
        #expect(MaintenanceOperation.vacuum.warning == nil)
    }

    private func mysqlResult(_ rows: [[String]]) -> StatementResult {
        StatementResult(
            columns: ["Table", "Op", "Msg_type", "Msg_text"].map { ResultColumn(name: $0, typeName: "VARCHAR") },
            rows: rows.map { $0.map { CellValue.text($0) } }
        )
    }

    @Test func readsMySQLMessageRows() {
        let optimized = MaintenanceOutcome.reading([mysqlResult([
            ["shop.t", "optimize", "note", "Table does not support optimize, doing recreate + analyze instead"],
            ["shop.t", "optimize", "status", "OK"],
        ])])
        #expect(optimized.status == .ok)
        #expect(optimized.messages == [
            MaintenanceMessage(.note, "Table does not support optimize, doing recreate + analyze instead"),
            MaintenanceMessage(.info, "OK"),
        ])
        let missing = MaintenanceOutcome.reading([mysqlResult([
            ["shop.gone", "check", "Error", "Table 'shop.gone' doesn't exist"],
            ["shop.gone", "check", "status", "Operation failed"],
        ])])
        #expect(missing.status == .failed)
        #expect(missing.summary == "Table 'shop.gone' doesn't exist; Operation failed")
        #expect(MaintenanceOutcome.reading([mysqlResult([["shop.t", "check", "warning", "1 client is using the table"], ["shop.t", "check", "status", "OK"]])]).status == .warning)
        #expect(MaintenanceOutcome.reading([mysqlResult([["shop.t", "check", "status", "Corrupt"]])]).status == .failed)
    }

    @Test func readsTagsNoticesAndIntegrityRows() {
        let vacuumed = MaintenanceOutcome.reading([StatementResult(message: "VACUUM")], notices: ["INFO: vacuuming \"public.t\""], elapsed: 0.25)
        #expect(vacuumed.status == .ok)
        #expect(vacuumed.messages == [MaintenanceMessage(.info, "VACUUM"), MaintenanceMessage(.info, "INFO: vacuuming \"public.t\"")])
        #expect(vacuumed.elapsed == 0.25)
        let skipped = MaintenanceOutcome.reading([StatementResult(message: "VACUUM")], notices: ["WARNING: permission denied to vacuum \"t\", skipping it"])
        #expect(skipped.status == .warning)

        let integrity = { (rows: [String]) in
            StatementResult(columns: [ResultColumn(name: "integrity_check", typeName: "")], rows: rows.map { [CellValue.text($0)] })
        }
        #expect(MaintenanceOutcome.reading([integrity(["ok"])]).status == .ok)
        let broken = MaintenanceOutcome.reading([integrity(["row 3 missing from index i1", "wrong # of entries in index i1"])])
        #expect(broken.status == .failed)
        #expect(broken.messages.count == 2)
        // Nothing to report (DuckDB CHECKPOINT, an OK packet): "Done".
        #expect(MaintenanceOutcome.reading([StatementResult(columns: [ResultColumn(name: "Success", typeName: "BOOLEAN")])]).summary == "Done")
        #expect(MaintenanceOutcome.reading([StatementResult(affectedRows: 0, message: "Affected rows: 0")]).summary == "Done")
    }
}

/// The commands on SQLite and DuckDB files, in process.
@Suite struct MaintenanceFileTests {
    @Test func sqliteRunsAnalyzeIntegrityCheckAndVacuum() async throws {
        let url = TestFiles.url("fq-maintenance-\(UUID().uuidString).sqlite")
        defer { TestFiles.removeDatabase(url) }
        let session = DatabaseSession(parameters: ConnectionParameters(config: ConnectionConfig(kind: .sqlite, filePath: url.path), password: ""))
        try await session.connect()
        defer { Task { await session.close() } }
        _ = try await session.execute("CREATE TABLE \"my tracks\" (id INTEGER PRIMARY KEY, name TEXT); CREATE INDEX tracks_name ON \"my tracks\" (name); INSERT INTO \"my tracks\" (name) VALUES ('a'), ('b'), ('c')")
        let tables = try await session.run { try $0.tables(schema: nil) }
        let sql = MaintenanceSQL(kind: .sqlite)
        for operation in [MaintenanceOperation.analyze, .integrityCheck, .vacuumDatabase] {
            let steps = sql.steps(operation, tables: tables)
            #expect(steps.count == 1)
            let outcomes = await MaintenanceRun(steps: steps).run(on: session)
            #expect(outcomes.map(\.status) == [.ok], "\(operation): \(outcomes.map(\.summary))")
            if operation == .integrityCheck { #expect(outcomes.first?.summary == "ok") }
        }
        let whole = await MaintenanceRun(steps: sql.steps(.integrityCheck, tables: [])).run(on: session)
        #expect(whole.first?.summary == "ok")
        // ANALYZE wrote statistics for the index.
        let stats = try await session.execute("SELECT count(*) FROM sqlite_stat1 WHERE tbl = 'my tracks'")
        #expect(stats.first?.rows.first?.first?.displayString != "0")
    }

    @Test func duckdbRunsAnalyzeAndCheckpoint() async throws {
        let url = TestFiles.url("fq-maintenance-\(UUID().uuidString).duckdb")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".wal")
        }
        let session = DatabaseSession(parameters: ConnectionParameters(config: ConnectionConfig(kind: .duckdb, filePath: url.path), password: ""))
        try await session.connect()
        defer { Task { await session.close() } }
        _ = try await session.execute("CREATE TABLE items (id INTEGER, name VARCHAR); INSERT INTO items VALUES (1, 'a'), (2, 'b')")
        let tables = try await session.run { try $0.tables(schema: "main") }
        let sql = MaintenanceSQL(kind: .duckdb)
        let outcomes = await MaintenanceRun(steps: sql.steps(.analyze, tables: tables) + sql.steps(.checkpoint, tables: tables)).run(on: session)
        #expect(outcomes.map(\.status) == [.ok, .ok], "\(outcomes.map(\.summary))")
    }

    @Test func aCancelledRunSkipsTheRest() async throws {
        let url = TestFiles.url("fq-maintenance-\(UUID().uuidString).sqlite")
        defer { TestFiles.removeDatabase(url) }
        let session = DatabaseSession(parameters: ConnectionParameters(config: ConnectionConfig(kind: .sqlite, filePath: url.path), password: ""))
        try await session.connect()
        defer { Task { await session.close() } }
        let run = MaintenanceRun(steps: [MaintenanceStep(table: nil, statement: "VACUUM"), MaintenanceStep(table: nil, statement: "PRAGMA integrity_check")])
        run.cancel()
        let outcomes = await run.run(on: session)
        #expect(outcomes.map(\.status) == [.skipped, .skipped])
        // A failing step does not stop the next one.
        let mixed = await MaintenanceRun(steps: [MaintenanceStep(table: TableRef(name: "gone"), statement: "ANALYZE \"gone\""), MaintenanceStep(table: nil, statement: "VACUUM")]).run(on: session)
        #expect(mixed.map(\.status) == [.failed, .ok])
    }
}

/// Every PostgreSQL command on scratch `fq_mt_<random>` tables in the foxlume test database, which the test drops.
@Suite("Maintenance on PostgreSQL", .serialized, .enabled(if: PostgresTestServer.isAvailable, "needs the PostgreSQL test server"))
struct PostgresMaintenanceLiveTests {
    private func session() async throws -> DatabaseSession {
        let config = ConnectionConfig(kind: .postgresql, host: PostgresTestServer.host, port: PostgresTestServer.port, user: "postgres", database: "foxlume", sslMode: .prefer)
        let session = DatabaseSession(parameters: ConnectionParameters(config: config, password: "postgres"))
        try await session.connect()
        return session
    }

    @Test func runsEveryCommandOutsideATransaction() async throws {
        let p = "fq_mt_" + UUID().uuidString.prefix(6).lowercased()
        let session = try await session()
        defer {
            Task {
                _ = try? await session.execute("DROP TABLE IF EXISTS public.\(p)_items CASCADE")
                await session.close()
            }
        }
        _ = try await session.execute("""
            CREATE TABLE public.\(p)_items (id integer PRIMARY KEY, note text);
            INSERT INTO public.\(p)_items SELECT g, md5(g::text) FROM generate_series(1, 500) g;
            DELETE FROM public.\(p)_items WHERE id % 2 = 0;
            CREATE MATERIALIZED VIEW public.\(p)_totals AS SELECT count(*) AS n FROM public.\(p)_items;
            """)
        let tables = try await session.run { try $0.tables(schema: "public") }.filter { $0.name.hasPrefix(p) }
        #expect(tables.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.materializedView, .table])
        let sql = MaintenanceSQL(kind: .postgresql)
        let expected: [MaintenanceOperation: String] = [.vacuum: "VACUUM", .vacuumAnalyze: "VACUUM", .analyze: "ANALYZE", .vacuumFull: "VACUUM", .reindex: "REINDEX"]
        for (operation, tag) in expected {
            let steps = sql.steps(operation, tables: tables)
            #expect(steps.count == 2)
            let outcomes = await MaintenanceRun(steps: steps).run(on: session)
            #expect(outcomes.map(\.status) == [.ok, .ok], "\(operation): \(outcomes.map(\.summary))")
            #expect(outcomes.allSatisfy { $0.messages.first == MaintenanceMessage(.info, tag) && ($0.elapsed ?? -1) >= 0 })
        }
        // ANALYZE updated the planner's row estimate.
        let estimate = try await session.execute("SELECT reltuples::bigint FROM pg_class WHERE oid = 'public.\(p)_items'::regclass")
        #expect(estimate.first?.rows.first?.first?.displayString == "250")

        // A table dropped meanwhile fails on its own; the other table still runs.
        let gone = MaintenanceStep(table: TableRef(schema: "public", name: "\(p)_gone"), statement: "VACUUM public.\(p)_gone")
        let outcomes = await MaintenanceRun(steps: [gone] + sql.steps(.vacuum, tables: tables)).run(on: session)
        #expect(outcomes.map(\.status) == [.failed, .ok, .ok])
        #expect(outcomes.first?.summary.contains("does not exist") == true)
    }

    @Test func cancelStopsAVacuumWaitingForALock() async throws {
        let p = "fq_mt_" + UUID().uuidString.prefix(6).lowercased()
        let session = try await session()
        let holder = try PostgresTestServer.connect()
        defer {
            _ = try? holder.execute("ROLLBACK", rowLimit: nil)
            _ = try? holder.execute("DROP TABLE IF EXISTS public.\(p)_locked", rowLimit: nil)
            holder.close()
            Task { await session.close() }
        }
        _ = try holder.execute("CREATE TABLE public.\(p)_locked (id integer)", rowLimit: nil)
        _ = try holder.execute("BEGIN; LOCK TABLE public.\(p)_locked IN ACCESS EXCLUSIVE MODE", rowLimit: nil)
        let table = TableInfo(ref: TableRef(schema: "public", name: "\(p)_locked"))
        let sql = MaintenanceSQL(kind: .postgresql)
        let run = MaintenanceRun(steps: sql.steps(.vacuum, tables: [table]) + sql.steps(.analyze, tables: [table]))
        let started = Date()
        let task = Task { await run.run(on: session) }
        try await Task.sleep(nanoseconds: 700_000_000)
        run.cancel()
        let outcomes = await task.value
        #expect(outcomes.map(\.status) == [.cancelled, .skipped])
        #expect(outcomes.first?.summary == "Stopped by Cancel")
        #expect(Date().timeIntervalSince(started) < 10)
        // The session is usable again.
        #expect(try await session.execute("SELECT 1").first?.rows.first?.first?.displayString == "1")
    }
}

/// Every MySQL command on scratch `fq_mt_<random>` tables in the foxlume test database, which the test drops.
@Suite("Maintenance on MySQL", .serialized, .enabled(if: MySQLTestServer.isAvailable, "needs the MySQL test server"))
struct MySQLMaintenanceLiveTests {
    private func session() async throws -> DatabaseSession {
        let session = DatabaseSession(parameters: MySQLTestServer.parameters())
        try await session.connect()
        return session
    }

    @Test func runsEveryCommandAndReadsTheMessageRows() async throws {
        let p = "fq_mt_" + UUID().uuidString.prefix(6).lowercased()
        let session = try await session()
        defer {
            Task {
                _ = try? await session.execute("DROP TABLE IF EXISTS \(p)_inno, \(p)_isam")
                await session.close()
            }
        }
        _ = try await session.execute("""
            CREATE TABLE \(p)_inno (id int PRIMARY KEY, note text) ENGINE=InnoDB;
            CREATE TABLE \(p)_isam (id int PRIMARY KEY, note text) ENGINE=MyISAM;
            INSERT INTO \(p)_inno VALUES (1, 'a'), (2, 'b');
            INSERT INTO \(p)_isam VALUES (1, 'a'), (2, 'b');
            """)
        let tables = try await session.run { try $0.tables(schema: "foxlume") }.filter { $0.name.hasPrefix(p) }
        #expect(tables.map(\.engine) == ["InnoDB", "MyISAM"])
        let sql = MaintenanceSQL(kind: .mysql)
        #expect(sql.operationGroups(for: tables).last != [.repair])
        #expect(sql.operationGroups(for: tables.filter { $0.engine == "MyISAM" }).last == [.repair])

        let optimized = await MaintenanceRun(steps: sql.steps(.optimize, tables: tables)).run(on: session)
        #expect(optimized.map(\.status) == [.ok, .ok], "\(optimized.map(\.summary))")
        #expect(optimized.first?.messages.contains { $0.level == .note && $0.text.contains("recreate + analyze") } == true)
        #expect(optimized.allSatisfy { $0.messages.last == MaintenanceMessage(.info, "OK") })
        for operation in [MaintenanceOperation.analyze, .check, .checkQuick, .checkExtended] {
            let outcomes = await MaintenanceRun(steps: sql.steps(operation, tables: tables)).run(on: session)
            #expect(outcomes.map(\.status) == [.ok, .ok], "\(operation): \(outcomes.map(\.summary))")
        }
        let repaired = await MaintenanceRun(steps: sql.steps(.repair, tables: tables)).run(on: session)
        #expect(repaired.map(\.status) == [.ok])

        // CHECK TABLE on a missing table answers with rows rather than an error.
        let missing = await MaintenanceRun(steps: [MaintenanceStep(table: TableRef(name: "\(p)_gone"), statement: "CHECK TABLE `\(p)_gone`")]).run(on: session)
        #expect(missing.first?.status == .failed)
        #expect(missing.first?.summary.contains("doesn't exist") == true)
    }

    @Test func cancelStopsAnOptimizeWaitingForALock() async throws {
        let p = "fq_mt_" + UUID().uuidString.prefix(6).lowercased()
        let session = try await session()
        let holder = try MySQLTestServer.connect()
        defer {
            _ = try? holder.execute("UNLOCK TABLES", rowLimit: nil)
            _ = try? holder.execute("DROP TABLE IF EXISTS \(p)_locked", rowLimit: nil)
            holder.close()
            Task { await session.close() }
        }
        _ = try holder.execute("CREATE TABLE \(p)_locked (id int PRIMARY KEY)", rowLimit: nil)
        _ = try holder.execute("LOCK TABLES \(p)_locked WRITE", rowLimit: nil)
        let table = TableInfo(ref: TableRef(schema: "foxlume", name: "\(p)_locked"), engine: "InnoDB")
        let sql = MaintenanceSQL(kind: .mysql)
        let run = MaintenanceRun(steps: sql.steps(.optimize, tables: [table]) + sql.steps(.analyze, tables: [table]))
        let started = Date()
        let task = Task { await run.run(on: session) }
        try await Task.sleep(nanoseconds: 700_000_000)
        run.cancel()
        let outcomes = await task.value
        #expect(outcomes.map(\.status) == [.cancelled, .skipped], "\(outcomes.map(\.summary))")
        #expect(outcomes.first?.summary.localizedCaseInsensitiveContains("interrupted") == true, "\(outcomes.map(\.summary))")
        #expect(outcomes.first?.messages.first == MaintenanceMessage(.warning, "Stopped by Cancel"))
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(try await session.execute("SELECT 1").first?.rows.first?.first?.displayString == "1")
    }
}

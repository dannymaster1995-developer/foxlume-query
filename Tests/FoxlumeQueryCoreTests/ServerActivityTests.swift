import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct ServerActivityTests {
    private func result(_ columns: [String], _ rows: [[String?]]) -> StatementResult {
        StatementResult(columns: columns.map { ResultColumn(name: $0) }, rows: rows.map { $0.map { $0.map(CellValue.text) ?? .null } })
    }

    @Test func supportedEnginesAndSessionQueries() {
        #expect(ServerActivitySQL.isSupported(.postgresql) && ServerActivitySQL.isSupported(.mysql) && ServerActivitySQL.isSupported(.mariadb))
        for kind in [DatabaseKind.sqlite, .duckdb, .mongodb, .redis] {
            #expect(!ServerActivitySQL.isSupported(kind))
            let sql = ServerActivitySQL(kind: kind)
            #expect(sql.sessionsQuery == nil && sql.slowQuerySourceQuery == nil && sql.statement(.cancelQuery, id: 1) == nil)
            #expect(sql.slowQueriesQuery(schema: "x", order: .totalTime) == nil)
        }
        let pg = ServerActivitySQL(kind: .postgresql, serverVersion: "16.2").sessionsQuery ?? ""
        #expect(pg.contains("FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND backend_type = 'client backend'"))
        #expect(pg.contains("extract(epoch FROM clock_timestamp() - query_start)"))
        // PostgreSQL 9.6 has no backend_type column.
        let old = ServerActivitySQL(kind: .postgresql, serverVersion: "9.6.24").sessionsQuery ?? ""
        #expect(!old.contains("backend_type"))
        let my = ServerActivitySQL(kind: .mysql, serverVersion: "8.4.9").sessionsQuery ?? ""
        #expect(my.contains("FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID()"))
        #expect(ServerActivitySQL(kind: .mariadb, serverVersion: "11.4.2-MariaDB").sessionsQuery == my)
    }

    @Test func parsesPostgresSessions() {
        let sql = ServerActivitySQL(kind: .postgresql, serverVersion: "18.6")
        let rows = result(
            ["pid", "username", "database", "application", "client", "state", "wait_event", "backend_start", "query_start", "running_seconds", "query"],
            [
                ["4711", "alice", "shop", "psql", "10.0.0.5:51234", "active", "Timeout: PgSleep", "2026-10-16 09:00:00", "2026-10-16 09:30:00", "12.500000", "SELECT pg_sleep(60)"],
                ["4712", "bob", "shop", "", "local socket", "idle", "Client: ClientRead", "2026-10-16 08:00:00", "2026-10-16 08:01:00", nil, "SELECT 1"],
                ["4713", "carol", "shop", "Foxlume Query", "127.0.0.1:5000", "idle in transaction", "", "", "", "3.25", "UPDATE t SET a = 1"],
                [nil, "ghost", "", "", "", "", "", "", "", nil, ""],
            ]
        )
        let sessions = sql.sessions(from: rows)
        #expect(sessions.map(\.id) == [4711, 4712, 4713])
        let first = sessions[0]
        #expect(first.user == "alice" && first.database == "shop" && first.application == "psql" && first.client == "10.0.0.5:51234")
        #expect(first.state == "active" && first.waitEvent == "Timeout: PgSleep" && first.queryStart == "2026-10-16 09:30:00")
        #expect(first.runningSeconds == 12.5 && !first.isIdle && first.query == "SELECT pg_sleep(60)")
        #expect(sessions[1].isIdle && sessions[1].runningSeconds == nil && sessions[1].runningSortKey == -1)
        #expect(!sessions[2].isIdle && sessions[2].runningSeconds == 3.25)
    }

    @Test func parsesMySQLSessions() {
        let sql = ServerActivitySQL(kind: .mysql, serverVersion: "8.4.9")
        let rows = result(
            ["id", "user", "host", "db", "command", "time", "state", "info"],
            [
                ["10", "root", "localhost:51000", "foxlume", "Query", "42", "User sleep", "SELECT SLEEP(60)"],
                ["11", "app", "10.0.0.9:3456", nil, "Sleep", "300", "", nil],
                ["5", "event_scheduler", "localhost", "", "Daemon", "122", "Waiting on empty queue", ""],
            ]
        )
        let sessions = sql.sessions(from: rows)
        #expect(sessions.map(\.id) == [10, 11, 5])
        #expect(sessions[0].client == "localhost:51000" && sessions[0].database == "foxlume" && sessions[0].command == "Query")
        #expect(sessions[0].state == "User sleep" && sessions[0].runningSeconds == 42 && !sessions[0].isIdle && sessions[0].query == "SELECT SLEEP(60)")
        // Sleeping and daemon threads are idle and have no running time.
        #expect(sessions[1].isIdle && sessions[1].runningSeconds == nil && sessions[1].database == "" && sessions[1].query == "")
        #expect(sessions[2].isIdle && sessions[2].runningSeconds == nil)
    }

    @Test func filtersHidesIdleSortsByRunningTimeAndMarksOwnSessions() {
        let sessions = [
            ServerActivitySession(id: 1, user: "alice", database: "shop", state: "idle", query: "SELECT 1", isIdle: true),
            ServerActivitySession(id: 2, user: "bob", database: "crm", state: "active", runningSeconds: 3, query: "SELECT pg_sleep(9)"),
            ServerActivitySession(id: 3, user: "carol", database: "shop", state: "active", runningSeconds: 40, query: "VACUUM orders"),
            ServerActivitySession(id: 4, user: "dave", database: "shop", state: "active", runningSeconds: 0.2, query: "SELECT now()"),
        ]
        #expect(ServerActivitySQL.visible(sessions, filter: "", hideIdle: true).map(\.id) == [3, 2, 4])
        #expect(ServerActivitySQL.visible(sessions, filter: "", hideIdle: false).map(\.id) == [3, 2, 4, 1])
        #expect(ServerActivitySQL.visible(sessions, filter: "SHOP", hideIdle: false).map(\.id) == [3, 4, 1])
        #expect(ServerActivitySQL.visible(sessions, filter: "pg_sleep", hideIdle: true).map(\.id) == [2])
        #expect(ServerActivitySQL.visible(sessions, filter: " bob ", hideIdle: true).map(\.id) == [2])
        #expect(ServerActivitySQL.visible(sessions, filter: "4", hideIdle: true).map(\.id) == [4])
        let marked = ServerActivitySQL.marking(sessions, owners: [2: "This window", 9: "Foxlume Query"])
        #expect(marked.map(\.owner) == [nil, "This window", nil, nil])
        #expect(ServerActivitySQL.visible(marked, filter: "this window", hideIdle: true).map(\.id) == [2])
    }

    @Test func actionStatementsAndOutcomes() {
        let pg = ServerActivitySQL(kind: .postgresql)
        #expect(pg.statement(.cancelQuery, id: 4711) == "SELECT pg_cancel_backend(4711)")
        #expect(pg.statement(.terminate, id: 4711) == "SELECT pg_terminate_backend(4711)")
        #expect(pg.title(.cancelQuery) == "Cancel Query" && pg.title(.terminate) == "Terminate Session")
        #expect(pg.outcome(of: [result(["pg_cancel_backend"], [["t"]])]) == .done)
        #expect(pg.outcome(of: [result(["pg_terminate_backend"], [["f"]])]) == .notFound)
        let denied = pg.outcome(of: DatabaseError.server(message: "permission denied to terminate process", code: "42501"))
        guard case .failed(let deniedText) = denied else { Issue.record("expected failed"); return }
        #expect(deniedText.contains("permission denied to terminate process") && deniedText.contains("pg_signal_backend"))
        #expect(pg.outcome(of: DatabaseError.queryTimeout(seconds: 5)) == .failed(DatabaseError.queryTimeout(seconds: 5).localizedDescription))

        let my = ServerActivitySQL(kind: .mariadb)
        #expect(my.statement(.cancelQuery, id: 12) == "KILL QUERY 12")
        #expect(my.statement(.terminate, id: 12) == "KILL CONNECTION 12")
        #expect(my.title(.cancelQuery) == "Kill Query" && my.title(.terminate) == "Kill Connection")
        #expect(my.outcome(of: [StatementResult(affectedRows: 0)]) == .done)
        #expect(my.outcome(of: DatabaseError.server(message: "Unknown thread id: 12", code: "1094/HY000")) == .notFound)
        guard case .failed(let notOwner) = my.outcome(of: DatabaseError.server(message: "You are not owner of thread 12", code: "1095")) else {
            Issue.record("expected failed")
            return
        }
        #expect(notOwner.contains("CONNECTION_ADMIN"))
        #expect(ServerSessionAction.terminate.isDestructive && !ServerSessionAction.cancelQuery.isDestructive)
    }

    @Test func slowQuerySourceStates() {
        let pg = ServerActivitySQL(kind: .postgresql, serverVersion: "16.1")
        #expect(pg.slowQuerySource(from: result(["nspname"], [])) == .unavailable(reason: "pg_stat_statements is not installed", hint: ServerActivitySQL.pgStatStatementsMissingHint))
        #expect(pg.slowQuerySource(from: nil) == pg.slowQuerySource(from: result(["nspname"], [])))
        #expect(pg.slowQuerySource(from: result(["nspname"], [["monitoring"]])) == .available(schema: "monitoring"))
        let notLoaded = pg.slowQuerySource(fromFailure: DatabaseError.server(message: "pg_stat_statements must be loaded via \"shared_preload_libraries\"", code: "55000"))
        guard case .unavailable(let reason, _)? = notLoaded else { Issue.record("expected unavailable"); return }
        #expect(reason == "pg_stat_statements is not loaded")
        #expect(pg.slowQuerySource(fromFailure: DatabaseError.server(message: "relation does not exist", code: "42P01")) == nil)

        let my = ServerActivitySQL(kind: .mysql, serverVersion: "8.4.9")
        #expect(my.slowQuerySource(from: result(["enabled", "digests"], [["1", "YES"]])) == .available(schema: "performance_schema"))
        guard case .unavailable(let off, _) = my.slowQuerySource(from: result(["enabled", "digests"], [["0", nil]])) else { Issue.record("expected off"); return }
        #expect(off == "performance_schema is off")
        guard case .unavailable(let noDigests, let hint) = my.slowQuerySource(from: result(["enabled", "digests"], [["1", "NO"]])) else { Issue.record("expected off"); return }
        #expect(noDigests == "Statement digests are not collected" && hint.contains("statements_digest"))
    }

    @Test func slowQueryStatementsPerVersion() {
        let pg16 = ServerActivitySQL(kind: .postgresql, serverVersion: "16.1").slowQueriesQuery(schema: "my schema", order: .totalTime, limit: 20) ?? ""
        #expect(pg16.contains(#"FROM "my schema".pg_stat_statements s"#))
        #expect(pg16.contains("s.total_exec_time / 1000.0 AS total_seconds") && pg16.hasSuffix("ORDER BY s.total_exec_time DESC NULLS LAST LIMIT 20"))
        let pg12 = ServerActivitySQL(kind: .postgresql, serverVersion: "12.18").slowQueriesQuery(schema: "public", order: .meanTime) ?? ""
        #expect(pg12.contains("s.total_time / 1000.0") && pg12.contains("ORDER BY s.mean_time DESC") && pg12.hasSuffix("LIMIT 50"))

        let mysql = ServerActivitySQL(kind: .mysql, serverVersion: "8.4.9").slowQueriesQuery(schema: "performance_schema", order: .meanTime) ?? ""
        #expect(mysql.contains("QUERY_SAMPLE_TEXT AS sample") && mysql.contains("ORDER BY AVG_TIMER_WAIT DESC LIMIT 50"))
        #expect(mysql.contains("FROM performance_schema.events_statements_summary_by_digest"))
        let mariadb = ServerActivitySQL(kind: .mysql, serverVersion: "11.4.2-MariaDB").slowQueriesQuery(schema: "performance_schema", order: .totalTime) ?? ""
        #expect(mariadb.contains("NULL AS sample") && mariadb.contains("ORDER BY SUM_TIMER_WAIT DESC"))
        #expect(ServerActivitySQL(kind: .mysql, serverVersion: "5.7.44").slowQueriesQuery(schema: "performance_schema", order: .totalTime)?.contains("NULL AS sample") == true)
    }

    @Test func parsesSlowQueryRows() {
        let pg = ServerActivitySQL(kind: .postgresql, serverVersion: "16.1")
        let pgRows = pg.slowQueries(from: result(
            ["query", "database", "username", "calls", "total_seconds", "mean_seconds", "rows"],
            [["SELECT * FROM orders WHERE id = $1", "shop", "alice", "1200", "36.000000", "0.030000", "1200"]]
        ))
        #expect(pgRows == [SlowQueryStat(id: 0, query: "SELECT * FROM orders WHERE id = $1", database: "shop", user: "alice", calls: 1200, totalSeconds: 36, meanSeconds: 0.03, rows: 1200)])
        #expect(pgRows.first?.runnableText == "SELECT * FROM orders WHERE id = $1")

        let my = ServerActivitySQL(kind: .mysql, serverVersion: "8.4.9")
        let myRows = my.slowQueries(from: result(
            ["query", "sample", "db", "calls", "total_seconds", "mean_seconds", "rows_sent", "rows_examined"],
            [
                ["SELECT `id` FROM `orders` WHERE `id` = ?", "SELECT id FROM orders WHERE id = 7", "shop", "3", "1.5000", "0.5000", "3", "6000"],
                ["SHOW TABLES", nil, nil, "1", "0.0010", "0.0010", "4", "4"],
            ]
        ))
        #expect(myRows.map(\.id) == [0, 1])
        #expect(myRows[0].calls == 3 && myRows[0].totalSeconds == 1.5 && myRows[0].rows == 3 && myRows[0].rowsExamined == 6000 && myRows[0].database == "shop")
        #expect(myRows[0].runnableText == "SELECT id FROM orders WHERE id = 7")
        #expect(myRows[1].sample == nil && myRows[1].runnableText == "SHOW TABLES" && myRows[1].database == "")
    }

    @Test func durationTextAndVersions() {
        #expect(ServerActivitySQL.durationText(nil) == "")
        #expect(ServerActivitySQL.durationText(0.25) == "250 ms")
        #expect(ServerActivitySQL.durationText(12.44) == "12.4 s")
        #expect(ServerActivitySQL.durationText(185) == "3 min 05 s")
        #expect(ServerActivitySQL.durationText(7_620) == "2 h 07 min")
        #expect(ServerActivitySQL(kind: .mysql, serverVersion: "11.4.2-MariaDB").isMariaDB)
        #expect(!ServerActivitySQL(kind: .mysql, serverVersion: "8.4.9").isMariaDB)
        #expect(ServerActivitySQL(kind: .postgresql, serverVersion: "9.6.24").versionParts == [9, 6, 24])
        #expect(ServerActivitySQL(kind: .postgresql, serverVersion: "18beta1").versionParts == [18, 0, 0])
        // Unknown versions count as current.
        #expect(ServerActivitySQL(kind: .postgresql).versionAtLeast(13))
    }
}

/// Polls pg_stat_activity, then cancels and terminates `pg_sleep` statements of sessions the test itself started.
@Suite("Server Activity on PostgreSQL", .serialized, .enabled(if: PostgresTestServer.isAvailable, "needs the PostgreSQL test server"))
struct PostgresServerActivityLiveTests {
    private func session(timeout: Int? = nil) async throws -> DatabaseSession {
        var config = ConnectionConfig(kind: .postgresql, host: PostgresTestServer.host, port: PostgresTestServer.port, user: "postgres", database: "foxlume", sslMode: .prefer)
        config.queryTimeout = timeout
        let session = DatabaseSession(parameters: ConnectionParameters(config: config, password: "postgres"))
        try await session.connect()
        return session
    }

    private func find(_ marker: String, on monitor: DatabaseSession, sql: ServerActivitySQL) async throws -> ServerActivitySession? {
        for _ in 0..<30 {
            let result = try await monitor.execute(sql.sessionsQuery ?? "").last(where: \.hasResultSet) ?? StatementResult()
            if let found = sql.sessions(from: result).first(where: { $0.query.contains(marker) && $0.state == "active" }) { return found }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    @Test func processIDsMatchTheServer() async throws {
        let session = try await session()
        defer { Task { await session.close() } }
        let pid = try await session.execute("SELECT pg_backend_pid()").first?.rows.first?.first?.textValue
        #expect(session.serverProcessID.map(String.init) == pid)
        #expect(DatabaseSession.liveSessions.contains { $0 === session })
        await session.close()
        #expect(session.serverProcessID == nil)
    }

    @Test func listsCancelsAndTerminatesASleepingSession() async throws {
        let marker = "fq112_" + UUID().uuidString.prefix(8).lowercased()
        let monitor = try await session(timeout: 5)
        let sleeper = try await session()
        defer { Task { await monitor.close(); await sleeper.close() } }
        let sql = ServerActivitySQL(kind: .postgresql, serverVersion: monitor.serverVersion)

        // The monitor leaves itself out of the list.
        let own = try await monitor.execute(sql.sessionsQuery ?? "").last(where: \.hasResultSet) ?? StatementResult()
        #expect(!sql.sessions(from: own).contains { $0.id == monitor.serverProcessID })

        let started = Date()
        let sleeping = Task { try await sleeper.execute("SELECT pg_sleep(30), '\(marker)'") }
        let found = try #require(try await find(marker, on: monitor, sql: sql))
        #expect(found.id == sleeper.serverProcessID)
        #expect(found.application == "Foxlume Query" && found.user == "postgres" && found.database == "foxlume" && !found.isIdle)
        #expect((found.runningSeconds ?? -1) >= 0 && !found.backendStart.isEmpty && !found.queryStart.isEmpty)

        let cancelled = sql.outcome(of: try await monitor.execute(sql.statement(.cancelQuery, id: found.id) ?? ""))
        #expect(cancelled == .done)
        await #expect(throws: DatabaseError.self) { try await sleeping.value }
        #expect(Date().timeIntervalSince(started) < 10)
        // Cancel leaves the session connected.
        #expect(try await sleeper.execute("SELECT 1").first?.rows.first?.first?.textValue == "1")

        let second = Task { try await sleeper.execute("SELECT pg_sleep(30), '\(marker)'") }
        let again = try #require(try await find(marker, on: monitor, sql: sql))
        #expect(sql.outcome(of: try await monitor.execute(sql.statement(.terminate, id: again.id) ?? "")) == .done)
        await #expect(throws: DatabaseError.self) { try await second.value }
        // The ended session is gone: a second terminate answers false.
        var gone = ServerSessionActionOutcome.done
        for _ in 0..<20 where gone != .notFound {
            gone = sql.outcome(of: try await monitor.execute(sql.statement(.terminate, id: again.id) ?? ""))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(gone == .notFound)
    }

    @Test func slowQueryReaderReportsTheExtensionState() async throws {
        let monitor = try await session(timeout: 5)
        defer { Task { await monitor.close() } }
        let sql = ServerActivitySQL(kind: .postgresql, serverVersion: monitor.serverVersion)
        let source = sql.slowQuerySource(from: try await monitor.execute(sql.slowQuerySourceQuery ?? "").last(where: \.hasResultSet))
        switch source {
        case .unavailable(let reason, let hint):
            // The test server does not install pg_stat_statements.
            #expect(reason == "pg_stat_statements is not installed" && hint.contains("CREATE EXTENSION pg_stat_statements"))
        case .available(let schema):
            do {
                let rows = sql.slowQueries(from: try await monitor.execute(sql.slowQueriesQuery(schema: schema, order: .meanTime) ?? "").last(where: \.hasResultSet) ?? StatementResult())
                #expect(rows.count <= 50)
            } catch {
                #expect(sql.slowQuerySource(fromFailure: error) != nil, "\(error)")
            }
        }
    }
}

/// Polls PROCESSLIST, then kills `SLEEP` statements of sessions the test itself started.
@Suite("Server Activity on MySQL", .serialized, .enabled(if: MySQLTestServer.isAvailable, "needs the MySQL test server"))
struct MySQLServerActivityLiveTests {
    private func session(timeout: Int? = nil) async throws -> DatabaseSession {
        var parameters = MySQLTestServer.parameters()
        parameters.config.queryTimeout = timeout
        let session = DatabaseSession(parameters: parameters)
        try await session.connect()
        return session
    }

    private func find(_ marker: String, on monitor: DatabaseSession, sql: ServerActivitySQL) async throws -> ServerActivitySession? {
        for _ in 0..<30 {
            let result = try await monitor.execute(sql.sessionsQuery ?? "").last(where: \.hasResultSet) ?? StatementResult()
            if let found = sql.sessions(from: result).first(where: { $0.query.contains(marker) && $0.command == "Query" }) { return found }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    @Test func listsAndKillsASleepingSession() async throws {
        let marker = "fq112_" + UUID().uuidString.prefix(8).lowercased()
        let monitor = try await session(timeout: 5)
        let sleeper = try await session()
        defer { Task { await monitor.close(); await sleeper.close() } }
        let sql = ServerActivitySQL(kind: .mysql, serverVersion: monitor.serverVersion)
        let connectionID = try await sleeper.execute("SELECT CONNECTION_ID()").first?.rows.first?.first?.textValue
        #expect(sleeper.serverProcessID.map(String.init) == connectionID)

        let started = Date()
        let sleeping = Task { try await sleeper.execute("SELECT SLEEP(30), '\(marker)'") }
        let found = try #require(try await find(marker, on: monitor, sql: sql))
        #expect(found.id == sleeper.serverProcessID)
        #expect(found.user == "root" && found.database == "foxlume" && !found.isIdle && (found.runningSeconds ?? -1) >= 0)

        #expect(sql.outcome(of: try await monitor.execute(sql.statement(.cancelQuery, id: found.id) ?? "")) == .done)
        // A killed SLEEP returns 1 instead of failing.
        _ = try? await sleeping.value
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(try await sleeper.execute("SELECT 1").first?.rows.first?.first?.textValue == "1")

        let second = Task { try await sleeper.execute("SELECT SLEEP(30), '\(marker)'") }
        let again = try #require(try await find(marker, on: monitor, sql: sql))
        #expect(sql.outcome(of: try await monitor.execute(sql.statement(.terminate, id: again.id) ?? "")) == .done)
        await #expect(throws: DatabaseError.self) { try await second.value }
        #expect(Date().timeIntervalSince(started) < 20)
        // Killing it again: Unknown thread id.
        var gone = ServerSessionActionOutcome.done
        do {
            _ = try await monitor.execute(sql.statement(.terminate, id: again.id) ?? "")
        } catch {
            gone = sql.outcome(of: error)
        }
        #expect(gone == .notFound)
    }

    @Test func slowQueryReaderReadsDigests() async throws {
        let monitor = try await session(timeout: 5)
        defer { Task { await monitor.close() } }
        let sql = ServerActivitySQL(kind: .mysql, serverVersion: monitor.serverVersion)
        _ = try await monitor.execute("SELECT COUNT(*) FROM information_schema.TABLES")
        let source = sql.slowQuerySource(from: try await monitor.execute(sql.slowQuerySourceQuery ?? "").last(where: \.hasResultSet))
        // The test server runs with performance_schema on.
        #expect(source == .available(schema: "performance_schema"))
        for order in SlowQueryOrder.allCases {
            let query = try #require(sql.slowQueriesQuery(schema: "performance_schema", order: order, limit: 10))
            let rows = sql.slowQueries(from: try await monitor.execute(query).last(where: \.hasResultSet) ?? StatementResult())
            #expect(!rows.isEmpty && rows.count <= 10)
            #expect(rows.allSatisfy { !$0.query.isEmpty && $0.calls > 0 && $0.totalSeconds >= $0.meanSeconds })
            let keys = rows.map { order == .totalTime ? $0.totalSeconds : $0.meanSeconds }
            #expect(keys == keys.sorted(by: >))
        }
    }
}

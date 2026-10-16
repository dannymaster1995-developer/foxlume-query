import Foundation
import Testing
@testable import FoxlumeQueryCore

/// Per-connection query timeout and "Run on connect" statements (FQ-107).
@Suite("Query timeout and startup commands")
struct SessionSetupTests {
    // MARK: - Saved settings

    @Test func oldConnectionsDecodeAndNewFieldsRoundTrip() throws {
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConnectionConfig(kind: .postgresql, host: "db"))) as? [String: Any] ?? [:]
        #expect(legacy["queryTimeout"] == nil && legacy["startupCommands"] == nil, "unset fields are not written")
        legacy.removeValue(forKey: "queryTimeout")
        legacy.removeValue(forKey: "startupCommands")
        let old = try JSONDecoder().decode(ConnectionConfig.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.queryTimeout == nil && old.startupCommands == nil && old.effectiveQueryTimeout == nil)

        var config = ConnectionConfig(kind: .mysql, host: "db")
        config.queryTimeout = 30
        config.startupCommands = "SET time_zone = '+00:00';\nSET NAMES utf8mb4;"
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.queryTimeout == 30)
        #expect(decoded.startupCommands == config.startupCommands)
        #expect(decoded == config)
    }

    @Test func onlyAPositiveTimeoutOnASQLEngineLimits() {
        var config = ConnectionConfig(kind: .postgresql)
        #expect(config.effectiveQueryTimeout == nil)
        config.queryTimeout = 0
        #expect(config.effectiveQueryTimeout == nil)
        config.queryTimeout = -5
        #expect(config.effectiveQueryTimeout == nil)
        config.queryTimeout = 15
        #expect(config.effectiveQueryTimeout == 15)
        config.kind = .redis
        #expect(config.effectiveQueryTimeout == nil)
    }

    @Test func startupStatementsSkipEmptyAndCommentOnlyPieces() {
        var config = ConnectionConfig(kind: .postgresql)
        #expect(SessionSetup.startupStatements(config, family: .postgresql).isEmpty)
        config.startupCommands = "-- schemas first\nSET search_path TO app, public;\n\n;  ;\nSET work_mem = '64MB'"
        #expect(SessionSetup.startupStatements(config, family: .postgresql).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            == ["-- schemas first\nSET search_path TO app, public", "SET work_mem = '64MB'"])
        config.kind = .mongodb
        #expect(SessionSetup.startupStatements(config, family: .postgresql).isEmpty)
    }

    @Test func readOnlyConnectionsAllowSessionSettingsButNotWrites() {
        for allowed in [
            "SET search_path TO app, public", "SET time_zone = '+00:00'", "SET NAMES utf8mb4", "set session sql_mode = 'ANSI'",
            "SELECT set_config('application_name', 'x', false)", "PRAGMA cache_size = -2000", "SET @@session.time_zone = 'UTC'",
        ] {
            #expect(!SessionSetup.isRefusedOnReadOnly(allowed), "\(allowed)")
        }
        for refused in [
            "INSERT INTO audit VALUES (1)", "CREATE TEMP TABLE t (id int)", "UPDATE t SET x = 1", "SET GLOBAL max_connections = 10",
            "SET PERSIST sql_mode = ''", "SET @@global.time_zone = 'UTC'", "SET TRANSACTION READ WRITE",
            "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE", "SET default_transaction_read_only = off",
            "SET SESSION transaction_read_only = 0", "SET PASSWORD = 'x'", "WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x",
        ] {
            #expect(SessionSetup.isRefusedOnReadOnly(refused), "\(refused)")
        }

        var config = ConnectionConfig(kind: .postgresql)
        config.startupCommands = "SET search_path TO app;\nINSERT INTO audit\nVALUES (1);"
        #expect(SessionSetup.readOnlyRefusal(config, family: .postgresql) == nil, "only Read-Only refuses")
        config.safeModeLevel = .readOnly
        let message = SessionSetup.readOnlyRefusal(config, family: .postgresql)?.localizedDescription ?? ""
        #expect(message.contains("“INSERT INTO audit VALUES (1)”"), "\(message)")
        #expect(message.contains("Read-Only"))
    }

    @Test func timeoutMessageNamesTheSeconds() {
        #expect(DatabaseError.queryTimeout(seconds: 1).localizedDescription == "The query was stopped after 1 second by the connection's query timeout.")
        #expect(DatabaseError.queryTimeout(seconds: 30).localizedDescription == "The query was stopped after 30 seconds by the connection's query timeout.")
        #expect(!DatabaseError.queryTimeout(seconds: 5).isConnectionLoss)
        #expect(DatabaseSession.isServerTimeout(DatabaseError.server(message: "canceling statement due to statement timeout", code: "57014")))
        #expect(!DatabaseSession.isServerTimeout(DatabaseError.server(message: "canceling statement due to user request", code: "57014")))
        #expect(DatabaseSession.isServerTimeout(DatabaseError.server(message: "Query execution was interrupted, maximum statement execution time exceeded", code: "3024/HY000")))
        #expect(!DatabaseSession.isServerTimeout(DatabaseError.cancelled))
    }

    // MARK: - SQLite

    static func sqliteSession(_ url: URL, timeout: Int? = nil, startup: String? = nil, readOnly: Bool = false) -> DatabaseSession {
        var config = ConnectionConfig(kind: .sqlite, filePath: url.path, readOnly: readOnly)
        config.queryTimeout = timeout
        config.startupCommands = startup
        return DatabaseSession(parameters: ConnectionParameters(config: config, password: ""))
    }

    static func expectTimeout(_ seconds: Int, within limit: TimeInterval, _ body: () async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) async {
        let began = Date()
        do {
            try await body()
            Issue.record("The statement was not stopped.", sourceLocation: sourceLocation)
        } catch DatabaseError.queryTimeout(let reported) {
            #expect(reported == seconds, sourceLocation: sourceLocation)
        } catch {
            Issue.record("Expected the query timeout, got \(error)", sourceLocation: sourceLocation)
        }
        let elapsed = Date().timeIntervalSince(began)
        #expect(elapsed > Double(seconds) - 0.1 && elapsed < limit, "stopped after \(elapsed) s", sourceLocation: sourceLocation)
    }

    @Test func sqliteTimeoutStopsALongStatementAndTheSessionStaysUsable() async throws {
        let url = TestFiles.url("timeout-\(UUID().uuidString).sqlite")
        defer { TestFiles.removeDatabase(url) }
        let session = Self.sqliteSession(url, timeout: 1)
        try await session.connect()
        #expect(session.queryTimeout == 1)
        await Self.expectTimeout(1, within: 4) {
            _ = try await session.execute("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000000000) SELECT count(*) FROM c")
        }
        #expect(try await session.execute("SELECT 'alive'")[0].rows == [[.text("alive")]])
        // A statement that finishes in time is untouched, and the expired timer does not reach it.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(try await session.execute("SELECT 2")[0].rows == [[.text("2")]])
        await session.close()
    }

    @Test func sqliteStartupCommandsRunOnConnectAndReconnect() async throws {
        let url = TestFiles.url("startup-\(UUID().uuidString).sqlite")
        defer { TestFiles.removeDatabase(url) }
        let session = Self.sqliteSession(url, startup: "-- cache\nPRAGMA cache_size = -1234;\nPRAGMA foreign_keys = OFF;")
        try await session.connect()
        #expect(try await session.execute("PRAGMA cache_size")[0].rows == [[.text("-1234")]])
        #expect(try await session.execute("PRAGMA foreign_keys")[0].rows == [[.text("0")]])
        try await session.reconnect()
        #expect(try await session.execute("PRAGMA cache_size")[0].rows == [[.text("-1234")]])
        await session.close()
    }

    @Test func failingStartupCommandStopsTheConnectAndNamesTheStatement() async throws {
        let url = TestFiles.url("startup-fail-\(UUID().uuidString).sqlite")
        defer { TestFiles.removeDatabase(url) }
        let session = Self.sqliteSession(url, startup: "PRAGMA cache_size = -1234;\nSELECT * FROM\n  missing_table;")
        do {
            try await session.connect()
            Issue.record("The connect succeeded.")
        } catch {
            let message = error.localizedDescription
            #expect(message.hasPrefix("Run on connect: “SELECT * FROM missing_table” failed:"), "\(message)")
            #expect(message.contains("no such table"), "\(message)")
        }
        #expect(!session.isConnected)
    }

    @Test func readOnlyConnectionRefusesAWritingStartupCommand() async throws {
        let url = TestFiles.url("startup-ro-\(UUID().uuidString).sqlite")
        defer { TestFiles.removeDatabase(url) }
        let creator = Self.sqliteSession(url)
        try await creator.connect()
        _ = try await creator.execute("CREATE TABLE t (id INTEGER)")
        await creator.close()

        let refused = Self.sqliteSession(url, startup: "PRAGMA cache_size = -100; DELETE FROM t;", readOnly: true)
        do {
            try await refused.connect()
            Issue.record("The connect succeeded.")
        } catch {
            #expect(error.localizedDescription.contains("“DELETE FROM t” may change data, and this connection is Read-Only"), "\(error)")
        }
        let allowed = Self.sqliteSession(url, startup: "PRAGMA cache_size = -100;", readOnly: true)
        try await allowed.connect()
        #expect(try await allowed.execute("PRAGMA cache_size")[0].rows == [[.text("-100")]])
        await allowed.close()
    }

    // MARK: - DuckDB

    @Test func duckdbTimeoutStopsALongStatementAndStartupCommandsApply() async throws {
        var config = ConnectionConfig(kind: .duckdb, filePath: "")
        config.queryTimeout = 1
        config.startupCommands = "SET threads = 2;"
        let session = DatabaseSession(parameters: ConnectionParameters(config: config, password: ""))
        try await session.connect()
        #expect(try await session.execute("SELECT current_setting('threads')")[0].rows.first?.first?.textValue == "2")
        await Self.expectTimeout(1, within: 4) {
            _ = try await session.execute("SELECT sum(hash(range)) FROM range(100000000000)")
        }
        #expect(try await session.execute("SELECT 'alive'")[0].rows == [[.text("alive")]])
        await session.close()
    }
}

@Suite("Query timeout and startup commands against PostgreSQL", .serialized, .enabled(if: PostgresTestServer.isAvailable))
struct PostgresSessionSetupTests {
    static func session(timeout: Int? = nil, startup: String? = nil, readOnly: Bool = false) -> DatabaseSession {
        var config = ConnectionConfig(kind: .postgresql, host: PostgresTestServer.host, port: PostgresTestServer.port, user: "postgres", database: "foxlume", readOnly: readOnly)
        config.queryTimeout = timeout
        config.startupCommands = startup
        return DatabaseSession(parameters: ConnectionParameters(config: config, password: "postgres"))
    }

    static func text(_ session: DatabaseSession, _ sql: String) async throws -> String? {
        try await session.execute(sql)[0].rows.first?.first?.textValue
    }

    @Test func timeoutStopsPgSleepThroughTheCancelRequest() async throws {
        let session = Self.session(timeout: 1)
        try await session.connect()
        // The server's own limit sits a second behind the client's, as a backstop.
        #expect(try await Self.text(session, "SHOW statement_timeout") == "2s")
        await SessionSetupTests.expectTimeout(1, within: 3) {
            _ = try await session.execute("SELECT pg_sleep(5)")
        }
        #expect(try await Self.text(session, "SELECT 'alive'") == "alive")
        // The server limit firing first is reported the same way.
        _ = try await session.execute("SET statement_timeout = 300")
        let began = Date()
        do {
            _ = try await session.execute("SELECT pg_sleep(5)")
            Issue.record("The statement was not stopped.")
        } catch DatabaseError.queryTimeout(let seconds) {
            #expect(seconds == 1)
        } catch {
            Issue.record("Expected the query timeout, got \(error)")
        }
        #expect(Date().timeIntervalSince(began) < 0.9)
        await session.close()
    }

    @Test func metadataReadsAreNotLimited() async throws {
        let session = Self.session(timeout: 1)
        try await session.connect()
        // `run` is how the catalog is read; only the server backstop (2 s) could stop it.
        let rows = try await session.run { try $0.execute("SELECT pg_sleep(1.3), 'done'", rowLimit: nil) }
        #expect(rows[0].rows.first?.last?.textValue == "done")
        await session.close()
    }

    @Test func startupCommandsTakeEffectAndSurviveReconnectAndDatabaseSwitch() async throws {
        let session = Self.session(startup: "SET search_path TO fq_startup_schema, public;\nSET application_name = 'fq-startup';")
        try await session.connect()
        #expect(try await Self.text(session, "SHOW search_path") == "fq_startup_schema, public")
        #expect(try await Self.text(session, "SHOW application_name") == "fq-startup")
        #expect(try await Self.text(session, "SHOW statement_timeout") == "0", "no query timeout, no server limit")
        try await session.reconnect()
        #expect(try await Self.text(session, "SHOW search_path") == "fq_startup_schema, public")
        // PostgreSQL switches databases by opening a new session.
        try await session.run { try $0.useDatabase("postgres") }
        #expect(try await Self.text(session, "SELECT current_database()") == "postgres")
        #expect(try await Self.text(session, "SHOW search_path") == "fq_startup_schema, public")
        await session.close()
    }

    @Test func failingStartupCommandStopsTheConnect() async throws {
        let session = Self.session(startup: "SET search_path TO public;\nSET fq_no_such_setting TO 1;")
        do {
            try await session.connect()
            Issue.record("The connect succeeded.")
        } catch {
            let message = error.localizedDescription
            #expect(message.hasPrefix("Run on connect: “SET fq_no_such_setting TO 1” failed:"), "\(message)")
            #expect(message.contains("fq_no_such_setting"), "\(message)")
        }
        #expect(!session.isConnected)
    }

    @Test func readOnlyConnectionRefusesWritesButRunsSettings() async throws {
        let refused = Self.session(startup: "SET search_path TO public;\nCREATE TEMP TABLE fq_scratch (id int);", readOnly: true)
        do {
            try await refused.connect()
            Issue.record("The connect succeeded.")
        } catch {
            #expect(error.localizedDescription.contains("“CREATE TEMP TABLE fq_scratch (id int)” may change data"), "\(error)")
        }
        let allowed = Self.session(startup: "SET search_path TO fq_ro, public;", readOnly: true)
        try await allowed.connect()
        #expect(try await Self.text(allowed, "SHOW search_path") == "fq_ro, public")
        await allowed.close()
    }
}

@Suite("Query timeout and startup commands against MySQL", .serialized, .enabled(if: MySQLTestServer.isAvailable))
struct MySQLSessionSetupTests {
    static func session(timeout: Int? = nil, startup: String? = nil, readOnly: Bool = false) -> DatabaseSession {
        var parameters = MySQLTestServer.parameters()
        parameters.config.queryTimeout = timeout
        parameters.config.startupCommands = startup
        parameters.config.readOnly = readOnly
        return DatabaseSession(parameters: parameters)
    }

    static func text(_ session: DatabaseSession, _ sql: String) async throws -> String? {
        try await session.execute(sql)[0].rows.first?.first?.textValue
    }

    @Test func timeoutStopsSleepWithKillQuery() async throws {
        let session = Self.session(timeout: 1)
        try await session.connect()
        #expect(try await Self.text(session, "SELECT @@session.max_execution_time") == "2000")
        // A killed SLEEP returns 1 instead of failing; it is still reported as stopped.
        await SessionSetupTests.expectTimeout(1, within: 3.5) {
            _ = try await session.execute("SELECT SLEEP(5)")
        }
        #expect(try await Self.text(session, "SELECT 'alive'") == "alive")
        await session.close()
    }

    @Test func startupCommandsTakeEffectAndSurviveReconnect() async throws {
        let session = Self.session(startup: "SET time_zone = '+03:00';\nSET @fq_marker = 'set on connect';")
        try await session.connect()
        #expect(try await Self.text(session, "SELECT @@session.time_zone") == "+03:00")
        #expect(try await Self.text(session, "SELECT @fq_marker") == "set on connect")
        try await session.reconnect()
        #expect(try await Self.text(session, "SELECT @@session.time_zone") == "+03:00")
        await session.close()
    }

    @Test func failingStartupCommandStopsTheConnect() async throws {
        let session = Self.session(startup: "SET time_zone = 'Not/AZone';")
        do {
            try await session.connect()
            Issue.record("The connect succeeded.")
        } catch {
            let message = error.localizedDescription
            #expect(message.hasPrefix("Run on connect: “SET time_zone = 'Not/AZone'” failed:"), "\(message)")
            #expect(message.contains("Not/AZone"), "\(message)")
        }
        #expect(!session.isConnected)
    }

    @Test func readOnlyConnectionRefusesAWritingStartupCommand() async throws {
        let session = Self.session(startup: "SET time_zone = '+00:00'; SET GLOBAL max_connections = 500;", readOnly: true)
        do {
            try await session.connect()
            Issue.record("The connect succeeded.")
        } catch {
            #expect(error.localizedDescription.contains("“SET GLOBAL max_connections = 500” may change data"), "\(error)")
        }
    }
}

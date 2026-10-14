import Foundation
import Testing
@testable import FoxlumeQueryCore

// MARK: - Protocol and authentication (no server needed)

@Suite("Postgres protocol")
struct PostgresProtocolTests {
    /// RFC 7677 section 3.
    @Test func scramMatchesRFC7677Vector() throws {
        var client = SCRAMSHA256Client(username: "user", password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO")
        #expect(client.clientFirstMessage == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
        let final = try client.clientFinalMessage(
            serverFirstMessage: "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
        )
        #expect(final == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        try client.verifyServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
    }

    @Test func scramRejectsWrongServerSignature() throws {
        var client = SCRAMSHA256Client(username: "user", password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO")
        _ = try client.clientFinalMessage(
            serverFirstMessage: "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
        )
        let error = #expect(throws: DatabaseError.self) {
            try client.verifyServerFinal("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        }
        #expect(error.map(Self.isAuthentication) == true)
    }

    @Test func scramRejectsNonceThatDoesNotExtendTheClientNonce() {
        var client = SCRAMSHA256Client(password: "pencil", clientNonce: "abc")
        #expect(throws: DatabaseError.self) {
            _ = try client.clientFinalMessage(serverFirstMessage: "r=xyz123,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
        }
    }

    @Test func scramReportsServerError() {
        let client = SCRAMSHA256Client(password: "pencil", clientNonce: "abc")
        #expect(throws: DatabaseError.self) { try client.verifyServerFinal("e=invalid-proof") }
    }

    @Test func scramEscapesUserNameAndUsesEmptyNameByDefault() {
        #expect(SCRAMSHA256Client(username: "a=b,c", password: "x", clientNonce: "n").clientFirstMessageBare == "n=a=3Db=2Cc,r=n")
        #expect(SCRAMSHA256Client(password: "x", clientNonce: "n").clientFirstMessage == "n,,n=,r=n")
        #expect(SCRAMSHA256Client.makeNonce().count == 24)
    }

    @Test func saslPrepNormalizesLikePostgres() {
        #expect(SCRAMSHA256Client.saslPrep("plain ascii") == "plain ascii")
        #expect(SCRAMSHA256Client.saslPrep("a\u{00A0}b") == "a b")
        #expect(SCRAMSHA256Client.saslPrep("I\u{00AD}X") == "IX")
        #expect(SCRAMSHA256Client.saslPrep("\u{2168}") == "IX")
        #expect(SCRAMSHA256Client.saslPrep("e\u{0301}") == "\u{00E9}")
        // Prohibited characters make PostgreSQL use the raw password instead.
        #expect(SCRAMSHA256Client.saslPrep("é\u{0007}") == "é\u{0007}")
    }

    @Test func md5PasswordHash() {
        // md5(md5("md5pass" + "md5user") hex + salt) computed with the system md5 tool.
        let hashed = PostgresFrontend.md5Password(user: "md5user", password: "md5pass", salt: [1, 2, 3, 4])
        #expect(hashed == "md5b5dfd8fbdd6fc9174cc8e85dfa598fa2")
    }

    @Test func frontendMessageLayout() {
        #expect(PostgresFrontend.sslRequest() == [0, 0, 0, 8, 0x04, 0xD2, 0x16, 0x2F])
        #expect(PostgresFrontend.terminate() == [UInt8(ascii: "X"), 0, 0, 0, 4])
        #expect(PostgresFrontend.query("SELECT 1") == [UInt8(ascii: "Q"), 0, 0, 0, 13] + Array("SELECT 1".utf8) + [0])

        let startup = PostgresFrontend.startup(parameters: [("user", "u")])
        #expect(startup == [0, 0, 0, 16, 0, 3, 0, 0] + Array("user".utf8) + [0, UInt8(ascii: "u"), 0, 0])

        // Protocol 3.2 keys can be longer than four bytes; the length follows the key.
        let cancel = PostgresFrontend.cancelRequest(processID: 42, secretKey: Array(repeating: 7, count: 32))
        #expect(cancel.count == 44)
        #expect(Array(cancel.prefix(12)) == [0, 0, 0, 44, 0x04, 0xD2, 0x16, 0x2E, 0, 0, 0, 42])
    }

    @Test func typeNames() {
        #expect(PostgresType.name(oid: 23) == "int4")
        #expect(PostgresType.name(oid: 1184) == "timestamptz")
        #expect(PostgresType.name(oid: 3802) == "jsonb")
        #expect(PostgresType.name(oid: 1007) == "int4[]")
        #expect(PostgresType.name(oid: 1009) == "text[]")
        #expect(PostgresType.name(oid: 987_654) == "oid:987654")
        #expect(PostgresType.isNumeric(oid: 1700))
        #expect(PostgresType.isNumeric(oid: 790))
        #expect(PostgresType.isNumeric(oid: 26))
        #expect(!PostgresType.isNumeric(oid: 25))
        #expect(!PostgresType.isNumeric(oid: 1007))
    }

    @Test(arguments: [
        ("INSERT 0 5", false, 5),
        ("UPDATE 3", false, 3),
        ("DELETE 0", false, 0),
        ("MERGE 2", false, 2),
        ("COPY 7", false, 7),
        ("MOVE 4", false, 4),
        ("FETCH 9", false, 9),
        ("SELECT 12", false, 12),
        ("INSERT 0 2", true, 2),
    ])
    func commandTagRowCounts(tag: String, hasResultSet: Bool, expected: Int) {
        #expect(PostgresParser.affectedRows(commandTag: tag, hasResultSet: hasResultSet) == expected)
    }

    @Test(arguments: [("SELECT 12", true), ("FETCH 3", true), ("CREATE TABLE", false), ("BEGIN", false)])
    func commandTagsWithoutRowCounts(tag: String, hasResultSet: Bool) {
        #expect(PostgresParser.affectedRows(commandTag: tag, hasResultSet: hasResultSet) == nil)
    }

    @Test func errorResponseFields() throws {
        var payload: [UInt8] = []
        for (code, value) in [("S", "ERREUR"), ("V", "ERROR"), ("C", "23505"), ("M", "duplicate key"), ("D", "Key (id)=(1) exists."), ("H", "Use another id.")] {
            payload += Array(code.utf8) + Array(value.utf8) + [0]
        }
        payload.append(0)
        let error = try PostgresServerError(payload: payload)
        #expect(error.severity == "ERROR")
        #expect(!error.isFatal)
        guard case let .server(message, code, detail) = error.databaseError else {
            Issue.record("expected a server error")
            return
        }
        #expect(message == "duplicate key")
        #expect(code == "23505")
        #expect(detail == "Key (id)=(1) exists.\nHint: Use another id.")
    }

    @Test func dataRowParsing() throws {
        let text = Array("Müller".utf8)
        var payload: [UInt8] = [0, 3]
        payload += [0xFF, 0xFF, 0xFF, 0xFF]
        payload += [0, 0, 0, UInt8(text.count)] + text
        payload += [0, 0, 0, 0]
        let row = try PostgresParser.dataRow(payload)
        #expect(row == [.null, .text("Müller"), .text("")])

        #expect(throws: DatabaseError.self) { try PostgresParser.dataRow([0, 1, 0, 0, 0, 9, 65]) }
    }

    @Test func rowDescriptionParsing() throws {
        var payload: [UInt8] = [0, 1]
        payload += Array("id".utf8) + [0]
        payload += [0, 0, 0x40, 0x00] + [0, 1] + [0, 0, 0, 23] + [0, 4] + [0xFF, 0xFF, 0xFF, 0xFF] + [0, 0]
        let columns = try PostgresParser.rowDescription(payload)
        #expect(columns.count == 1)
        #expect(columns.first?.typeOID == 23)
        #expect(columns.first?.tableOID == 0x4000)
        #expect(columns.first?.resultColumn == ResultColumn(name: "id", typeName: "int4", isNumeric: true))
    }

    static func isAuthentication(_ error: DatabaseError) -> Bool {
        if case .authentication = error { return true }
        return false
    }
}

// MARK: - Live server

enum PostgresTestServer {
    static let host = ProcessInfo.processInfo.environment["FQ_PG_HOST"] ?? "127.0.0.1"
    static let port = Int(ProcessInfo.processInfo.environment["FQ_PG_PORT"] ?? "") ?? 55432

    static let isAvailable: Bool = {
        let transport = SocketTransport()
        defer { transport.close() }
        return (try? transport.connect(host: host, port: port, timeout: 1)) != nil
    }()

    static func connect(
        user: String = "postgres",
        password: String = "postgres",
        database: String = "foxlume",
        sslMode: SSLMode = .prefer
    ) throws -> PostgresConnection {
        let connection = make(user: user, password: password, database: database, sslMode: sslMode)
        try connection.connect()
        return connection
    }

    static func make(user: String, password: String, database: String = "foxlume", sslMode: SSLMode = .prefer) -> PostgresConnection {
        let config = ConnectionConfig(kind: .postgresql, host: host, port: port, user: user, database: database, sslMode: sslMode)
        return PostgresConnection(parameters: ConnectionParameters(config: config, password: password))
    }
}

@Suite("Postgres live server", .enabled(if: PostgresTestServer.isAvailable, "needs the PostgreSQL test server"))
struct PostgresLiveTests {
    @Test func createAndDropDatabase() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let objects = DatabaseObjectSQL(kind: .postgresql)
        _ = try? connection.execute(try #require(objects.dropDatabase("fq_db_probe")), rowLimit: nil)
        _ = try connection.execute(try #require(objects.createDatabase("fq_db_probe")), rowLimit: nil)
        #expect(try connection.databases().contains("fq_db_probe"))
        _ = try connection.execute(try #require(objects.dropDatabase("fq_db_probe")), rowLimit: nil)
        #expect(try !connection.databases().contains("fq_db_probe"))
        let schema = try #require(objects.createSchema("fq_db_probe_schema"))
        _ = try connection.execute(schema, rowLimit: nil)
        #expect(try connection.schemas().contains("fq_db_probe_schema"))
        _ = try connection.execute(try #require(objects.dropSchema("fq_db_probe_schema", cascade: true)), rowLimit: nil)
        #expect(try !connection.schemas().contains("fq_db_probe_schema"))
    }

    @Test func searchAllRowsMatchesWildcardsLiterally() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        _ = try connection.execute("CREATE TEMP TABLE search_probe (id INT, note VARCHAR(40))", rowLimit: nil)
        let values = ["50% off", "500 items", "a_b", "axb", #"C:\temp"#, "Zoe MULLER"].enumerated()
            .map { "(\($0.offset + 1), \(SQLDialect.postgresql.quoteString($0.element)))" }.joined(separator: ", ")
        _ = try connection.execute("INSERT INTO search_probe VALUES \(values)", rowLimit: nil)
        func ids(_ text: String) throws -> [String] {
            let condition = TableQuery.anyColumnContains(text, columns: ["id", "note"], dialect: .postgresql)
            return try connection.execute("SELECT id FROM search_probe WHERE \(condition) ORDER BY id", rowLimit: nil)[0].rows.map { $0[0].displayString }
        }
        #expect(try ids("50%") == ["1"])
        #expect(try ids("a_b") == ["3"])
        #expect(try ids(#"C:\temp"#) == ["5"])
        // Case folding of non-ASCII letters depends on the database collation, so check ASCII here.
        #expect(try ids("muller") == ["6"])
        #expect(try ids("4") == ["4"])
    }

    @Test func gridEditsCanSetDefaultAndCurrentTimestamp() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        _ = try connection.execute("CREATE TEMP TABLE expr_edit (id INT PRIMARY KEY, status VARCHAR(20) DEFAULT 'new', touched timestamptz NULL)", rowLimit: nil)
        _ = try connection.execute("INSERT INTO expr_edit VALUES (1, 'old', NULL)", rowLimit: nil)
        let page = try connection.fetchRows(TableQuery(table: TableRef(name: "expr_edit"), pageSize: 10))
        var changes = PendingChanges()
        changes.setValue(.expression("DEFAULT"), row: 0, column: 1, original: page.rows[0][1])
        changes.setValue(.expression("CURRENT_TIMESTAMP"), row: 0, column: 2, original: page.rows[0][2])
        changes.addInsertion([.value(.text("2")), .value(.expression("DEFAULT")), .value(.expression("CURRENT_TIMESTAMP"))])
        try connection.applyChanges(ChangeBatch(table: TableRef(name: "expr_edit"), columns: page.columns, primaryKey: ["id"], originalRows: page.rows, changes: changes))
        let rows = try connection.execute("SELECT id, status, touched IS NOT NULL FROM expr_edit ORDER BY id", rowLimit: nil)[0].rows
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0[1] == .text("new") })
        #expect(rows.allSatisfy { ["t", "1"].contains($0[2].displayString) })
    }

    @Test func scramLoginOverTLS() throws {
        let connection = try PostgresTestServer.connect(sslMode: .require)
        defer { connection.close() }
        #expect(connection.isTLS)
        #expect(connection.serverVersion.first?.isNumber == true)
        #expect(!connection.serverVersion.contains(" "))
        #expect(connection.serverVersionNumber >= 100_000)
        #expect(connection.currentDatabase == "foxlume")
        #expect(connection.defaultSchema == "public")
        let ssl = try connection.rows("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
        #expect(ssl.first?.first == .text("t"))
    }

    @Test func plaintextWhenDisabled() throws {
        let connection = try PostgresTestServer.connect(sslMode: .disable)
        defer { connection.close() }
        #expect(!connection.isTLS)
        #expect(try connection.rows("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()").first?.first == .text("f"))
    }

    @Test func verifyFullRejectsSelfSignedCertificate() {
        let connection = PostgresTestServer.make(user: "postgres", password: "postgres", sslMode: .verifyFull)
        let error = #expect(throws: DatabaseError.self) { try connection.connect() }
        if case .connection(let message) = error {
            #expect(message.contains("TLS"))
        } else {
            Issue.record("expected a connection error, got \(String(describing: error))")
        }
        #expect(throws: DatabaseError.self) { _ = try connection.execute("SELECT 1", rowLimit: nil) }
    }

    @Test func md5Login() throws {
        let connection = try PostgresTestServer.connect(user: "md5user", password: "md5pass", sslMode: .disable)
        defer { connection.close() }
        #expect(try connection.rows("SELECT current_user").first?.first == .text("md5user"))
    }

    @Test(arguments: [("postgres", SSLMode.prefer), ("md5user", SSLMode.disable)])
    func wrongPasswordIsAnAuthenticationError(user: String, sslMode: SSLMode) {
        let connection = PostgresTestServer.make(user: user, password: "wrong", sslMode: sslMode)
        let error = #expect(throws: DatabaseError.self) { try connection.connect() }
        guard case .authentication(let message) = error else {
            Issue.record("expected an authentication error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("password authentication failed"))
    }

    @Test func rowLimitStopsTheServerInsteadOfDownloadingEverything() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let started = Date()
        let results = try connection.execute("SELECT g, md5(g::text) FROM generate_series(1, 3000000) g; SELECT 42", rowLimit: 100)
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(results.count == 2)
        #expect(results[0].rows.count == 100)
        #expect(results[0].truncated)
        #expect(results[0].rows.last?.first == .text("100"))
        #expect(results[1].rows == [[.text("42")]])
        #expect(!results[1].truncated)

        let exact = try connection.execute("SELECT g FROM generate_series(1, 100) g", rowLimit: 100)
        #expect(exact[0].rows.count == 100 && !exact[0].truncated)
    }

    @Test func rowLimitedStatementsShareOneImplicitTransaction() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        _ = try connection.execute("CREATE TEMP TABLE bounded_tx(x int)", rowLimit: 10)
        #expect(throws: (any Error).self) { try connection.execute("INSERT INTO bounded_tx VALUES (1); SELECT 1/0", rowLimit: 10) }
        #expect(try connection.execute("SELECT count(*) FROM bounded_tx", rowLimit: 10)[0].rows == [[.text("0")]])
        // Statements that refuse a transaction block still run on their own.
        _ = try connection.execute("VACUUM pg_catalog.pg_class", rowLimit: 10)
        _ = try connection.execute("BEGIN", rowLimit: 10)
        _ = try connection.execute("INSERT INTO bounded_tx VALUES (2); SELECT * FROM generate_series(1, 1000)", rowLimit: 10)
        _ = try connection.execute("ROLLBACK", rowLimit: 10)
        #expect(try connection.execute("SELECT count(*) FROM bounded_tx", rowLimit: 10)[0].rows == [[.text("0")]])
        do {
            _ = try connection.execute("SELECT $1", rowLimit: 10)
            Issue.record("A placeholder without a value ran.")
        } catch {
            #expect(error.localizedDescription.contains("parameter placeholders"))
        }
        #expect(try connection.execute("SELECT 'still usable'", rowLimit: 10)[0].rows == [[.text("still usable")]])
    }

    @Test func multipleStatements() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let results = try connection.execute(
            "SELECT 1; CREATE TEMP TABLE t(x int); INSERT INTO t VALUES (1),(2); UPDATE t SET x = 3; DELETE FROM t; SELECT 'Zoë ✓'",
            rowLimit: nil
        )
        #expect(results.map(\.message) == ["SELECT 1", "CREATE TABLE", "INSERT 0 2", "UPDATE 2", "DELETE 2", "SELECT 1"])
        #expect(results.map(\.affectedRows) == [nil, nil, 2, 2, 2, nil])
        #expect(results[0].columns == [ResultColumn(name: "?column?", typeName: "int4", isNumeric: true)])
        #expect(results[5].rows == [[.text("Zoë ✓")]])
        #expect(results.allSatisfy { $0.elapsed >= 0 })
        #expect(try connection.execute("  ; -- only a comment", rowLimit: nil).isEmpty)
    }

    @Test func sessionSurvivesServerErrors() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let error = #expect(throws: DatabaseError.self) { _ = try connection.execute("SELEC 1", rowLimit: nil) }
        guard case let .server(_, code, _) = error else {
            Issue.record("expected a server error, got \(String(describing: error))")
            return
        }
        #expect(code == "42601")
        #expect(try connection.rows("SELECT 2").first?.first == .text("2"))

        _ = try connection.execute("BEGIN", rowLimit: nil)
        #expect(throws: DatabaseError.self) { _ = try connection.execute("SELECT 1/0", rowLimit: nil) }
        #expect(connection.transactionStatus == "E")
        _ = try connection.execute("ROLLBACK", rowLimit: nil)
        #expect(connection.transactionStatus == "I")
        #expect(try connection.rows("SELECT 3").first?.first == .text("3"))
    }

    @Test func rowLimitTruncatesLargeResults() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let limited = try connection.execute("SELECT generate_series(1, 200000)", rowLimit: 5)
        #expect(limited.first?.rows.count == 5)
        #expect(limited.first?.truncated == true)
        #expect(limited.first?.affectedRows == nil)

        let full = try connection.execute("SELECT g, repeat('x', 50) FROM generate_series(1, 100000) g", rowLimit: nil)
        #expect(full.first?.rows.count == 100_000)
        #expect(full.first?.truncated == false)
        #expect(full.first?.rows.last?.first == .text("100000"))
    }

    @Test func decodesSeededTypes() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        guard let result = try connection.execute("SELECT * FROM types_demo ORDER BY id", rowLimit: nil).first else {
            Issue.record("no result")
            return
        }
        let types = Dictionary(uniqueKeysWithValues: result.columns.map { ($0.name, $0.typeName) })
        #expect(types["doc"] == "jsonb")
        #expect(types["tags"] == "text[]")
        #expect(types["raw"] == "bytea")
        #expect(types["uid"] == "uuid")
        #expect(types["money_value"] == "numeric")
        #expect(types["moment"] == "timestamp")
        let first = Dictionary(uniqueKeysWithValues: zip(result.columns.map(\.name), result.rows[0]))
        #expect(first["big"] == .text("9007199254740993"))
        #expect(first["raw"] == .text("\\xdeadbeef"))
        #expect(first["tags"] == .text("{red,green}"))
        #expect(first["doc"] == .text("{\"a\": 1, \"b\": [true, null]}"))
        #expect(first["quote_text"] == .text("It's a \"quote\" \\ backslash"))
        let secondRowValues = result.rows[1].dropFirst()
        #expect(secondRowValues.allSatisfy { $0.isNull })
    }

    @Test func copyIsRejectedAndSessionStaysUsable() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        for sql in ["CREATE TEMP TABLE c(x int); COPY c FROM STDIN", "COPY (SELECT 1) TO STDOUT"] {
            let error = #expect(throws: DatabaseError.self) { _ = try connection.execute(sql, rowLimit: nil) }
            guard case .unsupported = error else {
                Issue.record("expected unsupported for \(sql), got \(String(describing: error))")
                continue
            }
            #expect(try connection.rows("SELECT 1").first?.first == .text("1"))
        }
    }

    @Test func noticesAreCollected() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        _ = try connection.execute("DO $$ BEGIN RAISE NOTICE 'hello from plpgsql'; END $$", rowLimit: nil)
        #expect(connection.notices.contains { $0.contains("hello from plpgsql") })
    }

    @Test func cancelInterruptsRunningStatement() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { connection.cancel() }
        let began = Date()
        let error = #expect(throws: DatabaseError.self) { _ = try connection.execute("SELECT pg_sleep(30)", rowLimit: nil) }
        guard case .cancelled = error else {
            Issue.record("expected cancelled, got \(String(describing: error))")
            return
        }
        #expect(Date().timeIntervalSince(began) < 5)
        #expect(try connection.rows("SELECT 1 AS still_alive").first?.first == .text("1"))
    }

    @Test func statementTimeoutKeepsServerMessage() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        _ = try connection.execute("SET statement_timeout = 100", rowLimit: nil)
        let error = #expect(throws: DatabaseError.self) { _ = try connection.execute("SELECT pg_sleep(5)", rowLimit: nil) }
        guard case let .server(_, code, _) = error else {
            Issue.record("expected a server error, got \(String(describing: error))")
            return
        }
        #expect(code == "57014")
    }

    @Test func fatalErrorClosesSession() throws {
        let connection = try PostgresTestServer.connect()
        let error = #expect(throws: DatabaseError.self) {
            _ = try connection.execute("SELECT pg_terminate_backend(pg_backend_pid())", rowLimit: nil)
        }
        if case let .server(_, code, _) = error {
            #expect(code == "57P01")
        } else {
            Issue.record("expected the FATAL server error, got \(String(describing: error))")
        }
        let next = #expect(throws: DatabaseError.self) { _ = try connection.execute("SELECT 1", rowLimit: nil) }
        guard case .notConnected = next else {
            Issue.record("expected notConnected, got \(String(describing: next))")
            return
        }
        connection.cancel()
    }

    @Test func catalogListings() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let databases = try connection.databases()
        #expect(databases.contains("foxlume"))
        #expect(databases == databases.sorted())
        #expect(!databases.contains("template0"))

        let schemas = try connection.schemas()
        #expect(schemas.contains("public"))
        #expect(schemas.contains("shop"))
        #expect(!schemas.contains { $0.hasPrefix("pg_") || $0 == "information_schema" })

        let tables = try connection.tables(schema: nil)
        let byName = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) })
        #expect(byName["orders"]?.kind == .table)
        #expect(byName["orders"]?.ref.schema == "public")
        #expect(byName["order_summary"]?.kind == .view)
        #expect(byName["users"]?.comment == "Application users")
        #expect(tables.map(\.name) == tables.map(\.name).sorted())
        #expect(try connection.tables(schema: "shop").map(\.ref) == [TableRef(schema: "shop", name: "products")])
    }

    @Test func tableStructure() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let orders = try connection.structure(of: TableRef(schema: "public", name: "orders"))
        #expect(orders.table == TableRef(schema: "public", name: "orders"))
        #expect(orders.columns.map(\.name) == ["id", "user_id", "status", "total", "currency", "shipping_address", "notes", "paid_at"])
        #expect(orders.primaryKey == ["id"])
        let id = orders.columns[0]
        #expect(id.isPrimaryKey && id.isAutoIncrement && !id.isNullable)
        #expect(id.dataType == "bigint")
        #expect(orders.columns[3].dataType == "numeric(10,2)")
        #expect(orders.columns[2].defaultValue == "'pending'::text")
        #expect(Set(orders.indexes.map(\.name)) == ["orders_pkey", "orders_status_idx", "orders_user_id_idx"])
        #expect(orders.indexes.first { $0.isPrimary }?.method == "btree")
        let key = orders.foreignKeys.first
        #expect(key?.columns == ["user_id"])
        #expect(key?.referencedTable == TableRef(schema: "public", name: "users"))
        #expect(key?.referencedColumns == ["id"])
        #expect(key?.onDelete == "CASCADE")
        #expect(key?.onUpdate == "NO ACTION")

        let view = try connection.structure(of: TableRef(schema: "public", name: "order_summary"))
        #expect(view.columns.map(\.name) == ["email", "order_count", "total_spent"])
        #expect(view.indexes.isEmpty && view.foreignKeys.isEmpty)

        #expect(try connection.structure(of: TableRef(schema: "shop", name: "products")).primaryKey == ["sku"])
        #expect(try connection.structure(of: TableRef(name: "no_pk_log")).primaryKey.isEmpty)

        let missing = #expect(throws: DatabaseError.self) {
            _ = try connection.structure(of: TableRef(schema: "public", name: "nope'; DROP TABLE users; --"))
        }
        if case let .server(_, code, _) = missing { #expect(code == "42P01") }
    }

    @Test func generatedDDL() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let orders = try connection.ddl(of: TableRef(schema: "public", name: "orders"))
        #expect(orders.hasPrefix("CREATE TABLE \"public\".\"orders\" (\n"))
        #expect(orders.contains("\"user_id\" integer NOT NULL"))
        #expect(orders.contains("CONSTRAINT \"orders_pkey\" PRIMARY KEY (\"id\")"))
        #expect(orders.contains("REFERENCES \"public\".\"users\" (\"id\") ON DELETE CASCADE"))
        #expect(orders.contains("CREATE INDEX orders_status_idx ON public.orders USING btree (status);"))
        #expect(!orders.contains("CREATE UNIQUE INDEX orders_pkey"))

        let users = try connection.ddl(of: TableRef(schema: "public", name: "users"))
        #expect(users.contains("COMMENT ON TABLE \"public\".\"users\" IS 'Application users';"))
        #expect(users.contains("UNIQUE (email)"))

        let view = try connection.ddl(of: TableRef(schema: "public", name: "order_summary"))
        #expect(view.hasPrefix("CREATE VIEW \"public\".\"order_summary\" AS\nSELECT"))
        #expect(view.hasSuffix(";"))
    }

    @Test func scratchTableWithIdentityGeneratedAndComments() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let name = "tmp_eq_pg_\(UInt32.random(in: 0 ... .max))"
        let table = TableRef(schema: "public", name: name)
        let qualified = connection.dialect.qualifiedName(table)
        _ = try connection.execute("""
            CREATE TABLE \(qualified) (
                "Id" integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                price numeric NOT NULL CHECK (price >= 0),
                doubled numeric GENERATED ALWAYS AS (price * 2) STORED,
                code text UNIQUE
            );
            COMMENT ON COLUMN \(qualified).price IS 'Price in ''USD''';
            CREATE INDEX ON \(qualified) (lower(code));
            """, rowLimit: nil)
        defer { _ = try? connection.execute("DROP TABLE IF EXISTS \(qualified)", rowLimit: nil) }

        let structure = try connection.structure(of: table)
        #expect(structure.primaryKey == ["Id"])
        #expect(structure.columns[0].isAutoIncrement)
        #expect(structure.columns[0].extra == "GENERATED ALWAYS AS IDENTITY")
        #expect(structure.columns[1].comment == "Price in 'USD'")
        #expect(structure.columns[2].defaultValue == nil)
        #expect(structure.columns[2].extra?.hasSuffix("STORED") == true)
        #expect(structure.indexes.contains { $0.columns == ["lower(code)"] })

        let ddl = try connection.ddl(of: table)
        #expect(ddl.contains("\"Id\" integer GENERATED ALWAYS AS IDENTITY NOT NULL"))
        #expect(ddl.contains("CHECK (price >= 0::numeric)"))
        #expect(ddl.contains("COMMENT ON COLUMN \(qualified).\"price\" IS 'Price in ''USD''';"))
        #expect(ddl.contains("lower(code)"))
    }

    @Test func useDatabaseReconnects() throws {
        let connection = try PostgresTestServer.connect(sslMode: .require)
        defer { connection.close() }
        try connection.useDatabase("postgres")
        #expect(connection.currentDatabase == "postgres")
        #expect(connection.isTLS)
        #expect(try connection.rows("SELECT current_database()").first?.first == .text("postgres"))
        #expect(try connection.schemas().contains("public"))

        #expect(throws: DatabaseError.self) { try connection.useDatabase("eq_no_such_database") }
        #expect(connection.currentDatabase == "postgres")
        #expect(try connection.rows("SELECT 1").first?.first == .text("1"))
    }
}

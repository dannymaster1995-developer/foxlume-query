import Foundation
import Testing
@testable import FoxlumeQueryCore

/// The client tools the live backup tests run: the binaries that come with the test servers in `../.dbtest`, or the
/// folder in `FQ_MYSQL_CLIENT_BIN` (set by `scripts/ci-server.sh` to the matrix server's own tools). The PostgreSQL
/// test binaries are server-only, so pg_dump and pg_restore come from `FQ_PG_CLIENT_BIN` (set by `scripts/env.sh`
/// when `../.dbtest/pg-client/bin` exists), else the copy tool discovery finds on this Mac. Suites skip without.
enum BackupTestTools {
    static let dbtest = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".dbtest")

    static func bundled(_ tool: BackupTool, in folder: String) -> BackupToolCandidate? {
        bundled(tool, inBin: dbtest.appendingPathComponent("\(folder)/bin"))
    }

    static func bundled(_ tool: BackupTool, inBin folder: URL) -> BackupToolCandidate? {
        for name in tool.executableNames {
            let path = folder.appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) {
                return BackupToolCandidate(path: path, version: BackupToolDiscovery.version(ofToolAt: path))
            }
        }
        return nil
    }

    static func environmentFolder(_ name: String) -> URL? {
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    static let mysqlClientBin = environmentFolder("FQ_MYSQL_CLIENT_BIN")
    static let mysqldump = mysqlClientBin.map { bundled(.mysqldump, inBin: $0) } ?? bundled(.mysqldump, in: "mysql-bin")
    static let mysqlClient = mysqlClientBin.map { bundled(.mysql, inBin: $0) } ?? bundled(.mysql, in: "mysql-bin")
    static let pgClientBin = environmentFolder("FQ_PG_CLIENT_BIN")

    static func postgres(_ tool: BackupTool) -> BackupToolCandidate? {
        pgClientBin.flatMap { bundled(tool, inBin: $0) } ?? BackupToolDiscovery.find(tool).chosen
    }

    static let pgDump = postgres(.pgDump)
    static let pgRestore = postgres(.pgRestore)
    static let psql = postgres(.psql)

    /// The test servers' versions, as the app passes them on from its session.
    static let postgresVersion: ServerVersion? = {
        guard let connection = try? PostgresTestServer.connect() else { return nil }
        defer { connection.close() }
        return ServerVersion.parse(connection.serverVersion)
    }()
    static let mysqlVersion: ServerVersion? = {
        guard let connection = try? MySQLTestServer.connect() else { return nil }
        defer { connection.close() }
        return ServerVersion.parse(connection.serverVersion)
    }()

    static var mysqlReady: Bool { MySQLTestServer.isAvailable && mysqldump != nil && mysqlClient != nil }
    static var postgresReady: Bool { PostgresTestServer.isAvailable && pgDump != nil && pgRestore != nil && psql != nil }

    /// A folder of its own for the secret files, so a test can check it is empty afterwards.
    static func secretFolder(_ name: String) throws -> URL {
        let url = TestFiles.url("fq114-secrets-\(name)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs a job to the end, collecting its log lines.
    static func run(_ runner: BackupRunner, onEvent: ((BackupRunEvent) -> Void)? = nil) -> (BackupRunResult, [String]) {
        var lines: [String] = []
        let lock = NSLock()
        let result = runner.run { event in
            if case .log(let line) = event {
                lock.lock()
                lines.append(line)
                lock.unlock()
            }
            onEvent?(event)
        }
        return (result, lines)
    }

    /// Hidden partial files or folders left next to `destination`.
    static func partials(next destination: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)) ?? []
        return names.filter { $0.hasPrefix(".\(destination.lastPathComponent).") && $0.hasSuffix(".partial") }
    }
}

// MARK: - MySQL

@Suite("Backup and restore against MySQL", .serialized, .enabled(if: BackupTestTools.mysqlReady, "needs the MySQL test server and ../.dbtest/mysql-bin"))
struct MySQLBackupLiveTests {
    static let source = "fq114_src"
    static let targets = ["fq114_dst", "fq114_dst2"]
    static let tables = ["fq114_items", "fq114_log", "fq114_empty"]

    private func server() throws -> MySQLConnection { try MySQLTestServer.connect(database: "") }

    private func scalar(_ connection: DatabaseConnection, _ sql: String) throws -> String? {
        try TransferRoundTrip.scalar(connection, sql)
    }

    /// A scratch database with awkward values, binary data, a trigger, a procedure with a compound body and a view.
    private func makeSource() throws {
        let connection = try server()
        defer { connection.close() }
        for name in [Self.source] + Self.targets { _ = try connection.execute("DROP DATABASE IF EXISTS \(name)", rowLimit: nil) }
        _ = try connection.execute("CREATE DATABASE \(Self.source) CHARACTER SET utf8mb4", rowLimit: nil)
        try connection.useDatabase(Self.source)
        for statement in [
            "CREATE TABLE fq114_items (id int PRIMARY KEY, name varchar(40), note text, raw varbinary(16), price decimal(10,2))",
            "CREATE TABLE fq114_log (id int AUTO_INCREMENT PRIMARY KEY, msg varchar(60))",
            "CREATE TABLE fq114_empty (id int PRIMARY KEY)",
            "CREATE TRIGGER fq114_items_ai AFTER INSERT ON fq114_items FOR EACH ROW INSERT INTO fq114_log (msg) VALUES (CONCAT('added ', NEW.id))",
            "CREATE PROCEDURE fq114_count(OUT total INT) BEGIN SELECT COUNT(*) INTO total FROM fq114_items; SET total = total + 0; END",
            "CREATE VIEW fq114_cheap AS SELECT id, name FROM fq114_items WHERE price < 10",
            """
            INSERT INTO fq114_items VALUES
              (1, 'semi;colon', 'line\\nbreak and ''quote''', 0x00FF10, 9.99),
              (2, 'emoji 🦊', 'back\\\\slash', NULL, 12.50),
              (3, 'DELIMITER ;;', NULL, 0x0A0D3B, 0)
            """,
            "INSERT INTO fq114_items SELECT n + 4, CONCAT('bulk ', n), REPEAT('x', n % 50), NULL, n FROM (SELECT a.d * 10 + b.d AS n FROM (SELECT 0 d UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a, (SELECT 0 d UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b) numbers",
        ] {
            _ = try connection.execute(statement, rowLimit: nil)
        }
    }

    private func dropAll() {
        guard let connection = try? server() else { return }
        for name in [Self.source] + Self.targets { _ = try? connection.execute("DROP DATABASE IF EXISTS \(name)", rowLimit: nil) }
        connection.close()
    }

    private func connection(to database: String) -> BackupConnection {
        BackupConnection(parameters: MySQLTestServer.parameters(database: database), database: database, serverVersion: BackupTestTools.mysqlVersion)
    }

    /// Row counts of the scratch tables, the trigger, routine and view, and the binary values as hex.
    private func fingerprint(_ database: String) throws -> [String] {
        let connection = try MySQLTestServer.connect(database: database)
        defer { connection.close() }
        var result = try Self.tables.map { "\($0): " + (try scalar(connection, "SELECT COUNT(*) FROM \($0)") ?? "?") }
        result.append("raw: " + (try scalar(connection, "SELECT GROUP_CONCAT(COALESCE(HEX(raw), 'NULL') ORDER BY id) FROM fq114_items WHERE id <= 3") ?? ""))
        result.append("text: " + (try scalar(connection, "SELECT GROUP_CONCAT(CONCAT(name, '|', COALESCE(note, 'NULL')) ORDER BY id SEPARATOR '~') FROM fq114_items WHERE id <= 3") ?? ""))
        result.append("trigger: " + (try scalar(connection, "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = '\(database)'") ?? ""))
        result.append("routine: " + (try scalar(connection, "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '\(database)'") ?? ""))
        // A table backup has no views.
        result.append("view: " + ((try? scalar(connection, "SELECT COUNT(*) FROM fq114_cheap")).flatMap { $0 } ?? "missing"))
        return result
    }

    @Test func backupRestoresThroughRunSQLFile() throws {
        try makeSource()
        defer { dropAll() }
        let destination = TestFiles.url("fq114-mysql-\(UUID().uuidString.prefix(6)).sql")
        defer { try? FileManager.default.removeItem(at: destination) }
        let secrets = try BackupTestTools.secretFolder("mysql")
        defer { try? FileManager.default.removeItem(at: secrets) }
        let runner = BackupRunner(job: .mysqlBackup(scope: .database, options: MySQLBackupOptions(), destination: destination), connection: connection(to: Self.source), tool: try #require(BackupTestTools.mysqldump), secretParent: secrets)
        var sizes: [Int64] = []
        let (result, lines) = BackupTestTools.run(runner) { event in
            if case .outputSize(let size) = event { sizes.append(size) }
        }
        #expect(result.status == .succeeded, "\(result.message ?? "")")
        #expect(result.exitCode == 0)
        #expect(result.outputURL == destination)
        #expect((result.outputSize ?? 0) > 1000)
        #expect(sizes.last == result.outputSize)
        // mysqldump --verbose reports each table on standard error.
        #expect(lines.contains { $0.contains("Retrieving table structure for table fq114_items") })
        #expect(result.command.contains("--defaults-extra-file=<password file>"))
        #expect(!result.command.contains(secrets.path))
        // The password file is gone with its folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: secrets.path).isEmpty)
        #expect(BackupTestTools.partials(next: destination).isEmpty)
        #expect(BackupFileKind.detect(destination) == .plainSQL(compressed: false, dialect: .mysql))
        let dump = try String(contentsOf: destination, encoding: .utf8)
        #expect(dump.contains("DELIMITER ;;"))

        // Restore through Run SQL File into another scratch database.
        let setup = try server()
        _ = try setup.execute("CREATE DATABASE \(Self.targets[0])", rowLimit: nil)
        setup.close()
        let target = try MySQLTestServer.connect(database: Self.targets[0])
        let report = try SQLFileRunner(connection: target, options: SQLFileRunOptions()).run(file: destination)
        target.close()
        #expect(report.failure == nil, "\(report.failure?.message ?? "")")
        #expect(report.statementsFailed == 0)
        let original = try fingerprint(Self.source)
        #expect(original.first == "fq114_items: 103")
        #expect(original.contains("trigger: 1") && original.contains("routine: 1"))
        #expect(try fingerprint(Self.targets[0]) == original)
    }

    @Test func gzipBackupOfTablesRestoresWithTheMySQLClient() throws {
        try makeSource()
        defer { dropAll() }
        let destination = TestFiles.url("fq114-mysql-\(UUID().uuidString.prefix(6)).sql.gz")
        defer { try? FileManager.default.removeItem(at: destination) }
        var options = MySQLBackupOptions()
        options.compress = true
        let tables = Self.tables.map { TableRef(name: $0) }
        let runner = BackupRunner(job: .mysqlBackup(scope: .tables(tables), options: options, destination: destination), connection: connection(to: Self.source), tool: try #require(BackupTestTools.mysqldump))
        let (result, _) = BackupTestTools.run(runner)
        #expect(result.status == .succeeded, "\(result.message ?? "")")
        #expect(BackupFileKind.detect(destination) == .plainSQL(compressed: true, dialect: .mysql))

        let setup = try server()
        _ = try setup.execute("CREATE DATABASE \(Self.targets[1])", rowLimit: nil)
        setup.close()
        var inputEvents = 0
        let restore = BackupRunner(job: .scriptRestore(file: destination, singleTransaction: false), connection: connection(to: Self.targets[1]), tool: try #require(BackupTestTools.mysqlClient))
        let (restored, _) = BackupTestTools.run(restore) { event in
            if case .inputProgress = event { inputEvents += 1 }
        }
        #expect(restored.status == .succeeded, "\(restored.message ?? "")")
        #expect(restored.command.hasSuffix("< " + ToolInvocation.shellQuoted(destination.path)))
        #expect(inputEvents > 0)
        // Tables and their trigger; the view and procedure are not part of a table backup.
        let copy = try fingerprint(Self.targets[1]).prefix(6)
        let original = try fingerprint(Self.source).prefix(6)
        #expect(copy == original)
    }

    @Test func cancellingMidBackupRemovesThePartialFile() throws {
        let destination = TestFiles.url("fq114-cancel-\(UUID().uuidString.prefix(6)).sql.gz")
        defer { try? FileManager.default.removeItem(at: destination) }
        var options = MySQLBackupOptions()
        options.compress = true
        // perf_big has two million rows: long enough to be stopped half-way. It is only read.
        let runner = BackupRunner(job: .mysqlBackup(scope: .tables([TableRef(name: "perf_big")]), options: options, destination: destination), connection: connection(to: "foxlume"), tool: try #require(BackupTestTools.mysqldump))
        let started = Date()
        let (result, _) = BackupTestTools.run(runner) { event in
            if case .outputSize(let size) = event, size > 0 { runner.cancel() }
        }
        #expect(result.status == .cancelled)
        // Stopped, not finished: a signal ended mysqldump.
        #expect(result.exitCode == 128 + SIGTERM, "exit \(result.exitCode ?? -1)")
        #expect(Date().timeIntervalSince(started) < 15)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(BackupTestTools.partials(next: destination).isEmpty)
        #expect(runner.isCancelled)
    }

    @Test func failuresShowTheToolsMessage() throws {
        let destination = TestFiles.url("fq114-missing-\(UUID().uuidString.prefix(6)).sql")
        let runner = BackupRunner(job: .mysqlBackup(scope: .database, options: MySQLBackupOptions(), destination: destination), connection: connection(to: "fq114_no_such_database"), tool: try #require(BackupTestTools.mysqldump))
        let (result, _) = BackupTestTools.run(runner)
        #expect(result.status == .failed)
        #expect(result.exitCode != 0)
        #expect(result.message?.contains("Unknown database 'fq114_no_such_database'") == true)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(BackupTestTools.partials(next: destination).isEmpty)
        // A wrong password is the server's answer, not a prompt.
        var parameters = MySQLTestServer.parameters(database: "foxlume")
        parameters.password = "wrong"
        let denied = BackupRunner(job: .mysqlBackup(scope: .tables([TableRef(name: "users")]), options: MySQLBackupOptions(), destination: destination), connection: BackupConnection(parameters: parameters, database: "foxlume"), tool: try #require(BackupTestTools.mysqldump))
        let (deniedResult, _) = BackupTestTools.run(denied)
        #expect(deniedResult.status == .failed)
        #expect(deniedResult.message?.contains("Access denied") == true)
    }
}

// MARK: - MySQL with TLS

@Suite("Backup over TLS against MySQL", .serialized, .enabled(if: TLSTestServers.mysqlAvailable && BackupTestTools.mysqldump != nil, "needs scripts/dbtest-tls.sh"))
struct MySQLTLSBackupLiveTests {
    static let database = "fq114_tls"

    private func admin() throws -> MySQLConnection {
        let connection = MySQLConnection(parameters: TLSTestServers.parameters(.mysql, user: "root", password: "root", mode: .require, files: TLSCertificateFiles()))
        try connection.connect()
        return connection
    }

    private func backup(_ parameters: ConnectionParameters) throws -> BackupRunResult {
        let destination = TestFiles.url("fq114-tls-\(UUID().uuidString.prefix(6)).sql")
        defer { try? FileManager.default.removeItem(at: destination) }
        let runner = BackupRunner(job: .mysqlBackup(scope: .database, options: MySQLBackupOptions(), destination: destination), connection: BackupConnection(parameters: parameters, database: Self.database), tool: try #require(BackupTestTools.mysqldump))
        return BackupTestTools.run(runner).0
    }

    @Test func clientCertificatesAndVerification() throws {
        let setup = try admin()
        _ = try setup.execute("DROP DATABASE IF EXISTS \(Self.database)", rowLimit: nil)
        _ = try setup.execute("CREATE DATABASE \(Self.database)", rowLimit: nil)
        _ = try setup.execute("CREATE TABLE \(Self.database).t (id int PRIMARY KEY)", rowLimit: nil)
        defer {
            _ = try? setup.execute("DROP DATABASE IF EXISTS \(Self.database)", rowLimit: nil)
            setup.close()
        }
        // Verify CA with the test CA, and the client certificate from a PKCS#12 file with its password.
        let verified = try backup(TLSTestServers.parameters(.mysql, user: "root", password: "root", mode: .verifyCA, files: TLSTestServers.files(ca: "ca.crt", p12: "client.p12"), secret: "secret"))
        #expect(verified.status == .succeeded, "\(verified.message ?? "")")
        #expect(verified.command.contains("--ssl-mode=VERIFY_CA") && verified.command.contains("--ssl-key=") && !verified.command.contains("client.p12"))
        // The certificate names localhost: Verify Identity fails for 127.0.0.1 and passes for localhost.
        let mismatch = try backup(TLSTestServers.parameters(.mysql, user: "root", password: "root", mode: .verifyFull, files: TLSTestServers.files(ca: "ca.crt")))
        #expect(mismatch.status == .failed)
        let matching = try backup(TLSTestServers.parameters(.mysql, host: "localhost", user: "root", password: "root", mode: .verifyFull, files: TLSTestServers.files(ca: "ca.crt")))
        #expect(matching.status == .succeeded, "\(matching.message ?? "")")
        // certuser logs in only with its certificate (REQUIRE X509); it has no rights on the database, so getting
        // as far as "access denied to database" proves the encrypted key was handed over.
        let withCertificate = try backup(TLSTestServers.parameters(.mysql, user: "certuser", password: "certpass", mode: .require, files: TLSTestServers.files(cert: "client.crt", key: "client-pkcs8-enc.key"), secret: "secret"))
        #expect(withCertificate.status == .failed)
        #expect(withCertificate.message?.contains("to database '\(Self.database)'") == true, "\(withCertificate.message ?? "")")
        let withoutCertificate = try backup(TLSTestServers.parameters(.mysql, user: "certuser", password: "certpass", mode: .require, files: TLSCertificateFiles()))
        #expect(withoutCertificate.status == .failed)
        #expect(withoutCertificate.message?.contains("to database") == false)
    }
}

// MARK: - PostgreSQL

@Suite("Backup and restore against PostgreSQL", .serialized, .enabled(if: BackupTestTools.postgresReady, "needs the PostgreSQL test server and pg_dump / pg_restore / psql"))
struct PostgresBackupLiveTests {
    static let source = "fq114_pg_src"
    static let targets = ["fq114_pg_dst", "fq114_pg_dst2"]

    private func dropAll() {
        guard let connection = try? PostgresTestServer.connect(database: "foxlume") else { return }
        for name in [Self.source] + Self.targets { _ = try? connection.execute("DROP DATABASE IF EXISTS \(name)", rowLimit: nil) }
        connection.close()
    }

    private func createDatabase(_ name: String) throws {
        let connection = try PostgresTestServer.connect(database: "foxlume")
        defer { connection.close() }
        _ = try connection.execute("DROP DATABASE IF EXISTS \(name)", rowLimit: nil)
        _ = try connection.execute("CREATE DATABASE \(name)", rowLimit: nil)
    }

    private func makeSource() throws {
        dropAll()
        try createDatabase(Self.source)
        let connection = try PostgresTestServer.connect(database: Self.source)
        defer { connection.close() }
        _ = try connection.execute("""
            CREATE SCHEMA sales;
            CREATE TABLE public.items (id serial PRIMARY KEY, name text, raw bytea, tags text[], doc jsonb);
            CREATE TABLE sales.orders (id int PRIMARY KEY, item_id int REFERENCES public.items(id), total numeric(10,2));
            CREATE VIEW public.cheap AS SELECT id, name FROM public.items WHERE id < 5;
            CREATE FUNCTION public.touch() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.total := NEW.total; RETURN NEW; END $$;
            CREATE TRIGGER orders_touch BEFORE INSERT ON sales.orders FOR EACH ROW EXECUTE FUNCTION public.touch();
            INSERT INTO public.items (name, raw, tags, doc) SELECT 'item ' || g || E' tab\\t ''q''', decode('00ff', 'hex'), ARRAY['a;b', 'c'], jsonb_build_object('n', g) FROM generate_series(1, 300) g;
            INSERT INTO sales.orders SELECT g, g, g * 1.25 FROM generate_series(1, 120) g;
            """, rowLimit: nil)
    }

    /// The two tables' row counts ("missing" for a table that is not there).
    private func tableCounts(_ database: String) throws -> [String] {
        let connection = try PostgresTestServer.connect(database: database)
        defer { connection.close() }
        return ["items": "public.items", "orders": "sales.orders"].sorted { $0.key < $1.key }.map { label, table in
            "\(label): " + (((try? TransferRoundTrip.scalar(connection, "SELECT count(*) FROM \(table)")) ?? nil) ?? "missing")
        }
    }

    private func counts(_ database: String) throws -> [String] {
        let connection = try PostgresTestServer.connect(database: database)
        defer { connection.close() }
        return try [
            "items: " + (TransferRoundTrip.scalar(connection, "SELECT count(*) FROM public.items") ?? ""),
            "orders: " + (TransferRoundTrip.scalar(connection, "SELECT count(*) FROM sales.orders") ?? ""),
            "view: " + (TransferRoundTrip.scalar(connection, "SELECT count(*) FROM public.cheap") ?? ""),
            "trigger: " + (TransferRoundTrip.scalar(connection, "SELECT count(*) FROM pg_trigger WHERE tgname = 'orders_touch'") ?? ""),
            "values: " + (TransferRoundTrip.scalar(connection, "SELECT md5(string_agg(name || encode(raw, 'hex') || tags::text || doc::text, ',' ORDER BY id)) FROM public.items") ?? ""),
        ]
    }

    private func connection(to database: String) -> BackupConnection {
        let config = ConnectionConfig(kind: .postgresql, host: PostgresTestServer.host, port: PostgresTestServer.port, user: "postgres", database: database, sslMode: .prefer)
        return BackupConnection(parameters: ConnectionParameters(config: config, password: "postgres"), database: database, serverVersion: BackupTestTools.postgresVersion)
    }

    @Test func customBackupRestoresWithPgRestore() throws {
        try makeSource()
        defer { dropAll() }
        let destination = TestFiles.url("fq114-pg-\(UUID().uuidString.prefix(6)).dump")
        defer { try? FileManager.default.removeItem(at: destination) }
        let (result, lines) = BackupTestTools.run(BackupRunner(job: .postgresBackup(scope: .database, options: PostgresBackupOptions(), destination: destination), connection: connection(to: Self.source), tool: try #require(BackupTestTools.pgDump)))
        #expect(result.status == .succeeded, "\(result.message ?? "")")
        #expect(lines.contains { $0.contains("pg_dump: dumping contents of table") })
        #expect(result.command.hasPrefix("PGPASSFILE=<password file> "))
        #expect(result.command.contains("--file=\(destination.path)"))
        #expect(BackupFileKind.detect(destination) == .postgresCustom)
        #expect(BackupTestTools.partials(next: destination).isEmpty)

        try createDatabase(Self.targets[0])
        var options = PostgresRestoreOptions()
        options.noOwner = true
        let (restored, _) = BackupTestTools.run(BackupRunner(job: .postgresRestore(archive: destination, kind: .postgresCustom, options: options), connection: connection(to: Self.targets[0]), tool: try #require(BackupTestTools.pgRestore)))
        #expect(restored.status == .succeeded, "\(restored.message ?? "")")
        #expect(try counts(Self.targets[0]) == counts(Self.source))
    }

    @Test func plainBackupRestoresThroughRunSQLFile() throws {
        try makeSource()
        defer { dropAll() }
        let destination = TestFiles.url("fq114-pg-\(UUID().uuidString.prefix(6)).sql")
        defer { try? FileManager.default.removeItem(at: destination) }
        var options = PostgresBackupOptions()
        options.format = .plain
        options.noOwner = true
        let (result, _) = BackupTestTools.run(BackupRunner(job: .postgresBackup(scope: .database, options: options, destination: destination), connection: connection(to: Self.source), tool: try #require(BackupTestTools.pgDump)))
        #expect(result.status == .succeeded, "\(result.message ?? "")")
        #expect(BackupFileKind.detect(destination) == .plainSQL(compressed: false, dialect: .postgresql))
        #expect(try PlainDumpInspector.usesCopyFromStdin(destination) == false)

        try createDatabase(Self.targets[1])
        let target = try PostgresTestServer.connect(database: Self.targets[1])
        let report = try SQLFileRunner(connection: target, options: SQLFileRunOptions()).run(file: destination)
        target.close()
        #expect(report.failure == nil, "\(report.failure?.message ?? "")")
        #expect(try counts(Self.targets[1]) == counts(Self.source))
    }

    @Test func tarAndDirectoryArchivesRestoreWithPgRestore() throws {
        try makeSource()
        defer { dropAll() }
        let tar = TestFiles.url("fq114-pg-\(UUID().uuidString.prefix(6)).tar")
        let folder = TestFiles.url("fq114-pg-dir-\(UUID().uuidString.prefix(6))")
        defer {
            try? FileManager.default.removeItem(at: tar)
            try? FileManager.default.removeItem(at: folder)
        }
        // Tar: one schema-qualified table, restored without parallel jobs (pg_restore cannot use them on tar).
        var options = PostgresBackupOptions()
        options.format = .tar
        let tables = [TableRef(schema: "public", name: "items")]
        let (tarResult, tarLines) = BackupTestTools.run(BackupRunner(job: .postgresBackup(scope: .tables(tables), options: options, destination: tar), connection: connection(to: Self.source), tool: try #require(BackupTestTools.pgDump)))
        #expect(tarResult.status == .succeeded, "\(tarResult.message ?? "")")
        #expect(tarLines.contains { $0.contains("dumping contents of table \"public.items\"") })
        #expect(!tarLines.contains { $0.contains("sales.orders") })
        #expect(BackupFileKind.detect(tar) == .postgresTar)
        try createDatabase(Self.targets[0])
        var restore = PostgresRestoreOptions()
        restore.noOwner = true
        restore.jobs = 4
        let (tarRestored, _) = BackupTestTools.run(BackupRunner(job: .postgresRestore(archive: tar, kind: .postgresTar, options: restore), connection: connection(to: Self.targets[0]), tool: try #require(BackupTestTools.pgRestore)))
        #expect(tarRestored.status == .succeeded, "\(tarRestored.message ?? "")")
        #expect(!tarRestored.command.contains("--jobs"))
        let copied = try tableCounts(Self.targets[0])
        #expect(copied == [try counts(Self.source)[0], "orders: missing"])

        // Directory: the whole database in two parallel jobs, restored in two jobs with clean.
        options.format = .directory
        options.jobs = 2
        let (folderResult, _) = BackupTestTools.run(BackupRunner(job: .postgresBackup(scope: .database, options: options, destination: folder), connection: connection(to: Self.source), tool: try #require(BackupTestTools.pgDump)))
        #expect(folderResult.status == .succeeded, "\(folderResult.message ?? "")")
        #expect(folderResult.command.contains("--jobs=2"))
        #expect(BackupFileKind.detect(folder) == .postgresDirectory)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("toc.dat").path))
        #expect((folderResult.outputSize ?? 0) == BackupRunner.size(of: folder))
        #expect(BackupTestTools.partials(next: folder).isEmpty)
        try createDatabase(Self.targets[1])
        restore.jobs = 2
        restore.clean = true
        let (folderRestored, _) = BackupTestTools.run(BackupRunner(job: .postgresRestore(archive: folder, kind: .postgresDirectory, options: restore), connection: connection(to: Self.targets[1]), tool: try #require(BackupTestTools.pgRestore)))
        #expect(folderRestored.status == .succeeded, "\(folderRestored.message ?? "")")
        #expect(folderRestored.command.contains("--jobs=2") && folderRestored.command.contains("--clean --if-exists"))
        #expect(try counts(Self.targets[1]) == counts(Self.source))
    }

    @Test func gzipPlainBackupWithCopyRestoresThroughPsql() throws {
        try makeSource()
        defer { dropAll() }
        let destination = TestFiles.url("fq114-pg-\(UUID().uuidString.prefix(6)).sql.gz")
        defer { try? FileManager.default.removeItem(at: destination) }
        var options = PostgresBackupOptions()
        options.format = .plain
        options.compressPlain = true
        options.useInserts = false
        options.noOwner = true
        let (result, _) = BackupTestTools.run(BackupRunner(job: .postgresBackup(scope: .database, options: options, destination: destination), connection: connection(to: Self.source), tool: try #require(BackupTestTools.pgDump)))
        #expect(result.status == .succeeded, "\(result.message ?? "")")
        #expect(BackupFileKind.detect(destination) == .plainSQL(compressed: true, dialect: .postgresql))
        #expect(try PlainDumpInspector.usesCopyFromStdin(destination))

        try createDatabase(Self.targets[0])
        var inputEvents = 0
        let (restored, _) = BackupTestTools.run(BackupRunner(job: .scriptRestore(file: destination, singleTransaction: true), connection: connection(to: Self.targets[0]), tool: try #require(BackupTestTools.psql))) { event in
            if case .inputProgress = event { inputEvents += 1 }
        }
        #expect(restored.status == .succeeded, "\(restored.message ?? "")")
        #expect(restored.exitCode == 0)
        #expect(restored.command.contains("--single-transaction"))
        #expect(inputEvents > 0)
        #expect(try counts(Self.targets[0]) == counts(Self.source))

        // The same script again: CREATE fails on the existing objects, psql stops (ON_ERROR_STOP) and the single
        // transaction leaves the copy as it was.
        let (again, _) = BackupTestTools.run(BackupRunner(job: .scriptRestore(file: destination, singleTransaction: true), connection: connection(to: Self.targets[0]), tool: try #require(BackupTestTools.psql)))
        #expect(again.status == .failed)
        #expect(again.exitCode == 3, "exit \(again.exitCode ?? -1)")
        #expect(again.message?.contains("already exists") == true, "\(again.message ?? "")")
        #expect(try counts(Self.targets[0]) == counts(Self.source))
    }

    @Test func failuresShowTheToolsMessage() throws {
        let destination = TestFiles.url("fq114-pg-missing-\(UUID().uuidString.prefix(6)).dump")
        defer { try? FileManager.default.removeItem(at: destination) }
        let (missing, _) = BackupTestTools.run(BackupRunner(job: .postgresBackup(scope: .database, options: PostgresBackupOptions(), destination: destination), connection: connection(to: "fq114_no_such_database"), tool: try #require(BackupTestTools.pgDump)))
        #expect(missing.status == .failed)
        #expect(missing.exitCode == 1)
        #expect(missing.message?.contains("database \"fq114_no_such_database\" does not exist") == true, "\(missing.message ?? "")")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(BackupTestTools.partials(next: destination).isEmpty)

        // A wrong password is the server's answer, not a prompt (--no-password).
        var denied = connection(to: "foxlume")
        denied.parameters.password = "wrong"
        let (deniedResult, _) = BackupTestTools.run(BackupRunner(job: .postgresBackup(scope: .tables([TableRef(schema: "public", name: "users")]), options: PostgresBackupOptions(), destination: destination), connection: denied, tool: try #require(BackupTestTools.pgDump)))
        #expect(deniedResult.status == .failed)
        #expect(deniedResult.message?.contains("password authentication failed") == true, "\(deniedResult.message ?? "")")

        // A table that does not exist: pg_dump stops before writing anything.
        let (noTable, _) = BackupTestTools.run(BackupRunner(job: .postgresBackup(scope: .tables([TableRef(schema: "public", name: "fq114_no_such_table")]), options: PostgresBackupOptions(), destination: destination), connection: connection(to: "foxlume"), tool: try #require(BackupTestTools.pgDump)))
        #expect(noTable.status == .failed)
        #expect(noTable.message?.contains("no matching tables were found") == true, "\(noTable.message ?? "")")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func pgRestoreErrorsOnExistingObjectsFail() throws {
        try makeSource()
        defer { dropAll() }
        let destination = TestFiles.url("fq114-pg-\(UUID().uuidString.prefix(6)).dump")
        defer { try? FileManager.default.removeItem(at: destination) }
        let (result, _) = BackupTestTools.run(BackupRunner(job: .postgresBackup(scope: .database, options: PostgresBackupOptions(), destination: destination), connection: connection(to: Self.source), tool: try #require(BackupTestTools.pgDump)))
        #expect(result.status == .succeeded, "\(result.message ?? "")")
        // Back into the source without clean: every CREATE fails. pg_restore goes on, then exits 1 with a count.
        var options = PostgresRestoreOptions()
        options.noOwner = true
        let (restored, lines) = BackupTestTools.run(BackupRunner(job: .postgresRestore(archive: destination, kind: .postgresCustom, options: options), connection: connection(to: Self.source), tool: try #require(BackupTestTools.pgRestore)))
        #expect(restored.status == .failed)
        #expect(restored.exitCode == 1)
        #expect(lines.contains { $0.contains("errors ignored on restore") })
        #expect(restored.message?.contains("already exists") == true, "\(restored.message ?? "")")
        // With clean, the same restore replaces the objects.
        options.clean = true
        let (cleaned, _) = BackupTestTools.run(BackupRunner(job: .postgresRestore(archive: destination, kind: .postgresCustom, options: options), connection: connection(to: Self.source), tool: try #require(BackupTestTools.pgRestore)))
        #expect(cleaned.status == .succeeded, "\(cleaned.message ?? "")")
        #expect(try counts(Self.source)[0] == "items: 300")
    }

    @Test func cancellingACustomBackupRemovesThePartialFile() throws {
        let destination = TestFiles.url("fq114-pg-cancel-\(UUID().uuidString.prefix(6)).dump")
        defer { try? FileManager.default.removeItem(at: destination) }
        let runner = BackupRunner(job: .postgresBackup(scope: .tables([TableRef(schema: "public", name: "perf_big")]), options: PostgresBackupOptions(), destination: destination), connection: connection(to: "foxlume"), tool: try #require(BackupTestTools.pgDump))
        let started = Date()
        let (result, _) = BackupTestTools.run(runner) { event in
            if case .outputSize(let size) = event, size > 0 { runner.cancel() }
        }
        #expect(result.status == .cancelled)
        // Unlike mysqldump, pg_dump catches SIGTERM and exits 1; the run still counts as cancelled, not failed.
        #expect(result.exitCode == 1, "exit \(result.exitCode ?? -1)")
        #expect(result.message == nil)
        #expect(Date().timeIntervalSince(started) < 15)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(BackupTestTools.partials(next: destination).isEmpty)
    }

    @Test func cancellingADirectoryBackupRemovesTheFolder() throws {
        let destination = TestFiles.url("fq114-pg-dir-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: destination) }
        var options = PostgresBackupOptions()
        options.format = .directory
        options.jobs = 2
        let runner = BackupRunner(job: .postgresBackup(scope: .tables([TableRef(schema: "public", name: "perf_big")]), options: options, destination: destination), connection: connection(to: "foxlume"), tool: try #require(BackupTestTools.pgDump))
        let (result, _) = BackupTestTools.run(runner) { event in
            if case .outputSize(let size) = event, size > 0 { runner.cancel() }
        }
        #expect(result.status == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(BackupTestTools.partials(next: destination).isEmpty)
    }
}

// MARK: - PostgreSQL with TLS

@Suite("Backup over TLS against PostgreSQL", .serialized, .enabled(if: TLSTestServers.postgresAvailable && BackupTestTools.pgDump != nil, "needs scripts/dbtest-tls.sh and pg_dump"))
struct PostgresTLSBackupLiveTests {
    private func backup(_ parameters: ConnectionParameters) throws -> BackupRunResult {
        let destination = TestFiles.url("fq114-pg-tls-\(UUID().uuidString.prefix(6)).dump")
        defer { try? FileManager.default.removeItem(at: destination) }
        let secrets = try BackupTestTools.secretFolder("pg-tls")
        defer { try? FileManager.default.removeItem(at: secrets) }
        let runner = BackupRunner(job: .postgresBackup(scope: .schemas(["public"]), options: PostgresBackupOptions(), destination: destination), connection: BackupConnection(parameters: parameters, database: "postgres"), tool: try #require(BackupTestTools.pgDump), secretParent: secrets)
        let result = BackupTestTools.run(runner).0
        // The client key and password files are gone with their folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: secrets.path).isEmpty)
        return result
    }

    @Test func clientCertificatesAndVerification() throws {
        // Verify CA with the test CA and a password login.
        let verified = try backup(TLSTestServers.parameters(.postgresql, user: "postgres", password: "postgres", mode: .verifyCA, files: TLSTestServers.files(ca: "ca.crt")))
        #expect(verified.status == .succeeded, "\(verified.message ?? "")")
        #expect(verified.command.contains("sslmode=verify-ca") && verified.command.contains("sslrootcert="))
        // The certificate names localhost: verify-full fails for 127.0.0.1 and passes for localhost.
        let mismatch = try backup(TLSTestServers.parameters(.postgresql, user: "postgres", password: "postgres", mode: .verifyFull, files: TLSTestServers.files(ca: "ca.crt")))
        #expect(mismatch.status == .failed)
        #expect(mismatch.message?.contains("does not match host name") == true, "\(mismatch.message ?? "")")
        let matching = try backup(TLSTestServers.parameters(.postgresql, host: "localhost", user: "postgres", password: "postgres", mode: .verifyFull, files: TLSTestServers.files(ca: "ca.crt")))
        #expect(matching.status == .succeeded, "\(matching.message ?? "")")
        // certuser logs in only with its certificate (pg_hba "cert"): from a PKCS#12 file, and from an encrypted
        // PKCS#8 key, each with its password; the key reaches pg_dump decrypted in the private folder.
        let fromP12 = try backup(TLSTestServers.parameters(.postgresql, user: "certuser", mode: .verifyCA, files: TLSTestServers.files(ca: "ca.crt", p12: "client.p12"), secret: "secret"))
        #expect(fromP12.status == .succeeded, "\(fromP12.message ?? "")")
        #expect(fromP12.command.contains("sslcert=") && fromP12.command.contains("sslkey=") && !fromP12.command.contains("client.p12"))
        let fromKey = try backup(TLSTestServers.parameters(.postgresql, user: "certuser", mode: .require, files: TLSTestServers.files(cert: "client.crt", key: "client-pkcs8-enc.key"), secret: "secret"))
        #expect(fromKey.status == .succeeded, "\(fromKey.message ?? "")")
        let withoutCertificate = try backup(TLSTestServers.parameters(.postgresql, user: "certuser", mode: .require, files: TLSCertificateFiles()))
        #expect(withoutCertificate.status == .failed)
        #expect(withoutCertificate.message?.contains("certificate") == true, "\(withoutCertificate.message ?? "")")
    }
}

import Foundation
import Security
import Testing
@testable import FoxlumeQueryCore

// MARK: - Tool discovery

@Suite struct BackupToolDiscoveryTests {
    @Test func parsesVersionLines() {
        #expect(BackupToolVersion.parse("pg_dump (PostgreSQL) 16.4 (Homebrew)\n") == BackupToolVersion(major: 16, minor: 4, flavor: .postgresql))
        #expect(BackupToolVersion.parse("pg_restore (PostgreSQL) 18beta1") == BackupToolVersion(major: 18, minor: 0, flavor: .postgresql))
        #expect(BackupToolVersion.parse("psql (PostgreSQL) 9.6.24") == BackupToolVersion(major: 9, minor: 6, flavor: .postgresql))
        #expect(BackupToolVersion.parse("mysqldump  Ver 8.4.9 for macos15 on arm64 (MySQL Community Server - GPL)") == BackupToolVersion(major: 8, minor: 4, patch: 9, flavor: .mysql))
        #expect(BackupToolVersion.parse("mysqldump  Ver 10.13 Distrib 5.7.44, for osx10.19 (x86_64)") == BackupToolVersion(major: 5, minor: 7, patch: 44, flavor: .mysql))
        #expect(BackupToolVersion.parse("mysqldump  Ver 10.19 Distrib 10.11.6-MariaDB, for osx10.19 (arm64)") == BackupToolVersion(major: 10, minor: 11, patch: 6, flavor: .mariadb))
        #expect(BackupToolVersion.parse("mariadb-dump from 11.4.2-MariaDB, client 10.19 for osx10.20 (arm64)") == BackupToolVersion(major: 11, minor: 4, patch: 2, flavor: .mariadb))
        #expect(BackupToolVersion.parse("mysql  Ver 8.4.9 for macos15 on arm64 (MySQL Community Server - GPL)")?.flavor == .mysql)
        #expect(BackupToolVersion.parse("zsh: command not found") == nil)
        #expect(BackupToolVersion.parse("") == nil)
        #expect(BackupToolVersion(major: 16, minor: 4, flavor: .postgresql).description == "16.4")
        #expect(BackupToolVersion(major: 11, minor: 4, patch: 2, flavor: .mariadb).description == "MariaDB 11.4.2")
    }

    @Test func parsesServerVersions() {
        #expect(ServerVersion.parse("16.2") == ServerVersion(major: 16, minor: 2))
        #expect(ServerVersion.parse("8.4.9") == ServerVersion(major: 8, minor: 4))
        #expect(ServerVersion.parse("11.4.2-MariaDB-log") == ServerVersion(major: 11, minor: 4, isMariaDB: true))
        #expect(ServerVersion.parse("5.5.5-10.11.6-MariaDB") == ServerVersion(major: 10, minor: 11, isMariaDB: true))
        #expect(ServerVersion.parse("") == nil)
    }

    @Test func searchesPathThenHomebrewThenPostgresApp() {
        let listings: [String: [String]] = [
            "/opt/homebrew/opt": ["postgresql@14", "libpq", "postgresql@17", "mysql-client@8.0", "mysql-client", "openssl@3", "postgresql@9.6"],
            "/usr/local/opt": [],
            "/Applications/Postgres.app/Contents/Versions": ["15", "17", "latest", "16"],
            "/Library/PostgreSQL": ["13"],
        ]
        let directories = BackupToolDiscovery.searchDirectories(pathVariable: "/Users/me/bin:/opt/homebrew/bin:/usr/bin:") { listings[$0] ?? [] }
        #expect(directories.prefix(3) == ["/Users/me/bin", "/opt/homebrew/bin", "/usr/bin"])
        // No duplicates: /opt/homebrew/bin and /usr/bin came from PATH already.
        #expect(directories.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        #expect(directories.filter { $0 == "/usr/bin" }.count == 1)
        #expect(!directories.contains { $0.contains("openssl") })
        let kegs = directories.filter { $0.hasPrefix("/opt/homebrew/opt/") }
        #expect(kegs.firstIndex(of: "/opt/homebrew/opt/postgresql@17/bin")! < kegs.firstIndex(of: "/opt/homebrew/opt/postgresql@14/bin")!)
        #expect(kegs.firstIndex(of: "/opt/homebrew/opt/postgresql@14/bin")! < kegs.firstIndex(of: "/opt/homebrew/opt/postgresql@9.6/bin")!)
        #expect(kegs.contains("/opt/homebrew/opt/libpq/bin") && kegs.contains("/opt/homebrew/opt/mysql-client/bin"))
        let apps = directories.filter { $0.hasPrefix("/Applications/Postgres.app") }
        #expect(apps == [
            "/Applications/Postgres.app/Contents/Versions/17/bin",
            "/Applications/Postgres.app/Contents/Versions/16/bin",
            "/Applications/Postgres.app/Contents/Versions/15/bin",
            "/Applications/Postgres.app/Contents/Versions/latest/bin",
        ])
        #expect(directories.contains("/Library/PostgreSQL/13/bin"))
        #expect(directories.contains("/usr/local/mysql/bin"))
    }

    @Test func ranksNewestFirstAndMatchingFlavorFirst() {
        let pg = [
            BackupToolCandidate(path: "/usr/local/bin/pg_dump", version: BackupToolVersion(major: 14, minor: 2, flavor: .postgresql)),
            BackupToolCandidate(path: "/broken/pg_dump", version: nil),
            BackupToolCandidate(path: "/opt/homebrew/opt/libpq/bin/pg_dump", version: BackupToolVersion(major: 17, minor: 0, flavor: .postgresql)),
            BackupToolCandidate(path: "/Applications/Postgres.app/Contents/Versions/17/bin/pg_dump", version: BackupToolVersion(major: 17, minor: 0, flavor: .postgresql)),
        ]
        #expect(BackupToolDiscovery.rank(pg).map(\.path) == [
            "/opt/homebrew/opt/libpq/bin/pg_dump",
            "/Applications/Postgres.app/Contents/Versions/17/bin/pg_dump",
            "/usr/local/bin/pg_dump",
            "/broken/pg_dump",
        ])
        let dumps = [
            BackupToolCandidate(path: "/a/mysqldump", version: BackupToolVersion(major: 8, minor: 4, flavor: .mysql)),
            BackupToolCandidate(path: "/b/mariadb-dump", version: BackupToolVersion(major: 11, minor: 4, flavor: .mariadb)),
        ]
        #expect(BackupToolDiscovery.rank(dumps, preferring: .mysql).first?.path == "/a/mysqldump")
        #expect(BackupToolDiscovery.rank(dumps, preferring: .mariadb).first?.path == "/b/mariadb-dump")
    }

    @Test func missingToolMessageNamesToolPlacesAndInstall() {
        let error = BackupError.toolMissing(tool: .pgDump, searched: ["/usr/bin", "/opt/homebrew/bin", "/opt/homebrew/opt/libpq/bin", "/Applications/Postgres.app/Contents/Versions/latest/bin"])
        let message = error.localizedDescription
        #expect(message.hasPrefix("pg_dump was not found."))
        #expect(message.contains("looked in your PATH (1 folder), Homebrew (/opt/homebrew, /usr/local), Postgres.app."))
        #expect(message.contains("brew install libpq"))
        #expect(message.contains("Postgres.app"))
        #expect(message.contains("Settings › Backup Tools"))
        let mysql = BackupError.toolMissing(tool: .mysqldump, searched: []).localizedDescription
        #expect(mysql.hasPrefix("mysqldump or mariadb-dump was not found."))
        #expect(mysql.contains("brew install mysql-client"))
    }

    @Test func warnsWhenPgDumpIsOlderThanTheServer() {
        let old = BackupToolVersion(major: 15, minor: 4, flavor: .postgresql)
        let warning = BackupCompatibility.pgDumpWarning(tool: old, server: ServerVersion(major: 17), path: "/usr/local/bin/pg_dump")
        #expect(warning?.contains("older than the server (PostgreSQL 17)") == true)
        #expect(warning?.contains("install pg_dump 17 or later") == true)
        #expect(BackupCompatibility.pgDumpWarning(tool: BackupToolVersion(major: 17, flavor: .postgresql), server: ServerVersion(major: 16), path: "x") == nil)
        #expect(BackupCompatibility.pgDumpWarning(tool: nil, server: ServerVersion(major: 16), path: "x") == nil)
    }

    @Test func findsAToolInAGivenPathAndHonoursTheOverride() throws {
        let folder = TestFiles.url("fq114-tools-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("pg_dump")
        try "#!/bin/sh\necho 'pg_dump (PostgreSQL) 99.1'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let search = BackupToolDiscovery.find(.pgDump, pathVariable: folder.path)
        #expect(search.chosen?.path == script.path)
        #expect(search.chosen?.version == BackupToolVersion(major: 99, minor: 1, flavor: .postgresql))
        #expect(!search.isOverride)
        #expect(search.searchedDirectories.first == folder.path)
        let overridden = BackupToolDiscovery.find(.pgDump, override: folder.appendingPathComponent("missing").path, pathVariable: folder.path)
        #expect(overridden.isOverride && overridden.chosen == nil)
        #expect(overridden.candidates.first?.path == script.path)
    }
}

// MARK: - Command lines

@Suite struct BackupCommandTests {
    let secrets = URL(fileURLWithPath: "/private/tmp/fq-secrets")
    let pg17 = BackupToolCandidate(path: "/opt/homebrew/opt/libpq/bin/pg_dump", version: BackupToolVersion(major: 17, minor: 2, flavor: .postgresql))
    let mysql84 = BackupToolCandidate(path: "/opt/homebrew/opt/mysql-client/bin/mysqldump", version: BackupToolVersion(major: 8, minor: 4, patch: 9, flavor: .mysql))
    let mariadb = BackupToolCandidate(path: "/opt/homebrew/bin/mariadb-dump", version: BackupToolVersion(major: 11, minor: 4, patch: 2, flavor: .mariadb))
    let password = "s3cr:et\\pa'ss \"word\""

    func endpoint(_ mode: SSLMode = .prefer, tunnel: Bool = false, ca: String? = nil, cert: String? = nil, key: String? = nil) -> BackupEndpoint {
        BackupEndpoint(host: tunnel ? "127.0.0.1" : "db.example.com", port: tunnel ? 61234 : 5432, tunnelledHost: tunnel ? "db.example.com" : nil,
                       user: "app", database: "shop", sslMode: mode, caPath: ca, certificatePath: cert, keyPath: key)
    }

    @Test func pgDumpCustomDefaults() {
        let invocation = BackupCommandBuilder.pgDump(tool: pg17, endpoint: endpoint(), scope: .database, options: PostgresBackupOptions(), output: "/backups/shop.dump", password: password, secretDirectory: secrets)
        #expect(invocation.executable == pg17.path)
        #expect(invocation.arguments == [
            "--dbname=host=db.example.com port=5432 user=app dbname=shop sslmode=prefer",
            "--no-password",
            "--verbose",
            "--format=custom",
            "--file=/backups/shop.dump",
            "--compress=6",
        ])
        #expect(invocation.environment == ["PGPASSFILE": "/private/tmp/fq-secrets/pgpass"])
        #expect(invocation.secretFiles == [BackupSecretFile(path: "/private/tmp/fq-secrets/pgpass", contents: "*:*:*:*:s3cr\\:et\\\\pa'ss \"word\"\n", label: "<password file>")])
        #expect(invocation.arguments.allSatisfy { !$0.contains("s3cr") })
        #expect(!invocation.displayCommand().contains("s3cr"))
    }

    @Test func pgDumpPlainWithInsertsCleanAndGzip() {
        var options = PostgresBackupOptions()
        options.format = .plain
        options.clean = true
        options.compressPlain = true
        options.noOwner = true
        options.noPrivileges = true
        options.compressionLevel = 9
        let arguments = BackupCommandBuilder.pgDump(tool: pg17, endpoint: endpoint(), scope: .database, options: options, output: "/b/shop.sql.gz", password: "", secretDirectory: secrets).arguments
        #expect(Array(arguments.dropFirst(3)) == [
            "--format=plain", "--file=/b/shop.sql.gz", "--compress=6", "--no-owner", "--no-privileges", "--encoding=UTF8", "--clean", "--if-exists", "--rows-per-insert=1000",
        ])
        #expect(options.fileExtension == "sql.gz")
        // pg_dump before 12 has no --rows-per-insert; schema-only needs no INSERTs at all.
        let old = BackupToolCandidate(path: "/usr/bin/pg_dump", version: BackupToolVersion(major: 11, minor: 9, flavor: .postgresql))
        #expect(BackupCommandBuilder.pgDump(tool: old, endpoint: endpoint(), scope: .database, options: options, output: "/b/x", password: "", secretDirectory: secrets).arguments.contains("--inserts"))
        options.content = .schemaOnly
        options.clean = false
        let schemaOnly = BackupCommandBuilder.pgDump(tool: pg17, endpoint: endpoint(), scope: .database, options: options, output: "/b/x", password: "", secretDirectory: secrets).arguments
        #expect(schemaOnly.contains("--schema-only") && !schemaOnly.contains { $0.hasPrefix("--rows-per-insert") } && !schemaOnly.contains("--clean"))
    }

    @Test func pgDumpDirectoryJobsAndDataOnly() {
        var options = PostgresBackupOptions()
        options.format = .directory
        options.jobs = 4
        options.content = .dataOnly
        options.compressionLevel = 0
        options.clean = true
        let arguments = BackupCommandBuilder.pgDump(tool: pg17, endpoint: endpoint(), scope: .database, options: options, output: "/b/shop", password: "", secretDirectory: secrets).arguments
        #expect(arguments.contains("--format=directory") && arguments.contains("--compress=0") && arguments.contains("--jobs=4") && arguments.contains("--data-only"))
        // --clean only applies to plain scripts; pg_restore takes it for archives.
        #expect(!arguments.contains("--clean"))
        #expect(options.fileExtension.isEmpty)
        options.format = .tar
        let tar = BackupCommandBuilder.pgDump(tool: pg17, endpoint: endpoint(), scope: .database, options: options, output: "/b/shop.tar", password: "", secretDirectory: secrets).arguments
        #expect(tar.contains("--format=tar") && !tar.contains { $0.hasPrefix("--compress") || $0.hasPrefix("--jobs") })
    }

    @Test func pgDumpScopesQuoteNamesLiterally() {
        let schemas = BackupCommandBuilder.pgDump(tool: pg17, endpoint: endpoint(), scope: .schemas(["public", "Sales \"EU\""]), options: PostgresBackupOptions(), output: "/b/x", password: "", secretDirectory: secrets).arguments
        #expect(schemas.suffix(2) == ["--schema=\"public\"", "--schema=\"Sales \"\"EU\"\"\""])
        let tables = BackupCommandBuilder.pgDump(tool: pg17, endpoint: endpoint(), scope: .tables([TableRef(schema: "public", name: "Order*s"), TableRef(name: "plain")]), options: PostgresBackupOptions(), output: "/b/x", password: "", secretDirectory: secrets).arguments
        #expect(tables.suffix(2) == ["--table=\"public\".\"Order*s\"", "--table=\"plain\""])
    }

    @Test func postgresTLSAndTunnelInTheConnectionString() {
        let direct = BackupCommandBuilder.postgresConnectionString(endpoint(.verifyCA, ca: "/certs/ca.pem", cert: "/s/client-cert.pem", key: "/s/client-key.pem"), tool: pg17.version)
        #expect(direct == "host=db.example.com port=5432 user=app dbname=shop sslmode=verify-ca sslrootcert=/certs/ca.pem sslcert=/s/client-cert.pem sslkey=/s/client-key.pem")
        // Through a tunnel the real name is checked by verify-full while hostaddr dials the local end.
        let tunnelled = BackupCommandBuilder.postgresConnectionString(endpoint(.verifyFull, tunnel: true), tool: pg17.version)
        #expect(tunnelled == "host=db.example.com hostaddr=127.0.0.1 port=61234 user=app dbname=shop sslmode=verify-full sslrootcert=system")
        // libpq before 16 has no sslrootcert=system; the note says what it does instead.
        let old = BackupToolCandidate(path: "/x/pg_dump", version: BackupToolVersion(major: 15, minor: 1, flavor: .postgresql))
        let invocation = BackupCommandBuilder.pgDump(tool: old, endpoint: endpoint(.verifyFull), scope: .database, options: PostgresBackupOptions(), output: "/b/x", password: "", secretDirectory: secrets)
        #expect(!invocation.arguments[0].contains("sslrootcert"))
        #expect(invocation.notes.first?.contains("root.crt") == true)
        // Disabled TLS passes no certificate files.
        let disabled = BackupCommandBuilder.postgresConnectionString(endpoint(.disable, ca: "/c/ca.pem", cert: "/c/c.pem", key: "/c/k.pem"), tool: pg17.version)
        #expect(disabled == "host=db.example.com port=5432 user=app dbname=shop sslmode=disable")
    }

    @Test func connectionStringValuesAreQuoted() {
        var target = endpoint()
        target.database = "my db"
        target.user = "o'brien"
        target.caPath = "/Users/me/My Certs\\ca.pem"
        target.sslMode = .require
        #expect(BackupCommandBuilder.postgresConnectionString(target, tool: pg17.version)
            == "host=db.example.com port=5432 user='o\\'brien' dbname='my db' sslmode=require sslrootcert='/Users/me/My Certs\\\\ca.pem'")
    }

    @Test func pgRestoreOptions() {
        let tool = BackupToolCandidate(path: "/x/pg_restore", version: pg17.version)
        var options = PostgresRestoreOptions()
        options.clean = true
        options.noOwner = true
        options.jobs = 4
        let parallel = BackupCommandBuilder.pgRestore(tool: tool, endpoint: endpoint(), archive: "/b/shop.dump", archiveIsTar: false, options: options, password: password, secretDirectory: secrets)
        #expect(Array(parallel.arguments.dropFirst()) == ["--no-password", "--verbose", "--clean", "--if-exists", "--no-owner", "--jobs=4", "/b/shop.dump"])
        #expect(parallel.environment["PGPASSFILE"] != nil)
        let tar = BackupCommandBuilder.pgRestore(tool: tool, endpoint: endpoint(), archive: "/b/shop.tar", archiveIsTar: true, options: options, password: "", secretDirectory: secrets)
        #expect(!tar.arguments.contains("--jobs=4"))
        #expect(tar.environment.isEmpty && tar.secretFiles.isEmpty)
        options.singleTransaction = true
        let single = BackupCommandBuilder.pgRestore(tool: tool, endpoint: endpoint(), archive: "/b/shop.dump", archiveIsTar: false, options: options, password: "", secretDirectory: secrets)
        #expect(single.arguments.contains("--single-transaction") && !single.arguments.contains("--jobs=4"))
    }

    @Test func psqlScriptStopsAtTheFirstError() {
        let tool = BackupToolCandidate(path: "/x/psql", version: pg17.version)
        let invocation = BackupCommandBuilder.psqlScript(tool: tool, endpoint: endpoint(), singleTransaction: true, password: password, secretDirectory: secrets)
        #expect(Array(invocation.arguments.dropFirst()) == ["--no-password", "--no-psqlrc", "--set=ON_ERROR_STOP=1", "--echo-errors", "--single-transaction", "--file=-"])
        #expect(!invocation.arguments.joined().contains("s3cr"))
    }

    @Test func mysqldumpDefaults() {
        var target = endpoint()
        target.port = 3306
        let invocation = BackupCommandBuilder.mysqldump(tool: mysql84, endpoint: target, server: ServerVersion(major: 8, minor: 4), scope: .database, options: MySQLBackupOptions(), password: password, secretDirectory: secrets)
        #expect(invocation.arguments == [
            "--defaults-extra-file=/private/tmp/fq-secrets/client.cnf",
            "--protocol=TCP", "--host=db.example.com", "--port=3306", "--user=app", "--ssl-mode=PREFERRED",
            "--verbose", "--default-character-set=utf8mb4", "--hex-blob", "--no-tablespaces", "--set-gtid-purged=OFF",
            "--single-transaction", "--routines", "--triggers", "--skip-events", "--add-drop-table", "shop",
        ])
        #expect(invocation.environment.isEmpty)
        #expect(invocation.secretFiles.map(\.path) == ["/private/tmp/fq-secrets/client.cnf"])
        #expect(invocation.arguments.allSatisfy { !$0.contains("s3cr") })
        #expect(invocation.displayCommand().hasPrefix("/opt/homebrew/opt/mysql-client/bin/mysqldump --defaults-extra-file=<password file> --protocol=TCP"))
    }

    @Test func mysqldumpOptionsAndScopes() {
        var options = MySQLBackupOptions()
        options.singleTransaction = false
        options.events = true
        options.content = .dataOnly
        let dataOnly = BackupCommandBuilder.mysqldump(tool: mysql84, endpoint: endpoint(), server: nil, scope: .tables([TableRef(name: "orders"), TableRef(name: "users")]), options: options, password: "", secretDirectory: secrets).arguments
        #expect(dataOnly.first == "--protocol=TCP")
        #expect(dataOnly.contains("--lock-tables") && dataOnly.contains("--no-create-info"))
        // Data only leaves out routines, triggers and events, and DROP TABLE.
        #expect(dataOnly.contains("--skip-routines") && dataOnly.contains("--skip-triggers") && dataOnly.contains("--skip-events"))
        #expect(!dataOnly.contains("--add-drop-table") && !dataOnly.contains("--skip-add-drop-table"))
        #expect(dataOnly.suffix(3) == ["shop", "orders", "users"])
        options = MySQLBackupOptions()
        options.content = .schemaOnly
        options.addDropTable = false
        let databases = BackupCommandBuilder.mysqldump(tool: mysql84, endpoint: endpoint(), server: nil, scope: .schemas(["shop", "crm"]), options: options, password: "", secretDirectory: secrets).arguments
        #expect(databases.contains("--no-data") && databases.contains("--skip-add-drop-table"))
        #expect(databases.suffix(3) == ["--databases", "shop", "crm"])
    }

    @Test func mysqldumpAgainstMariaDBAndOlderServers() {
        let mariadbServer = BackupCommandBuilder.mysqldump(tool: mysql84, endpoint: endpoint(), server: ServerVersion(major: 11, minor: 4, isMariaDB: true), scope: .database, options: MySQLBackupOptions(), password: "", secretDirectory: secrets)
        #expect(mariadbServer.arguments.contains("--column-statistics=0"))
        #expect(mariadbServer.notes.contains { $0.contains("mariadb-dump") })
        let mysql57 = BackupCommandBuilder.mysqldump(tool: mysql84, endpoint: endpoint(), server: ServerVersion(major: 5, minor: 7), scope: .database, options: MySQLBackupOptions(), password: "", secretDirectory: secrets)
        #expect(mysql57.arguments.contains("--column-statistics=0"))
        let mariaTool = BackupCommandBuilder.mysqldump(tool: mariadb, endpoint: endpoint(.require), server: ServerVersion(major: 11, minor: 4, isMariaDB: true), scope: .database, options: MySQLBackupOptions(), password: "", secretDirectory: secrets)
        #expect(!mariaTool.arguments.contains { $0.hasPrefix("--set-gtid-purged") || $0.hasPrefix("--column-statistics") || $0.hasPrefix("--ssl-mode") })
        #expect(mariaTool.arguments.contains("--ssl") && mariaTool.arguments.contains("--skip-ssl-verify-server-cert"))
        #expect(mariaTool.notes.isEmpty)
    }

    @Test func mysqlTLSModesAndFiles() {
        func modeArguments(_ tool: BackupToolCandidate, _ endpoint: BackupEndpoint) -> (arguments: [String], notes: [String]) {
            let result = BackupCommandBuilder.mysqlConnectionArguments(endpoint, tool: tool.version)
            return (Array(result.arguments.dropFirst(4)), result.notes)
        }
        #expect(modeArguments(mysql84, endpoint(.disable, ca: "/c/ca.pem")).arguments == ["--ssl-mode=DISABLED"])
        #expect(modeArguments(mysql84, endpoint(.require)).arguments == ["--ssl-mode=REQUIRED"])
        #expect(modeArguments(mysql84, endpoint(.verifyCA, ca: "/c/ca.pem", cert: "/s/c.pem", key: "/s/k.pem")).arguments
            == ["--ssl-mode=VERIFY_CA", "--ssl-ca=/c/ca.pem", "--ssl-cert=/s/c.pem", "--ssl-key=/s/k.pem"])
        #expect(modeArguments(mysql84, endpoint(.verifyFull)).arguments == ["--ssl-mode=VERIFY_IDENTITY"])
        // A tunnel's local end cannot match the certificate's host name.
        let tunnelled = modeArguments(mysql84, endpoint(.verifyFull, tunnel: true))
        #expect(tunnelled.arguments == ["--ssl-mode=VERIFY_CA"])
        #expect(tunnelled.notes.first?.contains("SSH tunnel") == true)
        #expect(modeArguments(mariadb, endpoint(.disable)).arguments == ["--skip-ssl"])
        #expect(modeArguments(mariadb, endpoint(.prefer)).arguments == ["--skip-ssl-verify-server-cert"])
        let mariaVerify = modeArguments(mariadb, endpoint(.verifyCA, ca: "/c/ca.pem"))
        #expect(mariaVerify.arguments == ["--ssl", "--ssl-verify-server-cert", "--ssl-ca=/c/ca.pem"])
        #expect(mariaVerify.notes.first?.contains("no Verify CA mode") == true)
    }

    @Test func mysqlClientScript() {
        let tool = BackupToolCandidate(path: "/x/mysql", version: mysql84.version)
        let invocation = BackupCommandBuilder.mysqlScript(tool: tool, endpoint: endpoint(), password: password, secretDirectory: secrets)
        #expect(invocation.arguments.first == "--defaults-extra-file=/private/tmp/fq-secrets/client.cnf")
        #expect(invocation.arguments.last == "--database=shop")
        #expect(!invocation.arguments.joined().contains("s3cr"))
    }

    @Test func optionAndPassFilesEscapeTheirValues() {
        #expect(BackupCommandBuilder.mysqlOptionFileContents(password: "a\"b\\c d#e\nf") == "[client]\npassword=\"a\\\"b\\\\c d#e\\nf\"\n")
        #expect(BackupCommandBuilder.pgpassContents(password: "a:b\\c") == "*:*:*:*:a\\:b\\\\c\n")
    }

    @Test func displayCommandQuotesAndHidesSecrets() {
        var options = PostgresBackupOptions()
        options.format = .plain
        options.useInserts = false
        let invocation = BackupCommandBuilder.pgDump(tool: pg17, endpoint: endpoint(), scope: .schemas(["it's"]), options: options, output: "/b/.My Backup.sql.1234.partial", password: password, secretDirectory: secrets)
        let shown = invocation.displayCommand(replacing: ["/b/.My Backup.sql.1234.partial": "/b/My Backup.sql"])
        #expect(shown == "PGPASSFILE=<password file> /opt/homebrew/opt/libpq/bin/pg_dump '--dbname=host=db.example.com port=5432 user=app dbname=shop sslmode=prefer' --no-password --verbose --format=plain '--file=/b/My Backup.sql' --encoding=UTF8 '--schema=\"it'\\''s\"'")
    }
}

// MARK: - Files and secrets

@Suite struct BackupFileTests {
    @Test func detectsFormatsFromTheirFirstBytes() {
        #expect(BackupFileKind.detect(header: Array("PGDMP\u{1}\u{10}".utf8), compressed: false) == .postgresCustom)
        var tar = [UInt8](repeating: 0, count: 512)
        tar.replaceSubrange(0..<7, with: Array("toc.dat".utf8))
        tar.replaceSubrange(257..<262, with: Array("ustar".utf8))
        #expect(BackupFileKind.detect(header: tar, compressed: false) == .postgresTar)
        tar.replaceSubrange(0..<7, with: Array("foo.txt".utf8))
        #expect(BackupFileKind.detect(header: tar, compressed: false) == .unknown)
        #expect(BackupFileKind.detect(header: Array("--\n-- PostgreSQL database dump\n--\n".utf8), compressed: true) == .plainSQL(compressed: true, dialect: .postgresql))
        #expect(BackupFileKind.detect(header: Array("-- MySQL dump 10.13  Distrib 8.4.9\n".utf8), compressed: false) == .plainSQL(compressed: false, dialect: .mysql))
        #expect(BackupFileKind.detect(header: Array("-- MariaDB dump 10.19\n".utf8), compressed: false) == .plainSQL(compressed: false, dialect: .mysql))
        #expect(BackupFileKind.detect(header: Array("CREATE TABLE t (id int);\n".utf8), compressed: false) == .plainSQL(compressed: false, dialect: nil))
        #expect(BackupFileKind.detect(header: [0x00, 0x01, 0x02, 0xFF], compressed: false) == .unknown)
    }

    @Test func detectsFilesAndFolders() throws {
        let folder = TestFiles.url("fq114-detect-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        #expect(BackupFileKind.detect(archive) == .unknown)
        try Data("x".utf8).write(to: archive.appendingPathComponent("toc.dat"))
        #expect(BackupFileKind.detect(archive) == .postgresDirectory)
        let custom = folder.appendingPathComponent("named.sql")
        try Data("PGDMP\u{1}".utf8).write(to: custom)
        #expect(BackupFileKind.detect(custom) == .postgresCustom)
        let gz = folder.appendingPathComponent("dump.sql.gz")
        try gzip(Data("--\n-- PostgreSQL database dump\n--\nCOPY public.t (id) FROM stdin;\n1\n\\.\n".utf8)).write(to: gz)
        #expect(BackupFileKind.detect(gz) == .plainSQL(compressed: true, dialect: .postgresql))
        #expect(try PlainDumpInspector.usesCopyFromStdin(gz))
        let inserts = folder.appendingPathComponent("inserts.sql")
        try Data("-- PostgreSQL database dump\nINSERT INTO t VALUES (1);\n-- COPY t FROM stdin;\nCOPY t TO stdout;".utf8).write(to: inserts)
        #expect(try PlainDumpInspector.usesCopyFromStdin(inserts) == false)
        #expect(BackupFileKind.detect(folder.appendingPathComponent("missing")) == .unknown)
    }

    private func gzip(_ data: Data) throws -> Data {
        let encoder = try GzipEncoder()
        return try encoder.encode(data, final: true)
    }

    @Test func secretFilesArePrivateAndRemoved() throws {
        let directory = try BackupSecretDirectory(parent: TestFiles.directory)
        let path = directory.url.appendingPathComponent("pgpass").path
        try directory.write([BackupSecretFile(path: path, contents: "*:*:*:*:pw\n", label: "<password file>")])
        let folderMode = try FileManager.default.attributesOfItem(atPath: directory.url.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(folderMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "*:*:*:*:pw\n")
        directory.remove()
        #expect(!FileManager.default.fileExists(atPath: directory.url.path))
        directory.remove()
    }

    @Test(.enabled(if: TLSFixtures.isAvailable, "needs /usr/bin/openssl"))
    func clientCertificatesBecomePlainPEMFiles() throws {
        let expected = try TLSFixtures.certificate("client.crt")
        let expectedKey = SecCertificateCopyKey(expected).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? }
        let cases: [(TLSCertificateFiles, String?)] = [
            (TLSCertificateFiles(caCertificatePath: TLSFixtures.path("ca.crt"), pkcs12Path: TLSFixtures.path("client.p12")), "secret"),
            (TLSCertificateFiles(clientCertificatePath: TLSFixtures.path("client.crt"), clientKeyPath: TLSFixtures.path("client-pkcs8-enc.key")), "secret"),
            (TLSCertificateFiles(clientCertificatePath: TLSFixtures.path("client-chain.crt"), clientKeyPath: TLSFixtures.path("client-legacy-enc.key")), "secret"),
        ]
        for (files, secret) in cases {
            let directory = try BackupSecretDirectory(parent: TestFiles.directory)
            defer { directory.remove() }
            let resolved = try BackupTLSFiles.resolve(mode: .verifyCA, files: files, secret: secret, in: directory)
            #expect(resolved.caPath == (files.caCertificatePath.isEmpty ? nil : files.caCertificatePath))
            let certificate = try #require(resolved.certificatePath)
            let key = try #require(resolved.keyPath)
            for path in [certificate, key] {
                #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            }
            #expect(try String(contentsOfFile: key, encoding: .utf8).hasPrefix("-----BEGIN RSA PRIVATE KEY-----\n"))
            // The written files load again without a passphrase, as the same identity.
            let identity = try TLSCredentials.identity(certificatePath: certificate, keyPath: key, passphrase: nil)
            let key2 = SecCertificateCopyKey(identity.certificate).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? }
            #expect(key2 == expectedKey)
        }
        // EC keys are written as SEC1.
        let directory = try BackupSecretDirectory(parent: TestFiles.directory)
        defer { directory.remove() }
        let ec = try BackupTLSFiles.resolve(mode: .require, files: TLSCertificateFiles(clientCertificatePath: TLSFixtures.path("client-ec.crt"), clientKeyPath: TLSFixtures.path("client-ec.key")), secret: nil, in: directory)
        let ecKey = try #require(ec.keyPath)
        #expect(try String(contentsOfFile: ecKey, encoding: .utf8).hasPrefix("-----BEGIN EC PRIVATE KEY-----\n"))
        _ = try TLSCredentials.identity(certificatePath: try #require(ec.certificatePath), keyPath: ecKey, passphrase: nil)
        // Without TLS or a client certificate nothing is written.
        let none = try BackupTLSFiles.resolve(mode: .disable, files: TLSCertificateFiles(pkcs12Path: TLSFixtures.path("client.p12")), secret: "secret", in: directory)
        #expect(none == BackupTLSFiles.Resolved())
        let caOnly = try BackupTLSFiles.resolve(mode: .verifyCA, files: TLSCertificateFiles(caCertificatePath: "/c/ca.pem"), secret: nil, in: directory)
        #expect(caOnly == BackupTLSFiles.Resolved(caPath: "/c/ca.pem"))
        #expect(throws: TLSFileError.self) {
            _ = try BackupTLSFiles.resolve(mode: .require, files: TLSCertificateFiles(pkcs12Path: TLSFixtures.path("client.p12")), secret: "wrong", in: directory)
        }
    }
}

// MARK: - Client commands in scripts

@Suite struct ClientDirectiveTests {
    private func run(_ pieces: [String], _ family: SQLDialect.Family) -> String {
        var filter = ClientDirectiveFilter(family: family)
        return pieces.map { filter.filter($0, final: false) }.joined() + filter.filter("", final: true)
    }

    @Test func mysqlDelimiterBlocksBecomeStatements() {
        let script = """
            /*!50003 SET sql_mode = '' */ ;
            DELIMITER ;;
            /*!50003 CREATE*/ /*!50003 TRIGGER `t_ai` AFTER INSERT ON `t` FOR EACH ROW BEGIN INSERT INTO log VALUES (1); END */;;
            CREATE PROCEDURE p()
            BEGIN
              SELECT 1;
            END ;;
            DELIMITER ;
            SELECT 2;
            delimiter $$
            CREATE FUNCTION f() RETURNS INT RETURN 1$$
            delimiter ;
            """
        // Cut in odd places, as chunks of a large file are.
        let pieces = stride(from: 0, to: script.count, by: 7).map { start -> String in
            let from = script.index(script.startIndex, offsetBy: start)
            let to = script.index(from, offsetBy: min(7, script.distance(from: from, to: script.endIndex)))
            return String(script[from..<to])
        }
        let filtered = run(pieces, .mysql)
        #expect(filtered.components(separatedBy: "\n").count == script.components(separatedBy: "\n").count)
        let statements = SQLStatementSplitter.split(filtered, family: .mysql).map(\.text)
        #expect(statements == [
            "/*!50003 SET sql_mode = '' */",
            "/*!50003 CREATE*/ /*!50003 TRIGGER `t_ai` AFTER INSERT ON `t` FOR EACH ROW BEGIN INSERT INTO log VALUES (1); END */",
            "CREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\nEND",
            "SELECT 2",
            "CREATE FUNCTION f() RETURNS INT RETURN 1",
        ])
    }

    @Test func postgresRestrictLinesAreDropped() {
        let script = "\\restrict AbC123\n--\n-- PostgreSQL database dump\n--\nSET client_encoding = 'UTF8';\n\\unrestrict AbC123\n"
        let filtered = run([script], .postgresql)
        #expect(SQLStatementSplitter.split(filtered, family: .postgresql).map(\.text) == ["--\n-- PostgreSQL database dump\n--\nSET client_encoding = 'UTF8'"])
        // Other text passes through untouched, and SQLite ignores both commands.
        #expect(run(["SELECT 'DELIMITER ;;';\n"], .mysql) == "SELECT 'DELIMITER ;;';\n")
        #expect(run(["DELIMITER ;;\n"], .sqlite) == "DELIMITER ;;\n")
    }

    @Test func runnerReadsDelimiterScriptsFromFiles() throws {
        let file = TestFiles.url("fq114-delimiter-\(UUID().uuidString.prefix(6)).sql")
        defer { try? FileManager.default.removeItem(at: file) }
        try "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END //\nDELIMITER ;\nCALL p();\n".write(to: file, atomically: true, encoding: .utf8)
        var statements: [SQLFileStatement] = []
        try SQLFileRunner.forEachStatement(in: file, family: .mysql) { statements.append($0); return true }
        #expect(statements.map(\.text) == ["CREATE PROCEDURE p() BEGIN SELECT 1; END", "CALL p()"])
        #expect(statements.map(\.line) == [2, 4])
    }
}

// MARK: - Processes

@Suite struct ToolProcessTests {
    @Test func streamsErrorLinesAndOutput() throws {
        let process = ToolProcess(executable: "/bin/sh", arguments: ["-c", "printf 'one\\ntwo\\r\\nthree' >&2; printf out; exit 3"], environment: ToolProcess.environment(adding: [:]))
        var lines: [String] = []
        var output = Data()
        let lock = NSLock()
        process.onErrorLine = { line in lock.lock(); lines.append(line); lock.unlock() }
        process.onOutput = { data in lock.lock(); output.append(data); lock.unlock() }
        try process.start()
        #expect(process.waitUntilExit() == 3)
        #expect(lines == ["one", "two", "three"])
        #expect(String(decoding: output, as: UTF8.self) == "out")
    }

    @Test func feedsStandardInputAndCleansTheEnvironment() throws {
        setenv("PGPASSWORD", "leaked", 1)
        defer { unsetenv("PGPASSWORD") }
        let environment = ToolProcess.environment(adding: ["PGPASSFILE": "/x/pgpass"])
        #expect(environment["PGPASSWORD"] == nil && environment["PGPASSFILE"] == "/x/pgpass" && environment["PATH"] != nil)
        let process = ToolProcess(executable: "/bin/sh", arguments: ["-c", "cat; echo \"[$PGPASSWORD]\""], environment: environment, input: .pipe)
        var output = Data()
        process.onOutput = { output.append($0) }
        try process.start()
        #expect(process.writeInput(Array("hello ".utf8)))
        process.closeInput()
        #expect(process.waitUntilExit() == 0)
        #expect(String(decoding: output, as: UTF8.self) == "hello []\n")
    }

    @Test func terminateStopsTheWholeProcessGroup() throws {
        let marker = TestFiles.url("fq114-child-\(UUID().uuidString.prefix(6)).pid")
        defer { try? FileManager.default.removeItem(at: marker) }
        // The shell starts a worker of its own, as pg_dump --jobs does, then waits.
        let process = ToolProcess(executable: "/bin/sh", arguments: ["-c", "sleep 30 & echo $! > '\(marker.path)'; wait"], environment: ToolProcess.environment(adding: [:]))
        try process.start()
        var childPID: pid_t = 0
        for _ in 0..<200 where childPID == 0 {
            Thread.sleep(forTimeInterval: 0.05)
            childPID = pid_t((try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        }
        #expect(childPID > 0)
        let started = Date()
        process.terminate()
        let code = process.waitUntilExit()
        #expect(code == 128 + SIGTERM)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(process.wasTerminated)
        // The worker got the signal too.
        var gone = false
        for _ in 0..<40 where !gone {
            gone = kill(childPID, 0) != 0
            if !gone { Thread.sleep(forTimeInterval: 0.05) }
        }
        #expect(gone)
    }

    /// BackupRunner hands the process to `cancel()` before starting it, so a cancel can arrive before the tool exists.
    @Test func terminateBeforeStartStopsTheToolOnceItStarts() throws {
        let process = ToolProcess(executable: "/bin/sh", arguments: ["-c", "sleep 30"], environment: ToolProcess.environment(adding: [:]))
        process.terminate()
        let started = Date()
        try process.start()
        #expect(process.waitUntilExit() == 128 + SIGTERM)
        #expect(Date().timeIntervalSince(started) < 20)
        #expect(process.wasTerminated)
    }

    @Test func missingExecutableIsReported() {
        let process = ToolProcess(executable: "/nonexistent/pg_dump", arguments: [], environment: [:])
        #expect(throws: BackupError.toolNotRunnable(path: "/nonexistent/pg_dump")) { try process.start() }
    }
}

// MARK: - Runner with stand-in tools

/// BackupRunner end to end with small shell scripts standing in for pg_dump and mysqldump: what the tool really gets
/// (arguments, environment, the password file while it runs), where the output lands, and the clean-up.
@Suite struct BackupRunnerTests {
    let password = "pa:ss w\"o\\rd"

    /// A folder with a stand-in tool that records its arguments, its password file and that file's mode next to itself.
    private func standIn(_ name: String, body: String) throws -> (folder: URL, tool: URL) {
        let folder = TestFiles.url("fq114-standin-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tool = folder.appendingPathComponent(name)
        let script = """
            #!/bin/sh
            probe='\(folder.path)/probe'
            for a in "$@"; do printf '%s\\n' "$a"; done > "$probe.args"
            env > "$probe.env"
            secret="$PGPASSFILE"
            case "$1" in --defaults-extra-file=*) secret="${1#--defaults-extra-file=}";; esac
            if [ -n "$secret" ]; then cat "$secret" > "$probe.secret"; stat -f %Lp "$secret" > "$probe.mode"; printf '%s' "$secret" > "$probe.path"; fi
            \(body)
            """
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (folder, tool)
    }

    private func read(_ folder: URL, _ name: String) -> String {
        (try? String(contentsOf: folder.appendingPathComponent("probe.\(name)"), encoding: .utf8)) ?? ""
    }

    private func connection(_ kind: DatabaseKind, serverMajor: Int? = nil) -> BackupConnection {
        var config = ConnectionConfig(kind: kind, host: "db.example.com", port: kind == .postgresql ? 5432 : 3306, user: "app", database: "shop", sslMode: .prefer)
        config.environment = .local
        return BackupConnection(parameters: ConnectionParameters(config: config, password: password), database: "shop", serverVersion: ServerVersion(major: serverMajor ?? (kind == .postgresql ? 17 : 8)))
    }

    @Test func pgDumpGetsAPrivatePassfileAndTheBackupIsMovedIntoPlace() throws {
        let (folder, tool) = try standIn("pg_dump", body: """
            for a in "$@"; do case "$a" in --file=*) out="${a#--file=}";; esac; done
            echo 'pg_dump: dumping contents of table "public.items"' >&2
            printf 'PGDMP stand-in' > "$out"
            """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("shop.dump")
        try Data("older backup".utf8).write(to: destination)
        let secrets = folder.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        let runner = BackupRunner(job: .postgresBackup(scope: .database, options: PostgresBackupOptions(), destination: destination), connection: connection(.postgresql),
                                  tool: BackupToolCandidate(path: tool.path, version: BackupToolVersion(major: 17, flavor: .postgresql)), secretParent: secrets)
        var lines: [String] = []
        let result = runner.run { if case .log(let line) = $0 { lines.append(line) } }
        #expect(result.status == .succeeded, "\(result.message ?? "")")
        #expect(lines == ["pg_dump: dumping contents of table \"public.items\""])
        #expect(try String(contentsOf: destination, encoding: .utf8) == "PGDMP stand-in")
        #expect(result.outputSize == 14)
        // What the tool got: no password among its arguments or in its environment, a 0600 passfile that held it.
        let arguments = read(folder, "args")
        #expect(!arguments.contains("pa:ss") && !read(folder, "env").contains("pa:ss"))
        #expect(arguments.contains("--file=\(folder.path)/.shop.dump."))
        #expect(read(folder, "secret") == BackupCommandBuilder.pgpassContents(password: password))
        #expect(read(folder, "mode").trimmingCharacters(in: .whitespacesAndNewlines) == "600")
        #expect(read(folder, "env").contains("PGPASSFILE=\(read(folder, "path"))"))
        // The passfile and its folder are gone; the command shows the destination, not the partial file.
        #expect(!FileManager.default.fileExists(atPath: read(folder, "path")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: secrets.path).isEmpty)
        #expect(result.command.hasPrefix("PGPASSFILE=<password file> \(tool.path) "))
        #expect(result.command.contains("--file=\(destination.path)"))
        #expect(BackupTestTools.partials(next: destination).isEmpty)
    }

    @Test func aFailedOrCancelledBackupKeepsTheOlderFile() throws {
        let (folder, tool) = try standIn("pg_dump", body: """
            for a in "$@"; do case "$a" in --file=*) out="${a#--file=}";; esac; done
            printf 'half' > "$out"
            echo 'pg_dump: error: connection to server failed: FATAL:  password authentication failed for user "app"' >&2
            exit 1
            """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("shop.dump")
        try Data("older backup".utf8).write(to: destination)
        let candidate = BackupToolCandidate(path: tool.path, version: BackupToolVersion(major: 17, flavor: .postgresql))
        let failed = BackupRunner(job: .postgresBackup(scope: .database, options: PostgresBackupOptions(), destination: destination), connection: connection(.postgresql), tool: candidate).run { _ in }
        #expect(failed.status == .failed)
        #expect(failed.exitCode == 1)
        #expect(failed.message == "pg_dump: error: connection to server failed: FATAL:  password authentication failed for user \"app\"")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "older backup")
        #expect(BackupTestTools.partials(next: destination).isEmpty)

        let (slowFolder, slowTool) = try standIn("pg_dump", body: """
            for a in "$@"; do case "$a" in --file=*) out="${a#--file=}";; esac; done
            mkdir "$out"; printf 'x' > "$out/toc.dat"
            sleep 30
            """)
        defer { try? FileManager.default.removeItem(at: slowFolder) }
        var options = PostgresBackupOptions()
        options.format = .directory
        let folderDestination = slowFolder.appendingPathComponent("shop")
        let runner = BackupRunner(job: .postgresBackup(scope: .database, options: options, destination: folderDestination), connection: connection(.postgresql),
                                  tool: BackupToolCandidate(path: slowTool.path, version: candidate.version))
        let started = Date()
        let cancelled = runner.run { event in
            if case .outputSize(let size) = event, size > 0 { runner.cancel() }
        }
        #expect(cancelled.status == .cancelled)
        // Well before the stand-in's 30 seconds, with room for a loaded machine.
        #expect(Date().timeIntervalSince(started) < 20)
        #expect(!FileManager.default.fileExists(atPath: folderDestination.path))
        #expect(BackupTestTools.partials(next: folderDestination).isEmpty)
    }

    @Test func mysqldumpReadsTheOptionFileAndStreamsGzip() throws {
        let (folder, tool) = try standIn("mysqldump", body: """
            echo '-- Retrieving table structure for table items...' >&2
            printf -- '-- MySQL dump 10.13\\nCREATE TABLE items (id int);\\n'
            """)
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = MySQLBackupOptions()
        options.compress = true
        let destination = folder.appendingPathComponent("shop.sql.gz")
        let result = BackupRunner(job: .mysqlBackup(scope: .database, options: options, destination: destination), connection: connection(.mysql),
                                  tool: BackupToolCandidate(path: tool.path, version: BackupToolVersion(major: 8, minor: 4, flavor: .mysql))).run { _ in }
        #expect(result.status == .succeeded, "\(result.message ?? "")")
        #expect(BackupFileKind.detect(destination) == .plainSQL(compressed: true, dialect: .mysql))
        let arguments = read(folder, "args").split(separator: "\n").map(String.init)
        #expect(arguments.first?.hasPrefix("--defaults-extra-file=") == true)
        #expect(!arguments.joined().contains("pa:ss"))
        #expect(read(folder, "secret") == BackupCommandBuilder.mysqlOptionFileContents(password: password))
        #expect(read(folder, "mode").trimmingCharacters(in: .whitespacesAndNewlines) == "600")
        #expect(!FileManager.default.fileExists(atPath: read(folder, "path")))
        #expect(arguments.last == "shop")
    }

    @Test func scriptRestoresFeedTheFileOnStandardInput() throws {
        let (folder, tool) = try standIn("psql", body: "cat > \"$probe.stdin\"")
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("dump.sql.gz")
        let text = "--\n-- PostgreSQL database dump\n--\nCOPY public.t (id) FROM stdin;\n1\n\\.\n"
        try GzipEncoder().encode(Data(text.utf8), final: true).write(to: script)
        var progress: [Double] = []
        let result = BackupRunner(job: .scriptRestore(file: script, singleTransaction: true), connection: connection(.postgresql),
                                  tool: BackupToolCandidate(path: tool.path, version: BackupToolVersion(major: 17, flavor: .postgresql))).run { event in
            if case let .inputProgress(read, total) = event { progress.append(Double(read) / Double(max(total, 1))) }
        }
        #expect(result.status == .succeeded, "\(result.message ?? "")")
        #expect(read(folder, "stdin") == text)
        #expect(progress.last == 1)
        #expect(read(folder, "args").contains("--single-transaction\n--file=-"))
        #expect(result.command.hasSuffix("< " + ToolInvocation.shellQuoted(script.path)))
    }

    @Test(arguments: [13, 16, 17])
    func scriptsReachOlderServersWithoutTransactionTimeout(serverMajor: Int) throws {
        let (folder, tool) = try standIn("psql", body: "cat > \"$probe.stdin\"")
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("dump.sql")
        let header = "--\n-- PostgreSQL database dump\n--\n\nSET statement_timeout = 0;\nSET lock_timeout = 0;\nSET idle_in_transaction_session_timeout = 0;\n"
        let body = "SET client_encoding = 'UTF8';\nCREATE TABLE public.t (note text);\nINSERT INTO public.t VALUES ('SET transaction_timeout = 0;\n');\n"
        try Data((header + "SET transaction_timeout = 0;\n" + body).utf8).write(to: script)
        let result = BackupRunner(job: .scriptRestore(file: script, singleTransaction: false), connection: connection(.postgresql, serverMajor: serverMajor),
                                  tool: BackupToolCandidate(path: tool.path, version: BackupToolVersion(major: 18, flavor: .postgresql))).run { _ in }
        #expect(result.status == .succeeded, "\(result.message ?? "")")
        if serverMajor < 17 {
            // Only pg_dump's own line goes; the same text inside the data stays.
            #expect(read(folder, "stdin") == header + body)
            #expect(result.notes.contains { $0.contains("SET transaction_timeout was left out") })
        } else {
            #expect(read(folder, "stdin") == header + "SET transaction_timeout = 0;\n" + body)
            #expect(!result.notes.contains { $0.contains("transaction_timeout") })
        }
    }

    /// A stand-in pg_restore that reports errors the way pg_restore 17 and newer do against PostgreSQL 16 and older.
    private func failingRestore(otherError: Bool) throws -> (folder: URL, tool: URL) {
        let error = #"pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout""#
        return try standIn("pg_restore", body: """
            echo 'pg_restore: connecting to database for restore' >&2
            echo '\(error)' >&2
            echo 'Command was: SET transaction_timeout = 0;' >&2
            \(otherError ? "echo 'pg_restore: error: could not execute query: ERROR:  relation \"t\" already exists' >&2" : "")
            echo 'pg_restore: warning: errors ignored on restore: \(otherError ? 2 : 1)' >&2
            exit 1
            """)
    }

    @Test func pgRestoreThatOnlyMissedTransactionTimeoutSucceeds() throws {
        let (folder, tool) = try failingRestore(otherError: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("shop.dump")
        let candidate = BackupToolCandidate(path: tool.path, version: BackupToolVersion(major: 18, minor: 6, flavor: .postgresql))
        let result = BackupRunner(job: .postgresRestore(archive: archive, kind: .postgresCustom, options: PostgresRestoreOptions()), connection: connection(.postgresql, serverMajor: 13), tool: candidate).run { _ in }
        #expect(result.status == .succeeded, "\(result.message ?? "")")
        #expect(result.notes.contains("pg_restore 18.6 sets transaction_timeout, which this server does not have. Only that setting failed; everything else was restored."))

        // In one transaction pg_restore stops at that error, so nothing was restored.
        var single = PostgresRestoreOptions()
        single.singleTransaction = true
        let stopped = BackupRunner(job: .postgresRestore(archive: archive, kind: .postgresCustom, options: single), connection: connection(.postgresql, serverMajor: 13), tool: candidate).run { _ in }
        #expect(stopped.status == .failed)
        #expect(stopped.message?.contains("Turn off Single Transaction, or restore with pg_restore 16 or older") == true)
    }

    @Test func pgRestoreWithOtherErrorsStillFails() throws {
        let (folder, tool) = try failingRestore(otherError: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = BackupRunner(job: .postgresRestore(archive: folder.appendingPathComponent("shop.dump"), kind: .postgresCustom, options: PostgresRestoreOptions()),
                                  connection: connection(.postgresql, serverMajor: 13), tool: BackupToolCandidate(path: tool.path, version: BackupToolVersion(major: 18, flavor: .postgresql))).run { _ in }
        #expect(result.status == .failed)
        #expect(result.message?.contains(#"relation "t" already exists"#) == true)
    }
}

/// pg_dump and pg_restore 17 and newer set transaction_timeout, which PostgreSQL 16 and older do not have.
@Suite struct TransactionTimeoutCompatibilityTests {
    @Test func onlyOlderPostgreSQLServersSkipTheSetting() {
        #expect(BackupCompatibility.skipsTransactionTimeout(server: ServerVersion(major: 13)))
        #expect(BackupCompatibility.skipsTransactionTimeout(server: ServerVersion(major: 16, minor: 9)))
        #expect(!BackupCompatibility.skipsTransactionTimeout(server: ServerVersion(major: 17)))
        #expect(!BackupCompatibility.skipsTransactionTimeout(server: ServerVersion(major: 18)))
        #expect(!BackupCompatibility.skipsTransactionTimeout(server: nil))
        #expect(!BackupCompatibility.skipsTransactionTimeout(server: ServerVersion(major: 11, minor: 4, isMariaDB: true)))
    }

    @Test func recognizesTheSettingStatement() {
        for statement in ["SET transaction_timeout = 0;", "SET transaction_timeout = 0", "set Transaction_Timeout=0;", "SET transaction_timeout TO '5s'", "  SET SESSION transaction_timeout = 0;\n"] {
            #expect(BackupCompatibility.isTransactionTimeoutSetting(statement), "\(statement)")
        }
        for statement in ["SET statement_timeout = 0;", "SET transaction_timeout_extra = 0;", "SET transaction_timeout = 0; DROP TABLE t;", "SELECT 'SET transaction_timeout = 0;'"] {
            #expect(!BackupCompatibility.isTransactionTimeoutSetting(statement), "\(statement)")
        }
    }

    @Test func filterRemovesTheLineEvenAcrossChunks() {
        let script = Array("SET lock_timeout = 0;\nSET transaction_timeout = 0;\nSELECT 1;\n".utf8)
        var filter = TransactionTimeoutFilter()
        var out: [UInt8] = []
        var index = 0
        while index < script.count {
            out += filter.filter(Array(script[index..<min(index + 7, script.count)]), final: false)
            index += 7
        }
        out += filter.filter([], final: true)
        #expect(String(decoding: out, as: UTF8.self) == "SET lock_timeout = 0;\nSELECT 1;\n")
        #expect(filter.removed)
    }

    @Test func filterLeavesEverythingElseAlone() {
        // Not at the start of a line, and past the header window.
        let quoted = Array("-- SET transaction_timeout = 0;\nSELECT 1;\n".utf8)
        var first = TransactionTimeoutFilter()
        #expect(first.filter(quoted, final: true) == quoted)
        #expect(!first.removed)
        let late = Array((String(repeating: "-- padding\n", count: 1000) + "SET transaction_timeout = 0;\n").utf8)
        var second = TransactionTimeoutFilter()
        let passed = second.filter(late, final: false) + second.filter(Array("SELECT 2;\n".utf8), final: true)
        #expect(passed == late + Array("SELECT 2;\n".utf8))
        #expect(!second.removed)
    }
}

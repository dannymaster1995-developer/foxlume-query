import Foundation

/// Where and as whom a tool connects: the connection's settings after any SSH tunnel, with TLS files resolved to
/// paths the tool can read (see `BackupTLSFiles`).
public struct BackupEndpoint: Hashable, Sendable {
    /// What the tool dials: the server, or 127.0.0.1 behind an SSH tunnel.
    public var host: String
    public var port: Int
    /// The real server name when `host` is a tunnel's local end, for TLS host name checks.
    public var tunnelledHost: String?
    public var user: String
    public var database: String
    public var sslMode: SSLMode
    public var caPath: String?
    public var certificatePath: String?
    public var keyPath: String?

    public init(host: String, port: Int, tunnelledHost: String? = nil, user: String, database: String, sslMode: SSLMode, caPath: String? = nil, certificatePath: String? = nil, keyPath: String? = nil) {
        self.host = host
        self.port = port
        self.tunnelledHost = tunnelledHost
        self.user = user
        self.database = database
        self.sslMode = sslMode
        self.caPath = caPath
        self.certificatePath = certificatePath
        self.keyPath = keyPath
    }
}

/// A file only the tool may read, written with permissions 0600 before it starts and deleted when it ends.
public struct BackupSecretFile: Hashable, Sendable {
    public var path: String
    public var contents: String
    /// What the file stands for in the command shown to the user, such as "<password file>".
    public var label: String

    public init(path: String, contents: String, label: String) {
        self.path = path
        self.contents = contents
        self.label = label
    }
}

/// One run of a tool: what to start and with what. Passwords are never in `arguments`; they go into `secretFiles`.
public struct ToolInvocation: Hashable, Sendable {
    public var executable: String
    public var arguments: [String]
    /// Variables set for the tool on top of the app's environment (from which PG* and MYSQL_* are removed).
    public var environment: [String: String]
    public var secretFiles: [BackupSecretFile]
    /// Things the user should know about how the connection settings were mapped.
    public var notes: [String]

    public init(executable: String, arguments: [String], environment: [String: String] = [:], secretFiles: [BackupSecretFile] = [], notes: [String] = []) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.secretFiles = secretFiles
        self.notes = notes
    }

    /// The command as a shell would take it, with secret files shown by their label and `replacements` applied
    /// to arguments (the partial output path shown as the final one).
    public func displayCommand(replacing replacements: [String: String] = [:]) -> String {
        // Secret paths become plain tokens before quoting and their labels afterwards, so a label stays readable.
        let tokens = secretFiles.enumerated().map { ("FOXLUMESECRET\($0.offset)X", $0.element) }
        func shown(_ text: String) -> String {
            var text = text
            for (original, replacement) in replacements { text = text.replacingOccurrences(of: original, with: replacement) }
            for (token, file) in tokens { text = text.replacingOccurrences(of: file.path, with: token) }
            text = Self.shellQuoted(text)
            for (token, file) in tokens { text = text.replacingOccurrences(of: token, with: file.label) }
            return text
        }
        let variables = environment.keys.sorted().map { "\($0)=\(shown(environment[$0] ?? ""))" }
        let words = [Self.shellQuoted(executable)] + arguments.map(shown)
        return (variables + words).joined(separator: " ")
    }

    /// Single-quotes `text` for a POSIX shell when it holds anything but plain characters.
    static func shellQuoted(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@,+%")
        if !text.isEmpty, text.unicodeScalars.allSatisfy({ plain.contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Builds the command lines of pg_dump, pg_restore, psql, mysqldump / mariadb-dump and mysql from a connection's
/// settings. Pure: the caller starts the SSH tunnel, resolves the TLS files and writes the secret files.
public enum BackupCommandBuilder {
    public static let passwordFileLabel = "<password file>"

    // MARK: PostgreSQL

    /// libpq connection string for `--dbname`: everything but the password, which goes into a passfile.
    /// Behind a tunnel `host` names the real server (for verify-full) and `hostaddr` the tunnel's local end.
    public static func postgresConnectionString(_ endpoint: BackupEndpoint, tool: BackupToolVersion?) -> String {
        var pairs: [(String, String)] = []
        if let real = endpoint.tunnelledHost {
            pairs.append(("host", real))
            pairs.append(("hostaddr", endpoint.host))
        } else {
            pairs.append(("host", endpoint.host))
        }
        pairs.append(("port", String(endpoint.port)))
        if !endpoint.user.isEmpty { pairs.append(("user", endpoint.user)) }
        if !endpoint.database.isEmpty { pairs.append(("dbname", endpoint.database)) }
        pairs.append(("sslmode", endpoint.sslMode.libpqName))
        if endpoint.sslMode.wantsTLS {
            if let ca = endpoint.caPath, !ca.isEmpty {
                pairs.append(("sslrootcert", ca))
            } else if endpoint.sslMode.verifiesCertificate, (tool?.major ?? 0) >= 16 {
                // Without a CA file the app trusts the system store; libpq 16 can do the same.
                pairs.append(("sslrootcert", "system"))
            }
            if let certificate = endpoint.certificatePath, !certificate.isEmpty { pairs.append(("sslcert", certificate)) }
            if let key = endpoint.keyPath, !key.isEmpty { pairs.append(("sslkey", key)) }
        }
        return pairs.map { "\($0.0)=\(conninfoQuoted($0.1))" }.joined(separator: " ")
    }

    /// A conninfo value: quoted when empty or holding spaces, quotes or backslashes.
    static func conninfoQuoted(_ value: String) -> String {
        if !value.isEmpty, !value.contains(where: { $0 == " " || $0 == "'" || $0 == "\\" || $0.isNewline || $0 == "\t" }) { return value }
        return "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// A one-line passfile matching every host, port, database and user. `:` and `\` are escaped.
    public static func pgpassContents(password: String) -> String {
        "*:*:*:*:" + password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:") + "\n"
    }

    /// The passfile and the variable that points libpq at it; none for an empty password (libpq then reads the
    /// user's own ~/.pgpass, if any).
    static func postgresSecrets(password: String, secretDirectory: URL) -> (environment: [String: String], files: [BackupSecretFile]) {
        guard !password.isEmpty else { return ([:], []) }
        let path = secretDirectory.appendingPathComponent("pgpass").path
        return (["PGPASSFILE": path], [BackupSecretFile(path: path, contents: pgpassContents(password: password), label: passwordFileLabel)])
    }

    /// A pg_dump name pattern that matches `name` literally (double quotes stop wildcard and case folding).
    static func pgPattern(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func pgDump(
        tool: BackupToolCandidate,
        endpoint: BackupEndpoint,
        scope: BackupScope,
        options: PostgresBackupOptions,
        output: String,
        password: String,
        secretDirectory: URL
    ) -> ToolInvocation {
        var arguments = [
            "--dbname=" + postgresConnectionString(endpoint, tool: tool.version),
            "--no-password",
            "--verbose",
            "--format=" + options.format.flag,
            "--file=" + output,
        ]
        switch options.format {
        case .custom, .directory:
            arguments.append("--compress=\(min(9, max(0, options.compressionLevel)))")
        case .plain:
            if options.compressPlain { arguments.append("--compress=6") }
        case .tar:
            break
        }
        if options.format == .directory, options.jobs > 1 { arguments.append("--jobs=\(options.jobs)") }
        switch options.content {
        case .schemaAndData: break
        case .schemaOnly: arguments.append("--schema-only")
        case .dataOnly: arguments.append("--data-only")
        }
        if options.noOwner { arguments.append("--no-owner") }
        if options.noPrivileges { arguments.append("--no-privileges") }
        if options.format == .plain {
            // Run SQL File reads UTF-8.
            arguments.append("--encoding=UTF8")
            if options.clean {
                arguments.append("--clean")
                if options.ifExists { arguments.append("--if-exists") }
            }
            if options.useInserts, options.content != .schemaOnly {
                arguments.append((tool.version?.major ?? 12) >= 12 ? "--rows-per-insert=1000" : "--inserts")
            }
        }
        switch scope {
        case .database: break
        case .schemas(let schemas): arguments += schemas.map { "--schema=" + pgPattern($0) }
        case .tables(let tables): arguments += tables.map { "--table=" + ($0.schema.map { pgPattern($0) + "." } ?? "") + pgPattern($0.name) }
        }
        let secrets = postgresSecrets(password: password, secretDirectory: secretDirectory)
        return ToolInvocation(executable: tool.path, arguments: arguments, environment: secrets.environment, secretFiles: secrets.files, notes: postgresNotes(endpoint, tool: tool.version))
    }

    public static func pgRestore(
        tool: BackupToolCandidate,
        endpoint: BackupEndpoint,
        archive: String,
        archiveIsTar: Bool,
        options: PostgresRestoreOptions,
        password: String,
        secretDirectory: URL
    ) -> ToolInvocation {
        var arguments = [
            "--dbname=" + postgresConnectionString(endpoint, tool: tool.version),
            "--no-password",
            "--verbose",
        ]
        if options.clean {
            arguments.append("--clean")
            if options.ifExists { arguments.append("--if-exists") }
        }
        if options.noOwner { arguments.append("--no-owner") }
        if options.singleTransaction {
            arguments.append("--single-transaction")
        } else if options.jobs > 1, !archiveIsTar {
            arguments.append("--jobs=\(options.jobs)")
        }
        arguments.append(archive)
        let secrets = postgresSecrets(password: password, secretDirectory: secretDirectory)
        return ToolInvocation(executable: tool.path, arguments: arguments, environment: secrets.environment, secretFiles: secrets.files, notes: postgresNotes(endpoint, tool: tool.version))
    }

    /// psql running a plain SQL script from standard input, stopping at the first error.
    public static func psqlScript(tool: BackupToolCandidate, endpoint: BackupEndpoint, singleTransaction: Bool, password: String, secretDirectory: URL) -> ToolInvocation {
        var arguments = [
            "--dbname=" + postgresConnectionString(endpoint, tool: tool.version),
            "--no-password",
            "--no-psqlrc",
            "--set=ON_ERROR_STOP=1",
            "--echo-errors",
        ]
        if singleTransaction { arguments.append("--single-transaction") }
        arguments.append("--file=-")
        let secrets = postgresSecrets(password: password, secretDirectory: secretDirectory)
        return ToolInvocation(executable: tool.path, arguments: arguments, environment: secrets.environment, secretFiles: secrets.files, notes: postgresNotes(endpoint, tool: tool.version))
    }

    private static func postgresNotes(_ endpoint: BackupEndpoint, tool: BackupToolVersion?) -> [String] {
        guard endpoint.sslMode.verifiesCertificate, endpoint.caPath?.isEmpty ?? true, (tool?.major ?? 0) < 16 else { return [] }
        return ["No CA file is set and this libpq is older than 16, so it checks the server certificate against ~/.postgresql/root.crt instead of the system trust store."]
    }

    // MARK: MySQL and MariaDB

    /// An option file with the password, for `--defaults-extra-file`. The value is double-quoted with `\` and `"`
    /// (and control characters) escaped, as the MySQL and MariaDB option file parsers expect.
    public static func mysqlOptionFileContents(password: String) -> String {
        var escaped = ""
        for character in password {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\u{8}": escaped += "\\b"
            default: escaped.append(character)
            }
        }
        return "[client]\npassword=\"\(escaped)\"\n"
    }

    /// `--defaults-extra-file` must be the first argument.
    static func mysqlSecrets(password: String, secretDirectory: URL) -> (arguments: [String], files: [BackupSecretFile]) {
        guard !password.isEmpty else { return ([], []) }
        let path = secretDirectory.appendingPathComponent("client.cnf").path
        return (["--defaults-extra-file=" + path], [BackupSecretFile(path: path, contents: mysqlOptionFileContents(password: password), label: passwordFileLabel)])
    }

    /// Host, port, user and TLS options. MySQL's tools take `--ssl-mode`; MariaDB's take `--ssl` and
    /// `--ssl-verify-server-cert` (which checks the host name too, so Verify CA verifies the identity as well).
    static func mysqlConnectionArguments(_ endpoint: BackupEndpoint, tool: BackupToolVersion?) -> (arguments: [String], notes: [String]) {
        var arguments = ["--protocol=TCP", "--host=" + endpoint.host, "--port=\(endpoint.port)"]
        if !endpoint.user.isEmpty { arguments.append("--user=" + endpoint.user) }
        var notes: [String] = []
        let mode = endpoint.sslMode
        if tool?.flavor == .mariadb {
            switch mode {
            case .disable: arguments.append("--skip-ssl")
            case .prefer: arguments.append("--skip-ssl-verify-server-cert")
            case .require: arguments += ["--ssl", "--skip-ssl-verify-server-cert"]
            case .verifyCA, .verifyFull:
                arguments += ["--ssl", "--ssl-verify-server-cert"]
                if mode == .verifyCA { notes.append("MariaDB's dump tool has no Verify CA mode; it verifies the host name as well.") }
                if endpoint.tunnelledHost != nil { notes.append("Behind the SSH tunnel the host name checked is 127.0.0.1, which the server certificate may not name.") }
            }
        } else {
            var sslMode: String
            switch mode {
            case .disable: sslMode = "DISABLED"
            case .prefer: sslMode = "PREFERRED"
            case .require: sslMode = "REQUIRED"
            case .verifyCA: sslMode = "VERIFY_CA"
            case .verifyFull: sslMode = "VERIFY_IDENTITY"
            }
            if mode == .verifyFull, endpoint.tunnelledHost != nil {
                // mysqldump has no way to name the real host while dialing the tunnel's local end.
                sslMode = "VERIFY_CA"
                notes.append("Behind the SSH tunnel mysqldump verifies the server certificate's CA but not its host name.")
            }
            arguments.append("--ssl-mode=" + sslMode)
        }
        if mode.wantsTLS {
            if let ca = endpoint.caPath, !ca.isEmpty { arguments.append("--ssl-ca=" + ca) }
            if let certificate = endpoint.certificatePath, !certificate.isEmpty { arguments.append("--ssl-cert=" + certificate) }
            if let key = endpoint.keyPath, !key.isEmpty { arguments.append("--ssl-key=" + key) }
        }
        return (arguments, notes)
    }

    /// mysqldump or mariadb-dump writing the dump to standard output.
    public static func mysqldump(
        tool: BackupToolCandidate,
        endpoint: BackupEndpoint,
        server: ServerVersion?,
        scope: BackupScope,
        options: MySQLBackupOptions,
        password: String,
        secretDirectory: URL
    ) -> ToolInvocation {
        let secrets = mysqlSecrets(password: password, secretDirectory: secretDirectory)
        let connection = mysqlConnectionArguments(endpoint, tool: tool.version)
        var arguments = secrets.arguments + connection.arguments
        arguments += [
            "--verbose",
            "--default-character-set=utf8mb4",
            // Binary values as hex literals keep the dump valid UTF-8 for Run SQL File.
            "--hex-blob",
            // Tablespaces need the PROCESS privilege since MySQL 8.0.21 and rarely belong in a dump.
            "--no-tablespaces",
        ]
        let isMySQLTool = tool.version?.flavor != .mariadb
        if isMySQLTool {
            // GTID_PURGED statements fail on restore into a server with GTIDs of its own.
            arguments.append("--set-gtid-purged=OFF")
            // MySQL 8's tool reads column statistics that MariaDB and older MySQL servers do not have.
            if (tool.version?.major ?? 8) >= 8, let server, server.isMariaDB || server.major < 8 {
                arguments.append("--column-statistics=0")
            }
        }
        arguments.append(options.singleTransaction ? "--single-transaction" : "--lock-tables")
        let withObjects = options.content != .dataOnly
        arguments.append(options.routines && withObjects ? "--routines" : "--skip-routines")
        arguments.append(options.triggers && withObjects ? "--triggers" : "--skip-triggers")
        arguments.append(options.events && withObjects ? "--events" : "--skip-events")
        switch options.content {
        case .schemaAndData: break
        case .schemaOnly: arguments.append("--no-data")
        case .dataOnly: arguments.append("--no-create-info")
        }
        if options.content != .dataOnly { arguments.append(options.addDropTable ? "--add-drop-table" : "--skip-add-drop-table") }
        switch scope {
        case .database:
            arguments.append(endpoint.database)
        case .schemas(let databases):
            arguments.append("--databases")
            arguments += databases
        case .tables(let tables):
            arguments.append(endpoint.database)
            arguments += tables.map(\.name)
        }
        var notes = connection.notes
        if let note = BackupCompatibility.mysqlFlavorNote(tool: tool.version, serverIsMariaDB: server?.isMariaDB ?? false) { notes.append(note) }
        return ToolInvocation(executable: tool.path, arguments: arguments, secretFiles: secrets.files, notes: notes)
    }

    /// The mysql (or mariadb) client running a script from standard input into `endpoint.database`.
    public static func mysqlScript(tool: BackupToolCandidate, endpoint: BackupEndpoint, password: String, secretDirectory: URL) -> ToolInvocation {
        let secrets = mysqlSecrets(password: password, secretDirectory: secretDirectory)
        let connection = mysqlConnectionArguments(endpoint, tool: tool.version)
        var arguments = secrets.arguments + connection.arguments
        arguments += ["--default-character-set=utf8mb4", "--show-warnings"]
        if !endpoint.database.isEmpty { arguments.append("--database=" + endpoint.database) }
        return ToolInvocation(executable: tool.path, arguments: arguments, secretFiles: secrets.files, notes: connection.notes)
    }
}

import Foundation

/// pg_dump's output formats.
public enum PostgresBackupFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    /// pg_dump's compressed archive (`.dump`), restored with pg_restore; the default.
    case custom
    /// A SQL script (`.sql`, or `.sql.gz` when compressed).
    case plain
    /// A folder with one file per table, written in parallel with jobs.
    case directory
    /// A tar archive of the directory format.
    case tar

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .custom: return "Custom (.dump)"
        case .plain: return "Plain SQL (.sql)"
        case .directory: return "Directory"
        case .tar: return "Tar (.tar)"
        }
    }

    /// pg_dump's `--format` value.
    var flag: String { rawValue }

    /// Whether the output is a folder rather than a file.
    public var isDirectory: Bool { self == .directory }
}

/// What a backup contains.
public enum BackupContent: String, Codable, CaseIterable, Sendable, Identifiable {
    case schemaAndData
    case schemaOnly
    case dataOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .schemaAndData: return "Schema and data"
        case .schemaOnly: return "Schema only"
        case .dataOnly: return "Data only"
        }
    }
}

/// Options of a PostgreSQL backup with pg_dump. Codable so the sheet can remember the last choices.
public struct PostgresBackupOptions: Codable, Hashable, Sendable {
    public var format: PostgresBackupFormat = .custom
    public var content: BackupContent = .schemaAndData
    /// `--no-owner`: no ALTER … OWNER, so a restore makes the restoring user the owner.
    public var noOwner = false
    /// `--no-privileges`: no GRANT / REVOKE.
    public var noPrivileges = false
    /// Plain format: DROP statements before each CREATE (`--clean`).
    public var clean = false
    /// Plain format with clean: `DROP … IF EXISTS` (`--if-exists`).
    public var ifExists = true
    /// Custom and directory formats: compression level 0 (none) to 9.
    public var compressionLevel = 6
    /// Plain format: gzip the script (`.sql.gz`).
    public var compressPlain = false
    /// Plain format: INSERT statements instead of COPY … FROM stdin, so Run SQL File can restore the script without
    /// psql (`--rows-per-insert`, or `--inserts` before pg_dump 12).
    public var useInserts = true
    /// Directory format: tables dumped in parallel (`--jobs`).
    public var jobs = 1

    public init() {}

    public init(from decoder: Decoder) throws {
        // Missing keys keep their defaults, so saved choices from older versions still load.
        let defaults = PostgresBackupOptions()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? container.decode(PostgresBackupFormat.self, forKey: .format)) ?? defaults.format
        content = (try? container.decode(BackupContent.self, forKey: .content)) ?? defaults.content
        noOwner = (try? container.decode(Bool.self, forKey: .noOwner)) ?? defaults.noOwner
        noPrivileges = (try? container.decode(Bool.self, forKey: .noPrivileges)) ?? defaults.noPrivileges
        clean = (try? container.decode(Bool.self, forKey: .clean)) ?? defaults.clean
        ifExists = (try? container.decode(Bool.self, forKey: .ifExists)) ?? defaults.ifExists
        compressionLevel = (try? container.decode(Int.self, forKey: .compressionLevel)) ?? defaults.compressionLevel
        compressPlain = (try? container.decode(Bool.self, forKey: .compressPlain)) ?? defaults.compressPlain
        useInserts = (try? container.decode(Bool.self, forKey: .useInserts)) ?? defaults.useInserts
        jobs = (try? container.decode(Int.self, forKey: .jobs)) ?? defaults.jobs
    }

    /// The file name extension for the output.
    public var fileExtension: String {
        switch format {
        case .custom: return "dump"
        case .plain: return compressPlain ? "sql.gz" : "sql"
        case .directory: return ""
        case .tar: return "tar"
        }
    }
}

/// Options of a MySQL or MariaDB backup with mysqldump or mariadb-dump.
public struct MySQLBackupOptions: Codable, Hashable, Sendable {
    /// `--single-transaction`: a consistent InnoDB snapshot without locking tables.
    public var singleTransaction = true
    /// Stored procedures and functions (`--routines`).
    public var routines = true
    public var triggers = true
    /// Scheduled events (`--events`).
    public var events = false
    public var content: BackupContent = .schemaAndData
    /// `DROP TABLE IF EXISTS` before each CREATE TABLE (`--add-drop-table`).
    public var addDropTable = true
    /// gzip the output (`.sql.gz`).
    public var compress = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let defaults = MySQLBackupOptions()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        singleTransaction = (try? container.decode(Bool.self, forKey: .singleTransaction)) ?? defaults.singleTransaction
        routines = (try? container.decode(Bool.self, forKey: .routines)) ?? defaults.routines
        triggers = (try? container.decode(Bool.self, forKey: .triggers)) ?? defaults.triggers
        events = (try? container.decode(Bool.self, forKey: .events)) ?? defaults.events
        content = (try? container.decode(BackupContent.self, forKey: .content)) ?? defaults.content
        addDropTable = (try? container.decode(Bool.self, forKey: .addDropTable)) ?? defaults.addDropTable
        compress = (try? container.decode(Bool.self, forKey: .compress)) ?? defaults.compress
    }

    public var fileExtension: String { compress ? "sql.gz" : "sql" }
}

/// Options of a pg_restore run.
public struct PostgresRestoreOptions: Codable, Hashable, Sendable {
    /// Drop each object before creating it (`--clean`), with `IF EXISTS` (`--if-exists`).
    public var clean = false
    public var ifExists = true
    /// `--no-owner`: objects belong to the restoring user.
    public var noOwner = false
    /// `--single-transaction`: everything or nothing; stops at the first error.
    public var singleTransaction = false
    /// Parallel jobs (`--jobs`); custom and directory archives only, and not with a single transaction.
    public var jobs = 1

    public init() {}

    public init(from decoder: Decoder) throws {
        let defaults = PostgresRestoreOptions()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clean = (try? container.decode(Bool.self, forKey: .clean)) ?? defaults.clean
        ifExists = (try? container.decode(Bool.self, forKey: .ifExists)) ?? defaults.ifExists
        noOwner = (try? container.decode(Bool.self, forKey: .noOwner)) ?? defaults.noOwner
        singleTransaction = (try? container.decode(Bool.self, forKey: .singleTransaction)) ?? defaults.singleTransaction
        jobs = (try? container.decode(Int.self, forKey: .jobs)) ?? defaults.jobs
    }
}

/// What a backup covers.
public enum BackupScope: Hashable, Sendable {
    /// The whole database the connection uses.
    case database
    /// PostgreSQL schemas of the database; on MySQL and MariaDB, databases (each with CREATE DATABASE and USE).
    case schemas([String])
    case tables([TableRef])
}

/// The last choices of the Backup and Restore sheets, kept in the data folder next to the transfer options.
public struct BackupPreferences: Codable, Equatable, Sendable {
    public var postgres = PostgresBackupOptions()
    public var mysql = MySQLBackupOptions()
    public var restore = PostgresRestoreOptions()
    /// The folder of the last backup.
    public var lastFolder: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        postgres = (try? container.decode(PostgresBackupOptions.self, forKey: .postgres)) ?? PostgresBackupOptions()
        mysql = (try? container.decode(MySQLBackupOptions.self, forKey: .mysql)) ?? MySQLBackupOptions()
        restore = (try? container.decode(PostgresRestoreOptions.self, forKey: .restore)) ?? PostgresRestoreOptions()
        lastFolder = try? container.decode(String.self, forKey: .lastFolder)
    }

    public static var fileURL: URL { AppPaths.dataDirectory.appendingPathComponent("backup-options.json") }

    public static func load() -> BackupPreferences {
        JSONFile.read(BackupPreferences.self, from: fileURL) ?? BackupPreferences()
    }

    public func save() {
        try? JSONFile.write(self, to: Self.fileURL)
    }
}

/// A server version as the session reports it ("16.4", "8.4.9", "11.4.2-MariaDB-log").
public struct ServerVersion: Hashable, Sendable {
    public var major: Int
    public var minor: Int
    public var isMariaDB: Bool

    public init(major: Int, minor: Int = 0, isMariaDB: Bool = false) {
        self.major = major
        self.minor = minor
        self.isMariaDB = isMariaDB
    }

    public static func parse(_ text: String) -> ServerVersion? {
        var version = text
        // MariaDB behind the MySQL 5.5 compatibility prefix.
        if version.hasPrefix("5.5.5-"), version.dropFirst(6).first?.isNumber == true { version = String(version.dropFirst(6)) }
        guard let start = version.firstIndex(where: \.isNumber) else { return nil }
        let parts = version[start...].prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return nil }
        return ServerVersion(major: major, minor: parts.count > 1 ? parts[1] : 0, isMariaDB: text.range(of: "MariaDB", options: .caseInsensitive) != nil)
    }
}

public enum BackupCompatibility {
    /// A warning when pg_dump is older than the server: pg_dump refuses to back up a newer major version. Nil when
    /// the versions fit or either is unknown.
    public static func pgDumpWarning(tool: BackupToolVersion?, server: ServerVersion?, path: String) -> String? {
        guard let tool, let server, tool.flavor == .postgresql, tool.major < server.major else { return nil }
        return "\(path) is version \(tool), older than the server (PostgreSQL \(server.major)). pg_dump cannot back up a newer server; install pg_dump \(server.major) or later (brew install libpq, or Postgres.app) or choose a newer copy in Settings › Backup Tools."
    }

    /// pg_dump and pg_restore 17 and newer start every script and every restore with `SET transaction_timeout = 0`,
    /// which PostgreSQL 16 and older reject ("unrecognized configuration parameter"), even for a backup of that same
    /// server. True when that setting has to be left out for this server.
    public static func skipsTransactionTimeout(server: ServerVersion?) -> Bool {
        guard let server, !server.isMariaDB else { return false }
        return server.major < 17
    }

    /// Whether a statement only sets transaction_timeout, as pg_dump scripts do.
    public static func isTransactionTimeoutSetting(_ statement: String) -> Bool {
        statement.range(of: #"^\s*SET\s+(SESSION\s+)?transaction_timeout\s*(=|TO\b)[^;]*;?\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// pg_restore's report of the setting failing on an older server.
    static let transactionTimeoutError = #"unrecognized configuration parameter "transaction_timeout""#

    /// The note or hint after pg_restore met a server without transaction_timeout.
    static func transactionTimeoutNote(tool: BackupToolVersion?, failed: Bool) -> String {
        let name = tool.map { "pg_restore \($0)" } ?? "This pg_restore"
        if failed {
            return "\(name) sets transaction_timeout, which this server does not have, so a single-transaction restore stops at once. Turn off Single Transaction, or restore with pg_restore 16 or older."
        }
        return "\(name) sets transaction_timeout, which this server does not have. Only that setting failed; everything else was restored."
    }

    /// A note when the dump tool's flavor differs from the server's (mysqldump against MariaDB or the reverse),
    /// which mostly works but can miss engine-specific features.
    public static func mysqlFlavorNote(tool: BackupToolVersion?, serverIsMariaDB: Bool) -> String? {
        guard let tool, tool.flavor != .postgresql else { return nil }
        if serverIsMariaDB, tool.flavor == .mysql {
            return "MySQL's mysqldump is backing up a MariaDB server. If something is missing, install MariaDB's mariadb-dump (brew install mariadb)."
        }
        if !serverIsMariaDB, tool.flavor == .mariadb {
            return "MariaDB's dump tool is backing up a MySQL server. If something is missing, install MySQL's mysqldump (brew install mysql-client)."
        }
        return nil
    }
}

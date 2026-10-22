import Foundation

/// The command-line programs Backup and Restore run. Foxlume Query ships none of them: they come from the user's
/// PostgreSQL or MySQL client installation (Homebrew, Postgres.app, the official installers).
public enum BackupTool: String, CaseIterable, Codable, Sendable, Identifiable {
    case pgDump = "pg_dump"
    case pgRestore = "pg_restore"
    /// Optional: restores plain SQL dumps that Run SQL File cannot run (COPY … FROM stdin).
    case psql
    /// `mysqldump`, or MariaDB's `mariadb-dump`.
    case mysqldump
    /// Optional: the `mysql` (or `mariadb`) client, an alternative to Run SQL File for plain dumps.
    case mysql

    public var id: String { rawValue }

    /// File names to look for, preferred first.
    public var executableNames: [String] {
        switch self {
        case .pgDump: return ["pg_dump"]
        case .pgRestore: return ["pg_restore"]
        case .psql: return ["psql"]
        case .mysqldump: return ["mysqldump", "mariadb-dump"]
        case .mysql: return ["mysql", "mariadb"]
        }
    }

    public var isPostgres: Bool { self == .pgDump || self == .pgRestore || self == .psql }

    /// Tools Backup and Restore can work without.
    public var isOptional: Bool { self == .psql || self == .mysql }

    public var title: String {
        switch self {
        case .pgDump, .pgRestore, .psql: return rawValue
        case .mysqldump: return "mysqldump / mariadb-dump"
        case .mysql: return "mysql / mariadb"
        }
    }

    /// What the tool is used for, for Settings.
    public var purpose: String {
        switch self {
        case .pgDump: return "PostgreSQL backups"
        case .pgRestore: return "Restoring PostgreSQL custom, directory and tar backups"
        case .psql: return "Optional: restoring plain PostgreSQL dumps that load data with COPY"
        case .mysqldump: return "MySQL and MariaDB backups"
        case .mysql: return "Optional: restoring plain MySQL dumps with the mysql client"
        }
    }

    /// How to get the tool, for the missing-tool message.
    public var installHint: String {
        if isPostgres {
            return "Install the PostgreSQL client tools with Homebrew (brew install libpq, or brew install postgresql@17) or install Postgres.app (postgresapp.com), then try again. You can also choose the program in Settings › Backup Tools."
        }
        return "Install the MySQL client tools with Homebrew (brew install mysql-client, or brew install mariadb for MariaDB servers), then try again. You can also choose the program in Settings › Backup Tools."
    }
}

/// Which client a tool belongs to; MariaDB's dump tool takes different TLS options than MySQL's.
public enum BackupToolFlavor: String, Codable, Sendable {
    case postgresql
    case mysql
    case mariadb
}

/// A tool's version, read from its `--version` output.
public struct BackupToolVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var flavor: BackupToolFlavor

    public init(major: Int, minor: Int = 0, patch: Int = 0, flavor: BackupToolFlavor) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.flavor = flavor
    }

    public static func < (lhs: BackupToolVersion, rhs: BackupToolVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// "16.4", "8.4.9", "MariaDB 11.4.2".
    public var description: String {
        let number = flavor == .postgresql && patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
        return flavor == .mariadb ? "MariaDB \(number)" : number
    }

    /// Parses the first line a tool prints for `--version`:
    ///
    ///     pg_dump (PostgreSQL) 16.4 (Homebrew)
    ///     pg_restore (PostgreSQL) 18beta1
    ///     mysqldump  Ver 8.4.9 for macos15 on arm64 (MySQL Community Server - GPL)
    ///     mysqldump  Ver 10.13 Distrib 5.7.44, for osx10.19 (x86_64)
    ///     mysqldump  Ver 10.19 Distrib 10.11.6-MariaDB, for osx10.19 (arm64)
    ///     mariadb-dump from 11.4.2-MariaDB, client 10.19 for osx10.20 (arm64)
    public static func parse(_ output: String) -> BackupToolVersion? {
        guard let line = output.split(whereSeparator: \.isNewline).first.map(String.init) else { return nil }
        if line.contains("(PostgreSQL)") {
            guard let range = line.range(of: "(PostgreSQL)") else { return nil }
            return numbers(in: line[range.upperBound...]).map { BackupToolVersion(major: $0[0], minor: $0.count > 1 ? $0[1] : 0, patch: 0, flavor: .postgresql) }
        }
        if let mariadb = line.range(of: "-MariaDB") {
            // The server version is the number right before "-MariaDB".
            let before = line[..<mariadb.lowerBound]
            let start = before.lastIndex { !($0.isNumber || $0 == ".") }.map { before.index(after: $0) } ?? before.startIndex
            return numbers(in: before[start...]).map { version(from: $0, flavor: .mariadb) }
        }
        if let distrib = line.range(of: "Distrib ") {
            return numbers(in: line[distrib.upperBound...]).map { version(from: $0, flavor: .mysql) }
        }
        if let ver = line.range(of: "Ver ") {
            return numbers(in: line[ver.upperBound...]).map { version(from: $0, flavor: .mysql) }
        }
        return nil
    }

    private static func version(from parts: [Int], flavor: BackupToolFlavor) -> BackupToolVersion {
        BackupToolVersion(major: parts[0], minor: parts.count > 1 ? parts[1] : 0, patch: parts.count > 2 ? parts[2] : 0, flavor: flavor)
    }

    /// The first run of dot-separated numbers in `text`, such as [16, 4] from " 16.4 (Homebrew)" or [18] from "18beta1".
    private static func numbers(in text: Substring) -> [Int]? {
        guard let start = text.firstIndex(where: \.isNumber) else { return nil }
        let run = text[start...].prefix { $0.isNumber || $0 == "." }
        let parts = run.split(separator: ".").compactMap { Int($0) }
        return parts.isEmpty ? nil : Array(parts.prefix(3))
    }
}

/// One copy of a tool found on disk.
public struct BackupToolCandidate: Hashable, Sendable {
    public var path: String
    public var version: BackupToolVersion?

    public init(path: String, version: BackupToolVersion?) {
        self.path = path
        self.version = version
    }
}

/// What a search for a tool found: the copy to use and every other copy, with where it looked.
public struct BackupToolSearch: Sendable {
    public var tool: BackupTool
    /// The copy to use: the override from Settings when one is set, else the best copy found.
    public var chosen: BackupToolCandidate?
    /// True when `chosen` is the path from Settings.
    public var isOverride: Bool
    public var candidates: [BackupToolCandidate]
    public var searchedDirectories: [String]

    public init(tool: BackupTool, chosen: BackupToolCandidate?, isOverride: Bool, candidates: [BackupToolCandidate], searchedDirectories: [String]) {
        self.tool = tool
        self.chosen = chosen
        self.isOverride = isOverride
        self.candidates = candidates
        self.searchedDirectories = searchedDirectories
    }

    /// The error to show when nothing usable was found.
    public var missingError: BackupError {
        .toolMissing(tool: tool, searched: searchedDirectories)
    }
}

/// Errors of Backup and Restore, with messages that say what to do.
public enum BackupError: Error, LocalizedError, Equatable {
    case toolMissing(tool: BackupTool, searched: [String])
    case toolNotRunnable(path: String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case let .toolMissing(tool, searched):
            let names = tool.executableNames.joined(separator: " or ")
            let places = BackupToolDiscovery.summarize(searched)
            return "\(names) was not found. Foxlume Query looked in \(places).\n\n\(tool.installHint)"
        case .toolNotRunnable(let path):
            return "\(path) cannot be run. Choose another program in Settings › Backup Tools."
        case .unsupported(let message):
            return message
        }
    }
}

/// Finds the client tools as a login shell would (the user's PATH from their shell profile), plus the places
/// Homebrew, Postgres.app and the official installers put them, and picks the best copy.
public enum BackupToolDiscovery {
    /// Directories to search, in order, without duplicates: the login shell's PATH, Homebrew's bin folders, versioned
    /// Homebrew kegs (newest first), Postgres.app versions (newest first) and the official installers' folders.
    /// `listDirectory` returns the names inside a folder (empty when it does not exist).
    public static func searchDirectories(pathVariable: String?, listDirectory: (String) -> [String]) -> [String] {
        var directories: [String] = (pathVariable ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for prefix in ["/opt/homebrew", "/usr/local"] {
            directories.append(prefix + "/bin")
            let kegs = listDirectory(prefix + "/opt")
            let wanted = kegs.filter { name in
                name == "libpq" || name == "postgresql" || name.hasPrefix("postgresql@")
                    || name == "mysql-client" || name.hasPrefix("mysql-client@") || name == "mysql" || name.hasPrefix("mysql@")
                    || name == "mariadb" || name.hasPrefix("mariadb@")
            }
            directories += sortedNewestFirst(wanted).map { "\(prefix)/opt/\($0)/bin" }
        }
        let postgresApp = "/Applications/Postgres.app/Contents/Versions"
        directories += sortedNewestFirst(listDirectory(postgresApp).filter { $0 != "latest" }).map { "\(postgresApp)/\($0)/bin" }
        directories.append(postgresApp + "/latest/bin")
        directories += sortedNewestFirst(listDirectory("/Library/PostgreSQL")).map { "/Library/PostgreSQL/\($0)/bin" }
        directories += ["/usr/local/mysql/bin", "/usr/local/pgsql/bin", "/usr/bin"]
        var seen = Set<String>()
        return directories.map { ($0 as NSString).standardizingPath }.filter { seen.insert($0).inserted }
    }

    /// "postgresql@17" before "postgresql@9.6", unversioned names last.
    static func sortedNewestFirst(_ names: [String]) -> [String] {
        func key(_ name: String) -> [Int] {
            let digits = name.split { !$0.isNumber && $0 != "." }.last.map(String.init) ?? ""
            return digits.split(separator: ".").compactMap { Int($0) }
        }
        return names.sorted { lhs, rhs in
            let (a, b) = (key(lhs), key(rhs))
            if a != b { return a.lexicographicallyPrecedes(b) == false }
            return lhs < rhs
        }
    }

    /// The candidates in the order to use them. PostgreSQL tools: the newest version first (pg_dump can read older
    /// servers but refuses newer ones). MySQL tools: the matching flavor first (MariaDB's dump tool for MariaDB
    /// servers), then the newest. Ties keep the search order; copies whose version could not be read come last.
    public static func rank(_ candidates: [BackupToolCandidate], preferring flavor: BackupToolFlavor? = nil) -> [BackupToolCandidate] {
        let indexed = Array(candidates.enumerated())
        return indexed.sorted { lhs, rhs in
            let (a, b) = (lhs.element.version, rhs.element.version)
            switch (a, b) {
            case (nil, nil): return lhs.offset < rhs.offset
            case (nil, _): return false
            case (_, nil): return true
            case let (a?, b?):
                if let flavor, (a.flavor == flavor) != (b.flavor == flavor) { return a.flavor == flavor }
                if a < b || b < a { return b < a }
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// "your PATH (12 folders), Homebrew (/opt/homebrew, /usr/local), Postgres.app, …" for the missing-tool message:
    /// the directories that were searched, shortened to readable groups.
    public static func summarize(_ directories: [String]) -> String {
        var groups: [String] = []
        var others = 0
        func add(_ group: String) { if !groups.contains(group) { groups.append(group) } }
        for directory in directories {
            if directory.hasPrefix("/opt/homebrew") || directory.hasPrefix("/usr/local/opt") || directory == "/usr/local/bin" {
                add("Homebrew (/opt/homebrew, /usr/local)")
            } else if directory.hasPrefix("/Applications/Postgres.app") {
                add("Postgres.app")
            } else if directory.hasPrefix("/Library/PostgreSQL") || directory == "/usr/local/pgsql/bin" {
                add("the PostgreSQL installer folders")
            } else if directory == "/usr/local/mysql/bin" {
                add("/usr/local/mysql/bin")
            } else {
                others += 1
            }
        }
        if others > 0 { groups.insert("your PATH (\(others) \(others == 1 ? "folder" : "folders"))", at: 0) }
        return groups.isEmpty ? "the usual folders" : groups.joined(separator: ", ")
    }

    // MARK: Running the search

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedShellPath: String??
    nonisolated(unsafe) private static var cachedVersions: [String: (Date, BackupToolVersion?)] = [:]

    /// PATH as the user's login shell sets it (Homebrew's shellenv, Postgres.app's path_helper entry and the like),
    /// which apps started from the Dock do not inherit. Read once per launch; nil when the shell does not answer
    /// within 3 seconds.
    public static func loginShellPath() -> String? {
        cacheLock.lock()
        if let cached = cachedShellPath {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__FOXLUME_PATH__"
        let output = run(shell, ["-l", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""], timeout: 3)
        var path: String?
        if let output, let start = output.range(of: marker), let end = output.range(of: marker, range: start.upperBound..<output.endIndex) {
            path = String(output[start.upperBound..<end.lowerBound])
        }
        cacheLock.lock()
        cachedShellPath = .some(path)
        cacheLock.unlock()
        return path
    }

    /// The version a tool prints for `--version`, cached per path and modification date.
    public static func version(ofToolAt path: String) -> BackupToolVersion? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        cacheLock.lock()
        if let cached = cachedVersions[path], cached.0 == modified {
            cacheLock.unlock()
            return cached.1
        }
        cacheLock.unlock()
        let version = run(path, ["--version"], timeout: 5).flatMap(BackupToolVersion.parse)
        cacheLock.lock()
        cachedVersions[path] = (modified, version)
        cacheLock.unlock()
        return version
    }

    /// Searches for `tool`. `override` is the path chosen in Settings; when it is set it is used even if another copy
    /// is newer (it must exist and be executable). `pathVariable` defaults to the login shell's PATH and then the
    /// app's own.
    public static func find(_ tool: BackupTool, override: String? = nil, preferring flavor: BackupToolFlavor? = nil, pathVariable: String? = nil) -> BackupToolSearch {
        let manager = FileManager.default
        let path = pathVariable ?? loginShellPath() ?? ProcessInfo.processInfo.environment["PATH"]
        let directories = searchDirectories(pathVariable: path) { (try? manager.contentsOfDirectory(atPath: $0)) ?? [] }
        var found: [BackupToolCandidate] = []
        var seen = Set<String>()
        for directory in directories {
            for name in tool.executableNames {
                let candidate = (directory as NSString).appendingPathComponent(name)
                guard manager.isExecutableFile(atPath: candidate) else { continue }
                // Homebrew links bin/ to the keg; count each real file once.
                let real = (candidate as NSString).resolvingSymlinksInPath
                guard seen.insert(real).inserted else { continue }
                found.append(BackupToolCandidate(path: candidate, version: version(ofToolAt: candidate)))
            }
        }
        let ranked = rank(found, preferring: flavor)
        if let override = override?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            let expanded = ((override as NSString).expandingTildeInPath as NSString).standardizingPath
            let chosen = manager.isExecutableFile(atPath: expanded) ? BackupToolCandidate(path: expanded, version: version(ofToolAt: expanded)) : nil
            return BackupToolSearch(tool: tool, chosen: chosen, isOverride: true, candidates: ranked, searchedDirectories: directories)
        }
        return BackupToolSearch(tool: tool, chosen: ranked.first, isOverride: false, candidates: ranked, searchedDirectories: directories)
    }

    /// Runs a short command and returns its standard output (and error), or nil when it fails or takes too long.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read while waiting, so a chatty shell profile cannot fill the pipe and block.
        var data = Data()
        let reader = DispatchQueue(label: "FoxlumeQuery.toolProbe")
        let readDone = DispatchSemaphore(value: 0)
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
            _ = readDone.wait(timeout: .now() + 1)
            return nil
        }
        _ = readDone.wait(timeout: .now() + 2)
        return String(decoding: data, as: UTF8.self)
    }
}

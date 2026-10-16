import Foundation

public enum AppPaths {
    /// Set to keep every piece of app data (connections, passwords, history, settings) in one folder.
    /// Used for development and portable installs; passwords are then stored in a 0600 file instead of the Keychain.
    public static let dataDirectoryEnvironmentKey = "FOXLUME_DATA_DIR"

    public static var isPortable: Bool {
        ProcessInfo.processInfo.environment[dataDirectoryEnvironmentKey].map { !$0.isEmpty } ?? false
    }

    public static var dataDirectory: URL {
        let url: URL
        if let custom = ProcessInfo.processInfo.environment[dataDirectoryEnvironmentKey], !custom.isEmpty {
            url = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            url = base.appendingPathComponent("Foxlume Query", isDirectory: true)
            migrateLegacyDirectory(in: base, to: url)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The app was called EasyQuery before; move its data folder over once so nothing is lost.
    private static func migrateLegacyDirectory(in base: URL, to url: URL) {
        let fileManager = FileManager.default
        let legacy = base.appendingPathComponent("EasyQuery", isDirectory: true)
        guard !fileManager.fileExists(atPath: url.path), fileManager.fileExists(atPath: legacy.path) else { return }
        try? fileManager.moveItem(at: legacy, to: url)
    }

    public static var connectionsFile: URL { dataDirectory.appendingPathComponent("connections.json") }
    public static var settingsFile: URL { dataDirectory.appendingPathComponent("settings.json") }
    public static var historyDatabase: URL { dataDirectory.appendingPathComponent("history.sqlite") }
    public static var savedQueriesFile: URL { dataDirectory.appendingPathComponent("saved-queries.json") }
    /// Saved filter presets, per table.
    public static var filterPresetsFile: URL { dataDirectory.appendingPathComponent("filter-presets.json") }
    /// What Open Quickly remembers about recently chosen items, per connection.
    public static var openQuicklyFile: URL { dataDirectory.appendingPathComponent("open-quickly.json") }
    /// Table positions arranged in ER diagrams, per connection, database and schema.
    public static var erDiagramLayoutsFile: URL { dataDirectory.appendingPathComponent("er-diagram-layouts.json") }
    /// Column order, widths and hidden columns of table grids, per connection, database, schema and table.
    public static var gridColumnLayoutsFile: URL { dataDirectory.appendingPathComponent("grid-column-layouts.json") }
    /// Host keys accepted for SSH tunnels, kept apart from the user's own ~/.ssh/known_hosts.
    public static var knownHostsFile: URL { dataDirectory.appendingPathComponent("known_hosts") }
    public static var portableCredentialsFile: URL { dataDirectory.appendingPathComponent("credentials.json") }
    public static var tabStateDirectory: URL {
        let url = dataDirectory.appendingPathComponent("tabs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL, permissions: Int? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }
}

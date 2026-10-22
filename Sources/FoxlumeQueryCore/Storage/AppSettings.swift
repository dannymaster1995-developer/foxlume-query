import Foundation

/// User preferences, persisted as JSON in the data folder.
public struct AppSettings: Codable, Equatable, Sendable {
    public var rowsPerPage: Int = 500
    /// Rows kept from one query in the SQL editor; the rest are discarded.
    public var queryRowLimit: Int = 10_000
    public var editorFontSize: Double = 13
    public var gridFontSize: Double = 12
    public var autocompleteOnTyping: Bool = true
    /// How completed keywords are cased (Settings › SQL Editor).
    public var keywordCase: KeywordCase = .matchTypedElseUpper
    /// Wrap long lines in the query editor; off scrolls horizontally (View › Word Wrap).
    public var editorWordWrap: Bool = true
    /// Shade the statement at the caret when the query editor holds several.
    public var highlightCurrentStatement: Bool = true
    public var confirmWritesOnProduction: Bool = true
    public var showRowNumbers: Bool = true
    /// List engine-internal databases (mysql, sys, information_schema, admin, …) in the switcher.
    public var showSystemDatabases: Bool = false
    /// Ask before running UPDATE or DELETE statements that have no WHERE clause.
    public var confirmUnboundedWrites: Bool = true
    public var connectionHealthCheck: ConnectionHealthCheck = .every30Seconds
    /// System follows macOS; Light and Dark force the whole app, as TablePro's Appearance setting does.
    public var appearance: AppearanceMode = .system
    public var lightThemeID: String = BuiltInThemes.defaultLightID
    public var darkThemeID: String = BuiltInThemes.defaultDarkID
    /// Environments whose windows get a tinted toolbar (Settings › Appearance); Production and Staging by default.
    public var toolbarTintEnvironments: Set<ConnectionEnvironment> = [.production, .staging]
    /// Paths chosen in Settings › Backup Tools, keyed by `BackupTool.rawValue`; a missing key means "find it".
    public var backupToolPaths: [String: String] = [:]
    /// Settings › AI; off until the user turns it on.
    public var ai = AISettings()

    public init() {}

    /// The path chosen for `tool` in Settings, or nil to use the copy that discovery finds.
    public func backupToolPath(_ tool: BackupTool) -> String? {
        guard let path = backupToolPaths[tool.rawValue]?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
        return path
    }

    public mutating func setBackupToolPath(_ tool: BackupTool, _ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespaces) ?? ""
        backupToolPaths[tool.rawValue] = trimmed.isEmpty ? nil : trimmed
    }

    /// Whether windows of a connection in `environment` get the environment's toolbar tint. Never without an environment.
    public func tintsToolbar(for environment: ConnectionEnvironment) -> Bool {
        environment != .none && toolbarTintEnvironments.contains(environment)
    }

    public mutating func setTintsToolbar(_ tints: Bool, for environment: ConnectionEnvironment) {
        guard environment != .none else { return }
        if tints {
            toolbarTintEnvironments.insert(environment)
        } else {
            toolbarTintEnvironments.remove(environment)
        }
    }

    public init(from decoder: Decoder) throws {
        let defaults = AppSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rowsPerPage = try container.decodeIfPresent(Int.self, forKey: .rowsPerPage) ?? defaults.rowsPerPage
        queryRowLimit = try container.decodeIfPresent(Int.self, forKey: .queryRowLimit) ?? defaults.queryRowLimit
        editorFontSize = try container.decodeIfPresent(Double.self, forKey: .editorFontSize) ?? defaults.editorFontSize
        gridFontSize = try container.decodeIfPresent(Double.self, forKey: .gridFontSize) ?? defaults.gridFontSize
        autocompleteOnTyping = try container.decodeIfPresent(Bool.self, forKey: .autocompleteOnTyping) ?? defaults.autocompleteOnTyping
        keywordCase = try container.decodeIfPresent(KeywordCase.self, forKey: .keywordCase) ?? defaults.keywordCase
        editorWordWrap = try container.decodeIfPresent(Bool.self, forKey: .editorWordWrap) ?? defaults.editorWordWrap
        highlightCurrentStatement = try container.decodeIfPresent(Bool.self, forKey: .highlightCurrentStatement) ?? defaults.highlightCurrentStatement
        confirmWritesOnProduction = try container.decodeIfPresent(Bool.self, forKey: .confirmWritesOnProduction) ?? defaults.confirmWritesOnProduction
        showRowNumbers = try container.decodeIfPresent(Bool.self, forKey: .showRowNumbers) ?? defaults.showRowNumbers
        showSystemDatabases = try container.decodeIfPresent(Bool.self, forKey: .showSystemDatabases) ?? defaults.showSystemDatabases
        confirmUnboundedWrites = try container.decodeIfPresent(Bool.self, forKey: .confirmUnboundedWrites) ?? defaults.confirmUnboundedWrites
        connectionHealthCheck = try container.decodeIfPresent(ConnectionHealthCheck.self, forKey: .connectionHealthCheck) ?? defaults.connectionHealthCheck
        appearance = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? defaults.appearance
        lightThemeID = Self.migratedThemeID(try container.decodeIfPresent(String.self, forKey: .lightThemeID)) ?? defaults.lightThemeID
        darkThemeID = Self.migratedThemeID(try container.decodeIfPresent(String.self, forKey: .darkThemeID)) ?? defaults.darkThemeID
        toolbarTintEnvironments = (try? container.decodeIfPresent(Set<ConnectionEnvironment>.self, forKey: .toolbarTintEnvironments)) ?? defaults.toolbarTintEnvironments
        backupToolPaths = (try? container.decodeIfPresent([String: String].self, forKey: .backupToolPaths)) ?? defaults.backupToolPaths
        ai = (try? container.decodeIfPresent(AISettings.self, forKey: .ai)) ?? defaults.ai
    }
}

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// How often an open connection is pinged, as in TablePro. A failed ping reconnects in the background.
public enum ConnectionHealthCheck: Int, Codable, CaseIterable, Sendable {
    /// No timer: a lost link is noticed, and reconnected, when it is next used.
    case onDemand = 0
    case every30Seconds = 30
    case every5Minutes = 300
    case every15Minutes = 900

    public var title: String {
        switch self {
        case .onDemand: return "Only when I use the connection"
        case .every30Seconds: return "Every 30 seconds"
        case .every5Minutes: return "Every 5 minutes"
        case .every15Minutes: return "Every 15 minutes"
        }
    }

    public var interval: TimeInterval? {
        self == .onDemand ? nil : TimeInterval(rawValue)
    }
}

extension AppSettings {
    /// Built-in theme IDs were prefixed "easyquery." before the rename to Foxlume Query.
    static func migratedThemeID(_ id: String?) -> String? {
        guard let id, id.hasPrefix("easyquery.") else { return id }
        return "foxlume." + id.dropFirst("easyquery.".count)
    }
}

public final class SettingsStore: @unchecked Sendable {
    public static let shared = SettingsStore()
    public static let didChangeNotification = Notification.Name("FoxlumeQuery.SettingsStore.didChange")

    private let url: URL
    private let lock = NSLock()
    private var current: AppSettings

    public init(url: URL = AppPaths.settingsFile) {
        self.url = url
        self.current = JSONFile.read(AppSettings.self, from: url) ?? AppSettings()
    }

    public var settings: AppSettings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
            try? JSONFile.write(newValue, to: url)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}

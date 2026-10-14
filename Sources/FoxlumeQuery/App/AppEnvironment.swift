import AppKit
import FoxlumeQueryCore

/// Shared stores, created once at launch.
@MainActor
enum AppEnvironment {
    static let connections = ConnectionStore()
    static let credentials: CredentialStore = CredentialStores.makeDefault()
    static let history = QueryHistoryStore()
    static var settings: AppSettings {
        get { SettingsStore.shared.settings }
        set { SettingsStore.shared.settings = newValue }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

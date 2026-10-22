import AppKit
import FoxlumeQueryCore

/// Shared stores, created once at launch.
@MainActor
enum AppEnvironment {
    static let connections = ConnectionStore()
    static let credentials: CredentialStore = CredentialStores.makeDefault()
    /// AI provider API keys: their own Keychain service, or the portable credentials file.
    static let aiKeys = AIKeyStore(store: CredentialStores.makeAIDefault())
    static let history = QueryHistoryStore()
    static let savedQueries = SavedQueryStore()
    static let filterPresets = FilterPresetStore()
    static let openQuicklyFrecency = QuickOpenFrecencyStore()
    static let erDiagramLayouts = ERDiagramLayoutStore()
    static let gridColumnLayouts = GridColumnLayoutStore()
    static let favourites = FavouritesStore()
    static var settings: AppSettings {
        get { SettingsStore.shared.settings }
        set { SettingsStore.shared.settings = newValue }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

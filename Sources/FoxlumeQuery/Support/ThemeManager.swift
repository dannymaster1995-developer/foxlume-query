import AppKit
import FoxlumeQueryCore

/// The light and dark themes the user picked. Colors are read from any thread while drawing,
/// so the current pair is guarded by a lock rather than the main actor.
final class ThemeManager: @unchecked Sendable {
    static let shared = ThemeManager()
    static let didChangeNotification = Notification.Name("FoxlumeQuery.ThemeManager.didChange")

    private let lock = NSLock()
    private var light: ThemeDefinition = BuiltInThemes.defaultLight
    private var dark: ThemeDefinition = BuiltInThemes.defaultDark
    private var cache: [String: NSColor] = [:]

    private init() {
        reload()
        NotificationCenter.default.addObserver(forName: SettingsStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
        NotificationCenter.default.addObserver(forName: ThemeStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    /// Picks up the themes named in settings; posts a change only when they actually differ.
    func reload() {
        let settings = SettingsStore.shared.settings
        let store = ThemeStore.shared
        let newLight = store.theme(id: settings.lightThemeID) ?? BuiltInThemes.defaultLight
        let newDark = store.theme(id: settings.darkThemeID) ?? BuiltInThemes.defaultDark
        lock.lock()
        let changed = newLight != light || newDark != dark
        light = newLight
        dark = newDark
        if changed { cache.removeAll() }
        lock.unlock()
        if changed {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    func theme(dark isDark: Bool) -> ThemeDefinition {
        lock.lock()
        defer { lock.unlock() }
        return isDark ? dark : light
    }

    func color(_ slot: ThemeSlot, dark isDark: Bool) -> NSColor? {
        let key = "\(isDark ? "d" : "l").\(slot.rawValue)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        guard let rgba = (isDark ? dark : light).color(slot) else { return nil }
        let color = NSColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        cache[key] = color
        return color
    }

    static func nsColor(_ hex: String) -> NSColor? {
        RGBAColor(hex: hex).map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) }
    }
}

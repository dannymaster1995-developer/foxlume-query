import Foundation

/// The colors that mark a connection's windows with its environment: a translucent band behind the titlebar and
/// toolbar, and a thin accent line under it. Production is the strongest, Staging clearly visible, Development and
/// Local faint; a connection without an environment is never tinted.
public struct EnvironmentTint: Equatable, Sendable {
    /// Painted over the titlebar and toolbar; translucent, so the system material still shows through.
    public var band: RGBAColor
    /// The line along the top of the tab strip.
    public var accent: RGBAColor

    public init(band: RGBAColor, accent: RGBAColor) {
        self.band = band
        self.accent = accent
    }

    /// Band opacity in an active window, per environment and appearance. Dark windows need more to read at a glance.
    static func bandAlpha(_ environment: ConnectionEnvironment, dark: Bool) -> Double {
        switch environment {
        case .production: return dark ? 0.32 : 0.24
        case .staging: return dark ? 0.22 : 0.17
        case .development, .local: return dark ? 0.12 : 0.08
        case .none: return 0
        }
    }

    static func accentAlpha(_ environment: ConnectionEnvironment) -> Double {
        switch environment {
        case .production: return 0.9
        case .staging: return 0.75
        case .development, .local: return 0.45
        case .none: return 0
        }
    }

    /// Inactive windows keep the tint at this share, as macOS mutes an inactive titlebar.
    static let inactiveFactor = 0.6

    /// The environment's color: the macOS system color of its badge (red, orange, blue, green) for the appearance.
    public static func baseColor(for environment: ConnectionEnvironment, dark: Bool) -> RGBAColor? {
        let value: UInt32
        switch environment {
        case .production: value = dark ? 0xFF453A : 0xFF3B30
        case .staging: value = dark ? 0xFF9F0A : 0xFF9500
        case .development: value = dark ? 0x0A84FF : 0x007AFF
        case .local: value = dark ? 0x30D158 : 0x34C759
        case .none: return nil
        }
        return RGBAColor(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }

    /// The tint of a window of a connection in `environment`, or nil when it gets none (no environment, or the
    /// environment is switched off in Settings › Appearance).
    public static func tint(for environment: ConnectionEnvironment, enabled: Bool, dark: Bool, active: Bool) -> EnvironmentTint? {
        guard enabled, let base = baseColor(for: environment, dark: dark) else { return nil }
        let factor = active ? 1 : inactiveFactor
        var band = base
        band.alpha = bandAlpha(environment, dark: dark) * factor
        var accent = base
        accent.alpha = accentAlpha(environment) * factor
        return EnvironmentTint(band: band, accent: accent)
    }
}

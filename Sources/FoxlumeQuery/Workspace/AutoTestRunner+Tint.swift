import AppKit
import FoxlumeQueryCore

/// Scripted commands for the environment tint of the toolbar.
///
///     tintactive on|off|auto          draws every tint as in an active (on) or inactive (off) window, or as the window
///                                     really is (auto); scripted runs keep the app in the background
///     tint [connection]               logs the workspace window's environment, band and accent (the front one, or
///                                     the named connection's), and its Server Activity window's band and badge
///                                     when that is open
///     tintsetting <environment> on|off  Settings › Appearance › Tint the window toolbar for that environment
///     setenvironment <environment>    saves the front workspace's connection with that environment, as the
///                                     connection form's Save does
@MainActor
enum TintAutoTest {
    static let commands: Set<String> = ["tintactive", "tint", "tintsetting", "setenvironment"]
}

extension AutoTestRunner {
    func performTint(_ command: String, _ argument: String) async throws {
        switch command {
        case "tintactive":
            EnvironmentTintBand.activeOverride = argument == "on" ? true : argument == "off" ? false : nil
            try await Task.sleep(nanoseconds: 300_000_000)
        case "tint":
            let named = argument.isEmpty ? workspace : app?.workspaces.first { $0.workspace.config.displayName == argument }
            guard let window = named else { throw DatabaseError.notConnected }
            record("  workspace: " + Self.describe(window.environmentTint, environment: window.workspace.config.environment))
            let accent = window.tabs.strip.accentColor.map { Self.hex($0) } ?? "none"
            record("  tab strip accent: \(accent)")
            if let activity = window.serverActivityController {
                record("  server activity: " + Self.describe(activity.environmentTint, environment: activity.model.workspace.config.environment)
                    + "; badge: \(activity.environmentBadge.badgeText ?? "none")")
            }
        case "tintsetting":
            let parts = argument.split(separator: " ").map(String.init)
            guard parts.count == 2, let environment = ConnectionEnvironment(rawValue: parts[0]) else {
                throw DatabaseError.unsupported("tintsetting <environment> on|off")
            }
            var settings = AppEnvironment.settings
            settings.setTintsToolbar(parts[1] == "on", for: environment)
            AppEnvironment.settings = settings
            try await Task.sleep(nanoseconds: 300_000_000)
        case "setenvironment":
            guard let window = workspace, var config = AppEnvironment.connections.connection(id: window.workspace.config.id) else {
                throw DatabaseError.notConnected
            }
            guard let environment = ConnectionEnvironment(rawValue: argument) else { throw DatabaseError.unsupported("Unknown environment \(argument)") }
            config.environment = environment
            try AppEnvironment.connections.save(config)
            try await Task.sleep(nanoseconds: 300_000_000)
        default:
            break
        }
    }

    /// "production, active, band #FF3B30 at 24 % over 1280x52 in the titlebar" or "local, none".
    private static func describe(_ band: EnvironmentTintBand, environment: ConnectionEnvironment) -> String {
        guard let tint = band.tint, !band.isHidden else { return "\(environment.rawValue), none" }
        let state = band.isWindowActive ? "active" : "inactive"
        let titlebar = band.window?.standardWindowButton(.closeButton)?.superview
        let place = band.superview != nil && band.superview === titlebar ? "in the titlebar" : "outside the titlebar"
        let size = "\(Int(band.frame.width))x\(Int(band.frame.height))"
        var opaque = tint.band
        opaque.alpha = 1
        return "\(environment.rawValue), \(state), band \(opaque.hex) at \(Int((tint.band.alpha * 100).rounded())) % over \(size) \(place)"
    }

    private static func hex(_ color: NSColor) -> String {
        guard let srgb = color.usingColorSpace(.sRGB) else { return "?" }
        let rgba = RGBAColor(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
        return "\(rgba.hex) at \(Int((srgb.alphaComponent * 100).rounded())) %"
    }
}

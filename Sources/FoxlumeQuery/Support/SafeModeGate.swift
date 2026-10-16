import AppKit
import FoxlumeQueryCore
import LocalAuthentication

/// Applies a connection's Safe Mode before statements run: confirmation, then Touch ID or the login password for the
/// Safe Mode levels. Read-Only is enforced by the workspace and the server session, not here.
@MainActor
enum SafeModeGate {
    /// The connection's level, raised to Alert for Production connections while "Confirm data changes on Production
    /// connections" is on in Settings.
    static func level(for config: ConnectionConfig) -> SafeModeLevel {
        let chosen = config.safeModeLevel
        if config.environment == .production, AppEnvironment.settings.confirmWritesOnProduction, chosen.strictness < SafeModeLevel.alert.strictness {
            return .alert
        }
        return chosen
    }

    /// Calls `completion(true)` when the statements may run.
    /// - Parameters:
    ///   - statements: what will run, shown in the question (the first few).
    ///   - writes: whether any of them changes data.
    ///   - action: the question's verb phrase, such as "Run 2 statements" or "Save 3 changes to users".
    ///   - extraDetail: lines shown above the statements, such as a missing primary key warning.
    ///   - destructive: shows the question as a critical alert with a destructive button (ending a server session).
    ///   - confirmTitle: the button's title instead of Run or Continue.
    static func authorize(
        config: ConnectionConfig,
        statements: [String],
        writes: Bool,
        action: String,
        extraDetail: String? = nil,
        destructive: Bool = false,
        confirmTitle: String? = nil,
        in window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        let level = level(for: config)
        guard level.gates(writes: writes) || extraDetail != nil else { return completion(true) }
        var lines: [String] = []
        if let extraDetail { lines.append(extraDetail) }
        if level.gates(writes: writes) {
            lines.append("\(config.displayName) uses Safe Mode “\(level.title)”.")
        }
        if !statements.isEmpty {
            let shown = statements.prefix(6).map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }
            lines.append(shown.joined(separator: ";\n") + (statements.count > 6 ? ";\n…" : ""))
        }
        Alerts.confirm("\(action)?", detail: lines.joined(separator: "\n\n"), confirmTitle: confirmTitle ?? (writes ? "Run" : "Continue"), destructive: destructive, in: window) { confirmed in
            guard confirmed else { return completion(false) }
            guard level.requiresAuthentication, level.gates(writes: writes) else { return completion(true) }
            authenticate(reason: "run statements on \(config.displayName)", completion: completion)
        }
    }

    /// Touch ID, Apple Watch or the login password. Fails closed when the Mac offers none of them.
    static func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            Alerts.showError(DatabaseError.unsupported("This Mac cannot verify your identity (\(error?.localizedDescription ?? "no authentication method")), so the statements were not run."), title: "Authentication unavailable", in: NSApp.keyWindow)
            return completion(false)
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }
}

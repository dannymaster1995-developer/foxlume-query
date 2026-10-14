import Foundation

/// How carefully a connection runs statements, from no questions to no writes at all (TablePro's Safe Mode levels).
public enum SafeModeLevel: String, Codable, CaseIterable, Sendable {
    /// Runs everything without asking.
    case silent
    /// Asks before statements that change data.
    case alert
    /// Asks before every statement.
    case alertFull
    /// Asks, then requires Touch ID or the login password, before statements that change data.
    case safeMode
    /// Asks and requires authentication before every statement.
    case safeModeFull
    /// Refuses every statement that changes data.
    case readOnly

    public var title: String {
        switch self {
        case .silent: return "Silent"
        case .alert: return "Alert"
        case .alertFull: return "Alert (Full)"
        case .safeMode: return "Safe Mode"
        case .safeModeFull: return "Safe Mode (Full)"
        case .readOnly: return "Read-Only"
        }
    }

    public var summary: String {
        switch self {
        case .silent: return "Runs every statement without asking."
        case .alert: return "Asks before running statements that change data."
        case .alertFull: return "Asks before running any statement."
        case .safeMode: return "Asks, then requires Touch ID or your password, before statements that change data."
        case .safeModeFull: return "Asks and requires Touch ID or your password before any statement."
        case .readOnly: return "Never runs statements that change data."
        }
    }

    /// SF Symbol shown next to the connection.
    public var symbolName: String {
        switch self {
        case .silent: return "lock.open"
        case .alert: return "exclamationmark.triangle"
        case .alertFull: return "exclamationmark.triangle.fill"
        case .safeMode: return "lock.shield"
        case .safeModeFull: return "lock.shield.fill"
        case .readOnly: return "lock"
        }
    }

    public var requiresConfirmation: Bool {
        switch self {
        case .alert, .alertFull, .safeMode, .safeModeFull: return true
        case .silent, .readOnly: return false
        }
    }

    public var requiresAuthentication: Bool { self == .safeMode || self == .safeModeFull }

    /// Gates reads as well as writes.
    public var appliesToAllQueries: Bool { self == .alertFull || self == .safeModeFull }

    public var blocksAllWrites: Bool { self == .readOnly }

    /// Ordered by what each level prevents, so a stricter level can be chosen between two.
    public var strictness: Int {
        switch self {
        case .silent: return 0
        case .alert: return 1
        case .alertFull: return 2
        case .safeMode: return 3
        case .safeModeFull: return 4
        case .readOnly: return 5
        }
    }

    /// Whether a statement batch must be confirmed (and, for the Safe Mode levels, authenticated) before it runs.
    public func gates(writes: Bool) -> Bool {
        requiresConfirmation && (writes || appliesToAllQueries)
    }
}

extension ConnectionConfig {
    /// The connection's Safe Mode. `readOnly` stays the stored source of truth for Read-Only, because the drivers
    /// use it to open read-only sessions; connections saved before Safe Mode existed are Silent.
    public var safeModeLevel: SafeModeLevel {
        get { readOnly ? .readOnly : (safeMode ?? .silent) }
        set {
            readOnly = newValue == .readOnly
            safeMode = newValue
        }
    }
}

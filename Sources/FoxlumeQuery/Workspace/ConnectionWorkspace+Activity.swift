import AppKit
import FoxlumeQueryCore

/// One of Foxlume Query's own sessions on the server, as Server Activity marks it.
struct OwnServerSession {
    /// "This window", "Window “Prod”" or "Foxlume Query" (an export, import or maintenance session).
    let label: String
    /// The workspace whose main session this is; nil for the separate sessions.
    let workspace: ConnectionWorkspace?
}

/// Server Activity (PostgreSQL, MySQL, MariaDB) polls on a session of its own, opened like the export session but
/// with a short query timeout, so a busy server never holds up the grid, the query tabs or the window.
extension ConnectionWorkspace {
    /// Seconds a poll or an action may take before it is stopped.
    static let activityQueryTimeout = 5

    var supportsServerActivity: Bool { ServerActivitySQL.isSupported(kind) }

    var serverActivity: ServerActivitySQL { ServerActivitySQL(kind: kind, serverVersion: serverVersion) }

    /// A separate session for Server Activity: the database in use (pg_stat_statements is read where it is installed)
    /// and a query timeout of `activityQueryTimeout` seconds.
    func openActivitySession() async throws -> DatabaseSession {
        try await openTransferSession(queryTimeout: Self.activityQueryTimeout)
    }

    /// Whether Safe Mode refuses cancelling or ending sessions outright: the connection is Read-Only.
    var refusesSessionActions: Bool { SafeModeGate.level(for: config).blocksAllWrites }

    /// The app's own sessions on this server, by server process id: the main session of this and every other window
    /// connected to the same server, and the separate sessions (export, import, maintenance). `excluding` is left
    /// out (the activity session itself, which the server list leaves out too).
    func ownServerSessions(windows: [ConnectionWorkspace], excluding: DatabaseSession?) -> [Int: OwnServerSession] {
        var owners: [Int: OwnServerSession] = [:]
        for session in DatabaseSession.liveSessions where session !== excluding && sharesServer(with: session.parameters.config) {
            guard let pid = session.serverProcessID else { continue }
            if session === self.session {
                owners[pid] = OwnServerSession(label: "This window", workspace: self)
            } else if let other = windows.first(where: { $0.session === session }) {
                owners[pid] = OwnServerSession(label: "Window “\(other.config.displayName)”", workspace: other)
            } else {
                owners[pid] = OwnServerSession(label: "Foxlume Query", workspace: nil)
            }
        }
        return owners
    }

    /// Whether `other` connects to the same server: the same engine family, host and port, through the same SSH host.
    private func sharesServer(with other: ConnectionConfig) -> Bool {
        let family = { (kind: DatabaseKind) in kind.usesMySQLProtocol ? "mysql" : kind.rawValue }
        return family(other.kind) == family(kind)
            && other.host.lowercased() == config.host.lowercased()
            && other.port == config.port
            && other.ssh?.host == config.ssh?.host
            && other.ssh?.port == config.ssh?.port
    }

    /// One line in the query history per action, with the server's answer when it failed.
    func recordSessionAction(_ statement: String, duration: TimeInterval, error: String?) {
        AppEnvironment.history.add(sql: statement, connectionID: config.id, database: currentDatabase, duration: duration, rowCount: nil, error: error)
    }
}

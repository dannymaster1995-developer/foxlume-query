import AppKit
import FoxlumeQueryCore

/// Backup and Restore run the engine's own client tools (pg_dump, pg_restore, psql, mysqldump, mysql) with the
/// connection's settings; see FoxlumeQueryCore/Backup for how a run is put together.
extension ConnectionWorkspace {
    /// Engines with Backup and Restore.
    var supportsBackup: Bool { kind == .postgresql || kind.usesMySQLProtocol }

    var parsedServerVersion: ServerVersion? { ServerVersion.parse(serverVersion) }

    /// The dump tool flavor to prefer: MariaDB's for MariaDB servers.
    var preferredToolFlavor: BackupToolFlavor? {
        guard kind.usesMySQLProtocol else { return nil }
        return kind == .mariadb || parsedServerVersion?.isMariaDB == true ? .mariadb : .mysql
    }

    /// Searches for `tool` off the main thread: the path chosen in Settings, else the best copy found.
    func findBackupTool(_ tool: BackupTool) async -> BackupToolSearch {
        let override = AppEnvironment.settings.backupToolPath(tool)
        let flavor = preferredToolFlavor
        return await Task.detached(priority: .userInitiated) {
            BackupToolDiscovery.find(tool, override: override, preferring: flavor)
        }.value
    }

    /// What a tool connects with, acting on `database` (the one in use by default).
    func backupConnection(database: String? = nil) -> BackupConnection {
        BackupConnection(parameters: session.parameters, database: database ?? currentDatabase ?? config.database, serverVersion: parsedServerVersion)
    }

    /// Restores write: refused on Read-Only connections, always confirmed, as a critical alert on Production
    /// connections, and with Touch ID or the password on the Safe Mode levels. Calls `proceed` when allowed.
    func confirmRestore(_ action: String, detail: String, in window: NSWindow?, proceed: @escaping () -> Void) {
        let level = SafeModeGate.level(for: config)
        guard !level.blocksAllWrites else {
            Alerts.showError(DatabaseError.unsupported("This connection is read-only. Restores are not run."), title: "Read-only connection", in: window)
            return
        }
        var lines = [detail]
        if config.environment == .production { lines.append("\(config.displayName) is a Production connection.") }
        if level.requiresConfirmation { lines.append("\(config.displayName) uses Safe Mode “\(level.title)”.") }
        Alerts.confirm("\(action)?", detail: lines.joined(separator: "\n\n"), confirmTitle: "Restore", destructive: config.environment == .production, in: window) { [config] confirmed in
            guard confirmed else { return }
            guard level.requiresAuthentication else { return proceed() }
            SafeModeGate.authenticate(reason: "restore into \(config.displayName)") { allowed in
                if allowed { proceed() }
            }
        }
    }
}

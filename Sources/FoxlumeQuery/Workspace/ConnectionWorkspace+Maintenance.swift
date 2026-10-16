import AppKit
import FoxlumeQueryCore

/// Maintenance (VACUUM, ANALYZE, OPTIMIZE, CHECK TABLE…) runs on a session of its own, opened like the export and
/// import session (same database, no query timeout), so a long VACUUM FULL leaves the grid and query tabs free.
extension ConnectionWorkspace {
    var maintenance: MaintenanceSQL { MaintenanceSQL(kind: kind) }

    /// Whether Safe Mode refuses the steps outright: they write and the connection is Read-Only.
    func refusesMaintenance(_ steps: [MaintenanceStep]) -> Bool {
        SafeModeGate.level(for: config).blocksAllWrites && MaintenanceSQL.writes(steps)
    }

    /// A separate session for a maintenance run; see `openTransferSession`.
    func openMaintenanceRunSession() async throws -> DatabaseSession {
        try await openTransferSession()
    }

    /// One line in the query history per statement, with its time and, when it failed, the server's answer.
    func recordMaintenance(_ step: MaintenanceStep, _ outcome: MaintenanceOutcome) {
        let failed = outcome.status == .failed || outcome.status == .cancelled
        AppEnvironment.history.add(sql: step.statement, connectionID: config.id, database: currentDatabase, duration: outcome.elapsed ?? 0, rowCount: nil, error: failed ? outcome.summary : nil)
    }
}

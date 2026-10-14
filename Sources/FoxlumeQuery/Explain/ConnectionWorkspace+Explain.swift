import AppKit
import FoxlumeQueryCore

/// Explain and Explain Analyze on the workspace's session. The request decides what may run; this records it in the
/// history and counts it as running, like any statement.
extension ConnectionWorkspace {
    var explainAvailability: ExplainAvailability {
        ExplainRequest.availability(kind: kind, serverVersion: serverVersion)
    }

    /// Builds the request for `statement`, or throws the reason it cannot run on this connection.
    func explainRequest(for statement: String, mode: ExplainMode) throws -> ExplainRequest {
        try ExplainRequest.make(kind: kind, serverVersion: serverVersion, statement: statement, mode: mode, readOnly: isReadOnly)
    }

    func explain(_ request: ExplainRequest, token: QueryToken? = nil) async throws -> ExplainOutcome {
        // The request already refuses this; a read-only connection never runs a write, whoever built the request.
        if isReadOnly, request.isWrite {
            throw ExplainError.refused("This connection is read-only. Statements that change data are not run.")
        }
        return try await tracked {
            let started = Date()
            do {
                let outcome = try await session.explain(request, token: token)
                AppEnvironment.history.add(sql: request.sql, connectionID: config.id, database: currentDatabase, duration: outcome.elapsed, rowCount: nil, error: nil)
                return outcome
            } catch {
                AppEnvironment.history.add(sql: request.sql, connectionID: config.id, database: currentDatabase, duration: Date().timeIntervalSince(started), rowCount: nil, error: error.localizedDescription)
                throw error
            }
        }
    }
}

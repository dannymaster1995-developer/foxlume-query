import AppKit
import FoxlumeQueryCore

/// Rename and Copy Database (PostgreSQL): the statement runs on a session of its own, connected to another database;
/// see DatabaseChangeRunner. Rename Schema is in ConnectionWorkspace.swift, next to the state it changes.
extension ConnectionWorkspace {
    /// A second session on `database` with the connection's settings but no query timeout: a copy can take long.
    func openMaintenanceSession(on database: String) async throws -> DatabaseSession {
        var parameters = session.parameters
        parameters.config.database = database
        parameters.config.queryTimeout = nil
        let maintenance = DatabaseSession(parameters: parameters)
        do {
            try await maintenance.connect()
        } catch {
            await maintenance.close()
            throw error
        }
        return maintenance
    }

    /// Renames or copies a database and reloads the catalog. Other sessions on the source stop it with
    /// `DatabaseChangeError.otherSessions` before anything changes. The statement is recorded in the history.
    @discardableResult
    func performDatabaseChange(_ change: DatabaseChange) async throws -> DatabaseChangeRunner.Outcome {
        if config.readOnly {
            throw DatabaseError.unsupported("This connection is read-only. Statements that change data are not run.")
        }
        guard DatabaseObjectSQL(kind: kind).canRenameDatabases else {
            throw DatabaseError.unsupported(DatabaseObjectSQL(kind: kind).databaseRenameUnavailableReason ?? "Not supported.")
        }
        return try await tracked {
            let databases = try await allDatabases()
            guard !databases.contains(change.target) else {
                throw DatabaseError.unsupported("A database named “\(change.target)” already exists.")
            }
            guard let wait = DatabaseObjectSQL.maintenanceDatabase(for: change.source, target: change.target, among: databases) else {
                throw DatabaseError.unsupported("There is no other database to connect to while “\(change.source)” is \(change.verb == "Rename" ? "renamed" : "copied").")
            }
            let maintenance = try await openMaintenanceSession(on: wait)
            let started = Date()
            let statement = change.statement(DatabaseObjectSQL(kind: kind)) ?? ""
            do {
                let outcome = try await DatabaseChangeRunner(change: change).run(own: session, maintenance: maintenance, waitDatabase: wait)
                await maintenance.close()
                AppEnvironment.history.add(sql: statement, connectionID: config.id, database: wait, duration: Date().timeIntervalSince(started), rowCount: nil, error: nil)
                await adoptDatabaseChange(change, moved: outcome.ownDatabase)
                return outcome
            } catch {
                await maintenance.close()
                if !(error is DatabaseChangeError) {
                    AppEnvironment.history.add(sql: statement, connectionID: config.id, database: wait, duration: Date().timeIntervalSince(started), rowCount: nil, error: error.localizedDescription)
                }
                await refreshMetadata()
                throw error
            }
        }
    }
}

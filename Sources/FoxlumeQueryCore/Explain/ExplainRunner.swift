import Foundation

/// What one Explain returned.
public struct ExplainOutcome: Sendable {
    public var request: ExplainRequest
    /// The server's output as text: JSON, the MySQL tree or SQLite's rows.
    public var rawText: String
    /// Nil when the output could not be read as a plan; the raw text is still shown.
    public var plan: QueryPlan?
    public var elapsed: TimeInterval
    /// Explain Analyze ran inside a transaction (or savepoint) that was rolled back.
    public var rolledBack: Bool
}

/// Runs an `ExplainRequest` on one connection. Explain Analyze on PostgreSQL runs between BEGIN and ROLLBACK, or
/// between a savepoint and a rollback to it when the session is already inside a transaction, so the statement's
/// changes never stay.
public enum ExplainRunner {
    static let savepoint = "foxlume_explain"

    public static func run(_ request: ExplainRequest, on connection: DatabaseConnection) throws -> ExplainOutcome {
        let started = Date()
        let results: [StatementResult]
        var rolledBack = false
        if request.rollsBack {
            results = try inRolledBackTransaction(connection) { try connection.execute(request.sql, rowLimit: nil) }
            rolledBack = true
        } else {
            results = try connection.execute(request.sql, rowLimit: nil)
        }
        var rawText = QueryPlanParser.rawText(of: results, format: request.format)
        let plan = QueryPlanParser.parse(rawText, format: request.format)
        // MongoDB and DuckDB answer on one line or in odd spacing; show the reply indented.
        if request.format == .mongoExplain, let json = PlanJSON.parse(rawText) {
            rawText = json.prettyText
        }
        return ExplainOutcome(request: request, rawText: rawText, plan: plan.map { plan in
            var copy = plan
            copy.rawText = rawText
            return copy
        }, elapsed: Date().timeIntervalSince(started), rolledBack: rolledBack)
    }

    /// Runs `body` and always undoes it. Only PostgreSQL requests ask for this.
    static func inRolledBackTransaction<T>(_ connection: DatabaseConnection, _ body: () throws -> T) throws -> T {
        let status = (connection as? PostgresConnection)?.transactionStatus ?? "I"
        switch status {
        case "E":
            throw ExplainError.refused("The current transaction has failed. Roll it back (ROLLBACK) before running Explain Analyze.")
        case "T":
            // Inside the user's own transaction: a savepoint keeps their earlier work and undoes only ours.
            _ = try connection.execute("SAVEPOINT \(savepoint)", rowLimit: nil)
            do {
                let value = try body()
                try undoSavepoint(connection)
                return value
            } catch {
                try? undoSavepoint(connection)
                throw error
            }
        default:
            _ = try connection.execute("BEGIN", rowLimit: nil)
            do {
                let value = try body()
                _ = try connection.execute("ROLLBACK", rowLimit: nil)
                return value
            } catch {
                _ = try? connection.execute("ROLLBACK", rowLimit: nil)
                throw error
            }
        }
    }

    private static func undoSavepoint(_ connection: DatabaseConnection) throws {
        _ = try connection.execute("ROLLBACK TO SAVEPOINT \(savepoint)", rowLimit: nil)
        _ = try connection.execute("RELEASE SAVEPOINT \(savepoint)", rowLimit: nil)
    }
}

public extension DatabaseSession {
    /// Runs the request as one queue job, so nothing queued meanwhile can run inside its transaction.
    /// Cancelling `token` interrupts it; the transaction is still rolled back.
    func explain(_ request: ExplainRequest, token: QueryToken? = nil) async throws -> ExplainOutcome {
        try await runStatement(token) { try ExplainRunner.run(request, on: $0) }
    }
}

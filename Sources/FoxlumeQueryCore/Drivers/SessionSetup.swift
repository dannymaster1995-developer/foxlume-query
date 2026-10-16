import Foundation

/// What every SQL driver applies to a session right after it connects, so a reconnect, a PostgreSQL database switch
/// and a second session get it too: the server-side half of the query timeout and the user's "Run on connect"
/// statements (`ConnectionConfig.startupCommands`). The export and import session drops the timeout beforehand.
public enum SessionSetup {
    /// The server-side timeout fires this many seconds after the client-side one, so the client normally stops the
    /// statement first and reports it clearly; the server only steps in when the cancel cannot get through.
    static let serverGraceSeconds = 1

    /// The statements of `config.startupCommands`, without empty and comment-only ones. Empty for MongoDB and Redis.
    public static func startupStatements(_ config: ConnectionConfig, family: SQLDialect.Family) -> [String] {
        guard config.kind.isSQL, let text = config.startupCommands else { return [] }
        return SQLStatementSplitter.split(text, family: family).map(\.text).filter {
            !SQLStatementSplitter.strippingComments($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Whether a Read-Only connection refuses `statement` as a startup command. Statements are judged as in query
    /// tabs, except that a `SET` of a session setting (`search_path`, `time_zone`, `work_mem`) is allowed: it changes
    /// no data. A `SET` that reaches past the session (`GLOBAL`, `PERSIST`, `PASSWORD`) or touches the transaction
    /// mode or the read-only settings is still refused.
    public static func isRefusedOnReadOnly(_ statement: String) -> Bool {
        if SQLStatementSplitter.looksReadOnly(statement) { return false }
        let words = SQLStatementSplitter.strippingComments(statement)
            .uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
            .filter { !$0.isEmpty }
        guard words.first == "SET" else { return true }
        let beyondSession: Set<String> = ["GLOBAL", "PERSIST", "PERSIST_ONLY", "PASSWORD", "TRANSACTION", "CHARACTERISTICS"]
        return words.contains { beyondSession.contains($0) || $0.contains("READ_ONLY") }
    }

    /// The first startup statement a Read-Only connection refuses, as the error that stops the connect.
    public static func readOnlyRefusal(_ config: ConnectionConfig, family: SQLDialect.Family) -> DatabaseError? {
        guard config.safeModeLevel.blocksAllWrites,
              let write = startupStatements(config, family: family).first(where: isRefusedOnReadOnly)
        else { return nil }
        return .unsupported("Run on connect: \(quoted(write)) may change data, and this connection is Read-Only. Remove it or choose another Safe Mode.")
    }

    static func failure(_ statement: String, _ error: Error) -> DatabaseError {
        .connection("Run on connect: \(quoted(statement)) failed: \(error.localizedDescription)")
    }

    /// One line, at most about 120 characters, in quotes.
    static func quoted(_ statement: String) -> String {
        let line = statement.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "“" + (line.count > 120 ? line.prefix(119) + "…" : line) + "”"
    }
}

extension DatabaseConnection {
    /// Applies `SessionSetup` to the freshly opened session. Drivers call it at the end of `connect()` and close the
    /// session when it throws. `serverTimeout` returns the statement that sets the server's own statement limit
    /// (given in milliseconds), or nil where the engine has none or it is not safe to set.
    func applySessionSetup(_ config: ConnectionConfig, serverTimeout: (_ milliseconds: Int) -> String? = { _ in nil }) throws {
        let family = dialect.family
        if let refusal = SessionSetup.readOnlyRefusal(config, family: family) { throw refusal }
        if let seconds = config.effectiveQueryTimeout,
           let sql = serverTimeout((seconds + SessionSetup.serverGraceSeconds) * 1000) {
            // A backstop only, so a server or proxy that does not know the setting does not stop the connect.
            _ = try? execute(sql, rowLimit: nil)
        }
        for statement in SessionSetup.startupStatements(config, family: family) {
            do {
                _ = try execute(statement, rowLimit: nil)
            } catch {
                throw SessionSetup.failure(statement, error)
            }
        }
    }
}

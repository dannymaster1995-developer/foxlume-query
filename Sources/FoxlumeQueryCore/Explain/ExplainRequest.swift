import Foundation

/// Explain shows the plan without running the statement; Explain Analyze runs it and measures every step.
public enum ExplainMode: String, Sendable, CaseIterable {
    case plan
    case analyze

    public var title: String {
        switch self {
        case .plan: return "Explain"
        case .analyze: return "Explain Analyze"
        }
    }
}

/// Why a statement was not explained. The message is shown to the user as is.
public enum ExplainError: LocalizedError, Equatable, Sendable {
    /// The engine or server version cannot do this.
    case unsupported(String)
    /// Running it could change data that cannot be put back, or the connection does not allow it.
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let message), .refused(let message): return message
        }
    }
}

/// What a connection can explain, for enabling menu items.
public struct ExplainAvailability: Equatable, Sendable {
    public var plan: Bool
    public var analyze: Bool
    /// Why Explain Analyze is not offered, for its tooltip.
    public var analyzeNote: String?
}

/// The statement sent for one Explain, and what running it means for Safe Mode.
public struct ExplainRequest: Equatable, Sendable {
    public var kind: DatabaseKind
    public var mode: ExplainMode
    /// The statement being explained, as the user wrote it, without a trailing semicolon.
    public var statement: String
    /// What is sent to the server.
    public var sql: String
    public var format: QueryPlanFormat
    /// The explained statement changes data (by the same rule Safe Mode uses for normal runs).
    public var statementWrites: Bool
    /// Explain Analyze runs inside a transaction that is rolled back afterwards (PostgreSQL).
    public var rollsBack: Bool

    /// ANALYZE executes the statement; plain EXPLAIN only plans it.
    public var executesStatement: Bool { mode == .analyze }

    /// Whether Safe Mode must treat this as a write: only when the statement really runs and changes data.
    public var isWrite: Bool { executesStatement && statementWrites }

    /// The question Safe Mode asks before an Explain Analyze that writes.
    public var safeModeDetail: String? {
        guard isWrite else { return nil }
        return rollsBack
            ? "Explain Analyze really runs this statement to measure it. Foxlume Query runs it in a transaction and rolls it back, so no data is kept changed, but sequence values it takes are not given back and triggers run."
            : "Explain Analyze really runs this statement to measure it."
    }

    // MARK: Building

    public static func availability(kind: DatabaseKind, serverVersion: String) -> ExplainAvailability {
        switch kind {
        case .postgresql:
            return ExplainAvailability(plan: true, analyze: true)
        case .mysql, .mariadb:
            if isMariaDB(kind: kind, serverVersion: serverVersion) {
                return ExplainAvailability(plan: true, analyze: true)
            }
            let analyze = version(serverVersion, atLeast: [8, 0, 18])
            return ExplainAvailability(plan: true, analyze: analyze, analyzeNote: analyze ? nil : "Explain Analyze needs MySQL 8.0.18 or later.")
        case .sqlite:
            return ExplainAvailability(plan: true, analyze: false, analyzeNote: "SQLite has no Explain Analyze.")
        case .duckdb, .mongodb:
            return ExplainAvailability(plan: true, analyze: true)
        case .redis:
            return ExplainAvailability(plan: false, analyze: false, analyzeNote: "Redis has no query plans.")
        }
    }

    /// Builds the request, or explains why it cannot run.
    /// - Parameter readOnly: the connection is read-only; Explain Analyze is then offered only for statements that read.
    public static func make(kind: DatabaseKind, serverVersion: String, statement rawStatement: String, mode: ExplainMode, readOnly: Bool) throws -> ExplainRequest {
        let availability = availability(kind: kind, serverVersion: serverVersion)
        guard availability.plan else { throw ExplainError.unsupported("\(kind.displayName) has no query plans to explain.") }
        if mode == .analyze, !availability.analyze {
            throw ExplainError.unsupported(availability.analyzeNote ?? "\(kind.displayName) has no Explain Analyze.")
        }
        // Only one statement is ever sent: a second one after an analyzed write, such as COMMIT, would run outside
        // the rolled-back transaction. As in TablePro, the first statement of a selection is explained.
        let statement = trimmed(firstStatement(of: rawStatement, kind: kind))
        guard !SQLStatementSplitter.strippingComments(statement).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExplainError.unsupported("There is no statement to explain. Put the caret in a statement or select one.")
        }
        if kind.isSQL, isExplain(statement) {
            throw ExplainError.unsupported("This statement is already an EXPLAIN. Run it with ⌘↩ to see its output.")
        }
        let writes = kind == .mongodb ? !QueryLanguage.mongo.isReadOnly(statement) : !SQLStatementSplitter.looksReadOnly(statement)

        // MySQL refuses even to plan a write inside a read-only transaction, so say why before the server does.
        if readOnly, writes, kind == .mysql, !isMariaDB(kind: kind, serverVersion: serverVersion) {
            throw ExplainError.refused("This connection is read-only, and MySQL does not explain statements that change data in a read-only session. Explain works here for statements that read data.")
        }
        if mode == .analyze, writes {
            if readOnly {
                throw ExplainError.refused("This connection is read-only. Explain Analyze runs the statement, so it is only available for statements that read data. Use Explain to see the plan without running it.")
            }
            if kind != .postgresql {
                throw ExplainError.refused("Explain Analyze runs the statement, and \(kind == .mariadb || isMariaDB(kind: kind, serverVersion: serverVersion) ? "MariaDB" : kind.displayName) cannot always undo what it changes, so Foxlume Query only runs it for statements that read data. Use Explain to see the plan without running it.")
            }
        }

        let request: (sql: String, format: QueryPlanFormat)
        switch (kind, mode) {
        case (.postgresql, .plan):
            request = ("EXPLAIN (FORMAT JSON) \(statement)", .postgresJSON)
        case (.postgresql, .analyze):
            request = ("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) \(statement)", .postgresJSON)
        case (.mysql, _), (.mariadb, _):
            if isMariaDB(kind: kind, serverVersion: serverVersion) {
                request = (mode == .plan ? "EXPLAIN FORMAT=JSON \(statement)" : "ANALYZE FORMAT=JSON \(statement)", .mysqlJSON)
            } else {
                request = mode == .plan ? ("EXPLAIN FORMAT=JSON \(statement)", .mysqlJSON) : ("EXPLAIN ANALYZE \(statement)", .mysqlTree)
            }
        case (.sqlite, _):
            request = ("EXPLAIN QUERY PLAN \(statement)", .sqliteQueryPlan)
        case (.duckdb, .plan):
            request = ("EXPLAIN (FORMAT JSON) \(statement)", .duckdbJSON)
        case (.duckdb, .analyze):
            request = ("EXPLAIN (ANALYZE, FORMAT JSON) \(statement)", .duckdbJSON)
        case (.mongodb, _):
            guard isMongoExplainable(statement) else {
                throw ExplainError.unsupported("Explain works on find() and aggregate() in MongoDB, for example db.orders.find({ status: \"paid\" }).")
            }
            let verbosity = mode == .plan ? "queryPlanner" : "executionStats"
            request = ("EJSON.stringify((\(statement)).explain(\"\(verbosity)\"))", .mongoExplain)
        case (.redis, _):
            throw ExplainError.unsupported("Redis has no query plans.")
        }
        return ExplainRequest(
            kind: kind,
            mode: mode,
            statement: statement,
            sql: request.sql,
            format: request.format,
            statementWrites: writes,
            rollsBack: kind == .postgresql && mode == .analyze
        )
    }

    static func firstStatement(of text: String, kind: DatabaseKind) -> String {
        let language: QueryLanguage
        switch kind {
        case .postgresql: language = .sql(.postgresql)
        case .mysql, .mariadb: language = .sql(.mysql)
        case .sqlite: language = .sql(.sqlite)
        case .duckdb: language = .sql(.duckdb)
        case .mongodb: language = .mongo
        case .redis: language = .redis
        }
        return language.split(text).first?.text ?? text
    }

    /// Drops surrounding whitespace and trailing semicolons.
    static func trimmed(_ statement: String) -> String {
        var text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// EXPLAIN and MariaDB's ANALYZE statement, which describe another statement themselves.
    static func isExplain(_ statement: String) -> Bool {
        let first = SQLStatementSplitter.strippingComments(statement)
            .split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first.map { $0.uppercased() } ?? ""
        return ["EXPLAIN", "ANALYZE", "ANALYSE"].contains(first)
    }

    static func isMongoExplainable(_ statement: String) -> Bool {
        let code = QueryLanguage.stripJSComments(statement).trimmingCharacters(in: .whitespacesAndNewlines)
        return code.range(of: #"^db(\.[A-Za-z_$][\w$]*|\.getCollection\([^)]*\)|\[[^\]]+\])\.(find|aggregate)\s*\("#, options: .regularExpression) != nil
            || code.range(of: #"^db\.aggregate\s*\("#, options: .regularExpression) != nil
    }

    static func isMariaDB(kind: DatabaseKind, serverVersion: String) -> Bool {
        kind == .mariadb || serverVersion.localizedCaseInsensitiveContains("mariadb")
    }

    /// Compares the leading `major.minor.patch` of a version string such as `8.4.9` or `8.0.36-log`.
    static func version(_ text: String, atLeast minimum: [Int]) -> Bool {
        let numbers = text.split(whereSeparator: { !$0.isNumber && $0 != "." }).first?
            .split(separator: ".").compactMap { Int($0) } ?? []
        // An unknown version is assumed recent; the server reports an error if it is not.
        guard !numbers.isEmpty else { return true }
        for (index, required) in minimum.enumerated() {
            let actual = index < numbers.count ? numbers[index] : 0
            if actual != required { return actual > required }
        }
        return true
    }
}

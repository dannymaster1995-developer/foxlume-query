import Foundation

/// A function in the completion catalogue.
public struct SQLFunctionEntry: Sendable, Hashable {
    public var name: String
    /// Shown as the item detail, e.g. `COUNT(expr)`.
    public var signature: String
    /// One line, shown in the preview strip.
    public var summary: String?
    /// SQL-standard niladic functions (CURRENT_DATE…) insert without `()`.
    public var isNiladic: Bool

    public init(name: String, signature: String, summary: String? = nil, isNiladic: Bool = false) {
        self.name = name
        self.signature = signature
        self.summary = summary
        self.isNiladic = isNiladic
    }
}

public struct SQLOperatorEntry: Sendable, Hashable {
    public var symbol: String
    /// Types it applies to, joined for the detail (dialect operators only).
    public var types: String?
    public var summary: String?

    public init(symbol: String, types: String? = nil, summary: String? = nil) {
        self.symbol = symbol
        self.types = types
        self.summary = summary
    }
}

/// Word lists used by SQL completion (spec 6). Written for Foxlume Query; descriptions are our own.
/// Names are canonical UPPERCASE; the completion engine applies the keyword-case setting.
public enum SQLCompletionVocabulary {
    /// Statement-start keywords (spec 6.2).
    public static func statementStart(_ family: SQLDialect.Family?) -> [String] { statementStartKeywords }

    /// The generic catalogue, offered for every dialect (spec 6.3), in its dialect-neutral form.
    /// Engines should build their list with `functions(_:)` instead: on MySQL it fixes `USER` and `SESSION_USER`,
    /// which this list marks niladic but MySQL only accepts with `()`.
    public static var genericFunctions: [SQLFunctionEntry] { genericCatalogue }

    /// Extra functions of one dialect, sorted A–Z, without names already in the generic catalogue.
    /// Engines should use `functions(_:)`, which appends these to the dialect-adjusted generic catalogue.
    public static func dialectFunctions(_ family: SQLDialect.Family?) -> [SQLFunctionEntry] {
        switch family {
        case .mysql: return mysqlCatalogue
        case .postgresql: return postgresqlCatalogue
        case .sqlite: return sqliteCatalogue
        case .duckdb: return duckdbCatalogue
        case nil: return []
        }
    }

    /// Everything completion offers as functions for one dialect: the generic catalogue, then the dialect's extras.
    /// This is the list engines should use. MySQL only accepts `USER()` and `SESSION_USER()` with parentheses, so
    /// those lose their niladic flag there (bare `USER` is an unknown column on MySQL 8.4).
    public static func functions(_ family: SQLDialect.Family?) -> [SQLFunctionEntry] {
        guard family == .mysql else { return genericCatalogue + dialectFunctions(family) }
        let generic = genericCatalogue.map { entry -> SQLFunctionEntry in
            guard mysqlParenthesizedNiladics.contains(entry.name) else { return entry }
            return SQLFunctionEntry(name: entry.name, signature: entry.name + "()", summary: entry.summary)
        }
        return generic + mysqlCatalogue
    }

    /// `=`, `<>`, `!=`, `<`, `>`, `<=`, `>=`, `<=>` (spec 6.4).
    public static var genericOperators: [SQLOperatorEntry] { genericOperatorList }

    /// PostgreSQL's operators (spec 6.4). `IS NULL` and `IS NOT NULL` are also WHERE keywords; they stay here because
    /// ON and CASE offer only `IS` and `NULL`, so an engine appending these to WHERE should skip a symbol that already
    /// appears there as a keyword label.
    public static func dialectOperators(_ family: SQLDialect.Family?) -> [SQLOperatorEntry] {
        family == .postgresql ? postgresqlOperatorList : []
    }

    /// Data types for CREATE TABLE / column definitions and casts (spec 6.5), sorted A–Z;
    /// the fallback list without a dialect.
    public static func dataTypes(_ family: SQLDialect.Family?) -> [String] {
        switch family {
        case .mysql: return mysqlTypes
        case .postgresql: return postgresqlTypes
        case .sqlite: return sqliteTypes
        case .duckdb: return duckdbTypes
        case nil: return fallbackTypes
        }
    }

    /// Types offered after `::`: lowercased, sorted A–Z, without the ones a bare cast rejects, such as `serial`
    /// (column-only) or DuckDB's `struct` (needs parameters).
    public static func castTargetTypes(_ family: SQLDialect.Family?) -> [String] {
        dataTypes(family)
            .filter { !castExcludedTypes.contains($0) }
            .map { $0.lowercased() }
            .sorted()
    }

    /// Options after `CREATE TABLE … )` (spec 6.6); nil uses the generic fallback.
    public static func tableOptions(_ family: SQLDialect.Family?) -> [String]? {
        switch family {
        case .mysql: return ["ENGINE=InnoDB", "DEFAULT CHARSET=utf8mb4", "COLLATE=utf8mb4_unicode_ci", "AUTO_INCREMENT=", "COMMENT=", "ROW_FORMAT="]
        case .postgresql: return ["INHERITS", "PARTITION BY", "TABLESPACE", "WITH", "WITHOUT OIDS"]
        case .sqlite: return ["WITHOUT ROWID", "STRICT"]
        case .duckdb: return []
        case nil: return nil
        }
    }

    /// Short help for common keywords and phrases, keyed by the canonical UPPERCASE text (spec 4.2).
    public static var keywordDocumentation: [String: String] { keywordHelp }

    /// Every single-word keyword, for the as-you-type case rewriter (spec 5.4).
    public static var masterKeywords: Set<String> { masterKeywordSet }

    /// UPPERCASE words the engine rejects as a bare table or column name, so an inserted name equal to one of them
    /// needs quoting (spec A.2). Narrower than `masterKeywords`: `date`, `name` or `comment` stay bare.
    /// Without a dialect, the words every engine reserves.
    public static func reservedWords(_ family: SQLDialect.Family?) -> Set<String> {
        switch family {
        case .mysql: return mysqlReservedWords
        case .postgresql: return postgresqlReservedWords
        case .sqlite: return sqliteReservedWords
        case .duckdb: return duckdbReservedWords
        case nil: return commonReservedWords
        }
    }

    // MARK: - Function tables

    static let mysqlCatalogue = dialectCatalogue(mysqlFunctionTable)
    static let postgresqlCatalogue = dialectCatalogue(postgresqlFunctionTable, niladic: ["CURRENT_CATALOG", "CURRENT_ROLE"])
    static let sqliteCatalogue = dialectCatalogue(sqliteFunctionTable)
    static let duckdbCatalogue = dialectCatalogue(duckdbFunctionTable)

    static let mysqlParenthesizedNiladics: Set<String> = ["USER", "SESSION_USER"]

    /// Builds a dialect list from a table: sorted A–Z, minus anything the generic catalogue already has (spec 6.3).
    static func dialectCatalogue(_ table: String, niladic: Set<String> = []) -> [SQLFunctionEntry] {
        let generic = Set(genericCatalogue.map { $0.name.uppercased() })
        var seen = Set<String>()
        return parseFunctionTable(table, niladic: niladic)
            .filter { !generic.contains($0.name) && seen.insert($0.name).inserted }
            .sorted { $0.name < $1.name }
    }

    /// One function per line: `name`, `name(args)`, either optionally followed by ` | summary`.
    /// A bare name gets the `NAME(…)` signature; names in `niladic` are called without parentheses.
    static func parseFunctionTable(_ table: String, niladic: Set<String> = []) -> [SQLFunctionEntry] {
        table.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.components(separatedBy: " | ")
            let head = parts[0].trimmingCharacters(in: .whitespaces)
            let paren = head.firstIndex(of: "(")
            let name = String(head[..<(paren ?? head.endIndex)]).uppercased()
            let summary = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
            if niladic.contains(name) {
                return SQLFunctionEntry(name: name, signature: name, summary: summary, isNiladic: true)
            }
            let arguments = paren.map { String(head[$0...]) } ?? "(…)"
            return SQLFunctionEntry(name: name, signature: name + arguments, summary: summary)
        }
    }
}

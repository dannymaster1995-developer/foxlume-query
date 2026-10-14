import Foundation

public enum FilterOperator: String, Codable, CaseIterable, Sendable, Identifiable {
    case equals
    case notEquals
    case greaterThan
    case greaterOrEqual
    case lessThan
    case lessOrEqual
    case contains
    case notContains
    case startsWith
    case endsWith
    case isNull
    case isNotNull
    case inList
    case notInList
    case between
    case notBetween
    case regex
    case isEmpty
    case isNotEmpty

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .equals: return "="
        case .notEquals: return "≠"
        case .greaterThan: return ">"
        case .greaterOrEqual: return "≥"
        case .lessThan: return "<"
        case .lessOrEqual: return "≤"
        case .contains: return "contains"
        case .notContains: return "does not contain"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        case .isNull: return "is NULL"
        case .isNotNull: return "is not NULL"
        case .inList: return "in list"
        case .notInList: return "not in list"
        case .between: return "between"
        case .notBetween: return "not between"
        case .regex: return "matches regex"
        case .isEmpty: return "is empty"
        case .isNotEmpty: return "is not empty"
        }
    }

    /// The order of the operator menu: comparisons, text matching, ranges and lists, then emptiness.
    public static let menuOrder: [FilterOperator] = [
        .equals, .notEquals, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual,
        .contains, .notContains, .startsWith, .endsWith, .regex,
        .between, .notBetween, .inList, .notInList,
        .isEmpty, .isNotEmpty, .isNull, .isNotNull,
    ]

    public var needsValue: Bool {
        switch self {
        case .isNull, .isNotNull, .isEmpty, .isNotEmpty: return false
        default: return true
        }
    }

    /// BETWEEN and NOT BETWEEN take an upper bound in `secondValue`.
    public var needsSecondValue: Bool { self == .between || self == .notBetween }

    /// Text matching that ignores case unless the rule asks to match it. `=` and lists keep the engine's own rules.
    public var supportsMatchCase: Bool {
        switch self {
        case .contains, .notContains, .startsWith, .endsWith, .regex: return true
        default: return false
        }
    }
}

/// How the enabled column rules combine. A raw WHERE condition is always added with AND.
public enum FilterLogic: String, Codable, CaseIterable, Sendable {
    case and
    case or
}

public struct FilterRule: Hashable, Codable, Sendable, Identifiable {
    public var id = UUID()
    public var column: String
    public var op: FilterOperator
    public var value: String
    /// Upper bound of BETWEEN and NOT BETWEEN.
    public var secondValue: String
    public var isEnabled: Bool
    /// Text operators compare case-sensitively when set; off by default, as before the option existed.
    public var matchCase: Bool

    public init(column: String, op: FilterOperator = .equals, value: String = "", secondValue: String = "", isEnabled: Bool = true, matchCase: Bool = false) {
        self.column = column
        self.op = op
        self.value = value
        self.secondValue = secondValue
        self.isEnabled = isEnabled
        self.matchCase = matchCase
    }

    private enum CodingKeys: String, CodingKey {
        case id, column, op, value, secondValue, isEnabled, matchCase
    }

    /// Fields added later decode with their defaults, so older saved rules still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        column = try container.decode(String.self, forKey: .column)
        op = try container.decode(FilterOperator.self, forKey: .op)
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        secondValue = try container.decodeIfPresent(String.self, forKey: .secondValue) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        matchCase = try container.decodeIfPresent(Bool.self, forKey: .matchCase) ?? false
    }

    /// SQL condition for this rule. Values are always emitted as quoted literals.
    public func sql(dialect: SQLDialect) -> String? {
        guard isEnabled, !column.isEmpty else { return nil }
        let name = dialect.quoteIdentifier(column)
        let caseSensitive = matchCase && op.supportsMatchCase
        switch op {
        case .equals: return "\(name) = \(dialect.quoteString(value))"
        case .notEquals: return "\(name) <> \(dialect.quoteString(value))"
        case .greaterThan: return "\(name) > \(dialect.quoteString(value))"
        case .greaterOrEqual: return "\(name) >= \(dialect.quoteString(value))"
        case .lessThan: return "\(name) < \(dialect.quoteString(value))"
        case .lessOrEqual: return "\(name) <= \(dialect.quoteString(value))"
        case .contains: return dialect.textMatch(name, value, at: .anywhere, negate: false, matchCase: caseSensitive)
        case .notContains: return dialect.textMatch(name, value, at: .anywhere, negate: true, matchCase: caseSensitive)
        case .startsWith: return dialect.textMatch(name, value, at: .start, negate: false, matchCase: caseSensitive)
        case .endsWith: return dialect.textMatch(name, value, at: .end, negate: false, matchCase: caseSensitive)
        case .isNull: return "\(name) IS NULL"
        case .isNotNull: return "\(name) IS NOT NULL"
        case .inList, .notInList:
            return listCondition(name, dialect: dialect, negate: op == .notInList)
        case .between, .notBetween:
            guard !value.isEmpty, !secondValue.isEmpty else { return nil }
            let not = op == .notBetween ? "NOT " : ""
            return "\(name) \(not)BETWEEN \(dialect.quoteString(value)) AND \(dialect.quoteString(secondValue))"
        case .regex:
            guard !value.isEmpty else { return nil }
            return dialect.regexMatch(name, pattern: value, matchCase: caseSensitive)
        case .isEmpty: return "(\(name) IS NULL OR \(dialect.textCast(name)) = '')"
        case .isNotEmpty: return "(\(name) IS NOT NULL AND \(dialect.textCast(name)) <> '')"
        }
    }

    /// The comma-separated items of IN / NOT IN. An unquoted `NULL` item matches NULL, which `IN (NULL)` never does.
    public static func listItems(_ value: String) -> (values: [String], hasNull: Bool) {
        let items = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let values = items.filter { $0.uppercased() != "NULL" }
        return (values, values.count != items.count)
    }

    private func listCondition(_ name: String, dialect: SQLDialect, negate: Bool) -> String? {
        let (values, hasNull) = Self.listItems(value)
        let list = values.isEmpty ? nil : "\(name) \(negate ? "NOT IN" : "IN") (\(values.map(dialect.quoteString).joined(separator: ", ")))"
        let null = hasNull ? "\(name) IS \(negate ? "NOT " : "")NULL" : nil
        switch (list, null) {
        case let (list?, null?): return "(\(list) \(negate ? "AND" : "OR") \(null))"
        case let (list?, nil): return list
        case let (nil, null?): return null
        case (nil, nil): return nil
        }
    }

    /// Escape LIKE wildcards with backslash, the default escape character on PostgreSQL and MySQL.
    static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

public struct SortKey: Hashable, Codable, Sendable {
    public var column: String
    public var ascending: Bool

    public init(column: String, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

/// The SELECT behind a table tab: filters, sort and one page of rows.
public struct TableQuery: Hashable, Sendable {
    public var table: TableRef
    public var filters: [FilterRule]
    /// Whether the enabled `filters` must all match or any one of them.
    public var filterLogic: FilterLogic
    /// Free-form WHERE expression typed by the user, combined with `filters` using AND.
    public var rawWhere: String
    /// Every key in order; the first one sorts first.
    public var sort: [SortKey]
    public var pageSize: Int
    public var page: Int

    public init(table: TableRef, filters: [FilterRule] = [], filterLogic: FilterLogic = .and, rawWhere: String = "", sort: [SortKey] = [], pageSize: Int = 500, page: Int = 0) {
        self.table = table
        self.filters = filters
        self.filterLogic = filterLogic
        self.rawWhere = rawWhere
        self.sort = sort
        self.pageSize = pageSize
        self.page = page
    }

    public func whereClause(dialect: SQLDialect) -> String? {
        let rules = filters.compactMap { $0.sql(dialect: dialect) }
        var conditions = rules
        if filterLogic == .or, rules.count > 1 {
            conditions = ["(" + rules.joined(separator: " OR ") + ")"]
        }
        let raw = rawWhere.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { conditions.append("(\(raw))") }
        return conditions.isEmpty ? nil : conditions.joined(separator: " AND ")
    }

    public func selectSQL(dialect: SQLDialect) -> String {
        var sql = "SELECT * FROM \(dialect.qualifiedName(table))"
        if let condition = whereClause(dialect: dialect) { sql += " WHERE \(condition)" }
        if !sort.isEmpty {
            sql += " ORDER BY " + sort.map { "\(dialect.quoteIdentifier($0.column)) \($0.ascending ? "ASC" : "DESC")" }.joined(separator: ", ")
        }
        sql += " " + dialect.limitClause(limit: pageSize, offset: page * pageSize)
        return sql
    }

    public func countSQL(dialect: SQLDialect) -> String {
        var sql = "SELECT COUNT(*) FROM \(dialect.qualifiedName(table))"
        if let condition = whereClause(dialect: dialect) { sql += " WHERE \(condition)" }
        return sql
    }
}

extension TableQuery {
    /// `(col1 LIKE '%text%' OR col2 …)` for "Search All Rows": case-insensitive, with LIKE wildcards in `text`
    /// matched literally, every column compared as text.
    public static func anyColumnContains(_ text: String, columns: [String], dialect: SQLDialect) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let pattern = dialect.quoteString("%" + escaped + "%")
        let escape = dialect.quoteString("\\")
        let like = dialect.caseInsensitiveLike
        let conditions = columns.map { "LOWER(\(dialect.textCast(dialect.quoteIdentifier($0)))) \(like) LOWER(\(pattern)) ESCAPE \(escape)" }
        return "(" + conditions.joined(separator: " OR ") + ")"
    }
}

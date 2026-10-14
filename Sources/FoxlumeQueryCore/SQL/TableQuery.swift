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
        }
    }

    public var needsValue: Bool { self != .isNull && self != .isNotNull }
}

public struct FilterRule: Hashable, Codable, Sendable, Identifiable {
    public var id = UUID()
    public var column: String
    public var op: FilterOperator
    public var value: String
    public var isEnabled: Bool

    public init(column: String, op: FilterOperator = .equals, value: String = "", isEnabled: Bool = true) {
        self.column = column
        self.op = op
        self.value = value
        self.isEnabled = isEnabled
    }

    /// SQL condition for this rule. Values are always emitted as quoted literals.
    public func sql(dialect: SQLDialect) -> String? {
        guard isEnabled, !column.isEmpty else { return nil }
        let name = dialect.quoteIdentifier(column)
        switch op {
        case .equals: return "\(name) = \(dialect.quoteString(value))"
        case .notEquals: return "\(name) <> \(dialect.quoteString(value))"
        case .greaterThan: return "\(name) > \(dialect.quoteString(value))"
        case .greaterOrEqual: return "\(name) >= \(dialect.quoteString(value))"
        case .lessThan: return "\(name) < \(dialect.quoteString(value))"
        case .lessOrEqual: return "\(name) <= \(dialect.quoteString(value))"
        case .contains: return like(name, "%" + Self.escapeLike(value) + "%", dialect: dialect, negate: false)
        case .notContains: return like(name, "%" + Self.escapeLike(value) + "%", dialect: dialect, negate: true)
        case .startsWith: return like(name, Self.escapeLike(value) + "%", dialect: dialect, negate: false)
        case .endsWith: return like(name, "%" + Self.escapeLike(value), dialect: dialect, negate: false)
        case .isNull: return "\(name) IS NULL"
        case .isNotNull: return "\(name) IS NOT NULL"
        case .inList:
            let items = value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !items.isEmpty else { return nil }
            return "\(name) IN (\(items.map(dialect.quoteString).joined(separator: ", ")))"
        }
    }

    private func like(_ name: String, _ pattern: String, dialect: SQLDialect, negate: Bool) -> String {
        let not = negate ? "NOT " : ""
        let escape = dialect.family == .sqlite ? " ESCAPE '\\'" : ""
        return "\(dialect.textCast(name)) \(not)\(dialect.caseInsensitiveLike) \(dialect.quoteString(pattern))\(escape)"
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
    /// Free-form WHERE expression typed by the user, combined with `filters` using AND.
    public var rawWhere: String
    public var sort: [SortKey]
    public var pageSize: Int
    public var page: Int

    public init(table: TableRef, filters: [FilterRule] = [], rawWhere: String = "", sort: [SortKey] = [], pageSize: Int = 500, page: Int = 0) {
        self.table = table
        self.filters = filters
        self.rawWhere = rawWhere
        self.sort = sort
        self.pageSize = pageSize
        self.page = page
    }

    public func whereClause(dialect: SQLDialect) -> String? {
        var conditions = filters.compactMap { $0.sql(dialect: dialect) }
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

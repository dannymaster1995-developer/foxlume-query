import Foundation

/// Quoting and syntax rules for one engine. All generated SQL goes through here.
public struct SQLDialect: Sendable, Hashable {
    public enum Family: Sendable, Hashable {
        case postgresql
        case mysql
        case sqlite
        case duckdb
    }

    public var family: Family
    /// MySQL treats backslash as an escape inside string literals unless NO_BACKSLASH_ESCAPES is set.
    public var backslashEscapes: Bool

    public init(family: Family, backslashEscapes: Bool = false) {
        self.family = family
        self.backslashEscapes = backslashEscapes
    }

    public static let postgresql = SQLDialect(family: .postgresql)
    public static let mysql = SQLDialect(family: .mysql, backslashEscapes: true)
    public static let sqlite = SQLDialect(family: .sqlite)
    public static let duckdb = SQLDialect(family: .duckdb)

    public func quoteIdentifier(_ identifier: String) -> String {
        switch family {
        case .mysql:
            return "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
        case .postgresql, .sqlite, .duckdb:
            return "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    public func qualifiedName(_ table: TableRef) -> String {
        if let schema = table.schema, !schema.isEmpty {
            return quoteIdentifier(schema) + "." + quoteIdentifier(table.name)
        }
        return quoteIdentifier(table.name)
    }

    public func quoteString(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "'", with: "''")
        if backslashEscapes {
            escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "''")
                .replacingOccurrences(of: "\0", with: "\\0")
        }
        return "'" + escaped + "'"
    }

    public func literal(_ value: CellValue) -> String {
        switch value {
        case .null, .missing:
            return "NULL"
        case .expression(let sql):
            return sql
        case .text(let string):
            return quoteString(string)
        case .bytes(let data):
            switch family {
            case .postgresql: return "decode('\(data.hexString)', 'hex')"
            case .mysql: return "X'\(data.hexString)'"
            case .sqlite: return "X'\(data.hexString)'"
            case .duckdb: return "from_hex('\(data.hexString)')"
            }
        }
    }

    public func limitClause(limit: Int, offset: Int) -> String {
        offset > 0 ? "LIMIT \(limit) OFFSET \(offset)" : "LIMIT \(limit)"
    }

    /// Statement that starts a transaction.
    public var beginStatement: String {
        family == .mysql ? "START TRANSACTION" : "BEGIN"
    }

    /// LIKE operator that ignores case on every engine.
    public var caseInsensitiveLike: String {
        family == .postgresql || family == .duckdb ? "ILIKE" : "LIKE"
    }

    /// Cast an expression to text, so LIKE works on any column type.
    public func textCast(_ expression: String) -> String {
        switch family {
        case .postgresql: return "\(expression)::text"
        case .mysql: return "CAST(\(expression) AS CHAR)"
        case .sqlite: return "CAST(\(expression) AS TEXT)"
        case .duckdb: return "CAST(\(expression) AS VARCHAR)"
        }
    }
}

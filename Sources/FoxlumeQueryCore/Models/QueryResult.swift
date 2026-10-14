import Foundation

public enum CellValue: Hashable, Sendable {
    case null
    case text(String)
    /// Bytes that are not valid UTF-8 (BLOB / BINARY columns).
    case bytes(Data)
    /// The field does not exist in this document (MongoDB), which is different from a NULL value.
    case missing
    /// SQL written into a grid edit as is, such as `DEFAULT` or `CURRENT_TIMESTAMP`. Only produced by edits, never read
    /// from a server.
    case expression(String)

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// NULL or missing: the cell holds no value.
    public var isAbsent: Bool { self == .null || self == .missing }

    /// The value as text for display and editing. Bytes render as a hex literal.
    public var displayString: String {
        switch self {
        case .null: return "NULL"
        case .missing: return ""
        case .text(let string): return string
        case .bytes(let data): return "0x" + data.hexString
        case .expression(let sql): return sql
        }
    }

    public var textValue: String? {
        switch self {
        case .null, .missing: return nil
        case .text(let string): return string
        case .bytes(let data): return "0x" + data.hexString
        case .expression(let sql): return sql
        }
    }

    /// Decode wire bytes: UTF-8 text when valid, raw bytes otherwise.
    public static func decode(_ data: Data) -> CellValue {
        if let string = String(data: data, encoding: .utf8) { return .text(string) }
        return .bytes(data)
    }
}

public struct ResultColumn: Hashable, Sendable {
    public var name: String
    /// Server type name, for example `int4`, `VARCHAR`, `TEXT`.
    public var typeName: String
    public var isNumeric: Bool
    /// Source table when the server reports it.
    public var tableName: String?

    public init(name: String, typeName: String = "", isNumeric: Bool = false, tableName: String? = nil) {
        self.name = name
        self.typeName = typeName
        self.isNumeric = isNumeric
        self.tableName = tableName
    }
}

/// The outcome of one SQL statement.
public struct StatementResult: Sendable {
    public var columns: [ResultColumn]
    public var rows: [[CellValue]]
    /// Rows changed by INSERT / UPDATE / DELETE, when the server reports it.
    public var affectedRows: Int?
    /// Command tag or server message, for example `UPDATE 3`.
    public var message: String?
    /// True when the row limit cut the result short.
    public var truncated: Bool
    public var elapsed: TimeInterval

    public init(
        columns: [ResultColumn] = [],
        rows: [[CellValue]] = [],
        affectedRows: Int? = nil,
        message: String? = nil,
        truncated: Bool = false,
        elapsed: TimeInterval = 0
    ) {
        self.columns = columns
        self.rows = rows
        self.affectedRows = affectedRows
        self.message = message
        self.truncated = truncated
        self.elapsed = elapsed
    }

    public var hasResultSet: Bool { !columns.isEmpty }
}

public extension Data {
    var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

import Foundation

/// File formats for exporting whole tables.
public enum TableExportFormat: String, CaseIterable, Sendable, Identifiable, Codable {
    case csv
    case json
    case ndjson
    case sql

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .csv: return "CSV"
        case .json: return "JSON"
        case .ndjson: return "NDJSON"
        case .sql: return "SQL"
        }
    }

    public var summary: String {
        switch self {
        case .csv: return "Comma-separated values with a header row, one file per table."
        case .json: return "An array of row objects per table."
        case .ndjson: return "One JSON object per line, one file per table."
        case .sql: return "CREATE TABLE and INSERT statements that rebuild the tables."
        }
    }

    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .json: return "json"
        case .ndjson: return "ndjson"
        case .sql: return "sql"
        }
    }

    /// Whether several tables can share one file in this format.
    public var supportsCombinedFile: Bool { self == .sql || self == .json }
}

public enum CSVQuoting: String, CaseIterable, Sendable, Identifiable, Codable {
    /// Only fields holding the delimiter, a quote, a line break or a tab, and empty strings.
    case asNeeded
    case always

    public var id: String { rawValue }
    public var title: String { self == .asNeeded ? "As Needed" : "Always" }
}

public enum CSVLineEnding: String, CaseIterable, Sendable, Identifiable, Codable {
    case lf
    case crlf

    public var id: String { rawValue }
    public var title: String { self == .lf ? "LF (macOS, Linux)" : "CRLF (Windows)" }
    public var text: String { self == .lf ? "\n" : "\r\n" }
}

/// Every option of the Export Tables sheet. Codable so the last choices can be remembered.
public struct TableExportOptions: Hashable, Sendable, Codable {
    public var format: TableExportFormat = .csv
    /// One file per table instead of one combined file (always the case for CSV and NDJSON).
    public var filePerTable = false

    // SQL
    public var rowsPerInsert = 500
    /// A statement is closed early when it grows past this many bytes, so huge rows do not make huge statements.
    public var maxStatementBytes = 1 << 20
    public var compress = false
    /// MySQL: leave the `AUTO_INCREMENT=n` table option out of CREATE TABLE.
    public var stripAutoIncrement = true
    /// MySQL: leave `DEFINER=` out of view definitions, so they import under any account.
    public var stripDefiner = true

    // CSV
    public var csvDelimiter: CSVDelimiter = .comma
    public var csvHeader = true
    /// NULL becomes an empty field; off writes the text NULL.
    public var csvNullAsEmpty = true
    public var csvQuoting: CSVQuoting = .asNeeded
    public var csvLineEnding: CSVLineEnding = .lf
    public var csvLineBreaksAsSpaces = false
    public var csvByteOrderMark = false
    /// Prefixes text that a spreadsheet would run as a formula (`=`, `+`, `-`, `@`) with an apostrophe.
    public var csvProtectFormulas = false

    // JSON
    public var jsonPrettyPrint = true
    public var jsonIncludeNulls = true

    /// Rows read per round trip.
    public var fetchSize = 1000

    public init() {}

    /// Whether `count` tables end up in separate files.
    public func writesFilePerTable(tableCount: Int) -> Bool {
        guard tableCount > 1 else { return false }
        return filePerTable || !format.supportsCombinedFile
    }

    public func fileExtension() -> String {
        format.fileExtension + (format == .sql && compress ? ".gz" : "")
    }
}

/// What to do with one table in a SQL export, and which rows to read.
public struct TableExportItem: Hashable, Sendable {
    public var table: TableRef
    public var kind: TableKind
    public var includeStructure: Bool
    public var includeDrop: Bool
    public var includeData: Bool
    /// Extra condition for the rows, without the WHERE keyword.
    public var whereClause: String
    public var rowLimit: Int?

    public init(table: TableRef, kind: TableKind = .table, includeStructure: Bool = true, includeDrop: Bool = true, includeData: Bool = true, whereClause: String = "", rowLimit: Int? = nil) {
        self.table = table
        self.kind = kind
        self.includeStructure = includeStructure
        self.includeDrop = includeDrop
        self.includeData = includeData
        self.whereClause = whereClause
        self.rowLimit = rowLimit
    }

    /// Views and other derived objects have no rows of their own to insert in a SQL dump.
    public var isView: Bool { kind == .view || kind == .materializedView }

    /// A WHERE condition fit for appending to a query: a trailing `;` is dropped, any other `;` is refused,
    /// because it could smuggle a second statement into the export.
    public static func validatedCondition(_ text: String) throws -> String {
        var condition = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while condition.hasSuffix(";") {
            condition.removeLast()
            condition = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if hasUnquotedSemicolon(SQLStatementSplitter.strippingComments(condition)) {
            throw DatabaseError.unsupported("A row filter can hold only one condition; remove the semicolon.")
        }
        return condition
    }

    private static func hasUnquotedSemicolon(_ code: String) -> Bool {
        let units = Array(code.utf16)
        var index = 0
        while index < units.count {
            let c = units[index]
            if c == 0x27 || c == 0x22 || c == 0x60 {
                index = SQLStatementSplitter.skipQuoted(units, from: index, quote: c, backslash: false)
                continue
            }
            if c == 0x3B { return true }
            index += 1
        }
        return false
    }
}

/// Where the export goes: one file, or a folder that receives one file per table.
public enum TableExportDestination: Hashable, Sendable {
    case file(URL)
    case directory(URL)
}

/// Reported while an export runs. Row totals are nil when counting was skipped or failed.
public struct TableExportProgress: Sendable, Equatable {
    public var tableIndex: Int
    public var tableCount: Int
    public var table: TableRef
    public var tableRows: Int
    public var tableTotal: Int?
    /// Rows written across all tables so far, and the counted total for all of them.
    public var totalRows: Int
    public var grandTotal: Int?
}

public struct TableExportReport: Sendable {
    public var files: [URL]
    public var tables: [(table: TableRef, rows: Int)]
    public var totalRows: Int
    public var warnings: [String]
    public var elapsed: TimeInterval
}

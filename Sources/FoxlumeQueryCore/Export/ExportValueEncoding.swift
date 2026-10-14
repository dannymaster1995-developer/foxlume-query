import Foundation

/// What the writers need to know about one result column.
struct ExportColumn: Hashable, Sendable {
    var name: String
    var isNumeric: Bool
    var isBoolean: Bool

    init(name: String, isNumeric: Bool = false, isBoolean: Bool = false) {
        self.name = name
        self.isNumeric = isNumeric
        self.isBoolean = isBoolean
    }

    init(_ column: ResultColumn) {
        name = column.name
        isNumeric = column.isNumeric
        let type = column.typeName.lowercased()
        isBoolean = type == "bool" || type == "boolean"
    }
}

/// Turns cell values into CSV fields, JSON values and SQL literals.
enum ExportValueEncoding {
    // MARK: CSV

    static func csvRow(_ row: [CellValue], columns: [ExportColumn], options: TableExportOptions) -> String {
        var fields: [String] = []
        fields.reserveCapacity(columns.count)
        for (index, column) in columns.enumerated() {
            fields.append(csvField(index < row.count ? row[index] : .null, column: column, options: options))
        }
        return fields.joined(separator: options.csvDelimiter.rawValue) + options.csvLineEnding.text
    }

    static func csvHeader(_ columns: [ExportColumn], options: TableExportOptions) -> String {
        columns.map { csvQuoted($0.name, options: options, force: false) }.joined(separator: options.csvDelimiter.rawValue) + options.csvLineEnding.text
    }

    // Values are matched with `if case` rather than an exhaustive switch, so cases added to CellValue for grid
    // edits fall through to their text.
    static func csvField(_ value: CellValue, column: ExportColumn, options: TableExportOptions) -> String {
        if value.isAbsent {
            // Left unquoted, so a NULL reads differently from the text "NULL" or an empty string.
            return options.csvNullAsEmpty ? "" : "NULL"
        }
        if case .bytes(let data) = value {
            return "0x" + data.hexString.uppercased()
        }
        var text = value.textValue ?? ""
        if options.csvLineBreaksAsSpaces {
            text = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }
        var force = false
        if options.csvProtectFormulas, !column.isNumeric, let first = text.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) {
            text = "'" + text
            force = true
        }
        return csvQuoted(text, options: options, force: force)
    }

    /// Quotes when the quoting mode or the content asks for it. Empty strings are always quoted (`""`),
    /// which keeps them apart from NULL.
    static func csvQuoted(_ text: String, options: TableExportOptions, force: Bool) -> String {
        let delimiter = options.csvDelimiter.rawValue.unicodeScalars.first ?? ","
        let needsQuotes = force || options.csvQuoting == .always || text.isEmpty || text.unicodeScalars.contains {
            $0 == delimiter || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\t"
        }
        guard needsQuotes else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: JSON

    /// One row as a JSON object on a single line. `spaced` adds a space after `:` and `,` for readability.
    static func jsonObject(_ row: [CellValue], columns: [ExportColumn], options: TableExportOptions, spaced: Bool) -> String {
        var members: [String] = []
        members.reserveCapacity(columns.count)
        for (index, column) in columns.enumerated() {
            let value = index < row.count ? row[index] : .missing
            if value == .missing || (value == .null && !options.jsonIncludeNulls) { continue }
            members.append(ResultExporter.jsonString(column.name) + (spaced ? ": " : ":") + jsonValue(value, column: column))
        }
        return "{" + members.joined(separator: spaced ? ", " : ",") + "}"
    }

    static func jsonValue(_ value: CellValue, column: ExportColumn) -> String {
        if value.isAbsent { return "null" }
        if case .bytes(let data) = value {
            return ResultExporter.jsonString(data.base64EncodedString())
        }
        let text = value.textValue ?? ""
        if column.isNumeric, ResultExporter.isJSONNumber(text) { return text }
        if column.isBoolean {
            switch text.lowercased() {
            case "t", "true": return "true"
            case "f", "false": return "false"
            default: break
            }
        }
        return ResultExporter.jsonString(text)
    }

    // MARK: SQL

    static func sqlLiteral(_ value: CellValue, column: ExportColumn, dialect: SQLDialect) -> String {
        if case .text(let text) = value, column.isNumeric, ResultExporter.isJSONNumber(text) {
            return text
        }
        return dialect.literal(value)
    }

    static func sqlTuple(_ row: [CellValue], columns: [(index: Int, column: ExportColumn)], dialect: SQLDialect) -> String {
        "(" + columns.map { entry in
            sqlLiteral(entry.index < row.count ? row[entry.index] : .null, column: entry.column, dialect: dialect)
        }.joined(separator: ", ") + ")"
    }
}

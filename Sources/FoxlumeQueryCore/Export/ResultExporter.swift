import Foundation

public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case csv
    case tsv
    case json
    case sqlInsert
    case markdown

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .csv: return "CSV"
        case .tsv: return "TSV"
        case .json: return "JSON"
        case .sqlInsert: return "SQL INSERT"
        case .markdown: return "Markdown"
        }
    }

    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .json: return "json"
        case .sqlInsert: return "sql"
        case .markdown: return "md"
        }
    }
}

public enum ResultExporter {
    public static func export(
        columns: [ResultColumn],
        rows: [[CellValue]],
        format: ExportFormat,
        includeHeader: Bool = true,
        tableName: String = "table_name",
        dialect: SQLDialect = .postgresql
    ) -> String {
        switch format {
        case .csv: return delimited(columns: columns, rows: rows, separator: ",", includeHeader: includeHeader)
        case .tsv: return delimited(columns: columns, rows: rows, separator: "\t", includeHeader: includeHeader)
        case .json: return json(columns: columns, rows: rows)
        case .sqlInsert: return inserts(columns: columns, rows: rows, tableName: tableName, dialect: dialect)
        case .markdown: return markdown(columns: columns, rows: rows)
        }
    }

    static func delimited(columns: [ResultColumn], rows: [[CellValue]], separator: Character, includeHeader: Bool) -> String {
        func field(_ text: String) -> String {
            let needsQuotes = text.contains(separator) || text.contains("\"") || text.contains("\n") || text.contains("\r")
            guard needsQuotes else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines: [String] = []
        if includeHeader {
            lines.append(columns.map { field($0.name) }.joined(separator: String(separator)))
        }
        for row in rows {
            lines.append(row.map { $0.isAbsent ? "" : field($0.displayString) }.joined(separator: String(separator)))
        }
        return lines.joined(separator: "\r\n") + (lines.isEmpty ? "" : "\r\n")
    }

    static func json(columns: [ResultColumn], rows: [[CellValue]]) -> String {
        var objects: [String] = []
        for row in rows {
            var fields: [String] = []
            for (index, column) in columns.enumerated() where index < row.count && row[index] != .missing {
                fields.append("    \(jsonString(column.name)): \(jsonValue(row[index], numeric: column.isNumeric))")
            }
            objects.append("  {\n" + fields.joined(separator: ",\n") + "\n  }")
        }
        return "[\n" + objects.joined(separator: ",\n") + "\n]\n"
    }

    static func jsonValue(_ value: CellValue, numeric: Bool) -> String {
        switch value {
        case .null, .missing:
            return "null"
        case .bytes(let data):
            return jsonString(data.base64EncodedString())
        case .text(let text):
            if numeric, isJSONNumber(text) { return text }
            return jsonString(text)
        case .expression(let sql):
            return jsonString(sql)
        }
    }

    static func isJSONNumber(_ text: String) -> Bool {
        text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
    }

    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    static func inserts(columns: [ResultColumn], rows: [[CellValue]], tableName: String, dialect: SQLDialect) -> String {
        let names = columns.map { dialect.quoteIdentifier($0.name) }.joined(separator: ", ")
        let table = dialect.quoteIdentifier(tableName)
        let encodings = columns.map(ExportColumn.init)
        return rows.map { row in
            let values = row.enumerated().map { index, value -> String in
                index < encodings.count ? ExportValueEncoding.sqlLiteral(value, column: encodings[index], dialect: dialect) : dialect.literal(value)
            }
            return "INSERT INTO \(table) (\(names)) VALUES (\(values.joined(separator: ", ")));"
        }.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }

    static func markdown(columns: [ResultColumn], rows: [[CellValue]]) -> String {
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        var lines = ["| " + columns.map { cell($0.name) }.joined(separator: " | ") + " |"]
        lines.append("| " + columns.map { $0.isNumeric ? "---:" : "---" }.joined(separator: " | ") + " |")
        for row in rows {
            lines.append("| " + row.map { cell($0.displayString) }.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

import Foundation

/// Which editor a table cell gets beyond the plain text field: a check box for booleans, a date picker for dates and
/// times, a list for enum labels. Every one of them still accepts typed text.
public enum CellEditorKind: Hashable, Sendable {
    case text
    case boolean(BooleanStyle)
    case temporal(TemporalKind)
    /// Enum labels in their declared order.
    case choice([String])

    /// Picks the editor for a column of a table on `kind`. MongoDB and Redis always edit as text.
    public static func classify(_ column: ColumnInfo, kind: DatabaseKind) -> CellEditorKind {
        guard kind.isSQL else { return .text }
        let type = column.dataType.trimmingCharacters(in: .whitespaces)
        let lower = type.lowercased()
        // Arrays of any type keep the text editor.
        if lower.hasSuffix("]") { return .text }
        if let labels = column.enumValues { return .choice(labels) }
        switch kind {
        case .mysql, .mariadb:
            if lower.hasPrefix("enum(") { return EnumLabels.parse(type, backslashEscapes: true).map(CellEditorKind.choice) ?? .text }
            if lower == "tinyint(1)" || lower.hasPrefix("tinyint(1) ") || lower == "bool" || lower == "boolean" { return .boolean(.numeric) }
        case .duckdb:
            if lower.hasPrefix("enum(") { return EnumLabels.parse(type, backslashEscapes: false).map(CellEditorKind.choice) ?? .text }
            if lower == "boolean" || lower == "bool" || lower == "logical" { return .boolean(.words) }
        case .postgresql:
            if lower == "boolean" || lower == "bool" { return .boolean(.letters) }
        case .sqlite:
            if lower == "boolean" || lower == "bool" { return .boolean(.numeric) }
        case .mongodb, .redis:
            return .text
        }
        return TemporalKind.classify(lower).map(CellEditorKind.temporal) ?? .text
    }
}

/// How an engine spells true and false. The toggle writes the same spelling the engine returns, so a value toggled
/// twice compares equal to the loaded one and leaves no change behind.
public enum BooleanStyle: Hashable, Sendable {
    /// PostgreSQL: `t` and `f`.
    case letters
    /// MySQL, MariaDB and SQLite: `1` and `0`.
    case numeric
    /// DuckDB: `true` and `false`.
    case words

    public func text(_ value: Bool) -> String {
        switch self {
        case .letters: return value ? "t" : "f"
        case .numeric: return value ? "1" : "0"
        case .words: return value ? "true" : "false"
        }
    }

    /// Reads any spelling an engine returns or a user types; nil for anything else.
    public static func parse(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "t", "true", "1", "y", "yes", "on": return true
        case "f", "false", "0", "n", "no", "off": return false
        default: return nil
        }
    }
}

/// Date and time column types. Values are edited as wall-clock text; a time zone in the text is kept, never converted.
public enum TemporalKind: Hashable, Sendable {
    case date
    case time(withTimeZone: Bool)
    case timestamp(withTimeZone: Bool)

    public var hasDate: Bool {
        if case .time = self { return false }
        return true
    }

    public var hasTime: Bool {
        if case .date = self { return false }
        return true
    }

    public var hasTimeZone: Bool {
        switch self {
        case .date: return false
        case .time(let zone), .timestamp(let zone): return zone
        }
    }

    /// `date`, `time(3) with time zone`, `timestamp without time zone`, `datetime(6)`, `TIMESTAMPTZ`, `TIMESTAMP_MS`;
    /// nil for other types (`interval`, `year`, `daterange`).
    static func classify(_ lowerType: String) -> TemporalKind? {
        // Drop a precision such as (3) or (6) wherever it sits.
        let type = lowerType.replacingOccurrences(of: #"\s*\(\s*\d+\s*\)"#, with: "", options: .regularExpression)
        let withZone = type.hasSuffix(" with time zone") || type == "timestamptz" || type == "timetz"
        let base = type.components(separatedBy: " with").first ?? type
        switch base {
        case "date":
            return .date
        case "time", "timetz", "time_ns":
            return .time(withTimeZone: withZone)
        case "timestamp", "timestamptz", "datetime", "datetime2", "timestamp_s", "timestamp_ms", "timestamp_ns", "timestamp_us":
            return .timestamp(withTimeZone: withZone)
        default:
            return nil
        }
    }
}

/// Labels of `ENUM('a','b')` column types (MySQL, MariaDB, DuckDB).
public enum EnumLabels {
    /// Quotes are doubled inside a label; with `backslashEscapes` (MySQL) a backslash escapes the next character.
    /// Nil when the text is not a well-formed list.
    public static func parse(_ type: String, backslashEscapes: Bool) -> [String]? {
        guard let open = type.firstIndex(of: "("), type.hasSuffix(")"), type[..<open].trimmingCharacters(in: .whitespaces).lowercased() == "enum" else { return nil }
        let body = Array(type[type.index(after: open)..<type.index(before: type.endIndex)])
        var labels: [String] = []
        var index = 0
        func skipSpaces() { while index < body.count, body[index].isWhitespace { index += 1 } }
        skipSpaces()
        if index == body.count { return [] }
        while index < body.count {
            skipSpaces()
            guard index < body.count, body[index] == "'" else { return nil }
            index += 1
            var label = ""
            var closed = false
            while index < body.count {
                let character = body[index]
                if character == "'" {
                    if index + 1 < body.count, body[index + 1] == "'" {
                        label.append("'")
                        index += 2
                        continue
                    }
                    index += 1
                    closed = true
                    break
                }
                if backslashEscapes, character == "\\", index + 1 < body.count {
                    label.append(body[index + 1])
                    index += 2
                    continue
                }
                label.append(character)
                index += 1
            }
            guard closed else { return nil }
            labels.append(label)
            skipSpaces()
            if index < body.count {
                guard body[index] == "," else { return nil }
                index += 1
            }
        }
        return labels
    }
}

/// The foreign key whose picker a column gets: only a key of that one column, so one pick sets the whole reference.
public enum ReferencePicker {
    public static func foreignKey(forColumn column: String, in structure: TableStructure) -> ForeignKeyInfo? {
        structure.foreignKeys.first { $0.columns == [column] && $0.referencedColumns.count == 1 }
    }
}

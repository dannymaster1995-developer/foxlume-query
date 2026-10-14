import Foundation

/// SQLite triggers, from sqlite_master. Timing and event are read from the CREATE TRIGGER text; triggers are always
/// row-level and have no enable switch.
extension SQLiteConnection {
    public func schemaObjects(_ kind: SchemaObjectKind, schema: String?) throws -> [SchemaObject] {
        guard kind == .trigger else { return [] }
        return try triggerRows(table: nil).compactMap { row in
            guard let name = row[0].textValue, let table = row[1].textValue else { return nil }
            let parsed = Self.triggerHeader(row[2].textValue ?? "")
            return SchemaObject(kind: .trigger, name: name, table: table, detail: "\(parsed.timing) \(parsed.event)", attributes: [
                SchemaObjectAttribute("Timing", parsed.timing),
                SchemaObjectAttribute("Event", parsed.event),
                SchemaObjectAttribute("Level", "ROW"),
            ])
        }
    }

    public func definition(of object: SchemaObject) throws -> SchemaObjectDefinition {
        guard object.kind == .trigger,
              let text = try execute("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = \(dialect.quoteString(object.name))", rowLimit: nil)
                .first?.rows.first?.first?.textValue
        else {
            throw DatabaseError.server(message: "no such trigger: \(object.name)", code: nil)
        }
        return SchemaObjectDefinition(statement: text)
    }

    public func triggers(of table: TableRef) throws -> [TriggerInfo] {
        try triggerRows(table: table.name).compactMap { row in
            guard let name = row[0].textValue else { return nil }
            let sql = row[2].textValue ?? ""
            let parsed = Self.triggerHeader(sql)
            return TriggerInfo(name: name, timing: parsed.timing, events: [parsed.event], action: Self.triggerBody(sql), definition: sql)
        }
    }

    private func triggerRows(table: String?) throws -> [[CellValue]] {
        let filter = table.map { " AND tbl_name = \(dialect.quoteString($0))" } ?? ""
        return try execute("SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'trigger'\(filter) ORDER BY tbl_name, name", rowLimit: nil)
            .first?.rows ?? []
    }

    /// Timing (BEFORE when none is written, as SQLite assumes) and event (`UPDATE OF a, b` keeps its columns) from the
    /// words before ON.
    static func triggerHeader(_ sql: String) -> (timing: String, event: String) {
        let collapsed = sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let pattern = #"(?i)\bTRIGGER\b.*?\s((?:BEFORE|AFTER|INSTEAD OF)\s+)?(DELETE|INSERT|UPDATE(?:\s+OF\s+.+?)?)\s+ON\s"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: collapsed, range: NSRange(collapsed.startIndex..., in: collapsed))
        else { return ("BEFORE", "") }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: collapsed).map { String(collapsed[$0]).trimmingCharacters(in: .whitespaces) }
        }
        let timing = group(1).map { $0.uppercased() }.flatMap { $0.isEmpty ? nil : $0 } ?? "BEFORE"
        var event = group(2) ?? ""
        if let space = event.firstIndex(of: " ") {
            event = event[..<space].uppercased() + event[space...]
        } else {
            event = event.uppercased()
        }
        return (timing, event)
    }

    /// The statements between BEGIN and the final END.
    static func triggerBody(_ sql: String) -> String {
        guard let begin = sql.range(of: #"(?i)\bBEGIN\b"#, options: .regularExpression),
              let end = sql.range(of: #"(?i)\bEND\s*;?\s*$"#, options: .regularExpression),
              begin.upperBound <= end.lowerBound
        else { return sql }
        return sql[begin.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

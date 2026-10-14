import Foundation

/// Turns Redis replies into grids, the way TablePro types them per command.
enum RedisResults {
    static func column(_ name: String, type: String = "string", numeric: Bool = false, table: String? = nil) -> ResultColumn {
        ResultColumn(name: name, typeName: type, isNumeric: numeric, tableName: table)
    }

    /// Key | Type | TTL | Length | Value, used by key browsing, KEYS and SCAN.
    static func keyColumns(table: String? = nil) -> [ResultColumn] {
        [
            column("Key", table: table),
            column("Type", table: table),
            column("TTL", type: "integer", numeric: true, table: table),
            column("Length", type: "integer", numeric: true, table: table),
            column("Value", table: table),
        ]
    }

    static func grid(_ columns: [ResultColumn], _ rows: [[CellValue]], rowLimit: Int?, message: String? = nil) -> StatementResult {
        var kept = rows
        var truncated = false
        if let rowLimit, rows.count > max(0, rowLimit) {
            kept = Array(rows.prefix(max(0, rowLimit)))
            truncated = true
        }
        return StatementResult(columns: columns, rows: kept, message: message, truncated: truncated)
    }

    static func cell(_ data: Data) -> CellValue { CellValue.decode(data) }

    /// Formats the reply of a command that needs no further server calls. Unexpected shapes fall back to `generic`.
    /// `listStart` is the absolute index of the first LRANGE element.
    static func format(_ command: RedisCommand, reply: RESPValue, rowLimit: Int?, listStart: Int = 0) -> StatementResult {
        if case .simple(let text) = reply, text == "QUEUED" {
            return StatementResult(message: "QUEUED")
        }
        let key = command.arguments.count > 1 ? cell(command.arguments[1]) : .null
        switch command.name {
        case "HGETALL" where reply.isAggregate:
            let rows = reply.pairs.map { [$0.0.cell, $0.1.cell] }
            return grid([column("Field"), column("Value")], rows, rowLimit: rowLimit)

        case "HGET" where !reply.isAggregate && command.arguments.count > 2:
            return grid([column("Field"), column("Value")], [[cell(command.arguments[2]), reply.cell]], rowLimit: rowLimit)

        case "LRANGE" where reply.isAggregate:
            let rows = (reply.elements ?? []).enumerated().map { offset, item in
                [CellValue.text(String(listStart + offset)), item.cell]
            }
            return grid([column("Index", type: "integer", numeric: true), column("Value")], rows, rowLimit: rowLimit)

        case "SMEMBERS", "SINTER", "SUNION", "SDIFF":
            guard let items = reply.elements else { break }
            return grid([column("Member")], items.map { [$0.cell] }, rowLimit: rowLimit)

        case "ZRANGE", "ZREVRANGE", "ZRANGEBYSCORE", "ZREVRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGEBYLEX":
            guard let items = reply.elements else { break }
            if command.hasOption("WITHSCORES") {
                let rows = reply.pairs.map { [$0.0.cell, score($0.1)] }
                return grid([column("Member"), column("Score", type: "double", numeric: true)], rows, rowLimit: rowLimit)
            }
            return grid([column("Member")], items.map { [$0.cell] }, rowLimit: rowLimit)

        case "XRANGE", "XREVRANGE":
            guard let entries = reply.elements else { break }
            return grid([column("ID"), column("Fields")], entries.compactMap(streamRow), rowLimit: rowLimit)

        case "GET", "GETDEL", "GETEX", "GETSET", "GETRANGE", "SUBSTR":
            guard !reply.isAggregate else { break }
            return grid([column("Key"), column("Value")], [[key, reply.cell]], rowLimit: rowLimit)

        case "MGET" where reply.isAggregate:
            let values = reply.elements ?? []
            let rows = zip(command.arguments.dropFirst(), values).map { [cell($0), $1.cell] }
            return grid([column("Key"), column("Value")], rows, rowLimit: rowLimit)

        case "TTL", "PTTL", "EXPIRETIME", "PEXPIRETIME":
            guard let value = reply.integer else { break }
            let name = command.name == "TTL" ? "TTL" : command.name
            return grid([column("Key"), column(name, type: "integer", numeric: true)], [[key, .text(String(value))]], rowLimit: rowLimit)

        case "INFO":
            guard let text = reply.string else { break }
            let rows = RedisInfo.entries(text).map { [CellValue.text($0.section), .text($0.key), .text($0.value)] }
            return grid([column("Section"), column("Key"), column("Value")], rows, rowLimit: rowLimit)

        case "CONFIG" where command.word(1) == "GET" && reply.isAggregate:
            let rows = reply.pairs
                .map { [$0.0.cell, $0.1.cell] }
                .sorted { ($0[0].textValue ?? "") < ($1[0].textValue ?? "") }
            return grid([column("Parameter"), column("Value")], rows, rowLimit: rowLimit)

        case "DEL", "UNLINK":
            guard let count = reply.integer else { break }
            var result = grid([column("deleted", type: "integer", numeric: true)], [[.text(String(count))]], rowLimit: rowLimit)
            result.affectedRows = Int(count)
            return result

        case "HSCAN", "SSCAN", "ZSCAN":
            guard let parts = reply.elements, parts.count == 2, let cursor = parts[0].string else { break }
            let items = parts[1]
            let message = "Next cursor: \(cursor)"
            switch command.name {
            case "HSCAN":
                let rows = items.pairs.map { [$0.0.cell, $0.1.cell] }
                return grid([column("Field"), column("Value")], rows, rowLimit: rowLimit, message: message)
            case "ZSCAN":
                let rows = items.pairs.map { [$0.0.cell, score($0.1)] }
                return grid([column("Member"), column("Score", type: "double", numeric: true)], rows, rowLimit: rowLimit, message: message)
            default:
                return grid([column("Member")], (items.elements ?? []).map { [$0.cell] }, rowLimit: rowLimit, message: message)
            }

        case "EXEC":
            if case .null = reply {
                return StatementResult(message: "Transaction aborted: a watched key changed, EXEC returned nil.")
            }

        default:
            break
        }
        return generic(reply, rowLimit: rowLimit)
    }

    /// Anything else: `OK` as a message, other replies in a `result` column, one row per array element.
    static func generic(_ reply: RESPValue, rowLimit: Int?) -> StatementResult {
        switch reply {
        case .simple(let text) where text == "OK":
            return StatementResult(message: "OK")
        case .simple(let text) where text == "QUEUED":
            return StatementResult(message: "QUEUED")
        case .integer(let value):
            return grid([column("result", type: "integer", numeric: true)], [[.text(String(value))]], rowLimit: rowLimit)
        case .double, .bigNumber:
            return grid([column("result", type: "double", numeric: true)], [[reply.cell]], rowLimit: rowLimit)
        case .array(let items), .set(let items), .push(let items):
            return grid([column("result")], items.map { [$0.cell] }, rowLimit: rowLimit)
        case .map:
            let rows = reply.pairs.map { [$0.0.cell, $0.1.cell] }
            return grid([column("field"), column("value")], rows, rowLimit: rowLimit)
        default:
            return grid([column("result")], [[reply.cell]], rowLimit: rowLimit)
        }
    }

    /// Scores as redis-cli prints them; RESP3 sends doubles, RESP2 sends text.
    static func score(_ value: RESPValue) -> CellValue {
        if case .double(let number) = value { return .text(RESPValue.format(number)) }
        return value.cell
    }

    /// `[id, [field, value, …]]` → ID | `field=value, field2=value2`.
    static func streamRow(_ entry: RESPValue) -> [CellValue]? {
        guard let parts = entry.elements, parts.count >= 2 else { return nil }
        let fields = parts[1].pairs.map { "\($0.0.displayText)=\($0.1.displayText)" }
        return [parts[0].cell, .text(fields.joined(separator: ", "))]
    }

    /// `[id, [field, value, …]]` → `[id, {field: value}]` for the stream preview.
    static func streamPreviewEntry(_ entry: RESPValue) -> Any? {
        guard let parts = entry.elements, parts.count >= 2 else { return nil }
        var fields: [String: Any] = [:]
        for (field, value) in parts[1].pairs { fields[field.displayText] = value.displayText }
        return [parts[0].displayText, fields]
    }

    /// Converts a server error into the error the UI shows: the first word is the code, as in `WRONGTYPE`.
    static func serverError(_ message: String) -> DatabaseError {
        let parts = message.split(separator: " ", maxSplits: 1)
        if let first = parts.first, first.count > 1, first.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) {
            let rest = parts.count > 1 ? String(parts[1]) : String(first)
            return .server(message: rest, code: String(first))
        }
        return .server(message: message, code: nil)
    }
}

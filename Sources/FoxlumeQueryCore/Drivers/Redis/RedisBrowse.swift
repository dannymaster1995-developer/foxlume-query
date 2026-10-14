import Foundation

// MARK: - Key browsing

extension RedisConnection {
    /// One page of keys for a `db<n>` table: SCAN with the pattern and type, sorted, then summarized.
    public func fetchRows(_ query: TableQuery) throws -> StatementResult {
        let index = try Self.databaseIndex(of: query.table)
        let filter = Self.browseFilter(query)
        return try metadataOperation {
            try withDatabase(index) {
                let started = Date()
                let scan = try scanKeys(pattern: filter.pattern, type: filter.type, limit: Self.browseScanLimit)
                let sorted = Self.sortedKeys(scan.keys)
                let pageSize = max(1, query.pageSize)
                let start = max(0, query.page) * pageSize
                let page = start < sorted.count ? Array(sorted[start..<min(sorted.count, start + pageSize)]) : []
                var result = StatementResult(
                    columns: RedisResults.keyColumns(table: query.table.name),
                    rows: try keySummaries(page),
                    truncated: !scan.complete
                )
                if !scan.complete {
                    result.message = "Showing the first \(Self.browseScanLimit) keys found. Narrow the key pattern to see the others."
                }
                result.elapsed = Date().timeIntervalSince(started)
                return result
            }
        }
    }

    /// `DBSIZE` without a pattern or type, otherwise a full filtered SCAN.
    public func countRows(_ query: TableQuery) throws -> Int? {
        let index = try Self.databaseIndex(of: query.table)
        let filter = Self.browseFilter(query)
        return try metadataOperation {
            try withDatabase(index) {
                if filter.pattern == "*", filter.type == nil {
                    var total: Int64 = 0
                    for link in try keyspaceLinks() {
                        let reply = try send([Self.arguments("DBSIZE")], on: link)[0]
                        try throwIfError(reply)
                        total += reply.integer ?? 0
                    }
                    return Int(total)
                }
                return try scanKeys(pattern: filter.pattern, type: filter.type, limit: nil).keys.count
            }
        }
    }

    /// Keys of the session's database for the sidebar tree, with their types.
    public func browseKeys(pattern: String, limit: Int) throws -> KeyListing? {
        try metadataOperation {
            let glob = pattern.trimmingCharacters(in: .whitespaces).isEmpty ? "*" : pattern
            let scan = try scanKeys(pattern: glob, type: nil, limit: max(1, limit))
            let sorted = Self.sortedKeys(scan.keys)
            let types = try pipelineByKey(sorted.map { ($0, Self.arguments("TYPE") + [$0]) })
            var keys: [KeyListing.Key] = []
            keys.reserveCapacity(sorted.count)
            for (key, type) in zip(sorted, types) {
                guard let name = type.string?.lowercased(), name != "none", !type.isError else { continue }
                keys.append(KeyListing.Key(name: String(decoding: key, as: UTF8.self), type: name))
            }
            return KeyListing(keys: keys, truncated: !scan.complete)
        }
    }

    static func databaseIndex(of table: TableRef) throws -> Int {
        guard let index = RedisCommandParser.databaseIndex(table.name) else {
            throw DatabaseError.server(message: "\"\(table.name)\" is not a Redis database. Databases are named db0, db1, …", code: nil)
        }
        return index
    }

    /// The glob from `rawWhere` (empty means `*`) and the type from a `Type = …` rule.
    static func browseFilter(_ query: TableQuery) -> (pattern: String, type: String?) {
        let raw = query.rawWhere.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = query.filters.first { $0.isEnabled && $0.column == "Type" && $0.op == .equals }
        return (raw.isEmpty ? "*" : raw, rule.flatMap { normalizedType($0.value) })
    }

    /// `ZSET`, `Sorted Set` and `zset` all mean `zset`; `All` or empty means no type filter.
    static func normalizedType(_ text: String) -> String? {
        let compact = text.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
        switch compact {
        case "", "all", "any", "*": return nil
        case "sortedset": return "zset"
        default: return compact
        }
    }

    /// SCAN with MATCH (and TYPE) over the current database, every master in a cluster, de-duplicated.
    /// Stops once `limit` keys are found; `complete` is false when keys may remain.
    func scanKeys(pattern: String, type: String?, limit: Int?) throws -> (keys: [Data], complete: Bool) {
        // SCAN … TYPE arrived in Redis 6.0; older servers get each key's type checked instead.
        let serverFiltersType = serverInfo.compatibleMajor == 0 || serverInfo.compatibleMajor >= 6
        let clientType = serverFiltersType ? nil : type
        var seen = Set<Data>()
        var keys: [Data] = []
        var unchecked: [Data] = []
        let links = try keyspaceLinks()
        for (position, link) in links.enumerated() {
            var cursor = "0"
            repeat {
                var arguments = Self.arguments("SCAN", cursor, "MATCH", pattern, "COUNT", "1000")
                if serverFiltersType, let type { arguments += Self.arguments("TYPE", type) }
                let reply = try send([arguments], on: link)[0]
                try throwIfError(reply)
                guard let parts = reply.elements, parts.count == 2, let next = parts[0].string else {
                    throw DatabaseError.protocolViolation("Unexpected SCAN reply")
                }
                cursor = next
                for key in (parts[1].elements ?? []).compactMap(\.data) where seen.insert(key).inserted {
                    if clientType == nil { keys.append(key) } else { unchecked.append(key) }
                }
                if let clientType, unchecked.count >= 1000 || cursor == "0" {
                    keys += try keepType(unchecked, type: clientType)
                    unchecked.removeAll()
                }
                if let limit, keys.count >= limit {
                    let finished = cursor == "0" && position == links.count - 1
                    return (Array(keys.prefix(limit)), finished && keys.count == limit)
                }
            } while cursor != "0"
        }
        return (keys, true)
    }

    private func keepType(_ keys: [Data], type: String?) throws -> [Data] {
        guard let type, !keys.isEmpty else { return keys }
        let types = try pipelineByKey(keys.map { ($0, Self.arguments("TYPE") + [$0]) })
        return zip(keys, types).filter { $1.string?.lowercased() == type }.map(\.0)
    }

    /// Key | Type | TTL | Length | Value rows: TYPE and TTL in one pipelined round, length and preview in a second.
    func keySummaries(_ keys: [Data]) throws -> [[CellValue]] {
        var rows: [[CellValue]] = []
        rows.reserveCapacity(keys.count)
        for start in stride(from: 0, to: keys.count, by: 500) {
            let chunk = Array(keys[start..<min(keys.count, start + 500)])
            var describe: [(key: Data, arguments: [Data])] = []
            for key in chunk {
                describe.append((key, Self.arguments("TYPE") + [key]))
                describe.append((key, Self.arguments("TTL") + [key]))
            }
            let described = try pipelineByKey(describe)
            var contents: [(key: Data, arguments: [Data])] = []
            var plans: [(key: Data, type: String, ttl: Int64, hasContents: Bool)] = []
            for (offset, key) in chunk.enumerated() {
                let type = described[offset * 2].string?.lowercased() ?? "none"
                let ttl = described[offset * 2 + 1].integer ?? -1
                guard type != "none", !described[offset * 2].isError else { continue }
                if let commands = RedisKeyPreview.commands(type: type, key: key) {
                    contents.append((key, commands.length))
                    contents.append((key, commands.preview))
                    plans.append((key, type, ttl, true))
                } else {
                    plans.append((key, type, ttl, false))
                }
            }
            let answers = try pipelineByKey(contents)
            var cursor = 0
            for plan in plans {
                var length = CellValue.null
                var value = CellValue.null
                if plan.hasContents {
                    let lengthReply = answers[cursor]
                    let previewReply = answers[cursor + 1]
                    cursor += 2
                    if let count = lengthReply.integer { length = .text(String(count)) }
                    if !previewReply.isError { value = RedisKeyPreview.value(type: plan.type, reply: previewReply) }
                }
                rows.append([RedisResults.cell(plan.key), .text(plan.type.uppercased()), .text(String(plan.ttl)), length, value])
            }
        }
        return rows
    }
}

/// The Value column of the key grid: the string itself, or a JSON preview of a collection.
enum RedisKeyPreview {
    static let collectionLimit = 100
    static let streamLimit = 5

    static func commands(type: String, key: Data) -> (length: [Data], preview: [Data])? {
        func make(_ words: [String]) -> [Data] {
            var arguments = [Data(words[0].utf8), key]
            arguments += words.dropFirst().map { Data($0.utf8) }
            return arguments
        }
        let count = String(collectionLimit)
        switch type {
        case "string": return (make(["STRLEN"]), make(["GET"]))
        case "hash": return (make(["HLEN"]), make(["HSCAN", "0", "COUNT", count]))
        case "list": return (make(["LLEN"]), make(["LRANGE", "0", String(collectionLimit - 1)]))
        case "set": return (make(["SCARD"]), make(["SSCAN", "0", "COUNT", count]))
        case "zset": return (make(["ZCARD"]), make(["ZRANGE", "0", String(collectionLimit - 1), "WITHSCORES"]))
        case "stream": return (make(["XLEN"]), make(["XREVRANGE", "+", "-", "COUNT", String(streamLimit)]))
        default: return nil
        }
    }

    static func value(type: String, reply: RESPValue) -> CellValue {
        switch type {
        case "string":
            return reply.cell
        case "hash":
            var object: [String: Any] = [:]
            for (field, value) in scanItems(reply).pairs.prefix(collectionLimit) {
                object[field.displayText] = value.displayText
            }
            return json(object)
        case "list":
            return json((reply.elements ?? []).map(\.displayText))
        case "set":
            let members = (scanItems(reply).elements ?? []).map(\.displayText).sorted()
            return json(Array(members.prefix(collectionLimit)))
        case "zset":
            let pairs = reply.pairs.map { member, score -> [Any] in
                let number: Any = score.string.flatMap(Double.init).map { NSNumber(value: $0) } ?? score.displayText
                return [member.displayText, number]
            }
            return json(pairs)
        case "stream":
            return json((reply.elements ?? []).compactMap(RedisResults.streamPreviewEntry))
        default:
            return .null
        }
    }

    /// HSCAN/SSCAN answer `[cursor, items]`.
    private static func scanItems(_ reply: RESPValue) -> RESPValue {
        if let parts = reply.elements, parts.count == 2, parts[1].isAggregate { return parts[1] }
        return reply
    }

    private static func json(_ object: Any) -> CellValue {
        RESPValue.encodeJSON(object).map(CellValue.text) ?? .null
    }
}

// MARK: - Saving grid edits

/// The writes for one save, built from grid edits without touching the server.
struct RedisSavePlan: Equatable {
    struct Write: Equatable {
        var arguments: [Data]
        /// The key that decides the cluster slot.
        var key: Data

        var label: String {
            arguments.map { RedisArgumentText.quote($0) }.joined(separator: " ")
        }
    }

    var deletions: [Data] = []
    var writes: [Write] = []

    var isEmpty: Bool { deletions.isEmpty && writes.isEmpty }

    static let insertableTypes: Set<String> = ["string", "hash", "list", "set", "zset"]

    /// - Parameter keepTTL: `SET … KEEPTTL` (Redis 6.0+) so editing a value does not drop its expiry.
    init(batch: ChangeBatch, keepTTL: Bool) throws {
        let names = batch.columns.map(\.name)
        guard let keyColumn = names.firstIndex(of: "Key") else {
            throw DatabaseError.unsupported("These rows have no Key column, so they cannot be saved.")
        }
        let typeColumn = names.firstIndex(of: "Type")
        let changes = batch.changes

        func originalKey(_ row: Int) throws -> Data {
            guard batch.originalRows.indices.contains(row) else { throw StatementGenerationError.missingOriginalRow(row) }
            guard let key = Self.bytes(batch.originalRows[row][safeIndex: keyColumn]) else {
                throw DatabaseError.unsupported("Row \(row + 1): this key has no name, so it cannot be addressed.")
            }
            return key
        }

        for row in changes.deletions.sorted() {
            deletions.append(try originalKey(row))
        }

        for row in changes.updates.keys.sorted() where !changes.deletions.contains(row) {
            guard let edits = changes.updates[row], !edits.isEmpty else { continue }
            var key = try originalKey(row)
            let original = batch.originalRows[row]
            if let edit = edits[keyColumn] {
                guard let renamed = Self.bytes(edit), !renamed.isEmpty else {
                    throw DatabaseError.unsupported("Row \(row + 1): a key can only be renamed to a non-empty name.")
                }
                if renamed != key {
                    writes.append(Write(arguments: [Data("RENAME".utf8), key, renamed], key: key))
                    key = renamed
                }
            }
            // Value before TTL: without KEEPTTL a SET clears the expiry, which the TTL edit then sets again.
            let ordered = edits.keys.filter { $0 != keyColumn && names.indices.contains($0) }.sorted { lhs, rhs in
                (names[lhs] == "Value" ? 0 : 1, lhs) < (names[rhs] == "Value" ? 0 : 1, rhs)
            }
            for column in ordered {
                let value = edits[column] ?? .null
                switch names[column] {
                case "Value":
                    let type = typeColumn.flatMap { original[safeIndex: $0].textValue?.lowercased() } ?? "string"
                    guard type == "string" else {
                        throw DatabaseError.unsupported("Row \(row + 1): the value of a \(type) key cannot be edited in the grid. Change it with a command in the query editor.")
                    }
                    guard let bytes = Self.bytes(value) else {
                        throw DatabaseError.unsupported("Row \(row + 1): Redis cannot store NULL. Enter an empty value instead.")
                    }
                    var arguments = [Data("SET".utf8), key, bytes]
                    if keepTTL { arguments.append(Data("KEEPTTL".utf8)) }
                    writes.append(Write(arguments: arguments, key: key))
                case "TTL":
                    writes.append(Write(arguments: try Self.ttlCommand(value, key: key, row: row), key: key))
                default:
                    throw DatabaseError.unsupported("Row \(row + 1): \(names[column]) cannot be changed from the grid.")
                }
            }
        }

        for (offset, values) in changes.insertions.enumerated() {
            func cell(_ name: String) -> CellValue? {
                guard let column = names.firstIndex(of: name), values.indices.contains(column),
                      case .value(let cell) = values[column]
                else { return nil }
                return cell
            }
            let label = "New row \(offset + 1)"
            guard let key = cell("Key").flatMap(Self.bytes), !key.isEmpty else {
                throw DatabaseError.unsupported("\(label): a new key needs a name.")
            }
            let type = cell("Type").flatMap { $0.textValue }.flatMap(RedisConnection.normalizedType) ?? "string"
            guard Self.insertableTypes.contains(type) else {
                throw DatabaseError.unsupported("\(label): a \(type) key cannot be added from the grid. Add it with a command in the query editor.")
            }
            let value = cell("Value").flatMap(Self.bytes) ?? Data()
            var ttl: Int?
            if let text = cell("TTL")?.textValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                guard let seconds = Int(text), seconds > 0 || seconds == -1 else {
                    throw DatabaseError.unsupported("\(label): TTL has to be a whole number of seconds above 0, or -1 for no expiry.")
                }
                ttl = seconds > 0 ? seconds : nil
            }
            writes.append(Write(arguments: Self.insertCommand(type: type, key: key, value: value), key: key))
            if let ttl {
                writes.append(Write(arguments: [Data("EXPIRE".utf8), key, Data(String(ttl).utf8)], key: key))
            }
        }
    }

    static func ttlCommand(_ value: CellValue, key: Data, row: Int) throws -> [Data] {
        let text = value.textValue?.trimmingCharacters(in: .whitespaces) ?? ""
        if value.isAbsent || text.isEmpty || text == "-1" {
            return [Data("PERSIST".utf8), key]
        }
        guard let seconds = Int(text), seconds > 0 else {
            throw DatabaseError.unsupported("Row \(row + 1): TTL has to be a whole number of seconds above 0, or -1 or NULL for no expiry.")
        }
        return [Data("EXPIRE".utf8), key, Data(String(seconds).utf8)]
    }

    /// SET / HSET (a JSON object becomes fields, anything else a field named `value`) / RPUSH / SADD / ZADD 0.
    static func insertCommand(type: String, key: Data, value: Data) -> [Data] {
        func command(_ name: String, _ rest: [Data]) -> [Data] { [Data(name.utf8), key] + rest }
        switch type {
        case "hash":
            if let object = try? JSONSerialization.jsonObject(with: value) as? [String: Any], !object.isEmpty {
                let fields = object.keys.sorted().flatMap { name -> [Data] in
                    let field = object[name]
                    let text: String
                    if let string = field as? String {
                        text = string
                    } else if let number = field as? NSNumber {
                        text = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
                    } else if field is NSNull {
                        text = ""
                    } else if let field, JSONSerialization.isValidJSONObject(field),
                              let data = try? JSONSerialization.data(withJSONObject: field, options: [.sortedKeys]) {
                        text = String(decoding: data, as: UTF8.self)
                    } else {
                        text = field.map { "\($0)" } ?? ""
                    }
                    return [Data(name.utf8), Data(text.utf8)]
                }
                return command("HSET", fields)
            }
            return command("HSET", [Data("value".utf8), value])
        case "list": return command("RPUSH", [value])
        case "set": return command("SADD", [value])
        case "zset": return command("ZADD", [Data("0".utf8), value])
        default: return command("SET", [value])
        }
    }

    /// Cell → argument bytes, keeping binary values exact.
    static func bytes(_ cell: CellValue?) -> Data? {
        switch cell {
        case .text(let text)?: return Data(text.utf8)
        case .bytes(let data)?: return data
        default: return nil
        }
    }
}

/// redis-cli style rendering of an argument, for error messages.
enum RedisArgumentText {
    static func quote(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8), !text.isEmpty,
           !text.unicodeScalars.contains(where: { $0.value <= 0x20 || $0 == "\"" || $0 == "'" || $0 == "\\" || $0.value == 0x7F }) {
            return text
        }
        var result = "\""
        for byte in data {
            switch byte {
            case UInt8(ascii: "\\"): result += "\\\\"
            case UInt8(ascii: "\""): result += "\\\""
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            case 0x20..<0x7F: result.unicodeScalars.append(UnicodeScalar(byte))
            default:
                if byte >= 0x80, let text = String(data: data, encoding: .utf8) {
                    // Valid UTF-8 with spaces or quotes: escape only what needs it.
                    return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
                }
                result += String(format: "\\x%02x", byte)
            }
        }
        return result + "\""
    }
}

extension RedisConnection {
    /// Saves grid edits in `SELECT n; MULTI … EXEC; SELECT home`. A cluster runs one MULTI per hash slot.
    public func applyChanges(_ batch: ChangeBatch) throws {
        let index = try Self.databaseIndex(of: batch.table)
        let plan = try RedisSavePlan(batch: batch, keepTTL: serverInfo.compatibleMajor == 0 || serverInfo.compatibleMajor >= 6)
        guard !plan.isEmpty else { return }
        try metadataOperation {
            if cluster != nil {
                guard index == 0 else { throw DatabaseError.server(message: "A cluster has only database 0.", code: "ERR") }
                try saveToCluster(plan)
            } else {
                try saveToServer(plan, database: index)
            }
        }
    }

    /// The SELECT is its own round trip: pipelined behind a failed SELECT, the writes would land in the wrong database.
    private func saveToServer(_ plan: RedisSavePlan, database: Int) throws {
        var writes = plan.writes
        if !plan.deletions.isEmpty {
            writes.insert(RedisSavePlan.Write(arguments: [Data("DEL".utf8)] + plan.deletions, key: plan.deletions[0]), at: 0)
        }
        try withDatabase(database) {
            let commands = [Self.arguments("MULTI")] + writes.map(\.arguments) + [Self.arguments("EXEC")]
            let replies = try send(commands, on: try singleLink())
            try Self.checkTransaction(replies: replies, writes: writes)
        }
    }

    /// Replies to `MULTI, writes…, EXEC`: queue-time errors abort everything; EXEC errors name the failed command.
    static func checkTransaction(replies: [RESPValue], writes: [RedisSavePlan.Write]) throws {
        if let message = replies[0].errorMessage { throw RedisResults.serverError(message) }
        for (offset, write) in writes.enumerated() {
            if let message = replies[offset + 1].errorMessage {
                throw DatabaseError.server(message: "Nothing was saved. \(write.label) was refused: \(message)", code: message.split(separator: " ").first.map(String.init))
            }
        }
        let exec = replies[writes.count + 1]
        if let message = exec.errorMessage { throw RedisResults.serverError(message) }
        guard let results = exec.elements else {
            throw DatabaseError.server(message: "The transaction was aborted; nothing was saved.", code: "EXECABORT")
        }
        for (offset, result) in results.enumerated() {
            guard let message = result.errorMessage else { continue }
            let label = writes.indices.contains(offset) ? writes[offset].label : "command \(offset + 1)"
            let applied = results.enumerated().filter { $0.offset != offset && !$0.element.isError }.count
            throw DatabaseError.server(
                message: "\(label) failed: \(message). Redis does not roll back a transaction, so \(applied) other change\(applied == 1 ? " was" : "s were") applied.",
                code: message.split(separator: " ").first.map(String.init)
            )
        }
    }

    /// One `MULTI … EXEC` per hash slot, on the node that owns it; Redis Cluster refuses transactions across slots.
    private func saveToCluster(_ plan: RedisSavePlan) throws {
        guard let cluster else { throw DatabaseError.notConnected }
        var groups: [Int: [RedisSavePlan.Write]] = [:]
        var order: [Int] = []
        func add(_ write: RedisSavePlan.Write) {
            let slot = RedisKeySlot.slot(for: write.key)
            if groups[slot] == nil { order.append(slot) }
            groups[slot, default: []].append(write)
        }
        var deletionsBySlot: [Int: [Data]] = [:]
        var deletionOrder: [Int] = []
        for key in plan.deletions {
            let slot = RedisKeySlot.slot(for: key)
            if deletionsBySlot[slot] == nil { deletionOrder.append(slot) }
            deletionsBySlot[slot, default: []].append(key)
        }
        for slot in deletionOrder {
            let keys = deletionsBySlot[slot] ?? []
            add(RedisSavePlan.Write(arguments: [Data("DEL".utf8)] + keys, key: keys[0]))
        }
        for write in plan.writes {
            if write.arguments.first == Data("RENAME".utf8), write.arguments.count == 3,
               RedisKeySlot.slot(for: write.arguments[1]) != RedisKeySlot.slot(for: write.arguments[2]) {
                throw DatabaseError.unsupported("In a cluster a key can only be renamed within its hash slot. \(write.label) crosses slots; give both names the same {hash tag}.")
            }
            add(write)
        }

        var saved = 0
        for slot in order {
            let writes = groups[slot] ?? []
            let commands = [Self.arguments("MULTI")] + writes.map(\.arguments) + [Self.arguments("EXEC")]
            var replies = try send(commands, on: try cluster.link(for: cluster.endpoint(forSlot: slot)))
            if let redirect = replies.compactMap({ $0.errorMessage.flatMap(RedisRedirect.init) }).first {
                // The slot moved before EXEC, so nothing in this transaction ran. Retry once on the new owner.
                if redirect.kind == .moved {
                    cluster.noteMoved(slot: redirect.slot, to: redirect.endpoint)
                    try? cluster.refresh()
                }
                replies = try send(commands, on: try cluster.link(for: redirect.endpoint))
            }
            do {
                try Self.checkTransaction(replies: replies, writes: writes)
            } catch let DatabaseError.server(message, code, detail) where saved > 0 {
                throw DatabaseError.server(message: "\(message) Changes for \(saved) other hash slot\(saved == 1 ? " were" : "s were") already saved.", code: code, detail: detail)
            }
            saved += 1
        }
    }
}

private extension Array where Element == CellValue {
    subscript(safeIndex index: Int) -> CellValue {
        indices.contains(index) ? self[index] : .null
    }
}

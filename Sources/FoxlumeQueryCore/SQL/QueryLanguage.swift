import Foundation

/// The language typed in a query tab. Decides how text is split into statements and
/// which statements count as writes for read-only and production safety checks.
public enum QueryLanguage: Sendable, Hashable {
    case sql(SQLDialect.Family)
    /// MongoDB shell syntax: `db.orders.find({ status: "paid" }).sort({ _id: -1 })`.
    case mongo
    /// One Redis command per line: `HGETALL user:1`.
    case redis

    public var displayName: String {
        switch self {
        case .sql: return "SQL"
        case .mongo: return "MQL"
        case .redis: return "Redis CLI"
        }
    }

    public func split(_ text: String) -> [SQLStatementRange] {
        switch self {
        case .sql(let family): return SQLStatementSplitter.split(text, family: family)
        case .mongo: return Self.splitMongo(text)
        case .redis: return Self.splitLines(text)
        }
    }

    /// The statement containing `location` (UTF-16 offset), or the closest one before it.
    public func statement(at location: Int, in text: String) -> SQLStatementRange? {
        let statements = split(text)
        if let match = statements.first(where: { location >= $0.range.location && location <= NSMaxRange($0.range) }) {
            return match
        }
        return statements.last(where: { NSMaxRange($0.range) <= location }) ?? statements.first
    }

    public func isReadOnly(_ statement: String) -> Bool {
        switch self {
        case .sql: return SQLStatementSplitter.looksReadOnly(statement)
        case .mongo: return Self.mongoIsReadOnly(statement)
        case .redis: return Self.redisIsReadOnly(statement)
        }
    }

    /// Statements that add, drop or rename objects, after which the object list is reloaded.
    public func changesCatalog(_ statement: String) -> Bool {
        switch self {
        case .sql:
            let first = SQLStatementSplitter.strippingComments(statement)
                .split(whereSeparator: { $0.isWhitespace }).first.map { $0.uppercased() } ?? ""
            return ["CREATE", "DROP", "ALTER", "RENAME", "USE", "ATTACH", "DETACH"].contains(first)
        case .mongo:
            let lower = statement.lowercased()
            return ["createcollection", "drop(", "dropdatabase", "renamecollection", "insert", "use "].contains { lower.contains($0) }
        case .redis:
            let command = Self.redisCommandName(statement)
            return ["SELECT", "FLUSHDB", "FLUSHALL", "DEL", "UNLINK", "RENAME", "RENAMENX", "MOVE", "SWAPDB"].contains(command)
        }
    }

    // MARK: Redis

    /// One command per line; `;` outside quotes also separates commands, as in TablePro.
    static func splitLines(_ text: String) -> [SQLStatementRange] {
        let units = Array(text.utf16)
        var statements: [SQLStatementRange] = []
        var start = 0
        var index = 0

        func emit(upTo end: Int) {
            guard end > start else { return }
            let piece = (text as NSString).substring(with: NSRange(location: start, length: end - start))
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//") else { return }
            let leading = piece.prefix { $0.isWhitespace }.utf16.count
            statements.append(SQLStatementRange(range: NSRange(location: start + leading, length: (trimmed as NSString).length), text: trimmed))
        }

        while index < units.count {
            let c = units[index]
            if c == 0x22 || c == 0x27 {
                index = SQLStatementSplitter.skipQuoted(units, from: index, quote: c, backslash: true)
            } else if c == 0x0A || c == 0x3B {
                emit(upTo: index)
                index += 1
                start = index
            } else {
                index += 1
            }
        }
        emit(upTo: units.count)
        return statements
    }

    /// The command name, skipping a `DB n` prefix so `DB 1 GET x` classifies as `GET`.
    public static func redisCommandName(_ statement: String) -> String {
        let words = redisWords(statement)
        return words.first?.uppercased() ?? ""
    }

    static func redisWords(_ statement: String) -> [Substring] {
        let words = statement.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0.isWhitespace })
        if words.count >= 3, words[0].uppercased() == "DB", Int(words[1]) != nil {
            return Array(words.dropFirst(2))
        }
        return words
    }

    static let redisReadCommands: Set<String> = [
        "GET", "MGET", "GETRANGE", "STRLEN", "EXISTS", "TYPE", "TTL", "PTTL", "EXPIRETIME", "KEYS", "SCAN", "RANDOMKEY",
        "DBSIZE", "INFO", "PING", "ECHO", "TIME", "SELECT", "HGET", "HMGET", "HGETALL", "HKEYS", "HVALS", "HLEN",
        "HEXISTS", "HSCAN", "HSTRLEN", "HRANDFIELD", "LRANGE", "LINDEX", "LLEN", "LPOS", "SMEMBERS", "SISMEMBER",
        "SMISMEMBER", "SCARD", "SSCAN", "SRANDMEMBER", "SINTER", "SUNION", "SDIFF", "ZRANGE", "ZREVRANGE", "ZRANGEBYSCORE",
        "ZREVRANGEBYSCORE", "ZRANGEBYLEX", "ZSCORE", "ZMSCORE", "ZCARD", "ZCOUNT", "ZRANK", "ZREVRANK", "ZSCAN",
        "ZLEXCOUNT", "XRANGE", "XREVRANGE", "XLEN", "XINFO", "XREAD", "XPENDING", "PFCOUNT", "GETBIT", "BITCOUNT",
        "BITPOS", "OBJECT", "MEMORY", "CLIENT", "CONFIG", "COMMAND", "SLOWLOG", "LASTSAVE", "ROLE", "DUMP", "JSON.GET",
        "JSON.TYPE", "JSON.MGET", "JSON.STRLEN", "JSON.OBJKEYS", "JSON.OBJLEN", "JSON.ARRLEN", "GEOPOS", "GEODIST",
        "GEOSEARCH", "GEOHASH", "SORT_RO", "LCS", "SUBSTR",
    ]

    static func redisIsReadOnly(_ statement: String) -> Bool {
        let command = redisCommandName(statement)
        if command == "CONFIG" || command == "CLIENT" || command == "OBJECT" || command == "MEMORY" {
            let words = redisWords(statement)
            let sub = words.count > 1 ? words[1].uppercased() : ""
            return ["GET", "LIST", "INFO", "GETNAME", "ID", "ENCODING", "FREQ", "IDLETIME", "REFCOUNT", "USAGE", "STATS", "HELP"].contains(sub)
        }
        return redisReadCommands.contains(command)
    }

    // MARK: MongoDB

    /// Splits on `;` and on newlines that start a new top-level command, outside strings, comments and brackets.
    static func splitMongo(_ text: String) -> [SQLStatementRange] {
        let units = Array(text.utf16)
        var statements: [SQLStatementRange] = []
        var start = 0
        var index = 0
        var depth = 0

        func emit(upTo end: Int) {
            guard end > start else { return }
            let raw = NSRange(location: start, length: end - start)
            let piece = (text as NSString).substring(with: raw)
            var lines = piece.components(separatedBy: "\n")
            // A comment line before the next command belongs to that command, not to this one.
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty || last.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                lines.removeLast()
            }
            let trimmed = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let withoutComments = stripJSComments(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !withoutComments.isEmpty else { return }
            let leading = piece.prefix { $0.isWhitespace }.utf16.count
            statements.append(SQLStatementRange(range: NSRange(location: start + leading, length: (trimmed as NSString).length), text: trimmed))
        }

        func startsTopLevelCommand(at position: Int) -> Bool {
            var cursor = position
            while cursor < units.count, units[cursor] == 0x20 || units[cursor] == 0x09 { cursor += 1 }
            let rest = String(decoding: units[cursor..<min(units.count, cursor + 5)], as: UTF16.self)
            return rest.hasPrefix("db.") || rest.hasPrefix("db[") || rest.hasPrefix("use ") || rest.hasPrefix("show ")
        }

        while index < units.count {
            let c = units[index]
            let next = index + 1 < units.count ? units[index + 1] : 0
            switch c {
            case 0x27, 0x22, 0x60:
                index = SQLStatementSplitter.skipQuoted(units, from: index, quote: c, backslash: true)
            case 0x2F where next == 0x2F:
                index = SQLStatementSplitter.skipLine(units, from: index)
            case 0x2F where next == 0x2A:
                index = SQLStatementSplitter.skipBlockComment(units, from: index, nested: false)
            case 0x28, 0x5B, 0x7B:
                depth += 1
                index += 1
            case 0x29, 0x5D, 0x7D:
                depth = max(0, depth - 1)
                index += 1
            case 0x3B where depth == 0:
                emit(upTo: index)
                index += 1
                start = index
            case 0x0A where depth == 0 && index + 1 < units.count && startsTopLevelCommand(at: index + 1):
                emit(upTo: index)
                index += 1
                start = index
            default:
                index += 1
            }
        }
        emit(upTo: units.count)
        return statements
    }

    static func stripJSComments(_ text: String) -> String {
        let units = Array(text.utf16)
        var kept: [UInt16] = []
        var index = 0
        while index < units.count {
            let c = units[index]
            let next = index + 1 < units.count ? units[index + 1] : 0
            if c == 0x27 || c == 0x22 || c == 0x60 {
                let end = SQLStatementSplitter.skipQuoted(units, from: index, quote: c, backslash: true)
                kept.append(contentsOf: units[index..<end])
                index = end
            } else if c == 0x2F && next == 0x2F {
                index = SQLStatementSplitter.skipLine(units, from: index)
            } else if c == 0x2F && next == 0x2A {
                index = SQLStatementSplitter.skipBlockComment(units, from: index, nested: false)
                kept.append(0x20)
            } else {
                kept.append(c)
                index += 1
            }
        }
        return String(decoding: kept, as: UTF16.self)
    }

    /// Method calls and aggregation stages that write. Field names such as `updatedAt` do not count.
    static let mongoWritePattern = #"\.\s*(insert|update|replace|delete|remove|drop|create|rename|bulkwrite|findoneand\w+|runcommand|admincommand|createindex|dropindex)\w*\s*\("#

    static func mongoIsReadOnly(_ statement: String) -> Bool {
        let code = stripJSComments(statement).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if code.hasPrefix("use ") || code.hasPrefix("show ") { return true }
        // Stage names are often written as quoted keys (`{ "$out": "copy" }`), so check them before strings are removed.
        if code.contains("$out") || code.contains("$merge") { return false }
        // Strip string literals so `{ note: ".delete(" }` stays read-only.
        let withoutStrings = code.replacingOccurrences(of: #""([^"\\]|\\.)*"|'([^'\\]|\\.)*'"#, with: "\"\"", options: .regularExpression)
        return withoutStrings.range(of: mongoWritePattern, options: .regularExpression) == nil
    }
}

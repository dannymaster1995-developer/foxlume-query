import Foundation

/// One command typed in the editor, already split into arguments.
struct RedisCommand: Equatable {
    /// Arguments as raw bytes; `\xHH` escapes can produce bytes that are not UTF-8.
    var arguments: [Data]
    /// `DB n <command>` runs the command on database `n`, then returns to the current one.
    var database: Int?

    /// Upper-cased command name, for example `HGETALL`.
    var name: String { arguments.first.map { String(decoding: $0, as: UTF8.self).uppercased() } ?? "" }

    /// Upper-cased argument at `index`, for options such as `WITHSCORES` or `MATCH`.
    func word(_ index: Int) -> String? {
        arguments.indices.contains(index) ? String(decoding: arguments[index], as: UTF8.self).uppercased() : nil
    }

    func text(_ index: Int) -> String? {
        arguments.indices.contains(index) ? String(decoding: arguments[index], as: UTF8.self) : nil
    }

    /// Whether any argument after the name equals `option`, ignoring case.
    func hasOption(_ option: String) -> Bool {
        arguments.indices.dropFirst().contains { word($0) == option }
    }
}

enum RedisCommandParser {
    /// Splits one line with redis-cli rules (`sdssplitargs`):
    /// - whitespace separates arguments;
    /// - `"…"` understands `\n \r \t \b \a \xHH`, and a backslash before any other character keeps that character;
    /// - `'…'` understands only `\'`;
    /// - a closing quote must be followed by whitespace or the end of the line;
    /// - an unbalanced quote is an error.
    static func tokenize(_ line: String) throws -> [Data] {
        let bytes = Array(line.utf8)
        var arguments: [Data] = []
        var index = 0

        while index < bytes.count {
            while index < bytes.count, isBlank(bytes[index]) { index += 1 }
            guard index < bytes.count else { break }

            var current: [UInt8] = []
            var inDouble = false
            var inSingle = false
            var done = false
            while !done {
                guard index < bytes.count else {
                    if inDouble || inSingle {
                        throw DatabaseError.server(message: "Unbalanced quotes in command: \(line)", code: "ERR")
                    }
                    break
                }
                let byte = bytes[index]
                if inDouble {
                    if byte == backslash, index + 3 < bytes.count, bytes[index + 1] == UInt8(ascii: "x"),
                       let high = hexValue(bytes[index + 2]), let low = hexValue(bytes[index + 3]) {
                        current.append(high << 4 | low)
                        index += 4
                    } else if byte == backslash, index + 1 < bytes.count {
                        current.append(unescape(bytes[index + 1]))
                        index += 2
                    } else if byte == doubleQuote {
                        guard index + 1 >= bytes.count || isBlank(bytes[index + 1]) else {
                            throw DatabaseError.server(message: "A closing quote must be followed by a space: \(line)", code: "ERR")
                        }
                        index += 1
                        done = true
                    } else {
                        current.append(byte)
                        index += 1
                    }
                } else if inSingle {
                    if byte == backslash, index + 1 < bytes.count, bytes[index + 1] == singleQuote {
                        current.append(singleQuote)
                        index += 2
                    } else if byte == singleQuote {
                        guard index + 1 >= bytes.count || isBlank(bytes[index + 1]) else {
                            throw DatabaseError.server(message: "A closing quote must be followed by a space: \(line)", code: "ERR")
                        }
                        index += 1
                        done = true
                    } else {
                        current.append(byte)
                        index += 1
                    }
                } else {
                    switch byte {
                    case _ where isBlank(byte):
                        done = true
                    case doubleQuote:
                        inDouble = true
                        index += 1
                    case singleQuote:
                        inSingle = true
                        index += 1
                    default:
                        current.append(byte)
                        index += 1
                    }
                }
            }
            arguments.append(Data(current))
        }
        return arguments
    }

    /// Tokenizes a statement and peels off a leading `DB n`.
    static func parse(_ statement: String) throws -> RedisCommand {
        var arguments = try tokenize(statement)
        guard !arguments.isEmpty else { throw DatabaseError.server(message: "Empty command", code: "ERR") }
        var database: Int?
        if String(decoding: arguments[0], as: UTF8.self).uppercased() == "DB" {
            guard arguments.count >= 3 else {
                throw DatabaseError.server(message: "Usage: DB <index> <command>", code: "ERR")
            }
            guard let index = Int(String(decoding: arguments[1], as: UTF8.self)), index >= 0 else {
                throw DatabaseError.server(message: "DB expects a database index, got \"\(String(decoding: arguments[1], as: UTF8.self))\"", code: "ERR")
            }
            database = index
            arguments.removeFirst(2)
        }
        return RedisCommand(arguments: arguments, database: database)
    }

    /// `db3` or `3` → 3.
    static func databaseIndex(_ name: String) -> Int? {
        var text = name.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("db") { text.removeFirst(2) }
        guard let index = Int(text), index >= 0 else { return nil }
        return index
    }

    /// Commands that put the connection in a mode where replies no longer pair with requests.
    static let unsupportedCommands: [String: String] = [
        "SUBSCRIBE": "Pub/sub subscriptions", "PSUBSCRIBE": "Pub/sub subscriptions", "SSUBSCRIBE": "Pub/sub subscriptions",
        "UNSUBSCRIBE": "Pub/sub subscriptions", "PUNSUBSCRIBE": "Pub/sub subscriptions", "SUNSUBSCRIBE": "Pub/sub subscriptions",
        "MONITOR": "MONITOR", "SYNC": "SYNC", "PSYNC": "PSYNC", "RESET": "RESET",
    ]

    /// Commands the server may hold open; `cancel()` frees them with `CLIENT UNBLOCK`.
    static func isBlocking(_ command: RedisCommand) -> Bool {
        switch command.name {
        case "BLPOP", "BRPOP", "BRPOPLPUSH", "BLMOVE", "BLMPOP", "BZPOPMIN", "BZPOPMAX", "BZMPOP", "WAIT", "WAITAOF":
            return true
        case "XREAD", "XREADGROUP":
            return command.hasOption("BLOCK")
        default:
            return false
        }
    }

    enum ScriptKind { case script, function }

    /// Lua scripts and functions; `cancel()` stops them with `SCRIPT KILL` / `FUNCTION KILL`.
    static func scriptKind(_ command: RedisCommand) -> ScriptKind? {
        switch command.name {
        case "EVAL", "EVALSHA", "EVAL_RO", "EVALSHA_RO": return .script
        case "FCALL", "FCALL_RO": return .function
        default: return nil
        }
    }

    /// Commands that address no key and can run on any cluster node.
    static let keylessCommands: Set<String> = [
        "PING", "ECHO", "INFO", "DBSIZE", "KEYS", "SCAN", "RANDOMKEY", "CONFIG", "CLIENT", "CLUSTER", "COMMAND", "TIME",
        "LASTSAVE", "FLUSHDB", "FLUSHALL", "SELECT", "MULTI", "EXEC", "DISCARD", "SCRIPT", "FUNCTION", "ACL", "DEBUG",
        "SLOWLOG", "LATENCY", "ROLE", "SAVE", "BGSAVE", "BGREWRITEAOF", "WAIT", "WAITAOF", "SWAPDB", "PUBLISH", "SPUBLISH",
        "PUBSUB", "HELLO", "AUTH", "READONLY", "READWRITE", "ASKING", "LOLWUT", "MODULE", "FAILOVER", "SHUTDOWN", "QUIT",
        "MEMORY", "OBJECT", "XINFO", "XGROUP", "REPLICAOF", "SLAVEOF", "HOTKEYS",
    ]

    /// The key that decides which cluster node serves the command, or nil for keyless commands.
    /// A wrong guess costs one `MOVED` redirect, so only common shapes are modelled.
    static func routingKey(_ command: RedisCommand) -> Data? {
        let arguments = command.arguments
        func argument(_ index: Int) -> Data? { arguments.indices.contains(index) ? arguments[index] : nil }
        func numkeysKey(at numkeysIndex: Int) -> Data? {
            guard let count = command.text(numkeysIndex).flatMap(Int.init), count > 0 else { return nil }
            return argument(numkeysIndex + 1)
        }
        switch command.name {
        case "EVAL", "EVALSHA", "EVAL_RO", "EVALSHA_RO", "FCALL", "FCALL_RO":
            return numkeysKey(at: 2)
        case "OBJECT", "MEMORY", "XINFO", "XGROUP":
            return argument(2)
        case "BITOP":
            return argument(2)
        case "ZUNION", "ZINTER", "ZDIFF", "SINTERCARD", "ZINTERCARD", "LMPOP", "ZMPOP":
            return numkeysKey(at: 1)
        case "BLMPOP", "BZMPOP":
            return numkeysKey(at: 2)
        case "XREAD", "XREADGROUP":
            guard let streams = arguments.indices.first(where: { command.word($0) == "STREAMS" }) else { return nil }
            return argument(streams + 1)
        default:
            if keylessCommands.contains(command.name) { return nil }
            return argument(1)
        }
    }
}

private let backslash = UInt8(ascii: "\\")
private let doubleQuote = UInt8(ascii: "\"")
private let singleQuote = UInt8(ascii: "'")

private func isBlank(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0B || byte == 0x0C
}

private func unescape(_ byte: UInt8) -> UInt8 {
    switch byte {
    case UInt8(ascii: "n"): return 0x0A
    case UInt8(ascii: "r"): return 0x0D
    case UInt8(ascii: "t"): return 0x09
    case UInt8(ascii: "b"): return 0x08
    case UInt8(ascii: "a"): return 0x07
    default: return byte
    }
}

private func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
    default: return nil
    }
}

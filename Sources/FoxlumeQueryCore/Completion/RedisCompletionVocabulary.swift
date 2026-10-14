import Foundation

/// One Redis command as the completer knows it: an argument hint, a summary, where keys go and which option words
/// it takes. Names and syntax are Redis's public command reference; summaries are Foxlume Query's own.
struct RedisCommandSpec: Sendable {
    /// Which arguments (1-based, after the command name) are key names.
    enum Keys: Sendable {
        case none
        case first
        case firstTwo
        case all
        /// `MSET key value [key value …]`
        case pairs
        case from(Int)
        case at(Int)
        /// `numkeys key [key …]`: argument `countAt` says how many keys follow it; `also` are other key positions
        /// (a destination).
        case counted(countAt: Int, also: [Int])
        /// `key [key …] timeout`: any argument after the first may be the closing number.
        case thenTimeout
        /// `… STREAMS key [key …] id [id …]`: keys and ids share the arguments after STREAMS.
        case streams
    }

    /// Whether an argument names a key: surely, possibly (offered once something is typed), or not.
    enum KeyRole: Equatable {
        case no
        case yes
        case maybe
    }

    let name: String
    let arguments: String?
    let summary: String
    var keys: Keys = .none
    /// Option words offered from argument `optionsFrom` on.
    var options: [String] = []
    var optionsFrom = 1
    /// Offered as the first argument (`CONFIG GET`, `OBJECT ENCODING`).
    var subcommands: [String] = []

    /// The role of argument `index`; `words[i]` is argument `i` as typed (`words[0]` the command) for as many
    /// leading arguments as the analysis kept, `streamsAt` the index of a STREAMS word.
    func keyRole(at index: Int, words: [String], streamsAt: Int?) -> KeyRole {
        switch keys {
        case .none: return .no
        case .first: return index == 1 ? .yes : .no
        case .firstTwo: return index == 1 || index == 2 ? .yes : .no
        case .all: return index >= 1 ? .yes : .no
        case .pairs: return index % 2 == 1 ? .yes : .no
        case .from(let first): return index >= first ? .yes : .no
        case .at(let position): return index == position ? .yes : .no
        case let .counted(countAt, also):
            if also.contains(index) { return .yes }
            guard index > countAt, let count = Self.count(words, at: countAt) else { return .no }
            return index <= countAt + count ? .yes : .no
        case .thenTimeout:
            return index == 1 ? .yes : .maybe
        case .streams:
            guard let streams = streamsAt, index > streams else { return .no }
            return index == streams + 1 ? .yes : .maybe
        }
    }

    /// Option words fit from `optionsFrom` on, after a counted key list only once its keys are past, and never
    /// after STREAMS.
    func offersOptions(at index: Int, words: [String], streamsAt: Int?) -> Bool {
        guard !options.isEmpty, index >= optionsFrom else { return false }
        switch keys {
        case .counted(let countAt, _):
            guard let count = Self.count(words, at: countAt) else { return false }
            return index > countAt + count
        case .streams:
            return streamsAt == nil
        default:
            return true
        }
    }

    private static func count(_ words: [String], at index: Int) -> Int? {
        guard index < words.count, let count = Int(words[index]), count >= 0 else { return nil }
        return count
    }
}

enum RedisCompletionVocabulary {
    private typealias C = RedisCommandSpec

    private static func c(_ name: String, _ arguments: String?, _ summary: String, keys: C.Keys = .none, options: [String] = [], from: Int = 1, subcommands: [String] = []) -> C {
        C(name: name, arguments: arguments, summary: summary, keys: keys, options: options, optionsFrom: from, subcommands: subcommands)
    }

    private static let expiryConditions = ["NX", "XX", "GT", "LT"]
    private static let scanOptions = ["MATCH", "COUNT"]

    /// Common commands, A-Z.
    static let commands: [RedisCommandSpec] = [
        c("ACL", "subcommand [arg …]", "Users, permissions and the access log", subcommands: ["CAT", "DELUSER", "DRYRUN", "GENPASS", "GETUSER", "LIST", "LOG", "SETUSER", "USERS", "WHOAMI"]),
        c("APPEND", "key value", "Add text to the end of a string", keys: .first),
        c("AUTH", "[username] password", "Authenticate the connection"),
        c("BGREWRITEAOF", nil, "Rewrite the append-only file in the background"),
        c("BGSAVE", nil, "Save a snapshot in the background"),
        c("BITCOUNT", "key [start end [BYTE|BIT]]", "Number of bits set to 1", keys: .first, options: ["BYTE", "BIT"], from: 4),
        c("BITFIELD", "key [GET|SET|INCRBY …]", "Read and write integer fields inside a string", keys: .first, options: ["GET", "SET", "INCRBY", "OVERFLOW", "WRAP", "SAT", "FAIL"], from: 2),
        c("BITOP", "operation destkey key [key …]", "Bitwise operation across strings", keys: .from(2), subcommands: ["AND", "OR", "XOR", "NOT"]),
        c("BITPOS", "key bit [start [end [BYTE|BIT]]]", "Position of the first bit set to 0 or 1", keys: .first, options: ["BYTE", "BIT"], from: 5),
        c("BLMOVE", "source destination LEFT|RIGHT LEFT|RIGHT timeout", "Blocking LMOVE", keys: .firstTwo, options: ["LEFT", "RIGHT"], from: 3),
        c("BLMPOP", "timeout numkeys key [key …] LEFT|RIGHT [COUNT count]", "Blocking LMPOP", keys: .counted(countAt: 2, also: []), options: ["LEFT", "RIGHT", "COUNT"], from: 3),
        c("BLPOP", "key [key …] timeout", "Pop from the head of a list, waiting if empty", keys: .thenTimeout),
        c("BRPOP", "key [key …] timeout", "Pop from the tail of a list, waiting if empty", keys: .thenTimeout),
        c("BRPOPLPUSH", "source destination timeout", "Blocking RPOPLPUSH", keys: .firstTwo),
        c("BZMPOP", "timeout numkeys key [key …] MIN|MAX [COUNT count]", "Blocking ZMPOP", keys: .counted(countAt: 2, also: []), options: ["MIN", "MAX", "COUNT"], from: 3),
        c("BZPOPMAX", "key [key …] timeout", "Pop the highest-scored member, waiting if empty", keys: .thenTimeout),
        c("BZPOPMIN", "key [key …] timeout", "Pop the lowest-scored member, waiting if empty", keys: .thenTimeout),
        c("CLIENT", "subcommand [arg …]", "Inspect and manage client connections", subcommands: ["GETNAME", "ID", "INFO", "KILL", "LIST", "NO-EVICT", "NO-TOUCH", "PAUSE", "REPLY", "SETNAME", "TRACKING", "UNBLOCK", "UNPAUSE"]),
        c("CLUSTER", "subcommand [arg …]", "Cluster state and slot information", subcommands: ["COUNTKEYSINSLOT", "GETKEYSINSLOT", "INFO", "KEYSLOT", "MYID", "NODES", "SHARDS", "SLOTS"]),
        c("COMMAND", "[subcommand]", "Details about the server's commands", subcommands: ["COUNT", "DOCS", "GETKEYS", "INFO", "LIST"]),
        c("CONFIG", "subcommand [arg …]", "Read or change server configuration", subcommands: ["GET", "RESETSTAT", "REWRITE", "SET"]),
        c("COPY", "source destination [DB db] [REPLACE]", "Copy a key's value to another key", keys: .firstTwo, options: ["DB", "REPLACE"], from: 3),
        c("DB", "index command [arg …]", "Run one command on another database (FoxlumeQuery)"),
        c("DBSIZE", nil, "Number of keys in the current database"),
        c("DECR", "key", "Subtract 1 from an integer", keys: .first),
        c("DECRBY", "key decrement", "Subtract a number from an integer", keys: .first),
        c("DEL", "key [key …]", "Delete keys", keys: .all),
        c("DISCARD", nil, "Abandon a MULTI transaction"),
        c("DUMP", "key", "Serialized form of a key's value", keys: .first),
        c("ECHO", "message", "Return the message"),
        c("EVAL", "script numkeys [key …] [arg …]", "Run a Lua script", keys: .counted(countAt: 2, also: [])),
        c("EVALSHA", "sha1 numkeys [key …] [arg …]", "Run a cached Lua script by its digest", keys: .counted(countAt: 2, also: [])),
        c("EVALSHA_RO", "sha1 numkeys [key …] [arg …]", "Read-only EVALSHA", keys: .counted(countAt: 2, also: [])),
        c("EVAL_RO", "script numkeys [key …] [arg …]", "Read-only EVAL", keys: .counted(countAt: 2, also: [])),
        c("EXEC", nil, "Run the queued MULTI transaction"),
        c("EXISTS", "key [key …]", "How many of the keys exist", keys: .all),
        c("EXPIRE", "key seconds [NX|XX|GT|LT]", "Set a time to live in seconds", keys: .first, options: expiryConditions, from: 3),
        c("EXPIREAT", "key unix-time [NX|XX|GT|LT]", "Expire at a Unix time in seconds", keys: .first, options: expiryConditions, from: 3),
        c("EXPIRETIME", "key", "Unix time in seconds when the key expires", keys: .first),
        c("FCALL", "function numkeys [key …] [arg …]", "Call a library function", keys: .counted(countAt: 2, also: [])),
        c("FCALL_RO", "function numkeys [key …] [arg …]", "Call a read-only library function", keys: .counted(countAt: 2, also: [])),
        c("FLUSHALL", "[ASYNC|SYNC]", "Delete every key in every database", options: ["ASYNC", "SYNC"]),
        c("FLUSHDB", "[ASYNC|SYNC]", "Delete every key in the current database", options: ["ASYNC", "SYNC"]),
        c("FUNCTION", "subcommand [arg …]", "Manage function libraries", subcommands: ["DELETE", "DUMP", "FLUSH", "KILL", "LIST", "LOAD", "RESTORE", "STATS"]),
        c("GEOADD", "key [NX|XX] [CH] longitude latitude member …", "Add members with coordinates", keys: .first, options: ["NX", "XX", "CH"], from: 2),
        c("GEODIST", "key member1 member2 [M|KM|FT|MI]", "Distance between two members", keys: .first, options: ["M", "KM", "FT", "MI"], from: 4),
        c("GEOHASH", "key member [member …]", "Geohash strings of members", keys: .first),
        c("GEOPOS", "key member [member …]", "Coordinates of members", keys: .first),
        c("GEOSEARCH", "key FROMMEMBER member|FROMLONLAT lon lat BYRADIUS r unit|BYBOX w h unit …", "Members inside an area", keys: .first, options: ["FROMMEMBER", "FROMLONLAT", "BYRADIUS", "BYBOX", "ASC", "DESC", "COUNT", "ANY", "WITHCOORD", "WITHDIST", "WITHHASH", "M", "KM", "FT", "MI"], from: 2),
        c("GEOSEARCHSTORE", "destination source FROMMEMBER …|FROMLONLAT … BYRADIUS …|BYBOX …", "GEOSEARCH stored into a key", keys: .firstTwo, options: ["FROMMEMBER", "FROMLONLAT", "BYRADIUS", "BYBOX", "ASC", "DESC", "COUNT", "ANY", "STOREDIST", "M", "KM", "FT", "MI"], from: 3),
        c("GET", "key", "Value of a string key", keys: .first),
        c("GETBIT", "key offset", "Bit value at an offset", keys: .first),
        c("GETDEL", "key", "Get a string and delete the key", keys: .first),
        c("GETEX", "key [EX seconds|PX ms|EXAT time|PXAT time|PERSIST]", "Get a string and change its expiry", keys: .first, options: ["EX", "PX", "EXAT", "PXAT", "PERSIST"], from: 2),
        c("GETRANGE", "key start end", "Part of a string", keys: .first),
        c("GETSET", "key value", "Set a string and return the old value", keys: .first),
        c("HDEL", "key field [field …]", "Delete hash fields", keys: .first),
        c("HELLO", "[protover [AUTH username password] [SETNAME name]]", "Handshake: protocol version and server details", options: ["AUTH", "SETNAME"], from: 2),
        c("HEXISTS", "key field", "Whether a hash field exists", keys: .first),
        c("HEXPIRE", "key seconds [NX|XX|GT|LT] FIELDS numfields field …", "Set a time to live on hash fields", keys: .first, options: expiryConditions + ["FIELDS"], from: 3),
        c("HGET", "key field", "Value of a hash field", keys: .first),
        c("HGETALL", "key", "Every field and value of a hash", keys: .first),
        c("HINCRBY", "key field increment", "Add to an integer hash field", keys: .first),
        c("HINCRBYFLOAT", "key field increment", "Add to a floating point hash field", keys: .first),
        c("HKEYS", "key", "Field names of a hash", keys: .first),
        c("HLEN", "key", "Number of fields in a hash", keys: .first),
        c("HMGET", "key field [field …]", "Values of several hash fields", keys: .first),
        c("HMSET", "key field value [field value …]", "Set several hash fields (older form of HSET)", keys: .first),
        c("HPERSIST", "key FIELDS numfields field …", "Remove the time to live of hash fields", keys: .first, options: ["FIELDS"], from: 2),
        c("HRANDFIELD", "key [count [WITHVALUES]]", "Random fields of a hash", keys: .first, options: ["WITHVALUES"], from: 3),
        c("HSCAN", "key cursor [MATCH pattern] [COUNT count] [NOVALUES]", "Iterate over the fields of a hash", keys: .first, options: scanOptions + ["NOVALUES"], from: 3),
        c("HSET", "key field value [field value …]", "Set hash fields", keys: .first),
        c("HSETNX", "key field value", "Set a hash field only if it is new", keys: .first),
        c("HSTRLEN", "key field", "Length of a hash field's value", keys: .first),
        c("HTTL", "key FIELDS numfields field …", "Time to live of hash fields", keys: .first, options: ["FIELDS"], from: 2),
        c("HVALS", "key", "Values of a hash", keys: .first),
        c("INCR", "key", "Add 1 to an integer", keys: .first),
        c("INCRBY", "key increment", "Add a number to an integer", keys: .first),
        c("INCRBYFLOAT", "key increment", "Add a number to a floating point value", keys: .first),
        c("INFO", "[section …]", "Server information and statistics", options: ["ALL", "CLIENTS", "CLUSTER", "COMMANDSTATS", "CPU", "DEFAULT", "ERRORSTATS", "EVERYTHING", "KEYSPACE", "LATENCYSTATS", "MEMORY", "MODULES", "PERSISTENCE", "REPLICATION", "SERVER", "STATS"]),
        c("JSON.ARRAPPEND", "key path value [value …]", "Append to a JSON array", keys: .first),
        c("JSON.ARRLEN", "key [path]", "Length of a JSON array", keys: .first),
        c("JSON.DEL", "key [path]", "Delete a JSON value", keys: .first),
        c("JSON.GET", "key [path …]", "Read JSON values", keys: .first),
        c("JSON.MGET", "key [key …] path", "Read one path from several JSON keys", keys: .all),
        c("JSON.NUMINCRBY", "key path value", "Add to a JSON number", keys: .first),
        c("JSON.OBJKEYS", "key [path]", "Keys of a JSON object", keys: .first),
        c("JSON.OBJLEN", "key [path]", "Number of keys in a JSON object", keys: .first),
        c("JSON.SET", "key path value [NX|XX]", "Write a JSON value", keys: .first, options: ["NX", "XX"], from: 4),
        c("JSON.STRLEN", "key [path]", "Length of a JSON string", keys: .first),
        c("JSON.TYPE", "key [path]", "Type of a JSON value", keys: .first),
        c("KEYS", "pattern", "Keys matching a glob pattern (blocks the server; prefer SCAN)"),
        c("LASTSAVE", nil, "Unix time of the last successful save"),
        c("LATENCY", "subcommand [arg …]", "Latency monitoring", subcommands: ["DOCTOR", "GRAPH", "HISTOGRAM", "HISTORY", "LATEST", "RESET"]),
        c("LCS", "key1 key2 [LEN] [IDX] [MINMATCHLEN len] [WITHMATCHLEN]", "Longest common substring of two strings", keys: .firstTwo, options: ["LEN", "IDX", "MINMATCHLEN", "WITHMATCHLEN"], from: 3),
        c("LINDEX", "key index", "List element at an index", keys: .first),
        c("LINSERT", "key BEFORE|AFTER pivot element", "Insert next to an existing element", keys: .first, options: ["BEFORE", "AFTER"], from: 2),
        c("LLEN", "key", "Length of a list", keys: .first),
        c("LMOVE", "source destination LEFT|RIGHT LEFT|RIGHT", "Move an element between lists", keys: .firstTwo, options: ["LEFT", "RIGHT"], from: 3),
        c("LMPOP", "numkeys key [key …] LEFT|RIGHT [COUNT count]", "Pop from the first non-empty list", keys: .counted(countAt: 1, also: []), options: ["LEFT", "RIGHT", "COUNT"], from: 2),
        c("LPOP", "key [count]", "Remove and return elements from the head", keys: .first),
        c("LPOS", "key element [RANK rank] [COUNT n] [MAXLEN len]", "Index of matching list elements", keys: .first, options: ["RANK", "COUNT", "MAXLEN"], from: 3),
        c("LPUSH", "key element [element …]", "Add elements to the head of a list", keys: .first),
        c("LPUSHX", "key element [element …]", "LPUSH only if the list exists", keys: .first),
        c("LRANGE", "key start stop", "List elements in a range", keys: .first),
        c("LREM", "key count element", "Remove matching elements from a list", keys: .first),
        c("LSET", "key index element", "Replace the element at an index", keys: .first),
        c("LTRIM", "key start stop", "Keep only a range of a list", keys: .first),
        c("MEMORY", "subcommand [arg …]", "Memory usage and allocator details", keys: .at(2), subcommands: ["DOCTOR", "MALLOC-STATS", "PURGE", "STATS", "USAGE"]),
        c("MGET", "key [key …]", "Values of several string keys", keys: .all),
        c("MODULE", "subcommand [arg …]", "Load, unload and list server modules", subcommands: ["LIST", "LOAD", "LOADEX", "UNLOAD"]),
        c("MOVE", "key db", "Move a key to another database", keys: .first),
        c("MSET", "key value [key value …]", "Set several string keys", keys: .pairs),
        c("MSETNX", "key value [key value …]", "MSET only if none of the keys exist", keys: .pairs),
        c("MULTI", nil, "Start a transaction"),
        c("OBJECT", "subcommand key", "Internal details of a key's value", keys: .at(2), subcommands: ["ENCODING", "FREQ", "IDLETIME", "REFCOUNT"]),
        c("PERSIST", "key", "Remove a key's time to live", keys: .first),
        c("PEXPIRE", "key milliseconds [NX|XX|GT|LT]", "Set a time to live in milliseconds", keys: .first, options: expiryConditions, from: 3),
        c("PEXPIREAT", "key unix-time-ms [NX|XX|GT|LT]", "Expire at a Unix time in milliseconds", keys: .first, options: expiryConditions, from: 3),
        c("PEXPIRETIME", "key", "Unix time in milliseconds when the key expires", keys: .first),
        c("PFADD", "key [element …]", "Add elements to a HyperLogLog", keys: .first),
        c("PFCOUNT", "key [key …]", "Estimated number of distinct elements", keys: .all),
        c("PFMERGE", "destkey [sourcekey …]", "Merge HyperLogLogs", keys: .all),
        c("PING", "[message]", "Check that the server answers"),
        c("PSETEX", "key milliseconds value", "Set a string with a time to live in milliseconds", keys: .first),
        c("PTTL", "key", "Time to live in milliseconds", keys: .first),
        c("PUBLISH", "channel message", "Post a message to a channel"),
        c("PUBSUB", "subcommand [arg …]", "Pub/sub channels and subscribers", subcommands: ["CHANNELS", "NUMPAT", "NUMSUB", "SHARDCHANNELS", "SHARDNUMSUB"]),
        c("QUIT", nil, "Close the connection"),
        c("RANDOMKEY", nil, "A random key from the current database"),
        c("RENAME", "key newkey", "Rename a key", keys: .firstTwo),
        c("RENAMENX", "key newkey", "Rename a key only if the new name is free", keys: .firstTwo),
        c("REPLICAOF", "host port", "Replicate another server, or NO ONE to stop"),
        c("RESTORE", "key ttl serialized-value [REPLACE] [ABSTTL] [IDLETIME s] [FREQ f]", "Create a key from DUMP output", keys: .first, options: ["REPLACE", "ABSTTL", "IDLETIME", "FREQ"], from: 4),
        c("ROLE", nil, "Replication role of the server"),
        c("RPOP", "key [count]", "Remove and return elements from the tail", keys: .first),
        c("RPOPLPUSH", "source destination", "Move the last element of a list to the head of another", keys: .firstTwo),
        c("RPUSH", "key element [element …]", "Add elements to the tail of a list", keys: .first),
        c("RPUSHX", "key element [element …]", "RPUSH only if the list exists", keys: .first),
        c("SADD", "key member [member …]", "Add members to a set", keys: .first),
        c("SAVE", nil, "Save a snapshot, blocking the server"),
        c("SCAN", "cursor [MATCH pattern] [COUNT count] [TYPE type]", "Iterate over the keys of the database", options: scanOptions + ["TYPE"], from: 2),
        c("SCARD", "key", "Number of members in a set", keys: .first),
        c("SCRIPT", "subcommand [arg …]", "Manage the Lua script cache", subcommands: ["EXISTS", "FLUSH", "KILL", "LOAD"]),
        c("SDIFF", "key [key …]", "Members of the first set missing from the others", keys: .all),
        c("SDIFFSTORE", "destination key [key …]", "SDIFF stored into a key", keys: .all),
        c("SELECT", "index", "Switch the connection to another database"),
        c("SET", "key value [NX|XX] [GET] [EX seconds|PX ms|EXAT time|PXAT time|KEEPTTL]", "Set a string value", keys: .first, options: ["EX", "PX", "EXAT", "PXAT", "NX", "XX", "KEEPTTL", "GET"], from: 3),
        c("SETBIT", "key offset value", "Set or clear one bit", keys: .first),
        c("SETEX", "key seconds value", "Set a string with a time to live in seconds", keys: .first),
        c("SETNX", "key value", "Set a string only if the key is new", keys: .first),
        c("SETRANGE", "key offset value", "Overwrite part of a string", keys: .first),
        c("SHUTDOWN", "[NOSAVE|SAVE] [NOW] [FORCE] [ABORT]", "Stop the server", options: ["NOSAVE", "SAVE", "NOW", "FORCE", "ABORT"]),
        c("SINTER", "key [key …]", "Members common to every set", keys: .all),
        c("SINTERCARD", "numkeys key [key …] [LIMIT limit]", "Size of the intersection of sets", keys: .counted(countAt: 1, also: []), options: ["LIMIT"], from: 3),
        c("SINTERSTORE", "destination key [key …]", "SINTER stored into a key", keys: .all),
        c("SISMEMBER", "key member", "Whether a value is in a set", keys: .first),
        c("SLOWLOG", "subcommand [arg]", "Log of slow commands", subcommands: ["GET", "LEN", "RESET"]),
        c("SMEMBERS", "key", "Every member of a set", keys: .first),
        c("SMISMEMBER", "key member [member …]", "Whether each value is in a set", keys: .first),
        c("SMOVE", "source destination member", "Move a member between sets", keys: .firstTwo),
        c("SORT", "key [BY pattern] [LIMIT offset count] [GET pattern …] [ASC|DESC] [ALPHA] [STORE destination]", "Sorted elements of a list, set or sorted set", keys: .first, options: ["BY", "LIMIT", "GET", "ASC", "DESC", "ALPHA", "STORE"], from: 2),
        c("SORT_RO", "key [BY pattern] [LIMIT offset count] [GET pattern …] [ASC|DESC] [ALPHA]", "Read-only SORT", keys: .first, options: ["BY", "LIMIT", "GET", "ASC", "DESC", "ALPHA"], from: 2),
        c("SPOP", "key [count]", "Remove and return random members", keys: .first),
        c("SRANDMEMBER", "key [count]", "Random members of a set", keys: .first),
        c("SREM", "key member [member …]", "Remove members from a set", keys: .first),
        c("SSCAN", "key cursor [MATCH pattern] [COUNT count]", "Iterate over the members of a set", keys: .first, options: scanOptions, from: 3),
        c("STRLEN", "key", "Length of a string value", keys: .first),
        c("SUBSTR", "key start end", "Part of a string (older name of GETRANGE)", keys: .first),
        c("SUNION", "key [key …]", "Members of any of the sets", keys: .all),
        c("SUNIONSTORE", "destination key [key …]", "SUNION stored into a key", keys: .all),
        c("SWAPDB", "index1 index2", "Swap two databases"),
        c("TIME", nil, "Server time"),
        c("TOUCH", "key [key …]", "Update the last access time of keys", keys: .all),
        c("TTL", "key", "Time to live in seconds", keys: .first),
        c("TYPE", "key", "Type of the value at a key", keys: .first),
        c("UNLINK", "key [key …]", "Delete keys, freeing memory in the background", keys: .all),
        c("UNWATCH", nil, "Forget every WATCHed key"),
        c("WAIT", "numreplicas timeout", "Wait for replicas to acknowledge writes"),
        c("WAITAOF", "numlocal numreplicas timeout", "Wait until writes reach the append-only file"),
        c("WATCH", "key [key …]", "Abort the next transaction if these keys change", keys: .all),
        c("XACK", "key group id [id …]", "Acknowledge stream messages", keys: .first),
        c("XADD", "key [NOMKSTREAM] [MAXLEN|MINID [=|~] threshold [LIMIT count]] *|id field value …", "Append an entry to a stream", keys: .first, options: ["NOMKSTREAM", "MAXLEN", "MINID", "LIMIT"], from: 2),
        c("XAUTOCLAIM", "key group consumer min-idle-time start [COUNT count] [JUSTID]", "Take over idle pending messages", keys: .first, options: ["COUNT", "JUSTID"], from: 6),
        c("XCLAIM", "key group consumer min-idle-time id [id …] [IDLE ms] [TIME ms] [RETRYCOUNT n] [FORCE] [JUSTID]", "Change the owner of pending messages", keys: .first, options: ["IDLE", "TIME", "RETRYCOUNT", "FORCE", "JUSTID"], from: 6),
        c("XDEL", "key id [id …]", "Delete stream entries", keys: .first),
        c("XGROUP", "subcommand key group [arg …]", "Manage consumer groups", keys: .at(2), subcommands: ["CREATE", "CREATECONSUMER", "DELCONSUMER", "DESTROY", "SETID"]),
        c("XINFO", "subcommand key [arg …]", "Details about streams, groups and consumers", keys: .at(2), subcommands: ["CONSUMERS", "GROUPS", "STREAM"]),
        c("XLEN", "key", "Number of entries in a stream", keys: .first),
        c("XPENDING", "key group [[IDLE min-idle-time] start end count [consumer]]", "Pending messages of a consumer group", keys: .first, options: ["IDLE"], from: 3),
        c("XRANGE", "key start end [COUNT count]", "Stream entries in an id range", keys: .first, options: ["COUNT"], from: 4),
        c("XREAD", "[COUNT count] [BLOCK ms] STREAMS key [key …] id [id …]", "Read entries from streams", keys: .streams, options: ["COUNT", "BLOCK", "STREAMS"]),
        c("XREADGROUP", "GROUP group consumer [COUNT count] [BLOCK ms] [NOACK] STREAMS key [key …] id [id …]", "Read entries as a consumer group member", keys: .streams, options: ["GROUP", "COUNT", "BLOCK", "NOACK", "STREAMS"]),
        c("XREVRANGE", "key end start [COUNT count]", "Stream entries in an id range, newest first", keys: .first, options: ["COUNT"], from: 4),
        c("XTRIM", "key MAXLEN|MINID [=|~] threshold [LIMIT count]", "Trim a stream", keys: .first, options: ["MAXLEN", "MINID", "LIMIT"], from: 2),
        c("ZADD", "key [NX|XX] [GT|LT] [CH] [INCR] score member [score member …]", "Add members with scores to a sorted set", keys: .first, options: ["NX", "XX", "GT", "LT", "CH", "INCR"], from: 2),
        c("ZCARD", "key", "Number of members in a sorted set", keys: .first),
        c("ZCOUNT", "key min max", "Members with a score in a range", keys: .first),
        c("ZDIFF", "numkeys key [key …] [WITHSCORES]", "Members of the first sorted set missing from the others", keys: .counted(countAt: 1, also: []), options: ["WITHSCORES"], from: 3),
        c("ZDIFFSTORE", "destination numkeys key [key …]", "ZDIFF stored into a key", keys: .counted(countAt: 2, also: [1])),
        c("ZINCRBY", "key increment member", "Add to a member's score", keys: .first),
        c("ZINTER", "numkeys key [key …] [WEIGHTS w …] [AGGREGATE SUM|MIN|MAX] [WITHSCORES]", "Members common to every sorted set", keys: .counted(countAt: 1, also: []), options: ["WEIGHTS", "AGGREGATE", "SUM", "MIN", "MAX", "WITHSCORES"], from: 3),
        c("ZINTERCARD", "numkeys key [key …] [LIMIT limit]", "Size of the intersection of sorted sets", keys: .counted(countAt: 1, also: []), options: ["LIMIT"], from: 3),
        c("ZINTERSTORE", "destination numkeys key [key …] [WEIGHTS w …] [AGGREGATE SUM|MIN|MAX]", "ZINTER stored into a key", keys: .counted(countAt: 2, also: [1]), options: ["WEIGHTS", "AGGREGATE", "SUM", "MIN", "MAX"], from: 4),
        c("ZLEXCOUNT", "key min max", "Members in a lexicographical range", keys: .first),
        c("ZMPOP", "numkeys key [key …] MIN|MAX [COUNT count]", "Pop from the first non-empty sorted set", keys: .counted(countAt: 1, also: []), options: ["MIN", "MAX", "COUNT"], from: 3),
        c("ZMSCORE", "key member [member …]", "Scores of several members", keys: .first),
        c("ZPOPMAX", "key [count]", "Remove and return the highest-scored members", keys: .first),
        c("ZPOPMIN", "key [count]", "Remove and return the lowest-scored members", keys: .first),
        c("ZRANDMEMBER", "key [count [WITHSCORES]]", "Random members of a sorted set", keys: .first, options: ["WITHSCORES"], from: 3),
        c("ZRANGE", "key start stop [BYSCORE|BYLEX] [REV] [LIMIT offset count] [WITHSCORES]", "Members in a range of ranks, scores or names", keys: .first, options: ["BYSCORE", "BYLEX", "REV", "LIMIT", "WITHSCORES"], from: 4),
        c("ZRANGEBYLEX", "key min max [LIMIT offset count]", "Members in a lexicographical range", keys: .first, options: ["LIMIT"], from: 4),
        c("ZRANGEBYSCORE", "key min max [WITHSCORES] [LIMIT offset count]", "Members in a score range", keys: .first, options: ["WITHSCORES", "LIMIT"], from: 4),
        c("ZRANGESTORE", "destination source min max [BYSCORE|BYLEX] [REV] [LIMIT offset count]", "ZRANGE stored into a key", keys: .firstTwo, options: ["BYSCORE", "BYLEX", "REV", "LIMIT"], from: 5),
        c("ZRANK", "key member [WITHSCORE]", "Rank of a member, lowest score first", keys: .first, options: ["WITHSCORE"], from: 3),
        c("ZREM", "key member [member …]", "Remove members from a sorted set", keys: .first),
        c("ZREMRANGEBYLEX", "key min max", "Remove members in a lexicographical range", keys: .first),
        c("ZREMRANGEBYRANK", "key start stop", "Remove members in a range of ranks", keys: .first),
        c("ZREMRANGEBYSCORE", "key min max", "Remove members in a score range", keys: .first),
        c("ZREVRANGE", "key start stop [WITHSCORES]", "Members in a range of ranks, highest score first", keys: .first, options: ["WITHSCORES"], from: 4),
        c("ZREVRANGEBYLEX", "key max min [LIMIT offset count]", "Lexicographical range, in reverse", keys: .first, options: ["LIMIT"], from: 4),
        c("ZREVRANGEBYSCORE", "key max min [WITHSCORES] [LIMIT offset count]", "Score range, highest first", keys: .first, options: ["WITHSCORES", "LIMIT"], from: 4),
        c("ZREVRANK", "key member [WITHSCORE]", "Rank of a member, highest score first", keys: .first, options: ["WITHSCORE"], from: 3),
        c("ZSCAN", "key cursor [MATCH pattern] [COUNT count]", "Iterate over the members of a sorted set", keys: .first, options: scanOptions, from: 3),
        c("ZSCORE", "key member", "Score of a member", keys: .first),
        c("ZUNION", "numkeys key [key …] [WEIGHTS w …] [AGGREGATE SUM|MIN|MAX] [WITHSCORES]", "Members of any of the sorted sets", keys: .counted(countAt: 1, also: []), options: ["WEIGHTS", "AGGREGATE", "SUM", "MIN", "MAX", "WITHSCORES"], from: 3),
        c("ZUNIONSTORE", "destination numkeys key [key …] [WEIGHTS w …] [AGGREGATE SUM|MIN|MAX]", "ZUNION stored into a key", keys: .counted(countAt: 2, also: [1]), options: ["WEIGHTS", "AGGREGATE", "SUM", "MIN", "MAX"], from: 4),
    ]

    private static let byName: [String: RedisCommandSpec] = Dictionary(commands.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    static func command(named name: String) -> RedisCommandSpec? { byName[name.uppercased()] }
}

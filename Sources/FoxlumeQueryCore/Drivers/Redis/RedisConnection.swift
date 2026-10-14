import Foundation

/// Redis (and compatible servers) over RESP3, or RESP2 where HELLO is missing: standalone, behind Sentinel, or Cluster.
///
/// Logical databases (`db0`, `db1`, …) are listed as `.keyspace` tables whose rows are keys.
public final class RedisConnection: DatabaseConnection, TLSReporting {
    enum Mode: String {
        case standalone
        case sentinel
        case cluster
    }

    public var kind: DatabaseKind { parameters.config.kind }
    /// Unused: Redis has no SQL. Kept for the protocol.
    public let dialect: SQLDialect = .postgresql
    public private(set) var serverVersion: String = ""

    let parameters: ConnectionParameters
    /// Tests turn this off to exercise RESP2 replies.
    var preferRESP3 = true

    private(set) var mode: Mode = .standalone
    /// The server for standalone and Sentinel modes (the resolved master).
    private(set) var link: RedisNodeLink?
    private(set) var cluster: RedisClusterRouter?
    private(set) var serverInfo = RedisServerInfo()
    /// Database the session works in. `DB n` commands and browsing other databases return here.
    private(set) var databaseIndex = 0
    /// `connect()` succeeded and `close()` has not been called; a dropped link is reopened on the next call.
    private var isOpen = false
    /// SSL mode after the first connect resolved `prefer`, so reconnects and helper connections skip the probe.
    private var resolvedSSL: SSLMode = .disable
    /// CA and client certificates, read once per `connect()`.
    private var tlsContext = TLSContext(mode: .disable)

    /// MULTI opened from the editor and not yet ended.
    private(set) var inTransaction = false
    private var queuedSelect: Int?
    /// In cluster mode a transaction runs on the node that owns its first key.
    private var transactionNode: RedisEndpoint?

    /// Guards what `cancel()` reads from another thread.
    private let stateLock = NSLock()
    private var running = false
    private var generation = 0
    private var cancelRequested = false
    private var activeLink: RedisNodeLink?
    private var activeCommand: RedisCommand?

    /// Keys collected by one browse scan, as in TablePro.
    static let browseScanLimit = 10_000
    /// Keys summarized for one KEYS result when no row limit is given.
    static let keysSummaryLimit = 10_000

    public init(parameters: ConnectionParameters) {
        self.parameters = parameters
    }

    deinit { close() }

    var isTLS: Bool { link?.isTLS ?? cluster?.openLinks.first?.isTLS ?? false }
    public var tlsProtocolVersion: String? { (link ?? cluster?.openLinks.first)?.transport.tlsProtocolVersion }
    var protocolVersion: Int { link?.protocolVersion ?? cluster?.openLinks.first?.protocolVersion ?? 0 }

    public var capabilities: EngineCapabilities {
        EngineCapabilities(
            queryLanguage: .redis,
            objectNoun: "database",
            objectNounPlural: "databases",
            rowNoun: "key",
            supportsDDL: false,
            supportsForeignKeys: false,
            supportsIndexes: false,
            savesAtomically: true,
            rawFilterLabel: "Key pattern",
            rawFilterPlaceholder: "Key pattern, e.g. user:*",
            browseFilterStyle: .keyPattern(types: ["string", "hash", "list", "set", "zset", "stream"]),
            supportsColumnSort: false,
            immutableColumns: ["Length"],
            supportsDatabaseSwitching: false,
            preferredPageSize: 200
        )
    }

    // MARK: - Connection

    public func connect() throws {
        close()
        let config = parameters.config
        // An SSH tunnel reaches one server, so it always means standalone.
        mode = config.usesSSH ? .standalone : Mode(rawValue: (config.option(.redisMode) ?? "").lowercased()) ?? .standalone
        if mode == .cluster {
            databaseIndex = 0
        } else {
            let text = config.database.trimmingCharacters(in: .whitespaces)
            guard let index = text.isEmpty ? 0 : RedisCommandParser.databaseIndex(text) else {
                throw DatabaseError.connection("The Redis database index must be a number, got \"\(config.database)\".")
            }
            databaseIndex = index
        }
        let tls = try TLSContext.load(parameters)
        stateLock.lock()
        tlsContext = tls
        stateLock.unlock()
        setResolvedSSL(config.sslMode)
        if mode == .cluster {
            try openCluster()
        } else {
            try openSingle()
        }
        isOpen = true
    }

    /// `cancel()` reads the resolved mode from another thread.
    private func setResolvedSSL(_ mode: SSLMode) {
        stateLock.lock()
        resolvedSSL = mode
        stateLock.unlock()
    }

    /// Options for a node connection. Called from `cancel()` too, so it reads only immutable state and `resolvedSSL`
    /// under the lock.
    private func baseOptions(endpoint: RedisEndpoint, ssl: SSLMode? = nil) -> RedisNodeLink.Options {
        let config = parameters.config
        var options = RedisNodeLink.Options(endpoint: endpoint)
        options.user = config.user
        options.password = parameters.password
        stateLock.lock()
        options.sslMode = ssl ?? resolvedSSL
        options.tls = tlsContext
        stateLock.unlock()
        options.timeout = TimeInterval(max(1, config.connectTimeout))
        options.preferRESP3 = preferRESP3
        return options
    }

    private var configuredEndpoint: RedisEndpoint {
        RedisEndpoint(host: parameters.config.host, port: parameters.config.port)
    }

    /// Standalone server, or the master a sentinel names.
    private func openSingle() throws {
        let config = parameters.config
        var options = baseOptions(endpoint: configuredEndpoint)
        if mode == .sentinel {
            var sentinels = RedisEndpoint.list(config.option(.redisNodes), defaultPort: RedisSentinel.defaultPort)
            if sentinels.isEmpty { sentinels = [configuredEndpoint] }
            options.endpoint = try RedisSentinel.resolveMaster(
                sentinels: sentinels,
                masterName: config.option(.redisSentinelMaster) ?? RedisSentinel.defaultMaster,
                sentinelUser: config.option(.redisSentinelUser),
                template: options
            )
        }
        let opened = try RedisNodeLink.open(options)
        do {
            let info = try opened.serverInfo()
            try verifyMode(info, at: opened.endpoint)
            if mode == .sentinel { try verifyMaster(opened) }
            if databaseIndex != 0 {
                let reply = try opened.call(["SELECT", String(databaseIndex)])
                if let message = reply.errorMessage {
                    throw DatabaseError.connection("Cannot select database \(databaseIndex): \(message)")
                }
                opened.database = databaseIndex
            }
            serverInfo = info
            serverVersion = info.displayVersion
            setResolvedSSL(RedisClusterRouter.resolvedSSL(config.sslMode, isTLS: opened.isTLS))
            link = opened
            inTransaction = false
            transactionNode = nil
        } catch {
            opened.close()
            throw error
        }
    }

    private func openCluster() throws {
        let config = parameters.config
        var seeds = RedisEndpoint.list(config.option(.redisNodes), defaultPort: config.port)
        if seeds.isEmpty { seeds = [configuredEndpoint] }
        var info = RedisServerInfo()
        let router = try RedisClusterRouter(seeds: seeds, template: baseOptions(endpoint: seeds[0])) { seed in
            info = try seed.serverInfo()
            try self.verifyMode(info, at: seed.endpoint)
        }
        serverInfo = info
        serverVersion = info.displayVersion
        setResolvedSSL(RedisClusterRouter.resolvedSSL(config.sslMode, isTLS: router.openLinks.first?.isTLS ?? false))
        cluster = router
        inTransaction = false
        transactionNode = nil
    }

    /// `INFO server` reports `redis_mode`; a mismatch with the chosen mode is a setup mistake worth spelling out.
    private func verifyMode(_ info: RedisServerInfo, at endpoint: RedisEndpoint) throws {
        let actual = info.mode.lowercased()
        guard !actual.isEmpty else { return }
        switch mode {
        case .standalone, .sentinel:
            if actual == "cluster" {
                throw DatabaseError.connection("\(endpoint) is a Redis Cluster node. Set the connection mode to Cluster.")
            }
            if actual == "sentinel" {
                throw DatabaseError.connection(mode == .sentinel
                    ? "Sentinel named \(endpoint) as the master, but it is a sentinel itself."
                    : "\(endpoint) is a Redis Sentinel, which holds no data. Set the connection mode to Sentinel and list it as a sentinel node.")
            }
        case .cluster:
            if actual != "cluster" {
                throw DatabaseError.connection("\(endpoint) is not part of a Redis Cluster (redis_mode is \(actual)). Set the connection mode to \(actual == "sentinel" ? "Sentinel" : "Standalone").")
            }
        }
    }

    /// A sentinel can name a node that was just demoted; refuse to treat a replica as the master.
    private func verifyMaster(_ link: RedisNodeLink) throws {
        let reply = try link.call(["ROLE"])
        guard let role = reply.elements?.first?.string?.lowercased() else { return }
        if role != "master" {
            throw DatabaseError.connection("Sentinel named \(link.endpoint) as the master, but it reports the role \(role). A failover may be in progress; try again.")
        }
    }

    public func close() {
        link?.close()
        link = nil
        cluster?.closeAll()
        cluster = nil
        isOpen = false
        inTransaction = false
        transactionNode = nil
    }

    /// Reopens a link dropped by `cancel()` or a network error, back on the session's database.
    private func ensureConnected() throws {
        guard isOpen else { throw DatabaseError.notConnected }
        if mode == .cluster {
            if cluster == nil { try openCluster() }
            return
        }
        if let current = link, !current.isBroken, current.transport.isOpen { return }
        link?.close()
        link = nil
        try openSingle()
    }

    func singleLink() throws -> RedisNodeLink {
        guard let link else { throw DatabaseError.notConnected }
        return link
    }

    // MARK: - Running commands

    /// One driver call: `cancel()` acts only while this runs.
    func operation<T>(_ body: () throws -> T) throws -> T {
        stateLock.lock()
        running = true
        generation &+= 1
        cancelRequested = false
        stateLock.unlock()
        defer {
            stateLock.lock()
            running = false
            activeLink = nil
            activeCommand = nil
            stateLock.unlock()
        }
        try ensureConnected()
        return try body()
    }

    /// A driver call other than `execute`: while the editor holds a MULTI open, it runs on a short-lived second
    /// connection so its commands are not queued into the user's transaction.
    func metadataOperation<T>(_ body: () throws -> T) throws -> T {
        try operation {
            guard inTransaction else { return try body() }
            guard cluster == nil, let main = link else {
                throw DatabaseError.unsupported("A MULTI transaction is open in the query editor. Run EXEC or DISCARD first.")
            }
            var options = baseOptions(endpoint: main.endpoint)
            options.clientName = "FoxlumeQuery-browse"
            let side = try RedisNodeLink.open(options)
            defer { side.close() }
            if main.database != 0 {
                if let message = try side.call(["SELECT", String(main.database)]).errorMessage {
                    throw RedisResults.serverError(message)
                }
                side.database = main.database
            }
            link = side
            inTransaction = false
            defer {
                link = main
                inTransaction = true
            }
            return try body()
        }
    }

    var isCancelRequested: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelRequested
    }

    func checkCancelled() throws {
        if isCancelRequested { throw DatabaseError.cancelled }
    }

    /// Pipelines `commands` on `link` while `cancel()` can see them. A failed read after a cancel is a cancellation.
    func send(_ commands: [[Data]], on link: RedisNodeLink, command: RedisCommand? = nil, cancellable: Bool = true) throws -> [RESPValue] {
        if cancellable { try checkCancelled() }
        stateLock.lock()
        activeLink = link
        activeCommand = command
        stateLock.unlock()
        defer {
            stateLock.lock()
            activeLink = nil
            activeCommand = nil
            stateLock.unlock()
        }
        do {
            return try link.pipeline(commands)
        } catch {
            if isCancelRequested { throw DatabaseError.cancelled }
            throw error
        }
    }

    /// Server errors become `DatabaseError.server`; an error that answers a cancelled command is a cancellation.
    func throwIfError(_ reply: RESPValue) throws {
        guard case .error(let message) = reply else { return }
        if isCancelRequested { throw DatabaseError.cancelled }
        throw RedisResults.serverError(message)
    }

    static func arguments(_ words: String...) -> [Data] {
        words.map { Data($0.utf8) }
    }

    /// Runs one command where it belongs: the session's server, or the cluster node owning its key.
    func dispatch(_ command: RedisCommand) throws -> RESPValue {
        if cluster != nil {
            return try clusterCall(command.arguments, key: RedisCommandParser.routingKey(command), command: command)
        }
        return try send([command.arguments], on: try singleLink(), command: command)[0]
    }

    /// Sends to the node owning `key`, following `MOVED` (and refreshing the slot map) and `ASK`.
    func clusterCall(_ arguments: [Data], key: Data?, command: RedisCommand? = nil) throws -> RESPValue {
        guard let cluster else { throw DatabaseError.notConnected }
        var target = cluster.endpoint(forKey: key)
        var asking = false
        var moved = false
        for _ in 0..<6 {
            let link = try cluster.link(for: target)
            let commands = asking ? [Self.arguments("ASKING"), arguments] : [arguments]
            let reply = try send(commands, on: link, command: command).last ?? .null
            if let message = reply.errorMessage, let redirect = RedisRedirect(message) {
                if redirect.kind == .moved {
                    cluster.noteMoved(slot: redirect.slot, to: redirect.endpoint)
                    moved = true
                }
                asking = redirect.kind == .ask
                target = redirect.endpoint
                continue
            }
            if moved { try? cluster.refresh() }
            return reply
        }
        throw DatabaseError.server(message: "Too many cluster redirections.", code: "MOVED")
    }

    /// Commands that each address one key, pipelined per node, replies in input order.
    func pipelineByKey(_ commands: [(key: Data, arguments: [Data])]) throws -> [RESPValue] {
        guard !commands.isEmpty else { return [] }
        let chunk = 1000
        guard let cluster else {
            let link = try singleLink()
            var replies: [RESPValue] = []
            replies.reserveCapacity(commands.count)
            for start in stride(from: 0, to: commands.count, by: chunk) {
                let slice = commands[start..<min(commands.count, start + chunk)].map(\.arguments)
                replies += try send(slice, on: link)
            }
            return replies
        }
        var replies = [RESPValue](repeating: .null, count: commands.count)
        var byNode: [RedisEndpoint: [Int]] = [:]
        var order: [RedisEndpoint] = []
        for (index, command) in commands.enumerated() {
            let endpoint = cluster.endpoint(forKey: command.key)
            if byNode[endpoint] == nil { order.append(endpoint) }
            byNode[endpoint, default: []].append(index)
        }
        for endpoint in order {
            let indexes = byNode[endpoint] ?? []
            let link = try cluster.link(for: endpoint)
            for start in stride(from: 0, to: indexes.count, by: chunk) {
                let slice = Array(indexes[start..<min(indexes.count, start + chunk)])
                let answers = try send(slice.map { commands[$0].arguments }, on: link)
                for (position, index) in slice.enumerated() {
                    let answer = answers[position]
                    if let message = answer.errorMessage, RedisRedirect(message) != nil {
                        replies[index] = try clusterCall(commands[index].arguments, key: commands[index].key)
                    } else {
                        replies[index] = answer
                    }
                }
            }
        }
        return replies
    }

    /// The links a keyspace-wide command must visit: every master in a cluster, else the session's server.
    func keyspaceLinks() throws -> [RedisNodeLink] {
        if let cluster {
            return try cluster.masters.map { try cluster.link(for: $0) }
        }
        return [try singleLink()]
    }

    /// Runs `body` on database `index` and returns to the session's database, even when `body` fails.
    func withDatabase<T>(_ index: Int, _ body: () throws -> T) throws -> T {
        if cluster != nil {
            guard index == 0 else {
                throw DatabaseError.server(message: "A cluster has only database 0.", code: "ERR")
            }
            return try body()
        }
        let link = try singleLink()
        let home = link.database
        guard index != home else { return try body() }
        try select(index, on: link, cancellable: true)
        do {
            let result = try body()
            try select(home, on: link, cancellable: false)
            return result
        } catch {
            if !link.isBroken { try? select(home, on: link, cancellable: false) }
            throw error
        }
    }

    private func select(_ index: Int, on link: RedisNodeLink, cancellable: Bool) throws {
        let reply = try send([Self.arguments("SELECT", String(index))], on: link, cancellable: cancellable)[0]
        if let message = reply.errorMessage { throw RedisResults.serverError(message) }
        link.database = index
    }

    // MARK: - Statements

    public func execute(_ sql: String, rowLimit: Int?) throws -> [StatementResult] {
        try operation {
            var results: [StatementResult] = []
            for statement in QueryLanguage.redis.split(sql) {
                try checkCancelled()
                let started = Date()
                let command = try RedisCommandParser.parse(statement.text)
                var result = try run(command, rowLimit: rowLimit)
                result.elapsed = Date().timeIntervalSince(started)
                results.append(result)
            }
            return results
        }
    }

    func run(_ command: RedisCommand, rowLimit: Int?) throws -> StatementResult {
        if let what = RedisCommandParser.unsupportedCommands[command.name] {
            throw DatabaseError.unsupported("\(what) cannot run in the query editor: the connection would stop answering one reply per command.")
        }
        if command.name == "CLIENT", command.word(1) == "REPLY" {
            throw DatabaseError.unsupported("CLIENT REPLY cannot run in the query editor: replies would no longer match commands.")
        }
        if let database = command.database {
            return try withDatabase(database) { try runHere(command, rowLimit: rowLimit) }
        }
        return try runHere(command, rowLimit: rowLimit)
    }

    /// Runs a command on the database the link is on.
    private func runHere(_ command: RedisCommand, rowLimit: Int?) throws -> StatementResult {
        switch command.name {
        case "MULTI":
            return try beginTransaction(command)
        case "EXEC", "DISCARD":
            return try endTransaction(command, rowLimit: rowLimit)
        case _ where inTransaction:
            return try queue(command)
        case "KEYS":
            return try keysCommand(command, rowLimit: rowLimit)
        case "SCAN":
            return try scanCommand(command, rowLimit: rowLimit)
        case "SELECT":
            return try selectCommand(command)
        case "LRANGE":
            return try lrangeCommand(command, rowLimit: rowLimit)
        case "QUIT":
            link?.close()
            link = nil
            cluster?.closeAll()
            cluster = nil
            return StatementResult(message: "OK")
        default:
            if cluster != nil, let result = try clusterKeyspaceCommand(command, rowLimit: rowLimit) {
                return result
            }
            let reply = try dispatch(command)
            try throwIfError(reply)
            return RedisResults.format(command, reply: reply, rowLimit: rowLimit)
        }
    }

    private func selectCommand(_ command: RedisCommand) throws -> StatementResult {
        let reply = try dispatch(command)
        try throwIfError(reply)
        if let index = command.text(1).flatMap(Int.init), let link {
            link.database = index
            // Under a `DB n` prefix the link goes back to the session's database afterwards.
            if command.database == nil { databaseIndex = index }
        }
        return RedisResults.format(command, reply: reply, rowLimit: nil)
    }

    /// LRANGE with a negative start needs LLEN to number the rows with real indexes.
    private func lrangeCommand(_ command: RedisCommand, rowLimit: Int?) throws -> StatementResult {
        guard let key = command.arguments.dropFirst().first, let start = command.text(2).flatMap(Int.init) else {
            let reply = try dispatch(command)
            try throwIfError(reply)
            return RedisResults.format(command, reply: reply, rowLimit: rowLimit)
        }
        guard start < 0 else {
            let reply = try dispatch(command)
            try throwIfError(reply)
            return RedisResults.format(command, reply: reply, rowLimit: rowLimit, listStart: start)
        }
        let replies = try pipelineByKey([(key, Self.arguments("LLEN") + [key]), (key, command.arguments)])
        try throwIfError(replies[1])
        let length = Int(replies[0].integer ?? 0)
        return RedisResults.format(command, reply: replies[1], rowLimit: rowLimit, listStart: max(0, length + start))
    }

    /// KEYS → the key grid, every master in a cluster.
    private func keysCommand(_ command: RedisCommand, rowLimit: Int?) throws -> StatementResult {
        var keys: [Data] = []
        for link in try keyspaceLinks() {
            let reply = try send([command.arguments], on: link, command: command)[0]
            try throwIfError(reply)
            keys += (reply.elements ?? []).compactMap(\.data)
        }
        keys = Self.sortedKeys(keys)
        let limit = rowLimit ?? Self.keysSummaryLimit
        let shown = Array(keys.prefix(max(0, limit)))
        let rows = try keySummaries(shown)
        return StatementResult(columns: RedisResults.keyColumns(), rows: rows, truncated: keys.count > shown.count)
    }

    /// One SCAN step → the key grid plus the next cursor. A cluster cursor names the node it continues on.
    private func scanCommand(_ command: RedisCommand, rowLimit: Int?) throws -> StatementResult {
        var arguments = command.arguments
        let reply: RESPValue
        var nextCursor: String?
        if let cluster, arguments.count >= 2 {
            let masters = cluster.masters
            switch RedisClusterCursor.decode(String(decoding: arguments[1], as: UTF8.self), masters: masters) {
            case .finished:
                return StatementResult(columns: RedisResults.keyColumns(), rows: [], message: "Next cursor: 0")
            case .node(let index, let cursor):
                arguments[1] = Data(cursor.utf8)
                reply = try send([arguments], on: try cluster.link(for: masters[index]), command: command)[0]
                try throwIfError(reply)
                if let nodeCursor = reply.elements?.first?.string {
                    nextCursor = RedisClusterCursor.advance(index: index, nodeCursor: nodeCursor, masters: masters)
                }
            }
        } else {
            reply = try dispatch(command)
            try throwIfError(reply)
            nextCursor = reply.elements?.first?.string
        }
        guard let parts = reply.elements, parts.count == 2 else {
            return RedisResults.generic(reply, rowLimit: rowLimit)
        }
        let keys = Self.sortedKeys((parts[1].elements ?? []).compactMap(\.data))
        let shown = rowLimit.map { Array(keys.prefix(max(0, $0))) } ?? keys
        let rows = try keySummaries(shown)
        return StatementResult(columns: RedisResults.keyColumns(), rows: rows, message: "Next cursor: \(nextCursor ?? "0")", truncated: shown.count < keys.count)
    }

    /// Cluster-wide forms: DBSIZE and FLUSHDB visit every master; multi-key DEL/UNLINK/EXISTS/TOUCH/MGET split by slot.
    private func clusterKeyspaceCommand(_ command: RedisCommand, rowLimit: Int?) throws -> StatementResult? {
        guard cluster != nil else { return nil }
        switch command.name {
        case "DBSIZE":
            var total: Int64 = 0
            for link in try keyspaceLinks() {
                let reply = try send([command.arguments], on: link, command: command)[0]
                try throwIfError(reply)
                total += reply.integer ?? 0
            }
            return RedisResults.generic(.integer(total), rowLimit: rowLimit)
        case "FLUSHDB", "FLUSHALL":
            for link in try keyspaceLinks() {
                try throwIfError(try send([command.arguments], on: link, command: command)[0])
            }
            return StatementResult(message: "OK")
        case "DEL", "UNLINK", "EXISTS", "TOUCH", "MGET":
            let keys = Array(command.arguments.dropFirst())
            var groups: [Int: [Int]] = [:]
            var order: [Int] = []
            for (index, key) in keys.enumerated() {
                let slot = RedisKeySlot.slot(for: key)
                if groups[slot] == nil { order.append(slot) }
                groups[slot, default: []].append(index)
            }
            guard order.count > 1 else { return nil }
            var total: Int64 = 0
            var values = [RESPValue](repeating: .null, count: keys.count)
            for slot in order {
                let indexes = groups[slot] ?? []
                let reply = try clusterCall([command.arguments[0]] + indexes.map { keys[$0] }, key: keys[indexes[0]], command: command)
                try throwIfError(reply)
                total += reply.integer ?? 0
                for (position, index) in indexes.enumerated() {
                    values[index] = reply.elements?[safe: position] ?? .null
                }
            }
            let combined: RESPValue = command.name == "MGET" ? .array(values) : .integer(total)
            return RedisResults.format(command, reply: combined, rowLimit: rowLimit)
        default:
            return nil
        }
    }

    // MARK: Transactions from the editor

    private func beginTransaction(_ command: RedisCommand) throws -> StatementResult {
        guard !inTransaction else { throw DatabaseError.server(message: "MULTI calls can not be nested", code: "ERR") }
        queuedSelect = nil
        transactionNode = nil
        if cluster == nil {
            let reply = try dispatch(command)
            try throwIfError(reply)
        }
        // A cluster transaction starts on the node of the first queued key.
        inTransaction = true
        return StatementResult(message: "OK")
    }

    private func queue(_ command: RedisCommand) throws -> StatementResult {
        let reply: RESPValue
        if let cluster {
            if let node = transactionNode {
                reply = try send([command.arguments], on: try cluster.link(for: node), command: command)[0]
            } else {
                let node = cluster.endpoint(forKey: RedisCommandParser.routingKey(command))
                let replies = try send([Self.arguments("MULTI"), command.arguments], on: try cluster.link(for: node), command: command)
                try throwIfError(replies[0])
                transactionNode = node
                reply = replies[1]
            }
        } else {
            reply = try dispatch(command)
        }
        try throwIfError(reply)
        if command.name == "SELECT", let index = command.text(1).flatMap(Int.init) { queuedSelect = index }
        return RedisResults.format(command, reply: reply, rowLimit: nil)
    }

    private func endTransaction(_ command: RedisCommand, rowLimit: Int?) throws -> StatementResult {
        guard inTransaction else {
            let reply = try dispatch(command)
            try throwIfError(reply)
            return RedisResults.format(command, reply: reply, rowLimit: rowLimit)
        }
        defer {
            inTransaction = false
            transactionNode = nil
            queuedSelect = nil
        }
        let reply: RESPValue
        if let cluster {
            guard let node = transactionNode else {
                return command.name == "EXEC" ? RedisResults.generic(.array([]), rowLimit: rowLimit) : StatementResult(message: "OK")
            }
            reply = try send([command.arguments], on: try cluster.link(for: node), command: command)[0]
        } else {
            reply = try dispatch(command)
        }
        try throwIfError(reply)
        if command.name == "EXEC", reply.isAggregate, let index = queuedSelect, let link {
            link.database = index
            databaseIndex = index
        }
        return RedisResults.format(command, reply: reply, rowLimit: rowLimit)
    }

    // MARK: - Cancel

    /// Frees a blocking command with `CLIENT UNBLOCK … ERROR` and a script with `SCRIPT KILL` / `FUNCTION KILL`,
    /// both from a short-lived second connection. Anything else, or a failed attempt, interrupts the socket;
    /// the next call reconnects.
    public func cancel() {
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        cancelRequested = true
        let generation = self.generation
        let target = activeLink
        let command = activeCommand
        let ssl = resolvedSSL
        stateLock.unlock()

        // Between round trips the flag alone stops the next one.
        guard let target else { return }
        let blocking = command.map(RedisCommandParser.isBlocking) ?? false
        let script = command.flatMap(RedisCommandParser.scriptKind)
        guard (blocking && target.clientID != nil) || script != nil else {
            target.interrupt()
            return
        }
        var options = baseOptions(endpoint: target.endpoint, ssl: ssl)
        options.clientName = "FoxlumeQuery-cancel"
        let request: RedisCancelRequest = blocking ? .unblock(target.clientID ?? 0) : .kill(script ?? .script)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let freed = request.perform(options: options)
            guard let self else { return }
            if freed {
                // The freed command answers at once; interrupt if it still has not after a grace period.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.interruptIfStillRunning(generation)
                }
            } else {
                self.interruptIfStillRunning(generation)
            }
        }
    }

    public func abort() {
        stateLock.lock()
        let target = activeLink
        stateLock.unlock()
        (target ?? link)?.interrupt()
    }

    private func interruptIfStillRunning(_ generation: Int) {
        stateLock.lock()
        let target = running && self.generation == generation ? activeLink : nil
        stateLock.unlock()
        target?.interrupt()
    }

    // MARK: - Databases and metadata

    public func databases() throws -> [String] { [] }

    public var currentDatabase: String? { "db\(databaseIndex)" }

    public func useDatabase(_ name: String) throws {
        guard let index = RedisCommandParser.databaseIndex(name) else {
            throw DatabaseError.server(message: "Unknown database \"\(name)\". Redis databases are named db0, db1, …", code: nil)
        }
        try operation {
            guard !inTransaction else {
                throw DatabaseError.unsupported("Finish the open MULTI with EXEC or DISCARD before switching databases.")
            }
            if cluster != nil {
                guard index == 0 else { throw DatabaseError.server(message: "A cluster has only database 0.", code: "ERR") }
                return
            }
            try select(index, on: try singleLink(), cancellable: true)
            databaseIndex = index
        }
    }

    public func schemas() throws -> [String] { [] }

    public var defaultSchema: String? { nil }

    /// One `.keyspace` table per database, with key counts from `INFO keyspace`.
    public func tables(schema: String?) throws -> [TableInfo] {
        try metadataOperation {
            if cluster != nil {
                var total: Int64 = 0
                for link in try keyspaceLinks() {
                    let reply = try send([Self.arguments("DBSIZE")], on: link)[0]
                    try throwIfError(reply)
                    total += reply.integer ?? 0
                }
                return [TableInfo(ref: TableRef(name: "db0"), kind: .keyspace, estimatedRows: Int(total))]
            }
            let replies = try send([Self.arguments("CONFIG", "GET", "databases"), Self.arguments("INFO", "keyspace")], on: try singleLink())
            let configured = replies[0].isError ? nil : replies[0].pairs.first.flatMap { $0.1.integer }.map(Int.init)
            let counts = replies[1].isError ? nil : RedisInfo.keyCounts(replies[1].string ?? "")
            let highest = max(counts?.keys.max() ?? -1, databaseIndex)
            let total = configured.map { max($0, highest + 1) } ?? max(16, highest + 1)
            return (0..<total).map { index in
                TableInfo(ref: TableRef(name: "db\(index)"), kind: .keyspace, estimatedRows: counts.map { $0[index] ?? 0 })
            }
        }
    }

    public func structure(of table: TableRef) throws -> TableStructure {
        TableStructure(table: table, columns: [
            ColumnInfo(name: "Key", dataType: "string", isNullable: false, isPrimaryKey: true),
            ColumnInfo(name: "Type", dataType: "string", isNullable: false, comment: "string, hash, list, set, zset or stream"),
            ColumnInfo(name: "TTL", dataType: "integer", comment: "Seconds until the key expires; -1 means no expiry"),
            ColumnInfo(name: "Length", dataType: "integer", comment: "STRLEN, HLEN, LLEN, SCARD, ZCARD or XLEN"),
            ColumnInfo(name: "Value", dataType: "string", comment: "The string value, or a JSON preview of a collection"),
        ])
    }

    public func ddl(of table: TableRef) throws -> String { "" }

    /// Keys sorted by their text, the order the sidebar and the grid show. Each key is decoded once.
    static func sortedKeys(_ keys: [Data]) -> [Data] {
        keys.map { (String(decoding: $0, as: UTF8.self), $0) }
            .sorted { $0.0 == $1.0 ? $0.1.lexicographicallyPrecedes($1.1) : $0.0 < $1.0 }
            .map(\.1)
    }
}

/// What the cancel helper connection asks the server to do.
enum RedisCancelRequest {
    case unblock(Int64)
    case kill(RedisCommandParser.ScriptKind)

    /// Opens a second connection and frees the command. Returns false when the server did not confirm it.
    func perform(options: RedisNodeLink.Options) -> Bool {
        guard let helper = try? RedisNodeLink.open(options) else { return false }
        defer { helper.close() }
        // The command may not have reached the server yet; retry briefly before giving up.
        for attempt in 0..<5 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.1) }
            let reply: RESPValue
            switch self {
            case .unblock(let id):
                guard let answer = try? helper.call(["CLIENT", "UNBLOCK", String(id), "ERROR"]) else { return false }
                reply = answer
                if reply.integer == 1 { return true }
            case .kill(let kind):
                guard let answer = try? helper.call([kind == .function ? "FUNCTION" : "SCRIPT", "KILL"]) else { return false }
                reply = answer
                if case .simple = reply { return true }
                // UNKILLABLE: the script already wrote, so only SHUTDOWN NOSAVE could stop it.
                if reply.errorMessage?.hasPrefix("UNKILLABLE") == true { return false }
            }
            if reply.errorMessage?.hasPrefix("NOPERM") == true { return false }
        }
        return false
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

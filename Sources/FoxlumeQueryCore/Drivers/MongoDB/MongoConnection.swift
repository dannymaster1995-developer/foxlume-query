import Foundation

/// Everything needed to open links, resolved once from the saved config, the connection string and DNS.
struct MongoSettings: Sendable {
    var hosts: [MongoHost]
    var credential: MongoCredential?
    var useTLS: Bool
    var requireTLS: Bool
    var verifyCertificate: Bool
    var database: String?
    var replicaSet: String?
    /// mongosh spelling, for example `secondaryPreferred`. Nil means primary.
    var readPreference: String?
    var writeConcern: BSONValue?
    var directConnection: Bool
    var connectTimeout: TimeInterval

    static let readPreferenceModes = ["primary", "primaryPreferred", "secondary", "secondaryPreferred", "nearest"]

    static func resolve(_ parameters: ConnectionParameters) throws -> MongoSettings {
        let config = parameters.config
        let timeout = TimeInterval(max(1, config.connectTimeout))
        var hosts = [MongoHost(host: config.host.trimmingCharacters(in: .whitespaces), port: config.port)]
        var user = config.user
        var password = parameters.password
        var database: String? = config.database.isEmpty ? nil : config.database
        var authSource = config.option(.mongoAuthSource)
        var mechanismText = config.option(.mongoAuthMechanism)
        var replicaSet = config.option(.mongoReplicaSet)
        var readPreferenceText = config.option(.mongoReadPreference)
        var writeConcernText = config.option(.mongoWriteConcern)
        var isSRV = config.option(.mongoSRV)?.lowercased() == "true"
        var useTLS = config.sslMode.wantsTLS
        var requireTLS = config.sslMode.requiresTLS
        var verify = config.sslMode.verifiesCertificate
        var explicitTLS: Bool?
        var directConnection: Bool?

        // A URI pasted into the host field works like the connection string option.
        let hostURI = ["mongodb://", "mongodb+srv://"].contains { config.host.lowercased().hasPrefix($0) } ? config.host : nil
        if let text = config.option(.mongoConnectionString) ?? hostURI {
            let uri = try MongoConnectionString(text)
            hosts = uri.hosts
            isSRV = uri.isSRV
            if let uriUser = uri.user {
                user = uriUser
                if let uriPassword = uri.password { password = uriPassword }
            }
            database = uri.database ?? database
            authSource = uri.authSource ?? authSource
            mechanismText = uri.authMechanism ?? mechanismText
            replicaSet = uri.replicaSet ?? replicaSet
            readPreferenceText = uri.readPreference ?? readPreferenceText
            writeConcernText = uri.writeConcern ?? writeConcernText
            directConnection = uri.directConnection
            if let tls = uri.tls {
                explicitTLS = tls
                useTLS = tls
                requireTLS = tls
                verify = tls && verify && !uri.tlsInsecure
            } else if uri.tlsInsecure {
                verify = false
            }
        }

        if isSRV {
            guard let name = hosts.first?.host else { throw DatabaseError.connection("No host to look up") }
            let resolved = try MongoDNS.resolveSRV(name, timeout: timeout)
            hosts = resolved.hosts
            authSource = authSource ?? resolved.options["authsource"]
            replicaSet = replicaSet ?? resolved.options["replicaset"]
        }
        // SRV implies TLS, and Atlas hosts never accept plaintext.
        let isAtlas = hosts.contains { $0.host.lowercased().hasSuffix(".mongodb.net") }
        if (isSRV || isAtlas) && explicitTLS != false {
            useTLS = true
            requireTLS = true
        }

        var mechanism: MongoAuthMechanism?
        if let mechanismText, mechanismText.lowercased() != "default" {
            guard let parsed = MongoAuthMechanism(userText: mechanismText) else {
                throw DatabaseError.authentication("Unknown authentication mechanism \"\(mechanismText)\"")
            }
            mechanism = parsed
        }
        var credential: MongoCredential?
        if !user.isEmpty, !password.isEmpty || mechanism == .x509 || mechanism == .aws {
            let source: String
            if mechanism?.usesExternalSource == true {
                source = "$external"
            } else {
                source = authSource ?? (isSRV ? nil : database) ?? "admin"
            }
            credential = MongoCredential(user: user, password: password, source: source, mechanism: mechanism)
        }

        var readPreference: String?
        if let text = readPreferenceText, text.lowercased() != "default" {
            guard let mode = readPreferenceModes.first(where: { $0.lowercased() == text.lowercased() }) else {
                throw DatabaseError.connection("Unknown read preference \"\(text)\"")
            }
            readPreference = mode == "primary" ? nil : mode
        }
        var writeConcern: BSONValue?
        if let text = writeConcernText?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text.lowercased() != "default" {
            writeConcern = Int32(text).map { .int32($0) } ?? .string(text)
        }

        return MongoSettings(
            hosts: hosts,
            credential: credential,
            useTLS: useTLS,
            requireTLS: requireTLS,
            verifyCertificate: verify,
            database: database,
            replicaSet: replicaSet,
            readPreference: readPreference,
            writeConcern: writeConcern,
            directConnection: directConnection ?? (hosts.count == 1 && replicaSet == nil),
            connectTimeout: timeout
        )
    }
}

/// MongoDB over OP_MSG with SCRAM authentication, TLS, a JavaScriptCore shell and document browsing.
public final class MongoConnection: DatabaseConnection {
    public var kind: DatabaseKind { parameters.config.kind }
    /// Unused: MongoDB has no SQL. Kept because the protocol requires one.
    public let dialect: SQLDialect = .postgresql
    public private(set) var serverVersion: String = ""
    public var isTLS: Bool { link?.isTLS ?? false }
    /// `standalone`, `replica set rs0 (primary)` or `mongos`, for diagnostics.
    public private(set) var topology: String = ""

    public var capabilities: EngineCapabilities {
        EngineCapabilities(
            queryLanguage: .mongo,
            objectNoun: "collection",
            objectNounPlural: "collections",
            rowNoun: "document",
            supportsDDL: true,
            supportsForeignKeys: false,
            supportsIndexes: true,
            savesAtomically: false,
            rawFilterLabel: "Filter",
            rawFilterPlaceholder: #"{ status: "paid", total: { $gt: 100 } }"#,
            browseFilterStyle: .columns,
            supportsColumnSort: true,
            immutableColumns: ["_id"],
            supportsDatabaseSwitching: true,
            supportsFieldRemoval: true
        )
    }

    let parameters: ConnectionParameters
    private(set) var link: MongoLink?
    private(set) var settings: MongoSettings?
    var databaseName: String = ""
    var runtime: MongoScriptRuntime?
    /// Sampled columns per `db.collection`, reused by browsing until the structure is reloaded.
    var schemaCache: [String: MongoSampledSchema] = [:]
    /// Raw documents of the last page per `db.collection`, keyed by the canonical Extended JSON of `_id`.
    var pageCache: [String: [String: BSONDocument]] = [:]

    private struct InFlight {
        var comment: String?
        var link: MongoLink
    }

    /// Guards what `cancel()` reads from another thread.
    private let stateLock = NSLock()
    private var cancelRequested = false
    private var inFlight: InFlight?
    private var commandCounter = 0
    private let sessionTag = String(UUID().uuidString.prefix(8)).lowercased()

    public init(parameters: ConnectionParameters) {
        self.parameters = parameters
    }

    deinit { close() }

    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    // MARK: - Connection

    public func connect() throws {
        close()
        let settings = try MongoSettings.resolve(parameters)
        withState { self.settings = settings }
        let link = try openLink(settings)
        self.link = link
        do {
            let info = try link.command(["buildInfo": .int32(1)], database: "admin")
            serverVersion = info["version"]?.stringValue ?? ""
        } catch {
            serverVersion = ""
        }
        topology = Self.describeTopology(link.hello)
        if databaseName.isEmpty {
            databaseName = try settings.database ?? firstUserDatabase() ?? "test"
        }
        runtime?.setDatabase(databaseName)
    }

    public func close() {
        link?.close()
        link = nil
    }

    static func describeTopology(_ hello: MongoHello) -> String {
        if hello.isMongos { return "mongos" }
        if let set = hello.setName {
            return "replica set \(set) (\(hello.isWritablePrimary ? "primary" : hello.isSecondary ? "secondary" : "member"))"
        }
        return "standalone"
    }

    /// The first reachable host; when it is a secondary that names a primary, the primary instead, so writes work.
    private func openLink(_ settings: MongoSettings) throws -> MongoLink {
        let deadline = ConnectDeadline(timeout: settings.connectTimeout)
        var lastError: Error = DatabaseError.connection("No host to connect to")
        defer { deadline.finish() }
        for host in settings.hosts {
            do {
                let link = try openSingle(host, settings: settings, deadline: deadline)
                if let expected = settings.replicaSet, link.hello.setName != expected {
                    link.close()
                    lastError = DatabaseError.connection("\(host) is not a member of replica set \"\(expected)\" (it reports \(link.hello.setName.map { "\"\($0)\"" } ?? "no replica set")).")
                    continue
                }
                if !settings.directConnection, !link.hello.isWritablePrimary, !link.hello.isMongos,
                   let primaryText = link.hello.primary, let primary = MongoHost(parsing: primaryText), primary != host
                {
                    if let primaryLink = try? openSingle(primary, settings: settings, deadline: deadline), primaryLink.hello.isWritablePrimary {
                        link.close()
                        return primaryLink
                    }
                }
                return link
            } catch let error as DatabaseError {
                if case .authentication = error { throw error }
                if case .unsupported = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
        }
        if deadline.finish() {
            throw DatabaseError.connection("Timed out after \(Int(settings.connectTimeout)) seconds connecting to MongoDB at \(settings.hosts.map(\.description).joined(separator: ", ")). Is this a MongoDB server?")
        }
        throw lastError
    }

    /// TCP, then TLS from the first byte when wanted (MongoDB has no STARTTLS), then `hello` and authentication.
    func openSingle(_ host: MongoHost, settings: MongoSettings, deadline: ConnectDeadline?) throws -> MongoLink {
        let credential = settings.credential
        func open(tls: Bool) throws -> MongoLink {
            let transport = SocketTransport()
            try transport.connect(host: host.host, port: host.port, timeout: settings.connectTimeout)
            deadline?.watch(transport)
            if tls {
                try transport.startTLS(host: host.host, verifyCertificate: settings.verifyCertificate)
            }
            let link = MongoLink(transport: transport, host: host.host, port: host.port)
            do {
                try link.handshake(saslSupportedMechsFor: credential.map { "\($0.source).\($0.user)" })
            } catch {
                link.close()
                throw error
            }
            return link
        }

        var link: MongoLink
        if settings.useTLS {
            do {
                link = try open(tls: true)
            } catch DatabaseError.connection(let reason) {
                guard !settings.requireTLS else { throw tlsHandshakeError(host: host, reason: reason, settings: settings) }
                link = try open(tls: false)
            } catch DatabaseError.protocolViolation(let reason) {
                guard !settings.requireTLS else { throw tlsHandshakeError(host: host, reason: reason, settings: settings) }
                link = try open(tls: false)
            }
        } else {
            link = try open(tls: false)
        }
        if let credential {
            do {
                try MongoAuthenticator.authenticate(link, credential: credential)
            } catch {
                link.close()
                throw error
            }
        }
        return link
    }

    private func tlsHandshakeError(host: MongoHost, reason: String, settings: MongoSettings) -> DatabaseError {
        guard settings.verifyCertificate else {
            return .connection("TLS handshake with \(host) failed. The server may not accept TLS connections. \(reason)")
        }
        return .connection("""
            TLS handshake with \(host) failed: the server certificate could not be verified. \
            It must be signed by a trusted authority and match the host name; use SSL mode \
            "\(SSLMode.require.displayName)" to encrypt without verifying. \(reason)
            """)
    }

    /// The open link, reconnecting when a cancelled or failed command dropped it.
    func activeLink() throws -> MongoLink {
        if let link { return link }
        guard let settings = withState({ self.settings }) else { throw DatabaseError.notConnected }
        let link = try openLink(settings)
        self.link = link
        return link
    }

    private func dropLink(_ dropped: MongoLink) {
        dropped.close()
        if link === dropped { link = nil }
    }

    /// The first database that is not `admin`, `local` or `config`.
    private func firstUserDatabase() throws -> String? {
        try? databases().first { !Self.systemDatabases.contains($0) }
    }

    static let systemDatabases: Set<String> = ["admin", "local", "config"]

    // MARK: - Commands

    /// Call at the start of every public operation: clears an old cancel request.
    func beginOperation() throws {
        guard link != nil || withState({ settings }) != nil else { throw DatabaseError.notConnected }
        withState { cancelRequested = false }
    }

    var isCancelRequested: Bool { withState { cancelRequested } }

    func checkCancelled() throws {
        if isCancelRequested { throw DatabaseError.cancelled }
    }

    /// Generic `comment` arrived for every command in MongoDB 4.4 (wire version 9).
    private var supportsComment: Bool { (link?.hello.maxWireVersion ?? 0) >= 9 }

    private static let writeCommands: Set<String> = [
        "insert", "update", "delete", "findAndModify", "createIndexes", "dropIndexes", "create", "drop",
        "dropDatabase", "renameCollection", "collMod", "createUser", "updateUser", "dropUser",
    ]

    /// Runs a command for the user: tags it with a unique comment so `cancel()` can find it,
    /// applies the read preference and write concern, and maps cancellation.
    /// Server errors throw `MongoServerError`; use `mapError` at the public boundary.
    @discardableResult
    func runCommand(_ command: BSONDocument, database: String) throws -> BSONDocument {
        let link = try activeLink()
        if let batches = try writeBatches(command, link: link) {
            return try runWriteBatches(command, batches: batches, database: database)
        }
        var command = command
        let name = command.first?.key ?? ""
        var comment = command["comment"]?.stringValue
        if supportsComment, command["comment"] == nil, !["killCursors", "hello", "isMaster", "saslStart", "saslContinue"].contains(name) {
            let tag = withState { () -> String in
                commandCounter += 1
                return "foxlume:\(sessionTag):\(commandCounter)"
            }
            command["comment"] = .string(tag)
            comment = tag
        }
        if let settings = withState({ settings }) {
            if let mode = settings.readPreference, !link.hello.isStandalone, command["$readPreference"] == nil {
                command["$readPreference"] = .document(["mode": .string(mode)])
            }
            if let concern = settings.writeConcern, Self.writeCommands.contains(name), command["writeConcern"] == nil {
                command["writeConcern"] = .document(["w": concern])
            }
        }
        try withState {
            if cancelRequested { throw DatabaseError.cancelled }
            inFlight = InFlight(comment: comment, link: link)
        }
        defer { withState { inFlight = nil } }
        do {
            return try link.command(command, database: database)
        } catch let error as MongoServerError {
            if isCancelRequested, error.code == MongoServerError.interrupted || error.codeName == "Interrupted" {
                throw DatabaseError.cancelled
            }
            throw error
        } catch let error as DatabaseError {
            switch error {
            case .connection, .protocolViolation, .notConnected:
                dropLink(link)
                if isCancelRequested { throw DatabaseError.cancelled }
            default:
                break
            }
            throw error
        }
    }

    private static let writeArrayFields = ["insert": "documents", "update": "updates", "delete": "deletes"]

    /// Splits an insert/update/delete whose documents exceed the server's batch count or message size.
    /// Nil when the command fits in one message.
    private func writeBatches(_ command: BSONDocument, link: MongoLink) throws -> [[BSONValue]]? {
        guard let name = command.first?.key, let field = Self.writeArrayFields[name], case .array(let items)? = command[field] else { return nil }
        let maxCount = max(1, link.hello.maxWriteBatchSize)
        // Room for the command body and the OP_MSG framing.
        let maxBytes = max(1024, link.hello.maxMessageSizeBytes - 16 * 1024)
        guard items.count > 1 else { return nil }
        var batches: [[BSONValue]] = []
        var current: [BSONValue] = []
        var currentBytes = 0
        for item in items {
            guard case .document(let document) = item else { return nil }
            let size = try document.encoded().count
            guard size <= link.hello.maxBSONObjectSize + 16 * 1024 else {
                throw DatabaseError.server(message: "A document is \(size) bytes, more than the server's \(link.hello.maxBSONObjectSize) byte limit.", code: "BSONObjectTooLarge")
            }
            if !current.isEmpty, current.count >= maxCount || currentBytes + size > maxBytes {
                batches.append(current)
                current = []
                currentBytes = 0
            }
            current.append(item)
            currentBytes += size
        }
        if !current.isEmpty { batches.append(current) }
        return batches.count > 1 ? batches : nil
    }

    /// Runs the batches in order and merges `n`, `nModified` and `upserted` as one reply would report them.
    private func runWriteBatches(_ command: BSONDocument, batches: [[BSONValue]], database: String) throws -> BSONDocument {
        guard let name = command.first?.key, let field = Self.writeArrayFields[name] else { return [:] }
        var n: Int64 = 0
        var modified: Int64 = 0
        var upserted: [BSONValue] = []
        var offset = 0
        for batch in batches {
            var part = command
            part[field] = .array(batch)
            let reply: BSONDocument
            do {
                reply = try runCommand(part, database: database)
            } catch var error as MongoServerError {
                if offset > 0 { error.message += " (after \(offset) earlier \(field) succeeded)" }
                throw error
            }
            n += reply["n"]?.int64Value ?? 0
            modified += reply["nModified"]?.int64Value ?? 0
            for entry in reply["upserted"]?.arrayValue ?? [] {
                guard var document = entry.documentValue else { continue }
                document["index"] = .int64((document["index"]?.int64Value ?? 0) + Int64(offset))
                upserted.append(.document(document))
            }
            offset += batch.count
        }
        var merged: BSONDocument = ["n": .int64(n)]
        if name == "update" { merged["nModified"] = .int64(modified) }
        if !upserted.isEmpty { merged["upserted"] = .array(upserted) }
        merged["ok"] = .double(1)
        return merged
    }

    /// Converts internal errors for callers of the public API.
    func mapError(_ error: Error) -> Error {
        if let server = error as? MongoServerError { return server.databaseError }
        if let literal = error as? MongoLiteralError { return DatabaseError.server(message: literal.localizedDescription, code: nil) }
        if let bson = error as? BSONError { return DatabaseError.server(message: bson.localizedDescription, code: nil) }
        return error
    }

    func mapped<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw mapError(error)
        }
    }

    /// Runs a cursor-returning command (find, aggregate, listCollections, …) and reads up to `limit` documents.
    /// `more` is true when documents were left over; the server cursor is closed either way.
    func cursorDocuments(_ command: BSONDocument, database: String, limit: Int?) throws -> (documents: [BSONDocument], more: Bool) {
        var command = command
        if let limit, command.first?.key == "find", command["batchSize"] == nil {
            command["batchSize"] = .int32(Int32(clamping: min(limit + 1, 10_000)))
        }
        let reply = try runCommand(command, database: database)
        guard let cursor = reply["cursor"]?.documentValue else {
            throw DatabaseError.protocolViolation("The reply has no cursor")
        }
        var documents = (cursor["firstBatch"]?.arrayValue ?? []).compactMap(\.documentValue)
        var cursorID = cursor["id"] ?? .int64(0)
        let namespace = cursor["ns"]?.stringValue ?? ""
        let collection = namespace.firstIndex(of: ".").map { String(namespace[namespace.index(after: $0)...]) } ?? namespace
        let wanted = limit.map { $0 + 1 }
        while cursorID.int64Value != 0, wanted.map({ documents.count < $0 }) ?? true {
            var getMore: BSONDocument = ["getMore": cursorID, "collection": .string(collection)]
            if let wanted { getMore["batchSize"] = .int32(Int32(clamping: max(1, wanted - documents.count))) }
            let next = try runCommand(getMore, database: database)
            guard let nextCursor = next["cursor"]?.documentValue else { break }
            documents += (nextCursor["nextBatch"]?.arrayValue ?? []).compactMap(\.documentValue)
            cursorID = nextCursor["id"] ?? .int64(0)
        }
        var more = false
        if let limit, documents.count > limit {
            documents = Array(documents.prefix(limit))
            more = true
        }
        if cursorID.int64Value != 0 {
            more = true
            _ = try? link?.command(["killCursors": .string(collection), "cursors": .array([cursorID])], database: database)
        }
        return (documents, more)
    }

    // MARK: - Cancel

    /// Finds the running command by its comment through a second connection and kills it with `killOp`.
    /// When it cannot be found (or killed), the socket is shut down instead; the next command reconnects.
    public func abort() {
        let running = withState { inFlight?.link }
        (running ?? link)?.interrupt()
    }

    public func cancel() {
        let (target, settings) = withState { () -> (InFlight?, MongoSettings?) in
            cancelRequested = true
            return (inFlight, self.settings)
        }
        guard let target, let settings else { return }
        var killed = false
        if let comment = target.comment {
            var sideSettings = settings
            sideSettings.connectTimeout = min(settings.connectTimeout, 5)
            let endpoint = MongoHost(host: target.link.host, port: target.link.port)
            if let side = try? openSingle(endpoint, settings: sideSettings, deadline: nil) {
                defer { side.close() }
                for attempt in 0..<4 {
                    if attempt > 0 { usleep(150_000) }
                    guard withState({ inFlight?.comment == comment }) else { return }
                    let filter: BSONDocument = ["currentOp": .int32(1), "$ownOps": .bool(true), "command.comment": .string(comment)]
                    guard let reply = try? side.command(filter, database: "admin") else { break }
                    let operations = (reply["inprog"]?.arrayValue ?? []).compactMap { $0.documentValue?["opid"] }
                    guard !operations.isEmpty else { continue }
                    for operation in operations {
                        if (try? side.command(["killOp": .int32(1), "op": operation], database: "admin")) != nil { killed = true }
                    }
                    if killed { return }
                }
            }
        }
        if !killed, withState({ inFlight?.link === target.link }) {
            target.link.interrupt()
        }
    }

    // MARK: - Shell

    public func execute(_ text: String, rowLimit: Int?) throws -> [StatementResult] {
        try beginOperation()
        _ = try mapped { try activeLink() }
        let runtime = try scriptRuntime()
        var results: [StatementResult] = []
        for statement in QueryLanguage.mongo.split(text) {
            try checkCancelled()
            let started = Date()
            var result = try mapped { try runtime.run(statement.text, rowLimit: rowLimit) }
            result.elapsed = Date().timeIntervalSince(started)
            results.append(result)
        }
        return results
    }

    func scriptRuntime() throws -> MongoScriptRuntime {
        if let runtime { return runtime }
        let created = try MongoScriptRuntime(connection: self)
        created.setDatabase(databaseName)
        runtime = created
        return created
    }

    /// Authenticate the current connection as another user, as `db.auth()` does in mongosh.
    func authenticate(user: String, password: String, source: String, mechanism: MongoAuthMechanism?) throws {
        let link = try activeLink()
        let credential = MongoCredential(user: user, password: password, source: source, mechanism: mechanism)
        if credential.mechanism == nil {
            // saslSupportedMechs came from the handshake for the configured user, so ask again for this one.
            let reply = try? link.command(["hello": .int32(1), "saslSupportedMechs": .string("\(source).\(user)")], database: "admin")
            let negotiated = MongoAuthenticator.negotiate(reply?["saslSupportedMechs"]?.arrayValue?.compactMap(\.stringValue))
            try MongoAuthenticator.authenticate(link, credential: MongoCredential(user: user, password: password, source: source, mechanism: negotiated))
        } else {
            try MongoAuthenticator.authenticate(link, credential: credential)
        }
        // Reconnects and cancel connections authenticate as this user from now on.
        withState { settings?.credential = credential }
        if serverVersion.isEmpty, let info = try? link.command(["buildInfo": .int32(1)], database: "admin") {
            serverVersion = info["version"]?.stringValue ?? ""
        }
    }

    // MARK: - Databases

    public var currentDatabase: String? { databaseName.isEmpty ? nil : databaseName }

    public func useDatabase(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count < 64, !trimmed.contains(where: { "/\\. \"$\0".contains($0) }) else {
            throw DatabaseError.server(message: "Invalid database name \"\(name)\"", code: nil)
        }
        databaseName = trimmed
        runtime?.setDatabase(trimmed)
    }

    public func schemas() throws -> [String] { [] }
    public var defaultSchema: String? { nil }
}

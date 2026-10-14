import Foundation

enum MongoOpCode {
    static let reply: Int32 = 1
    static let query: Int32 = 2004
    static let compressed: Int32 = 2012
    static let message: Int32 = 2013
}

/// An error document from the server: `ok: 0`, a write error or a write concern error.
struct MongoServerError: Error, LocalizedError {
    var code: Int
    var codeName: String?
    var message: String
    var labels: [String] = []

    static let unauthorized = 13
    static let authenticationFailed = 18
    static let namespaceNotFound = 26
    static let maxTimeMSExpired = 50
    static let commandNotFound = 59
    static let interrupted = 11601
    static let cursorNotFound = 43

    var errorDescription: String? { message }

    var databaseError: DatabaseError {
        .server(message: message, code: codeName ?? (code == 0 ? nil : String(code)))
    }

    /// The error a reply carries, or nil when it succeeded.
    static func from(reply: BSONDocument) -> MongoServerError? {
        let ok = reply["ok"]?.doubleValue ?? (reply["ok"]?.boolValue == true ? 1 : 0)
        if ok != 1 {
            let message = reply["errmsg"]?.stringValue ?? reply["$err"]?.stringValue ?? "The command failed."
            let labels = reply["errorLabels"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return MongoServerError(code: reply["code"]?.intValue ?? 0, codeName: reply["codeName"]?.stringValue, message: message, labels: labels)
        }
        if let writeErrors = reply["writeErrors"]?.arrayValue, let first = writeErrors.first?.documentValue {
            var message = first["errmsg"]?.stringValue ?? "Write failed."
            if writeErrors.count > 1 { message += " (and \(writeErrors.count - 1) more write errors)" }
            return MongoServerError(code: first["code"]?.intValue ?? 0, codeName: first["codeName"]?.stringValue, message: message)
        }
        if let concern = reply["writeConcernError"]?.documentValue {
            let message = "Write concern error: " + (concern["errmsg"]?.stringValue ?? "unknown")
            return MongoServerError(code: concern["code"]?.intValue ?? 0, codeName: concern["codeName"]?.stringValue, message: message)
        }
        return nil
    }
}

/// What `hello` reported about the server.
struct MongoHello {
    var raw: BSONDocument

    var minWireVersion: Int { raw["minWireVersion"]?.intValue ?? 0 }
    var maxWireVersion: Int { raw["maxWireVersion"]?.intValue ?? 0 }
    var isWritablePrimary: Bool { raw["isWritablePrimary"]?.boolValue ?? raw["ismaster"]?.boolValue ?? false }
    var isSecondary: Bool { raw["secondary"]?.boolValue ?? false }
    var setName: String? { raw["setName"]?.stringValue }
    var primary: String? { raw["primary"]?.stringValue }
    var isMongos: Bool { raw["msg"]?.stringValue == "isdbgrid" }
    var isStandalone: Bool { setName == nil && !isMongos }
    var maxBSONObjectSize: Int { raw["maxBsonObjectSize"]?.intValue ?? 16 * 1024 * 1024 }
    var maxMessageSizeBytes: Int { raw["maxMessageSizeBytes"]?.intValue ?? 48_000_000 }
    var maxWriteBatchSize: Int { raw["maxWriteBatchSize"]?.intValue ?? 100_000 }
    var saslSupportedMechs: [String]? { raw["saslSupportedMechs"]?.arrayValue?.compactMap(\.stringValue) }
}

/// One TCP (or TLS) connection to one server, speaking OP_MSG.
///
/// The handshake uses a legacy OP_QUERY `isMaster` as drivers do, so a server too old for OP_MSG
/// still answers and can be refused with a clear message.
final class MongoLink {
    /// OP_MSG arrived in MongoDB 3.6 (wire version 6).
    static let minimumWireVersion = 6
    static let maximumWireVersion = 30

    let host: String
    let port: Int
    private let transport: SocketTransport
    private(set) var hello = MongoHello(raw: [:])
    private var lastRequestID: Int32 = 0

    init(transport: SocketTransport, host: String, port: Int) {
        self.transport = transport
        self.host = host
        self.port = port
    }

    var isTLS: Bool { transport.isTLS }
    var tlsProtocolVersion: String? { transport.tlsProtocolVersion }
    var endpoint: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    /// Wake a blocked read from another thread.
    func interrupt() { transport.interrupt() }

    func close() { transport.close() }

    // MARK: Handshake

    func handshake(saslSupportedMechsFor user: String?) throws {
        var command: BSONDocument = [
            "isMaster": .int32(1),
            "helloOk": .bool(true),
            "client": .document([
                "application": .document(["name": .string("Foxlume Query")]),
                "driver": .document(["name": .string("FoxlumeQuery"), "version": .string("1.0")]),
                "os": .document([
                    "type": .string("Darwin"),
                    "name": .string("macOS"),
                    "architecture": .string(Self.architecture),
                    "version": .string(ProcessInfo.processInfo.operatingSystemVersionString),
                ]),
                "platform": .string("Swift"),
            ]),
        ]
        if let user { command["saslSupportedMechs"] = .string(user) }
        let reply = try legacyCommand(command, database: "admin")
        if let error = MongoServerError.from(reply: reply) { throw error }
        hello = MongoHello(raw: reply)
        guard hello.maxWireVersion >= Self.minimumWireVersion else {
            throw DatabaseError.unsupported("The server at \(endpoint) is too old (wire version \(hello.maxWireVersion)). Foxlume Query needs MongoDB 3.6 or newer.")
        }
        guard hello.minWireVersion <= Self.maximumWireVersion else {
            throw DatabaseError.unsupported("The server at \(endpoint) requires wire version \(hello.minWireVersion), newer than Foxlume Query supports.")
        }
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    // MARK: Commands

    /// Run a command and return its reply. Server errors throw `MongoServerError`.
    @discardableResult
    func command(_ command: BSONDocument, database: String) throws -> BSONDocument {
        let reply = try rawCommand(command, database: database)
        if let error = MongoServerError.from(reply: reply) { throw error }
        return reply
    }

    /// Run a command and return the reply without checking `ok`.
    func rawCommand(_ command: BSONDocument, database: String) throws -> BSONDocument {
        var body = command
        if body["$db"] == nil { body["$db"] = .string(database) }
        // Write commands send their documents as a kind 1 document sequence instead of an embedded array.
        var sequence: (identifier: String, documents: [BSONDocument])?
        if let name = body.first?.key, let field = Self.sequenceFields[name],
           case .array(let items)? = body[field], items.allSatisfy({ $0.documentValue != nil })
        {
            sequence = (field, items.compactMap(\.documentValue))
            body.removeValue(forKey: field)
        }
        let requestID = nextRequestID()
        var message = BSONWriter()
        message.int32(0)
        message.int32(requestID)
        message.int32(0)
        message.int32(MongoOpCode.message)
        message.uint32(0)
        message.bytes.append(0)
        try message.document(body)
        if let sequence {
            message.bytes.append(1)
            let start = message.bytes.count
            message.int32(0)
            try message.cString(sequence.identifier, what: "Sequence identifier")
            for document in sequence.documents {
                try message.document(document)
            }
            message.setInt32(Int32(message.bytes.count - start), at: start)
        }
        message.setInt32(Int32(message.bytes.count), at: 0)
        try checkSize(message.bytes.count)
        try transport.write(message.bytes)
        return try readReply(to: requestID)
    }

    private static let sequenceFields = ["insert": "documents", "update": "updates", "delete": "deletes"]

    private func checkSize(_ size: Int) throws {
        let limit = hello.maxMessageSizeBytes
        guard size <= limit else {
            throw DatabaseError.unsupported("The command is \(size) bytes, more than the server's \(limit) byte message limit.")
        }
    }

    private func nextRequestID() -> Int32 {
        lastRequestID = lastRequestID == Int32.max ? 1 : lastRequestID + 1
        return lastRequestID
    }

    /// OP_QUERY against `<db>.$cmd`, used only for the first `isMaster`.
    private func legacyCommand(_ command: BSONDocument, database: String) throws -> BSONDocument {
        let requestID = nextRequestID()
        var message = BSONWriter()
        message.int32(0)
        message.int32(requestID)
        message.int32(0)
        message.int32(MongoOpCode.query)
        message.int32(0)
        try message.cString("\(database).$cmd", what: "Namespace")
        message.int32(0)
        message.int32(-1)
        try message.document(command)
        message.setInt32(Int32(message.bytes.count), at: 0)
        try transport.write(message.bytes)
        return try readReply(to: requestID)
    }

    private func readReply(to requestID: Int32) throws -> BSONDocument {
        while true {
            var header = BSONReader(try transport.read(exactly: 16))
            let length = Int(try header.int32())
            _ = try header.int32()
            let responseTo = try header.int32()
            let opCode = try header.int32()
            guard length >= 16, length <= 64 * 1024 * 1024 + 16 else {
                throw DatabaseError.protocolViolation("Invalid MongoDB message length \(length). Is this a MongoDB server?")
            }
            let body = try transport.read(exactly: length - 16)
            guard responseTo == requestID else { continue }
            switch opCode {
            case MongoOpCode.message:
                return try Self.parseMessage(body)
            case MongoOpCode.reply:
                return try Self.parseReply(body)
            case MongoOpCode.compressed:
                throw DatabaseError.protocolViolation("The server sent a compressed message, which was not negotiated")
            default:
                throw DatabaseError.protocolViolation("Unexpected MongoDB opcode \(opCode)")
            }
        }
    }

    static func parseMessage(_ body: [UInt8]) throws -> BSONDocument {
        var reader = BSONReader(body)
        let flags = try reader.uint32()
        let checksumPresent = flags & 1 != 0
        let end = body.count - (checksumPresent ? 4 : 0)
        var document: BSONDocument?
        var sequences: [(String, [BSONValue])] = []
        while reader.offset < end {
            let kind = try reader.uint8()
            switch kind {
            case 0:
                document = try reader.document(depth: 0)
            case 1:
                let start = reader.offset
                let size = Int(try reader.int32())
                guard size >= 5, start + size <= end else { throw DatabaseError.protocolViolation("Bad OP_MSG document sequence") }
                let identifier = try reader.cString()
                var items: [BSONValue] = []
                while reader.offset < start + size {
                    items.append(.document(try reader.document(depth: 0)))
                }
                sequences.append((identifier, items))
            default:
                throw DatabaseError.protocolViolation("Unknown OP_MSG section kind \(kind)")
            }
        }
        guard var result = document else { throw DatabaseError.protocolViolation("OP_MSG reply without a body") }
        for (identifier, items) in sequences {
            result[identifier] = .array(items)
        }
        return result
    }

    static func parseReply(_ body: [UInt8]) throws -> BSONDocument {
        var reader = BSONReader(body)
        let flags = try reader.int32()
        _ = try reader.uint64()
        _ = try reader.int32()
        let count = try reader.int32()
        guard count >= 1 else { throw DatabaseError.protocolViolation("OP_REPLY without documents") }
        var document = try reader.document(depth: 0)
        if flags & 2 != 0, document["ok"] == nil {
            document["ok"] = .double(0)
            if let text = document["$err"] { document["errmsg"] = text }
        }
        return document
    }
}

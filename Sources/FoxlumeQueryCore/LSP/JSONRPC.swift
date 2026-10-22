import Foundation

/// The base protocol's framing: a `Content-Length` header block, a blank line, then that many bytes of JSON.
public enum LSPFraming {
    /// Larger messages are a broken stream, not a real message.
    public static let maxMessageSize = 64 << 20

    public static func encode(_ body: Data) -> Data {
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        return data
    }
}

public enum LSPFramingError: Error, Equatable, LocalizedError {
    case missingContentLength
    case invalidContentLength(String)
    case headerTooLong

    public var errorDescription: String? {
        switch self {
        case .missingContentLength: return "A language server message had no Content-Length header"
        case .invalidContentLength(let value): return "A language server message had an invalid Content-Length (\(value))"
        case .headerTooLong: return "A language server message header was too long"
        }
    }
}

/// Splits a byte stream into message bodies. Bytes may arrive in any chunks: a header split in two, several
/// messages in one read.
public struct LSPFrameDecoder: Sendable {
    private var buffer = Data()
    /// The body length announced by a header already read.
    private var pendingLength: Int?
    private static let separator = Data("\r\n\r\n".utf8)
    static let maxHeaderSize = 8192

    public init() {}

    /// The bodies completed by `data`, in order. Throws on a header that cannot be read; the stream is then unusable.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var bodies: [Data] = []
        while true {
            if pendingLength == nil {
                guard let headerEnd = buffer.range(of: Self.separator) else {
                    if buffer.count > Self.maxHeaderSize { throw LSPFramingError.headerTooLong }
                    break
                }
                let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
                pendingLength = try Self.contentLength(in: header)
                buffer = Data(buffer[headerEnd.upperBound...])
            }
            guard let length = pendingLength, buffer.count >= length else { break }
            bodies.append(Data(buffer.prefix(length)))
            buffer = Data(buffer.dropFirst(length))
            pendingLength = nil
        }
        return bodies
    }

    private static func contentLength(in header: String) throws -> Int {
        for line in header.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "content-length" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let parsed = Int(value), parsed >= 0, parsed <= LSPFraming.maxMessageSize else {
                throw LSPFramingError.invalidContentLength(value)
            }
            return parsed
        }
        throw LSPFramingError.missingContentLength
    }
}

/// A request id: a number or a string.
public enum JSONRPCID: Sendable, Hashable {
    case number(Int)
    case string(String)

    var json: JSONValue {
        switch self {
        case .number(let value): return JSONValue(value)
        case .string(let value): return .string(value)
        }
    }

    init?(_ json: JSONValue?) {
        if let value = json?.int {
            self = .number(value)
        } else if let value = json?.string {
            self = .string(value)
        } else {
            return nil
        }
    }
}

/// A JSON-RPC error object; also what a failed request throws.
public struct JSONRPCError: Error, Sendable, Equatable, LocalizedError {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    /// The client cancelled the request (`$/cancelRequest`).
    public static let requestCancelled = -32800
    public static let contentModified = -32801
    /// The server dropped the request, for example because a newer completion request replaced it.
    public static let serverCancelled = -32802

    public var isCancellation: Bool {
        code == Self.requestCancelled || code == Self.serverCancelled || code == Self.contentModified
    }

    public var errorDescription: String? { message }

    var json: JSONValue {
        var object: [String: JSONValue] = ["code": JSONValue(code), "message": .string(message)]
        if let data { object["data"] = data }
        return .object(object)
    }
}

/// One JSON-RPC 2.0 message.
public enum JSONRPCMessage: Sendable, Equatable {
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: JSONRPCID?, result: Result<JSONValue, JSONRPCError>)

    public static func == (lhs: JSONRPCMessage, rhs: JSONRPCMessage) -> Bool {
        lhs.json == rhs.json
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["jsonrpc": "2.0"]
        switch self {
        case .request(let id, let method, let params):
            object["id"] = id.json
            object["method"] = .string(method)
            if let params { object["params"] = params }
        case .notification(let method, let params):
            object["method"] = .string(method)
            if let params { object["params"] = params }
        case .response(let id, let result):
            object["id"] = id?.json ?? .null
            switch result {
            case .success(let value): object["result"] = value
            case .failure(let error): object["error"] = error.json
            }
        }
        return .object(object)
    }

    /// The framed bytes to write.
    public var framed: Data { LSPFraming.encode(json.encoded()) }

    /// Reads one message body. A body that is JSON but no message throws `invalidRequest`.
    public init(body: Data) throws {
        let value: JSONValue
        do {
            value = try JSONValue.decode(body)
        } catch {
            throw JSONRPCError(code: JSONRPCError.parseError, message: "Not JSON")
        }
        guard case .object(let object) = value else { throw JSONRPCError(code: JSONRPCError.invalidRequest, message: "Not an object") }
        if let method = object["method"]?.string {
            if let idValue = object["id"], !idValue.isNull {
                guard let id = JSONRPCID(idValue) else { throw JSONRPCError(code: JSONRPCError.invalidRequest, message: "Bad id") }
                self = .request(id: id, method: method, params: object["params"])
            } else {
                self = .notification(method: method, params: object["params"])
            }
            return
        }
        let id = JSONRPCID(object["id"])
        if let error = object["error"], !error.isNull {
            let failure = JSONRPCError(code: error["code"]?.int ?? JSONRPCError.internalError,
                                       message: error["message"]?.string ?? "Unknown error", data: error["data"])
            self = .response(id: id, result: .failure(failure))
        } else if object.keys.contains("result") {
            self = .response(id: id, result: .success(object["result"] ?? .null))
        } else {
            throw JSONRPCError(code: JSONRPCError.invalidRequest, message: "Neither a request nor a response")
        }
    }
}

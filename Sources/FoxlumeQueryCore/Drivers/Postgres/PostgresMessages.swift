import CryptoKit
import Foundation

/// Type bytes of the backend messages Foxlume Query handles (protocol 3.0).
enum PostgresBackendType {
    static let authentication = UInt8(ascii: "R")
    static let backendKeyData = UInt8(ascii: "K")
    static let commandComplete = UInt8(ascii: "C")
    static let copyBothResponse = UInt8(ascii: "W")
    static let copyData = UInt8(ascii: "d")
    static let copyDone = UInt8(ascii: "c")
    static let copyInResponse = UInt8(ascii: "G")
    static let copyOutResponse = UInt8(ascii: "H")
    static let dataRow = UInt8(ascii: "D")
    static let emptyQueryResponse = UInt8(ascii: "I")
    static let errorResponse = UInt8(ascii: "E")
    static let negotiateProtocolVersion = UInt8(ascii: "v")
    static let noticeResponse = UInt8(ascii: "N")
    static let notificationResponse = UInt8(ascii: "A")
    static let parameterStatus = UInt8(ascii: "S")
    static let readyForQuery = UInt8(ascii: "Z")
    static let rowDescription = UInt8(ascii: "T")
    // Extended query protocol
    static let parseComplete = UInt8(ascii: "1")
    static let bindComplete = UInt8(ascii: "2")
    static let closeComplete = UInt8(ascii: "3")
    static let noData = UInt8(ascii: "n")
    static let portalSuspended = UInt8(ascii: "s")
}

/// Authentication request codes carried by an `R` message.
enum PostgresAuthRequest {
    static let ok: Int32 = 0
    static let kerberosV5: Int32 = 2
    static let cleartextPassword: Int32 = 3
    static let md5Password: Int32 = 5
    static let gss: Int32 = 7
    static let gssContinue: Int32 = 8
    static let sspi: Int32 = 9
    static let sasl: Int32 = 10
    static let saslContinue: Int32 = 11
    static let saslFinal: Int32 = 12
}

struct PostgresBackendMessage {
    let type: UInt8
    let payload: [UInt8]
}

/// Builders for frontend messages. Each returns the complete bytes to write.
enum PostgresFrontend {
    static let protocolVersion30: Int32 = 196_608
    static let sslRequestCode: Int32 = 80_877_103
    static let cancelRequestCode: Int32 = 80_877_102

    static func sslRequest() -> [UInt8] {
        var writer = ByteWriter(capacity: 8)
        writer.int32BE(8)
        writer.int32BE(sslRequestCode)
        return writer.bytes
    }

    static func startup(parameters: [(String, String)]) -> [UInt8] {
        var writer = ByteWriter(capacity: 128)
        writer.int32BE(0)
        writer.int32BE(protocolVersion30)
        for (name, value) in parameters {
            writer.cString(name)
            writer.cString(value)
        }
        writer.uint8(0)
        writer.setInt32BE(Int32(writer.count), at: 0)
        return writer.bytes
    }

    /// The secret key is 4 bytes under protocol 3.0 but up to 256 bytes under 3.2, so its length sets the message length.
    static func cancelRequest(processID: Int32, secretKey: [UInt8]) -> [UInt8] {
        var writer = ByteWriter(capacity: 12 + secretKey.count)
        writer.int32BE(Int32(12 + secretKey.count))
        writer.int32BE(cancelRequestCode)
        writer.int32BE(processID)
        writer.append(secretKey)
        return writer.bytes
    }

    static func query(_ sql: String) -> [UInt8] {
        message(UInt8(ascii: "Q")) { $0.cString(sql) }
    }

    /// Parse, Bind, Describe, Execute and Close for one statement in the unnamed statement and portal, with every
    /// result column in text format. Execute asks for at most `maxRows` rows; the server then suspends the portal.
    static func extendedStatement(_ sql: String, maxRows: Int32) -> [UInt8] {
        message(UInt8(ascii: "P")) { writer in
            writer.cString("")
            writer.cString(sql)
            writer.int16BE(0)
        }
        + message(UInt8(ascii: "B")) { writer in
            writer.cString("")
            writer.cString("")
            writer.int16BE(0)
            writer.int16BE(0)
            writer.int16BE(0)
        }
        + message(UInt8(ascii: "D")) { writer in
            writer.uint8(UInt8(ascii: "P"))
            writer.cString("")
        }
        + message(UInt8(ascii: "E")) { writer in
            writer.cString("")
            writer.int32BE(maxRows)
        }
        + message(UInt8(ascii: "C")) { writer in
            writer.uint8(UInt8(ascii: "P"))
            writer.cString("")
        }
    }

    static func sync() -> [UInt8] {
        message(UInt8(ascii: "S")) { _ in }
    }

    static func password(_ text: String) -> [UInt8] {
        message(UInt8(ascii: "p")) { $0.cString(text) }
    }

    static func saslInitialResponse(mechanism: String, data: [UInt8]) -> [UInt8] {
        message(UInt8(ascii: "p")) { writer in
            writer.cString(mechanism)
            writer.int32BE(Int32(data.count))
            writer.append(data)
        }
    }

    static func saslResponse(_ data: [UInt8]) -> [UInt8] {
        message(UInt8(ascii: "p")) { $0.append(data) }
    }

    static func copyFail(_ reason: String) -> [UInt8] {
        message(UInt8(ascii: "f")) { $0.cString(reason) }
    }

    static func terminate() -> [UInt8] {
        message(UInt8(ascii: "X")) { _ in }
    }

    /// `"md5" + md5hex(md5hex(password + user) + salt)`.
    static func md5Password(user: String, password: String, salt: [UInt8]) -> String {
        let inner = hex(Insecure.MD5.hash(data: Array((password + user).utf8)))
        let outer = hex(Insecure.MD5.hash(data: Array(inner.utf8) + salt))
        return "md5" + outer
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        Data(digest).hexString
    }

    private static func message(_ type: UInt8, _ build: (inout ByteWriter) -> Void) -> [UInt8] {
        var writer = ByteWriter()
        writer.uint8(type)
        writer.int32BE(0)
        build(&writer)
        writer.setInt32BE(Int32(writer.count - 1), at: 1)
        return writer.bytes
    }
}

extension SocketTransport {
    /// Read one typed backend message: type byte, Int32 length that includes itself, payload.
    func readPostgresMessage() throws -> PostgresBackendMessage {
        let header = try read(exactly: 5)
        let length = Int(Int32(bitPattern: UInt32(header[1]) << 24 | UInt32(header[2]) << 16 | UInt32(header[3]) << 8 | UInt32(header[4])))
        guard length >= 4 else {
            throw DatabaseError.protocolViolation("Invalid length \(length) for message '\(Character(Unicode.Scalar(header[0])))'")
        }
        let payload = try read(exactly: length - 4)
        return PostgresBackendMessage(type: header[0], payload: payload)
    }
}

/// An ErrorResponse or NoticeResponse: a list of one-byte field codes with string values.
struct PostgresServerError {
    private(set) var fields: [UInt8: String] = [:]

    init(payload: [UInt8]) throws {
        var reader = ByteReader(payload)
        while let code = reader.peekUInt8(), code != 0 {
            _ = try reader.uint8()
            fields[code] = try reader.cString()
        }
    }

    private func field(_ code: Character) -> String? {
        guard let ascii = code.asciiValue, let value = fields[ascii], !value.isEmpty else { return nil }
        return value
    }

    /// The non-localized severity (`V`, 9.6+) when present, so FATAL is recognized in any server language.
    var severity: String { field("V") ?? field("S") ?? "ERROR" }
    var code: String? { field("C") }
    var message: String { field("M") ?? "Unknown server error" }
    var detail: String? { field("D") }
    var hint: String? { field("H") }

    var isFatal: Bool { severity == "FATAL" || severity == "PANIC" }

    /// DETAIL and HINT combined, one per line.
    var detailText: String? {
        let lines = [detail, hint.map { "Hint: \($0)" }].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    var databaseError: DatabaseError {
        .server(message: message, code: code, detail: detailText)
    }

    var noticeText: String {
        "\(field("S") ?? severity): \(message)"
    }
}

struct PostgresColumnDescription: Equatable {
    var name: String
    var tableOID: UInt32
    var columnNumber: Int16
    var typeOID: UInt32
    var typeModifier: Int32
    var format: Int16

    var resultColumn: ResultColumn {
        ResultColumn(name: name, typeName: PostgresType.name(oid: typeOID), isNumeric: PostgresType.isNumeric(oid: typeOID))
    }
}

enum PostgresParser {
    static func rowDescription(_ payload: [UInt8]) throws -> [PostgresColumnDescription] {
        var reader = ByteReader(payload)
        let count = Int(try reader.int16BE())
        guard count >= 0 else { throw DatabaseError.protocolViolation("Negative column count") }
        var columns: [PostgresColumnDescription] = []
        columns.reserveCapacity(count)
        for _ in 0..<count {
            let name = try reader.cString()
            let tableOID = UInt32(bitPattern: try reader.int32BE())
            let columnNumber = try reader.int16BE()
            let typeOID = UInt32(bitPattern: try reader.int32BE())
            _ = try reader.int16BE()
            let typeModifier = try reader.int32BE()
            let format = try reader.int16BE()
            columns.append(PostgresColumnDescription(
                name: name,
                tableOID: tableOID,
                columnNumber: columnNumber,
                typeOID: typeOID,
                typeModifier: typeModifier,
                format: format
            ))
        }
        return columns
    }

    /// Parses a text-format DataRow straight from the payload buffer; this is the hot path for large results.
    static func dataRow(_ payload: [UInt8]) throws -> [CellValue] {
        try payload.withUnsafeBufferPointer { buffer -> [CellValue] in
            guard buffer.count >= 2 else { throw DatabaseError.protocolViolation("Short DataRow") }
            let count = Int(Int16(bitPattern: UInt16(buffer[0]) << 8 | UInt16(buffer[1])))
            guard count >= 0 else { throw DatabaseError.protocolViolation("Negative DataRow column count") }
            var offset = 2
            var row: [CellValue] = []
            row.reserveCapacity(count)
            for _ in 0..<count {
                guard offset + 4 <= buffer.count else { throw DatabaseError.protocolViolation("Short DataRow") }
                let length = Int32(bitPattern: UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16
                    | UInt32(buffer[offset + 2]) << 8 | UInt32(buffer[offset + 3]))
                offset += 4
                guard length >= 0 else {
                    row.append(.null)
                    continue
                }
                let end = offset + Int(length)
                guard end <= buffer.count else { throw DatabaseError.protocolViolation("DataRow value exceeds message") }
                row.append(CellValue.decode(Data(UnsafeBufferPointer(rebasing: buffer[offset..<end]))))
                offset = end
            }
            return row
        }
    }

    static func parameterStatus(_ payload: [UInt8]) throws -> (name: String, value: String) {
        var reader = ByteReader(payload)
        return (try reader.cString(), try reader.cString())
    }

    static func commandTag(_ payload: [UInt8]) throws -> String {
        var reader = ByteReader(payload)
        return try reader.cString()
    }

    /// Row count from a CommandComplete tag. Row-returning SELECT and FETCH report the rows, not changes, so they give nil.
    static func affectedRows(commandTag tag: String, hasResultSet: Bool) -> Int? {
        let parts = tag.split(separator: " ")
        guard parts.count >= 2, let verb = parts.first, let last = parts.last, let count = Int(last) else { return nil }
        switch verb {
        case "INSERT", "UPDATE", "DELETE", "MERGE", "COPY", "MOVE":
            return count
        case "SELECT", "FETCH":
            return hasResultSet ? nil : count
        default:
            return nil
        }
    }
}

import Foundation

// MARK: - Protocol constants

struct MySQLCapabilities: OptionSet, Sendable {
    let rawValue: UInt32

    static let longPassword = MySQLCapabilities(rawValue: 1 << 0)
    static let longFlag = MySQLCapabilities(rawValue: 1 << 2)
    static let connectWithDB = MySQLCapabilities(rawValue: 1 << 3)
    static let protocol41 = MySQLCapabilities(rawValue: 1 << 9)
    static let ssl = MySQLCapabilities(rawValue: 1 << 11)
    static let transactions = MySQLCapabilities(rawValue: 1 << 13)
    static let secureConnection = MySQLCapabilities(rawValue: 1 << 15)
    static let multiStatements = MySQLCapabilities(rawValue: 1 << 16)
    static let multiResults = MySQLCapabilities(rawValue: 1 << 17)
    static let psMultiResults = MySQLCapabilities(rawValue: 1 << 18)
    static let pluginAuth = MySQLCapabilities(rawValue: 1 << 19)
    static let pluginAuthLenencClientData = MySQLCapabilities(rawValue: 1 << 21)
    static let deprecateEOF = MySQLCapabilities(rawValue: 1 << 24)
}

struct MySQLServerStatus: OptionSet, Sendable {
    let rawValue: UInt16

    static let moreResultsExist = MySQLServerStatus(rawValue: 0x0008)
    static let noBackslashEscapes = MySQLServerStatus(rawValue: 0x0200)
}

enum MySQLCommand: UInt8 {
    case quit = 0x01
    case initDB = 0x02
    case query = 0x03
}

enum MySQLProtocol {
    /// Largest payload of a single wire packet. Longer payloads continue in the next packet.
    static let maxPacketPayload = 0xFF_FFFF
    /// `max_packet_size` announced in the handshake response.
    static let clientMaxPacketSize: UInt32 = 16 * 1024 * 1024
    /// utf8mb4_general_ci, known to both MySQL and MariaDB.
    static let utf8mb4GeneralCI: UInt8 = 45
    /// The `binary` pseudo charset reported for byte strings and for non-string types.
    static let binaryCharset: UInt16 = 63

    static let okHeader: UInt8 = 0x00
    static let errHeader: UInt8 = 0xFF
    static let eofHeader: UInt8 = 0xFE
    static let localInfileHeader: UInt8 = 0xFB
    static let authMoreDataHeader: UInt8 = 0x01
}

// MARK: - Packet framing

/// The byte stream under the packet layer. `SocketTransport` in production, an in-memory stream in tests.
protocol MySQLByteChannel: AnyObject {
    func read(exactly count: Int) throws -> [UInt8]
    func write(_ bytes: [UInt8]) throws
}

extension SocketTransport: MySQLByteChannel {}

/// Splits and joins MySQL packets: a 3-byte little-endian length, a sequence id, then the payload.
final class MySQLPacketStream {
    let channel: MySQLByteChannel
    private(set) var sequence: UInt8 = 0

    init(channel: MySQLByteChannel) {
        self.channel = channel
    }

    /// Every command starts a new sequence.
    func resetSequence() {
        sequence = 0
    }

    /// Read one logical packet, joining the continuation packets of payloads of 16 MB or more.
    func read() throws -> [UInt8] {
        var payload: [UInt8] = []
        while true {
            let header = try channel.read(exactly: 4)
            let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16
            guard header[3] == sequence else {
                // The server sends an unsolicited ERR before dropping a connection (idle timeout, shutdown).
                if length <= 1024, let stray = try? channel.read(exactly: length),
                   stray.first == MySQLProtocol.errHeader, let error = try? MySQLErrorPacket(payload: stray) {
                    throw DatabaseError.connection(error.message)
                }
                throw DatabaseError.protocolViolation("Packets out of order (expected \(sequence), received \(header[3]))")
            }
            sequence = sequence &+ 1
            let chunk = try channel.read(exactly: length)
            if length < MySQLProtocol.maxPacketPayload, payload.isEmpty {
                return chunk
            }
            if payload.isEmpty {
                payload.reserveCapacity(length * 2)
            }
            payload.append(contentsOf: chunk)
            if length < MySQLProtocol.maxPacketPayload {
                return payload
            }
        }
    }

    /// Write one logical packet. A payload that fills a packet exactly is followed by an empty one.
    func write(_ payload: [UInt8]) throws {
        var offset = 0
        while true {
            let length = min(MySQLProtocol.maxPacketPayload, payload.count - offset)
            var frame = [UInt8]()
            frame.reserveCapacity(length + 4)
            frame.append(UInt8(length & 0xFF))
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8((length >> 16) & 0xFF))
            frame.append(sequence)
            frame.append(contentsOf: payload[offset..<(offset + length)])
            sequence = sequence &+ 1
            try channel.write(frame)
            offset += length
            if length < MySQLProtocol.maxPacketPayload { return }
        }
    }
}

// MARK: - Server packets

/// Initial handshake, protocol version 10.
struct MySQLHandshake {
    var protocolVersion: UInt8
    var serverVersion: String
    var connectionID: UInt32
    /// The 20-byte nonce used by the password scrambles.
    var scramble: [UInt8]
    var capabilities: MySQLCapabilities
    var characterSet: UInt8
    var statusFlags: MySQLServerStatus
    var authPluginName: String

    init(payload: [UInt8]) throws {
        var reader = ByteReader(payload)
        protocolVersion = try reader.uint8()
        guard protocolVersion == 10 else {
            throw DatabaseError.unsupported("Unsupported MySQL protocol version \(protocolVersion).")
        }
        serverVersion = try reader.cString()
        connectionID = try reader.uint32LE()
        var scramble = try reader.bytes(8)
        try reader.skip(1)
        var capabilities = UInt32(try reader.uint16LE())
        characterSet = 0
        statusFlags = []
        authPluginName = ""
        if !reader.isAtEnd {
            characterSet = try reader.uint8()
            statusFlags = MySQLServerStatus(rawValue: try reader.uint16LE())
            capabilities |= UInt32(try reader.uint16LE()) << 16
            let authDataLength = Int(try reader.uint8())
            try reader.skip(10)
            if capabilities & MySQLCapabilities.secureConnection.rawValue != 0 {
                let partTwoLength = min(max(13, authDataLength - 8), reader.remaining)
                var partTwo = try reader.bytes(partTwoLength)
                if partTwo.last == 0 { partTwo.removeLast() }
                scramble += partTwo
            }
            if capabilities & MySQLCapabilities.pluginAuth.rawValue != 0 {
                authPluginName = try reader.cString()
            }
        }
        self.scramble = scramble
        self.capabilities = MySQLCapabilities(rawValue: capabilities)
    }

    /// MariaDB prefixes its version with `5.5.5-` so that old replication clients accept it.
    static func displayVersion(_ raw: String) -> String {
        let prefix = "5.5.5-"
        guard raw.hasPrefix(prefix), raw.dropFirst(prefix.count).first?.isNumber == true else { return raw }
        return String(raw.dropFirst(prefix.count))
    }
}

struct MySQLOKPacket {
    var affectedRows: UInt64
    var lastInsertID: UInt64
    var statusFlags: MySQLServerStatus
    var warnings: UInt16
    var info: String

    /// Parses OK packets with either the 0x00 header or, with CLIENT_DEPRECATE_EOF, the 0xFE header.
    init(payload: [UInt8]) throws {
        var reader = ByteReader(payload)
        try reader.skip(1)
        affectedRows = try reader.lengthEncodedInt() ?? 0
        lastInsertID = try reader.lengthEncodedInt() ?? 0
        statusFlags = []
        warnings = 0
        info = ""
        guard !reader.isAtEnd else { return }
        statusFlags = MySQLServerStatus(rawValue: try reader.uint16LE())
        warnings = try reader.uint16LE()
        guard !reader.isAtEnd else { return }
        // Documented as string<EOF> without CLIENT_SESSION_TRACK, but MySQL and MariaDB both send a
        // length-encoded string (libmysql reads it that way). Fall back to the raw rest if it does not fit.
        var probe = reader
        if let length = try? probe.lengthEncodedInt(), length <= UInt64(probe.remaining) {
            info = String(decoding: try probe.bytes(Int(length)), as: UTF8.self)
        } else {
            info = String(decoding: reader.rest(), as: UTF8.self)
        }
    }

    /// For example `Affected rows: 3; Records: 3  Duplicates: 0  Warnings: 0; Last insert ID: 7`.
    var message: String {
        var parts = ["Affected rows: \(affectedRows)"]
        let trimmedInfo = info.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInfo.isEmpty {
            parts.append(trimmedInfo)
        } else if warnings > 0 {
            parts.append("Warnings: \(warnings)")
        }
        if lastInsertID != 0 {
            parts.append("Last insert ID: \(lastInsertID)")
        }
        return parts.joined(separator: "; ")
    }
}

/// The legacy EOF packet that ends column definitions and rows without CLIENT_DEPRECATE_EOF.
struct MySQLEOFPacket {
    var warnings: UInt16
    var statusFlags: MySQLServerStatus

    init(payload: [UInt8]) throws {
        var reader = ByteReader(payload)
        try reader.skip(1)
        if reader.remaining >= 4 {
            warnings = try reader.uint16LE()
            statusFlags = MySQLServerStatus(rawValue: try reader.uint16LE())
        } else {
            warnings = 0
            statusFlags = []
        }
    }
}

struct MySQLErrorPacket {
    static let queryInterrupted: UInt16 = 1317
    static let authenticationCodes: Set<UInt16> = [1044, 1045, 1251, 1275, 1524, 1698, 1820, 1862, 3159]

    var code: UInt16
    var sqlState: String?
    var message: String

    init(payload: [UInt8]) throws {
        var reader = ByteReader(payload)
        try reader.skip(1)
        code = try reader.uint16LE()
        // The SQLSTATE marker is absent in errors sent before capabilities are negotiated.
        if reader.peekUInt8() == UInt8(ascii: "#"), reader.remaining >= 6 {
            try reader.skip(1)
            sqlState = String(decoding: try reader.bytes(5), as: UTF8.self)
        }
        message = String(decoding: reader.rest(), as: UTF8.self)
    }

    var codeText: String {
        guard let sqlState else { return String(code) }
        return "\(code)/\(sqlState)"
    }

    var serverError: DatabaseError {
        if code == Self.queryInterrupted { return .cancelled }
        return .server(message: message, code: codeText)
    }
}

/// Column definition (Protocol::ColumnDefinition41).
struct MySQLColumnDefinition {
    var schema: String
    var table: String
    var orgTable: String
    var name: String
    var orgName: String
    var characterSet: UInt16
    var length: UInt32
    var type: UInt8
    var flags: UInt16
    var decimals: UInt8

    static let unsignedFlag: UInt16 = 0x0020
    static let enumFlag: UInt16 = 0x0100
    static let setFlag: UInt16 = 0x0800

    init(
        name: String,
        type: UInt8,
        characterSet: UInt16 = UInt16(MySQLProtocol.utf8mb4GeneralCI),
        flags: UInt16 = 0,
        table: String = "",
        orgTable: String = ""
    ) {
        self.schema = ""
        self.table = table
        self.orgTable = orgTable
        self.name = name
        self.orgName = name
        self.characterSet = characterSet
        self.length = 0
        self.type = type
        self.flags = flags
        self.decimals = 0
    }

    init(payload: [UInt8]) throws {
        var reader = ByteReader(payload)
        _ = try reader.lengthEncodedBytes()
        schema = try reader.lengthEncodedString() ?? ""
        table = try reader.lengthEncodedString() ?? ""
        orgTable = try reader.lengthEncodedString() ?? ""
        name = try reader.lengthEncodedString() ?? ""
        orgName = try reader.lengthEncodedString() ?? ""
        _ = try reader.lengthEncodedInt()
        characterSet = try reader.uint16LE()
        length = try reader.uint32LE()
        type = try reader.uint8()
        flags = try reader.uint16LE()
        decimals = try reader.uint8()
    }

    var isBinaryCharset: Bool { characterSet == MySQLProtocol.binaryCharset }

    /// Byte strings only. Numbers and dates also report the binary charset but arrive as ASCII text.
    var isBinary: Bool {
        isBinaryCharset && MySQLFieldType.byteStringTypes.contains(type)
    }

    var isNumeric: Bool { MySQLFieldType.numericTypes.contains(type) }

    var typeName: String { MySQLFieldType.name(of: type, flags: flags, binary: isBinaryCharset) }

    var resultColumn: ResultColumn {
        let source = orgTable.isEmpty ? table : orgTable
        return ResultColumn(name: name, typeName: typeName, isNumeric: isNumeric, tableName: source.isEmpty ? nil : source)
    }
}

enum MySQLFieldType {
    static let decimal: UInt8 = 0
    static let tiny: UInt8 = 1
    static let short: UInt8 = 2
    static let long: UInt8 = 3
    static let float: UInt8 = 4
    static let double: UInt8 = 5
    static let null: UInt8 = 6
    static let timestamp: UInt8 = 7
    static let longLong: UInt8 = 8
    static let int24: UInt8 = 9
    static let date: UInt8 = 10
    static let time: UInt8 = 11
    static let datetime: UInt8 = 12
    static let year: UInt8 = 13
    static let newDate: UInt8 = 14
    static let varchar: UInt8 = 15
    static let bit: UInt8 = 16
    static let timestamp2: UInt8 = 17
    static let datetime2: UInt8 = 18
    static let time2: UInt8 = 19
    static let vector: UInt8 = 242
    static let json: UInt8 = 245
    static let newDecimal: UInt8 = 246
    static let enumType: UInt8 = 247
    static let set: UInt8 = 248
    static let tinyBlob: UInt8 = 249
    static let mediumBlob: UInt8 = 250
    static let longBlob: UInt8 = 251
    static let blob: UInt8 = 252
    static let varString: UInt8 = 253
    static let string: UInt8 = 254
    static let geometry: UInt8 = 255

    static let numericTypes: Set<UInt8> = [decimal, newDecimal, tiny, short, long, longLong, int24, float, double, year]
    static let byteStringTypes: Set<UInt8> = [varchar, varString, string, tinyBlob, mediumBlob, longBlob, blob, bit, geometry]

    static func name(of type: UInt8, flags: UInt16, binary: Bool) -> String {
        switch type {
        case decimal, newDecimal: return "DECIMAL"
        case tiny: return "TINYINT"
        case short: return "SMALLINT"
        case long: return "INT"
        case float: return "FLOAT"
        case double: return "DOUBLE"
        case null: return "NULL"
        case timestamp, timestamp2: return "TIMESTAMP"
        case longLong: return "BIGINT"
        case int24: return "MEDIUMINT"
        case date, newDate: return "DATE"
        case time, time2: return "TIME"
        case datetime, datetime2: return "DATETIME"
        case year: return "YEAR"
        case bit: return "BIT"
        case vector: return "VECTOR"
        case json: return "JSON"
        case enumType: return "ENUM"
        case set: return "SET"
        case tinyBlob: return binary ? "TINYBLOB" : "TINYTEXT"
        case mediumBlob: return binary ? "MEDIUMBLOB" : "MEDIUMTEXT"
        case longBlob: return binary ? "LONGBLOB" : "LONGTEXT"
        case blob: return binary ? "BLOB" : "TEXT"
        case varchar, varString: return binary ? "VARBINARY" : "VARCHAR"
        case string:
            if flags & MySQLColumnDefinition.enumFlag != 0 { return "ENUM" }
            if flags & MySQLColumnDefinition.setFlag != 0 { return "SET" }
            return binary ? "BINARY" : "CHAR"
        case geometry: return "GEOMETRY"
        default: return "type:\(type)"
        }
    }
}

// MARK: - Text result rows

enum MySQLTextRow {
    /// Decode a text-protocol row. Cells are length-encoded strings, 0xFB marks NULL.
    static func decode(_ packet: [UInt8], columns: [MySQLColumnDefinition]) throws -> [CellValue] {
        var row: [CellValue] = []
        row.reserveCapacity(columns.count)
        var offset = 0
        for column in columns {
            guard offset < packet.count else {
                throw DatabaseError.protocolViolation("Row has fewer values than columns")
            }
            if packet[offset] == 0xFB {
                row.append(.null)
                offset += 1
                continue
            }
            let (length, headerSize) = try lengthEncodedInt(packet, at: offset)
            let start = offset + headerSize
            guard length <= UInt64(packet.count - start) else {
                throw DatabaseError.protocolViolation("Value length exceeds packet")
            }
            let end = start + Int(length)
            row.append(cell(packet[start..<end], binary: column.isBinary))
            offset = end
        }
        return row
    }

    static func cell(_ bytes: ArraySlice<UInt8>, binary: Bool) -> CellValue {
        if binary { return .bytes(Data(bytes)) }
        // Most values are ASCII (numbers, dates, identifiers): skip Foundation's UTF-8 validation for them.
        if bytes.allSatisfy({ $0 < 0x80 }) {
            return .text(String(decoding: bytes, as: UTF8.self))
        }
        return CellValue.decode(Data(bytes))
    }

    private static func lengthEncodedInt(_ packet: [UInt8], at offset: Int) throws -> (UInt64, Int) {
        let first = packet[offset]
        let size: Int
        switch first {
        case 0xFC: size = 2
        case 0xFD: size = 3
        case 0xFE: size = 8
        case 0xFF: throw DatabaseError.protocolViolation("Invalid length-encoded integer")
        default: return (UInt64(first), 1)
        }
        guard offset + size < packet.count else {
            throw DatabaseError.protocolViolation("Unexpected end of row")
        }
        var value: UInt64 = 0
        for index in 0..<size {
            value |= UInt64(packet[offset + 1 + index]) << UInt64(index * 8)
        }
        return (value, size + 1)
    }
}

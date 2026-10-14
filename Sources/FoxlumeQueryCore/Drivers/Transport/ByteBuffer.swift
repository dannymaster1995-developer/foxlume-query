import Foundation

/// Builds a binary message. Big-endian helpers serve PostgreSQL, little-endian helpers serve MySQL.
public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []

    public init(capacity: Int = 64) {
        bytes.reserveCapacity(capacity)
    }

    public var count: Int { bytes.count }
    public var data: Data { Data(bytes) }

    public mutating func uint8(_ value: UInt8) { bytes.append(value) }

    public mutating func append(_ data: Data) { bytes.append(contentsOf: data) }
    public mutating func append(_ data: [UInt8]) { bytes.append(contentsOf: data) }

    public mutating func utf8(_ string: String) { bytes.append(contentsOf: Array(string.utf8)) }

    /// UTF-8 bytes followed by a zero terminator.
    public mutating func cString(_ string: String) {
        utf8(string)
        bytes.append(0)
    }

    public mutating func int16BE(_ value: Int16) {
        let v = UInt16(bitPattern: value)
        bytes.append(UInt8(v >> 8))
        bytes.append(UInt8(v & 0xff))
    }

    public mutating func int32BE(_ value: Int32) {
        let v = UInt32(bitPattern: value)
        bytes.append(UInt8((v >> 24) & 0xff))
        bytes.append(UInt8((v >> 16) & 0xff))
        bytes.append(UInt8((v >> 8) & 0xff))
        bytes.append(UInt8(v & 0xff))
    }

    public mutating func uint16LE(_ value: UInt16) {
        bytes.append(UInt8(value & 0xff))
        bytes.append(UInt8(value >> 8))
    }

    public mutating func uint24LE(_ value: UInt32) {
        bytes.append(UInt8(value & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8((value >> 16) & 0xff))
    }

    public mutating func uint32LE(_ value: UInt32) {
        bytes.append(UInt8(value & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 24) & 0xff))
    }

    /// MySQL length-encoded integer.
    public mutating func lengthEncodedInt(_ value: UInt64) {
        switch value {
        case 0..<251:
            bytes.append(UInt8(value))
        case 251..<(1 << 16):
            bytes.append(0xfc)
            uint16LE(UInt16(value))
        case (1 << 16)..<(1 << 24):
            bytes.append(0xfd)
            uint24LE(UInt32(value))
        default:
            bytes.append(0xfe)
            for shift in stride(from: 0, to: 64, by: 8) {
                bytes.append(UInt8((value >> UInt64(shift)) & 0xff))
            }
        }
    }

    /// MySQL length-encoded string.
    public mutating func lengthEncodedBytes(_ data: [UInt8]) {
        lengthEncodedInt(UInt64(data.count))
        bytes.append(contentsOf: data)
    }

    /// Overwrite a big-endian Int32 at `offset`, used to patch message lengths.
    public mutating func setInt32BE(_ value: Int32, at offset: Int) {
        let v = UInt32(bitPattern: value)
        bytes[offset] = UInt8((v >> 24) & 0xff)
        bytes[offset + 1] = UInt8((v >> 16) & 0xff)
        bytes[offset + 2] = UInt8((v >> 8) & 0xff)
        bytes[offset + 3] = UInt8(v & 0xff)
    }
}

/// Reads a binary message with bounds checking. Every read throws instead of trapping on short input.
public struct ByteReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ data: Data) { bytes = [UInt8](data) }
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    private mutating func need(_ n: Int) throws {
        guard n >= 0, offset + n <= bytes.count else {
            throw DatabaseError.protocolViolation("Unexpected end of message")
        }
    }

    public func peekUInt8() -> UInt8? { offset < bytes.count ? bytes[offset] : nil }

    public mutating func skip(_ n: Int) throws {
        try need(n)
        offset += n
    }

    public mutating func uint8() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func bytes(_ n: Int) throws -> [UInt8] {
        try need(n)
        defer { offset += n }
        return Array(bytes[offset..<(offset + n)])
    }

    public mutating func data(_ n: Int) throws -> Data { Data(try bytes(n)) }

    public mutating func rest() -> [UInt8] {
        defer { offset = bytes.count }
        return Array(bytes[min(offset, bytes.count)...])
    }

    public mutating func int16BE() throws -> Int16 {
        let b = try bytes(2)
        return Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
    }

    public mutating func int32BE() throws -> Int32 {
        let b = try bytes(4)
        let v = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        return Int32(bitPattern: v)
    }

    public mutating func uint16LE() throws -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    public mutating func uint24LE() throws -> UInt32 {
        let b = try bytes(3)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16
    }

    public mutating func uint32LE() throws -> UInt32 {
        let b = try bytes(4)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    public mutating func uint64LE() throws -> UInt64 {
        let b = try bytes(8)
        var v: UInt64 = 0
        for (i, byte) in b.enumerated() { v |= UInt64(byte) << UInt64(i * 8) }
        return v
    }

    /// Zero-terminated UTF-8 string. Without a terminator, reads to the end.
    public mutating func cString() throws -> String {
        guard offset <= bytes.count else { throw DatabaseError.protocolViolation("Unexpected end of message") }
        var end = offset
        while end < bytes.count, bytes[end] != 0 { end += 1 }
        let string = String(decoding: bytes[offset..<end], as: UTF8.self)
        offset = min(end + 1, bytes.count)
        return string
    }

    /// MySQL length-encoded integer. Returns nil for the NULL marker 0xfb.
    public mutating func lengthEncodedInt() throws -> UInt64? {
        let first = try uint8()
        switch first {
        case 0xfb: return nil
        case 0xfc: return UInt64(try uint16LE())
        case 0xfd: return UInt64(try uint24LE())
        case 0xfe: return try uint64LE()
        default: return UInt64(first)
        }
    }

    /// MySQL length-encoded string. Returns nil for NULL.
    public mutating func lengthEncodedBytes() throws -> [UInt8]? {
        guard let length = try lengthEncodedInt() else { return nil }
        guard length <= UInt64(remaining) else { throw DatabaseError.protocolViolation("Length exceeds packet") }
        return try bytes(Int(length))
    }

    public mutating func lengthEncodedString() throws -> String? {
        guard let raw = try lengthEncodedBytes() else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }
}

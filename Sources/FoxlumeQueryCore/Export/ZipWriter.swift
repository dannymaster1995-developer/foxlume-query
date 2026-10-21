import Foundation

/// Where a `ZipWriter` puts the archive's bytes, front to back.
protocol ZipOutput: AnyObject {
    func writeBytes(_ data: Data) throws
}

extension ExportFileWriter: ZipOutput {
    func writeBytes(_ data: Data) throws { try write(data) }
}

/// An archive kept in memory, for small files and tests.
final class DataZipOutput: ZipOutput {
    private(set) var data = Data()

    func writeBytes(_ data: Data) throws { self.data.append(data) }
}

/// Little-endian field encoding for ZIP records.
struct ZipBytes {
    var data = Data()

    mutating func u16(_ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(value >> UInt32(shift) & 0xFF)) }
    }

    mutating func u64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8(value >> UInt64(shift) & 0xFF)) }
    }
}

/// One file of an archive as the central directory describes it.
struct ZipCentralRecord: Equatable {
    static let localHeaderSignature: UInt32 = 0x0403_4B50
    static let centralHeaderSignature: UInt32 = 0x0201_4B50
    static let descriptorSignature: UInt32 = 0x0807_4B50
    static let endSignature: UInt32 = 0x0605_4B50
    static let zip64EndSignature: UInt32 = 0x0606_4B50
    static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    /// Bit 3: sizes and CRC follow the data. Bit 11: the name is UTF-8.
    static let descriptorFlag: UInt16 = 0x0008
    static let utf8Flag: UInt16 = 0x0800
    static let stored: UInt16 = 0
    static let deflated: UInt16 = 8

    var name: String
    var method: UInt16
    var flags: UInt16
    var crc: UInt32
    var compressedSize: UInt64
    var size: UInt64
    var localHeaderOffset: UInt64
    var dosTime: UInt16 = 0
    var dosDate: UInt16 = 0x21

    var needsZip64: Bool {
        compressedSize >= 0xFFFF_FFFF || size >= 0xFFFF_FFFF || localHeaderOffset >= 0xFFFF_FFFF
    }

    /// The central directory header. Values that do not fit 32 bits go into a ZIP64 extra field, in the
    /// order the format prescribes: size, compressed size, local header offset.
    func centralHeader() -> Data {
        var extra = ZipBytes()
        if needsZip64 {
            var fields = ZipBytes()
            if size >= 0xFFFF_FFFF { fields.u64(size) }
            if compressedSize >= 0xFFFF_FFFF { fields.u64(compressedSize) }
            if localHeaderOffset >= 0xFFFF_FFFF { fields.u64(localHeaderOffset) }
            extra.u16(0x0001)
            extra.u16(UInt16(fields.data.count))
            extra.data.append(fields.data)
        }
        let nameBytes = Data(name.utf8)
        var record = ZipBytes()
        record.u32(Self.centralHeaderSignature)
        record.u16(needsZip64 ? 45 : 20)
        record.u16(needsZip64 ? 45 : 20)
        record.u16(flags)
        record.u16(method)
        record.u16(dosTime)
        record.u16(dosDate)
        record.u32(crc)
        record.u32(UInt32(min(compressedSize, 0xFFFF_FFFF)))
        record.u32(UInt32(min(size, 0xFFFF_FFFF)))
        record.u16(UInt16(nameBytes.count))
        record.u16(UInt16(extra.data.count))
        record.u16(0)
        record.u16(0)
        record.u16(0)
        record.u32(0)
        record.u32(UInt32(min(localHeaderOffset, 0xFFFF_FFFF)))
        record.data.append(nameBytes)
        record.data.append(extra.data)
        return record.data
    }

    /// The records after the central directory: the ZIP64 end record and its locator when the entry count,
    /// the directory size or its offset do not fit the classic end record, then the classic one.
    static func endRecords(entryCount: Int, directorySize: UInt64, directoryOffset: UInt64) -> Data {
        var bytes = ZipBytes()
        let zip64 = entryCount >= 0xFFFF || directorySize >= 0xFFFF_FFFF || directoryOffset >= 0xFFFF_FFFF
        if zip64 {
            let recordOffset = directoryOffset + directorySize
            bytes.u32(zip64EndSignature)
            bytes.u64(44)
            bytes.u16(45)
            bytes.u16(45)
            bytes.u32(0)
            bytes.u32(0)
            bytes.u64(UInt64(entryCount))
            bytes.u64(UInt64(entryCount))
            bytes.u64(directorySize)
            bytes.u64(directoryOffset)
            bytes.u32(zip64LocatorSignature)
            bytes.u32(0)
            bytes.u64(recordOffset)
            bytes.u32(1)
        }
        bytes.u32(endSignature)
        bytes.u16(0)
        bytes.u16(0)
        bytes.u16(UInt16(min(entryCount, 0xFFFF)))
        bytes.u16(UInt16(min(entryCount, 0xFFFF)))
        bytes.u32(UInt32(min(directorySize, 0xFFFF_FFFF)))
        bytes.u32(UInt32(min(directoryOffset, 0xFFFF_FFFF)))
        bytes.u16(0)
        return bytes.data
    }

    /// MS-DOS time and date fields for `date` in the local time zone.
    static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, parts.year ?? 1980))
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }
}

/// Writes a ZIP archive strictly front to back, so it can stream into an `ExportFileWriter` without seeking.
/// Small parts are added whole with their sizes in the local header; large parts are streamed, deflated
/// on the fly, with the CRC and sizes in a data descriptor after the data. ZIP64 records are written only
/// where an entry, an offset or the entry count needs them.
final class ZipWriter {
    private let output: ZipOutput
    private var records: [ZipCentralRecord] = []
    private(set) var offset: UInt64 = 0
    private let timestamp: (time: UInt16, date: UInt16)
    private var finished = false

    private struct OpenEntry {
        var record: ZipCentralRecord
        var encoder: DeflateEncoder
        var crc: UInt32 = 0
    }

    private var open: OpenEntry?

    init(output: ZipOutput, date: Date = Date()) {
        self.output = output
        timestamp = ZipCentralRecord.dosTimestamp(date)
    }

    var entryCount: Int { records.count }

    private func emit(_ data: Data) throws {
        try output.writeBytes(data)
        offset += UInt64(data.count)
    }

    private func localHeader(_ record: ZipCentralRecord, extra: Data = Data()) -> Data {
        let nameBytes = Data(record.name.utf8)
        var header = ZipBytes()
        header.u32(ZipCentralRecord.localHeaderSignature)
        header.u16(extra.isEmpty ? 20 : 45)
        header.u16(record.flags)
        header.u16(record.method)
        header.u16(record.dosTime)
        header.u16(record.dosDate)
        let streamed = record.flags & ZipCentralRecord.descriptorFlag != 0
        header.u32(streamed ? 0 : record.crc)
        header.u32(streamed ? 0 : UInt32(min(record.compressedSize, 0xFFFF_FFFF)))
        header.u32(streamed ? 0 : UInt32(min(record.size, 0xFFFF_FFFF)))
        header.u16(UInt16(nameBytes.count))
        header.u16(UInt16(extra.count))
        header.data.append(nameBytes)
        header.data.append(extra)
        return header.data
    }

    private func newRecord(_ name: String, method: UInt16, flags: UInt16) throws -> ZipCentralRecord {
        guard !finished else { throw DatabaseError.unsupported("The archive is already closed.") }
        guard open == nil else { throw DatabaseError.unsupported("Finish the current archive entry first.") }
        guard records.count < Int(UInt32.max), name.utf8.count <= 0xFFFF else { throw DatabaseError.unsupported("Too many or too long archive entries.") }
        return ZipCentralRecord(name: name, method: method, flags: flags | ZipCentralRecord.utf8Flag, crc: 0, compressedSize: 0, size: 0,
                                localHeaderOffset: offset, dosTime: timestamp.time, dosDate: timestamp.date)
    }

    /// Adds a part held in memory, deflated unless that would not make it smaller (or `compress` is false).
    func addFile(_ name: String, contents: Data, compress: Bool = true) throws {
        var record = try newRecord(name, method: ZipCentralRecord.deflated, flags: 0)
        var body = compress ? try DeflateEncoder().encode(contents, final: true) : contents
        if !compress || body.count >= contents.count {
            body = contents
            record.method = ZipCentralRecord.stored
        }
        record.crc = CRC32.update(0, contents)
        record.size = UInt64(contents.count)
        record.compressedSize = UInt64(body.count)
        var extra = ZipBytes()
        if record.size >= 0xFFFF_FFFF || record.compressedSize >= 0xFFFF_FFFF {
            extra.u16(0x0001)
            extra.u16(16)
            extra.u64(record.size)
            extra.u64(record.compressedSize)
        }
        try emit(localHeader(record, extra: extra.data))
        try emit(body)
        records.append(record)
    }

    /// Starts a streamed, deflated part; `write` adds to it and `endFile` closes it.
    func beginFile(_ name: String) throws {
        let record = try newRecord(name, method: ZipCentralRecord.deflated, flags: ZipCentralRecord.descriptorFlag)
        try emit(localHeader(record))
        open = OpenEntry(record: record, encoder: try DeflateEncoder())
    }

    func write(_ data: Data) throws {
        guard var entry = open else { throw DatabaseError.unsupported("No archive entry is open.") }
        guard !data.isEmpty else { return }
        entry.crc = CRC32.update(entry.crc, data)
        entry.record.size += UInt64(data.count)
        let compressed = try entry.encoder.encode(data, final: false)
        entry.record.compressedSize += UInt64(compressed.count)
        open = entry
        if !compressed.isEmpty { try emit(compressed) }
    }

    func endFile() throws {
        guard var entry = open else { return }
        let tail = try entry.encoder.encode(Data(), final: true)
        entry.record.compressedSize += UInt64(tail.count)
        entry.record.crc = entry.crc
        open = nil
        try emit(tail)
        try emit(Self.dataDescriptor(entry.record))
        records.append(entry.record)
    }

    /// CRC and sizes after streamed data; sizes are 8 bytes once either passes 4 GB.
    static func dataDescriptor(_ record: ZipCentralRecord) -> Data {
        var bytes = ZipBytes()
        bytes.u32(ZipCentralRecord.descriptorSignature)
        bytes.u32(record.crc)
        if record.compressedSize >= 0xFFFF_FFFF || record.size >= 0xFFFF_FFFF {
            bytes.u64(record.compressedSize)
            bytes.u64(record.size)
        } else {
            bytes.u32(UInt32(record.compressedSize))
            bytes.u32(UInt32(record.size))
        }
        return bytes.data
    }

    /// Writes the central directory and the end records. The output is complete afterwards.
    func finish() throws {
        guard !finished else { return }
        try endFile()
        let directoryOffset = offset
        var directory = Data()
        for record in records {
            directory.append(record.centralHeader())
            if directory.count >= 1 << 18 {
                try emit(directory)
                directory.removeAll(keepingCapacity: true)
            }
        }
        try emit(directory)
        try emit(ZipCentralRecord.endRecords(entryCount: records.count, directorySize: offset - directoryOffset, directoryOffset: directoryOffset))
        finished = true
    }
}

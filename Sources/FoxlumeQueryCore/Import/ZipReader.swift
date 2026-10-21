import Compression
import Foundation

/// Reads ZIP archives through their central directory: stored and deflated entries, entries whose sizes
/// follow the data in a descriptor (the central directory has them too), and ZIP64 archives.
final class ZipReader {
    struct Entry: Equatable {
        var name: String
        var method: UInt16
        var flags: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var size: UInt64
        var localHeaderOffset: UInt64
    }

    let url: URL
    let entries: [Entry]
    let fileSize: UInt64
    private let handle: FileHandle

    init(url: URL) throws {
        self.url = url
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DatabaseError.unsupported("Could not open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        fileSize = (try? handle.seekToEnd()) ?? 0
        let size = fileSize
        let handle = self.handle
        let read: (UInt64, Int) throws -> Data = { offset, count in
            guard offset + UInt64(count) <= size else { throw ZipReader.damaged }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw ZipReader.damaged }
            return data
        }
        let end = try Self.locateDirectory(fileSize: fileSize, read: read)
        guard end.size <= 1 << 30 else { throw DatabaseError.unsupported("The archive's directory is too large.") }
        entries = try Self.parseCentralDirectory(try read(end.offset, Int(end.size)), count: end.count)
    }

    deinit { try? handle.close() }

    static let damaged = DatabaseError.unsupported("The file is not a valid ZIP archive, or it is damaged.")

    /// The entry with this name; ZIP names are case-sensitive, but some writers differ in case from the specification.
    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name } ?? entries.first { $0.name.lowercased() == name.lowercased() }
    }

    // MARK: Directory

    /// Offset, size and entry count of the central directory, from the end record (and the ZIP64 end record
    /// when the classic one holds placeholders).
    static func locateDirectory(fileSize: UInt64, read: (UInt64, Int) throws -> Data) throws -> (offset: UInt64, size: UInt64, count: Int) {
        guard fileSize >= 22 else { throw damaged }
        let tailLength = Int(min(fileSize, 22 + 0xFFFF))
        let tailStart = fileSize - UInt64(tailLength)
        let tail = [UInt8](try read(tailStart, tailLength))
        var position = tail.count - 22
        while position >= 0 {
            if tail[position] == 0x50, tail[position + 1] == 0x4B, tail[position + 2] == 0x05, tail[position + 3] == 0x06 { break }
            position -= 1
        }
        guard position >= 0 else { throw damaged }
        let end = ByteCursor(tail, at: position + 4)
        _ = end.u16()
        _ = end.u16()
        _ = end.u16()
        var count = UInt64(end.u16())
        var size = UInt64(end.u32())
        var offset = UInt64(end.u32())
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            let locatorStart = tailStart + UInt64(position)
            guard locatorStart >= 20 else { throw damaged }
            let locator = ByteCursor([UInt8](try read(locatorStart - 20, 20)), at: 0)
            guard locator.u32() == ZipCentralRecord.zip64LocatorSignature else { throw damaged }
            _ = locator.u32()
            let recordOffset = locator.u64()
            let record = ByteCursor([UInt8](try read(recordOffset, 56)), at: 0)
            guard record.u32() == ZipCentralRecord.zip64EndSignature else { throw damaged }
            _ = record.u64()
            _ = record.u16()
            _ = record.u16()
            _ = record.u32()
            _ = record.u32()
            _ = record.u64()
            count = record.u64()
            size = record.u64()
            offset = record.u64()
        }
        guard offset + size <= fileSize, count <= UInt64(Int32.max) else { throw damaged }
        return (offset, size, Int(count))
    }

    static func parseCentralDirectory(_ data: Data, count: Int) throws -> [Entry] {
        let bytes = [UInt8](data)
        let cursor = ByteCursor(bytes, at: 0)
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard cursor.remaining >= 46, cursor.u32() == ZipCentralRecord.centralHeaderSignature else { throw damaged }
            _ = cursor.u16()
            _ = cursor.u16()
            let flags = cursor.u16()
            let method = cursor.u16()
            _ = cursor.u16()
            _ = cursor.u16()
            let crc = cursor.u32()
            var compressed = UInt64(cursor.u32())
            var size = UInt64(cursor.u32())
            let nameLength = Int(cursor.u16())
            let extraLength = Int(cursor.u16())
            let commentLength = Int(cursor.u16())
            _ = cursor.u16()
            _ = cursor.u16()
            _ = cursor.u32()
            var offset = UInt64(cursor.u32())
            guard cursor.remaining >= nameLength + extraLength + commentLength else { throw damaged }
            let nameBytes = cursor.bytes(nameLength)
            // Names are UTF-8 when flagged and in practice almost always; CP437 names of old tools come out as Latin 1.
            let name = String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? ""
            let extraEnd = cursor.position + extraLength
            while cursor.position + 4 <= extraEnd {
                let id = cursor.u16()
                let length = Int(cursor.u16())
                let fieldEnd = cursor.position + length
                guard fieldEnd <= extraEnd else { throw damaged }
                if id == 0x0001 {
                    if size == 0xFFFF_FFFF, cursor.position + 8 <= fieldEnd { size = cursor.u64() }
                    if compressed == 0xFFFF_FFFF, cursor.position + 8 <= fieldEnd { compressed = cursor.u64() }
                    if offset == 0xFFFF_FFFF, cursor.position + 8 <= fieldEnd { offset = cursor.u64() }
                }
                cursor.position = fieldEnd
            }
            cursor.position = extraEnd + commentLength
            entries.append(Entry(name: name, method: method, flags: flags, crc: crc, compressedSize: compressed, size: size, localHeaderOffset: offset))
        }
        return entries
    }

    // MARK: Data

    /// Where the entry's data starts: after its local header, whose name and extra field lengths may differ
    /// from the central directory's.
    private func dataOffset(of entry: Entry) throws -> UInt64 {
        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let header = try handle.read(upToCount: 30), header.count == 30 else { throw Self.damaged }
        let cursor = ByteCursor([UInt8](header), at: 0)
        guard cursor.u32() == ZipCentralRecord.localHeaderSignature else { throw Self.damaged }
        cursor.position = 26
        let nameLength = UInt64(cursor.u16())
        let extraLength = UInt64(cursor.u16())
        let start = entry.localHeaderOffset + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= fileSize else { throw Self.damaged }
        return start
    }

    /// The whole entry, for parts that are small enough to hold in memory.
    func contents(of entry: Entry, limit: UInt64 = 256 << 20) throws -> Data {
        guard entry.size <= limit else {
            throw DatabaseError.unsupported("\(entry.name) in the archive is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)).")
        }
        let source = try stream(of: entry)
        var data = Data(capacity: Int(entry.size))
        while let chunk = try source.read() { data.append(contentsOf: chunk) }
        return data
    }

    /// The entry's bytes in chunks, expanded on the fly and checked against its CRC at the end.
    func stream(of entry: Entry) throws -> ZipEntrySource {
        guard entry.method == ZipCentralRecord.stored || entry.method == ZipCentralRecord.deflated else {
            throw DatabaseError.unsupported("\(entry.name) is compressed with a method Foxlume Query cannot read (\(entry.method)).")
        }
        guard entry.flags & 0x0001 == 0 else { throw DatabaseError.unsupported("The archive is encrypted.") }
        let handle = try FileHandle(forReadingFrom: url)
        let start = try dataOffset(of: entry)
        try handle.seek(toOffset: start)
        return try ZipEntrySource(handle: handle, entry: entry)
    }
}

/// Reads little-endian fields from a byte array.
final class ByteCursor {
    private let bytes: [UInt8]
    var position: Int

    init(_ bytes: [UInt8], at position: Int) {
        self.bytes = bytes
        self.position = position
    }

    var remaining: Int { bytes.count - position }

    func u16() -> UInt16 {
        guard position + 2 <= bytes.count else { position = bytes.count; return 0 }
        defer { position += 2 }
        return UInt16(bytes[position]) | UInt16(bytes[position + 1]) << 8
    }

    func u32() -> UInt32 {
        UInt32(u16()) | UInt32(u16()) << 16
    }

    func u64() -> UInt64 {
        UInt64(u32()) | UInt64(u32()) << 32
    }

    func bytes(_ count: Int) -> ArraySlice<UInt8> {
        let end = min(bytes.count, position + count)
        defer { position = end }
        return bytes[position..<end]
    }
}

/// One entry's data, inflated chunk by chunk. `consumedBytes` counts compressed bytes, for progress.
final class ZipEntrySource: RawByteSource {
    private let handle: FileHandle
    private let entry: ZipReader.Entry
    private var remainingInput: UInt64
    private var input: [UInt8] = []
    private var inputOffset = 0
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0, src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    private var streamReady = false
    private let output = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 17)
    private let outputSize = 1 << 17
    private var ended = false
    private var inflateEnded = false
    private var crc: UInt32 = 0
    private var produced: UInt64 = 0
    private(set) var consumedBytes: Int64 = 0

    var totalBytes: Int64 { Int64(entry.compressedSize) }

    init(handle: FileHandle, entry: ZipReader.Entry) throws {
        self.handle = handle
        self.entry = entry
        remainingInput = entry.compressedSize
        if entry.method == ZipCentralRecord.deflated {
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                output.deallocate()
                throw DatabaseError.unsupported("Could not start DEFLATE decompression.")
            }
            streamReady = true
        }
    }

    deinit {
        if streamReady { compression_stream_destroy(&stream) }
        output.deallocate()
        try? handle.close()
    }

    private func readInput() throws -> [UInt8] {
        guard remainingInput > 0 else { return [] }
        let count = Int(min(remainingInput, 1 << 16))
        guard let data = try handle.read(upToCount: count), data.count == count else { throw ZipReader.damaged }
        remainingInput -= UInt64(count)
        consumedBytes += Int64(count)
        return [UInt8](data)
    }

    func read() throws -> [UInt8]? {
        guard !ended else { return nil }
        let chunk: [UInt8]
        if entry.method == ZipCentralRecord.stored {
            chunk = try readInput()
            if chunk.isEmpty { return try finish() }
        } else {
            chunk = try inflate()
            if chunk.isEmpty { return try finish() }
        }
        crc = chunk.withUnsafeBytes { CRC32.update(crc, $0) }
        produced += UInt64(chunk.count)
        return chunk
    }

    private func finish() throws -> [UInt8]? {
        ended = true
        guard crc == entry.crc, produced == entry.size else {
            throw DatabaseError.unsupported("\(entry.name) in the archive is damaged (its checksum does not match).")
        }
        return nil
    }

    /// The next inflated bytes, or an empty array at the end of the entry.
    private func inflate() throws -> [UInt8] {
        guard !inflateEnded else { return [] }
        while true {
            if inputOffset >= input.count {
                input = try readInput()
                inputOffset = 0
            }
            let atEnd = input.isEmpty
            var result: [UInt8] = []
            let status: compression_status = input.withUnsafeBufferPointer { buffer in
                stream.src_ptr = buffer.baseAddress.map { $0 + inputOffset } ?? UnsafePointer<UInt8>(bitPattern: 1)!
                stream.src_size = input.count - inputOffset
                stream.dst_ptr = output
                stream.dst_size = outputSize
                let status = compression_stream_process(&stream, atEnd ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                inputOffset = input.count - stream.src_size
                result = Array(UnsafeBufferPointer(start: output, count: outputSize - stream.dst_size))
                return status
            }
            switch status {
            case COMPRESSION_STATUS_END:
                inflateEnded = true
                return result
            case COMPRESSION_STATUS_OK:
                if !result.isEmpty { return result }
                if atEnd { throw DatabaseError.unsupported("\(entry.name) in the archive is truncated.") }
            default:
                throw DatabaseError.unsupported("\(entry.name) in the archive is damaged.")
            }
        }
    }
}

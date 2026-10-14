import Compression
import Foundation

/// Character encodings an imported text file may use.
public enum ImportTextEncoding: String, CaseIterable, Sendable, Identifiable, Codable {
    /// Byte order mark first, then UTF-8 when the start of the file is valid UTF-8, else Windows-1252.
    case automatic
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    case isoLatin1
    case windows1252
    case macRoman

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return "Detect Automatically"
        case .utf8: return "UTF-8"
        case .utf16LittleEndian: return "UTF-16 (Little Endian)"
        case .utf16BigEndian: return "UTF-16 (Big Endian)"
        case .isoLatin1: return "ISO Latin 1"
        case .windows1252: return "Windows Latin 1 (CP1252)"
        case .macRoman: return "Mac Roman"
        }
    }

    var foundationEncoding: String.Encoding {
        switch self {
        case .automatic, .utf8: return .utf8
        case .utf16LittleEndian: return .utf16LittleEndian
        case .utf16BigEndian: return .utf16BigEndian
        case .isoLatin1: return .isoLatin1
        case .windows1252: return .windowsCP1252
        case .macRoman: return .macOSRoman
        }
    }

    var isUTF16: Bool { self == .utf16LittleEndian || self == .utf16BigEndian }

    /// The encoding for a file that starts with `sample`, and how many leading bytes are a byte order mark.
    public static func detect(_ sample: [UInt8]) -> (encoding: ImportTextEncoding, bomLength: Int) {
        if sample.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if sample.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if sample.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        return (isMostlyValidUTF8(sample) ? .utf8 : .windows1252, 0)
    }

    /// The byte order mark length for an explicitly chosen encoding, so it never reaches the data.
    static func bomLength(of sample: [UInt8], for encoding: ImportTextEncoding) -> Int {
        switch encoding {
        case .utf8, .automatic: return sample.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        case .utf16LittleEndian: return sample.starts(with: [0xFF, 0xFE]) ? 2 : 0
        case .utf16BigEndian: return sample.starts(with: [0xFE, 0xFF]) ? 2 : 0
        case .isoLatin1, .windows1252, .macRoman: return 0
        }
    }

    /// Valid UTF-8, allowing the sample to end in the middle of a multi-byte sequence.
    static func isMostlyValidUTF8(_ bytes: [UInt8]) -> Bool {
        var end = bytes.count
        // Drop an incomplete sequence at the end of the sample (at most three bytes).
        var back = 0
        while back < 3, end - back - 1 >= 0, bytes[end - back - 1] & 0xC0 == 0x80 { back += 1 }
        if end - back - 1 >= 0 {
            let lead = bytes[end - back - 1]
            let needed = lead >= 0xF0 ? 3 : lead >= 0xE0 ? 2 : lead >= 0xC0 ? 1 : 0
            if needed > back { end = end - back - 1 }
        }
        return String(bytes: bytes[0..<end], encoding: .utf8) != nil
    }
}

/// Reads a text file as UTF-8 bytes in chunks, whatever its encoding, so parsers only deal with
/// ASCII-compatible bytes. UTF-16 is transcoded; single-byte encodings pass through and are
/// decoded by the parser field by field. Gzip files are expanded on the fly.
final class TextChunkSource {
    let encoding: ImportTextEncoding
    let isCompressed: Bool
    private let raw: RawByteSource
    private var pending: [UInt8]?
    private var carry: [UInt8] = []
    private var finished = false
    /// Bytes of the file on disk, which for gzip files is the compressed size.
    let totalBytes: Int64

    var bytesRead: Int64 { raw.consumedBytes }

    init(url: URL, encoding requested: ImportTextEncoding, chunkSize: Int = 1 << 16) throws {
        let file = try FileByteSource(url: url, chunkSize: max(16, chunkSize))
        totalBytes = file.totalBytes
        let first = try file.read() ?? []
        if first.starts(with: [0x1F, 0x8B, 0x08]) {
            raw = try GunzipByteSource(file: file, firstChunk: first)
            isCompressed = true
        } else {
            raw = file
            file.unread(first)
            isCompressed = false
        }
        var sample = try raw.read() ?? []
        let resolved: ImportTextEncoding
        let bom: Int
        if requested == .automatic {
            (resolved, bom) = ImportTextEncoding.detect(sample)
        } else {
            resolved = requested
            bom = ImportTextEncoding.bomLength(of: sample, for: requested)
        }
        encoding = resolved
        sample.removeFirst(min(bom, sample.count))
        pending = sample
    }

    /// The next chunk, or nil at the end of the file. For UTF-16 files the chunk is already UTF-8.
    func next() throws -> [UInt8]? {
        guard !finished else { return nil }
        let data: [UInt8]
        if let pending {
            data = pending
            self.pending = nil
        } else {
            data = try raw.read() ?? []
        }
        if data.isEmpty {
            finished = true
            guard !carry.isEmpty else { return nil }
            defer { carry = [] }
            guard encoding.isUTF16 else { return carry }
            throw DatabaseError.unsupported("The file ends in the middle of a UTF-16 character.")
        }
        guard encoding.isUTF16 else { return data }
        var bytes = carry + data
        carry = []
        // Keep an odd trailing byte and a trailing high surrogate for the next chunk.
        if bytes.count % 2 == 1 { carry = [bytes.removeLast()] }
        if bytes.count >= 2 {
            let pair = (bytes[bytes.count - 2], bytes[bytes.count - 1])
            let unit = encoding == .utf16LittleEndian ? UInt16(pair.1) << 8 | UInt16(pair.0) : UInt16(pair.0) << 8 | UInt16(pair.1)
            if (0xD800...0xDBFF).contains(unit) {
                carry = Array(bytes.suffix(2)) + carry
                bytes.removeLast(2)
            }
        }
        if bytes.isEmpty { return [] }
        guard let text = String(bytes: bytes, encoding: encoding.foundationEncoding) else {
            throw DatabaseError.unsupported("The file is not valid \(encoding.title) text.")
        }
        return Array(text.utf8)
    }

    /// Decodes one field's bytes. Bytes are UTF-8 unless the file uses a single-byte encoding.
    func decode(_ bytes: ArraySlice<UInt8>) -> String? {
        switch encoding {
        case .automatic, .utf8, .utf16LittleEndian, .utf16BigEndian:
            return String(bytes: bytes, encoding: .utf8)
        case .isoLatin1, .windows1252, .macRoman:
            if !bytes.contains(where: { $0 >= 0x80 }) { return String(decoding: bytes, as: UTF8.self) }
            // CP1252 leaves five byte values undefined; Latin 1 maps every byte, so it is the fallback.
            return String(bytes: bytes, encoding: encoding.foundationEncoding) ?? String(bytes: bytes, encoding: .isoLatin1)
        }
    }
}

/// Raw bytes of a file, in chunks.
protocol RawByteSource: AnyObject {
    /// The next chunk, or nil at the end.
    func read() throws -> [UInt8]?
    /// Bytes taken from the file so far, for progress.
    var consumedBytes: Int64 { get }
}

final class FileByteSource: RawByteSource {
    private let handle: FileHandle
    private let chunkSize: Int
    private var pushedBack: [UInt8]?
    private(set) var consumedBytes: Int64 = 0
    let totalBytes: Int64

    init(url: URL, chunkSize: Int) throws {
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DatabaseError.unsupported("Could not open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        self.chunkSize = chunkSize
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        totalBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    deinit { try? handle.close() }

    /// Hands `bytes` out again on the next read, so the caller could peek at the start of the file.
    func unread(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        pushedBack = bytes
        consumedBytes -= Int64(bytes.count)
    }

    func read() throws -> [UInt8]? {
        if let pushedBack {
            self.pushedBack = nil
            consumedBytes += Int64(pushedBack.count)
            return pushedBack
        }
        let data = handle.readData(ofLength: chunkSize)
        guard !data.isEmpty else { return nil }
        consumedBytes += Int64(data.count)
        return [UInt8](data)
    }
}

/// Expands a gzip (RFC 1952) file with the system DEFLATE decoder. Only the first member is read.
final class GunzipByteSource: RawByteSource {
    private let file: FileByteSource
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0, src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    private var input: [UInt8]
    private var inputOffset = 0
    private var ended = false
    private let output = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 17)
    private let outputSize = 1 << 17

    var consumedBytes: Int64 { file.consumedBytes }

    init(file: FileByteSource, firstChunk: [UInt8]) throws {
        self.file = file
        var chunk = firstChunk
        // The header can in theory be longer than one chunk (a long file name); gather until it parses.
        while true {
            if let headerLength = Self.headerLength(chunk) {
                input = Array(chunk[headerLength...])
                break
            }
            guard let more = try file.read() else { throw DatabaseError.unsupported("The gzip header is damaged.") }
            chunk += more
        }
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            output.deallocate()
            throw DatabaseError.unsupported("Could not start gzip decompression.")
        }
    }

    deinit {
        compression_stream_destroy(&stream)
        output.deallocate()
    }

    /// Length of the gzip member header, or nil when `bytes` does not hold all of it yet.
    static func headerLength(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 10 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard bytes.count >= index + 2 else { return nil }
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {
            guard let end = bytes[min(index, bytes.count)...].firstIndex(of: 0) else { return nil }
            index = end + 1
        }
        if flags & 0x02 != 0 { index += 2 }
        return index <= bytes.count ? index : nil
    }

    func read() throws -> [UInt8]? {
        guard !ended else { return nil }
        while true {
            if inputOffset >= input.count {
                if let more = try file.read() {
                    input = more
                    inputOffset = 0
                } else {
                    input = []
                    inputOffset = 0
                }
            }
            let atEOF = input.isEmpty
            var produced: [UInt8] = []
            let status: compression_status = input.withUnsafeBufferPointer { buffer in
                let base = buffer.baseAddress.map { $0 + inputOffset } ?? UnsafePointer<UInt8>(bitPattern: 1)!
                stream.src_ptr = base
                stream.src_size = input.count - inputOffset
                stream.dst_ptr = output
                stream.dst_size = outputSize
                let result = compression_stream_process(&stream, atEOF ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                inputOffset = input.count - stream.src_size
                produced = Array(UnsafeBufferPointer(start: output, count: outputSize - stream.dst_size))
                return result
            }
            switch status {
            case COMPRESSION_STATUS_END:
                ended = true
                return produced.isEmpty ? nil : produced
            case COMPRESSION_STATUS_OK:
                if !produced.isEmpty { return produced }
                if atEOF { throw DatabaseError.unsupported("The gzip file is truncated.") }
            default:
                throw DatabaseError.unsupported("The gzip file is damaged.")
            }
        }
    }
}

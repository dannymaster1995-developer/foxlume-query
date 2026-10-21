import Compression
import Foundation

/// Buffered writer for one export file. Writes go to a hidden temporary file next to the destination,
/// which replaces the destination only in `commit()`, so a failed or cancelled export never leaves a
/// half-written file behind or clobbers an existing one. Optionally gzip-compresses on the fly.
final class ExportFileWriter {
    let destination: URL
    private let temporary: URL
    private let handle: FileHandle
    private var buffer = Data()
    private let bufferLimit = 1 << 18
    private var gzip: GzipEncoder?
    private var finished = false
    /// Uncompressed bytes written so far.
    private(set) var bytesWritten: Int64 = 0

    init(destination: URL, compress: Bool) throws {
        self.destination = destination
        let directory = destination.deletingLastPathComponent()
        temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString.prefix(8)).partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw DatabaseError.unsupported("Could not create a file in \(directory.path). Check that the folder exists and is writable.")
        }
        do {
            handle = try FileHandle(forWritingTo: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        if compress { gzip = try GzipEncoder() }
    }

    deinit {
        if !finished { discard() }
    }

    func write(_ text: String) throws {
        buffer.append(contentsOf: text.utf8)
        bytesWritten += Int64(text.utf8.count)
        if buffer.count >= bufferLimit { try flush() }
    }

    func write(_ data: Data) throws {
        buffer.append(data)
        bytesWritten += Int64(data.count)
        if buffer.count >= bufferLimit { try flush() }
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        let bytes = buffer
        buffer.removeAll(keepingCapacity: true)
        if let gzip {
            try handle.write(contentsOf: try gzip.encode(bytes, final: false))
        } else {
            try handle.write(contentsOf: bytes)
        }
    }

    /// Flushes, closes and moves the file into place, replacing what was there.
    func commit() throws {
        guard !finished else { return }
        try flush()
        if let gzip { try handle.write(contentsOf: try gzip.encode(Data(), final: true)) }
        try handle.close()
        finished = true
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
    }

    /// Drops the temporary file; the destination is left untouched.
    func discard() {
        guard !finished else { return }
        finished = true
        try? handle.close()
        try? FileManager.default.removeItem(at: temporary)
    }
}

/// Streaming gzip (RFC 1952) built on the system DEFLATE encoder, which produces raw RFC 1951 data.
final class GzipEncoder {
    private let deflater: DeflateEncoder
    private var crc: UInt32 = 0
    private var size: UInt32 = 0
    private var wroteHeader = false

    init() throws {
        deflater = try DeflateEncoder()
    }

    func encode(_ data: Data, final: Bool) throws -> Data {
        var result = Data()
        if !wroteHeader {
            // Magic, deflate, no flags, no time, no extra flags, OS unknown.
            result.append(contentsOf: [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
            wroteHeader = true
        }
        crc = CRC32.update(crc, data)
        size = size &+ UInt32(truncatingIfNeeded: data.count)
        do {
            result.append(try deflater.encode(data, final: final))
        } catch {
            throw DatabaseError.unsupported("gzip compression failed.")
        }
        if final {
            for value in [crc, size] {
                result.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
            }
        }
        return result
    }
}

/// Streaming raw DEFLATE (RFC 1951) on the system encoder, for gzip files and ZIP entries.
final class DeflateEncoder {
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0, src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    private let output = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 16)
    private let outputSize = 1 << 16

    init() throws {
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            output.deallocate()
            throw DatabaseError.unsupported("Could not start DEFLATE compression.")
        }
    }

    deinit {
        compression_stream_destroy(&stream)
        output.deallocate()
    }

    /// Compresses `data`. `final` ends the stream; the encoder cannot be used afterwards.
    func encode(_ data: Data, final: Bool) throws -> Data {
        var result = Data()
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            stream.src_ptr = base ?? UnsafePointer<UInt8>(bitPattern: 1)!
            stream.src_size = data.count
            let flags = final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            while true {
                stream.dst_ptr = output
                stream.dst_size = outputSize
                let status = compression_stream_process(&stream, flags)
                let produced = outputSize - stream.dst_size
                if produced > 0 { result.append(output, count: produced) }
                switch status {
                case COMPRESSION_STATUS_OK:
                    if stream.src_size == 0, stream.dst_size > 0 { return }
                case COMPRESSION_STATUS_END:
                    return
                default:
                    throw DatabaseError.unsupported("DEFLATE compression failed.")
                }
            }
        }
        return result
    }
}

/// CRC-32 (IEEE 802.3), as gzip and ZIP need it.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        data.withUnsafeBytes { update(crc, $0) }
    }

    static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var value = ~crc
        // Unsafe buffers keep this fast in debug builds too, where the tests run.
        table.withUnsafeBufferPointer { table in
            for byte in bytes {
                value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
            }
        }
        return ~value
    }
}

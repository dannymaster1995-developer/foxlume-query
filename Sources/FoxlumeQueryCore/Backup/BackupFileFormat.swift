import Foundation

/// Which engine wrote a plain SQL dump, from its header comment.
public enum PlainDumpDialect: String, Sendable {
    case postgresql
    case mysql
}

/// What a file chosen for Restore holds, told from its first bytes rather than its name.
public enum BackupFileKind: Equatable, Sendable {
    /// pg_dump custom archive (starts with `PGDMP`).
    case postgresCustom
    /// pg_dump directory archive (a folder with `toc.dat`).
    case postgresDirectory
    /// pg_dump tar archive (a tar whose first entry is `toc.dat`).
    case postgresTar
    /// A SQL script, possibly gzip-compressed, with the dialect when its header names one.
    case plainSQL(compressed: Bool, dialect: PlainDumpDialect?)
    case unknown

    public var isPostgresArchive: Bool {
        self == .postgresCustom || self == .postgresDirectory || self == .postgresTar
    }

    public var title: String {
        switch self {
        case .postgresCustom: return "pg_dump custom archive"
        case .postgresDirectory: return "pg_dump directory archive"
        case .postgresTar: return "pg_dump tar archive"
        case let .plainSQL(compressed, dialect):
            let engine = dialect.map { $0 == .postgresql ? "PostgreSQL " : "MySQL " } ?? ""
            return "\(engine)SQL script" + (compressed ? " (gzip)" : "")
        case .unknown: return "unknown format"
        }
    }

    /// Reads the start of the file (expanding gzip) and tells the kind.
    public static func detect(_ url: URL) -> BackupFileKind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .unknown }
        if isDirectory.boolValue {
            return FileManager.default.fileExists(atPath: url.appendingPathComponent("toc.dat").path) ? .postgresDirectory : .unknown
        }
        guard let file = try? FileByteSource(url: url, chunkSize: 1 << 14), let first = try? file.read() else { return .unknown }
        if first.starts(with: [0x1F, 0x8B, 0x08]) {
            guard let gunzip = try? GunzipByteSource(file: file, firstChunk: first) else { return .unknown }
            var text: [UInt8] = []
            while text.count < 4096, let more = try? gunzip.read() { text += more }
            return detect(header: text, compressed: true)
        }
        return detect(header: first, compressed: false)
    }

    /// The kind from the first bytes of a file (already expanded when `compressed`).
    public static func detect(header bytes: [UInt8], compressed: Bool) -> BackupFileKind {
        if !compressed, bytes.starts(with: Array("PGDMP".utf8)) { return .postgresCustom }
        if !compressed, bytes.count >= 262, Array(bytes[257..<262]) == Array("ustar".utf8) {
            let name = bytes[0..<100].prefix { $0 != 0 }
            return Array(name) == Array("toc.dat".utf8) ? .postgresTar : .unknown
        }
        // Text: no NUL bytes in the sample.
        guard !bytes.prefix(4096).contains(0) else { return .unknown }
        let head = String(decoding: bytes.prefix(4096), as: UTF8.self)
        let dialect: PlainDumpDialect?
        if head.contains("-- PostgreSQL database dump") || head.contains("SET standard_conforming_strings") || head.contains("pg_catalog.set_config") {
            dialect = .postgresql
        } else if head.contains("-- MySQL dump") || head.contains("-- MariaDB dump") || head.contains("/*!40101 SET") {
            dialect = .mysql
        } else {
            dialect = nil
        }
        return .plainSQL(compressed: compressed, dialect: dialect)
    }
}

/// Looks through a plain SQL dump for what Run SQL File cannot run.
public enum PlainDumpInspector {
    /// Whether the script loads data with `COPY … FROM stdin` (pg_dump's default), which needs psql.
    /// Reads the whole file line by line (expanding gzip); stops at the first such line.
    public static func usesCopyFromStdin(_ url: URL, cancellation: OperationCancellation? = nil) throws -> Bool {
        let source = try TextChunkSource(url: url, encoding: .automatic, chunkSize: 1 << 18)
        var line: [UInt8] = []
        var atLineStart = true
        var collecting = false
        while let chunk = try source.next() {
            try cancellation?.check()
            for byte in chunk {
                if byte == 0x0A {
                    if collecting, isCopyFromStdin(line) { return true }
                    line.removeAll(keepingCapacity: true)
                    atLineStart = true
                    collecting = false
                    continue
                }
                if atLineStart {
                    atLineStart = false
                    // Only lines starting with "COPY" matter; skip the rest without keeping their bytes.
                    collecting = byte == 0x43 || byte == 0x63
                }
                if collecting, line.count < 4096 { line.append(byte) }
            }
        }
        return collecting && isCopyFromStdin(line)
    }

    static func isCopyFromStdin(_ line: [UInt8]) -> Bool {
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return text.hasPrefix("COPY ") && text.hasSuffix("FROM STDIN;")
    }
}

/// Raw bytes of a file for a tool's standard input, gzip expanded on the fly.
final class RawFileReader {
    private let source: RawByteSource
    let isCompressed: Bool
    let totalBytes: Int64

    init(url: URL) throws {
        let file = try FileByteSource(url: url, chunkSize: 1 << 17)
        totalBytes = file.totalBytes
        let first = try file.read() ?? []
        if first.starts(with: [0x1F, 0x8B, 0x08]) {
            source = try GunzipByteSource(file: file, firstChunk: first)
            isCompressed = true
        } else {
            file.unread(first)
            source = file
            isCompressed = false
        }
    }

    var bytesRead: Int64 { source.consumedBytes }

    func read() throws -> [UInt8]? { try source.read() }
}

import Foundation

/// Scratch files for tests. `FileManager.temporaryDirectory` ignores `TMPDIR` on macOS, while `fqtest`
/// points `TMPDIR` inside the project folder, so tests must use this instead.
enum TestFiles {
    static var directory: URL {
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty {
            return URL(fileURLWithPath: tmp, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Removes a SQLite database together with its WAL, shared-memory and journal files.
    static func removeDatabase(_ url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}

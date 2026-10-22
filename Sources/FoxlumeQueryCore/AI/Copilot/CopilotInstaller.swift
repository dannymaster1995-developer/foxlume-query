import CryptoKit
import Foundation
import os

/// The GitHub Copilot language server release the app runs. Pinned: an app release changes it after checking the
/// new tarballs, so what runs on a Mac is what was reviewed. The package is MIT (`@github/copilot-language-server`).
public enum CopilotRelease {
    public static let version = "1.557.0"

    public struct Digests: Sendable, Equatable {
        /// SHA-256 of the npm tarball.
        public var tarball: String
        /// SHA-256 of `package/copilot-language-server` inside it.
        public var binary: String

        public init(tarball: String, binary: String) {
            self.tarball = tarball
            self.binary = binary
        }
    }

    public static let digests: [String: Digests] = [
        "darwin-arm64": Digests(
            tarball: "093aa07fe0b55f9dd448ed2817d2f7dc940dfb4ba468b93c188b42272ff3a7af",
            binary: "fb8d5ccaacfde5e101f20d2225e9eb04bfc3745dcd08f54e36ef9713e792dcc2"
        ),
        "darwin-x64": Digests(
            tarball: "dc4c69ede4eb3b766b2920eb7c1b301a8a8739c0008ccfb0c1ec7744768d7ab8",
            binary: "a297fac8a3f4d1562e4636c8426cdefae1b40cbf987cf2908975d5d683838dac"
        ),
    ]

    /// The npm platform name of this Mac.
    public static var currentPlatform: String {
        #if arch(arm64)
        return "darwin-arm64"
        #else
        return "darwin-x64"
        #endif
    }

    /// `https://registry.npmjs.org/@github/copilot-language-server-<platform>/-/copilot-language-server-<platform>-<version>.tgz`
    public static func tarballURL(platform: String, version: String = version) -> URL {
        URL(string: "https://registry.npmjs.org/@github/copilot-language-server-\(platform)/-/copilot-language-server-\(platform)-\(version).tgz")!
    }

    /// The folder versions are installed in: `<data folder>/copilot-language-server`.
    public static var installRoot: URL {
        AppPaths.dataDirectory.appendingPathComponent("copilot-language-server", isDirectory: true)
    }
}

public enum CopilotInstallError: Error, Equatable, LocalizedError {
    case unsupportedPlatform(String)
    case downloadFailed(String)
    case checksumMismatch(String)
    case extractFailed(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform(let platform):
            return "GitHub Copilot is not available for this Mac (\(platform))."
        case .downloadFailed(let detail):
            return "Could not download the GitHub Copilot language server: \(detail)"
        case .checksumMismatch(let what):
            return "The downloaded GitHub Copilot language server did not match its expected checksum (\(what)), so it was not installed."
        case .extractFailed(let detail):
            return "Could not unpack the GitHub Copilot language server: \(detail)"
        case .installFailed(let detail):
            return "Could not install the GitHub Copilot language server: \(detail)"
        }
    }
}

/// Downloads, checks and installs the pinned language server: the platform tarball from npm, its SHA-256 and the
/// extracted binary's SHA-256 checked against `CopilotRelease`, only the binary unpacked (with /usr/bin/tar) into
/// `<root>/<version>/` with mode 0755 and a `version.txt`. An installed binary is hashed again before each start, and
/// reinstalled when its version or hash differs.
public actor CopilotInstaller {
    static let log = Logger(subsystem: "com.foxlume.query", category: "copilot")

    public let root: URL
    public let version: String
    public let platform: String
    private let digests: [String: CopilotRelease.Digests]
    private let session: URLSession
    private var running: Task<URL, Error>?

    public init(root: URL = CopilotRelease.installRoot, version: String = CopilotRelease.version,
                platform: String = CopilotRelease.currentPlatform, digests: [String: CopilotRelease.Digests] = CopilotRelease.digests,
                session: URLSession = .shared) {
        self.root = root
        self.version = version
        self.platform = platform
        self.digests = digests
        self.session = session
    }

    public nonisolated var installDirectory: URL { root.appendingPathComponent(version, isDirectory: true) }
    public nonisolated var executableURL: URL { installDirectory.appendingPathComponent("copilot-language-server") }
    nonisolated var versionFile: URL { installDirectory.appendingPathComponent("version.txt") }

    /// The installed binary is the pinned version and its bytes match the pinned hash.
    public func isInstalled() -> Bool {
        guard let expected = digests[platform]?.binary,
              FileManager.default.isExecutableFile(atPath: executableURL.path),
              (try? String(contentsOf: versionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == version
        else { return false }
        return Self.sha256(ofFileAt: executableURL) == expected
    }

    /// The binary to start, downloading it first when needed. `progress` gets the downloaded fraction (nil while the
    /// size is unknown). Concurrent callers share one download.
    public func ensureInstalled(progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws -> URL {
        if isInstalled() { return executableURL }
        if let running { return try await running.value }
        let task = Task { try await install(progress: progress) }
        running = task
        defer { running = nil }
        return try await task.value
    }

    private func install(progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        guard let digests = digests[platform] else { throw CopilotInstallError.unsupportedPlatform(platform) }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw CopilotInstallError.installFailed(error.localizedDescription)
        }
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let archive = staging.appendingPathComponent("package.tgz")
        let tarballHash = try await CopilotDownload.run(session: session, url: CopilotRelease.tarballURL(platform: platform, version: version),
                                                        to: archive, progress: progress)
        guard tarballHash == digests.tarball else {
            Self.log.error("Copilot language server tarball hash mismatch: \(tarballHash, privacy: .public)")
            throw CopilotInstallError.checksumMismatch("package")
        }
        try await Self.extractBinary(from: archive, into: staging)
        let extracted = staging.appendingPathComponent("copilot-language-server")
        guard Self.sha256(ofFileAt: extracted) == digests.binary else {
            throw CopilotInstallError.checksumMismatch("copilot-language-server")
        }
        do {
            try? fileManager.removeItem(at: installDirectory)
            try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: extracted, to: executableURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
            try (version + "\n").write(to: versionFile, atomically: true, encoding: .utf8)
        } catch {
            throw CopilotInstallError.installFailed(error.localizedDescription)
        }
        // Earlier versions are not needed any more.
        for item in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent != version && !item.lastPathComponent.hasPrefix(".staging-") {
            try? fileManager.removeItem(at: item)
        }
        Self.log.info("Installed the Copilot language server \(self.version, privacy: .public)")
        return executableURL
    }

    /// Unpacks only `package/copilot-language-server`, without its folder, into `directory`.
    static func extractBinary(from archive: URL, into directory: URL) async throws {
        let tar = ToolProcess(executable: "/usr/bin/tar",
                              arguments: ["-xzf", archive.path, "-C", directory.path, "--strip-components=1", "package/copilot-language-server"],
                              environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"])
        let messages = LineCollector()
        tar.onErrorLine = { messages.append($0) }
        let code: Int32 = try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do {
                    try tar.start()
                    continuation.resume(returning: tar.waitUntilExit())
                } catch {
                    continuation.resume(throwing: CopilotInstallError.extractFailed(error.localizedDescription))
                }
            }
        }
        guard code == 0, FileManager.default.fileExists(atPath: directory.appendingPathComponent("copilot-language-server").path) else {
            throw CopilotInstallError.extractFailed(messages.lines.last ?? "tar exited with code \(code)")
        }
    }

    public static func sha256(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}

/// One download to a file with progress, hashed while it is written. Cancelling the calling task cancels it.
enum CopilotDownload {
    static func run(session: URLSession, url: URL, to file: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> String {
        guard FileManager.default.createFile(atPath: file.path, contents: nil), let handle = try? FileHandle(forWritingTo: file) else {
            throw CopilotInstallError.installFailed("Could not write \(file.lastPathComponent)")
        }
        let receiver = Receiver(handle: handle, progress: progress)
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "GET"
        let task = session.dataTask(with: request)
        task.delegate = receiver
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let handle: FileHandle
        let progress: @Sendable (Double?) -> Void
        var continuation: CheckedContinuation<String, Error>?
        private var hasher = SHA256()
        private var expected: Int64 = -1
        private var received: Int64 = 0
        private var failure: Error?
        private var lastReported = -1.0

        init(handle: FileHandle, progress: @escaping @Sendable (Double?) -> Void) {
            self.handle = handle
            self.progress = progress
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failure = CopilotInstallError.downloadFailed("the server answered HTTP \(http.statusCode)")
                completionHandler(.cancel)
                return
            }
            expected = response.expectedContentLength
            progress(expected > 0 ? 0 : nil)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard failure == nil else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                failure = CopilotInstallError.installFailed(error.localizedDescription)
                dataTask.cancel()
                return
            }
            hasher.update(data: data)
            received += Int64(data.count)
            guard expected > 0 else { return }
            let fraction = min(1, Double(received) / Double(expected))
            if fraction - lastReported >= 0.01 || fraction == 1 {
                lastReported = fraction
                progress(fraction)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle.close()
            let continuation = self.continuation
            self.continuation = nil
            if let failure {
                continuation?.resume(throwing: failure)
            } else if let error {
                if (error as? URLError)?.code == .cancelled {
                    continuation?.resume(throwing: CancellationError())
                } else {
                    continuation?.resume(throwing: CopilotInstallError.downloadFailed(error.localizedDescription))
                }
            } else {
                continuation?.resume(returning: CopilotInstaller.hex(hasher.finalize()))
            }
        }
    }
}

import Foundation
import os

/// A language server started with `--stdio` in a process group of its own (`ToolProcess`: no inherited file
/// descriptors but the three standard ones), its standard output fed to an `LSPEndpoint` and its standard error
/// logged at debug level.
public final class LSPServerProcess: @unchecked Sendable {
    static let log = Logger(subsystem: "com.foxlume.query", category: "lsp")

    public let endpoint: LSPEndpoint
    private let process: ToolProcess
    /// Writes and the closing of standard input, in order.
    private let writes = DispatchQueue(label: "com.foxlume.query.lsp.write")
    private let stateLock = NSLock()
    private var exitCode: Int32?
    private var stopping = false

    /// Called once on a background thread when the process has exited: its exit code and whether `stop` or
    /// `terminate` asked for it.
    public var onExit: (@Sendable (_ code: Int32, _ requested: Bool) -> Void)?

    public init(executable: URL, arguments: [String] = ["--stdio"], environment: [String: String], requestTimeout: TimeInterval = 30) {
        let process = ToolProcess(executable: executable.path, arguments: arguments, environment: environment, input: .pipe)
        // One message after the other, never on the caller's thread: a server that stops reading must not block the
        // main thread on a full pipe, and two messages must never interleave their bytes.
        let writes = self.writes
        self.process = process
        endpoint = LSPEndpoint(defaultTimeout: requestTimeout) { [weak process] data in
            guard let process else { return false }
            writes.async { _ = process.writeInput([UInt8](data)) }
            return true
        }
    }

    public func start() throws {
        let endpoint = self.endpoint
        process.onOutput = { data in endpoint.receive(data) }
        process.onErrorLine = { line in Self.log.debug("server stderr: \(line, privacy: .public)") }
        do {
            try process.start()
        } catch {
            throw LSPError.connectionClosed("Could not start the language server: \(error.localizedDescription)")
        }
        Thread.detachNewThread { [self] in
            let code = process.waitUntilExit()
            let requested: Bool = stateLock.withLock {
                exitCode = code
                return stopping
            }
            endpoint.close(reason: requested ? "The language server was stopped" : "The language server exited (code \(code))")
            onExit?(code, requested)
        }
    }

    public var hasExited: Bool { stateLock.withLock { exitCode != nil } }

    /// Asks the server to shut down (`shutdown`, then `exit`), and ends the process group if it is still there
    /// after `grace` seconds.
    public func stop(grace: TimeInterval = 2) async {
        stateLock.withLock { stopping = true }
        if !hasExited {
            _ = try? await endpoint.request("shutdown", timeout: grace)
            endpoint.notify("exit")
        }
        closeInput()
        let deadline = Date().addingTimeInterval(grace)
        while !hasExited, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if !hasExited { process.terminate(grace: 1) }
    }

    /// Ends the process group at once (SIGTERM, then SIGKILL): app quit.
    public func terminate() {
        stateLock.withLock { stopping = true }
        closeInput()
        process.terminate(grace: 1)
    }

    /// After the messages already queued.
    private func closeInput() {
        writes.async { [process] in process.closeInput() }
    }
}

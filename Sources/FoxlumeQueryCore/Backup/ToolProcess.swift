import Darwin
import Foundation

/// A command-line tool started in a process group of its own, so Cancel stops it together with any workers it
/// forked (pg_dump and pg_restore with `--jobs`). Standard error is delivered line by line; standard output either
/// streams to a handler or is discarded; standard input is empty or fed by the caller.
///
/// The child inherits no file descriptors but its three standard ones (`POSIX_SPAWN_CLOEXEC_DEFAULT`), so the app's
/// database sockets and pipes never leak into it.
public final class ToolProcess: @unchecked Sendable {
    public enum Input {
        case none
        /// The caller writes with `writeInput` and ends with `closeInput`.
        case pipe
    }

    public let executable: String
    public let arguments: [String]
    private let environment: [String: String]
    private let input: Input
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var inputDescriptor: Int32 = -1
    private var readers = DispatchGroup()
    private var exited = false
    private var terminateRequested = false

    /// Called on a background thread with each chunk of standard output; nil discards it.
    public var onOutput: ((Data) -> Void)?
    /// Called on a background thread with each line of standard error.
    public var onErrorLine: ((String) -> Void)?

    /// `environment` replaces the app's own (see `ToolProcess.environment(adding:)`).
    public init(executable: String, arguments: [String], environment: [String: String], input: Input = .none) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.input = input
    }

    /// The app's environment without the variables PostgreSQL and MySQL clients read on their own (PGPASSWORD,
    /// PGHOST, MYSQL_PWD, …), which would override the connection's settings, plus `extra`.
    public static func environment(adding extra: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !(key.hasPrefix("PG") || key.hasPrefix("MYSQL_") || key == "MARIADB_HOME" || key == "LIBMYSQL_ENABLE_CLEARTEXT_PLUGIN")
        }
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    public func start() throws {
        var outputPipe: [Int32] = [-1, -1]
        var errorPipe: [Int32] = [-1, -1]
        var inputPipe: [Int32] = [-1, -1]
        func closeAll() {
            for descriptor in outputPipe + errorPipe + inputPipe where descriptor >= 0 { close(descriptor) }
        }
        guard pipe(&errorPipe) == 0, onOutput == nil || pipe(&outputPipe) == 0, input == .none || pipe(&inputPipe) == 0 else {
            closeAll()
            throw BackupError.unsupported("Could not start \(name): \(String(cString: strerror(errno))).")
        }
        // The app's ends must not leak into other children either.
        for descriptor in [errorPipe[0], outputPipe[0], inputPipe[1]] where descriptor >= 0 {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        if inputPipe[1] >= 0 {
            // A tool that exits early must not kill the app with SIGPIPE.
            _ = fcntl(inputPipe[1], F_SETNOSIGPIPE, 1)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if inputPipe[0] >= 0 {
            posix_spawn_file_actions_adddup2(&actions, inputPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        if outputPipe[1] >= 0 {
            posix_spawn_file_actions_adddup2(&actions, outputPipe[1], 1)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, errorPipe[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGCHLD] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let status = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        // The child's ends belong to the child now.
        for descriptor in [errorPipe[1], outputPipe[1], inputPipe[0]] where descriptor >= 0 { close(descriptor) }
        guard status == 0 else {
            for descriptor in [errorPipe[0], outputPipe[0], inputPipe[1]] where descriptor >= 0 { close(descriptor) }
            if status == ENOENT || status == EACCES || status == ENOEXEC { throw BackupError.toolNotRunnable(path: executable) }
            throw BackupError.unsupported("Could not start \(name): \(String(cString: strerror(status))).")
        }
        lock.lock()
        pid = child
        inputDescriptor = inputPipe[1]
        lock.unlock()

        readers = DispatchGroup()
        let errorDescriptor = errorPipe[0]
        readLoop(errorDescriptor) { [weak self] data, final in self?.splitLines(data, final: final) }
        if outputPipe[0] >= 0 {
            readLoop(outputPipe[0]) { [weak self] data, _ in
                if !data.isEmpty { self?.onOutput?(data) }
            }
        }
    }

    private var name: String { (executable as NSString).lastPathComponent }

    private func readLoop(_ descriptor: Int32, handle: @escaping (Data, Bool) -> Void) {
        readers.enter()
        Thread.detachNewThread { [readers] in
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    handle(Data(buffer[0..<count]), false)
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            handle(Data(), true)
            close(descriptor)
            readers.leave()
        }
    }

    private var partialLine = Data()

    private func splitLines(_ data: Data, final: Bool) {
        partialLine.append(data)
        while let index = partialLine.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = partialLine[partialLine.startIndex..<index]
            partialLine = Data(partialLine[(index + 1)...])
            if !line.isEmpty { onErrorLine?(String(decoding: line, as: UTF8.self)) }
        }
        if final, !partialLine.isEmpty {
            onErrorLine?(String(decoding: partialLine, as: UTF8.self))
            partialLine = Data()
        }
    }

    /// Writes to the tool's standard input; false when the tool stopped reading (it exited or closed it).
    public func writeInput(_ bytes: [UInt8]) -> Bool {
        lock.lock()
        let descriptor = inputDescriptor
        lock.unlock()
        guard descriptor >= 0 else { return false }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress! + offset, bytes.count - offset) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    public func closeInput() {
        lock.lock()
        let descriptor = inputDescriptor
        inputDescriptor = -1
        lock.unlock()
        if descriptor >= 0 { close(descriptor) }
    }

    /// Waits for the tool to exit and for its output to be read. Returns the exit code, or 128 + the signal number
    /// when a signal ended it.
    @discardableResult
    public func waitUntilExit() -> Int32 {
        lock.lock()
        let child = pid
        lock.unlock()
        guard child > 0 else { return -1 }
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0, errno == EINTR {}
        lock.lock()
        exited = true
        lock.unlock()
        closeInput()
        // The group's other members may still hold the pipes; they get SIGKILL in terminate, otherwise wait a moment.
        _ = readers.wait(timeout: .now() + 10)
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    /// Stops the tool and every process in its group: SIGTERM, then SIGKILL after `grace` seconds.
    public func terminate(grace: TimeInterval = 3) {
        lock.lock()
        let child = pid
        let done = exited
        terminateRequested = true
        lock.unlock()
        guard child > 0, !done else { return }
        killpg(child, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let finished = self.exited
            self.lock.unlock()
            if !finished { killpg(child, SIGKILL) }
        }
    }

    public var wasTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminateRequested
    }
}

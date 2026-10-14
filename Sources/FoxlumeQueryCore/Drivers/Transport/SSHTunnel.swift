import Darwin
import Foundation

/// Forwards a local port to the database through the system `ssh` client.
///
/// Passwords and key passphrases reach ssh through `SSH_ASKPASS`: a two-line helper script prints the
/// secret from ssh's environment. The script holds no secret, and only the ssh child process gets the variable.
public final class SSHTunnel: @unchecked Sendable {
    static let secretKey = "FOXLUME_SSH_SECRET"
    public static var sshExecutable = "/usr/bin/ssh"

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var running: [ObjectIdentifier: Process] = [:]

    /// Terminates every tunnel this process started. Call when the app quits, since windows
    /// are not closed one by one at termination and ssh would otherwise outlive the app.
    public static func stopAll() {
        registryLock.lock()
        let processes = Array(running.values)
        running.removeAll()
        registryLock.unlock()
        for process in processes where process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
    static let askPassScript = "#!/bin/sh\nprintf '%s\\n' \"$FOXLUME_SSH_SECRET\"\n"

    private let config: SSHConfig
    private let secret: String?
    private let remoteHost: String
    private let remotePort: Int
    private let lock = NSLock()
    private var process: Process?
    private var errorOutput = Data()
    public private(set) var localPort = 0

    public init(config: SSHConfig, secret: String?, remoteHost: String, remotePort: Int) {
        self.config = config
        self.secret = secret
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    deinit { stop() }

    /// Starts ssh and waits until the forwarded port accepts connections. Returns the local port.
    public func start(timeout: TimeInterval, knownHostsFile: URL) throws -> Int {
        guard !config.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DatabaseError.connection("Enter the SSH host.")
        }
        localPort = try Self.freeLocalPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sshExecutable)
        process.arguments = arguments(timeout: timeout, knownHostsFile: knownHostsFile)
        process.environment = try environment(helperDirectory: knownHostsFile.deletingLastPathComponent())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // At EOF the handler keeps firing with empty data, so detach it.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.lock.lock()
            self.errorOutput.append(data)
            if self.errorOutput.count > 16_384 { self.errorOutput.removeFirst(self.errorOutput.count - 16_384) }
            self.lock.unlock()
        }
        do {
            try process.run()
        } catch {
            throw DatabaseError.connection("Cannot start ssh: \(error.localizedDescription)")
        }
        lock.lock()
        self.process = process
        lock.unlock()
        Self.registryLock.lock()
        Self.running[ObjectIdentifier(self)] = process
        Self.registryLock.unlock()

        let deadline = Date().addingTimeInterval(timeout + 5)
        while Date() < deadline {
            if !process.isRunning {
                process.waitUntilExit()
                errors.fileHandleForReading.readabilityHandler = nil
                throw DatabaseError.connection(failureMessage(exitCode: process.terminationStatus))
            }
            if Self.portAcceptsConnections(localPort) { return localPort }
            Thread.sleep(forTimeInterval: 0.1)
        }
        stop()
        throw DatabaseError.connection("The SSH tunnel to \(config.host) did not open within \(Int(timeout)) seconds.")
    }

    public func stop() {
        lock.lock()
        let process = self.process
        self.process = nil
        lock.unlock()
        Self.registryLock.lock()
        Self.running.removeValue(forKey: ObjectIdentifier(self))
        Self.registryLock.unlock()
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        guard let process, process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    func arguments(timeout: TimeInterval, knownHostsFile: URL) -> [String] {
        var arguments = [
            "-N", "-T",
            "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)",
            "-p", String(config.port),
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=\(max(1, Int(timeout)))",
            // First connection to a host records its key; a changed key afterwards fails loudly.
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsFile.path)",
            "-o", "NumberOfPasswordPrompts=1",
        ]
        let hasSecret = !(secret ?? "").isEmpty
        switch config.authMethod {
        case .agent:
            arguments += ["-o", "BatchMode=yes"]
        case .keyFile:
            arguments += ["-i", (config.keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
            if !hasSecret { arguments += ["-o", "BatchMode=yes"] }
        case .password:
            arguments += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"]
        }
        let user = config.user.trimmingCharacters(in: .whitespaces)
        arguments.append(user.isEmpty ? config.host : "\(user)@\(config.host)")
        return arguments
    }

    private func environment(helperDirectory: URL) throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: Self.secretKey)
        guard let secret, !secret.isEmpty else { return environment }
        environment["SSH_ASKPASS"] = try Self.installAskPassHelper(in: helperDirectory).path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment[Self.secretKey] = secret
        return environment
    }

    /// Writes the helper once per data folder, readable and executable only by the user.
    static func installAskPassHelper(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("ssh-askpass.sh")
        let existing = try? String(contentsOf: url, encoding: .utf8)
        if existing != askPassScript {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try askPassScript.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func failureMessage(exitCode: Int32) -> String {
        lock.lock()
        let text = String(decoding: errorOutput, as: UTF8.self)
        lock.unlock()
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        let detail = lines.suffix(4).joined(separator: "\n")
        return "SSH tunnel to \(config.host) failed (exit \(exitCode))." + (detail.isEmpty ? "" : "\n" + detail)
    }

    static func freeLocalPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw DatabaseError.connection("Cannot open a local socket") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { throw DatabaseError.connection("Cannot reserve a local port for the SSH tunnel") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    static func portAcceptsConnections(_ port: Int) -> Bool {
        let transport = SocketTransport()
        defer { transport.close() }
        return (try? transport.connect(host: "127.0.0.1", port: port, timeout: 0.3)) != nil
    }
}

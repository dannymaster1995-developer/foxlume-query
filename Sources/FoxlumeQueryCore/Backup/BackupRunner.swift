import Foundation

/// The connection a backup or restore uses: the saved settings with their secrets, and the database to act on.
public struct BackupConnection: Sendable {
    public var parameters: ConnectionParameters
    public var database: String
    /// The server's version as the session reported it, for tool options that depend on it.
    public var serverVersion: ServerVersion?

    public init(parameters: ConnectionParameters, database: String, serverVersion: ServerVersion? = nil) {
        self.parameters = parameters
        self.database = database
        self.serverVersion = serverVersion
    }
}

/// One backup or restore.
public enum BackupJob: Sendable {
    case postgresBackup(scope: BackupScope, options: PostgresBackupOptions, destination: URL)
    case mysqlBackup(scope: BackupScope, options: MySQLBackupOptions, destination: URL)
    /// pg_restore of a custom, directory or tar archive into the connection's database.
    case postgresRestore(archive: URL, kind: BackupFileKind, options: PostgresRestoreOptions)
    /// A plain SQL script (gzip expanded) through psql or the mysql client.
    case scriptRestore(file: URL, singleTransaction: Bool)

    /// The tool the job runs, for the connection's engine.
    public func tool(for kind: DatabaseKind) -> BackupTool {
        switch self {
        case .postgresBackup: return .pgDump
        case .mysqlBackup: return .mysqldump
        case .postgresRestore: return .pgRestore
        case .scriptRestore: return kind == .postgresql ? .psql : .mysql
        }
    }

    public var isBackup: Bool {
        switch self {
        case .postgresBackup, .mysqlBackup: return true
        case .postgresRestore, .scriptRestore: return false
        }
    }
}

public enum BackupRunStatus: String, Sendable {
    case succeeded
    case failed
    case cancelled
}

/// How a run ended.
public struct BackupRunResult: Sendable {
    public var status: BackupRunStatus
    /// The tool's exit code; nil when it never started.
    public var exitCode: Int32?
    public var elapsed: TimeInterval
    /// The backup written, on success.
    public var outputURL: URL?
    public var outputSize: Int64?
    /// The command as it ran, secret files shown by their label.
    public var command: String
    public var notes: [String]
    /// Why it failed: the tool's last error lines, or what stopped it from starting.
    public var message: String?
}

public enum BackupRunEvent: Sendable {
    /// The tool started with this command (secrets shown by their label).
    case started(command: String)
    /// A line the tool wrote to standard error (pg_dump --verbose, mysqldump --verbose, server notices).
    case log(String)
    /// Bytes of the backup written so far.
    case outputSize(Int64)
    /// Bytes of the script read so far (of the file on disk, compressed for gzip), for script restores.
    case inputProgress(read: Int64, total: Int64)
}

/// Runs one job: opens the connection's SSH tunnel, writes the password and client key files (0600, in a private
/// folder), starts the tool in its own process group, streams its messages, and cleans up whatever happens. A backup
/// is written to a hidden partial file or folder next to the destination and moved into place only when the tool
/// succeeds, so a failed or cancelled backup leaves nothing behind and never clobbers an older backup.
public final class BackupRunner: @unchecked Sendable {
    public let job: BackupJob
    public let connection: BackupConnection
    public let tool: BackupToolCandidate
    private let secretParent: URL?
    private let knownHostsFile: URL
    private let lock = NSLock()
    private var cancelled = false
    private var process: ToolProcess?
    private var tunnel: SSHTunnel?

    public init(job: BackupJob, connection: BackupConnection, tool: BackupToolCandidate, secretParent: URL? = nil, knownHostsFile: URL = AppPaths.knownHostsFile) {
        self.job = job
        self.connection = connection
        self.tool = tool
        self.secretParent = secretParent
        self.knownHostsFile = knownHostsFile
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Stops the tool (and its workers) or the tunnel being opened; the run then ends as cancelled.
    public func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        let tunnel = self.tunnel
        lock.unlock()
        process?.terminate()
        if process == nil { tunnel?.stop() }
    }

    /// The hidden file or folder a backup is written to before it is moved into place.
    static func partialURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString.prefix(8)).partial")
    }

    /// Size of a file, or of every file inside a folder.
    public static func size(of url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return ((try? manager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let item = enumerator?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Runs the job to the end. Blocks; call it off the main thread. Never throws: failures are in the result.
    public func run(events: @escaping (BackupRunEvent) -> Void) -> BackupRunResult {
        let started = Date()
        var command = ""
        var notes: [String] = []
        func result(_ status: BackupRunStatus, exitCode: Int32? = nil, output: URL? = nil, message: String? = nil) -> BackupRunResult {
            let size = output.map { Self.size(of: $0) }
            return BackupRunResult(status: status, exitCode: exitCode, elapsed: Date().timeIntervalSince(started), outputURL: output, outputSize: size, command: command, notes: notes, message: message)
        }

        let config = connection.parameters.config
        let secrets: BackupSecretDirectory
        do {
            secrets = try BackupSecretDirectory(parent: secretParent)
        } catch {
            return result(.failed, message: error.localizedDescription)
        }
        defer { secrets.remove() }

        // Endpoint: TLS files, then the tunnel.
        var endpoint: BackupEndpoint
        do {
            let tls = try BackupTLSFiles.resolve(mode: config.sslMode, files: config.tlsFiles, secret: connection.parameters.tlsSecret, in: secrets)
            endpoint = BackupEndpoint(host: config.host, port: config.port, user: config.user, database: connection.database, sslMode: config.sslMode,
                                      caPath: tls.caPath, certificatePath: tls.certificatePath, keyPath: tls.keyPath)
            if config.usesSSH, let ssh = config.ssh {
                let tunnel = SSHTunnel(config: ssh, secret: connection.parameters.sshSecret, remoteHost: config.host, remotePort: config.port)
                lock.lock()
                self.tunnel = tunnel
                let stop = cancelled
                lock.unlock()
                if stop { return result(.cancelled) }
                events(.log("Opening the SSH tunnel to \(ssh.host)…"))
                let port = try tunnel.start(timeout: TimeInterval(max(config.connectTimeout, 5)), knownHostsFile: knownHostsFile)
                endpoint.host = "127.0.0.1"
                endpoint.port = port
                endpoint.tunnelledHost = connection.parameters.tlsServerName ?? config.host
            }
        } catch {
            if isCancelled { return result(.cancelled) }
            return result(.failed, message: error.localizedDescription)
        }
        defer {
            lock.lock()
            let tunnel = self.tunnel
            self.tunnel = nil
            lock.unlock()
            tunnel?.stop()
        }

        // The command.
        let password = connection.parameters.password
        var invocation: ToolInvocation
        var partial: URL?
        var destination: URL?
        var writer: ExportFileWriter?
        var scriptFile: URL?
        switch job {
        case let .postgresBackup(scope, options, target):
            let path = Self.partialURL(for: target)
            partial = path
            destination = target
            invocation = BackupCommandBuilder.pgDump(tool: tool, endpoint: endpoint, scope: scope, options: options, output: path.path, password: password, secretDirectory: secrets.url)
        case let .mysqlBackup(scope, options, target):
            destination = target
            invocation = BackupCommandBuilder.mysqldump(tool: tool, endpoint: endpoint, server: connection.serverVersion, scope: scope, options: options, password: password, secretDirectory: secrets.url)
            do {
                writer = try ExportFileWriter(destination: target, compress: options.compress)
            } catch {
                return result(.failed, message: error.localizedDescription)
            }
        case let .postgresRestore(archive, kind, options):
            invocation = BackupCommandBuilder.pgRestore(tool: tool, endpoint: endpoint, archive: archive.path, archiveIsTar: kind == .postgresTar, options: options, password: password, secretDirectory: secrets.url)
        case let .scriptRestore(file, singleTransaction):
            scriptFile = file
            if config.kind == .postgresql {
                invocation = BackupCommandBuilder.psqlScript(tool: tool, endpoint: endpoint, singleTransaction: singleTransaction, password: password, secretDirectory: secrets.url)
            } else {
                invocation = BackupCommandBuilder.mysqlScript(tool: tool, endpoint: endpoint, password: password, secretDirectory: secrets.url)
            }
        }
        var replacements: [String: String] = [:]
        if let partial, let destination { replacements[partial.path] = destination.path }
        command = invocation.displayCommand(replacing: replacements)
        if let scriptFile { command += " < " + ToolInvocation.shellQuoted(scriptFile.path) }
        notes = invocation.notes

        func discardOutput() {
            writer?.discard()
            if let partial { try? FileManager.default.removeItem(at: partial) }
        }

        do {
            try secrets.write(invocation.secretFiles)
        } catch {
            discardOutput()
            return result(.failed, message: error.localizedDescription)
        }

        let process = ToolProcess(
            executable: invocation.executable,
            arguments: invocation.arguments,
            environment: ToolProcess.environment(adding: invocation.environment),
            input: scriptFile == nil ? .none : .pipe
        )
        var errorLines: [String] = []
        // pg_restore errors over the whole run, and how many of them were transaction_timeout on an older server.
        var restoreErrors = 0
        var transactionTimeoutErrors = 0
        let linesLock = NSLock()
        process.onErrorLine = { line in
            linesLock.lock()
            errorLines.append(line)
            if errorLines.count > 400 { errorLines.removeFirst(errorLines.count - 400) }
            if line.hasPrefix("pg_restore: error:") {
                restoreErrors += 1
                if line.contains(BackupCompatibility.transactionTimeoutError) { transactionTimeoutErrors += 1 }
            }
            linesLock.unlock()
            events(.log(line))
        }
        var writeFailure: String?
        if let writer {
            var lastReport = Date.distantPast
            process.onOutput = { [weak process] data in
                guard writeFailure == nil else { return }
                do {
                    try writer.write(data)
                } catch {
                    writeFailure = "Could not write the backup: \(error.localizedDescription)"
                    process?.terminate()
                    return
                }
                let now = Date()
                if now.timeIntervalSince(lastReport) >= 0.2 {
                    lastReport = now
                    events(.outputSize(writer.bytesWritten))
                }
            }
        }

        lock.lock()
        if cancelled {
            lock.unlock()
            discardOutput()
            return result(.cancelled)
        }
        self.process = process
        lock.unlock()
        do {
            try process.start()
        } catch {
            discardOutput()
            return result(.failed, message: error.localizedDescription)
        }
        events(.started(command: command))

        // pg_dump writes the file itself; watch its size.
        var sizeTimer: DispatchSourceTimer?
        if let partial {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + 0.3, repeating: 0.5)
            timer.setEventHandler { events(.outputSize(Self.size(of: partial))) }
            timer.resume()
            sizeTimer = timer
        }
        var feedFailure: String?
        var skippedTransactionTimeout = false
        let feeding = DispatchGroup()
        if let scriptFile {
            var filter = config.kind == .postgresql && BackupCompatibility.skipsTransactionTimeout(server: connection.serverVersion)
                ? TransactionTimeoutFilter() : nil
            feeding.enter()
            Thread.detachNewThread {
                defer {
                    process.closeInput()
                    feeding.leave()
                }
                do {
                    let reader = try RawFileReader(url: scriptFile)
                    var lastReport = Date.distantPast
                    var open = true
                    while open, let chunk = try reader.read() {
                        let bytes = filter?.filter(chunk, final: false) ?? chunk
                        open = bytes.isEmpty || process.writeInput(bytes)
                        let now = Date()
                        if now.timeIntervalSince(lastReport) >= 0.2 {
                            lastReport = now
                            events(.inputProgress(read: reader.bytesRead, total: reader.totalBytes))
                        }
                    }
                    if open, let rest = filter?.filter([], final: true), !rest.isEmpty { _ = process.writeInput(rest) }
                    skippedTransactionTimeout = filter?.removed ?? false
                    events(.inputProgress(read: reader.totalBytes, total: reader.totalBytes))
                } catch {
                    feedFailure = error.localizedDescription
                    process.terminate()
                }
            }
        }

        let exitCode = process.waitUntilExit()
        feeding.wait()
        sizeTimer?.cancel()
        lock.lock()
        self.process = nil
        lock.unlock()

        linesLock.lock()
        let lines = errorLines
        let onlyTransactionTimeout = restoreErrors > 0 && restoreErrors == transactionTimeoutErrors
        linesLock.unlock()
        if skippedTransactionTimeout {
            notes.append("pg_dump's SET transaction_timeout was left out: this server does not have that setting.")
        }
        if isCancelled {
            discardOutput()
            return result(.cancelled, exitCode: exitCode)
        }
        if let failure = writeFailure ?? feedFailure {
            discardOutput()
            return result(.failed, exitCode: exitCode, message: failure)
        }
        // pg_restore 17 and newer set transaction_timeout, which older servers reject. Without a single transaction
        // pg_restore carries on, so when that was its only error the restore is complete.
        if case let .postgresRestore(_, _, options) = job, exitCode != 0, onlyTransactionTimeout {
            if options.singleTransaction {
                return result(.failed, exitCode: exitCode, message: BackupCompatibility.transactionTimeoutNote(tool: tool.version, failed: true))
            }
            notes.append(BackupCompatibility.transactionTimeoutNote(tool: tool.version, failed: false))
            return result(.succeeded, exitCode: exitCode)
        }
        guard exitCode == 0 else {
            discardOutput()
            return result(.failed, exitCode: exitCode, message: Self.failureMessage(lines, tool: (invocation.executable as NSString).lastPathComponent, exitCode: exitCode))
        }
        // Success: move the backup into place.
        do {
            if let writer {
                try writer.commit()
            } else if let partial, let destination {
                let manager = FileManager.default
                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: destination)
                }
                try manager.moveItem(at: partial, to: destination)
            }
        } catch {
            discardOutput()
            return result(.failed, exitCode: exitCode, message: "The backup was written but could not be moved into place: \(error.localizedDescription)")
        }
        if let destination { events(.outputSize(Self.size(of: destination))) }
        return result(.succeeded, exitCode: exitCode, output: destination)
    }

    /// The tool's error lines (`pg_dump: error: …`, `mysqldump: Got error: …`), else its last lines.
    static func failureMessage(_ lines: [String], tool: String, exitCode: Int32) -> String {
        let errors = lines.filter { line in
            let lower = line.lowercased()
            return lower.contains("error") || lower.contains("fatal") || lower.contains("couldn't") || lower.contains("denied")
        }
        let shown = (errors.isEmpty ? lines : errors).suffix(6)
        let exit = exitCode > 128 ? "was stopped by signal \(exitCode - 128)" : "exited with code \(exitCode)"
        return shown.isEmpty ? "\(tool) \(exit)." : shown.joined(separator: "\n")
    }
}

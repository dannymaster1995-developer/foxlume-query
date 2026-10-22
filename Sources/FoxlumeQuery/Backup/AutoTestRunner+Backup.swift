import AppKit
import FoxlumeQueryCore

/// Scripted commands for Backup and Restore. Relative paths are inside the data folder (the run folder of a script).
///
///     backupmenu [main]               logs the Backup and Restore items: of the Database menu (main, disabled ones in
///                                     brackets) or of the sidebar's context menus (selection, empty area, schema picker)
///     backup [database|schema <name>|tables <name…>]   opens the Backup sheet for that scope (default: as
///                                     Database › Backup… would, from the sidebar selection)
///     backupset <option> <value>      format custom|plain|directory|tar, content schemaAndData|schemaOnly|dataOnly,
///                                     compress, inserts, noowner, singletransaction, routines, triggers, events
///                                     true|false, scope database|schemas|tables
///     backupstate                     logs the tool line, scope, warning, missing-tool message and whether it can start
///     backupstart <path>              starts the backup into <path>, as the save panel would
///     backupcancel [bytes]            cancels the running backup or restore once it has written that many bytes
///     backupwait                      waits until the backup or restore has finished
///     backupresult                    logs the outcome, the command (data folder shown as {DATA}) and the notes
///     restore <path>                  opens the Restore sheet for the file
///     restoreset <option> <value>     database <name>, runner runsqlfile|client, clean, noowner, singletransaction
///                                     true|false, jobs <n>
///     restorestate                    logs the file line, tool line, problem and the choices
///     restorestart                    presses Restore… / Continue… (the confirmation follows; answer with confirm)
@MainActor
enum BackupAutoTest {
    static let commands: Set<String> = [
        "backupmenu", "backup", "backupset", "backupstate", "backupstart", "backupcancel", "backupwait", "backupresult",
        "restore", "restoreset", "restorestate", "restorestart",
    ]

    static func path(_ argument: String) -> URL {
        let expanded = (argument as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : AppPaths.dataDirectory.appendingPathComponent(expanded)
    }

    static func shown(_ text: String) -> String {
        text.replacingOccurrences(of: AppPaths.dataDirectory.path, with: "{DATA}")
    }

    /// The run of the sheet in front, Backup or Restore.
    static var run: ToolRunState? {
        BackupController.presented?.model.run ?? RestoreController.presented?.model.run
    }
}

extension AutoTestRunner {
    func performBackup(_ command: String, _ argument: String) async throws {
        guard let window = workspace else { throw DatabaseError.notConnected }
        let flag = argument.split(separator: " ").last.map { $0 == "true" } ?? false
        switch command {
        case "backupmenu":
            if argument == "main" {
                let items = [NSMenuItem(title: "Backup…", action: #selector(WorkspaceWindowController.backupDatabase(_:)), keyEquivalent: ""),
                             NSMenuItem(title: "Restore…", action: #selector(WorkspaceWindowController.restoreDatabase(_:)), keyEquivalent: "")]
                record("  main: " + items.map { item in
                    window.validateMenuItem(item) ? item.title : "[\(item.title)]" + (item.toolTip.map { " (\($0))" } ?? "")
                }.joined(separator: " | "))
            } else {
                let sidebar = window.sidebarController
                let relevant: (String) -> Bool = { $0.hasPrefix("Backup") || $0.hasPrefix("Restore") }
                record("  selection: " + sidebar.menuTitlesForSelection().filter(relevant).joined(separator: " | "))
                record("  schema picker: " + sidebar.schemaMenuTitles().filter(relevant).joined(separator: " | "))
                let selected = sidebar.selectedTableInfos.map(\.ref)
                record("  empty area: " + sidebar.menuTitlesForBackground().filter(relevant).joined(separator: " | "))
                sidebar.select(selected)
            }
        case "backup":
            let parts = argument.split(separator: " ").map(String.init)
            switch parts.first {
            case nil: window.backupDatabase(nil)
            case "database": window.presentBackup(.database)
            case "schema": window.presentBackup(.schemas(Array(parts.dropFirst())))
            case "tables":
                let names = Set(parts.dropFirst())
                window.presentBackup(.tables(window.workspace.tables.filter { names.contains($0.name) }.map(\.ref)))
            default: throw DatabaseError.unsupported("backup [database|schema <name>|tables <name…>]")
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            try await waitFor(seconds: 20) { BackupController.presented?.model.toolSearch != nil }
        case "backupset":
            guard let model = BackupController.presented?.model else { throw DatabaseError.unsupported("No Backup sheet") }
            let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw DatabaseError.unsupported("backupset <option> <value>") }
            switch parts[0] {
            case "format": model.postgres.format = PostgresBackupFormat(rawValue: parts[1]) ?? .custom
            case "content":
                let content = BackupContent(rawValue: parts[1]) ?? .schemaAndData
                model.postgres.content = content
                model.mysql.content = content
            case "compress":
                model.postgres.compressPlain = flag
                model.mysql.compress = flag
            case "inserts": model.postgres.useInserts = flag
            case "noowner": model.postgres.noOwner = flag
            case "singletransaction": model.mysql.singleTransaction = flag
            case "routines": model.mysql.routines = flag
            case "triggers": model.mysql.triggers = flag
            case "events": model.mysql.events = flag
            case "scope": model.scopeKind = BackupModel.ScopeKind(rawValue: parts[1]) ?? .database
            default: throw DatabaseError.unsupported("Unknown backup option \(parts[0])")
            }
        case "backupstate":
            guard let model = BackupController.presented?.model else { throw DatabaseError.unsupported("No Backup sheet") }
            record("  tool: " + model.toolLine)
            record("  scope: \(model.scopeKind.rawValue) · \(model.scopeSummary) · file \(model.suggestedName.replacingOccurrences(of: #"\d{4}-\d{2}-\d{2}-\d{4}"#, with: "<date>", options: .regularExpression))")
            if let warning = model.warning { record("  warning: " + warning) }
            if let missing = model.missingToolMessage { record("  missing: " + missing.replacingOccurrences(of: "\n", with: " / ")) }
            record("  can start: \(model.canStart)")
        case "backupstart":
            guard let model = BackupController.presented?.model else { throw DatabaseError.unsupported("No Backup sheet") }
            let destination = BackupAutoTest.path(argument)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard model.canStart else { return record("  cannot start") }
            model.start(destination: destination)
            try await Task.sleep(nanoseconds: 200_000_000)
        case "backupcancel":
            guard let run = BackupAutoTest.run, run.hasStarted else { throw DatabaseError.unsupported("Nothing running") }
            let bytes = Int64(argument) ?? 0
            try await waitFor(seconds: 30) { (run.outputSize ?? 0) >= bytes || !run.isRunning }
            if run.isRunning { run.cancel() } else { record("  finished before it could be cancelled") }
        case "backupwait":
            try await Task.sleep(nanoseconds: 300_000_000)
            try await waitFor(seconds: 120) { BackupAutoTest.run?.isRunning != true }
            try await Task.sleep(nanoseconds: 400_000_000)
        case "backupresult":
            guard let run = BackupAutoTest.run, let result = run.result else { throw DatabaseError.unsupported("No finished run") }
            let title = BackupController.presented?.model.resultTitle ?? RestoreController.presented?.model.resultTitle ?? ""
            record("  \(result.status.rawValue): \(title)")
            if result.status == .failed { record("  message: " + BackupAutoTest.shown(result.message ?? "").replacingOccurrences(of: "\n", with: " / ")) }
            if let url = result.outputURL { record("  output: \(BackupAutoTest.shown(url.path)), \(result.outputSize ?? 0 > 0 ? "not empty" : "empty")") }
            record("  command: " + BackupAutoTest.shown(run.command ?? result.command))
            for note in result.notes { record("  note: " + note) }
            record("  log: \(run.lines.isEmpty ? "empty" : "\(run.lines.count > 3 ? "several lines" : "\(run.lines.count) lines")")")
        case "restore":
            window.presentRestore(file: BackupAutoTest.path(argument))
            try await Task.sleep(nanoseconds: 300_000_000)
            try await waitFor(seconds: 30) { RestoreController.presented?.model.isSearching == false }
        case "restoreset":
            guard let model = RestoreController.presented?.model else { throw DatabaseError.unsupported("No Restore sheet") }
            let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw DatabaseError.unsupported("restoreset <option> <value>") }
            switch parts[0] {
            case "database": model.targetDatabase = parts[1]
            case "runner": model.scriptRunner = parts[1] == "client" ? .client : .runSQLFile
            case "clean": model.options.clean = flag
            case "noowner": model.options.noOwner = flag
            case "singletransaction":
                model.options.singleTransaction = flag
                model.singleTransaction = flag
            case "jobs": model.options.jobs = Int(parts[1]) ?? 1
            default: throw DatabaseError.unsupported("Unknown restore option \(parts[0])")
            }
        case "restorestate":
            guard let model = RestoreController.presented?.model else { throw DatabaseError.unsupported("No Restore sheet") }
            record("  file: " + model.fileLine.replacingOccurrences(of: #" · [0-9.,]+ (bytes|KB|MB|GB)"#, with: "", options: .regularExpression))
            if let tool = model.toolLine { record("  tool: " + tool) }
            if let problem = model.problem { record("  problem: " + problem.replacingOccurrences(of: "\n", with: " / ")) }
            if let warning = model.copyWarning { record("  warning: " + warning) }
            record("  into: \(model.targetDatabase) · runner: \(model.tool?.rawValue ?? "Run SQL File") · can restore: \(model.canRestore)")
        case "restorestart":
            guard let model = RestoreController.presented?.model else { throw DatabaseError.unsupported("No Restore sheet") }
            guard model.canRestore else { return record("  cannot restore") }
            model.restoreClicked()
            try await Task.sleep(nanoseconds: 500_000_000)
        default:
            break
        }
    }
}

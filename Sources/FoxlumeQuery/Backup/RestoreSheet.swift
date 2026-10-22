import AppKit
import FoxlumeQueryCore
import SwiftUI

/// State of the Restore sheet: the file and what it holds, the target database and how to restore it.
///
/// pg_dump archives (custom, directory, tar) go through pg_restore. Plain SQL scripts (.sql or .sql.gz) go through
/// Run SQL File, which needs no client tool, or, when chosen or needed (a PostgreSQL script that loads data with
/// COPY … FROM stdin), through psql or the mysql client.
@MainActor
final class RestoreModel: ObservableObject {
    enum ScriptRunner: String, Identifiable {
        case runSQLFile
        case client
        var id: String { rawValue }
    }

    let workspace: ConnectionWorkspace
    @Published private(set) var fileURL: URL?
    @Published private(set) var kind: BackupFileKind = .unknown
    @Published private(set) var fileSize: Int64 = 0
    @Published var targetDatabase: String
    @Published var options: PostgresRestoreOptions
    @Published var scriptRunner: ScriptRunner = .runSQLFile
    @Published var singleTransaction = false
    /// Nil while unknown; true when the script loads data with COPY … FROM stdin.
    @Published private(set) var usesCopy: Bool?
    /// The tool for the file's kind; nil while it is being looked for or when none is needed.
    @Published private(set) var toolSearch: BackupToolSearch?
    @Published private(set) var isSearching = false
    let run = ToolRunState()

    var onClose: (() -> Void)?
    var chooseFile: ((_ completion: @escaping (URL?) -> Void) -> Void)?
    var confirm: ((_ action: String, _ detail: String, _ proceed: @escaping () -> Void) -> Void)?
    /// Hands a plain script to the Run SQL File sheet, for the chosen database.
    var openRunSQLFile: ((_ file: URL, _ database: String) -> Void)?
    var onFinished: (() -> Void)?

    private var inspection: OperationCancellation?

    init(workspace: ConnectionWorkspace, file: URL?) {
        self.workspace = workspace
        targetDatabase = workspace.currentDatabase ?? workspace.config.database
        options = BackupPreferences.load().restore
        if let file { setFile(file) }
    }

    var isPostgres: Bool { workspace.kind == .postgresql }

    /// Databases to restore into: the one in use first.
    var databaseChoices: [String] {
        var names = workspace.databases.filter { !workspace.kind.systemDatabases.contains($0) }
        if let current = workspace.currentDatabase, !names.contains(current) { names.insert(current, at: 0) }
        if !names.contains(targetDatabase), !targetDatabase.isEmpty { names.append(targetDatabase) }
        return names
    }

    func pickFile() {
        chooseFile? { [weak self] url in
            if let url { self?.setFile(url) }
        }
    }

    func setFile(_ url: URL) {
        inspection?.cancel()
        fileURL = url
        fileSize = BackupRunner.size(of: url)
        kind = BackupFileKind.detect(url)
        usesCopy = nil
        toolSearch = nil
        scriptRunner = .runSQLFile
        Task { await inspect(url) }
    }

    private func inspect(_ url: URL) async {
        isSearching = true
        defer { isSearching = false }
        switch kind {
        case .postgresCustom, .postgresDirectory, .postgresTar:
            guard isPostgres else { return }
            toolSearch = await workspace.findBackupTool(.pgRestore)
        case .plainSQL:
            toolSearch = await workspace.findBackupTool(isPostgres ? .psql : .mysql)
            guard isPostgres else { return }
            let cancellation = OperationCancellation()
            inspection = cancellation
            let copy = await Task.detached(priority: .utility) {
                try? PlainDumpInspector.usesCopyFromStdin(url, cancellation: cancellation)
            }.value
            guard !cancellation.isCancelled, fileURL == url else { return }
            usesCopy = copy
            // Run SQL File cannot run COPY … FROM stdin; psql can.
            if copy == true, toolSearch?.chosen != nil { scriptRunner = .client }
        case .unknown:
            return
        }
    }

    var clientName: String { isPostgres ? "psql" : "mysql" }

    /// The tool that will run, nil for Run SQL File.
    var tool: BackupTool? {
        switch kind {
        case .postgresCustom, .postgresDirectory, .postgresTar: return .pgRestore
        case .plainSQL: return scriptRunner == .client ? (isPostgres ? .psql : .mysql) : nil
        case .unknown: return nil
        }
    }

    /// Why the file cannot be restored here, if it cannot.
    var problem: String? {
        guard fileURL != nil else { return nil }
        switch kind {
        case .unknown:
            return "This is not a backup Foxlume Query can restore: choose a pg_dump archive (custom, directory or tar) or a .sql / .sql.gz script."
        case .postgresCustom, .postgresDirectory, .postgresTar:
            if !isPostgres { return "This is a PostgreSQL archive; it can only be restored into a PostgreSQL connection." }
        case .plainSQL(_, let dialect):
            if let dialect, dialect == .postgresql, !isPostgres { return "This script was written by pg_dump for PostgreSQL." }
            if let dialect, dialect == .mysql, isPostgres { return "This script was written by mysqldump for MySQL or MariaDB." }
        }
        if tool != nil, let search = toolSearch, search.chosen == nil {
            return search.missingError.localizedDescription
        }
        return nil
    }

    /// The missing tool needs the settings link.
    var isMissingTool: Bool { tool != nil && toolSearch != nil && toolSearch?.chosen == nil }

    var copyWarning: String? {
        guard isPostgres, usesCopy == true, scriptRunner == .runSQLFile else { return nil }
        return "This script loads data with COPY … FROM stdin, which Run SQL File cannot run. Restore it with psql" + (toolSearch?.chosen == nil ? " (brew install libpq, or Postgres.app)." : ".")
    }

    var canRestore: Bool {
        guard fileURL != nil, problem == nil, !targetDatabase.isEmpty, !run.hasStarted, !isSearching || tool == nil else { return false }
        return tool == nil || toolSearch?.chosen != nil
    }

    /// "pg_restore 17.2"; the path is in its tooltip.
    var toolLine: String? {
        guard tool != nil, let chosen = toolSearch?.chosen else { return nil }
        return "\((chosen.path as NSString).lastPathComponent)\(chosen.version.map { " \($0)" } ?? "")"
    }

    var toolPath: String { toolSearch?.chosen?.path ?? "" }

    var fileLine: String {
        guard let url = fileURL else { return "No file chosen" }
        return "\(url.lastPathComponent) · \(kind.title)" + (fileSize > 0 ? " · \(fileSize.byteCountText)" : "")
    }

    func restoreClicked() {
        guard canRestore, let url = fileURL else { return }
        let action = "Restore \(url.lastPathComponent) into \(targetDatabase)"
        var detail = "Objects and rows from the backup are written into \(targetDatabase) on \(workspace.config.displayName)."
        if kind.isPostgresArchive, options.clean { detail += " Existing objects with the same names are dropped first." }
        confirm?(action, detail) { [weak self] in self?.start() }
    }

    private func start() {
        guard let url = fileURL else { return }
        if tool == nil {
            // Plain script through Run SQL File, confirmed already.
            openRunSQLFile?(url, targetDatabase)
            return
        }
        guard let chosen = toolSearch?.chosen else { return }
        var preferences = BackupPreferences.load()
        preferences.restore = options
        preferences.save()
        let job: BackupJob = kind.isPostgresArchive
            ? .postgresRestore(archive: url, kind: kind, options: options)
            : .scriptRestore(file: url, singleTransaction: singleTransaction)
        let runner = BackupRunner(job: job, connection: workspace.backupConnection(database: targetDatabase), tool: chosen)
        let workspace = self.workspace
        let target = targetDatabase
        run.onFinished = { [weak self] result in
            let error = result.status == .succeeded ? nil : (result.status == .cancelled ? "Cancelled" : result.message)
            workspace.recordTransfer("-- Restore of \(url.lastPathComponent) into \(target) with \((chosen.path as NSString).lastPathComponent)", duration: result.elapsed, rows: nil, error: error)
            self?.onFinished?()
        }
        run.start(runner)
    }

    var resultTitle: String {
        switch run.result?.status {
        case .succeeded: return "Restore finished"
        case .failed: return "Restore failed"
        case .cancelled: return "Restore cancelled"
        case nil: return ""
        }
    }

    var resultDetail: String {
        guard let result = run.result else { return "" }
        switch result.status {
        case .succeeded: return "\(fileURL?.lastPathComponent ?? "") into \(targetDatabase) · \(ToolRunState.clock(result.elapsed))"
        case .failed: return result.message ?? ""
        case .cancelled: return "Stopped after \(ToolRunState.clock(result.elapsed)). What was restored until then stays" + (singleTransaction || options.singleTransaction ? ", unless it ran in a single transaction." : ".")
        }
    }

    func cancel() {
        if run.isRunning {
            run.cancel()
        } else {
            inspection?.cancel()
            onClose?()
        }
    }
}

// MARK: - View

struct RestoreView: View {
    @ObservedObject var model: RestoreModel
    @ObservedObject var run: ToolRunState

    init(model: RestoreModel) {
        self.model = model
        self.run = model.run
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            if run.hasStarted {
                ToolLogView(state: run)
            } else {
                Form { settings }
                    .formStyle(.grouped)
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 56)
        }
        .frame(minWidth: 640, minHeight: 460)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Restore").font(.headline)
                Text(model.fileLine).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(model.fileURL?.path ?? "")
                    .accessibilityIdentifier("restoreFile")
                if let tool = model.toolLine {
                    Text(tool).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(model.toolPath)
                }
            }
            Spacer()
            if !run.hasStarted {
                Button(model.fileURL == nil ? "Choose File…" : "Change File…") { model.pickFile() }
            }
        }
    }

    @ViewBuilder
    private var settings: some View {
        Section("Into") {
            Picker("Database", selection: $model.targetDatabase) {
                ForEach(model.databaseChoices, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("restoreDatabase")
            Text("Create an empty database first (Database › New Database…) to restore a copy next to the original.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let problem = model.problem {
            Section {
                if model.isMissingTool {
                    MissingToolView(message: problem) { (NSApp.delegate as? AppDelegate)?.showSettings(nil) }
                } else {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        switch model.kind {
        case .postgresCustom, .postgresDirectory, .postgresTar:
            Section("pg_restore") {
                Toggle("Drop objects before creating them (clean)", isOn: $model.options.clean)
                if model.options.clean {
                    Toggle("Only if they exist (IF EXISTS)", isOn: $model.options.ifExists)
                }
                Toggle("No owner (objects belong to \(model.workspace.config.user))", isOn: $model.options.noOwner)
                Toggle("Single transaction (all or nothing)", isOn: $model.options.singleTransaction)
                if !model.options.singleTransaction, model.kind != .postgresTar {
                    Stepper("Parallel jobs: \(model.options.jobs)", value: $model.options.jobs, in: 1...16)
                }
            }
        case .plainSQL:
            Section("Run with") {
                Picker("Run with", selection: $model.scriptRunner) {
                    Text("Run SQL File (no client tool needed)").tag(RestoreModel.ScriptRunner.runSQLFile)
                    Text(model.clientName).tag(RestoreModel.ScriptRunner.client)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityIdentifier("restoreRunner")
                if model.scriptRunner == .client {
                    Toggle("Single transaction (all or nothing)", isOn: $model.singleTransaction)
                        .disabled(!model.isPostgres)
                    Text(model.isPostgres ? "psql stops at the first error." : "mysql stops at the first error.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Shows the script with its options (error handling, encoding) before it runs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let warning = model.copyWarning {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.isPostgres, model.usesCopy == nil, model.isSearching {
                    Text("Reading the script…").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let result = run.result {
            ToolResultView(state: run, result: result, title: model.resultTitle, detail: model.resultDetail) { model.onClose?() }
        } else if run.isRunning {
            ToolRunningFooter(state: run, sizeLabel: "")
        } else {
            HStack {
                if model.isSearching { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(model.tool == nil && model.kind != .unknown && model.fileURL != nil ? "Continue…" : "Restore…") { model.restoreClicked() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canRestore)
                    .accessibilityIdentifier("restoreStart")
            }
        }
    }
}

// MARK: - Controller

@MainActor
final class RestoreController: NSObject {
    static weak var presented: RestoreController?

    let model: RestoreModel
    private let window: NSWindow
    private weak var parent: NSWindow?
    private var retainSelf: RestoreController?

    init(workspace: ConnectionWorkspace, file: URL?, parent: NSWindow?, onFinished: @escaping () -> Void, openRunSQLFile: @escaping (URL, String) -> Void) {
        model = RestoreModel(workspace: workspace, file: file)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isRestorable = false
        window.setAccessibilityIdentifier("restoreSheet")
        self.parent = parent
        super.init()
        window.contentViewController = NSHostingController(rootView: RestoreView(model: model))
        window.title = "Restore"
        window.setContentSize(NSSize(width: 680, height: 500))
        model.onClose = { [weak self] in self?.dismiss() }
        model.onFinished = onFinished
        model.chooseFile = { [weak self] completion in self?.chooseFile(completion) }
        model.confirm = { [weak self] action, detail, proceed in
            guard let self else { return }
            workspace.confirmRestore(action, detail: detail, in: self.window, proceed: proceed)
        }
        model.openRunSQLFile = { [weak self] file, database in
            self?.dismiss()
            // Let this sheet finish closing before the next one attaches to the window.
            DispatchQueue.main.async { openRunSQLFile(file, database) }
        }
    }

    func present() {
        retainSelf = self
        Self.presented = self
        if let parent, parent.isVisible {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func dismiss() {
        if model.run.isRunning { model.run.cancel() }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
        retainSelf = nil
    }

    func chooseFile(_ completion: @escaping (URL?) -> Void) {
        let panel = RestoreController.openPanel()
        if window.isVisible {
            panel.beginSheetModal(for: window) { response in completion(response == .OK ? panel.url : nil) }
        } else {
            completion(panel.runModal() == .OK ? panel.url : nil)
        }
    }

    /// Files and folders (pg_dump's directory format) can be chosen.
    static func openPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsOtherFileTypes = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a backup: a pg_dump archive (.dump, .tar or a directory backup) or a .sql / .sql.gz script"
        panel.prompt = "Choose"
        return panel
    }
}

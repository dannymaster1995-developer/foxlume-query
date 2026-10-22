import AppKit
import FoxlumeQueryCore
import SwiftUI

/// What a Backup… command preselects.
enum BackupRequest {
    case database
    case schemas([String])
    case tables([TableRef])
}

/// State of the Backup sheet: scope and options, then the run.
@MainActor
final class BackupModel: ObservableObject {
    enum ScopeKind: String, CaseIterable, Identifiable {
        case database, schemas, tables
        var id: String { rawValue }
    }

    let workspace: ConnectionWorkspace
    let database: String
    @Published var scopeKind: ScopeKind
    @Published var selectedSchemas: Set<String>
    @Published var selectedTables: Set<TableRef>
    @Published var postgres: PostgresBackupOptions
    @Published var mysql: MySQLBackupOptions
    /// Nil while the tool is being looked for.
    @Published private(set) var toolSearch: BackupToolSearch?
    let run = ToolRunState()

    var onClose: (() -> Void)?
    /// Applies Safe Mode to the reads (the "Full" levels ask before every statement); calls `proceed` when allowed.
    var confirmRead: ((_ action: String, _ proceed: @escaping () -> Void) -> Void)?
    /// Asks where to save; nil means the user cancelled.
    var chooseDestination: ((_ suggested: String, _ isDirectory: Bool, _ folder: URL?, _ completion: @escaping (URL?) -> Void) -> Void)?

    init(workspace: ConnectionWorkspace, request: BackupRequest) {
        self.workspace = workspace
        database = workspace.currentDatabase ?? workspace.config.database
        let preferences = BackupPreferences.load()
        postgres = preferences.postgres
        mysql = preferences.mysql
        switch request {
        case .database:
            scopeKind = .database
            selectedSchemas = []
            selectedTables = []
        case .schemas(let schemas):
            scopeKind = schemas.isEmpty ? .database : .schemas
            selectedSchemas = Set(schemas)
            selectedTables = []
        case .tables(let tables):
            scopeKind = tables.isEmpty ? .database : .tables
            selectedSchemas = []
            selectedTables = Set(tables)
        }
        Task { await locateTool() }
    }

    var isPostgres: Bool { workspace.kind == .postgresql }
    var tool: BackupTool { isPostgres ? .pgDump : .mysqldump }

    func locateTool() async {
        toolSearch = nil
        toolSearch = await workspace.findBackupTool(tool)
    }

    /// Schemas (PostgreSQL) or databases (MySQL) that can be picked.
    var schemaChoices: [String] {
        if isPostgres {
            return workspace.schemas.filter { !DatabaseObjectSQL.isSystemSchema($0) }
        }
        return workspace.databases.filter { !workspace.kind.systemDatabases.contains($0) }
    }

    /// Tables, views and sequences of the browsed schema.
    var tableChoices: [TableInfo] {
        workspace.tables.filter { [.table, .view, .materializedView, .foreignTable].contains($0.kind) }
    }

    var scopeTitle: (database: String, schemas: String, tables: String) {
        isPostgres
            ? ("Whole database", "Selected schemas", "Selected tables")
            : ("Whole database", "Selected databases", "Selected tables")
    }

    var scope: BackupScope {
        switch scopeKind {
        case .database: return .database
        case .schemas: return .schemas(schemaChoices.filter { selectedSchemas.contains($0) })
        case .tables: return .tables(tableChoices.map(\.ref).filter { selectedTables.contains($0) })
        }
    }

    var subtitle: String {
        var parts = ["\(workspace.kind.displayName) \(workspace.serverVersion)", workspace.config.displayName]
        if workspace.config.usesSSH { parts.append("via SSH \(workspace.config.ssh?.host ?? "")") }
        return parts.joined(separator: " · ")
    }

    /// "pg_dump 17.2"; the path is in `toolPath`.
    var toolLine: String {
        guard let search = toolSearch else { return "Looking for \(tool.rawValue)…" }
        guard let chosen = search.chosen else { return "" }
        let version = chosen.version.map { " \($0)" } ?? ""
        return "\((chosen.path as NSString).lastPathComponent)\(version)" + (search.isOverride ? " (chosen in Settings)" : "")
    }

    var toolPath: String { toolSearch?.chosen?.path ?? "" }

    var missingToolMessage: String? {
        guard let search = toolSearch, search.chosen == nil else { return nil }
        if search.isOverride, let path = AppEnvironment.settings.backupToolPath(tool) {
            return "\(path), chosen in Settings › Backup Tools, cannot be run. Choose another copy or clear the setting to let Foxlume Query find one."
        }
        return search.missingError.localizedDescription
    }

    /// pg_dump older than the server, or a dump tool of the other flavor.
    var warning: String? {
        guard let chosen = toolSearch?.chosen else { return nil }
        if isPostgres {
            return BackupCompatibility.pgDumpWarning(tool: chosen.version, server: workspace.parsedServerVersion, path: chosen.path)
        }
        return BackupCompatibility.mysqlFlavorNote(tool: chosen.version, serverIsMariaDB: workspace.preferredToolFlavor == .mariadb)
    }

    var canStart: Bool {
        guard toolSearch?.chosen != nil, !run.hasStarted else { return false }
        switch scope {
        case .database: return !database.isEmpty
        case .schemas(let names): return !names.isEmpty
        case .tables(let tables): return !tables.isEmpty
        }
    }

    var fileExtension: String { isPostgres ? postgres.fileExtension : mysql.fileExtension }

    /// "shop-2026-10-21-1530.dump"; for a schema or table backup the name says which.
    var suggestedName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        var base = database.isEmpty ? workspace.config.displayName : database
        switch scope {
        case .database: break
        case .schemas(let names): base += names.count == 1 ? "-\(names[0])" : "-\(names.count)-\(isPostgres ? "schemas" : "databases")"
        case .tables(let tables): base += tables.count == 1 ? "-\(tables[0].name)" : "-\(tables.count)-tables"
        }
        let safe = base.map { "/:\\".contains($0) ? "_" : $0 }
        let name = String(safe) + "-" + formatter.string(from: Date())
        return fileExtension.isEmpty ? name : "\(name).\(fileExtension)"
    }

    func backUpClicked() {
        guard canStart else { return }
        let folder = BackupPreferences.load().lastFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let choose = { [weak self] in
            guard let self else { return }
            self.chooseDestination?(self.suggestedName, self.isPostgres && self.postgres.format.isDirectory, folder) { [weak self] url in
                guard let self, let url else { return }
                self.start(destination: url)
            }
        }
        guard let confirmRead else { return choose() }
        confirmRead("Back up \(scopeSummary)") {
            // Let the question's sheet close before the save panel opens.
            DispatchQueue.main.async { choose() }
        }
    }

    /// Starts the backup into `destination` (a file, or a folder for the directory format).
    func start(destination: URL) {
        guard let tool = toolSearch?.chosen, !run.hasStarted else { return }
        var preferences = BackupPreferences.load()
        preferences.postgres = postgres
        preferences.mysql = mysql
        preferences.lastFolder = destination.deletingLastPathComponent().path
        preferences.save()
        let job: BackupJob = isPostgres
            ? .postgresBackup(scope: scope, options: postgres, destination: destination)
            : .mysqlBackup(scope: scope, options: mysql, destination: destination)
        let runner = BackupRunner(job: job, connection: workspace.backupConnection(database: database), tool: tool)
        let workspace = self.workspace
        let summary = scopeSummary
        run.onFinished = { result in
            let error = result.status == .succeeded ? nil : (result.status == .cancelled ? "Cancelled" : result.message)
            workspace.recordTransfer("-- Backup of \(summary) to \(destination.lastPathComponent) with \((tool.path as NSString).lastPathComponent)", duration: result.elapsed, rows: nil, error: error)
        }
        run.start(runner)
    }

    var scopeSummary: String {
        switch scope {
        case .database: return database
        case .schemas(let names): return names.joined(separator: ", ")
        case .tables(let tables): return tables.count == 1 ? tables[0].name : "\(tables.count) tables"
        }
    }

    var resultTitle: String {
        switch run.result?.status {
        case .succeeded: return "Backup finished"
        case .failed: return "Backup failed"
        case .cancelled: return "Backup cancelled; the partial output was removed"
        case nil: return ""
        }
    }

    var resultDetail: String {
        guard let result = run.result else { return "" }
        switch result.status {
        case .succeeded:
            let size = result.outputSize.map { $0.byteCountText } ?? ""
            return "\(result.outputURL?.path ?? "") · \(size) · \(ToolRunState.clock(result.elapsed))"
        case .failed: return result.message ?? ""
        case .cancelled: return "Stopped after \(ToolRunState.clock(result.elapsed))."
        }
    }

    func cancel() {
        if run.isRunning {
            run.cancel()
        } else {
            onClose?()
        }
    }
}

// MARK: - View

struct BackupView: View {
    @ObservedObject var model: BackupModel
    @ObservedObject var run: ToolRunState

    init(model: BackupModel) {
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
                HStack(spacing: 0) {
                    scopePane
                        .frame(minWidth: 260, maxWidth: .infinity)
                    Divider()
                    optionsPane
                        .frame(width: 330)
                }
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 56)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Back Up \(model.database.isEmpty ? model.workspace.config.displayName : model.database)").font(.headline)
                Text(model.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(model.toolLine).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(model.toolPath)
                    .accessibilityIdentifier("backupTool")
            }
            Spacer()
        }
    }

    private var scopePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Back up", selection: $model.scopeKind) {
                Text(model.scopeTitle.database).tag(BackupModel.ScopeKind.database)
                Text(model.scopeTitle.schemas).tag(BackupModel.ScopeKind.schemas)
                Text(model.scopeTitle.tables).tag(BackupModel.ScopeKind.tables)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("backupScope")
            switch model.scopeKind {
            case .database:
                Text(model.isPostgres
                     ? "Every schema of \(model.database): tables, data, views, functions, sequences, types and extensions."
                     : "Every table of \(model.database) with its data, views and, as chosen on the right, routines, triggers and events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            case .schemas:
                checklist(model.schemaChoices, id: \.self, label: { $0 }, isOn: { model.selectedSchemas.contains($0) }) { name, on in
                    if on { model.selectedSchemas.insert(name) } else { model.selectedSchemas.remove(name) }
                }
            case .tables:
                if model.isPostgres, let schema = model.workspace.currentSchema {
                    Text("Tables of the schema \(schema)").font(.caption).foregroundStyle(.secondary)
                }
                checklist(model.tableChoices, id: \.ref, label: { $0.name }, isOn: { model.selectedTables.contains($0.ref) }) { info, on in
                    if on { model.selectedTables.insert(info.ref) } else { model.selectedTables.remove(info.ref) }
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func checklist<Item, ID: Hashable>(_ items: [Item], id: KeyPath<Item, ID>, label: @escaping (Item) -> String, isOn: @escaping (Item) -> Bool, set: @escaping (Item, Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Select All") { items.forEach { set($0, true) } }
                Button("Select None") { items.forEach { set($0, false) } }
            }
            .controlSize(.small)
            List(items, id: id) { item in
                Toggle(label(item), isOn: Binding(get: { isOn(item) }, set: { set(item, $0) }))
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    @ViewBuilder
    private var optionsPane: some View {
        Form {
            if model.isPostgres {
                postgresOptions
            } else {
                mysqlOptions
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var postgresOptions: some View {
        Section("Format") {
            Picker("Format", selection: $model.postgres.format) {
                ForEach(PostgresBackupFormat.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("backupFormat")
            switch model.postgres.format {
            case .custom, .directory:
                Picker("Compression", selection: $model.postgres.compressionLevel) {
                    Text("None").tag(0)
                    ForEach(1...9, id: \.self) { Text("Level \($0)").tag($0) }
                }
                if model.postgres.format == .directory {
                    Stepper("Parallel jobs: \(model.postgres.jobs)", value: $model.postgres.jobs, in: 1...16)
                }
                Text("Restore with Restore… (pg_restore), into this or another database.").font(.caption).foregroundStyle(.secondary)
            case .plain:
                Toggle("Compress with gzip (.sql.gz)", isOn: $model.postgres.compressPlain)
                Toggle("INSERT statements instead of COPY", isOn: $model.postgres.useInserts)
                Text(model.postgres.useInserts
                     ? "Run SQL File can restore it without psql."
                     : "COPY is faster but needs psql to restore.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Drop objects before creating them", isOn: $model.postgres.clean)
                if model.postgres.clean {
                    Toggle("Only if they exist (IF EXISTS)", isOn: $model.postgres.ifExists)
                }
            case .tar:
                Text("A tar archive of the directory format, restored with Restore… (pg_restore).").font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Content") {
            Picker("Include", selection: $model.postgres.content) {
                ForEach(BackupContent.allCases) { Text($0.title).tag($0) }
            }
            Toggle("No owner (skip ALTER … OWNER)", isOn: $model.postgres.noOwner)
            Toggle("No privileges (skip GRANT / REVOKE)", isOn: $model.postgres.noPrivileges)
        }
    }

    @ViewBuilder
    private var mysqlOptions: some View {
        Section("Content") {
            Picker("Include", selection: $model.mysql.content) {
                ForEach(BackupContent.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Routines (procedures and functions)", isOn: $model.mysql.routines)
                .disabled(model.mysql.content == .dataOnly)
            Toggle("Triggers", isOn: $model.mysql.triggers)
                .disabled(model.mysql.content == .dataOnly)
            Toggle("Events", isOn: $model.mysql.events)
                .disabled(model.mysql.content == .dataOnly)
            Toggle("DROP TABLE before each CREATE TABLE", isOn: $model.mysql.addDropTable)
                .disabled(model.mysql.content == .dataOnly)
        }
        Section("Consistency and output") {
            Toggle("Single transaction (no table locks)", isOn: $model.mysql.singleTransaction)
            Text(model.mysql.singleTransaction
                 ? "A consistent snapshot of InnoDB tables while others keep writing."
                 : "Locks each database's tables while it is read.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Compress with gzip (.sql.gz)", isOn: $model.mysql.compress)
            Text("Restore with Restore… or Run SQL File; DELIMITER blocks are understood.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let result = run.result {
            ToolResultView(state: run, result: result, title: model.resultTitle, detail: model.resultDetail) { model.onClose?() }
        } else if run.isRunning {
            ToolRunningFooter(state: run, sizeLabel: "written")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let missing = model.missingToolMessage {
                    MissingToolView(message: missing) { (NSApp.delegate as? AppDelegate)?.showSettings(nil) }
                }
                if let warning = model.warning {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("backupWarning")
                }
                HStack {
                    if model.toolSearch == nil { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel") { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                    Button("Back Up…") { model.backUpClicked() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canStart)
                        .accessibilityIdentifier("backupStart")
                }
            }
        }
    }
}

// MARK: - Controller

@MainActor
final class BackupController: NSObject {
    /// The sheet in front, for the scripted UI checks.
    static weak var presented: BackupController?

    let model: BackupModel
    private let window: NSWindow
    private weak var parent: NSWindow?
    private var retainSelf: BackupController?

    init(workspace: ConnectionWorkspace, request: BackupRequest, parent: NSWindow?) {
        model = BackupModel(workspace: workspace, request: request)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isRestorable = false
        window.setAccessibilityIdentifier("backupSheet")
        self.parent = parent
        super.init()
        window.contentViewController = NSHostingController(rootView: BackupView(model: model))
        window.title = "Backup"
        window.setContentSize(NSSize(width: 760, height: 560))
        model.onClose = { [weak self] in self?.dismiss() }
        model.confirmRead = { [weak self] action, proceed in
            guard let self else { return }
            SafeModeGate.authorize(config: workspace.config, statements: [], writes: false, action: action, confirmTitle: "Back Up", in: self.window) { allowed in
                if allowed { proceed() }
            }
        }
        model.chooseDestination = { [weak self] name, isDirectory, folder, completion in
            self?.chooseDestination(name: name, isDirectory: isDirectory, folder: folder, completion: completion)
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

    private func chooseDestination(name: String, isDirectory: Bool, folder: URL?, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let folder { panel.directoryURL = folder }
        panel.message = isDirectory
            ? "pg_dump creates a folder with this name holding the backup."
            : "Choose where to save the backup."
        panel.prompt = "Back Up"
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }
}

import AppKit
import FoxlumeQueryCore
import SwiftUI

/// State of the Export Tables sheet: which objects, how, and the running export.
@MainActor
final class ExportTablesModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let info: TableInfo
        var id: TableRef { info.ref }
        var isSelected: Bool
        var includeStructure = true
        var includeDrop = true
        var includeData = true
        var whereClause = ""
        var rowLimit = ""

        var isView: Bool { info.kind == .view || info.kind == .materializedView }
        var isFiltered: Bool {
            !whereClause.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !rowLimit.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    struct Summary: Equatable {
        var title: String
        var detail: String
        var warnings: [String]
        var files: [URL]
    }

    enum Phase: Equatable {
        case editing
        case running
        case finished(Summary)
        case failed(String)
    }

    let workspace: ConnectionWorkspace
    @Published var rows: [Row]
    @Published var options: TableExportOptions
    @Published var search = ""
    @Published var phase: Phase = .editing
    @Published var progress: TableExportProgress?
    @Published var message: String?

    var onClose: (() -> Void)?
    /// Asks for the file or folder; the controller shows the panel.
    var chooseDestination: ((_ folder: Bool, _ suggestedName: String, _ completion: @escaping (URL?) -> Void) -> Void)?

    private var cancellation: OperationCancellation?
    private var transferSession: DatabaseSession?

    init(workspace: ConnectionWorkspace, preselected: Set<TableRef>) {
        self.workspace = workspace
        let preferences = TransferPreferences.load()
        var options = preferences.export
        // Engines without SQL dumps of their own still offer the data formats.
        if !workspace.kind.isSQL, options.format == .sql { options.format = .csv }
        self.options = options
        rows = workspace.exportableObjects.map { Row(info: $0, isSelected: preselected.contains($0.ref)) }
    }

    var locationTitle: String {
        var parts: [String] = []
        if let database = workspace.currentDatabase, !database.isEmpty { parts.append(database) }
        if workspace.kind.supportsSchemas, let schema = workspace.currentSchema { parts.append(schema) }
        return parts.isEmpty ? workspace.config.displayName : parts.joined(separator: " · ")
    }

    var visibleRows: [Row] {
        let filter = search.trimmingCharacters(in: .whitespaces).lowercased()
        return filter.isEmpty ? rows : rows.filter { $0.info.name.lowercased().contains(filter) }
    }

    var selectedRows: [Row] { rows.filter(\.isSelected) }

    var isRunning: Bool { phase == .running }

    // MARK: Selection

    enum GroupState {
        case none
        case some
        case all
    }

    func groupState(views: Bool) -> GroupState {
        let members = visibleRows.filter { $0.isView == views }
        let selected = members.filter(\.isSelected).count
        if selected == 0 { return .none }
        return selected == members.count ? .all : .some
    }

    func toggleGroup(views: Bool) {
        let select = groupState(views: views) != .all
        let visible = Set(visibleRows.filter { $0.isView == views }.map(\.id))
        for index in rows.indices where visible.contains(rows[index].id) {
            setSelected(index, select)
        }
    }

    func setSelected(_ index: Int, _ selected: Bool) {
        rows[index].isSelected = selected
        // A row ticked while every SQL part is off gets the defaults back.
        if selected, !rows[index].includeStructure, !rows[index].includeDrop, !rows[index].includeData {
            rows[index].includeStructure = true
            rows[index].includeDrop = true
            rows[index].includeData = true
        }
    }

    func binding(for id: TableRef) -> Binding<Row>? {
        guard rows.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.rows.first { $0.id == id } ?? Row(info: TableInfo(ref: id), isSelected: false) },
            set: { newValue in
                guard let index = self.rows.firstIndex(where: { $0.id == id }) else { return }
                var row = newValue
                // Turning every SQL part off is the same as leaving the row out.
                if !row.includeStructure, !row.includeDrop, !row.includeData { row.isSelected = false }
                if row.isSelected, !self.rows[index].isSelected {
                    self.rows[index] = row
                    self.setSelected(index, true)
                } else {
                    self.rows[index] = row
                }
            }
        )
    }

    func select(names: [String]) {
        for index in rows.indices {
            setSelected(index, names.contains(rows[index].info.name))
        }
    }

    // MARK: Running

    var exportButtonTitle: String { "Export…" }

    var selectionSummary: String {
        let count = selectedRows.count
        var text = "\(count) of \(rows.count) selected"
        let filtered = selectedRows.filter(\.isFiltered).count
        if filtered > 0 { text += " · \(filtered) filtered" }
        return text
    }

    /// The items to export, or a message saying what is missing.
    func items() -> Result<[TableExportItem], DatabaseError> {
        let chosen = selectedRows
        guard !chosen.isEmpty else { return .failure(.unsupported("Choose at least one table or view.")) }
        var items: [TableExportItem] = []
        for row in chosen {
            let condition: String
            do {
                condition = try TableExportItem.validatedCondition(row.whereClause)
            } catch {
                return .failure(.unsupported("\(row.info.name): \(error.localizedDescription)"))
            }
            let limitText = row.rowLimit.trimmingCharacters(in: .whitespaces)
            var limit: Int?
            if !limitText.isEmpty {
                guard let value = Int(limitText), value >= 0 else {
                    return .failure(.unsupported("\(row.info.name): the row limit must be a whole number."))
                }
                limit = value
            }
            let sql = options.format == .sql
            items.append(TableExportItem(
                table: row.info.ref,
                kind: row.info.kind,
                includeStructure: !sql || row.includeStructure,
                includeDrop: sql && row.includeDrop,
                includeData: !sql || row.includeData,
                whereClause: condition,
                rowLimit: limit
            ))
        }
        return .success(items)
    }

    var suggestedFileName: String {
        let base: String
        if selectedRows.count == 1, let only = selectedRows.first {
            base = only.info.name
        } else {
            base = workspace.currentDatabase.flatMap { $0.isEmpty ? nil : $0 } ?? "export"
        }
        return base.replacingOccurrences(of: "/", with: "_") + "." + options.fileExtension()
    }

    /// Asks for the destination, then exports.
    func exportClicked() {
        message = nil
        switch items() {
        case .failure(let error):
            message = error.localizedDescription
        case .success(let items):
            let folder = options.writesFilePerTable(tableCount: items.count)
            chooseDestination?(folder, suggestedFileName) { [weak self] url in
                guard let self, let url else { return }
                self.start(items: items, destination: folder ? .directory(url) : .file(url))
            }
        }
    }

    func start(items: [TableExportItem], destination requested: TableExportDestination) {
        let options = self.options
        var destination = requested
        // A gzip file keeps a name that says so, even when the name typed in the save panel lost the suffix.
        if case .file(let url) = requested, options.format == .sql, options.compress, url.pathExtension.lowercased() != "gz" {
            destination = .file(url.appendingPathExtension("gz"))
        }
        let cancellation = OperationCancellation()
        let throttle = ProgressThrottle()
        self.cancellation = cancellation
        progress = nil
        message = nil
        phase = .running
        Task {
            var session: DatabaseSession?
            do {
                let opened = try await workspace.openTransferSession()
                session = opened
                transferSession = opened
                try cancellation.check()
                let database = workspace.currentDatabase
                let report = try await opened.run { connection in
                    try TableExporter(connection: connection, options: options, cancellation: cancellation, databaseName: database)
                        .export(items, to: destination) { progress in
                            guard throttle.shouldReport() || progress.tableRows == progress.tableTotal else { return }
                            DispatchQueue.main.async { MainActor.assumeIsolated { self.progress = progress } }
                        }
                }
                var preferences = TransferPreferences.load()
                preferences.export = options
                preferences.save()
                phase = .finished(Self.summary(report))
            } catch {
                if cancellation.isCancelled {
                    phase = .editing
                    message = "Export cancelled. No files were written."
                } else {
                    phase = .failed(error.localizedDescription)
                }
            }
            transferSession = nil
            await session?.close()
        }
    }

    static func summary(_ report: TableExportReport) -> Summary {
        let tables = report.tables.count
        let files = report.files.count
        let title = "Exported \(tables) \(tables == 1 ? "object" : "objects"), \(report.totalRows.groupedText) \(report.totalRows == 1 ? "row" : "rows")"
        var detail = files == 1 ? (report.files.first?.path ?? "") : "\(files) files in \(report.files.first?.deletingLastPathComponent().path ?? "")"
        detail += " · \(report.elapsed.durationText)"
        return Summary(title: title, detail: detail, warnings: report.warnings, files: report.files)
    }

    func cancel() {
        if isRunning {
            cancellation?.cancel()
            transferSession?.cancel()
        } else {
            onClose?()
        }
    }

    func backToOptions() {
        phase = .editing
    }

    func revealFiles() {
        guard case .finished(let summary) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting(summary.files)
    }

    /// Text for the progress line: the table, its position and its rows.
    var progressText: String {
        guard let progress else { return "Preparing…" }
        var text = "Exporting \(progress.table.name) (\(progress.tableIndex + 1) of \(progress.tableCount))"
        if let total = progress.tableTotal {
            text += " · \(progress.tableRows.groupedText) of \(total.groupedText) rows"
        } else {
            text += " · \(progress.tableRows.groupedText) rows"
        }
        return text
    }

    var progressFraction: Double? {
        guard let progress, let total = progress.grandTotal, total > 0 else { return nil }
        return min(1, Double(progress.totalRows) / Double(total))
    }
}

// MARK: - View

struct ExportTablesView: View {
    @ObservedObject var model: ExportTablesModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                ExportObjectList(model: model)
                    .frame(minWidth: 380, maxWidth: .infinity)
                Divider()
                ExportOptionsPanel(model: model)
                    .frame(width: 300)
            }
            .disabled(model.isRunning)
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Export Tables").font(.headline)
                Text(model.locationTitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            switch model.phase {
            case .editing:
                if let message = model.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else {
                    Text(model.selectionSummary).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(model.exportButtonTitle) { model.exportClicked() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedRows.isEmpty)
                    .accessibilityIdentifier("exportStart")
            case .running:
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction = model.progressFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(model.progressText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Button("Stop") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            case .finished(let summary):
                Image(systemName: summary.warnings.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.warnings.isEmpty ? Color.green : Color.orange)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title).font(.callout.weight(.semibold))
                    Text(summary.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    ForEach(summary.warnings.prefix(3), id: \.self) { warning in
                        Text(warning).font(.caption).foregroundStyle(.orange).lineLimit(1)
                    }
                }
                Spacer()
                Button("Show in Finder") { model.revealFiles() }
                Button("Done") { model.onClose?() }
                    .keyboardShortcut(.defaultAction)
            case .failed(let error):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.title2)
                Text(error).font(.callout).lineLimit(3).textSelection(.enabled)
                Spacer()
                Button("Back") { model.backToOptions() }
                Button("Close") { model.onClose?() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
    }
}

/// The objects to export, grouped into tables and views, with per-row SQL parts and row filters.
private struct ExportObjectList: View {
    @ObservedObject var model: ExportTablesModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                if model.options.format == .sql {
                    HStack(spacing: 0) {
                        Text("Structure").frame(width: 62)
                        Text("Drop").frame(width: 40)
                        Text("Data").frame(width: 40)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 34)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            List {
                group(views: false)
                group(views: true)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func group(views: Bool) -> some View {
        let members = model.visibleRows.filter { $0.isView == views }
        if !members.isEmpty {
            Section {
                ForEach(members) { row in
                    if let binding = model.binding(for: row.id) {
                        ExportObjectRow(row: binding, format: model.options.format)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Button {
                        model.toggleGroup(views: views)
                    } label: {
                        Image(systemName: groupSymbol(model.groupState(views: views)))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Select all or none")
                    Text(views ? "Views" : model.workspace.capabilities.objectNounPlural.capitalized)
                    Text("\(members.count)").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func groupSymbol(_ state: ExportTablesModel.GroupState) -> String {
        switch state {
        case .none: return "square"
        case .some: return "minus.square.fill"
        case .all: return "checkmark.square.fill"
        }
    }
}

private struct ExportObjectRow: View {
    @Binding var row: ExportTablesModel.Row
    let format: TableExportFormat
    @State private var showsFilter = false

    var body: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $row.isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: Theme.symbol(for: row.info.kind))
                .foregroundStyle(row.isView ? Color.purple : Color.accentColor)
                .frame(width: 16)
            Text(row.info.name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if let rows = row.info.estimatedRows, !row.isView {
                Text("≈ \(rows.groupedText)").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if format == .sql {
                Toggle("", isOn: $row.includeStructure).toggleStyle(.checkbox).labelsHidden().frame(width: 62)
                Toggle("", isOn: $row.includeDrop).toggleStyle(.checkbox).labelsHidden().frame(width: 40)
                if row.isView {
                    // Views have no rows of their own in a SQL dump.
                    Text("–").foregroundStyle(.tertiary).frame(width: 40)
                } else {
                    Toggle("", isOn: $row.includeData).toggleStyle(.checkbox).labelsHidden().frame(width: 40)
                }
            }
            Button {
                showsFilter.toggle()
            } label: {
                Image(systemName: row.isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(row.isFiltered ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(row.isFiltered ? "Rows are filtered" : "Filter rows")
            .popover(isPresented: $showsFilter, arrowEdge: .trailing) {
                ExportRowFilterEditor(row: $row, isPresented: $showsFilter)
            }
        }
        .padding(.vertical, 1)
    }
}

/// WHERE condition and row limit for one table.
private struct ExportRowFilterEditor: View {
    @Binding var row: ExportTablesModel.Row
    @Binding var isPresented: Bool
    @State private var condition = ""
    @State private var limit = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rows of \(row.info.name)").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("WHERE").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. created_at >= '2026-01-01'", text: $condition, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Row limit").font(.caption).foregroundStyle(.secondary)
                TextField("All rows", text: $limit)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Clear") {
                    condition = ""
                    limit = ""
                    error = nil
                }
                Spacer()
                Button("Done") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            condition = row.whereClause
            limit = row.rowLimit
        }
    }

    private func apply() {
        do {
            let cleaned = try TableExportItem.validatedCondition(condition)
            let trimmedLimit = limit.trimmingCharacters(in: .whitespaces)
            guard trimmedLimit.isEmpty || (Int(trimmedLimit).map { $0 >= 0 } ?? false) else {
                error = "The row limit must be a whole number."
                return
            }
            row.whereClause = cleaned
            row.rowLimit = trimmedLimit
            if row.isFiltered { row.isSelected = true }
            isPresented = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Format and its options.
private struct ExportOptionsPanel: View {
    @ObservedObject var model: ExportTablesModel

    private var formats: [TableExportFormat] {
        model.workspace.kind.isSQL ? TableExportFormat.allCases : TableExportFormat.allCases.filter { $0 != .sql }
    }

    var body: some View {
        Form {
            Section {
                Picker("Format", selection: $model.options.format) {
                    ForEach(formats) { format in
                        Text(format.title).tag(format)
                    }
                }
                .accessibilityIdentifier("exportFormat")
                Text(model.options.format.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch model.options.format {
            case .sql: sqlOptions
            case .csv: csvOptions
            case .json: jsonOptions
            case .ndjson: EmptyView()
            }
            Section("Output") {
                if model.options.format.supportsCombinedFile {
                    Picker("Files", selection: $model.options.filePerTable) {
                        Text("One file").tag(false)
                        Text("One file per table").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                } else {
                    Text("Each table is written to its own file.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Reset to Defaults") {
                    let format = model.options.format
                    model.options = TableExportOptions()
                    model.options.format = format
                }
            }
        }
        .formStyle(.grouped)
    }

    private var sqlOptions: some View {
        Section("SQL") {
            Picker("Rows per INSERT", selection: $model.options.rowsPerInsert) {
                Text("1").tag(1)
                Text("100").tag(100)
                Text("500").tag(500)
                Text("1000").tag(1000)
            }
            Toggle("Compress (gzip)", isOn: $model.options.compress)
            if model.workspace.kind.usesMySQLProtocol {
                Toggle("Leave out AUTO_INCREMENT counters", isOn: $model.options.stripAutoIncrement)
                Toggle("Leave out DEFINER clauses", isOn: $model.options.stripDefiner)
            }
        }
    }

    private var csvOptions: some View {
        Section("CSV") {
            Picker("Delimiter", selection: $model.options.csvDelimiter) {
                ForEach(CSVDelimiter.allCases) { Text($0.title).tag($0) }
            }
            Picker("Quote", selection: $model.options.csvQuoting) {
                ForEach(CSVQuoting.allCases) { Text($0.title).tag($0) }
            }
            Picker("Line endings", selection: $model.options.csvLineEnding) {
                ForEach(CSVLineEnding.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Column names in first row", isOn: $model.options.csvHeader)
            Toggle("Write NULL as an empty field", isOn: $model.options.csvNullAsEmpty)
            Toggle("Replace line breaks with spaces", isOn: $model.options.csvLineBreaksAsSpaces)
            Toggle("Protect against spreadsheet formulas", isOn: $model.options.csvProtectFormulas)
            Toggle("Start with a byte order mark", isOn: $model.options.csvByteOrderMark)
        }
    }

    private var jsonOptions: some View {
        Section("JSON") {
            Toggle("Pretty print", isOn: $model.options.jsonPrettyPrint)
            Toggle("Include NULL values", isOn: $model.options.jsonIncludeNulls)
        }
    }
}

// MARK: - Controller

/// Hosts the export sheet on a workspace window.
@MainActor
final class ExportTablesController: NSObject, NSWindowDelegate {
    let model: ExportTablesModel
    private let window: NSWindow
    private weak var parent: NSWindow?
    private var retainSelf: ExportTablesController?

    init(workspace: ConnectionWorkspace, preselected: Set<TableRef>, parent: NSWindow?) {
        model = ExportTablesModel(workspace: workspace, preselected: preselected)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Export Tables"
        window.isRestorable = false
        window.setAccessibilityIdentifier("exportTablesSheet")
        self.parent = parent
        super.init()
        window.contentViewController = NSHostingController(rootView: ExportTablesView(model: model))
        window.setContentSize(NSSize(width: 820, height: 580))
        model.onClose = { [weak self] in self?.dismiss() }
        model.chooseDestination = { [weak self] folder, name, completion in
            self?.chooseDestination(folder: folder, suggestedName: name, completion: completion)
        }
    }

    func present() {
        retainSelf = self
        TransferSheets.exportSheet = self
        if let parent, parent.isVisible {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func dismiss() {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
        retainSelf = nil
    }

    private func chooseDestination(folder: Bool, suggestedName: String, completion: @escaping (URL?) -> Void) {
        let panel: NSSavePanel
        if folder {
            let open = NSOpenPanel()
            open.canChooseDirectories = true
            open.canChooseFiles = false
            open.canCreateDirectories = true
            open.prompt = "Export Here"
            open.message = "Choose a folder. Each table is written to its own file; files with the same names are replaced."
            panel = open
        } else {
            panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedName
            panel.canCreateDirectories = true
            panel.prompt = "Export"
        }
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }
}

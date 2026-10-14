import AppKit
import FoxlumeQueryCore
import SwiftUI
import UniformTypeIdentifiers

/// State of the Import CSV sheet: file, target table, preview, mapping, options and the running import.
@MainActor
final class ImportCSVModel: ObservableObject {
    struct Source: Identifiable, Equatable {
        let index: Int
        var name: String
        var sample: String
        /// The target column, or nil to skip the field.
        var column: String?
        var id: Int { index }
    }

    struct Summary: Equatable {
        var title: String
        var detail: String
        var isClean: Bool
        var issues: [ImportIssue]
    }

    enum Phase: Equatable {
        case editing
        case running
        case finished(Summary)
        case failed(String)
    }

    static let previewLimit = 20

    let workspace: ConnectionWorkspace
    @Published var fileURL: URL?
    @Published var fileSize: Int64 = 0
    @Published var table: TableRef?
    @Published var options: CSVImportOptions
    @Published private(set) var previewRecords: [[String]] = []
    @Published private(set) var detectedDelimiter: CSVDelimiter = .comma
    @Published private(set) var detectedEncoding: ImportTextEncoding = .utf8
    @Published private(set) var previewError: String?
    @Published var sources: [Source] = []
    @Published private(set) var columns: [ColumnInfo] = []
    @Published var phase: Phase = .editing
    @Published var progress: CSVImportProgress?
    @Published var message: String?

    var onClose: (() -> Void)?
    var chooseFile: ((_ completion: @escaping (URL?) -> Void) -> Void)?
    var confirm: ((_ proceed: @escaping () -> Void) -> Void)?
    var onImported: ((TableRef) -> Void)?

    private var cancellation: OperationCancellation?
    private var transferSession: DatabaseSession?
    private var previewTask: Task<Void, Never>?

    init(workspace: ConnectionWorkspace, table: TableRef?, file: URL?) {
        self.workspace = workspace
        options = TransferPreferences.load().csvImport
        self.table = table ?? workspace.importableTables.first?.ref
        if let file { setFile(file) }
        loadColumns()
    }

    var tables: [TableInfo] { workspace.importableTables }

    var isRunning: Bool { phase == .running }

    /// Columns a field can go into: generated columns compute their own values.
    var insertableColumns: [ColumnInfo] {
        let family = workspace.dialect.family
        return columns.filter { !TableExporter.isGenerated($0, family: family) }
    }

    var mapping: [CSVColumnMapping] {
        sources.compactMap { source in source.column.map { CSVColumnMapping(sourceIndex: source.index, column: $0) } }
    }

    var mappingProblem: String? {
        guard fileURL != nil else { return "Choose a CSV file." }
        guard table != nil else { return "Choose the table to import into." }
        if let previewError { return previewError }
        return CSVImportMapping.problem(with: mapping, columns: columns)
    }

    var rowsInPreview: [[String]] {
        options.hasHeaderRow ? Array(previewRecords.dropFirst()) : previewRecords
    }

    // MARK: File and table

    func pickFile() {
        chooseFile? { [weak self] url in
            if let url { self?.setFile(url) }
        }
    }

    func setFile(_ url: URL) {
        fileURL = url
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        phase = .editing
        reloadPreview()
    }

    func setTable(_ ref: TableRef?) {
        table = ref
        loadColumns()
    }

    private func loadColumns() {
        guard let table else {
            columns = []
            return
        }
        Task {
            do {
                let structure = try await workspace.structure(of: table)
                guard self.table == table else { return }
                columns = structure.columns
                autoMap(byName: options.hasHeaderRow)
            } catch {
                message = "Could not read the columns of \(table.name): \(error.localizedDescription)"
            }
        }
    }

    /// Reads the first records again after the file or a reading option changed.
    func reloadPreview() {
        guard let url = fileURL else { return }
        let delimiter = options.delimiter
        let encoding = options.encoding
        let limit = Self.previewLimit + 1
        previewTask?.cancel()
        previewTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try CSVReader.preview(url: url, delimiter: delimiter, encoding: encoding, limit: limit) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let preview):
                previewRecords = preview.records.map(\.texts)
                detectedDelimiter = preview.delimiter
                detectedEncoding = preview.encoding
                previewError = preview.records.isEmpty ? "The file has no rows." : nil
            case .failure(let error):
                previewRecords = []
                previewError = error.localizedDescription
            }
            rebuildSources()
        }
    }

    /// Field names and samples from the preview, keeping the chosen columns where the field still exists.
    func rebuildSources() {
        let width = previewRecords.map(\.count).max() ?? 0
        let names = options.hasHeaderRow
            ? CSVImportMapping.headerNames((previewRecords.first ?? []) + Array(repeating: "", count: max(0, width - (previewRecords.first?.count ?? 0))))
            : CSVImportMapping.positionalNames(count: width)
        let samples = rowsInPreview
        let previous = Dictionary(uniqueKeysWithValues: sources.map { ($0.name, $0.column) })
        sources = names.enumerated().map { index, name in
            let sample = samples.first { index < $0.count && !$0.isEmpty }.map { $0[index] } ?? ""
            return Source(index: index, name: name, sample: sample, column: previous[name] ?? nil)
        }
        if previous.isEmpty || !sources.contains(where: { $0.column != nil }) {
            autoMap(byName: options.hasHeaderRow)
        }
    }

    func autoMap(byName: Bool) {
        let names = insertableColumns.map(\.name)
        let mapping = byName
            ? CSVImportMapping.byName(sources: sources.map(\.name), columns: names)
            : CSVImportMapping.byPosition(sourceCount: sources.count, columns: names)
        for index in sources.indices {
            sources[index].column = mapping.first { $0.sourceIndex == sources[index].index }?.column
        }
    }

    func setColumn(_ column: String?, for sourceIndex: Int) {
        guard let position = sources.firstIndex(where: { $0.index == sourceIndex }) else { return }
        // A column takes one field; choosing it here frees it elsewhere.
        if let column {
            for other in sources.indices where other != position && sources[other].column == column {
                sources[other].column = nil
            }
        }
        sources[position].column = column
    }

    // MARK: Running

    func importClicked() {
        message = nil
        if let problem = mappingProblem {
            message = problem
            return
        }
        confirm? { [weak self] in self?.start() }
    }

    var confirmationText: (message: String, detail: String) {
        let name = table?.name ?? ""
        var detail = "Rows from \(fileURL?.lastPathComponent ?? "the file") will be inserted into \(name)."
        if options.deleteExistingRows { detail += " Every existing row of \(name) is deleted first." }
        return ("Import into \(name)", detail)
    }

    func start() {
        guard let url = fileURL, let table else { return }
        let options = self.options
        let mapping = self.mapping
        let cancellation = OperationCancellation()
        let throttle = ProgressThrottle()
        self.cancellation = cancellation
        progress = nil
        message = nil
        phase = .running
        let started = Date()
        Task {
            var session: DatabaseSession?
            do {
                let opened = try await workspace.openTransferSession()
                session = opened
                transferSession = opened
                try cancellation.check()
                let report = try await opened.run { connection in
                    let structure = try connection.structure(of: table)
                    return try CSVImporter(connection: connection, table: table, structure: structure, mapping: mapping, options: options, cancellation: cancellation)
                        .run(file: url) { progress in
                            guard throttle.shouldReport() else { return }
                            DispatchQueue.main.async { MainActor.assumeIsolated { self.progress = progress } }
                        }
                }
                var preferences = TransferPreferences.load()
                preferences.csvImport = options
                preferences.save()
                phase = .finished(Self.summary(report, table: table, file: url))
                workspace.recordTransfer(
                    "-- Imported \(report.rowsImported) rows from \(url.lastPathComponent) into \(workspace.dialect.qualifiedName(table))",
                    duration: Date().timeIntervalSince(started),
                    rows: report.rowsImported,
                    error: report.failure?.message
                )
                if report.rowsImported > 0 || options.deleteExistingRows { onImported?(table) }
            } catch {
                phase = cancellation.isCancelled ? .editing : .failed(error.localizedDescription)
                if cancellation.isCancelled { message = "Import cancelled." }
            }
            transferSession = nil
            await session?.close()
        }
    }

    static func summary(_ report: CSVImportReport, table: TableRef, file: URL) -> Summary {
        var issues = report.issues
        if let failure = report.failure { issues.insert(failure, at: 0) }
        let title: String
        var detail: String
        if report.cancelled {
            title = report.rolledBack ? "Import cancelled; nothing was imported" : "Import cancelled after \(report.rowsImported.groupedText) rows"
            detail = ""
        } else if let failure = report.failure {
            title = report.rolledBack ? "Import failed at line \(failure.line); nothing was imported" : "Import stopped at line \(failure.line) after \(report.rowsImported.groupedText) rows"
            detail = failure.message
        } else {
            title = "Imported \(report.rowsImported.groupedText) \(report.rowsImported == 1 ? "row" : "rows") into \(table.name)"
            detail = report.rowsSkipped > 0 ? "\(report.rowsSkipped.groupedText) \(report.rowsSkipped == 1 ? "row" : "rows") skipped" : "No errors"
        }
        detail += (detail.isEmpty ? "" : " · ") + report.elapsed.durationText
        return Summary(title: title, detail: detail, isClean: report.failure == nil && report.rowsSkipped == 0 && !report.cancelled, issues: issues)
    }

    func cancel() {
        if isRunning {
            cancellation?.cancel()
            transferSession?.cancel()
        } else {
            onClose?()
        }
    }

    func copyIssues() {
        guard case .finished(let summary) = phase else { return }
        let text = summary.issues.map { "Line \($0.line): \($0.message)\n  \($0.snippet)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var progressText: String {
        guard let progress else { return "Preparing…" }
        var text = "\(progress.rowsImported.groupedText) rows imported"
        if progress.rowsSkipped > 0 { text += ", \(progress.rowsSkipped.groupedText) skipped" }
        if progress.totalBytes > 0 { text += " · \(progress.bytesRead.byteCountText) of \(progress.totalBytes.byteCountText)" }
        return text
    }

    var progressFraction: Double? {
        guard let progress, progress.totalBytes > 0 else { return nil }
        return min(1, Double(progress.bytesRead) / Double(progress.totalBytes))
    }
}

// MARK: - View

struct ImportCSVView: View {
    @ObservedObject var model: ImportCSVModel

    var body: some View {
        VStack(spacing: 0) {
            ImportCSVHeader(model: model)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .disabled(model.isRunning)
            Divider()
            ImportCSVPreview(model: model)
                .frame(height: 150)
            Divider()
            HStack(spacing: 0) {
                ImportCSVMappingList(model: model)
                    .frame(minWidth: 380, maxWidth: .infinity)
                Divider()
                ImportCSVOptions(model: model)
                    .frame(width: 300)
            }
            .disabled(model.isRunning)
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 620)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            switch model.phase {
            case .editing:
                if let message = model.message ?? model.mappingProblem {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else {
                    Text("\(model.mapping.count) of \(model.sources.count) fields mapped").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { model.importClicked() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.mappingProblem != nil)
                    .accessibilityIdentifier("importStart")
            case .running:
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction = model.progressFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(model.progressText).font(.caption).foregroundStyle(.secondary)
                }
                Button("Stop") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            case .finished(let summary):
                TransferResultView(title: summary.title, detail: summary.detail, isClean: summary.isClean, issues: summary.issues)
                Spacer()
                if !summary.issues.isEmpty {
                    Button("Copy Errors") { model.copyIssues() }
                }
                Button("Done") { model.onClose?() }
                    .keyboardShortcut(.defaultAction)
            case .failed(let error):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.title2)
                Text(error).font(.callout).lineLimit(3).textSelection(.enabled)
                Spacer()
                Button("Back") { model.phase = .editing }
                Button("Close") { model.onClose?() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
    }
}

/// Outcome line plus the first errors, shared by the CSV and SQL file sheets.
struct TransferResultView: View {
    let title: String
    let detail: String
    let isClean: Bool
    let issues: [ImportIssue]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isClean ? Color.green : Color.orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                if !issues.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(issues.prefix(200).enumerated()), id: \.offset) { _, issue in
                                Text("Line \(issue.line): \(issue.message)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .help(issue.snippet)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 64)
                }
            }
        }
    }
}

private struct ImportCSVHeader: View {
    @ObservedObject var model: ImportCSVModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import CSV into Table").font(.headline)
                if let url = model.fileURL {
                    Text("\(url.lastPathComponent) · \(model.fileSize.byteCountText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(url.path)
                } else {
                    Text("No file chosen").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(model.fileURL == nil ? "Choose File…" : "Change File…") { model.pickFile() }
            Spacer()
            Picker("Into table", selection: Binding(get: { model.table }, set: { model.setTable($0) })) {
                ForEach(model.tables) { info in
                    Text(info.name).tag(Optional(info.ref))
                }
            }
            .frame(maxWidth: 280)
            .accessibilityIdentifier("importTable")
        }
    }
}

/// The first rows as they will be read with the current options.
private struct ImportCSVPreview: View {
    @ObservedObject var model: ImportCSVModel

    var body: some View {
        if let error = model.previewError {
            Text(error)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.previewRecords.isEmpty {
            Text(model.fileURL == nil ? "Choose a CSV file to see its first rows." : "Reading…")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(model.sources) { source in
                            cell(source.name, header: true)
                        }
                    }
                    ForEach(Array(model.rowsInPreview.enumerated()), id: \.offset) { _, record in
                        GridRow {
                            ForEach(model.sources) { source in
                                cell(source.index < record.count ? record[source.index] : "", header: false)
                            }
                        }
                    }
                }
                .padding(8)
                // Small previews sit in the top left corner instead of the middle of the scroll view.
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func cell(_ text: String, header: Bool) -> some View {
        Text(text.isEmpty ? " " : String(text.replacingOccurrences(of: "\n", with: "⏎").prefix(60)))
            .font(header ? .caption.weight(.semibold) : .caption.monospaced())
            .lineLimit(1)
            .frame(width: 120, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(header ? Color.secondary.opacity(0.12) : Color.clear)
            .border(Color.secondary.opacity(0.15), width: 0.5)
    }
}

private struct ImportCSVMappingList: View {
    @ObservedObject var model: ImportCSVModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Columns").font(.subheadline.weight(.semibold))
                Spacer()
                Menu("Match Columns") {
                    Button("By Name") { model.autoMap(byName: true) }
                    Button("By Position") { model.autoMap(byName: false) }
                    Button("Skip All") {
                        for source in model.sources { model.setColumn(nil, for: source.index) }
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            List(model.sources) { source in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.name).lineLimit(1)
                        Text(source.sample.isEmpty ? "empty" : String(source.sample.prefix(80)))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Picker("", selection: Binding(get: { source.column }, set: { model.setColumn($0, for: source.index) })) {
                        Text("Skip").tag(String?.none)
                        Divider()
                        ForEach(model.insertableColumns, id: \.name) { column in
                            Text("\(column.name)  \(column.dataType)").tag(Optional(column.name))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct ImportCSVOptions: View {
    @ObservedObject var model: ImportCSVModel

    var body: some View {
        Form {
            Section("Reading") {
                Picker("Encoding", selection: Binding(get: { model.options.encoding }, set: { model.options.encoding = $0; model.reloadPreview() })) {
                    ForEach(ImportTextEncoding.allCases) { encoding in
                        Text(encoding == .automatic ? "Automatic (\(model.detectedEncoding.title))" : encoding.title).tag(encoding)
                    }
                }
                Picker("Delimiter", selection: Binding(get: { model.options.delimiter }, set: { model.options.delimiter = $0; model.reloadPreview() })) {
                    Text("Automatic (\(model.detectedDelimiter.title))").tag(CSVDelimiter?.none)
                    ForEach(CSVDelimiter.allCases) { Text($0.title).tag(Optional($0)) }
                }
                Toggle("First row has column names", isOn: Binding(get: { model.options.hasHeaderRow }, set: {
                    model.options.hasHeaderRow = $0
                    model.rebuildSources()
                    model.autoMap(byName: $0)
                }))
            }
            Section("Values") {
                Toggle("Trim spaces", isOn: $model.options.trimWhitespace)
                Toggle("Empty values become NULL", isOn: $model.options.emptyAsNull)
                TextField("NULL text", text: $model.options.nullToken, prompt: Text("e.g. \\N"))
            }
            Section("Writing") {
                Picker("On error", selection: $model.options.errorPolicy) {
                    ForEach(ImportErrorPolicy.allCases) { Text($0.title).tag($0) }
                }
                Text(policyNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Delete existing rows first", isOn: $model.options.deleteExistingRows)
            }
        }
        .formStyle(.grouped)
    }

    private var policyNote: String {
        switch model.options.errorPolicy {
        case .stopAndRollBack: return "Runs in one transaction: a bad row undoes the whole import."
        case .stopAndKeep: return "Rows before the bad one stay imported."
        case .skipAndContinue: return "Bad rows are left out and listed at the end."
        }
    }
}

// MARK: - Controller

@MainActor
final class ImportCSVController: NSObject {
    let model: ImportCSVModel
    private let window: NSWindow
    private weak var parent: NSWindow?
    private var retainSelf: ImportCSVController?

    init(workspace: ConnectionWorkspace, table: TableRef?, file: URL?, parent: NSWindow?, onImported: @escaping (TableRef) -> Void) {
        model = ImportCSVModel(workspace: workspace, table: table, file: file)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 660), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Import CSV"
        window.isRestorable = false
        window.setAccessibilityIdentifier("importCSVSheet")
        self.parent = parent
        super.init()
        window.contentViewController = NSHostingController(rootView: ImportCSVView(model: model))
        window.setContentSize(NSSize(width: 860, height: 660))
        model.onClose = { [weak self] in self?.dismiss() }
        model.onImported = onImported
        model.chooseFile = { [weak self] completion in self?.chooseFile(completion) }
        model.confirm = { [weak self] proceed in
            guard let self else { return }
            let text = self.model.confirmationText
            workspace.confirmImport(text.message, detail: text.detail, in: self.window, proceed: proceed)
        }
    }

    func present() {
        retainSelf = self
        TransferSheets.importSheet = self
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

    func chooseFile(_ completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText, UTType(filenameExtension: "tsv") ?? .plainText]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a CSV or TSV file"
        if let parent = window.isVisible ? window : parent {
            panel.beginSheetModal(for: parent) { response in completion(response == .OK ? panel.url : nil) }
        } else {
            completion(panel.runModal() == .OK ? panel.url : nil)
        }
    }
}

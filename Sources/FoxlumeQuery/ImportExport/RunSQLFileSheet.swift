import AppKit
import FoxlumeQueryCore
import SwiftUI
import UniformTypeIdentifiers

/// State of the Run SQL File sheet.
@MainActor
final class RunSQLFileModel: ObservableObject {
    enum Phase: Equatable {
        case editing
        case running
        case finished(title: String, detail: String, isClean: Bool, issues: [ImportIssue])
        case failed(String)
    }

    let workspace: ConnectionWorkspace
    @Published var fileURL: URL?
    @Published var fileSize: Int64 = 0
    @Published var options: SQLFileRunOptions
    @Published private(set) var previewText = ""
    @Published private(set) var detectedEncoding: ImportTextEncoding = .utf8
    @Published private(set) var isCompressed = false
    @Published private(set) var statementCount: Int?
    @Published private(set) var countError: String?
    @Published var phase: Phase = .editing
    @Published var progress: SQLFileProgress?
    @Published var message: String?

    var onClose: (() -> Void)?
    var chooseFile: ((_ completion: @escaping (URL?) -> Void) -> Void)?
    var confirm: ((_ proceed: @escaping () -> Void) -> Void)?
    var onFinished: (() -> Void)?

    private var cancellation: OperationCancellation?
    private var countCancellation: OperationCancellation?
    private var transferSession: DatabaseSession?

    init(workspace: ConnectionWorkspace, file: URL?) {
        self.workspace = workspace
        options = TransferPreferences.load().sqlFile
        if let file { setFile(file) }
    }

    var isRunning: Bool { phase == .running }

    /// Engines with a session switch for foreign key checks.
    var offersForeignKeyToggle: Bool {
        workspace.kind.usesMySQLProtocol || workspace.kind == .sqlite
    }

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
        reload()
    }

    /// Reads the preview and counts statements in the background.
    func reload() {
        guard let url = fileURL else { return }
        let encoding = options.encoding
        let family = workspace.dialect.family
        countCancellation?.cancel()
        let counting = OperationCancellation()
        countCancellation = counting
        statementCount = nil
        countError = nil
        Task {
            let preview = await Task.detached(priority: .userInitiated) {
                Result { try SQLFileRunner.preview(of: url, encoding: encoding) }
            }.value
            switch preview {
            case .success(let value):
                previewText = Self.firstLines(value.text, count: 300)
                detectedEncoding = value.encoding
                isCompressed = value.isCompressed
            case .failure(let error):
                previewText = ""
                countError = error.localizedDescription
                return
            }
            let counted = await Task.detached(priority: .utility) {
                Result { try SQLFileRunner.countStatements(in: url, family: family, encoding: encoding, cancellation: counting) }
            }.value
            guard !counting.isCancelled else { return }
            switch counted {
            case .success(let count): statementCount = count
            case .failure(let error): countError = error.localizedDescription
            }
        }
    }

    static func firstLines(_ text: String, count: Int) -> String {
        var lines = 0
        var end = text.startIndex
        while end < text.endIndex, lines < count {
            if text[end] == "\n" { lines += 1 }
            end = text.index(after: end)
        }
        return String(text[..<end])
    }

    var countText: String {
        if let countError { return countError }
        guard let statementCount else { return fileURL == nil ? "" : "Counting statements…" }
        return "\(statementCount.groupedText) \(statementCount == 1 ? "statement" : "statements")"
    }

    // MARK: Running

    func runClicked() {
        message = nil
        guard fileURL != nil else {
            message = "Choose a SQL file."
            return
        }
        confirm? { [weak self] in self?.start() }
    }

    var confirmationText: (message: String, detail: String) {
        ("Run \(fileURL?.lastPathComponent ?? "this file")",
         "Every statement in the file runs against \(workspace.currentDatabase ?? workspace.config.displayName).")
    }

    func start() {
        guard let url = fileURL else { return }
        var options = self.options
        if !offersForeignKeyToggle { options.disableForeignKeyChecks = false }
        let cancellation = OperationCancellation()
        let throttle = ProgressThrottle()
        self.cancellation = cancellation
        countCancellation?.cancel()
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
                    try SQLFileRunner(connection: connection, options: options, cancellation: cancellation).run(file: url) { progress in
                        guard throttle.shouldReport() else { return }
                        DispatchQueue.main.async { MainActor.assumeIsolated { self.progress = progress } }
                    }
                }
                var preferences = TransferPreferences.load()
                preferences.sqlFile = self.options
                preferences.save()
                phase = Self.finishedPhase(report)
                workspace.recordTransfer(
                    "-- Ran \(report.statementsRun) statements from \(url.lastPathComponent)",
                    duration: Date().timeIntervalSince(started),
                    rows: report.affectedRows,
                    error: report.failure?.message
                )
            } catch {
                phase = cancellation.isCancelled ? .editing : .failed(error.localizedDescription)
                if cancellation.isCancelled { message = "Stopped." }
            }
            transferSession = nil
            await session?.close()
            onFinished?()
        }
    }

    static func finishedPhase(_ report: SQLFileReport) -> Phase {
        var issues = report.issues
        if let failure = report.failure { issues.insert(failure, at: 0) }
        let title: String
        var detail = ""
        if report.cancelled {
            title = report.rolledBack ? "Stopped; every change was rolled back" : "Stopped after \(report.statementsRun.groupedText) statements"
        } else if let failure = report.failure {
            title = report.rolledBack ? "Failed at line \(failure.line); every change was rolled back" : "Stopped at line \(failure.line) after \(report.statementsRun.groupedText) statements"
            detail = failure.message
        } else {
            title = "\(report.statementsRun.groupedText) statements executed" + (report.statementsFailed > 0 ? ", \(report.statementsFailed.groupedText) failed" : "")
        }
        detail += (detail.isEmpty ? "" : " · ") + report.elapsed.durationText
        let clean = report.failure == nil && report.statementsFailed == 0 && !report.cancelled
        return .finished(title: title, detail: detail, isClean: clean, issues: issues)
    }

    func cancel() {
        if isRunning {
            cancellation?.cancel()
            transferSession?.cancel()
        } else {
            countCancellation?.cancel()
            onClose?()
        }
    }

    func copyIssues() {
        guard case .finished(_, _, _, let issues) = phase else { return }
        let text = issues.map { "Line \($0.line): \($0.message)\n  \($0.snippet)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var progressText: String {
        guard let progress else { return "Preparing…" }
        var text = "\(progress.statementsRun.groupedText)"
        if let total = statementCount { text += " of \(total.groupedText)" }
        text += " statements"
        if progress.statementsFailed > 0 { text += ", \(progress.statementsFailed.groupedText) failed" }
        return text
    }

    var progressFraction: Double? {
        guard let progress else { return nil }
        if let total = statementCount, total > 0 {
            return min(1, Double(progress.statementsRun + progress.statementsFailed) / Double(total))
        }
        guard progress.totalBytes > 0 else { return nil }
        return min(1, Double(progress.bytesRead) / Double(progress.totalBytes))
    }
}

// MARK: - View

struct RunSQLFileView: View {
    @ObservedObject var model: RunSQLFileModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .disabled(model.isRunning)
            Divider()
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    ScrollView([.vertical, .horizontal]) {
                        Text(model.previewText.isEmpty ? " " : model.previewText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .frame(minWidth: 360, maxWidth: .infinity)
                Divider()
                options
                    .frame(width: 290)
                    .disabled(model.isRunning)
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Run SQL File").font(.headline)
                if let url = model.fileURL {
                    Text("\(url.lastPathComponent) · \(model.fileSize.byteCountText)\(model.isCompressed ? " · gzip" : "") · \(model.countText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(url.path)
                } else {
                    Text("No file chosen").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(model.fileURL == nil ? "Choose File…" : "Change File…") { model.pickFile() }
        }
    }

    private var options: some View {
        Form {
            Section("Reading") {
                Picker("Encoding", selection: Binding(get: { model.options.encoding }, set: { model.options.encoding = $0; model.reload() })) {
                    ForEach(ImportTextEncoding.allCases) { encoding in
                        Text(encoding == .automatic ? "Automatic (\(model.detectedEncoding.title))" : encoding.title).tag(encoding)
                    }
                }
            }
            Section("Running") {
                Picker("On error", selection: $model.options.errorPolicy) {
                    ForEach(ImportErrorPolicy.allCases) { policy in
                        Text(policy == .stopAndKeep ? "Stop and Keep Changes" : policy.title).tag(policy)
                    }
                }
                Text(policyNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.offersForeignKeyToggle {
                    Toggle("Disable foreign key checks", isOn: $model.options.disableForeignKeyChecks)
                }
            }
            Section {
                Text("Runs on a separate connection to \(model.workspace.currentDatabase ?? model.workspace.config.displayName). Statements are split on semicolons; COPY … FROM stdin blocks and the mysql client's DELIMITER command are not supported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var policyNote: String {
        switch model.options.errorPolicy {
        case .stopAndRollBack:
            return model.workspace.kind.usesMySQLProtocol
                ? "Runs in one transaction. MySQL commits CREATE, ALTER and DROP at once; those are not rolled back."
                : "Runs in one transaction: an error undoes every statement of the file."
        case .stopAndKeep: return "Each statement is committed as it runs; the run stops at the first error."
        case .skipAndContinue: return "Failed statements are listed at the end; the rest still run."
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            switch model.phase {
            case .editing:
                if let message = model.message {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") { model.runClicked() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.fileURL == nil)
                    .accessibilityIdentifier("sqlFileRun")
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
            case let .finished(title, detail, isClean, issues):
                TransferResultView(title: title, detail: detail, isClean: isClean, issues: issues)
                Spacer()
                if !issues.isEmpty {
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

// MARK: - Controller

@MainActor
final class RunSQLFileController: NSObject {
    let model: RunSQLFileModel
    private let window: NSWindow
    private weak var parent: NSWindow?
    private var retainSelf: RunSQLFileController?

    init(workspace: ConnectionWorkspace, file: URL?, parent: NSWindow?, onFinished: @escaping () -> Void) {
        model = RunSQLFileModel(workspace: workspace, file: file)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 520), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Run SQL File"
        window.isRestorable = false
        window.setAccessibilityIdentifier("runSQLFileSheet")
        self.parent = parent
        super.init()
        window.contentViewController = NSHostingController(rootView: RunSQLFileView(model: model))
        window.setContentSize(NSSize(width: 780, height: 520))
        model.onClose = { [weak self] in self?.dismiss() }
        model.onFinished = onFinished
        model.chooseFile = { [weak self] completion in self?.chooseFile(completion) }
        model.confirm = { [weak self] proceed in
            guard let self else { return }
            let text = self.model.confirmationText
            workspace.confirmImport(text.message, detail: text.detail, in: self.window, proceed: proceed)
        }
    }

    func present() {
        retainSelf = self
        TransferSheets.sqlFileSheet = self
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
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, UTType(filenameExtension: "gz") ?? .gzip, .plainText]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .sql or .sql.gz file"
        if window.isVisible {
            panel.beginSheetModal(for: window) { response in completion(response == .OK ? panel.url : nil) }
        } else {
            completion(panel.runModal() == .OK ? panel.url : nil)
        }
    }
}

import AppKit
import FoxlumeQueryCore
import SwiftUI

/// State of the Maintenance results sheet: one row per statement, filled in as each one finishes.
@MainActor
final class MaintenanceModel: ObservableObject {
    struct Row: Identifiable {
        let id: Int
        let target: String
        let statement: String
        var outcome = MaintenanceOutcome(status: .waiting)
    }

    let workspace: ConnectionWorkspace
    let title: String
    let subtitle: String
    @Published private(set) var rows: [Row]
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var elapsed: TimeInterval?
    /// Why the run could not start (the separate session did not connect).
    @Published private(set) var failure: String?

    var onClose: (() -> Void)?
    var onFinished: (() -> Void)?

    private let run: MaintenanceRun

    init(workspace: ConnectionWorkspace, operation: MaintenanceOperation, steps: [MaintenanceStep]) {
        self.workspace = workspace
        self.run = MaintenanceRun(steps: steps)
        let database = workspace.currentDatabase ?? workspace.config.displayName
        title = workspace.maintenance.name(operation)
        let tables = steps.filter { $0.table != nil }.count
        subtitle = (tables == 0 ? database : "\(tables) \(tables == 1 ? "table" : "tables") in \(database)") + " · runs on a separate connection"
        rows = steps.enumerated().map { index, step in
            Row(id: index, target: step.table.map { $0.name } ?? database, statement: step.statement)
        }
    }

    var finishedCount: Int { rows.filter { $0.outcome.status.isFinished }.count }

    func start() {
        isRunning = true
        let started = Date()
        let run = self.run
        Task {
            var session: DatabaseSession?
            do {
                session = try await workspace.openMaintenanceRunSession()
            } catch {
                failure = error.localizedDescription
            }
            if let session {
                let outcomes = await run.run(on: session) { index, outcome in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(outcome, at: index) } }
                }
                await session.close()
                for (index, outcome) in outcomes.enumerated() {
                    apply(outcome, at: index)
                    if outcome.status != .skipped { workspace.recordMaintenance(run.steps[index], outcome) }
                }
            }
            elapsed = Date().timeIntervalSince(started)
            isRunning = false
            isCancelling = false
            onFinished?()
        }
    }

    private func apply(_ outcome: MaintenanceOutcome, at index: Int) {
        guard rows.indices.contains(index) else { return }
        // A late "running" update must not overwrite the final outcome.
        if rows[index].outcome.status.isFinished, !outcome.status.isFinished { return }
        rows[index].outcome = outcome
    }

    /// Cancel while running (the statement is stopped as ⌘. stops a query), Done afterwards.
    func cancel() {
        if isRunning {
            isCancelling = true
            run.cancel()
        } else {
            onClose?()
        }
    }

    var progressText: String {
        if isCancelling { return "Cancelling…" }
        let running = rows.first { $0.outcome.status == .running }
        return "\(finishedCount) of \(rows.count)" + (running.map { " · \($0.target)" } ?? "")
    }

    /// "3 OK, 1 warning, 1 failed · 1.20 s".
    var summaryText: String {
        if let failure { return failure }
        let counts: [(MaintenanceStatus, String)] = [(.ok, "OK"), (.warning, "warning"), (.failed, "failed"), (.cancelled, "cancelled"), (.skipped, "not run")]
        let parts = counts.compactMap { status, word -> String? in
            let count = rows.filter { $0.outcome.status == status }.count
            guard count > 0 else { return nil }
            return "\(count) \(word)" + (count > 1 && status == .warning ? "s" : "")
        }
        return parts.joined(separator: ", ") + (elapsed.map { " · " + $0.durationText } ?? "")
    }

    var isClean: Bool { failure == nil && rows.allSatisfy { $0.outcome.status == .ok } }

    /// Tab-separated lines: target, status, time, messages.
    var resultText: String {
        rows.map { row in
            [row.target, row.outcome.status.title, row.outcome.elapsed?.durationText ?? "", row.outcome.summary].joined(separator: "\t")
        }.joined(separator: "\n")
    }

    func copyResults() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
    }
}

// MARK: - View

struct MaintenanceView: View {
    @ObservedObject var model: MaintenanceModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.headline)
                Text(model.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            Table(model.rows) {
                TableColumn("Table") { row in
                    Text(row.target).font(.system(size: 12, design: .monospaced)).help(row.statement)
                }
                .width(min: 110, ideal: 150)
                TableColumn("Status") { row in
                    Label { Text(row.outcome.status.title) } icon: { statusIcon(row.outcome.status) }
                }
                .width(min: 90, ideal: 100, max: 120)
                TableColumn("Messages") { row in
                    Text(row.outcome.messages.map(\.text).joined(separator: "\n"))
                        .font(.callout)
                        .foregroundStyle(row.outcome.status == .failed ? Color.red : Color.primary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .help(row.outcome.messages.map { "\($0.level.rawValue): \($0.text)" }.joined(separator: "\n"))
                }
                .width(min: 200, ideal: 340)
                TableColumn("Time") { row in
                    Text(row.outcome.elapsed?.durationText ?? "").foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 56, ideal: 64, max: 90)
            }
            .accessibilityIdentifier("maintenanceResults")
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 320)
    }

    @ViewBuilder
    private func statusIcon(_ status: MaintenanceStatus) -> some View {
        switch status {
        case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled, .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            if model.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(model.finishedCount), total: Double(max(model.rows.count, 1)))
                    Text(model.progressText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isCancelling)
                    .accessibilityIdentifier("maintenanceCancel")
            } else {
                Image(systemName: model.isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.isClean ? Color.green : Color.orange)
                    .font(.title2)
                Text(model.summaryText).font(.callout).lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("Copy Results") { model.copyResults() }
                Button("Done") { model.cancel() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
    }
}

// MARK: - Controller

@MainActor
final class MaintenanceController: NSObject {
    /// The sheet in front, for the scripted UI checks.
    static weak var presented: MaintenanceController?

    let model: MaintenanceModel
    private let window: NSWindow
    private weak var parent: NSWindow?
    private var retainSelf: MaintenanceController?

    init(workspace: ConnectionWorkspace, operation: MaintenanceOperation, steps: [MaintenanceStep], parent: NSWindow?, onFinished: @escaping () -> Void) {
        model = MaintenanceModel(workspace: workspace, operation: operation, steps: steps)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = model.title
        window.isRestorable = false
        window.setAccessibilityIdentifier("maintenanceSheet")
        self.parent = parent
        super.init()
        window.contentViewController = NSHostingController(rootView: MaintenanceView(model: model))
        window.setContentSize(NSSize(width: 800, height: 400))
        model.onClose = { [weak self] in self?.dismiss() }
        model.onFinished = onFinished
    }

    /// Shows the sheet and starts the run.
    func present() {
        retainSelf = self
        Self.presented = self
        if let parent, parent.isVisible {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        model.start()
    }

    func dismiss() {
        if model.isRunning { model.cancel() }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
        retainSelf = nil
    }
}

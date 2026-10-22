import AppKit
import FoxlumeQueryCore
import SwiftUI

/// The running and finished part shared by the Backup and Restore sheets: the tool's messages as they arrive,
/// elapsed time, size written, Cancel, then the outcome with the command that ran.
@MainActor
final class ToolRunState: ObservableObject {
    static let maxLines = 5000

    @Published private(set) var lines: [String] = []
    @Published private(set) var outputSize: Int64?
    /// Fraction of the script fed to psql or mysql.
    @Published private(set) var inputFraction: Double?
    @Published private(set) var startedAt: Date?
    @Published private(set) var command: String?
    @Published private(set) var result: BackupRunResult?
    @Published private(set) var isCancelling = false

    var onFinished: ((BackupRunResult) -> Void)?

    private var runner: BackupRunner?
    private let buffer = EventBuffer()
    private var drainTimer: Timer?

    var hasStarted: Bool { startedAt != nil }
    var isRunning: Bool { startedAt != nil && result == nil }

    func start(_ runner: BackupRunner) {
        self.runner = runner
        lines = []
        outputSize = nil
        inputFraction = nil
        result = nil
        isCancelling = false
        startedAt = Date()
        let buffer = self.buffer
        drainTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                runner.run { buffer.add($0) }
            }.value
            finish(result)
        }
    }

    /// Stops the tool and its workers; the outcome follows when it has exited and the partial output is removed.
    func cancel() {
        guard isRunning, !isCancelling else { return }
        isCancelling = true
        runner?.cancel()
    }

    private func finish(_ result: BackupRunResult) {
        drain()
        drainTimer?.invalidate()
        drainTimer = nil
        runner = nil
        isCancelling = false
        if command == nil, !result.command.isEmpty { command = result.command }
        if let size = result.outputSize { outputSize = size }
        self.result = result
        onFinished?(result)
    }

    private func drain() {
        let events = buffer.take()
        guard !events.isEmpty else { return }
        var added: [String] = []
        for event in events {
            switch event {
            case .started(let command): self.command = command
            case .log(let line): added.append(line)
            case .outputSize(let size): outputSize = size
            case let .inputProgress(read, total): inputFraction = total > 0 ? min(1, Double(read) / Double(total)) : nil
            }
        }
        if !added.isEmpty {
            lines.append(contentsOf: added)
            if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        }
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return (result.map { $0.elapsed }) ?? Date().timeIntervalSince(startedAt)
    }

    func copyCommand() {
        guard let command = command ?? result?.command else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// "1:05", "12.4 s" or "230 ms".
    static func clock(_ interval: TimeInterval) -> String {
        if interval < 1 { return interval.durationText }
        if interval < 60 { return String(format: "%.1f s", interval) }
        let seconds = Int(interval)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Events arrive on the tool's reader threads; the sheet takes them in batches a few times per second.
private final class EventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BackupRunEvent] = []

    func add(_ event: BackupRunEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func take() -> [BackupRunEvent] {
        lock.lock()
        defer { lock.unlock() }
        let taken = events
        events.removeAll(keepingCapacity: true)
        return taken
    }
}

/// The tool's messages, newest at the bottom, following the end while it runs.
struct ToolLogView: View {
    @ObservedObject var state: ToolRunState

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(state.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Self.isError(line) ? Color.red : Color.primary)
                                .fixedSize()
                                .id(index)
                        }
                    }
                    .padding(10)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    .textSelection(.enabled)
                }
                .onChange(of: state.lines.count) { count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottomLeading) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .center) {
            if state.lines.isEmpty {
                Text(state.isRunning ? "Waiting for the first messages…" : "No messages.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("backupLog")
    }

    static func isError(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("error") || lower.contains("fatal") || lower.contains("denied")
    }
}

/// The footer while the tool runs: elapsed time and size, and Cancel.
struct ToolRunningFooter: View {
    @ObservedObject var state: ToolRunState
    let sizeLabel: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = state.inputFraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(statusText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Button(state.isCancelling ? "Cancelling…" : "Cancel") { state.cancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(state.isCancelling)
                .accessibilityIdentifier("backupCancel")
        }
    }

    private var statusText: String {
        var parts = [ToolRunState.clock(state.elapsed)]
        if let size = state.outputSize { parts.append("\(sizeLabel) \(size.byteCountText)") }
        if let fraction = state.inputFraction { parts.append("\(Int(fraction * 100))% of the file sent") }
        return parts.joined(separator: " · ")
    }
}

/// The outcome: what happened, the command that ran (password shown as a file label), notes and actions.
struct ToolResultView: View {
    @ObservedObject var state: ToolRunState
    let result: BackupRunResult
    let title: String
    let detail: String
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(color).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).accessibilityIdentifier("backupResultTitle")
                    if !detail.isEmpty {
                        Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(6)
                    }
                }
                Spacer()
            }
            if let command = state.command ?? (result.command.isEmpty ? nil : result.command) {
                HStack(alignment: .top, spacing: 6) {
                    Text(command)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                        .help("The command that ran. The password was passed in a private temporary file, deleted afterwards.")
                        .accessibilityIdentifier("backupCommand")
                    Button("Copy") { state.copyCommand() }
                        .help("Copy the command")
                }
            }
            ForEach(result.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Copy Log") { state.copyLog() }.disabled(state.lines.isEmpty)
                Spacer()
                if let url = result.outputURL, result.status == .succeeded {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .accessibilityIdentifier("backupReveal")
                }
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var symbol: String {
        switch result.status {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }

    private var color: Color {
        switch result.status {
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}

/// The missing-tool message: what was not found, where the app looked, how to install it.
struct MissingToolView: View {
    let message: String
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(.orange)
            }
            Button("Open Settings…") { openSettings() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
        .accessibilityIdentifier("backupMissingTool")
    }
}

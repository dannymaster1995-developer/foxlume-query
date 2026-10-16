import AppKit
import FoxlumeQueryCore
import SwiftUI

/// The Server Activity window of one workspace (Database › Server Activity, ⌥⌘A). It polls while open and closes its
/// session when it closes; the workspace window closes it too.
@MainActor
final class ServerActivityWindowController: NSWindowController, NSWindowDelegate {
    let model: ServerActivityModel
    var onClose: (() -> Void)?
    /// Opens text in a new query tab of the workspace window.
    private let openQuery: (String) -> Void

    init(workspace: ConnectionWorkspace, windows: @escaping () -> [ConnectionWorkspace], openQuery: @escaping (String) -> Void) {
        model = ServerActivityModel(workspace: workspace)
        model.windows = windows
        self.openQuery = openQuery
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setAccessibilityIdentifier("serverActivityWindow")
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: ServerActivityView(
            model: model,
            onAction: { [weak self] action, ids in self?.confirm(action, on: ids) },
            onOpenQuery: { [weak self] text in self?.openQuery(text) }
        ))
        // Set after the hosting controller, which replaces the title with the view's (empty) navigation title.
        window.title = "Server Activity – \(workspace.config.displayName)"
        window.setContentSize(NSSize(width: 1280, height: 640))
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        model.start()
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        onClose?()
    }

    // MARK: Actions

    /// Cancel Query / Terminate Session (Kill Query / Kill Connection): refused on Read-Only connections, always
    /// confirmed (Terminate as a critical alert), authenticated on the Safe Mode levels like other writes. Ending one
    /// of the app's own sessions says that its window reconnects.
    func confirm(_ action: ServerSessionAction, on ids: [Int]) {
        let workspace = model.workspace
        let sql = model.sql
        let targets = model.sessions.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return NSSound.beep() }
        let title = sql.title(action)
        if workspace.refusesSessionActions {
            return Alerts.showError(DatabaseError.unsupported("This connection is read-only. \(title) was not run."), title: "Read-only connection", in: window)
        }
        let statements = targets.compactMap { sql.statement(action, id: $0.id) }
        var detail = [sql.explanation(action)]
        detail.append(targets.prefix(5).map(Self.describe).joined(separator: "\n") + (targets.count > 5 ? "\n…" : ""))
        let own = targets.filter { model.owners[$0.id] != nil }
        for session in own {
            guard let owner = model.owners[session.id] else { continue }
            let name = owner.workspace === workspace ? "this window's connection" : owner.workspace.map { "the connection of the window “\($0.config.displayName)”" } ?? "another session of Foxlume Query (such as an export, import or maintenance run)"
            switch action {
            case .terminate:
                detail.append(owner.workspace == nil
                    ? "Session \(session.id) is \(name); what it runs stops with an error."
                    : "Session \(session.id) is \(name). It will reconnect: its open transaction and session settings are lost.")
            case .cancelQuery:
                detail.append("Session \(session.id) is \(name); its running statement stops.")
            }
        }
        let target = targets.count == 1 ? "session \(targets[0].id)" : "\(targets.count) sessions"
        SafeModeGate.authorize(
            config: workspace.config,
            statements: statements,
            writes: true,
            action: "\(title) for \(target)",
            extraDetail: detail.joined(separator: "\n\n"),
            destructive: action.isDestructive,
            confirmTitle: title,
            in: window
        ) { [weak self] allowed in
            guard allowed, let self else { return }
            Task { await self.run(action, on: targets.map(\.id)) }
        }
    }

    private func run(_ action: ServerSessionAction, on ids: [Int]) async {
        let report = await model.perform(action, on: ids)
        guard !report.failures.isEmpty, window?.isVisible == true else { return }
        let lines = report.failures.map { "Session \($0.id): \($0.message)" }
        let message = lines.prefix(5).joined(separator: "\n\n") + (lines.count > 5 ? "\n\n…" : "")
        // Let the confirmation's sheet finish closing first.
        DispatchQueue.main.async { [weak self] in
            Alerts.showError(DatabaseError.unsupported(message), title: "\(self?.model.sql.title(action) ?? "The action") failed", in: self?.window)
        }
    }

    /// "4711 · alice@shop · active · SELECT pg_sleep(60)".
    static func describe(_ session: ServerActivitySession) -> String {
        var parts = [String(session.id)]
        let who = session.user + (session.database.isEmpty ? "" : "@" + session.database)
        if !who.isEmpty { parts.append(who) }
        let state = session.command.isEmpty ? session.state : session.command
        if !state.isEmpty { parts.append(state) }
        let query = ServerActivityView.oneLine(session.query)
        if !query.isEmpty { parts.append(query.count > 80 ? query.prefix(79) + "…" : query) }
        return parts.joined(separator: " · ")
    }
}

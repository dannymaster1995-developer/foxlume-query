import AppKit
import FoxlumeQueryCore

/// Scripted commands for Server Activity (sessions and slow queries).
///
///     activitymenu                    logs whether Database › Server Activity is enabled, disabled or hidden
///     activity                        opens the Server Activity window and waits for its first refresh
///     activitywait                    waits for the next refresh
///     activityfilter [text]           sets (or clears) the filter field
///     activityidle show|hide          the "Hide idle" toggle
///     activitypause on|off            pauses or resumes the 2-second refresh
///     activityrows                    logs the visible sessions: owner, user@database, state, running or not, query
///     activityrun <sql>               runs a statement in the background on a new session of the script's own (such
///                                     as a pg_sleep), so it shows up as a running session
///     activityrunresult               waits up to 10 s for those statements and logs how each ended
///     activityrunstop                 closes those sessions
///     activityselect <text>           selects the visible sessions whose query contains the text
///     activityselectown               selects this window's own session
///     activityact cancel|terminate    the Cancel Query / Terminate Session (Kill Query / Kill Connection) button
///                                     for the selection; answer its question with confirm or closesheet
///     activitystatus                  logs the result of the last action and the session counts
///     activitytab sessions|slow       switches tabs; Slow Queries waits for its load
///     activityslow [total|mean]       reloads slow queries (in that order) and logs the state and the first rows
///     activityopen                    Open in Query Tab for the selected session, or the first slow query
///     activityclose                   closes the Server Activity window
@MainActor
enum ActivityAutoTest {
    static let commands: Set<String> = [
        "activitymenu", "activity", "activitywait", "activityfilter", "activityidle", "activitypause", "activityrows",
        "activityrun", "activityrunresult", "activityrunstop", "activityselect", "activityselectown", "activityact",
        "activitystatus", "activitytab", "activityslow", "activityopen", "activityclose",
    ]
    /// How a statement of `activityrun` ended; nil while it runs.
    final class Run {
        let session: DatabaseSession
        var outcome: String?

        init(session: DatabaseSession) {
            self.session = session
        }
    }

    static var runs: [Run] = []
}

extension AutoTestRunner {
    func performActivity(_ command: String, _ argument: String) async throws {
        guard let window = workspace else { throw DatabaseError.notConnected }
        let activity = window.serverActivityController
        let model = activity?.model
        switch command {
        case "activitymenu":
            let item = NSMenuItem(title: "Server Activity", action: #selector(WorkspaceWindowController.showServerActivity(_:)), keyEquivalent: "a")
            let enabled = window.validateMenuItem(item)
            record("  Server Activity: " + (item.isHidden ? "hidden" : enabled ? "enabled" : "disabled"))
        case "activity":
            let item = NSMenuItem(title: "Server Activity", action: #selector(WorkspaceWindowController.showServerActivity(_:)), keyEquivalent: "a")
            guard window.validateMenuItem(item) else { return record("  disabled: Server Activity") }
            window.showServerActivity(nil)
            guard let model = window.serverActivityController?.model else { throw DatabaseError.unsupported("No Server Activity window") }
            try await waitFor(seconds: 15) { model.lastUpdated != nil || model.errorText != nil }
            try await Task.sleep(nanoseconds: 300_000_000)
            record("  opened: \(window.serverActivityController?.window?.title ?? "")")
        case "activitywait":
            let model = try require(model)
            let count = model.refreshCount
            try await waitFor(seconds: 10) { model.refreshCount > count }
            try await Task.sleep(nanoseconds: 200_000_000)
        case "activityfilter":
            try require(model).filter = argument
            try await Task.sleep(nanoseconds: 200_000_000)
        case "activityidle":
            try require(model).hideIdle = argument != "show"
            try await Task.sleep(nanoseconds: 200_000_000)
        case "activitypause":
            try require(model).isPaused = argument != "off"
        case "activityrows":
            let model = try require(model)
            let rows = model.visibleSessions
            record("  \(rows.count) visible of \(model.sessions.count)")
            for session in rows {
                let who = session.user + (session.database.isEmpty ? "" : "@" + session.database)
                let state = model.isPostgres ? session.state : session.command
                let query = ServerActivityView.oneLine(session.query)
                record("  \(session.owner ?? "-") | \(who) | \(state) | \(session.runningSeconds == nil ? "not running" : "running") | \(query.prefix(70))")
            }
        case "activityrun":
            var parameters = window.workspace.session.parameters
            parameters.config.queryTimeout = nil
            let session = DatabaseSession(parameters: parameters)
            try await session.connect()
            let sql = argument
            let run = ActivityAutoTest.Run(session: session)
            ActivityAutoTest.runs.append(run)
            Task {
                do {
                    _ = try await session.execute(sql)
                    run.outcome = "finished"
                } catch {
                    run.outcome = "stopped: " + error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
                }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        case "activityrunresult":
            let runs = ActivityAutoTest.runs
            try? await waitFor(seconds: 10) { runs.allSatisfy { $0.outcome != nil } }
            for (index, run) in runs.enumerated() {
                record("  run \(index + 1): \(run.outcome ?? "still running")")
            }
        case "activityrunstop":
            for run in ActivityAutoTest.runs {
                run.session.cancel()
                await run.session.close()
            }
            ActivityAutoTest.runs = []
        case "activityselect":
            let model = try require(model)
            model.selection = Set(model.visibleSessions.filter { $0.query.contains(argument) }.map(\.id))
            record("  selected \(model.selection.count)")
            try await Task.sleep(nanoseconds: 200_000_000)
        case "activityselectown":
            let model = try require(model)
            model.selection = Set(model.sessions.filter { $0.owner == "This window" }.map(\.id))
            record("  selected \(model.selection.count)")
        case "activityact":
            let model = try require(model)
            let ids = model.selectedSessions.map(\.id)
            activity?.confirm(argument == "terminate" ? .terminate : .cancelQuery, on: ids)
            try await Task.sleep(nanoseconds: 500_000_000)
        case "activitystatus":
            let model = try require(model)
            try await waitFor(seconds: 10) { !model.isActing }
            record("  action: \(model.actionStatus ?? "none")")
            // The status ends with the refresh time, which changes from run to run.
            record("  status: " + (model.statusText.components(separatedBy: " · updated").first ?? ""))
        case "activitytab":
            let model = try require(model)
            let count = model.slowLoadCount
            model.tab = argument == "slow" ? .slowQueries : .sessions
            if argument == "slow" {
                try await waitFor(seconds: 15) { model.slowLoadCount > count || model.slowSource != nil }
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        case "activityslow":
            let model = try require(model)
            let count = model.slowLoadCount
            if argument == "mean" { model.slowOrder = .meanTime } else if argument == "total" { model.slowOrder = .totalTime }
            if model.slowLoadCount == count, !model.isLoadingSlow { await model.refreshSlowQueries() }
            try await waitFor(seconds: 15) { model.slowLoadCount > count && !model.isLoadingSlow }
            switch model.slowSource {
            case .available(let schema)?: record("  source: \(schema), \(model.slowQueries.count) rows, by \(model.slowOrder.title)")
            case .unavailable(let reason, let hint)?: record("  unavailable: \(reason) | \(hint)")
            case nil: record("  source: none" + (model.slowError.map { " (\($0))" } ?? ""))
            }
            for stat in model.slowQueries.prefix(3) {
                record("  slow: calls \(stat.calls > 0 ? ">0" : "0") | \(ServerActivityView.oneLine(stat.query).prefix(60))")
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        case "activityopen":
            let model = try require(model)
            let text: String?
            if model.tab == .slowQueries {
                model.slowSelection = model.slowQueries.first?.id
                text = model.selectedSlowQuery?.runnableText
            } else {
                text = model.selectedSessions.first?.query
            }
            guard let text, !text.isEmpty else { return record("  nothing to open") }
            window.tabs.openQuery(sql: text)
            window.window?.makeKeyAndOrderFront(nil)
            let opened = (window.tabs.selectedTab?.content as? QueryTabViewController)?.sql ?? ""
            record("  opened query tab: \(ServerActivityView.oneLine(opened).prefix(70))")
            try await Task.sleep(nanoseconds: 400_000_000)
        case "activityclose":
            activity?.window?.close()
            record("  closed; stopped: \(model?.isStopped == true)")
        default:
            break
        }
    }

    private func require(_ model: ServerActivityModel?) throws -> ServerActivityModel {
        guard let model else { throw DatabaseError.unsupported("No Server Activity window") }
        return model
    }
}

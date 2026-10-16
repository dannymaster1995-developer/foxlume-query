import AppKit
import FoxlumeQueryCore
import SwiftUI

/// State of the Server Activity window: the server's sessions, polled every two seconds on a session of its own, and
/// the slow query statistics, read when asked for. See ServerActivitySQL for the statements.
@MainActor
final class ServerActivityModel: ObservableObject {
    enum Tab: String, CaseIterable {
        case sessions
        case slowQueries

        var title: String { self == .sessions ? "Sessions" : "Slow Queries" }
    }

    /// The outcome of one action on several sessions.
    struct ActionReport {
        var action: ServerSessionAction
        var done: [Int] = []
        var gone: [Int] = []
        var failures: [(id: Int, message: String)] = []
    }

    static let pollInterval: TimeInterval = 2
    static let slowQueryLimit = 50

    let workspace: ConnectionWorkspace
    let sql: ServerActivitySQL
    /// The workspaces of every open window, to name their sessions.
    var windows: () -> [ConnectionWorkspace] = { [] }

    @Published var tab: Tab = .sessions {
        didSet {
            guard tab != oldValue else { return }
            if tab == .slowQueries, slowSource == nil { reloadSlowQueries() }
            if tab == .sessions { refreshNow() }
        }
    }

    // MARK: Sessions state

    @Published private(set) var sessions: [ServerActivitySession] = []
    @Published var filter = ""
    @Published var hideIdle = true
    @Published var isPaused = false {
        didSet { if !isPaused, oldValue { refreshNow() } }
    }
    @Published var selection = Set<Int>()
    @Published var sortOrder = [KeyPathComparator(\ServerActivitySession.runningSortKey, order: .reverse)]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorText: String?
    /// What the last action did, shown in the footer.
    @Published private(set) var actionStatus: String?
    @Published private(set) var isActing = false
    /// The app's own sessions found by the last refresh.
    private(set) var owners: [Int: OwnServerSession] = [:]
    /// Finished refreshes, for the scripted UI checks.
    private(set) var refreshCount = 0

    // MARK: Slow queries state

    @Published private(set) var slowSource: SlowQuerySource?
    @Published private(set) var slowQueries: [SlowQueryStat] = []
    @Published var slowOrder: SlowQueryOrder = .totalTime {
        didSet { if slowOrder != oldValue { reloadSlowQueries() } }
    }
    @Published var slowSelection: SlowQueryStat.ID?
    @Published private(set) var slowError: String?
    @Published private(set) var isLoadingSlow = false
    private(set) var slowLoadCount = 0
    private var slowReloadPending = false

    private var session: DatabaseSession?
    private var opening: Task<DatabaseSession, Error>?
    private var pollTask: Task<Void, Never>?
    private var isRefreshing = false
    private(set) var isStopped = false

    init(workspace: ConnectionWorkspace) {
        self.workspace = workspace
        self.sql = workspace.serverActivity
    }

    var isPostgres: Bool { workspace.kind == .postgresql }

    /// The sessions shown: filtered, idle ones hidden when asked, in the table's sort order.
    var visibleSessions: [ServerActivitySession] {
        ServerActivitySQL.visible(sessions, filter: filter, hideIdle: hideIdle).sorted(using: sortOrder)
    }

    var selectedSessions: [ServerActivitySession] {
        sessions.filter { selection.contains($0.id) }
    }

    var selectedSlowQuery: SlowQueryStat? {
        slowQueries.first { $0.id == slowSelection }
    }

    // MARK: Polling

    func start() {
        guard pollTask == nil, !isStopped else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isPaused, self.tab == .sessions { await self.refresh() }
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    /// Stops polling and closes the activity session. Called when the window closes.
    func stop() {
        isStopped = true
        pollTask?.cancel()
        pollTask = nil
        opening?.cancel()
        let session = self.session
        self.session = nil
        guard let session else { return }
        session.cancel()
        Task { await session.close() }
    }

    func refreshNow() {
        Task { await refresh() }
    }

    /// The activity session, opened on first use and again after its link was lost. Concurrent callers share one attempt.
    private func activitySession() async throws -> DatabaseSession {
        if let session, session.isConnected { return session }
        if let opening { return try await opening.value }
        let workspace = self.workspace
        let task = Task { try await workspace.openActivitySession() }
        opening = task
        defer { opening = nil }
        let opened = try await task.value
        if isStopped {
            await opened.close()
            throw DatabaseError.cancelled
        }
        session = opened
        return opened
    }

    /// Drops a session whose link failed, so the next poll opens a new one.
    private func dropSession(_ failed: DatabaseSession) async {
        guard session === failed else { return }
        session = nil
        await failed.close()
    }

    func refresh() async {
        guard !isRefreshing, !isStopped, let query = sql.sessionsQuery else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            refreshCount += 1
        }
        var used: DatabaseSession?
        do {
            let session = try await activitySession()
            used = session
            let result = try await session.execute(query).last(where: \.hasResultSet) ?? StatementResult()
            guard !isStopped else { return }
            owners = workspace.ownServerSessions(windows: windows(), excluding: session)
            sessions = ServerActivitySQL.marking(sql.sessions(from: result), owners: owners.mapValues(\.label))
            let present = selection.intersection(sessions.map(\.id))
            if present != selection { selection = present }
            lastUpdated = Date()
            errorText = nil
        } catch {
            guard !isStopped else { return }
            errorText = error.localizedDescription
            if let used, (error as? DatabaseError)?.isConnectionLoss == true || !used.isConnected {
                await dropSession(used)
            }
        }
    }

    // MARK: Actions

    /// Runs `action` on each session in turn on the activity session, records it in the history, reconnects windows
    /// whose own session was ended, then refreshes the list.
    func perform(_ action: ServerSessionAction, on ids: [Int]) async -> ActionReport {
        var report = ActionReport(action: action)
        isActing = true
        defer { isActing = false }
        let session: DatabaseSession
        do {
            session = try await activitySession()
        } catch {
            report.failures = ids.map { ($0, error.localizedDescription) }
            actionStatus = summary(of: report)
            return report
        }
        for id in ids {
            guard let statement = sql.statement(action, id: id) else { continue }
            let started = Date()
            let outcome: ServerSessionActionOutcome
            do {
                outcome = sql.outcome(of: try await session.execute(statement))
            } catch {
                outcome = sql.outcome(of: error)
            }
            switch outcome {
            case .done: report.done.append(id)
            case .notFound: report.gone.append(id)
            case .failed(let message): report.failures.append((id, message))
            }
            let failure: String?
            switch outcome {
            case .done: failure = nil
            case .notFound: failure = "Session \(id) no longer exists."
            case .failed(let message): failure = message
            }
            workspace.recordSessionAction(statement, duration: Date().timeIntervalSince(started), error: failure)
        }
        if action == .terminate {
            // A window whose own session was ended reconnects now rather than on its next statement.
            for id in report.done {
                guard let owner = owners[id]?.workspace else { continue }
                Task { try? await owner.reconnect() }
            }
        }
        actionStatus = summary(of: report)
        await refresh()
        return report
    }

    /// "Cancelled the query of session 4711." / "Terminated 2 sessions; 1 had already ended." for the footer.
    func summary(of report: ActionReport) -> String {
        let verb: String
        switch (report.action, isPostgres) {
        case (.cancelQuery, true): verb = "Cancelled the query of"
        case (.terminate, true): verb = "Terminated"
        case (.cancelQuery, false): verb = "Killed the query of"
        case (.terminate, false): verb = "Killed"
        }
        var parts: [String] = []
        if !report.done.isEmpty {
            parts.append(report.done.count == 1 ? "\(verb) session \(report.done[0])" : "\(verb) \(report.done.count) sessions")
        }
        if !report.gone.isEmpty {
            parts.append(report.gone.count == 1 ? "session \(report.gone[0]) had already ended" : "\(report.gone.count) sessions had already ended")
        }
        if !report.failures.isEmpty {
            parts.append("\(report.failures.count) failed")
        }
        guard let first = parts.first else { return "" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: "; ") + "."
    }

    // MARK: Slow queries

    func reloadSlowQueries() {
        Task { await refreshSlowQueries() }
    }

    func refreshSlowQueries() async {
        guard !isStopped, let sourceQuery = sql.slowQuerySourceQuery else { return }
        guard !isLoadingSlow else {
            slowReloadPending = true
            return
        }
        isLoadingSlow = true
        defer {
            isLoadingSlow = false
            slowLoadCount += 1
            if slowReloadPending {
                slowReloadPending = false
                reloadSlowQueries()
            }
        }
        do {
            let session = try await activitySession()
            var source = sql.slowQuerySource(from: try await session.execute(sourceQuery).last(where: \.hasResultSet))
            var rows: [SlowQueryStat] = []
            if case .available(let schema) = source, let query = sql.slowQueriesQuery(schema: schema, order: slowOrder, limit: Self.slowQueryLimit) {
                do {
                    rows = sql.slowQueries(from: try await session.execute(query).last(where: \.hasResultSet) ?? StatementResult())
                } catch {
                    guard let unavailable = sql.slowQuerySource(fromFailure: error) else { throw error }
                    source = unavailable
                }
            }
            guard !isStopped else { return }
            slowSource = source
            slowQueries = rows
            if let slowSelection, !rows.contains(where: { $0.id == slowSelection }) { self.slowSelection = nil }
            slowError = nil
        } catch {
            guard !isStopped else { return }
            slowError = error.localizedDescription
        }
    }

    // MARK: Copy

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The footer's status: the session counts and the time of the last refresh, or why it failed.
    var statusText: String {
        if let errorText { return errorText }
        guard let lastUpdated else { return "Loading…" }
        let shown = visibleSessions.count
        let time = DateFormatter.localizedString(from: lastUpdated, dateStyle: .none, timeStyle: .medium)
        let noun = sessions.count == 1 ? "session" : "sessions"
        let counts = shown == sessions.count ? "\(sessions.count) \(noun)" : "\(shown) of \(sessions.count) \(noun)"
        return counts + (isPaused ? " · paused" : "") + " · updated \(time)"
    }
}

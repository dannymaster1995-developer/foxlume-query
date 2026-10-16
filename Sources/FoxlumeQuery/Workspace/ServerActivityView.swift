import AppKit
import FoxlumeQueryCore
import SwiftUI

/// Server Activity: the Sessions table with its actions, and the Slow Queries table.
struct ServerActivityView: View {
    @ObservedObject var model: ServerActivityModel
    /// Asks for confirmation (and Safe Mode), then runs the action; see ServerActivityWindowController.
    var onAction: (ServerSessionAction, [Int]) -> Void
    var onOpenQuery: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.tab {
            case .sessions: sessionsContent
            case .slowQueries: slowContent
            }
        }
        .frame(minWidth: 760, minHeight: 360)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.tab) {
                ForEach(ServerActivityModel.Tab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("activityTab")
            Spacer()
            switch model.tab {
            case .sessions:
                TextField("Filter by user, database or query", text: $model.filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .accessibilityIdentifier("activityFilter")
                Toggle("Hide idle", isOn: $model.hideIdle)
                    .accessibilityIdentifier("activityHideIdle")
                Button {
                    model.isPaused.toggle()
                } label: {
                    Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                }
                .help(model.isPaused ? "Refresh every 2 seconds again" : "Stop refreshing every 2 seconds")
                .accessibilityIdentifier("activityPause")
            case .slowQueries:
                Picker("Order by", selection: $model.slowOrder) {
                    ForEach(SlowQueryOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Button {
                    model.reloadSlowQueries()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoadingSlow)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Sessions

    private var sessionsContent: some View {
        VStack(spacing: 0) {
            Group {
                if model.isPostgres { postgresSessions } else { mysqlSessions }
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                sessionMenu(Array(ids))
            }
            .accessibilityIdentifier("activitySessions")
            Divider()
            sessionDetail
            Divider()
            sessionsFooter
        }
    }

    private var postgresSessions: some View {
        Table(model.visibleSessions, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("PID", value: \.id) { pidCell($0) }.width(min: 60, ideal: 140)
            TableColumn("User", value: \.user).width(min: 50, ideal: 65)
            TableColumn("Database", value: \.database).width(min: 50, ideal: 70)
            TableColumn("Application", value: \.application).width(min: 60, ideal: 100)
            TableColumn("Client", value: \.client).width(min: 60, ideal: 100)
            TableColumn("State", value: \.state) { stateCell($0.state) }.width(min: 50, ideal: 75)
            TableColumn("Wait Event", value: \.waitEvent).width(min: 50, ideal: 90)
            TableColumn("Backend Start", value: \.backendStart).width(min: 60, ideal: 125)
            TableColumn("Running", value: \.runningSortKey) { session in
                runningCell(session).help(session.queryStart.isEmpty ? "" : "Query started \(session.queryStart)")
            }
            .width(min: 50, ideal: 60)
            TableColumn("Query", value: \.query) { queryCell($0.query) }.width(min: 120, ideal: 240)
        }
    }

    private var mysqlSessions: some View {
        Table(model.visibleSessions, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("ID", value: \.id) { pidCell($0) }.width(min: 50, ideal: 140)
            TableColumn("User", value: \.user).width(min: 50, ideal: 80)
            TableColumn("Host", value: \.client).width(min: 60, ideal: 120)
            TableColumn("DB", value: \.database).width(min: 40, ideal: 80)
            TableColumn("Command", value: \.command).width(min: 50, ideal: 75)
            TableColumn("Time", value: \.runningSortKey) { runningCell($0) }.width(min: 40, ideal: 60)
            TableColumn("State", value: \.state).width(min: 60, ideal: 130)
            TableColumn("Info", value: \.query) { queryCell($0.query) }.width(min: 120, ideal: 320)
        }
    }

    private func pidCell(_ session: ServerActivitySession) -> some View {
        HStack(spacing: 5) {
            Text(String(session.id)).monospacedDigit()
            if let owner = session.owner {
                Text(owner)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .help("A session of Foxlume Query")
            }
        }
    }

    private func stateCell(_ state: String) -> some View {
        Text(state).foregroundStyle(state.hasPrefix("idle in transaction") ? Color.orange : state == "active" ? Color.primary : Color.secondary)
    }

    private func runningCell(_ session: ServerActivitySession) -> some View {
        Text(ServerActivitySQL.durationText(session.runningSeconds))
            .monospacedDigit()
            .foregroundStyle((session.runningSeconds ?? 0) >= 10 ? Color.orange : Color.primary)
    }

    private func queryCell(_ query: String) -> some View {
        Text(Self.oneLine(query))
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .help(String(query.prefix(2000)))
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    @ViewBuilder
    private func sessionMenu(_ ids: [Int]) -> some View {
        let refused = model.workspace.refusesSessionActions
        Button(model.sql.title(.cancelQuery) + "…") { onAction(.cancelQuery, ids) }
            .disabled(ids.isEmpty || refused || model.isActing)
        Button(model.sql.title(.terminate) + "…") { onAction(.terminate, ids) }
            .disabled(ids.isEmpty || refused || model.isActing)
        Divider()
        let queries = model.sessions.filter { ids.contains($0.id) }.map(\.query).filter { !$0.isEmpty }
        Button("Copy Query") { ServerActivityModel.copy(queries.joined(separator: ";\n\n")) }
            .disabled(queries.isEmpty)
        Button("Open in Query Tab") { onOpenQuery(queries.joined(separator: ";\n\n")) }
            .disabled(queries.isEmpty)
    }

    /// The whole statement of the selected session, with who runs it.
    private var sessionDetail: some View {
        let selected = model.selectedSessions
        return Group {
            if selected.count == 1, let session = selected.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(detailLine(session)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    ScrollView {
                        Text(session.query.isEmpty ? "No statement" : session.query)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(session.query.isEmpty ? Color.secondary : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text(selected.isEmpty ? "Select a session to see its statement." : "\(selected.count) sessions selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 96)
    }

    private func detailLine(_ session: ServerActivitySession) -> String {
        var parts = ["\(model.isPostgres ? "PID" : "ID") \(session.id)"]
        let who = session.user + (session.database.isEmpty ? "" : "@" + session.database)
        if !who.isEmpty { parts.append(who) }
        if !session.application.isEmpty { parts.append(session.application) }
        if !session.client.isEmpty { parts.append(session.client) }
        let state = session.command.isEmpty ? session.state : [session.command, session.state].filter { !$0.isEmpty }.joined(separator: ", ")
        if !state.isEmpty { parts.append(state) }
        if session.runningSeconds != nil { parts.append("running " + ServerActivitySQL.durationText(session.runningSeconds)) }
        if !session.queryStart.isEmpty { parts.append("query started " + session.queryStart) }
        if let owner = session.owner { parts.append(owner) }
        return parts.joined(separator: " · ")
    }

    private var sessionsFooter: some View {
        let ids = model.selectedSessions.map(\.id)
        let refused = model.workspace.refusesSessionActions
        let queries = model.selectedSessions.map(\.query).filter { !$0.isEmpty }
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(model.errorText == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let status = model.actionStatus {
                    Text(status).font(.caption).lineLimit(1)
                }
            }
            Spacer()
            Button("Copy Query") { ServerActivityModel.copy(queries.joined(separator: ";\n\n")) }
                .disabled(queries.isEmpty)
            Button("Open in Query Tab") { onOpenQuery(queries.joined(separator: ";\n\n")) }
                .disabled(queries.isEmpty)
            Button(model.sql.title(.cancelQuery) + "…") { onAction(.cancelQuery, ids) }
                .disabled(ids.isEmpty || refused || model.isActing)
                .help(refused ? "This connection is read-only" : "Stop the running statement of the selected sessions")
                .accessibilityIdentifier("activityCancelQuery")
            Button(model.sql.title(.terminate) + "…") { onAction(.terminate, ids) }
                .disabled(ids.isEmpty || refused || model.isActing)
                .help(refused ? "This connection is read-only" : "End the selected sessions")
                .accessibilityIdentifier("activityTerminate")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Slow queries

    @ViewBuilder
    private var slowContent: some View {
        VStack(spacing: 0) {
            if case .unavailable(let reason, let hint)? = model.slowSource {
                VStack(spacing: 8) {
                    Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(reason).font(.headline)
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 480)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("activitySlowUnavailable")
            } else {
                Group {
                    if model.isPostgres { postgresSlowQueries } else { mysqlSlowQueries }
                }
                .contextMenu(forSelectionType: Int.self) { ids in
                    if let stat = model.slowQueries.first(where: { ids.contains($0.id) }) {
                        Button("Copy Query") { ServerActivityModel.copy(stat.runnableText) }
                        Button("Open in Query Tab") { onOpenQuery(stat.runnableText) }
                    }
                }
                .accessibilityIdentifier("activitySlowQueries")
            }
            Divider()
            slowFooter
        }
    }

    private var postgresSlowQueries: some View {
        Table(model.slowQueries, selection: $model.slowSelection) {
            TableColumn("Query") { queryCell($0.query) }.width(min: 160, ideal: 420)
            TableColumn("Database") { Text($0.database) }.width(min: 50, ideal: 90)
            TableColumn("User") { Text($0.user) }.width(min: 50, ideal: 80)
            TableColumn("Calls") { number($0.calls) }.width(min: 40, ideal: 70)
            TableColumn("Total Time") { duration($0.totalSeconds) }.width(min: 50, ideal: 80)
            TableColumn("Mean Time") { duration($0.meanSeconds) }.width(min: 50, ideal: 80)
            TableColumn("Rows") { number($0.rows) }.width(min: 40, ideal: 70)
        }
    }

    private var mysqlSlowQueries: some View {
        Table(model.slowQueries, selection: $model.slowSelection) {
            TableColumn("Query") { queryCell($0.runnableText) }.width(min: 160, ideal: 400)
            TableColumn("Schema") { Text($0.database) }.width(min: 50, ideal: 90)
            TableColumn("Exec Count") { number($0.calls) }.width(min: 40, ideal: 70)
            TableColumn("Total Latency") { duration($0.totalSeconds) }.width(min: 50, ideal: 80)
            TableColumn("Avg Latency") { duration($0.meanSeconds) }.width(min: 50, ideal: 80)
            TableColumn("Rows Sent") { number($0.rows) }.width(min: 40, ideal: 70)
            TableColumn("Rows Examined") { number($0.rowsExamined) }.width(min: 40, ideal: 90)
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(\.groupedText) ?? "").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func duration(_ seconds: Double) -> some View {
        Text(ServerActivitySQL.durationText(seconds)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var slowFooter: some View {
        let selected = model.selectedSlowQuery
        let status: String = {
            if let error = model.slowError { return error }
            if model.isLoadingSlow && model.slowSource == nil { return "Loading…" }
            guard case .available? = model.slowSource else { return "" }
            let source = model.isPostgres ? "pg_stat_statements" : "performance_schema"
            return "Top \(model.slowQueries.count) statements by \(model.slowOrder.title.lowercased()) from \(source), since its statistics were last reset"
        }()
        return HStack(spacing: 8) {
            Text(status)
                .font(.caption)
                .foregroundStyle(model.slowError == nil ? Color.secondary : Color.red)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
            Button("Copy Query") { selected.map { ServerActivityModel.copy($0.runnableText) } }
                .disabled(selected == nil)
            Button("Open in Query Tab") { selected.map { onOpenQuery($0.runnableText) } }
                .disabled(selected == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

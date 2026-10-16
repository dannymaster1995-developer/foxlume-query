import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

extension AppCompletionTests {
    /// Server Activity through the window: the menu item per engine, polling and the app's own sessions, actions on a
    /// `pg_sleep` session the test starts itself, ending this window's own session, and Read-Only refusal.
    @Suite("Server Activity", .serialized)
    @MainActor
    struct ServerActivityAppTests {
        private static func postgres(readOnly: Bool = false) -> ConnectionConfig {
            ConnectionConfig(name: "fqtest", kind: .postgresql, host: "127.0.0.1", port: 55432, user: "postgres", database: "foxlume", sslMode: .prefer, readOnly: readOnly)
        }

        private func makeWindow(_ config: ConnectionConfig, password: String) async throws -> WorkspaceWindowController {
            let workspace = ConnectionWorkspace(config: config, password: password)
            try await workspace.connect()
            return WorkspaceWindowController(workspace: workspace)
        }

        private func close(_ controller: WorkspaceWindowController) async {
            let id = controller.workspace.config.id
            controller.window?.close()
            await controller.workspace.disconnect()
            try? FileManager.default.removeItem(at: AppPaths.tabStateDirectory.appendingPathComponent(id.uuidString + ".json"))
        }

        private func menuItem() -> NSMenuItem {
            NSMenuItem(title: "Server Activity", action: #selector(WorkspaceWindowController.showServerActivity(_:)), keyEquivalent: "a")
        }

        private func sleeper() async throws -> DatabaseSession {
            let session = DatabaseSession(parameters: ConnectionParameters(config: Self.postgres(), password: "postgres"))
            try await session.connect()
            return session
        }

        @Test func hiddenForEnginesWithoutSessions() async throws {
            let directory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
            let url = directory.appendingPathComponent("activity-\(UUID().uuidString).sqlite")
            let controller = try await makeWindow(ConnectionConfig(name: "fqtest", kind: .sqlite, filePath: url.path), password: "")
            defer {
                Task {
                    await close(controller)
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let item = menuItem()
            #expect(!controller.validateMenuItem(item))
            #expect(item.isHidden)
            controller.showServerActivity(nil)
            #expect(controller.serverActivityController == nil)
            #expect(MainMenu.build().items.first { $0.title == "Database" }?.submenu?.items.first { $0.title == "Server Activity" }?.keyEquivalentModifierMask == [.command, .option])
        }

        @Test func actionSummaries() {
            let model = ServerActivityModel(workspace: ConnectionWorkspace(config: Self.postgres(), password: ""))
            #expect(model.summary(of: .init(action: .cancelQuery, done: [4711])) == "Cancelled the query of session 4711.")
            #expect(model.summary(of: .init(action: .terminate, done: [1, 2], gone: [3], failures: [(4, "denied")])) == "Terminated 2 sessions; session 3 had already ended; 1 failed.")
            #expect(model.summary(of: .init(action: .terminate, gone: [3, 5])) == "2 sessions had already ended.")
            let mysql = ServerActivityModel(workspace: ConnectionWorkspace(config: ConnectionConfig(name: "fqtest", kind: .mysql, host: "127.0.0.1", port: 53306, user: "root"), password: ""))
            #expect(mysql.summary(of: .init(action: .terminate, done: [12])) == "Killed session 12.")
            #expect(ServerActivityWindowController.describe(ServerActivitySession(id: 7, user: "alice", database: "shop", state: "active", query: "SELECT\n  pg_sleep(60)")) == "7 · alice@shop · active · SELECT pg_sleep(60)")
        }

        @Test(.enabled(if: LiveServer.postgres, "needs the PostgreSQL test server"))
        func pollsMarksOwnSessionsActsAndStopsOnClose() async throws {
            let controller = try await makeWindow(Self.postgres(), password: "postgres")
            let workspace = controller.workspace
            let sleeper = try await sleeper()
            defer {
                Task {
                    await sleeper.close()
                    await close(controller)
                }
            }
            let item = menuItem()
            #expect(controller.validateMenuItem(item) && !item.isHidden)
            controller.showServerActivity(nil)
            let activity = try #require(controller.serverActivityController)
            let model = activity.model
            model.hideIdle = false
            await settle(until: { model.lastUpdated != nil }, seconds: 10)
            #expect(model.errorText == nil)
            let mainPID = try #require(workspace.session.serverProcessID)
            #expect(model.sessions.first { $0.id == mainPID }?.owner == "This window")
            // Opening it again brings the same window forward.
            controller.showServerActivity(nil)
            #expect(controller.serverActivityController === activity)

            // A pg_sleep on a session the test started shows up within a poll or two, marked as the app's own.
            let marker = "fq112_app_" + UUID().uuidString.prefix(6).lowercased()
            let sleeping = Task { try await sleeper.execute("SELECT pg_sleep(30), '\(marker)'") }
            await settle(until: { model.sessions.contains { $0.query.contains(marker) && $0.state == "active" } }, seconds: 8)
            let target = try #require(model.sessions.first { $0.query.contains(marker) })
            #expect(target.id == sleeper.serverProcessID && target.owner == "Foxlume Query" && target.runningSeconds != nil)
            model.hideIdle = true
            model.filter = marker
            #expect(model.visibleSessions.map(\.id) == [target.id])

            // Terminate asks first, as a sheet on the activity window; Cancel leaves the session alone.
            activity.confirm(.terminate, on: [target.id])
            let question = try #require(activity.window?.attachedSheet)
            activity.window?.endSheet(question, returnCode: .alertSecondButtonReturn)
            await settle(300)
            #expect(model.actionStatus == nil)

            let report = await model.perform(.cancelQuery, on: [target.id])
            #expect(report.done == [target.id] && report.failures.isEmpty)
            #expect(model.actionStatus == "Cancelled the query of session \(target.id).")
            await #expect(throws: DatabaseError.self) { try await sleeping.value }

            // Ending this window's own session: the window reconnects on its own.
            let ended = await model.perform(.terminate, on: [mainPID])
            #expect(ended.done == [mainPID])
            await settle(until: { workspace.connectionState == .connected && workspace.session.serverProcessID != mainPID && workspace.session.serverProcessID != nil }, seconds: 10)
            #expect(workspace.session.serverProcessID != mainPID)
            #expect(try await workspace.execute("SELECT 1", recordHistory: false).first?.rows.first?.first?.textValue == "1")

            activity.window?.close()
            #expect(model.isStopped)
            #expect(controller.serverActivityController == nil)
        }

        @Test(.enabled(if: LiveServer.postgres, "needs the PostgreSQL test server"))
        func readOnlyConnectionsRefuseActions() async throws {
            let controller = try await makeWindow(Self.postgres(readOnly: true), password: "postgres")
            defer { Task { await close(controller) } }
            controller.showServerActivity(nil)
            let activity = try #require(controller.serverActivityController)
            let model = activity.model
            model.hideIdle = false
            await settle(until: { model.lastUpdated != nil }, seconds: 10)
            // The list still works on a Read-Only connection.
            let mainPID = try #require(controller.workspace.session.serverProcessID)
            #expect(model.sessions.contains { $0.id == mainPID })
            #expect(controller.workspace.refusesSessionActions)
            activity.confirm(.cancelQuery, on: [mainPID])
            let alert = try #require(activity.window?.attachedSheet)
            activity.window?.endSheet(alert)
            await settle(200)
            #expect(model.actionStatus == nil)
            activity.window?.close()
        }
    }
}

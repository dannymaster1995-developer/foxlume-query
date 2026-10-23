import AppKit
import Testing
@testable import FoxlumeQuery
@testable import FoxlumeQueryCore

extension AppCompletionTests {
    /// Backup and Restore through the window: the menu items per engine and on Read-Only connections, the Backup sheet
    /// running the test server's own mysqldump (chosen in Settings) on a scratch database, a wrong tool path, and the
    /// Restore sheet telling a MySQL script from a PostgreSQL connection's needs.
    @Suite("Backup and Restore", .serialized)
    @MainActor
    struct BackupAppTests {
        /// The test server's own mysqldump: `FQ_MYSQL_CLIENT_BIN` (set by `scripts/ci-server.sh`), else `../.dbtest/mysql-bin`.
        nonisolated static let mysqldump: String = {
            if let folder = ProcessInfo.processInfo.environment["FQ_MYSQL_CLIENT_BIN"], !folder.isEmpty {
                return URL(fileURLWithPath: folder).appendingPathComponent("mysqldump").path
            }
            return URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".dbtest/mysql-bin/bin/mysqldump").path
        }()
        nonisolated static var ready: Bool { LiveServer.mysql && FileManager.default.isExecutableFile(atPath: mysqldump) }
        static let scratch = "fq114_app"

        private static func mysql(database: String = "foxlume", readOnly: Bool = false) -> ConnectionConfig {
            ConnectionConfig(name: "fqtest", kind: .mysql, host: "127.0.0.1", port: 53306, user: "root", database: database, sslMode: .prefer, readOnly: readOnly)
        }

        private func makeWindow(_ config: ConnectionConfig, password: String) async throws -> WorkspaceWindowController {
            let workspace = ConnectionWorkspace(config: config, password: password)
            try await workspace.connect()
            let controller = WorkspaceWindowController(workspace: workspace)
            controller.window?.isReleasedWhenClosed = false
            controller.window?.orderFront(nil)
            return controller
        }

        private func close(_ controller: WorkspaceWindowController) async {
            let id = controller.workspace.config.id
            controller.window?.close()
            await controller.workspace.disconnect()
            try? FileManager.default.removeItem(at: AppPaths.tabStateDirectory.appendingPathComponent(id.uuidString + ".json"))
        }

        private func item(_ action: Selector) -> NSMenuItem {
            NSMenuItem(title: "", action: action, keyEquivalent: "")
        }

        private func scratchDatabase(create: Bool) async throws {
            let session = DatabaseSession(parameters: ConnectionParameters(config: Self.mysql(), password: "root"))
            try await session.connect()
            _ = try await session.execute("DROP DATABASE IF EXISTS \(Self.scratch)")
            if create {
                _ = try await session.execute("CREATE DATABASE \(Self.scratch)")
                _ = try await session.execute("CREATE TABLE \(Self.scratch).fq114_app_items (id int PRIMARY KEY, name varchar(20))")
                _ = try await session.execute("INSERT INTO \(Self.scratch).fq114_app_items VALUES (1, 'one'), (2, 'two')")
            }
            await session.close()
        }

        @Test func databaseMenuHasBackupAndRestore() {
            // Building the menu sets NSApp's Services, Window and Help menus.
            _ = NSApplication.shared
            let database = MainMenu.build().items.first { $0.title == "Database" }?.submenu
            #expect(database?.items.contains { $0.title == "Backup…" } == true)
            #expect(database?.items.contains { $0.title == "Restore…" } == true)
        }

        @Test func noBackupForEnginesWithoutTools() async throws {
            let directory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
            let url = directory.appendingPathComponent("backup-\(UUID().uuidString).sqlite")
            let controller = try await makeWindow(ConnectionConfig(name: "fqtest", kind: .sqlite, filePath: url.path), password: "")
            defer {
                Task {
                    await close(controller)
                    try? FileManager.default.removeItem(at: url)
                }
            }
            #expect(!controller.validateMenuItem(item(#selector(WorkspaceWindowController.backupDatabase(_:)))))
            #expect(!controller.validateMenuItem(item(#selector(WorkspaceWindowController.restoreDatabase(_:)))))
            #expect(!controller.sidebarBackgroundMenuTitles().contains { $0.hasPrefix("Backup") || $0.hasPrefix("Restore") })
        }

        @Test(.enabled(if: LiveServer.mysql, "needs the MySQL test server"))
        func readOnlyConnectionsBackUpButDoNotRestore() async throws {
            let writable = try await makeWindow(Self.mysql(), password: "root")
            #expect(writable.validateMenuItem(item(#selector(WorkspaceWindowController.backupDatabase(_:)))))
            #expect(writable.validateMenuItem(item(#selector(WorkspaceWindowController.restoreDatabase(_:)))))
            let background = writable.sidebarBackgroundMenuTitles()
            #expect(background.contains("Backup Database…") && background.contains("Restore…"))
            // MySQL has no schemas to back up on their own.
            #expect(!background.contains("Backup Schema…"))
            let users = try #require(writable.workspace.tables.first { $0.name == "users" })
            #expect(writable.sidebarMenuTitles(for: users).contains("Backup…"))
            await close(writable)

            let readOnly = try await makeWindow(Self.mysql(readOnly: true), password: "root")
            defer { Task { await close(readOnly) } }
            let restore = item(#selector(WorkspaceWindowController.restoreDatabase(_:)))
            #expect(readOnly.validateMenuItem(item(#selector(WorkspaceWindowController.backupDatabase(_:)))))
            #expect(!readOnly.validateMenuItem(restore))
            #expect(restore.toolTip == "This connection is read-only")
            let titles = readOnly.sidebarBackgroundMenuTitles()
            #expect(titles.contains("Backup Database…") && !titles.contains("Restore…"))
        }

        @Test(.enabled(if: ready, "needs the MySQL test server and ../.dbtest/mysql-bin"))
        func backupSheetRunsTheChosenTool() async throws {
            let original = AppEnvironment.settings
            defer { AppEnvironment.settings = original }
            try await scratchDatabase(create: true)
            let destination = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appendingPathComponent("fq114-app-\(UUID().uuidString.prefix(6)).sql")
            let controller = try await makeWindow(Self.mysql(database: Self.scratch), password: "root")
            // Removed here, not in the Task below, which may still be pending when the test process ends.
            defer { try? FileManager.default.removeItem(at: destination) }
            defer {
                Task {
                    await close(controller)
                    try? await scratchDatabase(create: false)
                }
            }

            // A path in Settings that cannot run is reported, and nothing starts.
            AppEnvironment.settings.setBackupToolPath(.mysqldump, "/nonexistent/mysqldump")
            controller.presentBackup(.database)
            let broken = try #require(BackupController.presented?.model)
            await settle(until: { broken.toolSearch != nil }, seconds: 10)
            #expect(broken.missingToolMessage?.contains("/nonexistent/mysqldump, chosen in Settings › Backup Tools, cannot be run") == true)
            #expect(!broken.canStart)
            BackupController.presented?.dismiss()

            AppEnvironment.settings.setBackupToolPath(.mysqldump, Self.mysqldump)
            let table = TableRef(name: "fq114_app_items")
            controller.presentBackup(.tables([table]))
            let model = try #require(BackupController.presented?.model)
            #expect(model !== broken)
            await settle(until: { model.toolSearch != nil }, seconds: 10)
            // The test server's own tool, whichever version it is (8.4 locally; every matrix version on CI).
            let version = try #require(BackupToolDiscovery.version(ofToolAt: Self.mysqldump))
            #expect(model.toolLine == "mysqldump \(version) (chosen in Settings)")
            #expect(model.toolPath == Self.mysqldump)
            #expect(model.scope == .tables([table]))
            #expect(model.suggestedName.hasPrefix("fq114_app-fq114_app_items-") && model.suggestedName.hasSuffix(".sql"))
            #expect(model.canStart)
            model.start(destination: destination)
            #expect(!model.canStart)
            await settle(until: { model.run.result != nil }, seconds: 30)
            let result = try #require(model.run.result)
            #expect(result.status == .succeeded, "\(result.message ?? "")")
            #expect(model.resultTitle == "Backup finished")
            #expect(model.run.command?.contains("--defaults-extra-file=<password file>") == true)
            #expect(!model.run.lines.isEmpty)
            #expect(FileManager.default.fileExists(atPath: destination.path))
            // The choices are remembered for the next backup.
            #expect(BackupPreferences.load().lastFolder == destination.deletingLastPathComponent().path)
            BackupController.presented?.dismiss()
            #expect(controller.window?.attachedSheet == nil)

            // Restore tells what the file is and that Run SQL File can take it without a client tool.
            let restore = RestoreController(workspace: controller.workspace, file: destination, parent: controller.window, onFinished: {}, openRunSQLFile: { _, _ in })
            restore.present()
            let restoreModel = restore.model
            await settle(until: { !restoreModel.isSearching }, seconds: 10)
            #expect(restoreModel.kind == .plainSQL(compressed: false, dialect: .mysql))
            #expect(restoreModel.problem == nil)
            #expect(restoreModel.tool == nil)
            #expect(restoreModel.targetDatabase == Self.scratch)
            #expect(restoreModel.canRestore)
            restoreModel.scriptRunner = .client
            #expect(restoreModel.tool == .mysql)
            restore.dismiss()
        }

        @Test(.enabled(if: LiveServer.postgres, "needs the PostgreSQL test server"))
        func restoreRefusesAScriptForTheOtherEngine() async throws {
            let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
            let file = directory.appendingPathComponent("fq114-app-\(UUID().uuidString.prefix(6)).sql")
            try "-- MySQL dump 10.13  Distrib 8.4.9\n/*!40101 SET NAMES utf8mb4 */;\n".write(to: file, atomically: true, encoding: .utf8)
            let controller = try await makeWindow(ConnectionConfig(name: "fqtest", kind: .postgresql, host: "127.0.0.1", port: 55432, user: "postgres", database: "foxlume", sslMode: .prefer), password: "postgres")
            defer { try? FileManager.default.removeItem(at: file) }
            defer { Task { await close(controller) } }
            let background = controller.sidebarBackgroundMenuTitles()
            #expect(background.contains("Backup Database…") && background.contains("Backup Schema…") && background.contains("Restore…"))
            let model = RestoreModel(workspace: controller.workspace, file: file)
            await settle(until: { !model.isSearching }, seconds: 10)
            #expect(model.problem == "This script was written by mysqldump for MySQL or MariaDB.")
            #expect(!model.canRestore)
        }
    }
}

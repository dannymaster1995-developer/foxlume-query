import AppKit
import FoxlumeQueryCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var welcome: WelcomeWindowController?
    private(set) var workspaces: [WorkspaceWindowController] = []
    private var pendingOpenURLs: [URL] = []
    private var didFinishLaunching = false
    private var autoTest: AutoTestRunner?

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        NSApp.mainMenu = MainMenu.build()
        NSApp.applicationIconImage = AppIcon.image()
        applyAppearance()
        NotificationCenter.default.addObserver(forName: SettingsStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
    }

    private var appliedAppearance: AppearanceMode?

    /// Forces light or dark for every window, or follows macOS. The light or dark theme then follows the window.
    private func applyAppearance() {
        let mode = AppEnvironment.settings.appearance
        guard mode != appliedAppearance else { return }
        appliedAppearance = mode
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        moveEmbeddedPasswordsToCredentialStore()
        reportUnreadableConnections()
        reportUnreadableSavedQueries()
        if pendingOpenURLs.isEmpty {
            showWelcome(nil)
        } else {
            pendingOpenURLs.forEach(open)
            pendingOpenURLs = []
        }
        #if DEBUG
        // Scripted UI checks exist only in debug builds; release builds ignore the environment variable.
        if let script = AutoTestRunner.scriptFromEnvironment() {
            autoTest = AutoTestRunner(app: self, script: script)
            autoTest?.start()
            // Scripted runs stay in the background so they never take keyboard focus from the user.
            return
        }
        #endif
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workspaces.contains(where: { $0.tabs.hasUnsavedChanges }) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit and discard unsaved changes?"
        alert.informativeText = "Some open tables have edits that were not saved."
        alert.alertStyle = .warning
        let quit = alert.addButton(withTitle: "Discard and Quit")
        quit.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaces.forEach { $0.tabs.saveState() }
        SSHTunnel.stopAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard didFinishLaunching else {
            pendingOpenURLs += urls
            return
        }
        urls.forEach(open)
    }

    /// Files open as SQLite/DuckDB databases; database URLs (`postgresql://…`) connect directly.
    private func open(_ url: URL) {
        if url.isFileURL, ["sql", "psql", "pgsql"].contains(url.pathExtension.lowercased()) {
            openSQLFile(url)
        } else if url.isFileURL {
            openDatabaseFile(url)
        } else {
            openConnectionURL(url.absoluteString)
        }
    }

    @objc func promptConnectionURL(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Open Connection URL"
        alert.informativeText = "postgresql://, mysql://, mariadb://, mongodb://, mongodb+srv://, redis://, rediss://, sqlite:// or duckdb:// links are supported."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "postgresql://user:password@host:5432/database"
        if let clipboard = NSPasteboard.general.string(forType: .string), ConnectionURL.parse(clipboard) != nil {
            field.stringValue = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openConnectionURL(field.stringValue)
    }

    /// Connects to a database URL without saving it; the password comes from the URL.
    func openConnectionURL(_ text: String) {
        guard let parsed = ConnectionURL.parse(text) else {
            Alerts.showError(DatabaseError.unsupported("Foxlume Query cannot open “\(text)”."), title: "Unsupported link", in: NSApp.keyWindow)
            return
        }
        if parsed.config.kind.isFileBased {
            openDatabaseFile(URL(fileURLWithPath: parsed.config.filePath))
            return
        }
        connect(parsed.config, password: parsed.password, tlsSecret: parsed.tlsSecret)
    }

    // MARK: Welcome

    @objc func showWelcome(_ sender: Any?) {
        if welcome == nil {
            let controller = WelcomeWindowController()
            controller.model.onConnect = { [weak self] config in self?.connect(config) }
            controller.model.onNew = { [weak self] in self?.newConnection(nil) }
            controller.model.onEdit = { [weak self] config in self?.editConnection(config) }
            controller.model.onOpenFile = { [weak self] in self?.openDocument(nil) }
            welcome = controller
        }
        welcome?.model.reload()
        welcome?.showWindow(nil)
        welcome?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func newConnection(_ sender: Any?) {
        presentForm(for: nil)
    }

    func editConnection(_ config: ConnectionConfig) {
        presentForm(for: config)
    }

    @discardableResult
    func presentForm(for config: ConnectionConfig?) -> ConnectionFormController {
        let parent = welcome?.window?.isVisible == true ? welcome?.window : NSApp.keyWindow
        let form = ConnectionFormController(config: config, parent: parent) { [weak self] saved, connect in
            self?.welcome?.model.selection = saved.id
            if connect { self?.connect(saved) }
        }
        form.present()
        return form
    }

    /// ⌘O: SQL files open in a query tab of the front connection; database files open as connections.
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose a .sql file, a SQLite or DuckDB database, or a Parquet, CSV or JSON file"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if ["sql", "psql", "pgsql", "txt", "mql", "redis"].contains(url.pathExtension.lowercased()) {
                openSQLFile(url)
            } else {
                openDatabaseFile(url)
            }
        }
    }

    private func openSQLFile(_ url: URL) {
        guard let workspace = activeWorkspace else {
            Alerts.showError(DatabaseError.unsupported("Connect to a database first, then open \(url.lastPathComponent) in it."), title: "No open connection", in: NSApp.keyWindow)
            return
        }
        do {
            let sql = try String(contentsOf: url, encoding: .utf8)
            workspace.tabs.openQuery(sql: sql, fileURL: url)
            workspace.window?.makeKeyAndOrderFront(nil)
        } catch {
            Alerts.showError(error, title: "Could not open \(url.lastPathComponent)", in: workspace.window)
        }
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(nil)
    }

    /// View › Word Wrap (⌥Z): the Settings value, so every query editor follows and the choice outlives the app.
    @objc func toggleWordWrap(_ sender: Any?) {
        AppEnvironment.settings.editorWordWrap.toggle()
    }

    /// Older versions saved a MongoDB URI with its password in connections.json; keep the password in the Keychain instead.
    private func moveEmbeddedPasswordsToCredentialStore() {
        for saved in AppEnvironment.connections.all() {
            var config = saved
            guard let password = config.removeEmbeddedPassword() else { continue }
            do {
                if (AppEnvironment.credentials.password(for: config.id) ?? "").isEmpty {
                    try AppEnvironment.credentials.setPassword(password, for: config.id)
                }
                try AppEnvironment.connections.save(config)
            } catch {
                // Leave the connection as it was; it still works with the embedded password.
            }
        }
    }

    private func reportUnreadableConnections() {
        guard let aside = AppEnvironment.connections.setAsideFile else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some saved connections could not be read"
        alert.informativeText = "The connection list was damaged. Connections that could still be read are kept, and the original file was saved as “\(aside.lastPathComponent)” in the app's data folder so nothing is lost."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show File")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([aside])
        }
    }

    static let projectURL = URL(string: "https://github.com/dannymaster1995-developer/foxlume-query")!

    @objc func openProjectPage(_ sender: Any?) {
        NSWorkspace.shared.open(Self.projectURL)
    }

    @objc func reportIssue(_ sender: Any?) {
        NSWorkspace.shared.open(Self.projectURL.appendingPathComponent("issues/new/choose"))
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: """
            A native macOS database client for PostgreSQL, MySQL, MariaDB, SQLite, DuckDB, MongoDB and Redis.
            Free software under the GNU AGPL v3 or later. Inspired by TablePro (github.com/TableProApp/TablePro); not affiliated with it.
            Includes DuckDB (MIT License, Stichting DuckDB Foundation).
            """,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Foxlume Query",
            .applicationVersion: AppEnvironment.appVersion,
            .credits: credits,
        ])
    }

    // MARK: Connecting

    /// Opens a SQLite file, reusing a saved connection for the same path when there is one.
    func openDatabaseFile(_ url: URL) {
        let path = url.standardizedFileURL.path
        let kind: DatabaseKind = ["duckdb", "ddb", "parquet", "csv", "tsv", "json", "ndjson"].contains(url.pathExtension.lowercased()) ? .duckdb : .sqlite
        if let existing = AppEnvironment.connections.all().first(where: { $0.kind.isFileBased && ($0.filePath as NSString).standardizingPath == path }) {
            connect(existing)
            return
        }
        let config = ConnectionConfig(name: url.deletingPathExtension().lastPathComponent, kind: kind, filePath: path)
        try? AppEnvironment.connections.save(config)
        connect(config)
    }

    func connect(_ config: ConnectionConfig, password overridePassword: String? = nil, tlsSecret overrideTLSSecret: String? = nil, completion: ((WorkspaceWindowController?) -> Void)? = nil) {
        if let open = workspaces.first(where: { $0.workspace.config.id == config.id }) {
            open.window?.makeKeyAndOrderFront(nil)
            completion?(open)
            return
        }
        let password = overridePassword ?? AppEnvironment.credentials.password(for: config.id) ?? ""
        let sshSecret = AppEnvironment.credentials.sshSecret(for: config.id)
        let tlsSecret = overrideTLSSecret ?? AppEnvironment.credentials.tlsSecret(for: config.id)
        let workspace = ConnectionWorkspace(config: config, password: password, sshSecret: sshSecret, tlsSecret: tlsSecret)
        welcome?.model.connectingID = config.id
        Task {
            do {
                try await workspace.connect()
                welcome?.model.connectingID = nil
                let controller = WorkspaceWindowController(workspace: workspace)
                controller.onClose = { [weak self] closed in
                    guard let self else { return }
                    self.workspaces.removeAll { $0 === closed }
                    if self.workspaces.isEmpty, !(NSApp.windows.contains { $0.isVisible && $0 !== closed.window }) {
                        self.showWelcome(nil)
                    }
                }
                workspaces.append(controller)
                controller.tabs.restoreState()
                controller.clampToScreen()
                controller.showWindow(nil)
                controller.window?.makeKeyAndOrderFront(nil)
                welcome?.window?.orderOut(nil)
                completion?(controller)
            } catch {
                welcome?.model.connectingID = nil
                await workspace.disconnect()
                let window = welcome?.window?.isVisible == true ? welcome?.window : NSApp.keyWindow
                Alerts.showError(error, title: "Could not connect to \(config.displayName)", in: window)
                completion?(nil)
            }
        }
    }

    var activeWorkspace: WorkspaceWindowController? {
        workspaces.first { $0.window?.isKeyWindow == true } ?? workspaces.last
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Ticks View › Word Wrap; every other item the delegate handles stays enabled.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleWordWrap(_:)) {
            menuItem.state = AppEnvironment.settings.editorWordWrap ? .on : .off
        }
        return true
    }
}

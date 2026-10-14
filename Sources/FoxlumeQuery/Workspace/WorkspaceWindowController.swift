import AppKit
import FoxlumeQueryCore
import UniformTypeIdentifiers

private extension NSToolbarItem.Identifier {
    static let database = NSToolbarItem.Identifier("eq.database")
    static let refresh = NSToolbarItem.Identifier("eq.refresh")
    static let status = NSToolbarItem.Identifier("eq.status")
    static let newQuery = NSToolbarItem.Identifier("eq.newQuery")
    static let history = NSToolbarItem.Identifier("eq.history")
}

/// One window per open connection: sidebar, tabs and an optional history panel.
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let workspace: ConnectionWorkspace
    let tabs: TabsViewController
    private let sidebar: SidebarViewController
    private let history: HistoryViewController
    private let split = NSSplitViewController()
    private var historyItem: NSSplitViewItem?
    private let statusView = ToolbarStatusView()
    private let databasePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var onClose: ((WorkspaceWindowController) -> Void)?
    private var closingConfirmed = false

    init(workspace: ConnectionWorkspace) {
        self.workspace = workspace
        self.tabs = TabsViewController(workspace: workspace)
        self.sidebar = SidebarViewController(workspace: workspace)
        self.history = HistoryViewController(workspace: workspace)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = workspace.config.displayName
        window.subtitle = workspace.config.kind.isFileBased ? workspace.config.filePath : workspace.config.subtitle
        window.minSize = NSSize(width: 760, height: 480)
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.titlebarSeparatorStyle = .line
        window.backgroundColor = Theme.windowBackdrop
        window.setAccessibilityIdentifier("workspaceWindow")
        super.init(window: window)
        window.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: tabs)
        contentItem.minimumThickness = 400
        let historyItem = NSSplitViewItem(viewController: history)
        historyItem.minimumThickness = 240
        historyItem.maximumThickness = 480
        historyItem.canCollapse = true
        historyItem.isCollapsed = true
        self.historyItem = historyItem
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.addSplitViewItem(historyItem)
        split.splitView.dividerStyle = .thin
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()

        sidebar.onOpenTable = { [weak self] table, newTab in self?.openFromSidebar(table, newTab: newTab) }
        sidebar.onOpenKey = { [weak self] key, type, newTab in self?.openKey(key, type: type, newTab: newTab) }
        sidebar.onFilterKeys = { [weak self] pattern in self?.browseKeys(matching: pattern) }
        sidebar.onOpenStructure = { [weak self] table in self?.tabs.openTable(table, newTab: true, mode: .structure) }
        sidebar.onTableOperation = { [weak self] info, operation in self?.toggleTableOperation(info, operation) }
        sidebar.onRename = { [weak self] info in self?.renameObject(info) }
        sidebar.onExport = { [weak self] table in self?.presentExport(preselecting: table.map { [$0] } ?? []) }
        sidebar.onImportCSV = { [weak self] table in self?.presentImportCSV(into: table) }
        sidebar.onRunSQLFile = { [weak self] in self?.presentRunSQLFile(file: nil) }
        sidebar.onNewTable = { [weak self] in self?.newTable(nil) }
        sidebar.onQueryTable = { [weak self] table in
            guard let self else { return }
            let sql = "SELECT * FROM \(self.workspace.dialect.qualifiedName(table)) LIMIT 100;"
            self.tabs.openQuery(sql: sql, run: true)
        }
        history.onOpen = { [weak self] sql, run in
            guard let self else { return }
            if !run, let query = self.tabs.selectedTab?.content as? QueryTabViewController, query.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                query.setSQL(sql)
            } else {
                self.tabs.openQuery(sql: sql, run: run)
            }
        }
        tabs.onSelectionChange = { [weak self] tab in
            if let table = tab?.table { self?.sidebar.select(table) }
        }

        statusView.onReconnect = { [weak self] in self?.reconnect(nil) }
        configureToolbar()
        NotificationCenter.default.addObserver(self, selector: #selector(workspaceChanged), name: ConnectionWorkspace.metadataDidChange, object: workspace)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: ThemeManager.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(workspaceChanged), name: ConnectionWorkspace.activityDidChange, object: workspace)
        workspaceChanged()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Toolbar

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "FoxlumeQueryWorkspaceToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified

        databasePopup.controlSize = .regular
        databasePopup.target = self
        databasePopup.action = #selector(databaseChosen(_:))
        databasePopup.toolTip = "Switch database"
        databasePopup.setAccessibilityIdentifier("databaseSwitcher")
    }

    @objc private func workspaceChanged() {
        statusView.update(with: workspace)
        if !workspace.kind.isFileBased {
            var shown = workspace.config
            if let current = workspace.currentDatabase {
                // Redis reports "db1"; the config, like a redis:// URL, keeps the bare index.
                shown.database = workspace.kind == .redis && current.hasPrefix("db") ? String(current.dropFirst(2)) : current
            }
            window?.subtitle = shown.subtitle
        }
        databasePopup.removeAllItems()
        let names = workspace.databases.isEmpty ? [workspace.currentDatabase ?? workspace.config.database].filter { !$0.isEmpty } : workspace.databases
        databasePopup.addItems(withTitles: names)
        if let current = workspace.currentDatabase { databasePopup.selectItem(withTitle: current) }
        databasePopup.isEnabled = names.count > 1
    }

    @objc private func databaseChosen(_ sender: Any?) {
        guard let name = databasePopup.titleOfSelectedItem, name != workspace.currentDatabase else { return }
        guard !tabs.hasUnsavedTableEdits, workspace.pendingTableOperations.isEmpty else {
            workspaceChanged()
            Alerts.showError(DatabaseError.unsupported("Save or discard the edits in your open tables and the pending truncates and drops before switching database."), title: "Unsaved changes", in: window)
            return
        }
        Task {
            do {
                try await workspace.switchDatabase(name)
                tabs.closeTableTabs()
            } catch {
                workspaceChanged()
                Alerts.showError(error, title: "Could not switch database", in: window)
            }
        }
    }

    @objc private func themeChanged() {
        window?.backgroundColor = Theme.windowBackdrop
        window?.contentView?.needsDisplay = true
    }

    // MARK: Sidebar

    /// Redis database rows switch the session's database before showing its keys, as TablePro does.
    private func openFromSidebar(_ table: TableRef, newTab: Bool) {
        guard workspace.tables.first(where: { $0.ref == table })?.kind == .keyspace, table.name != workspace.currentDatabase else {
            tabs.openTable(table, newTab: newTab)
            return
        }
        Task {
            do {
                try await workspace.switchDatabase(table.name)
                tabs.openTable(table, newTab: newTab)
            } catch {
                Alerts.showError(error, title: "Could not switch database", in: window)
            }
        }
    }

    func openKey(_ key: String, type: String, newTab: Bool) {
        let quoted = Self.redisQuoted(key)
        let command: String
        switch type.lowercased() {
        case "hash": command = "HGETALL \(quoted)"
        case "list": command = "LRANGE \(quoted) 0 -1"
        case "set": command = "SMEMBERS \(quoted)"
        case "zset": command = "ZRANGE \(quoted) 0 -1 WITHSCORES"
        case "stream": command = "XRANGE \(quoted) - +"
        default: command = "GET \(quoted)"
        }
        if !newTab, let open = tabs.tabs.first(where: { ($0.content as? QueryTabViewController)?.tabTitle == key }) {
            tabs.select(id: open.id)
            return
        }
        tabs.openQuery(sql: command, run: true, title: key)
    }

    /// Shows the current database's key grid filtered by `pattern`.
    private func browseKeys(matching pattern: String) {
        guard let database = workspace.currentDatabase else { return }
        let ref = TableRef(name: database)
        tabs.openTable(ref, newTab: false)
        (tabs.selectedTab?.content as? TableTabViewController)?.applyFilters([], raw: pattern)
    }

    /// Quotes a Redis argument the way redis-cli parses it.
    static func redisQuoted(_ value: String) -> String {
        let needsQuotes = value.isEmpty || value.contains { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == ";" || $0 == "\\" }
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Connection

    @objc func reconnect(_ sender: Any?) {
        Task {
            do {
                try await workspace.reconnect()
            } catch {
                Alerts.showError(error, title: "Could not reconnect to \(workspace.config.displayName)", in: window)
            }
        }
    }

    /// Closes the link and keeps the window and its tabs; Reconnect, or running anything, opens it again.
    @objc func disconnect(_ sender: Any?) {
        guard workspace.connectionState == .connected else { return }
        workspace.cancelEverything()
        Task { await workspace.disconnectKeepingWindow() }
    }

    // MARK: Truncate, Drop and Rename

    /// Stages a truncate or drop after asking for its options; choosing it again unstages it.
    func toggleTableOperation(_ info: TableInfo, _ operation: TableOperationKind, options preset: TableOperationOptions? = nil) {
        if workspace.pendingOperation(for: info.ref)?.operation == operation {
            workspace.unstage(info.ref)
            return
        }
        let stage: (TableOperationOptions) -> Void = { [weak self] options in
            self?.workspace.stage(PendingTableOperation(table: info.ref, objectKind: info.kind, operation: operation, options: options))
        }
        if let preset { return stage(preset) }
        TableOperationAlert.present(operation, table: info, sql: workspace.tableOperations, in: window) { options in
            if let options { stage(options) }
        }
    }

    func renameObject(_ info: TableInfo, to presetName: String? = nil) {
        let perform: (String) -> Void = { [weak self] name in
            guard let self else { return }
            guard !self.tabs.tabs.contains(where: { $0.table == info.ref && $0.content.hasUnsavedChanges }) else {
                Alerts.showError(DatabaseError.unsupported("Save or discard the edits to “\(info.name)” before renaming it."), title: "Unsaved changes", in: self.window)
                return
            }
            let statement = self.workspace.tableOperations.renameStatement(info.ref, objectKind: info.kind, to: name)
            SafeModeGate.authorize(config: self.workspace.config, statements: statement.map { [$0] } ?? [], writes: true, action: "Rename “\(info.name)” to “\(name)”", in: self.window) { confirmed in
                guard confirmed else { return }
                Task {
                    do {
                        try await self.workspace.rename(info.ref, objectKind: info.kind, to: name)
                        let wasOpen = self.tabs.tabs.contains { $0.table == info.ref }
                        self.tabs.closeTabs(showing: info.ref)
                        if wasOpen { self.tabs.openTable(TableRef(schema: info.ref.schema, name: name), newTab: true) }
                    } catch {
                        Alerts.showError(error, title: "Could not rename “\(info.name)”", in: self.window)
                    }
                }
            }
        }
        if let presetName { return perform(presetName) }
        RenamePrompt.present(info, sql: workspace.tableOperations, in: window) { name in
            if let name { perform(name) }
        }
    }

    /// ⌘S: the staged truncates and drops, then the selected tab's own save.
    @objc func saveAll(_ sender: Any?) {
        let operations = workspace.pendingTableOperations
        guard !operations.isEmpty else {
            forwardToSelectedTab(#selector(FoxlumeQueryActions.saveChanges(_:)), sender)
            return
        }
        let apply = { [weak self] in self?.applyTableOperations(sender) }
        SafeModeGate.authorize(
            config: workspace.config,
            statements: workspace.pendingTableOperationPlan.all,
            writes: true,
            action: "Run \(operations.count) table operation\(operations.count == 1 ? "" : "s")",
            in: window
        ) { confirmed in
            if confirmed { apply() }
        }
    }

    private func applyTableOperations(_ sender: Any?) {
        Task {
            do {
                let done = try await workspace.applyPendingTableOperations()
                for operation in done {
                    switch operation.operation {
                    case .drop: tabs.closeTabs(showing: operation.table)
                    case .truncate: tabs.reloadTabs(showing: operation.table)
                    }
                }
                // Grid edits in the table in front are saved too, as one Save in TablePro does.
                if let table = tabs.selectedTab?.content as? TableTabViewController, table.hasUnsavedChanges {
                    table.saveChanges(sender)
                }
            } catch {
                Alerts.showError(error, title: "The pending operations did not finish", in: window)
            }
        }
    }

    @objc func discardAll(_ sender: Any?) {
        workspace.discardPendingTableOperations()
        forwardToSelectedTab(#selector(FoxlumeQueryActions.discardChanges(_:)), sender)
    }

    /// ⇧⌘P: the statements Save would run.
    @objc func previewSQL(_ sender: Any?) {
        guard let window else { return }
        var parts: [String] = []
        let plan = workspace.pendingTableOperationPlan
        if !plan.isEmpty { parts.append(statementsText(plan.all)) }
        if let table = tabs.selectedTab?.content as? TableTabViewController, let preview = table.previewOfPendingChanges() {
            parts.append(preview)
        }
        let comment = workspace.kind.isSQL ? "--" : "//"
        let text = parts.isEmpty ? "\(comment) No pending changes" : parts.joined(separator: "\n\n")
        SQLPreviewSheet(text: text, language: workspace.queryLanguage).begin(for: window)
    }

    private func statementsText(_ statements: [String]) -> String {
        let terminator = workspace.kind.isSQL ? ";" : ""
        return statements.map { $0 + terminator }.joined(separator: "\n")
    }

    private func forwardToSelectedTab(_ action: Selector, _ sender: Any?) {
        guard let content = tabs.selectedTab?.content, content.responds(to: action) else { return }
        NSApp.sendAction(action, to: content, from: sender)
    }

    private func selectedTabValidates(_ action: Selector) -> Bool {
        guard let content = tabs.selectedTab?.content, content.responds(to: action) else { return false }
        let probe = NSMenuItem(title: "", action: action, keyEquivalent: "")
        return (content as? NSMenuItemValidation)?.validateMenuItem(probe) ?? true
    }

    // MARK: Actions

    @objc func newQueryTab(_ sender: Any?) {
        tabs.openQuery()
    }

    @objc func openSQLFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            for url in panel.urls {
                do {
                    let sql = try String(contentsOf: url, encoding: .utf8)
                    self.tabs.openQuery(sql: sql, fileURL: url)
                } catch {
                    Alerts.showError(error, title: "Could not open \(url.lastPathComponent)", in: window)
                }
            }
        }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        tabs.reopenClosedTab()
    }

    /// Opens the toolbar's database menu (⌘K).
    @objc func showDatabaseSwitcher(_ sender: Any?) {
        guard databasePopup.window != nil, databasePopup.isEnabled else { return NSSound.beep() }
        databasePopup.performClick(nil)
    }

    @objc func closeTab(_ sender: Any?) {
        if !tabs.closeSelected() {
            window?.performClose(sender)
        }
    }

    @objc func toggleHistory(_ sender: Any?) {
        guard let historyItem else { return }
        historyItem.animator().isCollapsed.toggle()
    }

    @objc func refreshMetadata(_ sender: Any?) {
        Task { await workspace.refreshMetadata() }
    }

    @objc func focusTableFilter(_ sender: Any?) {
        if let sidebarItem = split.splitViewItems.first, sidebarItem.isCollapsed {
            sidebarItem.isCollapsed = false
        }
        sidebar.focusFilter()
    }

    func sidebarMenuTitles(for info: TableInfo) -> [String] {
        sidebar.select(info.ref)
        return sidebar.menuTitlesForSelection()
    }

    func sidebarBackgroundMenuTitles() -> [String] {
        sidebar.menuTitlesForBackground()
    }

    func applySidebarFilter(_ text: String) {
        sidebar.setFilter(text)
    }

    /// The table selected in the sidebar, which File menu commands act on.
    var sidebarSelection: TableRef? { sidebar.selectedTable }

    @objc func selectNextTab(_ sender: Any?) { tabs.selectNext(offset: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { tabs.selectNext(offset: -1) }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        let index = sender.tag - 1
        if sender.tag == 9 {
            tabs.selectTab(at: tabs.tabs.count - 1)
        } else {
            tabs.selectTab(at: index)
        }
    }

    @objc func toggleSidebar(_ sender: Any?) {
        split.toggleSidebar(sender)
    }

    /// Lets menu commands reach the selected tab even when focus is in the sidebar or history panel.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let content = tabs.selectedTab?.content, content.responds(to: action) {
            return content
        }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard tabs.hasUnsavedChanges, !closingConfirmed else { return true }
        Alerts.confirm("Close this connection and discard unsaved changes?", detail: "Some tables have edits that were not saved.", confirmTitle: "Discard and Close", destructive: true, in: window) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.closingConfirmed = true
            self.window?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        tabs.saveState()
        workspace.cancelEverything()
        let workspace = self.workspace
        Task { await workspace.disconnect() }
        onClose?(self)
    }
}

extension WorkspaceWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let transfer = validateTransferItem(menuItem.action) { return transfer }
        let hasOperations = !workspace.pendingTableOperations.isEmpty
        switch menuItem.action {
        case #selector(saveAll(_:)):
            return hasOperations || selectedTabValidates(#selector(FoxlumeQueryActions.saveChanges(_:)))
        case #selector(discardAll(_:)):
            return hasOperations || selectedTabValidates(#selector(FoxlumeQueryActions.discardChanges(_:)))
        case #selector(newDatabase(_:)), #selector(dropDatabase(_:)):
            return databaseObjects.canManageDatabases && !workspace.isReadOnly && workspace.connectionState == .connected
        case #selector(newSchema(_:)), #selector(dropSchema(_:)):
            return databaseObjects.canManageSchemas && !workspace.isReadOnly && workspace.connectionState == .connected
        case #selector(newTable(_:)):
            return workspace.canChangeStructure && workspace.connectionState == .connected
        case #selector(disconnect(_:)):
            return workspace.connectionState == .connected
        case #selector(reconnect(_:)):
            return workspace.connectionState != .reconnecting
        default:
            return true
        }
    }
}

extension WorkspaceWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var items: [NSToolbarItem.Identifier] = [.toggleSidebar, .sidebarTrackingSeparator]
        if workspace.kind.supportsMultipleDatabases && workspace.capabilities.supportsDatabaseSwitching { items.append(.database) }
        items += [.refresh, .flexibleSpace, .status, .flexibleSpace, .newQuery, .history]
        return items
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .database:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Database"
            item.view = databasePopup
            return item
        case .refresh:
            return button(itemIdentifier, "Refresh", "arrow.clockwise", #selector(refreshMetadata(_:)))
        case .status:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Connection"
            item.view = statusView
            item.visibilityPriority = .high
            return item
        case .newQuery:
            return button(itemIdentifier, "New Query", "plus.rectangle.on.rectangle", #selector(newQueryTab(_:)))
        case .history:
            return button(itemIdentifier, "History", "clock.arrow.circlepath", #selector(toggleHistory(_:)))
        default:
            return nil
        }
    }

    private func button(_ identifier: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = label
        item.image = Theme.image(symbol, label)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }
}

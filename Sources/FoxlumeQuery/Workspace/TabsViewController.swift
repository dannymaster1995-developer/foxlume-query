import AppKit
import FoxlumeQueryCore

/// Content shown inside one tab.
@MainActor
protocol WorkspaceTabContent: NSViewController {
    var tabTitle: String { get }
    var tabSymbol: String { get }
    var hasUnsavedChanges: Bool { get }
    var onStateChange: (() -> Void)? { get set }
}

@MainActor
final class WorkspaceTab {
    let id: UUID
    let content: WorkspaceTabContent
    var isPreview: Bool

    /// `id` is kept when a tab's content is replaced in place, so the strip keeps its position and recency.
    init(content: WorkspaceTabContent, isPreview: Bool, id: UUID = UUID()) {
        self.id = id
        self.content = content
        self.isPreview = isPreview
    }

    var table: TableRef? { (content as? TableTabViewController)?.table }
}

/// Tab strip plus the selected tab's content.
@MainActor
final class TabsViewController: NSViewController {
    let workspace: ConnectionWorkspace
    private(set) var tabs: [WorkspaceTab] = []
    private(set) var selectedTab: WorkspaceTab?
    /// The tab strip; it shows the tabs that fit and lists the rest behind "+N".
    let strip = TabStripView()
    /// The window's tabs, most recently selected first, which decides the ones the strip keeps in view.
    private var recency = TabRecency<UUID>()
    private let container = NSView()
    private let emptyState = NSStackView()
    private var queryCounter = 0
    /// Recently closed tabs, newest last, for Reopen Closed Tab.
    private var closedTabs: [(table: TableRef?, sql: String?, title: String?, fileURL: URL?)] = []
    var onSelectionChange: ((WorkspaceTab?) -> Void)?
    /// Where a source tab's Edit in Query Tab goes; set by the window.
    var onObjectCommand: ((SchemaObjectCommand) -> Void)?
    /// A New View… or Edit View… tab created or replaced this view.
    var onViewSaved: ((TableRef) -> Void)?

    init(workspace: ConnectionWorkspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(strip)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: strip.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        let icon = NSImageView(image: Theme.image("tablecells", "", size: 40, weight: .ultraLight) ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor
        let title = UI.label("Select a table to view its data", size: 15, weight: .medium, color: .secondaryLabelColor)
        let hint = UI.label("or press ⌘T to open a SQL query tab", size: 12, color: .tertiaryLabelColor)
        let button = UI.button("New Query", symbol: "plus", target: self, action: #selector(newQueryClicked(_:)))
        emptyState.orientation = .vertical
        emptyState.spacing = 8
        emptyState.setViews([icon, title, hint, button], in: .center)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        strip.onSelect = { [weak self] id in self?.select(id: id) }
        strip.onClose = { [weak self] id in self?.close(id: id) }
        strip.onAdd = { [weak self] in self?.openQuery() }
        strip.onPin = { [weak self] id in
            self?.tabs.first { $0.id == id }?.isPreview = false
            self?.refreshStrip()
        }
        view = root
        refreshStrip()
    }

    @objc private func newQueryClicked(_ sender: Any?) {
        openQuery()
    }

    // MARK: Opening

    /// Opens a table. A single click reuses the preview tab; `newTab` keeps existing tabs.
    func openTable(_ table: TableRef, newTab: Bool = false, mode: TableTabViewController.Mode = .data, filters: [FilterRule]? = nil) {
        if let existing = tabs.first(where: { $0.table == table }) {
            if newTab { existing.isPreview = false }
            select(id: existing.id)
            (existing.content as? TableTabViewController)?.setMode(mode)
            if let filters { (existing.content as? TableTabViewController)?.applyFilters(filters, raw: "") }
            return
        }
        let controller = makeTableTab(table, mode: mode, filters: filters ?? [])
        if !newTab, let preview = tabs.firstIndex(where: { $0.isPreview && !$0.content.hasUnsavedChanges }) {
            let old = tabs[preview]
            let tab = WorkspaceTab(content: controller, isPreview: true)
            tabs[preview] = tab
            recency.remove(old.id)
            detach(old)
            install(tab)
            select(id: tab.id)
            return
        }
        let tab = WorkspaceTab(content: controller, isPreview: !newTab)
        tabs.append(tab)
        install(tab)
        select(id: tab.id)
    }

    private func makeTableTab(_ table: TableRef, mode: TableTabViewController.Mode, filters: [FilterRule]) -> TableTabViewController {
        let controller = TableTabViewController(workspace: workspace, table: table, initialMode: mode, initialFilters: filters)
        controller.onOpenReference = { [weak self] referenced, rules in
            self?.openTable(referenced, newTab: true, filters: rules)
        }
        return controller
    }

    @discardableResult
    func openQuery(sql: String = "", run: Bool = false, title: String? = nil, fileURL: URL? = nil, viewEditor: ViewEditorContext? = nil) -> QueryTabViewController {
        queryCounter += 1
        let controller = QueryTabViewController(workspace: workspace, title: title ?? "Query \(queryCounter)", sql: sql, fileURL: fileURL)
        if let viewEditor {
            controller.viewEditor = viewEditor
            controller.onViewSaved = { [weak self] view in self?.onViewSaved?(view) }
        }
        let tab = WorkspaceTab(content: controller, isPreview: false)
        tabs.append(tab)
        install(tab)
        select(id: tab.id)
        if run { controller.runAll(nil) }
        return controller
    }

    /// Shows an object's source in its own tab; an object already open gets its tab focused.
    @discardableResult
    func openObjectSource(_ object: SchemaObject) -> ObjectSourceViewController {
        if let existing = tabs.first(where: { ($0.content as? ObjectSourceViewController)?.object.id == object.id }),
           let controller = existing.content as? ObjectSourceViewController {
            select(id: existing.id)
            // A tab that could not read the source (restored before the object existed, say) tries again.
            if controller.loadError != nil { controller.reload(nil) }
            return controller
        }
        let controller = makeObjectSourceTab(object)
        let tab = WorkspaceTab(content: controller, isPreview: false)
        tabs.append(tab)
        install(tab)
        select(id: tab.id)
        return controller
    }

    private func makeObjectSourceTab(_ object: SchemaObject) -> ObjectSourceViewController {
        let controller = ObjectSourceViewController(workspace: workspace, object: object)
        controller.onCommand = { [weak self] command in self?.onObjectCommand?(command) }
        return controller
    }

    /// Opens the ER diagram of a schema, or selects the one already open, and focuses `table` in it.
    @discardableResult
    func openERDiagram(database: String?, schema: String?, focusing table: String? = nil) -> ERDiagramViewController {
        if let existing = tabs.first(where: { ($0.content as? ERDiagramViewController)?.matches(database: database, schema: schema) == true }),
           let controller = existing.content as? ERDiagramViewController {
            select(id: existing.id)
            if let table { controller.focus(table: table) }
            return controller
        }
        let controller = makeERDiagramTab(database: database, schema: schema)
        if let table { controller.focus(table: table) }
        let tab = WorkspaceTab(content: controller, isPreview: false)
        tabs.append(tab)
        install(tab)
        select(id: tab.id)
        return controller
    }

    private func makeERDiagramTab(database: String?, schema: String?) -> ERDiagramViewController {
        let controller = ERDiagramViewController(workspace: workspace, database: database, schema: schema)
        controller.onOpenTable = { [weak self] ref in self?.openTable(ref, newTab: true) }
        controller.onShowStructure = { [weak self] ref in self?.openTable(ref, newTab: true, mode: .structure) }
        return controller
    }

    /// After a schema or database was renamed, tabs showing it are rebuilt in place for the new name: table tabs keep
    /// their mode and filter rules, ER diagrams and object sources show the renamed schema. Tabs with unsaved edits
    /// must be saved or discarded first (the caller checks `hasUnsavedEdits(affectedBy:)`).
    func retarget(_ rename: StoredStateRename) {
        let connection = workspace.config.id
        for index in tabs.indices {
            let tab = tabs[index]
            let replacement: WorkspaceTabContent
            if let table = tab.content as? TableTabViewController {
                let ref: TableRef
                if let renamed = rename.renamed(table.table) {
                    ref = renamed
                } else if case .database(_, let from, _) = rename, table.openedDatabase == from {
                    ref = table.table
                } else {
                    continue
                }
                replacement = makeTableTab(ref, mode: table.mode, filters: table.appliedFilterRules)
            } else if let diagram = tab.content as? ERDiagramViewController,
                      let scope = rename.renamed(ERDiagramScope(connectionID: connection, database: diagram.database, schema: diagram.schema)) {
                replacement = makeERDiagramTab(database: scope.database, schema: scope.schema)
            } else if let source = tab.content as? ObjectSourceViewController, case .schema(_, _, let from, let to) = rename, source.object.schema == from {
                var object = source.object
                object.schema = to
                replacement = makeObjectSourceTab(object)
            } else {
                continue
            }
            let updated = WorkspaceTab(content: replacement, isPreview: tab.isPreview, id: tab.id)
            let wasSelected = tab === selectedTab
            if wasSelected { selectedTab = nil }
            detach(tab)
            tabs[index] = updated
            install(updated)
            if wasSelected { select(id: updated.id) }
        }
        closedTabs = closedTabs.map { closed in
            guard let table = closed.table, let renamed = rename.renamed(table) else { return closed }
            return (renamed, closed.sql, closed.title, closed.fileURL)
        }
        refreshStrip()
    }

    /// Whether a tab that `retarget(rename)` would rebuild has unsaved edits.
    func hasUnsavedEdits(affectedBy rename: StoredStateRename) -> Bool {
        tabs.contains { tab in
            guard tab.content.hasUnsavedChanges, let table = tab.content as? TableTabViewController else { return false }
            if rename.renamed(table.table) != nil { return true }
            if case .database(_, let from, _) = rename { return table.openedDatabase == from }
            return false
        }
    }

    /// Closes the source tabs of an object after it was dropped.
    func closeObjectTabs(_ object: SchemaObject) {
        for index in tabs.indices.reversed() where (tabs[index].content as? ObjectSourceViewController)?.object.id == object.id {
            remove(at: index)
        }
    }

    private func install(_ tab: WorkspaceTab) {
        addChild(tab.content)
        tab.content.onStateChange = { [weak self] in self?.refreshStrip() }
    }

    private func detach(_ tab: WorkspaceTab) {
        tab.content.view.removeFromSuperview()
        tab.content.removeFromParent()
    }

    // MARK: Selection

    func select(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if selectedTab !== tab {
            selectedTab?.content.view.removeFromSuperview()
            selectedTab = tab
            container.addSubviewFilling(tab.content.view)
        }
        recency.use(tab.id)
        emptyState.isHidden = true
        refreshStrip()
        onSelectionChange?(tab)
        DispatchQueue.main.async { [weak tab] in
            (tab?.content as? QueryTabViewController)?.focusEditor()
        }
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(id: tabs[index].id)
    }

    func selectNext(offset: Int) {
        guard let selectedTab, let index = tabs.firstIndex(where: { $0 === selectedTab }), !tabs.isEmpty else { return }
        select(id: tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    // MARK: Closing

    func close(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        if tab.content.hasUnsavedChanges {
            Alerts.confirm(
                "Close “\(tab.content.tabTitle)” and discard unsaved changes?",
                detail: "Unsaved changes in this tab will be lost.",
                confirmTitle: "Discard Changes",
                destructive: true,
                in: view.window
            ) { [weak self] confirmed in
                if confirmed { self?.remove(at: index) }
            }
            return
        }
        remove(at: index)
    }

    /// The window closes: the query tabs' GitHub Copilot documents are closed at the language server.
    func retireInlineSuggestions() {
        for tab in tabs {
            (tab.content as? QueryTabViewController)?.inlineSourceCache.retire()
        }
    }

    private func remove(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs.remove(at: index)
        recency.remove(tab.id)
        if let query = tab.content as? QueryTabViewController {
            closedTabs.append((nil, query.sql, query.tabTitle, query.fileURL))
            // Its GitHub Copilot document is closed at the language server.
            query.inlineSourceCache.retire()
        } else if let table = tab.table {
            closedTabs.append((table, nil, nil, nil))
        }
        if closedTabs.count > 20 { closedTabs.removeFirst() }
        let wasSelected = tab === selectedTab
        detach(tab)
        if wasSelected {
            selectedTab = nil
            if tabs.isEmpty {
                emptyState.isHidden = false
                onSelectionChange?(nil)
            } else {
                select(id: tabs[min(index, tabs.count - 1)].id)
            }
        }
        refreshStrip()
    }

    /// Closes the selected tab; returns false when there was none.
    @discardableResult
    func closeSelected() -> Bool {
        guard let selectedTab else { return false }
        close(id: selectedTab.id)
        return true
    }

    var hasUnsavedChanges: Bool { tabs.contains { $0.content.hasUnsavedChanges } }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return NSSound.beep() }
        if let table = closed.table {
            openTable(table, newTab: true)
        } else {
            openQuery(sql: closed.sql ?? "", title: closed.title, fileURL: closed.fileURL)
        }
    }

    /// Grid edits only; edited .sql files survive a database switch.
    var hasUnsavedTableEdits: Bool { tabs.contains { $0.content is TableTabViewController && $0.content.hasUnsavedChanges } }

    /// Closes tabs showing `table` without asking, after it was dropped or renamed. They are not offered for reopening.
    func closeTabs(showing table: TableRef) {
        for index in tabs.indices.reversed() where tabs[index].table == table {
            remove(at: index)
            if closedTabs.last?.table == table { closedTabs.removeLast() }
        }
    }

    /// Reloads tabs showing `table`, dropping their edits, after its rows changed underneath them.
    func reloadTabs(showing table: TableRef) {
        for tab in tabs where tab.table == table {
            (tab.content as? TableTabViewController)?.reloadAfterExternalChange()
        }
        refreshStrip()
    }

    /// Table tabs show one database's rows, so they close when the database changes; so do its ER diagrams.
    func closeTableTabs() {
        for index in tabs.indices.reversed() where tabs[index].content is TableTabViewController || tabs[index].content is ERDiagramViewController {
            remove(at: index)
        }
    }

    // MARK: State

    private struct SavedState: Codable {
        struct Tab: Codable {
            var kind: String
            var title: String?
            var sql: String?
            var filePath: String?
            var schema: String?
            var name: String?
            /// A source tab: the object's kind, table (triggers) and arguments; `schema` and `name` hold the rest.
            var objectKind: String?
            var objectTable: String?
            var objectArguments: String?
            var objectIdentity: String?
            var objectDetail: String?
        }

        var tabs: [Tab]
        var selected: Int?
        var database: String?
    }

    private var stateURL: URL {
        AppPaths.tabStateDirectory.appendingPathComponent(workspace.config.id.uuidString + ".json")
    }

    /// Remembers open tabs so they come back the next time this connection opens.
    func saveState() {
        let saved = tabs.map { tab -> SavedState.Tab in
            if let query = tab.content as? QueryTabViewController {
                return SavedState.Tab(kind: "query", title: query.tabTitle, sql: query.sql, filePath: query.fileURL?.path)
            }
            if let diagram = tab.content as? ERDiagramViewController {
                return SavedState.Tab(kind: "diagram", schema: diagram.schema, name: diagram.database)
            }
            if let source = tab.content as? ObjectSourceViewController {
                let object = source.object
                return SavedState.Tab(kind: "object", schema: object.schema, name: object.name, objectKind: object.kind.rawValue,
                                      objectTable: object.table, objectArguments: object.arguments,
                                      objectIdentity: object.identityArguments, objectDetail: object.detail)
            }
            let table = tab.table
            return SavedState.Tab(kind: "table", schema: table?.schema, name: table?.name)
        }
        let selected = tabs.firstIndex { $0 === selectedTab }
        let state = SavedState(tabs: saved, selected: selected, database: workspace.currentDatabase)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    func restoreState() {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        guard state.database == nil || state.database == workspace.currentDatabase else { return }
        let known = Set(workspace.tables.map(\.ref))
        for tab in state.tabs {
            if tab.kind == "query" {
                openQuery(sql: tab.sql ?? "", title: tab.title, fileURL: tab.filePath.map { URL(fileURLWithPath: $0) })
            } else if tab.kind == "diagram" {
                // `name` holds the diagram's database; it comes back only for the database it showed.
                if workspace.supportsERDiagram, tab.name == workspace.currentDatabase {
                    openERDiagram(database: tab.name, schema: tab.schema)
                }
            } else if tab.kind == "object" {
                // The text is fetched again; an object that is gone shows "Source Unavailable".
                if let name = tab.name, let kind = tab.objectKind.flatMap(SchemaObjectKind.init(rawValue:)) {
                    openObjectSource(SchemaObject(kind: kind, schema: tab.schema, name: name, arguments: tab.objectArguments,
                                                  identityArguments: tab.objectIdentity, table: tab.objectTable, detail: tab.objectDetail))
                }
            } else if let name = tab.name {
                let ref = TableRef(schema: tab.schema, name: name)
                if known.contains(ref) { openTable(ref, newTab: true) }
            }
        }
        if let selected = state.selected { selectTab(at: min(selected, tabs.count - 1)) }
        queryCounter = max(queryCounter, tabs.count)
    }

    func refreshStrip() {
        let items = tabs.map {
            TabStripItem(id: $0.id, title: $0.content.tabTitle, symbol: $0.content.tabSymbol, isDirty: $0.content.hasUnsavedChanges, isPreview: $0.isPreview)
        }
        strip.update(items: items, selectedID: selectedTab?.id, recency: recency.ids)
        if let selectedTab, selectedTab.content.hasUnsavedChanges, selectedTab.isPreview {
            selectedTab.isPreview = false
            refreshStrip()
        }
    }
}

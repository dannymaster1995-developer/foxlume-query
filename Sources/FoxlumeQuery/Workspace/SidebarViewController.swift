import AppKit
import FoxlumeQueryCore

/// Table and view list for the current database / schema, with a filter field.
@MainActor
final class SidebarViewController: NSViewController {
    let workspace: ConnectionWorkspace
    var onOpenTable: ((TableRef, _ newTab: Bool) -> Void)?
    var onOpenStructure: ((TableRef) -> Void)?
    var onQueryTable: ((TableRef) -> Void)?
    /// A key in the key tree was chosen: open its value.
    var onOpenKey: ((_ key: String, _ type: String, _ newTab: Bool) -> Void)?
    /// A folder in the key tree was chosen: browse keys matching this glob.
    var onFilterKeys: ((String) -> Void)?
    /// Truncate or Drop chosen from the context menu (toggles when already staged).
    var onTableOperation: ((TableInfo, TableOperationKind) -> Void)?
    var onRename: ((TableInfo) -> Void)?
    /// Export Tables, with the clicked table ticked (nil from the empty area).
    var onExport: ((TableRef?) -> Void)?
    var onImportCSV: ((TableRef) -> Void)?
    var onRunSQLFile: (() -> Void)?
    /// "New Table…" from the context menu; offered only where structure can be changed.
    var onNewTable: (() -> Void)?
    /// New View…, Edit View… or Refresh Materialized View; see WorkspaceWindowController+Views.swift.
    var onViewCommand: ((ViewCommand) -> Void)?
    /// A procedure, function, trigger or type was opened (double-click, Return, Show Definition).
    var onOpenObject: ((SchemaObject) -> Void)?
    /// Copy Definition, Edit in Query Tab, Drop… or New Trigger… on an object or its group; see SidebarViewController+SchemaObjects.swift.
    var onObjectCommand: ((SchemaObjectCommand) -> Void)?
    /// ER Diagram (nil, from the empty area) or Show in ER Diagram (a table); see WorkspaceWindowController+Diagram.swift.
    var onShowERDiagram: ((TableRef?) -> Void)?
    /// Rename Schema… for the browsed schema, from the schema picker's context menu or the empty area's.
    var onRenameSchema: ((String) -> Void)?
    /// The Maintenance submenu's items for the given tables (empty for the empty area); see
    /// WorkspaceWindowController+Maintenance.swift.
    var maintenanceItems: (([TableInfo]) -> [NSMenuItem])?

    private let filterField = NSSearchField()
    private let schemaPopup = ContextMenuPopUpButton()
    let outline = SidebarOutlineView()
    private let statusLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator()

    final class Group {
        let title: String
        var items: [TableInfo]
        /// Folders and keys, for the Redis "Keys" section.
        var keyRoots: [KeyNode]?
        var keyCount = 0
        /// Procedures, Functions, Triggers or Types: the objects, their row labels and the row shown when there are none.
        var objectKind: SchemaObjectKind?
        var objects: [SchemaObjectBox] = []
        var note: SidebarNote?
        init(title: String, items: [TableInfo], keyRoots: [KeyNode]? = nil) {
            self.title = title
            self.items = items
            self.keyRoots = keyRoots
        }

        var childCount: Int {
            if objectKind != nil { return objects.isEmpty ? (note == nil ? 0 : 1) : objects.count }
            return keyRoots?.count ?? items.count
        }

        var headerCount: Int {
            if objectKind != nil { return objects.count }
            return keyRoots == nil ? items.count : keyCount
        }
    }

    private(set) var groups: [Group] = []
    /// Titles of the groups the user collapsed (or that start collapsed), kept while the window lives.
    var collapsedGroups: Set<String> = Set(SchemaObjectKind.allCases.map(\.title))
    /// Set while `reload` expands groups, so those expansions are not taken for the user's.
    var isRestoringExpansion = false

    init(workspace: ConnectionWorkspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.setAccessibilityIdentifier("sidebar")

        filterField.placeholderString = "Filter"
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        filterField.sendsSearchStringImmediately = true
        filterField.setAccessibilityIdentifier("sidebarFilter")

        schemaPopup.translatesAutoresizingMaskIntoConstraints = false
        schemaPopup.controlSize = .small
        schemaPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        schemaPopup.target = self
        schemaPopup.action = #selector(schemaChanged(_:))
        schemaPopup.isHidden = !workspace.kind.supportsSchemas
        schemaPopup.toolTip = "Schema"
        schemaPopup.contextMenu = { [weak self] in self?.schemaContextMenu() }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.allowsMultipleSelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.setAccessibilityIdentifier("tableList")

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(filterField)
        root.addSubview(schemaPopup)
        root.addSubview(scroll)
        root.addSubview(statusLabel)
        root.addSubview(spinner)

        let schemaHeight: CGFloat = workspace.kind.supportsSchemas ? 22 : 0
        NSLayoutConstraint.activate([
            filterField.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            filterField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            filterField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            schemaPopup.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: workspace.kind.supportsSchemas ? 6 : 0),
            schemaPopup.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            schemaPopup.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            schemaPopup.heightAnchor.constraint(equalToConstant: schemaHeight),

            scroll.topAnchor.constraint(equalTo: schemaPopup.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -6),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            spinner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            spinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(metadataChanged), name: ConnectionWorkspace.metadataDidChange, object: workspace)
        reload()
    }

    @objc private func metadataChanged() {
        reload()
    }

    func setFilter(_ text: String) {
        filterField.stringValue = text
        reload()
    }

    func focusFilter() {
        view.window?.makeFirstResponder(filterField)
    }

    private func reload() {
        let selected = selectedTableInfos.map(\.ref)
        schemaPopup.removeAllItems()
        schemaPopup.addItems(withTitles: workspace.schemas)
        if let schema = workspace.currentSchema { schemaPopup.selectItem(withTitle: schema) }

        let filter = filterField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let capabilities = workspace.capabilities
        let visible = workspace.tables.filter { filter.isEmpty || $0.name.lowercased().contains(filter) || $0.kind == .keyspace }
        let tables = visible.filter { $0.kind == .table || $0.kind == .foreignTable }
        let views = visible.filter { $0.kind == .view || $0.kind == .materializedView }
        let system = visible.filter { $0.kind == .systemTable }
        let keyspaces = visible.filter { $0.kind == .keyspace }
        var newGroups = [
            Group(title: capabilities.objectNounPlural.capitalized, items: tables),
            Group(title: "Views", items: views),
            Group(title: "System", items: system),
        ].filter { !$0.items.isEmpty }
        newGroups += objectGroups(filter: filter)
        newGroups += [Group(title: "Databases", items: keyspaces)].filter { !$0.items.isEmpty }
        if let listing = workspace.keyListing {
            let keys = listing.keys.filter { filter.isEmpty || $0.name.lowercased().contains(filter) }
            let group = Group(title: "Keys", items: [], keyRoots: KeyNode.tree(keys, separator: workspace.keySeparator, truncated: listing.truncated, limit: ConnectionWorkspace.keyTreeLimit))
            group.keyCount = keys.count
            newGroups.append(group)
        }
        let selectedObject = selectedSchemaObject
        groups = newGroups
        outline.reloadData()
        isRestoringExpansion = true
        for group in groups {
            // While filtering, every group with matches opens; otherwise the user's choice holds.
            let opens = !collapsedGroups.contains(group.title) || (!filter.isEmpty && group.objectKind != nil && !group.objects.isEmpty)
            if opens { outline.expandItem(group) }
        }
        isRestoringExpansion = false
        if !selected.isEmpty { select(selected) }
        if let selectedObject { select(selectedObject) }

        if workspace.isLoadingTables {
            spinner.startAnimation(nil)
            statusLabel.stringValue = "Loading…"
        } else {
            spinner.stopAnimation(nil)
            if let error = workspace.lastError {
                statusLabel.stringValue = error.localizedDescription
                statusLabel.textColor = .systemRed
            } else {
                statusLabel.textColor = .secondaryLabelColor
                let count = workspace.tables.count
                statusLabel.stringValue = filter.isEmpty ? "\(count) item\(count == 1 ? "" : "s")" : "\(visible.count) of \(count)"
                let pending = workspace.pendingTableOperations.count
                if pending > 0 {
                    statusLabel.stringValue = "\(pending) pending · ⌘S to apply"
                    statusLabel.textColor = .systemOrange
                }
            }
        }
    }

    var selectedTable: TableRef? {
        (outline.item(atRow: outline.selectedRow) as? TableInfoBox)?.info.ref
    }

    /// The tables and views selected in the list (Shift-click or Shift-arrow selects several), in list order.
    var selectedTableInfos: [TableInfo] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? TableInfoBox)?.info }.filter { $0.kind != .keyspace }
    }

    func select(_ table: TableRef) {
        select([table])
    }

    /// Selects every listed table of `tables`, replacing the selection.
    func select(_ tables: [TableRef]) {
        var rows = IndexSet()
        for group in groups {
            for info in group.items where tables.contains(info.ref) {
                let row = outline.row(forItem: box(for: info))
                if row >= 0 { rows.insert(row) }
            }
        }
        if !rows.isEmpty { outline.selectRowIndexes(rows, byExtendingSelection: false) }
    }

    // NSOutlineView needs stable object identity per item.
    private var boxes: [TableRef: TableInfoBox] = [:]
    var objectBoxes: [String: SchemaObjectBox] = [:]
    private func box(for info: TableInfo) -> TableInfoBox {
        if let existing = boxes[info.ref], existing.info == info { return existing }
        let box = TableInfoBox(info)
        boxes[info.ref] = box
        return box
    }

    @objc private func filterChanged(_ sender: Any?) {
        reload()
    }

    @objc private func schemaChanged(_ sender: Any?) {
        guard let schema = schemaPopup.titleOfSelectedItem else { return }
        Task { await workspace.switchSchema(schema) }
    }

    @objc private func clicked(_ sender: Any?) {
        let item = outline.item(atRow: outline.clickedRow)
        let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if let node = item as? KeyNode {
            open(node, newTab: newTab)
            return
        }
        // Opening an object's source is a round trip, so a single click only selects it, as in TablePro.
        guard let info = (item as? TableInfoBox)?.info else { return }
        // Shift-click extends the selection (for Maintenance) without opening anything.
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true || outline.selectedRowIndexes.count > 1 { return }
        onOpenTable?(info.ref, newTab)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let item = outline.item(atRow: outline.clickedRow)
        if let node = item as? KeyNode {
            open(node, newTab: true)
            return
        }
        if let object = (item as? SchemaObjectBox)?.object {
            onOpenObject?(object)
            return
        }
        guard let info = (item as? TableInfoBox)?.info else { return }
        onOpenTable?(info.ref, true)
    }

    private func open(_ node: KeyNode, newTab: Bool) {
        guard !node.isNote else { return }
        if node.isFolder {
            onFilterKeys?(node.path + "*")
        } else {
            onOpenKey?(node.path, node.type, newTab)
        }
    }

    fileprivate var menuKeyNode: KeyNode? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return outline.item(atRow: row) as? KeyNode
    }

    @objc private func menuOpenKeyInNewTab(_ sender: Any?) {
        if let node = menuKeyNode { open(node, newTab: true) }
    }

    @objc private func menuCopyKey(_ sender: Any?) {
        guard let node = menuKeyNode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    @objc private func menuRefreshKeys(_ sender: Any?) {
        Task { await workspace.refreshKeys() }
    }

    /// Opens the table selected with the keyboard.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, let table = selectedTable {
            onOpenTable?(table, false)
            return
        }
        if event.keyCode == 36, let object = selectedSchemaObject {
            onOpenObject?(object)
            return
        }
        super.keyDown(with: event)
    }

    fileprivate var menuTargetInfo: TableInfo? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard let info = (outline.item(atRow: row) as? TableInfoBox)?.info, info.kind != .keyspace else { return nil }
        return info
    }

    fileprivate var menuTarget: TableRef? { menuTargetInfo?.ref }

    /// What the context menu's Maintenance acts on: the selection when the clicked row is part of it, else the
    /// clicked row alone, as in Finder.
    fileprivate var maintenanceTargetInfos: [TableInfo] {
        let row = outline.clickedRow
        if row >= 0, !outline.selectedRowIndexes.contains(row) { return menuTargetInfo.map { [$0] } ?? [] }
        let selected = selectedTableInfos
        return selected.isEmpty ? (menuTargetInfo.map { [$0] } ?? []) : selected
    }

    /// The context menu's Maintenance submenu for the selection (or the empty area), as "Title" lines; nil when the
    /// menu has none. For scripted checks.
    func maintenanceMenuTitles(background: Bool) -> [String]? {
        guard let items = maintenanceItems?(background ? [] : maintenanceTargetInfos), !items.isEmpty else { return nil }
        return items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    private func addMaintenanceMenu(for tables: [TableInfo], to menu: NSMenu) {
        guard let items = maintenanceItems?(tables), !items.isEmpty else { return }
        let submenu = NSMenu(title: "Maintenance")
        items.forEach(submenu.addItem)
        let item = NSMenuItem(title: "Maintenance", action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    /// The context menu for the selected row, as "Title" or "✓ Title", for scripted checks.
    func menuTitlesForSelection() -> [String] {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        return menu.items.filter { !$0.isSeparatorItem }.map { ($0.state == .on ? "✓ " : "") + $0.title }
    }

    /// The menu for a click on empty space, for scripted checks.
    func menuTitlesForBackground() -> [String] {
        outline.deselectAll(nil)
        return menuTitlesForSelection()
    }

    @objc private func menuRename(_ sender: Any?) {
        if let info = menuTargetInfo { onRename?(info) }
    }

    @objc private func menuTruncate(_ sender: Any?) {
        if let info = menuTargetInfo { onTableOperation?(info, .truncate) }
    }

    @objc private func menuDrop(_ sender: Any?) {
        if let info = menuTargetInfo { onTableOperation?(info, .drop) }
    }

    @objc private func menuOpen(_ sender: Any?) {
        if let table = menuTarget { onOpenTable?(table, false) }
    }

    @objc private func menuOpenInNewTab(_ sender: Any?) {
        if let table = menuTarget { onOpenTable?(table, true) }
    }

    @objc private func menuStructure(_ sender: Any?) {
        if let table = menuTarget { onOpenStructure?(table) }
    }

    @objc private func menuQuery(_ sender: Any?) {
        if let table = menuTarget { onQueryTable?(table) }
    }

    @objc private func menuShowInERDiagram(_ sender: Any?) {
        if let table = menuTarget { onShowERDiagram?(table) }
    }

    @objc private func menuShowERDiagram(_ sender: Any?) {
        onShowERDiagram?(nil)
    }

    @objc private func menuCopyName(_ sender: Any?) {
        guard let table = menuTarget else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(table.name, forType: .string)
    }

    @objc private func menuCopyDDL(_ sender: Any?) {
        guard let table = menuTarget else { return }
        Task {
            do {
                let ddl = try await workspace.ddl(of: table)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ddl, forType: .string)
            } catch {
                Alerts.showError(error, title: "Could not read the definition", in: view.window)
            }
        }
    }

    @objc private func menuExport(_ sender: Any?) {
        onExport?(menuTarget)
    }

    @objc private func menuImportCSV(_ sender: Any?) {
        if let table = menuTarget { onImportCSV?(table) }
    }

    @objc private func menuRunSQLFile(_ sender: Any?) {
        onRunSQLFile?()
    }

    @objc private func menuRefresh(_ sender: Any?) {
        Task { await workspace.refreshMetadata() }
    }

    /// Whether Rename Schema… is offered: PostgreSQL, writable, and not a system schema.
    private var renamableSchema: String? {
        guard onRenameSchema != nil, !workspace.isReadOnly, DatabaseObjectSQL(kind: workspace.kind).canRenameSchemas,
              let schema = workspace.currentSchema, !DatabaseObjectSQL.isSystemSchema(schema) else { return nil }
        return schema
    }

    private func schemaContextMenu() -> NSMenu? {
        guard renamableSchema != nil else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Rename Schema…", action: #selector(menuRenameSchema(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// The schema picker's context menu, for scripted checks.
    func schemaMenuTitles() -> [String] {
        schemaContextMenu()?.items.map(\.title) ?? []
    }

    @objc private func menuRenameSchema(_ sender: Any?) {
        if let schema = workspace.currentSchema { onRenameSchema?(schema) }
    }

    @objc private func menuNewTable(_ sender: Any?) {
        onNewTable?()
    }

    @objc private func menuNewView(_ sender: Any?) {
        onViewCommand?(.new)
    }

    @objc private func menuEditView(_ sender: Any?) {
        if let info = menuTargetInfo { onViewCommand?(.edit(info)) }
    }

    @objc private func menuRefreshMaterializedView(_ sender: Any?) {
        if let info = menuTargetInfo { onViewCommand?(.refresh(info)) }
    }
}

/// A folder or key in the Redis key tree. Keys are grouped by the separator, folders first, both alphabetical.
final class KeyNode: NSObject {
    let name: String
    /// The full key for a key; the prefix including the trailing separator for a folder.
    let path: String
    let type: String
    let isFolder: Bool
    /// The "Showing first N keys" row.
    let isNote: Bool
    var children: [KeyNode] = []
    var keyCount = 0

    init(name: String, path: String, type: String = "", isFolder: Bool, isNote: Bool = false) {
        self.name = name
        self.path = path
        self.type = type
        self.isFolder = isFolder
        self.isNote = isNote
    }

    static func tree(_ keys: [KeyListing.Key], separator: String, truncated: Bool, limit: Int) -> [KeyNode] {
        let root = KeyNode(name: "", path: "", isFolder: true)
        var folders: [String: KeyNode] = ["": root]
        for key in keys {
            let parts = separator.isEmpty ? [key.name] : key.name.components(separatedBy: separator)
            var parent = root
            var prefix = ""
            for part in parts.dropLast() {
                prefix += part + separator
                if let existing = folders[prefix] {
                    parent = existing
                } else {
                    let folder = KeyNode(name: part, path: prefix, isFolder: true)
                    folders[prefix] = folder
                    parent.children.append(folder)
                    parent = folder
                }
            }
            parent.children.append(KeyNode(name: parts.last ?? key.name, path: key.name, type: key.type, isFolder: false))
        }
        root.sortAndCount()
        var roots = root.children
        if truncated {
            roots.append(KeyNode(name: "Showing first \(limit.groupedText) keys", path: "", isFolder: false, isNote: true))
        }
        return roots
    }

    @discardableResult
    private func sortAndCount() -> Int {
        children.sort { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        keyCount = children.reduce(0) { $0 + ($1.isFolder ? $1.sortAndCount() : 1) }
        return keyCount
    }

    static func symbol(forType type: String) -> String {
        switch type.lowercased() {
        case "string": return "textformat"
        case "hash": return "square.grid.2x2"
        case "list": return "list.bullet"
        case "set": return "circle.grid.3x3"
        case "zset": return "chart.bar"
        case "stream": return "waveform"
        default: return "key"
        }
    }
}

final class TableInfoBox: NSObject {
    let info: TableInfo
    init(_ info: TableInfo) { self.info = info }
}

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groups.count }
        if let node = item as? KeyNode { return node.children.count }
        return (item as? Group)?.childCount ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return groups[index] }
        if let node = item as? KeyNode { return node.children[index] }
        guard let group = item as? Group else { return NSNull() }
        if group.objectKind != nil {
            if group.objects.isEmpty, let note = group.note { return note }
            return group.objects[index]
        }
        if let roots = group.keyRoots { return roots[index] }
        return box(for: group.items[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Group || (item as? KeyNode)?.isFolder == true
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is Group
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is TableInfoBox || item is SchemaObjectBox || ((item as? KeyNode)?.isNote == false)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? Group {
            let identifier = NSUserInterfaceItemIdentifier("header")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier: identifier, withImage: false)
            cell.textField?.stringValue = "\(group.title) (\(group.headerCount.groupedText))"
            return cell
        }
        if let object = item as? SchemaObjectBox {
            return objectCell(object, in: outlineView)
        }
        if let note = item as? SidebarNote {
            return noteCell(note, in: outlineView)
        }
        if let node = item as? KeyNode {
            let identifier = NSUserInterfaceItemIdentifier("table")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier: identifier, withImage: true)
            let font = cell.textField?.font ?? Theme.monospaced(12)
            let text = NSMutableAttributedString(string: node.name, attributes: [.font: font, .foregroundColor: node.isNote ? NSColor.secondaryLabelColor : NSColor.labelColor])
            if node.isFolder {
                text.append(NSAttributedString(string: "  \(node.keyCount.groupedText)", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor]))
            } else if !node.isNote {
                text.append(NSAttributedString(string: "  \(node.type.uppercased())", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            cell.textField?.attributedStringValue = text
            cell.imageView?.image = node.isNote ? nil : Theme.image(node.isFolder ? "folder" : KeyNode.symbol(forType: node.type), node.type)
            cell.imageView?.contentTintColor = node.isFolder ? .secondaryLabelColor : .systemOrange
            cell.toolTip = node.isNote ? nil : node.path
            return cell
        }
        guard let info = (item as? TableInfoBox)?.info else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("table")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier: identifier, withImage: true)
        cell.textField?.stringValue = info.kind == .keyspace ? "\(info.name)  (\((info.estimatedRows ?? 0).groupedText))" : info.name
        cell.textField?.textColor = .labelColor
        cell.imageView?.image = Theme.image(Theme.symbol(for: info.kind), info.kind.rawValue)
        cell.imageView?.contentTintColor = info.kind == .table ? .controlAccentColor : .systemPurple
        var tooltip = info.name
        // Staged operations replace the icon, as in TablePro.
        if let pending = workspace.pendingOperation(for: info.ref) {
            switch pending.operation {
            case .drop:
                cell.imageView?.image = Theme.image("minus.circle.fill", "Will be dropped")
                cell.imageView?.contentTintColor = .systemRed
                cell.textField?.textColor = .secondaryLabelColor
                tooltip += "\nWill be dropped when you save (⌘S)"
            case .truncate:
                cell.imageView?.image = Theme.image("exclamationmark.circle.fill", "Will be truncated")
                cell.imageView?.contentTintColor = .systemOrange
                tooltip += "\nWill be truncated when you save (⌘S)"
            }
        }
        if let rows = info.estimatedRows { tooltip += "\n≈ \(rows.groupedText) rows" }
        if let comment = info.comment, !comment.isEmpty { tooltip += "\n\(comment)" }
        cell.toolTip = tooltip
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier, withImage: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        cell.addSubview(text)
        cell.textField = text
        if withImage {
            text.font = Theme.monospaced(12)
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ])
        } else {
            text.font = .systemFont(ofSize: 11, weight: .semibold)
            text.textColor = .secondaryLabelColor
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

extension SidebarViewController: NSMenuDelegate {
    static func dropTitle(for kind: TableKind) -> String {
        switch kind {
        case .view: return "Drop View"
        case .materializedView: return "Drop Materialized View"
        case .foreignTable: return "Drop Foreign Table"
        case .table, .systemTable, .keyspace: return "Drop"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if addObjectMenuItems(to: menu) { return }
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        if let node = menuKeyNode, !node.isNote {
            menu.addItem(item(node.isFolder ? "Show Keys in Folder" : "Open in New Tab", #selector(menuOpenKeyInNewTab(_:))))
            menu.addItem(item(node.isFolder ? "Copy Namespace Prefix" : "Copy Key", #selector(menuCopyKey(_:))))
            menu.addItem(.separator())
            menu.addItem(item("Refresh Keys", #selector(menuRefreshKeys(_:))))
            return
        }
        if menuTarget != nil {
            menu.addItem(item("Open", #selector(menuOpen(_:))))
            menu.addItem(item("Open in New Tab", #selector(menuOpenInNewTab(_:))))
            menu.addItem(item("Show Structure", #selector(menuStructure(_:))))
            menu.addItem(item("New Query for Table", #selector(menuQuery(_:))))
            if onShowERDiagram != nil, workspace.supportsERDiagram {
                menu.addItem(item("Show in ER Diagram", #selector(menuShowInERDiagram(_:))))
            }
            menu.addItem(.separator())
            menu.addItem(item("Copy Name", #selector(menuCopyName(_:))))
            menu.addItem(item("Copy Definition (DDL)", #selector(menuCopyDDL(_:))))
            menu.addItem(.separator())
            if onViewCommand != nil, workspace.canEditViews, let info = menuTargetInfo, workspace.viewSQL.canEdit(info.kind) {
                menu.addItem(item(info.kind == .materializedView ? "Edit Materialized View…" : "Edit View…", #selector(menuEditView(_:))))
                if info.kind == .materializedView {
                    menu.addItem(item("Refresh Materialized View", #selector(menuRefreshMaterializedView(_:))))
                }
                menu.addItem(item("New View…", #selector(menuNewView(_:))))
                menu.addItem(.separator())
            }
            if workspace.supportsTableTransfer, let info = menuTargetInfo {
                menu.addItem(item("Export…", #selector(menuExport(_:))))
                if info.kind == .table, !workspace.isReadOnly {
                    menu.addItem(item("Import CSV…", #selector(menuImportCSV(_:))))
                }
                menu.addItem(.separator())
            }
            let maintenanceCount = menu.items.count
            addMaintenanceMenu(for: maintenanceTargetInfos, to: menu)
            if menu.items.count > maintenanceCount { menu.addItem(.separator()) }
            if let info = menuTargetInfo, !workspace.isReadOnly {
                let operations = workspace.tableOperations
                let pending = workspace.pendingOperation(for: info.ref)?.operation
                var added = false
                if operations.canRename(info.kind) {
                    menu.addItem(item("Rename", #selector(menuRename(_:))))
                    added = true
                }
                if operations.canTruncate(info.kind) {
                    let truncate = item("Truncate", #selector(menuTruncate(_:)))
                    truncate.state = pending == .truncate ? .on : .off
                    menu.addItem(truncate)
                    added = true
                }
                if operations.canDrop(info.kind) {
                    let drop = item(Self.dropTitle(for: info.kind), #selector(menuDrop(_:)))
                    drop.state = pending == .drop ? .on : .off
                    menu.addItem(drop)
                    added = true
                }
                if added { menu.addItem(.separator()) }
            }
        }
        if menuTarget == nil, workspace.supportsTableTransfer {
            menu.addItem(item("Export Tables…", #selector(menuExport(_:))))
            if !workspace.isReadOnly { menu.addItem(item("Run SQL File…", #selector(menuRunSQLFile(_:)))) }
            menu.addItem(.separator())
        }
        if onNewTable != nil, workspace.canChangeStructure {
            menu.addItem(item("New Table…", #selector(menuNewTable(_:))))
        }
        if menuTarget == nil, onViewCommand != nil, workspace.canEditViews {
            menu.addItem(item("New View…", #selector(menuNewView(_:))))
        }
        if menuTarget == nil, onShowERDiagram != nil, workspace.supportsERDiagram {
            menu.addItem(item("ER Diagram", #selector(menuShowERDiagram(_:))))
        }
        if menuTarget == nil, renamableSchema != nil {
            menu.addItem(item("Rename Schema…", #selector(menuRenameSchema(_:))))
        }
        if menuTarget == nil {
            addMaintenanceMenu(for: [], to: menu)
        }
        menu.addItem(item("Refresh", #selector(menuRefresh(_:))))
    }
}

/// A pop-up button that shows its own context menu on a right-click or Control-click instead of opening its list.
final class ContextMenuPopUpButton: NSPopUpButton {
    var contextMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenu?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = contextMenu?() {
            return NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        super.mouseDown(with: event)
    }
}

/// The sidebar list. Shift-click and Shift-arrow select several rows; ⌘-click keeps opening a table in a new tab
/// instead of toggling it in the selection.
final class SidebarOutlineView: NSOutlineView {
    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags
        guard flags.contains(.command), !flags.contains(.shift),
              let plain = NSEvent.mouseEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: flags.subtracting(.command),
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure)
        else { return super.mouseDown(with: event) }
        super.mouseDown(with: plain)
    }
}

import AppKit
import FoxlumeQueryCore

/// The sidebar's Saved Queries list: folders, then queries, for every connection plus this one.
@MainActor
final class SavedQueriesViewController: NSViewController {
    private let workspace: ConnectionWorkspace
    /// Double-click or Return: fills the selected empty query tab, otherwise opens a new one (`newTab` forces it).
    var onOpen: ((SavedQuery, _ newTab: Bool) -> Void)?
    /// Opens a query tab and runs it through the normal run path (Safe Mode, read-only refusal).
    var onRun: ((SavedQuery) -> Void)?
    var onInsert: ((SavedQuery) -> Void)?

    private let filterField = NSSearchField()
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let statusLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private lazy var addButton = UI.iconButton("plus", tooltip: "New Saved Query or Folder", target: self, action: #selector(addClicked(_:)))
    private let emptyState = NSStackView()

    private var roots: [SavedQueryNode] = []
    /// Folders the user opened or closed, kept across reloads; new folders start expanded.
    private var collapsed: Set<UUID> = []
    /// The row being renamed in place and its name before editing.
    private var renaming: (id: UUID, original: String)?

    private var store: SavedQueryStore { AppEnvironment.savedQueries }
    private var connectionID: UUID { workspace.config.id }

    init(workspace: ConnectionWorkspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.setAccessibilityIdentifier("savedQueries")

        filterField.placeholderString = "Filter saved queries"
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        filterField.sendsSearchStringImmediately = true
        filterField.setAccessibilityIdentifier("savedQueriesFilter")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setAccessibilityIdentifier("savedQueryList")

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        buildEmptyState()

        root.addSubview(filterField)
        root.addSubview(scroll)
        root.addSubview(emptyState)
        root.addSubview(addButton)
        root.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            filterField.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            filterField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            filterField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -4),

            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -20),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),

            addButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            addButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
        ])
        view = root
    }

    private func buildEmptyState() {
        let icon = NSImageView(image: Theme.image("star", "", size: 28, weight: .light) ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor
        let title = UI.label("No Saved Queries", size: 13, weight: .semibold, color: .secondaryLabelColor)
        let hint = NSTextField(wrappingLabelWithString: "Keep queries you run often. Save one from a query tab with ⌘D, or create one here.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = 190
        let newQuery = UI.button("New Saved Query…", target: self, action: #selector(newQueryClicked(_:)))
        let newFolder = UI.button("New Folder", target: self, action: #selector(newFolderClicked(_:)))
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        emptyState.setViews([icon, title, hint, newQuery, newFolder], in: .center)
        emptyState.setCustomSpacing(12, after: hint)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.setAccessibilityIdentifier("savedQueriesEmpty")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: SavedQueryStore.didChangeNotification, object: nil)
        reload()
    }

    @objc private func storeChanged() {
        // A rename in progress would lose its field; its end of editing reloads instead.
        guard renaming == nil else { return }
        reload()
    }

    func focusFilter() {
        view.window?.makeFirstResponder(filterField)
    }

    func setFilter(_ text: String) {
        filterField.stringValue = text
        reload()
    }

    @objc private func filterChanged(_ sender: Any?) {
        reload()
    }

    // MARK: Tree

    private var filterText: String {
        filterField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    func reload() {
        guard isViewLoaded else { return }
        let selected = selectedNode?.id
        let library = store.library(visibleOn: connectionID)
        let filter = filterText
        roots = SavedQueryNode.tree(library, filter: filter)
        outline.reloadData()
        expandFolders(roots, all: !filter.isEmpty)
        if let selected { select(id: selected) }

        let total = library.queries.count
        let shown = SavedQueryNode.queryCount(roots)
        if total == 0 && library.folders.isEmpty {
            statusLabel.stringValue = ""
        } else if filter.isEmpty {
            statusLabel.stringValue = "\(total) saved quer\(total == 1 ? "y" : "ies")"
        } else {
            statusLabel.stringValue = "\(shown) of \(total)"
        }
        let isEmpty = library.queries.isEmpty && library.folders.isEmpty
        emptyState.isHidden = !isEmpty
        scroll.isHidden = isEmpty
        filterField.isEnabled = !isEmpty
    }

    private func expandFolders(_ nodes: [SavedQueryNode], all: Bool) {
        for node in nodes where node.isFolder {
            if all || !collapsed.contains(node.id) {
                outline.expandItem(node)
            }
            expandFolders(node.children, all: all)
        }
    }

    private var selectedNode: SavedQueryNode? {
        outline.item(atRow: outline.selectedRow) as? SavedQueryNode
    }

    /// The row the context menu or a key press acts on.
    private var targetNode: SavedQueryNode? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return outline.item(atRow: row) as? SavedQueryNode
    }

    @discardableResult
    func select(id: UUID) -> Bool {
        guard let node = SavedQueryNode.find(id, in: roots) else { return false }
        var parent = outline.parent(forItem: node)
        var ancestors: [Any] = []
        while let current = parent {
            ancestors.insert(current, at: 0)
            parent = outline.parent(forItem: current)
        }
        ancestors.forEach { outline.expandItem($0) }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return false }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        return true
    }

    /// Selects the query or folder named `name`, for scripted checks.
    @discardableResult
    func select(named name: String) -> Bool {
        guard let node = SavedQueryNode.find(named: name, in: roots) else { return false }
        return select(id: node.id)
    }

    /// "Name [keyword] {all}" per row (folders end in "/"), indented by depth, for scripted checks.
    func rowDescriptions() -> [String] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let node = outline.item(atRow: row) as? SavedQueryNode else { return nil }
            var text = String(repeating: "  ", count: outline.level(forRow: row)) + node.name + (node.isFolder ? "/" : "")
            if let keyword = node.query?.keyword { text += " [\(keyword)]" }
            if node.connectionID == nil { text += " {all}" }
            return text
        }
    }

    // MARK: Opening

    @objc private func doubleClicked(_ sender: Any?) {
        guard outline.clickedRow >= 0 else { return }
        activate(targetNode)
    }

    private func activate(_ node: SavedQueryNode?) {
        guard let node else { return }
        if node.isFolder {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else if let query = node.query {
            onOpen?(query, false)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            activate(selectedNode)
        case 51, 117:
            if let node = selectedNode { confirmDelete(node) }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Creating

    @objc private func addClicked(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(menuItem("New Saved Query…", #selector(newQueryClicked(_:))))
        menu.addItem(menuItem("New Folder", #selector(newFolderClicked(_:))))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// The folder new items go into: the targeted folder, or the folder of the targeted query.
    private var targetFolderID: UUID? {
        guard let node = targetNode else { return nil }
        return node.isFolder ? node.id : node.query?.folderID
    }

    @objc func newQueryClicked(_ sender: Any?) {
        guard let window = view.window else { return }
        SavedQuerySheet(workspace: workspace, sql: "", folderID: targetFolderID).begin(for: window) { [weak self] saved in
            if let saved { self?.select(id: saved.id) }
        }
    }

    @objc func newFolderClicked(_ sender: Any?) {
        createFolder(parent: nil)
    }

    @objc private func newSubfolderClicked(_ sender: Any?) {
        guard let node = targetNode, node.isFolder else { return }
        createFolder(parent: node.id)
    }

    /// New folders belong to this connection, as TablePro's do; "Available in All Connections" shares them.
    func createFolder(parent: UUID?, name: String = "New Folder", rename: Bool = true) {
        do {
            let folder = try store.saveFolder(SavedQueryFolder(name: name, parentID: parent, connectionID: connectionID))
            if let parent { collapsed.remove(parent) }
            reload()
            select(id: folder.id)
            if rename { beginRename(folder.id) }
        } catch {
            Alerts.showError(error, title: "Could not create the folder", in: view.window)
        }
    }

    // MARK: Query actions

    @objc private func menuOpen(_ sender: Any?) {
        if let query = targetNode?.query { onOpen?(query, false) }
    }

    @objc private func menuOpenInNewTab(_ sender: Any?) {
        if let query = targetNode?.query { onOpen?(query, true) }
    }

    @objc private func menuRun(_ sender: Any?) {
        if let query = targetNode?.query { onRun?(query) }
    }

    @objc private func menuInsert(_ sender: Any?) {
        if let query = targetNode?.query { onInsert?(query) }
    }

    @objc private func menuEdit(_ sender: Any?) {
        guard let query = targetNode?.query else { return }
        edit(query)
    }

    func edit(_ query: SavedQuery) {
        guard let window = view.window else { return }
        SavedQuerySheet(workspace: workspace, editing: query).begin(for: window) { [weak self] saved in
            if let saved { self?.select(id: saved.id) }
        }
    }

    @objc private func menuDuplicate(_ sender: Any?) {
        guard let query = targetNode?.query else { return }
        do {
            if let copy = try store.duplicateQuery(id: query.id) { select(id: copy.id) }
        } catch {
            Alerts.showError(error, title: "Could not duplicate “\(query.name)”", in: view.window)
        }
    }

    @objc private func menuCopyQuery(_ sender: Any?) {
        guard let query = targetNode?.query else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(query.sql, forType: .string)
    }

    @objc private func menuMove(_ sender: NSMenuItem) {
        guard let query = targetNode?.query else { return }
        let folder = sender.representedObject as? UUID
        do {
            try store.moveQuery(id: query.id, to: folder)
            if let folder { collapsed.remove(folder) }
            reload()
            select(id: query.id)
        } catch {
            Alerts.showError(error, title: "Could not move “\(query.name)”", in: view.window)
        }
    }

    @objc private func menuDelete(_ sender: Any?) {
        if let node = targetNode { confirmDelete(node) }
    }

    func confirmDelete(_ node: SavedQueryNode) {
        let message: String
        let detail: String
        if node.isFolder {
            message = "Delete the folder “\(node.name)”?"
            detail = "The queries and folders in it move up one level."
        } else {
            message = "Delete “\(node.name)”?"
            detail = "The saved query will be deleted. This cannot be undone."
        }
        Alerts.confirm(message, detail: detail, confirmTitle: "Delete", destructive: true, in: view.window) { [weak self] confirmed in
            guard confirmed, let self else { return }
            do {
                if node.isFolder {
                    try self.store.deleteFolder(id: node.id)
                } else {
                    try self.store.deleteQuery(id: node.id)
                }
            } catch {
                Alerts.showError(error, title: "Could not delete “\(node.name)”", in: self.view.window)
            }
        }
    }

    // MARK: Folder actions

    @objc private func menuToggleGlobal(_ sender: Any?) {
        guard var folder = targetNode?.folder else { return }
        folder.connectionID = folder.connectionID == nil ? connectionID : nil
        do {
            try store.saveFolder(folder)
        } catch {
            Alerts.showError(error, title: "Could not change “\(folder.name)”", in: view.window)
        }
    }

    // MARK: Rename in place

    @objc private func menuRename(_ sender: Any?) {
        if let node = targetNode { beginRename(node.id) }
    }

    func beginRename(_ id: UUID) {
        guard let node = SavedQueryNode.find(id, in: roots) else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SavedQueryCellView, let field = cell.textField else { return }
        renaming = (id, node.name)
        field.stringValue = node.name
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.isEditable = true
        field.delegate = self
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Ends a rename; scripted checks pass the new name directly.
    func finishRename(_ newName: String?) {
        guard let (id, original) = renaming else { return }
        renaming = nil
        let name = newName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty, name != original {
            do {
                if var folder = store.library.folder(id: id) {
                    folder.name = name
                    try store.saveFolder(folder)
                } else if var query = store.query(id: id) {
                    query.name = name
                    try store.save(query)
                }
            } catch {
                Alerts.showError(error, title: "Could not rename “\(original)”", in: view.window)
            }
        }
        reload()
        select(id: id)
        view.window?.makeFirstResponder(outline)
    }

    /// Renames a row without the inline field, for scripted checks.
    func rename(named oldName: String, to newName: String) {
        guard let node = SavedQueryNode.find(named: oldName, in: roots) else { return }
        renaming = (node.id, node.name)
        finishRename(newName)
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}

extension SavedQueriesViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, renaming != nil else { return }
        field.isEditable = false
        field.drawsBackground = false
        finishRename(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), let original = renaming?.original else { return false }
        // Escape keeps the old name.
        control.stringValue = original
        view.window?.makeFirstResponder(outline)
        return true
    }
}

// MARK: - Context menu

extension SavedQueriesViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let node = outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) as? SavedQueryNode : nil
        buildMenu(menu, for: node)
    }

    private func buildMenu(_ menu: NSMenu, for node: SavedQueryNode?) {
        if let query = node?.query {
            menu.addItem(menuItem("Open", #selector(menuOpen(_:))))
            menu.addItem(menuItem("Open in New Tab", #selector(menuOpenInNewTab(_:))))
            menu.addItem(menuItem("Run in New Tab", #selector(menuRun(_:))))
            menu.addItem(menuItem("Insert into Editor", #selector(menuInsert(_:))))
            menu.addItem(.separator())
            menu.addItem(menuItem("Edit…", #selector(menuEdit(_:))))
            menu.addItem(menuItem("Rename", #selector(menuRename(_:))))
            menu.addItem(menuItem("Duplicate", #selector(menuDuplicate(_:))))
            menu.addItem(moveMenu(for: query))
            menu.addItem(menuItem("Copy Query", #selector(menuCopyQuery(_:))))
            menu.addItem(.separator())
            menu.addItem(menuItem("Delete…", #selector(menuDelete(_:))))
        } else if let folder = node?.folder {
            menu.addItem(menuItem("New Saved Query…", #selector(newQueryClicked(_:))))
            menu.addItem(menuItem("New Subfolder", #selector(newSubfolderClicked(_:))))
            menu.addItem(.separator())
            menu.addItem(menuItem("Rename", #selector(menuRename(_:))))
            let global = menuItem("Available in All Connections", #selector(menuToggleGlobal(_:)))
            global.state = folder.connectionID == nil ? .on : .off
            menu.addItem(global)
            menu.addItem(.separator())
            menu.addItem(menuItem("Delete Folder…", #selector(menuDelete(_:))))
        } else {
            menu.addItem(menuItem("New Saved Query…", #selector(newQueryClicked(_:))))
            menu.addItem(menuItem("New Folder", #selector(newFolderClicked(_:))))
        }
    }

    /// "Move to": the top level and every folder whose scope can hold the query, indented by depth.
    private func moveMenu(for query: SavedQuery) -> NSMenuItem {
        let item = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Move to")
        let library = store.library(visibleOn: connectionID)
        let top = menuItem("Top Level", #selector(menuMove(_:)))
        top.isEnabled = query.folderID != nil
        submenu.addItem(top)
        let folders = SavedQueryNode.foldersInOrder(library).filter { $0.folder.canHold(scope: query.connectionID) }
        if !folders.isEmpty { submenu.addItem(.separator()) }
        for (folder, depth) in folders {
            let entry = menuItem(folder.name, #selector(menuMove(_:)))
            entry.representedObject = folder.id
            entry.indentationLevel = min(depth, 15)
            entry.state = folder.id == query.folderID ? .on : .off
            submenu.addItem(entry)
        }
        submenu.autoenablesItems = false
        item.submenu = submenu
        return item
    }

    /// The context menu of the row named `name` (nil: the empty area), "Title" or "✓ Title", for scripted checks.
    func menuTitles(forRowNamed name: String?) -> [String] {
        let node = name.flatMap { SavedQueryNode.find(named: $0, in: roots) }
        let menu = NSMenu()
        buildMenu(menu, for: node)
        return menu.items.filter { !$0.isSeparatorItem }.map { item in
            let title = (item.state == .on ? "✓ " : "") + item.title
            guard let submenu = item.submenu else { return title }
            return title + " ▸ " + submenu.items.filter { !$0.isSeparatorItem }.map { ($0.state == .on ? "✓ " : "") + $0.title }.joined(separator: ", ")
        }
    }

    /// Runs a context menu command on the row named `name`, as a click on it would, for scripted checks.
    func performMenuItem(_ title: String, onRowNamed name: String?, submenuItem: String? = nil) -> Bool {
        if let name { guard select(named: name) else { return false } } else { outline.deselectAll(nil) }
        let node = name.flatMap { SavedQueryNode.find(named: $0, in: roots) }
        let menu = NSMenu()
        buildMenu(menu, for: node)
        guard var item = menu.items.first(where: { $0.title == title }) else { return false }
        if let submenuItem {
            guard let inner = item.submenu?.items.first(where: { $0.title == submenuItem }) else { return false }
            item = inner
        }
        guard let action = item.action else { return false }
        NSApp.sendAction(action, to: item.target, from: item)
        return true
    }
}

// MARK: - Outline

extension SavedQueriesViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SavedQueryNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SavedQueryNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SavedQueryNode)?.isFolder == true
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? SavedQueryNode { collapsed.remove(node.id) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard filterText.isEmpty, let node = notification.userInfo?["NSObject"] as? SavedQueryNode else { return }
        collapsed.insert(node.id)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SavedQueryNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("savedQuery")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SavedQueryCellView ?? SavedQueryCellView(identifier: identifier)
        cell.configure(node)
        return cell
    }

    /// Dragging a query out drops its SQL as text, for example into the editor.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? SavedQueryNode)?.query.map { $0.sql as NSString }
    }
}

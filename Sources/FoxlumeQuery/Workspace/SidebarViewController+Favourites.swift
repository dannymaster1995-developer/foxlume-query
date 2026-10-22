import AppKit
import FoxlumeQueryCore

/// A row of the Favourites or Recent section.
final class ShortcutBox: NSObject {
    let section: FavouritesStore.Section
    let row: SidebarSections.Row
    init(_ section: FavouritesStore.Section, _ row: SidebarSections.Row) {
        self.section = section
        self.row = row
    }
}

/// The Favourites and Recent sections at the top of the Tables list, the star at the end of table and object rows,
/// and their menu items. Favourites are kept per connection in favourites.json; Recent holds the last tables and views
/// opened. Redis has neither: its keys are browsed by pattern, not kept as objects.
extension SidebarViewController {
    static let favouriteDragType = NSPasteboard.PasteboardType("com.foxlume.query.favourite")

    var supportsFavourites: Bool { workspace.kind != .redis }

    private var connectionID: UUID { workspace.config.id }
    private var store: FavouritesStore { AppEnvironment.favourites }

    func sidebarItem(_ info: TableInfo) -> SidebarItemRef? {
        guard supportsFavourites else { return nil }
        return SidebarItemRef(table: info.ref, kind: info.kind, database: workspace.currentDatabase)
    }

    func sidebarItem(_ object: SchemaObject) -> SidebarItemRef? {
        guard supportsFavourites else { return nil }
        return SidebarItemRef(object: object, database: workspace.currentDatabase)
    }

    /// The browsed database and schema with what is known to be in them.
    var browsed: SidebarSections.Browsed {
        var browsed = SidebarSections.Browsed(database: workspace.currentDatabase, schema: workspace.kind.supportsSchemas ? workspace.currentSchema : nil,
                                              schemasMatter: workspace.kind.supportsSchemas)
        if workspace.hasLoadedTables, workspace.lastError == nil {
            browsed.tables = Set(workspace.tables.map(\.name))
        }
        if !workspace.isLoadingSchemaObjects {
            let objects = workspace.schemaObjects
            for kind in workspace.schemaObjectKinds where workspace.schemaObjectFailure(kind) == nil {
                browsed.objects[kind] = Set(objects.filter { $0.kind == kind }.compactMap { sidebarItem($0)?.identity })
            }
        }
        return browsed
    }

    func shortcutGroups(filter: String) -> [Group] {
        guard supportsFavourites else { return [] }
        let browsed = self.browsed
        let sections: [(FavouritesStore.Section, String, [SidebarSections.Row])] = [
            (.favourites, "Favourites", SidebarSections.favouriteRows(store.favourites(for: connectionID), browsed: browsed, filter: filter)),
            (.recent, "Recent", SidebarSections.recentRows(store.recent(for: connectionID), browsed: browsed, filter: filter)),
        ]
        return sections.filter { !$0.2.isEmpty }.map { section, title, rows in
            let group = Group(title: title, items: [])
            group.section = section
            group.shortcuts = rows.map { shortcutBox(section, $0) }
            return group
        }
    }

    private func shortcutBox(_ section: FavouritesStore.Section, _ row: SidebarSections.Row) -> ShortcutBox {
        let key = section.rawValue + "\u{1F}" + row.item.identity
        if let existing = shortcutBoxes[key], existing.row == row { return existing }
        let box = ShortcutBox(section, row)
        shortcutBoxes[key] = box
        return box
    }

    /// The listed table a row stands for, when it lies in the browsed database and schema.
    func resolvedInfo(_ box: ShortcutBox) -> TableInfo? {
        let item = box.row.item
        guard let ref = item.tableRef, browsed.contains(item) else { return nil }
        return workspace.tables.first { $0.ref == ref }
    }

    /// The listed object a row stands for, when it lies in the browsed database and schema.
    func resolvedObject(_ box: ShortcutBox) -> SchemaObject? {
        let item = box.row.item
        guard !item.isTableLike, browsed.contains(item) else { return nil }
        return workspace.schemaObjects.first { sidebarItem($0)?.identity == item.identity }
    }

    // MARK: Cells

    func shortcutCell(_ box: ShortcutBox, in outlineView: NSOutlineView) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("shortcut")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? ObjectCellView ?? makeObjectCell(identifier: identifier)
        let item = box.row.item
        cell.textField?.stringValue = item.name
        cell.textField?.textColor = box.row.isMissing ? .tertiaryLabelColor : .labelColor
        let detail = [item.kind == .trigger ? item.table : nil, box.row.location].compactMap { $0 }.filter { !$0.isEmpty }
        cell.detailField.stringValue = detail.joined(separator: " · ")
        cell.detailField.isHidden = detail.isEmpty
        if let tableKind = item.kind.tableKind {
            cell.imageView?.image = Theme.image(Theme.symbol(for: tableKind), tableKind.rawValue)
            cell.imageView?.contentTintColor = tableKind == .table ? .controlAccentColor : .systemPurple
        } else if let object = item.schemaObject {
            cell.imageView?.image = Theme.image(Self.symbol(for: object), object.kind.label)
            cell.imageView?.contentTintColor = Self.tint(for: object.kind)
        }
        if box.row.isMissing { cell.imageView?.contentTintColor = .tertiaryLabelColor }
        var tooltip = [item.database, item.schema == item.database ? nil : item.schema, item.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ".")
        if box.row.isMissing { tooltip += "\nNo longer in this " + (workspace.kind.supportsSchemas ? "schema" : "database") }
        cell.toolTip = tooltip
        cell.setAccessibilityLabel("\(box.section == .favourites ? "Favourite" : "Recent"): \(item.name)")
        configureStar(of: cell, for: item)
        return cell
    }

    /// Shows the star filled for a favourite, hollow on hover otherwise; nil hides it for good.
    func configureStar(of cell: ObjectCellView, for item: SidebarItemRef?) {
        cell.canStar = item != nil
        cell.isFavourite = item.map { store.isFavourite($0, connection: connectionID) } ?? false
        cell.isHovered = false
    }

    func hoverChanged(from old: Int, to new: Int) {
        for (row, hovered) in [(old, false), (new, true)] where row >= 0 && row < outline.numberOfRows {
            (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? ObjectCellView)?.isHovered = hovered
        }
    }

    /// The item a row stands for: a table, an object or a Favourites or Recent row.
    func sidebarItem(atRow row: Int) -> SidebarItemRef? {
        switch outline.item(atRow: row) {
        case let box as ShortcutBox: return box.row.item
        case let box as TableInfoBox: return box.info.kind == .keyspace ? nil : sidebarItem(box.info)
        case let box as SchemaObjectBox: return sidebarItem(box.object)
        default: return nil
        }
    }

    /// What View › Add to Favourites acts on when the sidebar has the focus.
    var selectedSidebarItem: SidebarItemRef? {
        outline.selectedRow >= 0 ? sidebarItem(atRow: outline.selectedRow) : nil
    }

    var isOutlineFocused: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === outline || responder.isDescendant(of: outline)
    }

    @objc func starClicked(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0, let item = sidebarItem(atRow: row) else { return }
        // The reload rebuilds the row under the button, so let the click finish first.
        DispatchQueue.main.async { [weak self] in self?.toggleFavourite(item) }
    }

    func isFavourite(_ item: SidebarItemRef) -> Bool {
        store.isFavourite(item, connection: connectionID)
    }

    func toggleFavourite(_ item: SidebarItemRef) {
        do {
            try store.toggleFavourite(item, connection: connectionID)
        } catch {
            Alerts.showError(error, title: "Could not save the favourites", in: view.window)
        }
        reload()
    }

    func moveFavourite(_ item: SidebarItemRef, before: SidebarItemRef?) {
        try? store.moveFavourite(item, before: before, connection: connectionID)
        reload()
    }

    @objc func favouritesChanged() {
        guard !isReloadScheduled else { return }
        isReloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval) { [weak self] in
            guard let self else { return }
            self.isReloadScheduled = false
            self.reload()
        }
    }

    // MARK: Context menu

    private var menuShortcut: ShortcutBox? {
        outline.item(atRow: outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow) as? ShortcutBox
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Add to or Remove from Favourites for the clicked item, and on Recent rows Remove from Recent and Clear Recent.
    func addFavouriteMenuItems(for item: SidebarItemRef?, to menu: NSMenu) {
        guard let item else { return }
        let favourite = menuItem(isFavourite(item) ? "Remove from Favourites" : "Add to Favourites", #selector(menuToggleFavourite(_:)))
        favourite.keyEquivalent = "b"
        favourite.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(favourite)
        if menuShortcut?.section == .recent {
            menu.addItem(menuItem("Remove from Recent", #selector(menuRemoveRecent(_:))))
            menu.addItem(menuItem("Clear Recent", #selector(menuClearRecent(_:))))
        }
    }

    /// The menu of a Favourites or Recent row that is not in the browsed schema, or no longer exists: opening and
    /// the list's own items only, since the table actions work on the browsed database. False for every other row.
    func addDetachedShortcutMenuItems(to menu: NSMenu) -> Bool {
        guard let box = menuShortcut, resolvedInfo(box) == nil, resolvedObject(box) == nil else { return false }
        if !box.row.isMissing {
            if box.row.item.isTableLike {
                menu.addItem(menuItem("Open", #selector(menuOpenShortcut(_:))))
                menu.addItem(menuItem("Open in New Tab", #selector(menuOpenShortcutInNewTab(_:))))
            } else {
                menu.addItem(menuItem(box.row.item.kind == .type ? "Show Definition" : "Show DDL", #selector(menuOpenShortcut(_:))))
            }
            menu.addItem(menuItem("Copy Name", #selector(menuCopyShortcutName(_:))))
            menu.addItem(.separator())
        }
        if box.row.isMissing, box.section == .favourites {
            menu.addItem(menuItem("Remove", #selector(menuToggleFavourite(_:))))
        } else {
            addFavouriteMenuItems(for: box.row.item, to: menu)
        }
        if box.row.isMissing, box.section == .recent {
            menu.addItem(menuItem("Remove from Recent", #selector(menuRemoveRecent(_:))))
            menu.addItem(menuItem("Clear Recent", #selector(menuClearRecent(_:))))
        }
        return true
    }

    private var menuItemRef: SidebarItemRef? {
        sidebarItem(atRow: outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow)
    }

    @objc private func menuToggleFavourite(_ sender: Any?) {
        if let item = menuItemRef { toggleFavourite(item) }
    }

    @objc private func menuRemoveRecent(_ sender: Any?) {
        guard let item = menuShortcut?.row.item else { return }
        try? store.removeRecent(item, connection: connectionID)
        reload()
    }

    @objc private func menuClearRecent(_ sender: Any?) {
        try? store.clearRecent(connection: connectionID)
        reload()
    }

    @objc private func menuOpenShortcut(_ sender: Any?) {
        if let item = menuShortcut?.row.item { onOpenItem?(item, false) }
    }

    @objc private func menuOpenShortcutInNewTab(_ sender: Any?) {
        if let item = menuShortcut?.row.item { onOpenItem?(item, true) }
    }

    @objc private func menuCopyShortcutName(_ sender: Any?) {
        guard let item = menuShortcut?.row.item else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.name, forType: .string)
    }

    // MARK: Reordering favourites

    @objc func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let box = item as? ShortcutBox, box.section == .favourites else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(box.row.item.identity, forType: Self.favouriteDragType)
        return pasteboardItem
    }

    private var favouritesGroup: Group? { groups.first { $0.section == .favourites } }

    @objc func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard (info.draggingSource as? NSOutlineView) === outline, let group = favouritesGroup else { return [] }
        if let target = item as? Group, target === group, index >= 0 { return .move }
        // Dropped onto a favourite: in front of it.
        if let box = item as? ShortcutBox, box.section == .favourites, let position = group.shortcuts.firstIndex(of: box) {
            outlineView.setDropItem(group, dropChildIndex: position)
            return .move
        }
        return []
    }

    @objc func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let group = item as? Group, group.section == .favourites,
              let identity = info.draggingPasteboard.string(forType: Self.favouriteDragType),
              let moving = group.shortcuts.first(where: { $0.row.item.identity == identity }) else { return false }
        let before = index >= 0 && index < group.shortcuts.count ? group.shortcuts[index].row.item : nil
        moveFavourite(moving.row.item, before: before)
        return true
    }

    // MARK: Scripted checks

    /// "Favourites (open): orders, total [shop.sales], gone (missing)", one line per section shown.
    func describeShortcutSections() -> [String] {
        groups.filter { $0.section != nil }.map { group in
            let rows = group.shortcuts.map { box -> String in
                var text = box.row.item.name
                if let location = box.row.location { text += " [\(location)]" }
                if box.row.isMissing { text += " (missing)" }
                return text
            }
            return "\(group.title) (\(outline.isItemExpanded(group) ? "open" : "closed")): " + rows.joined(separator: ", ")
        }
    }

    /// The row of a section with this name.
    func shortcutRow(_ section: FavouritesStore.Section, named name: String) -> Int? {
        guard let box = groups.first(where: { $0.section == section })?.shortcuts.first(where: { $0.row.item.name == name }) else { return nil }
        let row = outline.row(forItem: box)
        return row >= 0 ? row : nil
    }

    /// Opens a section's row as a click does.
    func openShortcut(_ section: FavouritesStore.Section, named name: String, newTab: Bool = false) -> Bool {
        guard let row = shortcutRow(section, named: name), let box = outline.item(atRow: row) as? ShortcutBox, !box.row.isMissing else { return false }
        onOpenItem?(box.row.item, newTab)
        return true
    }

    /// The context menu of a section's row, as "Title" lines.
    func shortcutMenuTitles(_ section: FavouritesStore.Section, named name: String) -> [String]? {
        guard let row = shortcutRow(section, named: name) else { return nil }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return menuTitlesForSelection()
    }

    /// Whether the star of a row is showing, for scripted checks of the hover.
    func setHoveredRow(_ row: Int) {
        outline.setHoveredRowForTesting(row)
    }

    func isStarShown(atRow row: Int) -> Bool {
        (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? ObjectCellView)?.starButton.isHidden == false
    }

    func row(ofTable name: String) -> Int? {
        for group in groups {
            if let info = group.items.first(where: { $0.name == name }) {
                let row = outline.row(forItem: box(for: info))
                return row >= 0 ? row : nil
            }
        }
        return nil
    }
}

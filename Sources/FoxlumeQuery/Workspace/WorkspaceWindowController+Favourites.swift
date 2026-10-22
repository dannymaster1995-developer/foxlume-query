import AppKit
import FoxlumeQueryCore

/// Database › Add to Favourites (⌥⌘B), opening Favourites and Recent rows, and keeping both lists in step with what
/// is opened, renamed and dropped. The sidebar side is in SidebarViewController+Favourites.swift.
extension WorkspaceWindowController {
    /// Opens a Favourites or Recent row: switches database first when the item lives in another one (the guard of
    /// the toolbar's switcher applies), then opens the table or the object's source. Tables of another schema open
    /// directly, since their ref names the schema.
    func openSidebarItem(_ item: SidebarItemRef, newTab: Bool) {
        let open: () -> Void = { [weak self] in
            guard let self else { return }
            if let ref = item.tableRef {
                self.tabs.openTable(ref, newTab: newTab)
            } else if let object = item.schemaObject {
                self.openObjectSource(object)
            }
        }
        if workspace.kind.supportsMultipleDatabases, let database = item.database, database != workspace.currentDatabase {
            requestDatabaseSwitch(to: database, then: open)
        } else {
            open()
        }
    }

    /// The item a table ref stands for in the browsed database: its kind from the table list, or from the kept copy
    /// when the table is in another schema; nil for Redis.
    func sidebarItem(for table: TableRef) -> SidebarItemRef? {
        guard sidebarController.supportsFavourites else { return nil }
        let database = workspace.currentDatabase
        if let info = workspace.tables.first(where: { $0.ref == table }) {
            return SidebarItemRef(table: table, kind: info.kind, database: database)
        }
        guard var item = SidebarItemRef(table: table, kind: .table, database: database) else { return nil }
        if let stored = AppEnvironment.favourites.stored(item, connection: workspace.config.id) { item.kind = stored.kind }
        return item
    }

    /// A table tab came to the front: it goes first in Recent.
    func recordRecent(_ table: TableRef) {
        guard let item = sidebarItem(for: table) else { return }
        try? AppEnvironment.favourites.recordOpened(item, connection: workspace.config.id)
    }

    /// Rename in the sidebar: Favourites and Recent follow the new name.
    func favouriteRenamed(_ info: TableInfo, to name: String) {
        guard sidebarController.supportsFavourites, let item = SidebarItemRef(table: info.ref, kind: info.kind, database: workspace.currentDatabase) else { return }
        try? AppEnvironment.favourites.renameObject(item, to: name, connection: workspace.config.id)
    }

    /// A staged drop ran: the table leaves Favourites and Recent.
    func favouriteDropped(_ table: TableRef, kind: TableKind) {
        guard sidebarController.supportsFavourites, let item = SidebarItemRef(table: table, kind: kind, database: workspace.currentDatabase) else { return }
        try? AppEnvironment.favourites.removeObject(item, connection: workspace.config.id)
    }

    /// What Add to Favourites acts on: the sidebar's selected row while the sidebar has the focus, otherwise the table
    /// or object of the selected tab, otherwise the sidebar's selection.
    var favouriteTarget: SidebarItemRef? {
        let sidebar = sidebarController
        guard sidebar.supportsFavourites else { return nil }
        if sidebar.isOutlineFocused, let item = sidebar.selectedSidebarItem { return item }
        if let table = tabs.selectedTab?.table, let item = sidebarItem(for: table) { return item }
        if let object = (tabs.selectedTab?.content as? ObjectSourceViewController)?.object {
            return SidebarItemRef(object: object, database: workspace.currentDatabase)
        }
        return sidebar.selectedSidebarItem
    }

    @objc func toggleFavourite(_ sender: Any?) {
        guard let item = favouriteTarget else { return NSSound.beep() }
        sidebarController.toggleFavourite(item)
    }

    /// Enables Add to Favourites when there is something to add, and names what it will do.
    func validateFavouriteItem(_ menuItem: NSMenuItem) -> Bool? {
        guard menuItem.action == #selector(toggleFavourite(_:)) else { return nil }
        guard let item = favouriteTarget else {
            menuItem.title = "Add to Favourites"
            return false
        }
        menuItem.title = sidebarController.isFavourite(item) ? "Remove from Favourites" : "Add to Favourites"
        return true
    }
}

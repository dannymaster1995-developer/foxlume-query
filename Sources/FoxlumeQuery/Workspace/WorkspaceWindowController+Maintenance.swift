import AppKit
import FoxlumeQueryCore

/// What a Maintenance menu item runs.
final class MaintenanceChoice: NSObject {
    let operation: MaintenanceOperation
    let tables: [TableInfo]

    init(operation: MaintenanceOperation, tables: [TableInfo]) {
        self.operation = operation
        self.tables = tables
    }
}

/// The Maintenance submenu of the sidebar's context menu and of the Database menu: VACUUM / ANALYZE / REINDEX
/// (PostgreSQL), OPTIMIZE / ANALYZE / CHECK / REPAIR TABLE (MySQL, MariaDB), ANALYZE / integrity check / VACUUM
/// (SQLite), ANALYZE / CHECKPOINT (DuckDB). See MaintenanceSQL for the statements and MaintenanceSheet.swift for the run.
extension WorkspaceWindowController {
    /// What the Database menu's Maintenance acts on: the tables selected in the sidebar, else the selected tab's table.
    var maintenanceTargets: [TableInfo] {
        let selected = sidebarController.selectedTableInfos
        if !selected.isEmpty { return selected }
        if let ref = tabs.selectedTab?.table, let info = workspace.tables.first(where: { $0.ref == ref }) { return [info] }
        return []
    }

    /// The items of a Maintenance submenu for `tables`, groups between separators. Commands a Read-Only connection
    /// refuses are left out when `hidingRefused` (the sidebar, which hides what cannot run) and otherwise shown
    /// disabled with the reason (the Database menu). Empty when nothing applies.
    func maintenanceItems(for tables: [TableInfo], hidingRefused: Bool) -> [NSMenuItem] {
        let sql = workspace.maintenance
        var items: [NSMenuItem] = []
        for group in sql.operationGroups(for: tables) {
            var groupItems: [NSMenuItem] = []
            for operation in group {
                let refused = workspace.refusesMaintenance(sql.steps(operation, tables: tables))
                if refused && hidingRefused { continue }
                let item = NSMenuItem(title: sql.title(operation), action: #selector(runMaintenance(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = MaintenanceChoice(operation: operation, tables: tables)
                if refused { item.toolTip = "This connection is read-only" }
                groupItems.append(item)
            }
            guard !groupItems.isEmpty else { continue }
            if !items.isEmpty { items.append(.separator()) }
            items += groupItems
        }
        return items
    }

    /// Fills the Database menu's Maintenance submenu for the current selection.
    func fillMaintenanceMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = maintenanceItems(for: maintenanceTargets, hidingRefused: false)
        if items.isEmpty {
            let reason = workspace.maintenance.isSupported ? "Select Tables in the Sidebar" : "Not Available for \(workspace.kind.displayName)"
            menu.addItem(NSMenuItem(title: reason, action: nil, keyEquivalent: ""))
        }
        items.forEach(menu.addItem)
    }

    @objc func runMaintenance(_ sender: Any?) {
        guard let choice = (sender as? NSMenuItem)?.representedObject as? MaintenanceChoice else { return }
        performMaintenance(choice.operation, on: choice.tables)
    }

    /// Applies Safe Mode, then shows the results sheet and runs the statements on a separate session. Commands that
    /// write are refused on Read-Only connections and confirmed (and authenticated) on the stricter levels like other
    /// DDL; Vacuum Full, Optimize Table and Repair Table always ask, with their warning.
    func performMaintenance(_ operation: MaintenanceOperation, on tables: [TableInfo]) {
        let sql = workspace.maintenance
        let steps = sql.steps(operation, tables: tables)
        guard !steps.isEmpty, workspace.connectionState == .connected else { return NSSound.beep() }
        let name = sql.name(operation)
        if workspace.refusesMaintenance(steps) {
            return Alerts.showError(DatabaseError.unsupported("This connection is read-only. \(name) changes the database, so it was not run."), title: "Read-only connection", in: window)
        }
        let tableCount = steps.filter { $0.table != nil }.count
        let target: String
        switch tableCount {
        case 0: target = workspace.currentDatabase ?? workspace.config.displayName
        case 1: target = "“\(steps[0].table?.name ?? "")”"
        default: target = "\(tableCount) tables"
        }
        SafeModeGate.authorize(
            config: workspace.config,
            statements: steps.map(\.statement),
            writes: MaintenanceSQL.writes(steps),
            action: "Run \(name) on \(target)",
            extraDetail: operation.warning,
            in: window
        ) { [weak self] allowed in
            guard allowed, let self else { return }
            // Let the confirmation's sheet finish closing before the results sheet attaches to the window.
            DispatchQueue.main.async {
                MaintenanceController(workspace: self.workspace, operation: operation, steps: steps, parent: self.window) { [weak self] in
                    guard let self else { return }
                    Task { await self.workspace.refreshMetadata() }
                }.present()
            }
        }
    }

    /// Menu validation for the Maintenance items, called from `validateMenuItem`.
    func validateMaintenanceItem(_ menuItem: NSMenuItem) -> Bool? {
        guard menuItem.action == #selector(runMaintenance(_:)) else { return nil }
        guard let choice = menuItem.representedObject as? MaintenanceChoice else { return false }
        let steps = workspace.maintenance.steps(choice.operation, tables: choice.tables)
        // One run at a time: the results sheet stays on the window until Done.
        return workspace.connectionState == .connected && !steps.isEmpty && !workspace.refusesMaintenance(steps) && window?.attachedSheet == nil
    }
}

/// Builds Database › Maintenance for the front workspace window each time the menu opens.
@MainActor
final class MaintenanceMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = MaintenanceMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        let front = NSApp.mainWindow?.windowController as? WorkspaceWindowController ?? (NSApp.delegate as? AppDelegate)?.activeWorkspace
        guard let front else {
            menu.removeAllItems()
            menu.addItem(NSMenuItem(title: "Not Connected", action: nil, keyEquivalent: ""))
            return
        }
        front.fillMaintenanceMenu(menu)
    }
}

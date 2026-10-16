import AppKit
import FoxlumeQueryCore

/// Scripted commands for Maintenance (VACUUM, ANALYZE, OPTIMIZE, CHECK TABLE…).
///
///     selecttables <name> [name…]     selects these tables in the sidebar, as Shift-click would
///     maintenancemenu [main|background]  logs the Maintenance submenu: of the sidebar's context menu for the
///                                     selection (default) or the empty area, or of Database › Maintenance (main),
///                                     disabled items in brackets
///     maintenance <title>             chooses that Database › Maintenance item for the selection (Safe Mode
///                                     questions still appear; answer with confirm)
///     maintenancewait                 waits until the results sheet's run finished
///     maintenancecancel               presses Cancel on the running sheet
///     maintenanceresults              logs the sheet's rows (table, status, messages) and its summary
///     maintenancelock <table>         holds a lock on a table from another session (PostgreSQL ACCESS EXCLUSIVE,
///                                     MySQL LOCK TABLES … WRITE), so a command on it waits until cancelled
///     maintenanceunlock               releases that lock and closes the session
@MainActor
enum MaintenanceAutoTest {
    static let commands: Set<String> = [
        "selecttables", "maintenancemenu", "maintenance", "maintenancewait", "maintenancecancel", "maintenanceresults",
        "maintenancelock", "maintenanceunlock",
    ]
    static var lockSession: DatabaseSession?
}

extension AutoTestRunner {
    func performMaintenance(_ command: String, _ argument: String) async throws {
        guard let window = workspace else { throw DatabaseError.notConnected }
        let sidebar = window.sidebarController
        switch command {
        case "selecttables":
            let names = argument.split(separator: " ").map(String.init)
            let refs = window.workspace.tables.filter { names.contains($0.name) }.map(\.ref)
            sidebar.select(refs)
            record("  selected: " + sidebar.selectedTableInfos.map(\.name).joined(separator: ", "))
        case "maintenancemenu":
            if argument == "main" {
                let menu = NSMenu()
                window.fillMaintenanceMenu(menu)
                let titles = menu.items.map { item -> String in
                    if item.isSeparatorItem { return "-" }
                    let enabled = item.action != nil && window.validateMenuItem(item)
                    return enabled ? item.title : "[\(item.title)]" + (item.toolTip.map { " (\($0))" } ?? "")
                }
                record("  main maintenance: " + titles.joined(separator: " | "))
            } else {
                let titles = sidebar.maintenanceMenuTitles(background: argument == "background")
                record("  sidebar maintenance: " + (titles?.joined(separator: " | ") ?? "none"))
            }
        case "maintenance":
            let menu = NSMenu()
            window.fillMaintenanceMenu(menu)
            guard let item = menu.items.first(where: { $0.title == argument }) else { throw DatabaseError.unsupported("No Maintenance item \(argument)") }
            guard item.action != nil, window.validateMenuItem(item) else { return record("  disabled: \(argument)") }
            window.runMaintenance(item)
            try await Task.sleep(nanoseconds: 500_000_000)
        case "maintenancewait":
            try await Task.sleep(nanoseconds: 300_000_000)
            try await waitFor(seconds: 60) { MaintenanceController.presented?.model.isRunning != true }
            try await Task.sleep(nanoseconds: 300_000_000)
        case "maintenancecancel":
            guard let model = MaintenanceController.presented?.model, model.isRunning else { throw DatabaseError.unsupported("No maintenance running") }
            model.cancel()
        case "maintenanceresults":
            guard let model = MaintenanceController.presented?.model else { throw DatabaseError.unsupported("No Maintenance sheet") }
            record("  \(model.title): \(model.subtitle)")
            for row in model.rows {
                record("  \(row.target) | \(row.outcome.status.title) | \(row.outcome.summary) | \(row.outcome.elapsed == nil ? "no time" : "timed")")
            }
            // The summary ends with the elapsed time, which changes from run to run.
            record("  summary: " + (model.summaryText.components(separatedBy: " · ").first ?? ""))
        case "maintenancelock":
            var parameters = window.workspace.session.parameters
            parameters.config.queryTimeout = nil
            let session = DatabaseSession(parameters: parameters)
            try await session.connect()
            let table = window.workspace.tables.first { $0.name == argument }?.ref ?? TableRef(name: argument)
            let name = window.workspace.dialect.qualifiedName(table)
            switch window.workspace.kind {
            case .postgresql: _ = try await session.execute("BEGIN; LOCK TABLE \(name) IN ACCESS EXCLUSIVE MODE")
            case .mysql, .mariadb: _ = try await session.execute("LOCK TABLES \(name) WRITE")
            default: throw DatabaseError.unsupported("maintenancelock needs PostgreSQL or MySQL")
            }
            MaintenanceAutoTest.lockSession = session
        case "maintenanceunlock":
            if let session = MaintenanceAutoTest.lockSession {
                _ = try? await session.execute(window.workspace.kind == .postgresql ? "ROLLBACK" : "UNLOCK TABLES")
                await session.close()
            }
            MaintenanceAutoTest.lockSession = nil
        default:
            break
        }
    }
}

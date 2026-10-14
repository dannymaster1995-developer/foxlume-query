import AppKit
import FoxlumeQueryCore

/// Scripted commands for procedures, functions, triggers and types. An object is named by its name, or by
/// `kind:name` (procedure, function, trigger, type) when two kinds share it; overloads pick the first.
///
///     objects                     logs the object groups: title, count, open or closed, and the row labels
///     expandgroup <title>         opens a group (Functions, Triggers…); collapsegroup <title> closes it
///     selectobject <name>         selects the object's row in the sidebar
///     objectmenu <name>           logs the object's context menu
///     openobject <name>           opens its source tab (double-click) and waits for the text
///     objectsource                logs the selected source tab: title, status and the first lines of the text
///     editobject <name>           Edit in Query Tab; logs the new query tab's text
///     copydefinition <name>       Copy Definition; logs the start of what was copied
///     dropobject <name>           Drop…: shows the question (answer with confirm, read it with sheettext)
///     newtrigger [table]          New Trigger… with a template in a query tab
@MainActor
enum RoutinesAutoTest {
    static let commands: Set<String> = [
        "objects", "expandgroup", "collapsegroup", "selectobject", "objectmenu", "openobject", "objectsource", "editobject",
        "copydefinition", "dropobject", "newtrigger",
    ]
}

extension AutoTestRunner {
    func performRoutines(_ command: String, _ argument: String) async throws {
        guard let window = workspace else { throw DatabaseError.notConnected }
        let sidebar = window.sidebarController
        func object(_ text: String) throws -> SchemaObject {
            let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
            let kind = parts.count == 2 ? SchemaObjectKind(rawValue: parts[0]) : nil
            let name = parts.count == 2 && kind != nil ? parts[1] : text
            guard let match = window.workspace.schemaObjects.first(where: { $0.name == name && (kind == nil || $0.kind == kind) }) else {
                throw DatabaseError.unsupported("No procedure, function, trigger or type named \(text)")
            }
            return match
        }
        switch command {
        case "objects":
            try await waitFor(seconds: 20) { !window.workspace.isLoadingSchemaObjects }
            for line in sidebar.describeObjectGroups() { record("  " + line) }
        case "expandgroup", "collapsegroup":
            sidebar.setGroup(argument, expanded: command == "expandgroup")
            try await Task.sleep(nanoseconds: 200_000_000)
        case "selectobject":
            sidebar.select(try object(argument))
        case "objectmenu":
            sidebar.select(try object(argument))
            record("  " + sidebar.menuTitlesForSelection().joined(separator: " | "))
        case "openobject":
            let target = try object(argument)
            sidebar.select(target)
            window.openObjectSource(target)
            try await waitFor(seconds: 20) { (window.tabs.selectedTab?.content as? ObjectSourceViewController)?.isLoading == false }
            try await Task.sleep(nanoseconds: 300_000_000)
        case "objectsource":
            guard let source = window.tabs.selectedTab?.content as? ObjectSourceViewController else { throw DatabaseError.unsupported("No source tab") }
            record("  title: \(source.tabTitle)")
            if let error = source.loadError { record("  error: \(error.localizedDescription)") }
            let lines = (source.definitionText ?? "").components(separatedBy: "\n")
            record("  text (\(lines.count) lines): " + lines.prefix(4).joined(separator: " | "))
        case "editobject":
            let target = try object(argument)
            window.editInQueryTab(target)
            try await waitFor(seconds: 20) { (window.tabs.selectedTab?.content as? QueryTabViewController)?.tabTitle == "Edit \(target.name)" }
            if let query = window.tabs.selectedTab?.content as? QueryTabViewController {
                record("  edit: " + query.sql.replacingOccurrences(of: "\n", with: " | "))
            }
        case "copydefinition":
            NSPasteboard.general.clearContents()
            window.performObjectCommand(.copyDefinition(try object(argument)))
            try await waitFor(seconds: 20) { NSPasteboard.general.string(forType: .string) != nil }
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            record("  copied: " + String(copied.prefix(160)).replacingOccurrences(of: "\n", with: " | "))
        case "dropobject":
            window.confirmDrop(try object(argument))
            try await Task.sleep(nanoseconds: 500_000_000)
        case "newtrigger":
            let table = argument.isEmpty ? nil : TableRef(schema: window.workspace.kind.supportsSchemas ? window.workspace.currentSchema : nil, name: argument)
            window.openTriggerTemplate(table: table)
            try await Task.sleep(nanoseconds: 300_000_000)
        default:
            break
        }
    }
}

import AppKit
import FoxlumeQueryCore

/// Scripted commands for saved queries and Open Quickly. Fields are separated by " | ".
///
///     sidebarmode saved                       tables | saved: the sidebar's Tables / Saved Queries switch
///     addsavedfolder Reports | <parent> | all  creates a folder (parent and "all" optional; default: this connection)
///     addsavedquery Name | kw | all | Reports | SELECT 1   keyword "-" for none, "this" or "all", folder "-" for none
///     savedqueries                            logs the saved query tree and its status line
///     savedqueryfilter text                   types into the list's filter
///     savedquerymenu Name                     logs the context menu of a row ("-": the empty area)
///     savedqueryaction Delete… | Name         runs a context menu item on a row; a third field picks a submenu item
///     savedqueryrename Old | New              renames a row as the inline field would
///     savequery                               Query › Add to Saved Queries… (⌘D) in the selected tab
///     historysave                             "Add to Saved Queries…" on the newest history row
///     savequeryfield keyword top10            sets a field of the open sheet: name, keyword, sql, folder, global
///     savequerystate                          logs the open sheet's fields, keyword message and Save button
///     savequerysave / savequerycancel
///     focusfilter                             View › Focus Sidebar Filter
///     tabs [all]                              logs the open tabs ("*" marks the selected one) and its SQL; "all": every window
///     openquickly                             File › Open Quickly… (⇧⌘O)
///     oqtype ord                              replaces the search text
///     oqkey down                              down, up, return, cmd-return, opt-return, escape, ctrl-n, cmd-2, toggle
///     oqstate                                 logs the scope, the rows («» = highlighted) and the panel frame
@MainActor
enum SavedQueriesAutoTest {
    static let commands: Set<String> = [
        "sidebarmode", "addsavedfolder", "addsavedquery", "savedqueries", "savedqueryfilter", "savedquerymenu", "savedqueryaction",
        "savedqueryrename", "savequery", "historysave", "savequeryfield", "savequerystate", "savequerysave", "savequerycancel",
        "focusfilter", "tabs", "openquickly", "oqtype", "oqkey", "oqstate",
    ]
}

extension AutoTestRunner {
    func performSavedQueries(_ command: String, _ argument: String) async throws {
        guard let window = workspace else { throw DatabaseError.notConnected }
        let fields = argument.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
        let store = AppEnvironment.savedQueries
        let connection = window.workspace.config.id
        switch command {
        case "sidebarmode":
            window.sidebarContainer.show(argument == "saved" ? .savedQueries : .tables)
            try await Task.sleep(nanoseconds: 300_000_000)
        case "addsavedfolder":
            let parent = fields.count > 1 && fields[1] != "-" ? store.library.folders.first { $0.name == fields[1] }?.id : nil
            try store.saveFolder(SavedQueryFolder(name: fields[0], parentID: parent, connectionID: fields.count > 2 && fields[2] == "all" ? nil : connection))
        case "addsavedquery":
            guard fields.count == 5 else { throw DatabaseError.unsupported("addsavedquery name | keyword | this|all | folder | sql") }
            let folder = fields[3] == "-" ? nil : store.library.folders.first { $0.name == fields[3] }?.id
            try store.save(SavedQuery(name: fields[0], sql: Self.queryText(fields[4]), keyword: fields[1] == "-" ? nil : fields[1],
                                      folderID: folder, connectionID: fields[2] == "all" ? nil : connection))
        case "savedqueries":
            let list = window.savedQueriesList
            list.reload()
            record("  saved queries: " + list.rowDescriptions().joined(separator: " ; "))
        case "savedqueryfilter":
            window.savedQueriesList.setFilter(argument)
            record("  saved queries: " + window.savedQueriesList.rowDescriptions().joined(separator: " ; "))
        case "savedquerymenu":
            record("  " + window.savedQueriesList.menuTitles(forRowNamed: argument == "-" ? nil : argument).joined(separator: " | "))
        case "savedqueryaction":
            guard fields.count >= 2 else { throw DatabaseError.unsupported("savedqueryaction <menu item> | <row> [| <submenu item>]") }
            let done = window.savedQueriesList.performMenuItem(fields[0], onRowNamed: fields[1] == "-" ? nil : fields[1], submenuItem: fields.count > 2 ? fields[2] : nil)
            if !done { record("  ! no menu item \(fields[0]) for \(fields[1])") }
            try await settle()
        case "savedqueryrename":
            guard fields.count == 2 else { throw DatabaseError.unsupported("savedqueryrename <old> | <new>") }
            window.savedQueriesList.rename(named: fields[0], to: fields[1])
        case "savequery":
            window.addToSavedQueries(nil)
            try await Task.sleep(nanoseconds: 500_000_000)
        case "historysave":
            (window.splitItems.last?.viewController as? HistoryViewController)?.saveFirstEntry()
            try await Task.sleep(nanoseconds: 500_000_000)
        case "savequeryfield":
            let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard let sheet = SavedQuerySheet.presented, let key = words.first else { throw DatabaseError.unsupported("No saved query sheet") }
            sheet.setValue(Self.queryText(words.count > 1 ? words[1] : ""), for: key)
        case "savequerystate":
            guard let sheet = SavedQuerySheet.presented else { throw DatabaseError.unsupported("No saved query sheet") }
            record("  sheet: " + sheet.stateDescription)
        case "savequerysave", "savequerycancel":
            guard let sheet = SavedQuerySheet.presented else { throw DatabaseError.unsupported("No saved query sheet") }
            if command == "savequerysave" { sheet.pressSave() } else { sheet.pressCancel() }
            try await Task.sleep(nanoseconds: 500_000_000)
        case "focusfilter":
            window.focusTableFilter(nil)
            let responder = window.window?.firstResponder
            let field = (responder as? NSTextView)?.delegate as? NSView ?? responder as? NSView
            record("  focus: \(field?.accessibilityIdentifier() ?? String(describing: responder.map { type(of: $0) }))")
        case "tabs":
            // tabs all: every open connection's tabs, for items opened in another window.
            for shown in argument == "all" ? (app?.workspaces ?? []) : [window] {
                let titles = shown.tabs.tabs.map { ($0 === shown.tabs.selectedTab ? "*" : "") + $0.content.tabTitle }
                record("  tabs\(argument == "all" ? " [\(shown.workspace.config.displayName)]" : ""): " + titles.joined(separator: ", "))
            }
            if let query = window.tabs.selectedTab?.content as? QueryTabViewController {
                record("  sql: " + query.sql.replacingOccurrences(of: "\n", with: "\\n"))
            }
        case "openquickly":
            window.openQuickly(nil)
            try await Task.sleep(nanoseconds: 500_000_000)
        case "oqtype":
            guard let panel = OpenQuicklyController.current else { throw DatabaseError.unsupported("Open Quickly is not showing") }
            panel.setQuery(Self.typedText(argument))
            try await settle()
        case "oqkey":
            guard let panel = OpenQuicklyController.current else { throw DatabaseError.unsupported("Open Quickly is not showing") }
            guard panel.perform(argument) else { throw DatabaseError.unsupported("Unknown key \(argument)") }
            try await settle()
        case "oqstate":
            guard let panel = OpenQuicklyController.current else { return record("  open quickly: closed") }
            let frame = panel.panelFrame
            record("  open quickly [\(panel.scopeTitle)] \(Int(frame.width))x\(Int(frame.height)): " + panel.rowDescriptions().joined(separator: " ; "))
        default:
            throw DatabaseError.unsupported("Unknown command \(command)")
        }
    }

    /// Lets the panel, sheets and lazy loads finish, then waits for running statements.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
        try await waitFor(seconds: 20) { (self.workspace?.workspace.runningStatements ?? 0) == 0 }
    }
}

import AppKit
import FoxlumeQueryCore

/// Scripted commands for Rename Schema, Rename Database and Copy Database (PostgreSQL).
///
///     renameschema <old> <new>            Rename Schema without the prompt (Safe Mode still asks); waits for the reload
///     renameschemaprompt [schema]         shows the Rename Schema prompt (answer with confirm)
///     schemamenu                          logs the schema picker's context menu
///     renamedatabase <old> <new>          Rename Database without the prompt; waits until it finished
///     copydatabase <old> <new> [owner]    Copy Database; `owner` keeps the source's owner; waits until it finished
///     copydatabasestart <old> <new> [png] starts Copy Database and returns at once; `png` captures the progress sheet
///     databasechangewait                  waits for a started rename or copy
///     databaseprompt rename|copy          shows the Rename or Copy Database prompt (answer with confirm)
///     dropdatabaseconfirm <name>         Drop Database…: picks the database, types its name and presses Drop
///     holdsession <database>              keeps another session open on a database, as another user's would be
///     releasesessions                     closes the sessions `holdsession` opened
///     dbstate                             logs the database, schema, schemas and the open tabs
@MainActor
enum DatabasesAutoTest {
    static let commands: Set<String> = [
        "renameschema", "renameschemaprompt", "schemamenu", "renamedatabase", "copydatabase", "copydatabasestart",
        "databasechangewait", "databaseprompt", "dropdatabaseconfirm", "holdsession", "releasesessions", "dbstate",
    ]
    static var heldSessions: [DatabaseSession] = []
}

extension AutoTestRunner {
    func performDatabases(_ command: String, _ argument: String) async throws {
        guard let window = workspace else { throw DatabaseError.notConnected }
        let words = argument.split(separator: " ").map(String.init)
        func waitForChange() async throws {
            try await Task.sleep(nanoseconds: 300_000_000)
            try await waitFor(seconds: 120) { !window.isChangingDatabase && window.workspace.runningStatements == 0 }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        switch command {
        case "renameschema":
            guard words.count == 2 else { throw DatabaseError.unsupported("renameschema <old> <new>") }
            window.renameSchema(words[0], to: words[1])
            try await Task.sleep(nanoseconds: 500_000_000)
            try await waitFor(seconds: 20) { window.workspace.runningStatements == 0 }
            try await Task.sleep(nanoseconds: 300_000_000)
        case "renameschemaprompt":
            window.presentRenameSchema(argument.isEmpty ? window.workspace.currentSchema : argument)
            try await Task.sleep(nanoseconds: 500_000_000)
        case "schemamenu":
            record("  schema menu: " + window.sidebarController.schemaMenuTitles().joined(separator: " | "))
        case "renamedatabase":
            guard words.count == 2 else { throw DatabaseError.unsupported("renamedatabase <old> <new>") }
            window.renameDatabase(words[0], to: words[1])
            try await waitForChange()
        case "copydatabase", "copydatabasestart":
            guard words.count >= 2 else { throw DatabaseError.unsupported("\(command) <old> <new> [owner]") }
            window.copyDatabase(words[0], to: words[1], keepOwner: command == "copydatabase" && words.count > 2 && words[2] == "owner")
            if command == "copydatabase" {
                try await waitForChange()
            } else {
                try await waitFor(seconds: 10) { window.isChangingDatabase }
                if words.count > 2 { try snapshot(named: words[2]) }
            }
        case "databasechangewait":
            try await waitForChange()
        case "databaseprompt":
            window.presentDatabaseChange(copy: argument == "copy")
            try await Task.sleep(nanoseconds: 500_000_000)
        case "dropdatabaseconfirm":
            window.dropDatabase(nil)
            try await Task.sleep(nanoseconds: 500_000_000)
            guard let sheet = window.window?.attachedSheet, let content = sheet.contentView else { throw DatabaseError.unsupported("No Drop Database sheet") }
            let picker = Self.views(of: NSPopUpButton.self, in: content).first
            let field = Self.views(of: NSTextField.self, in: content).first { $0.isEditable }
            guard let picker, let field, picker.itemTitles.contains(argument) else { throw DatabaseError.unsupported("Cannot pick \(argument) in the Drop Database sheet") }
            picker.selectItem(withTitle: argument)
            field.stringValue = argument
            guard let drop = Self.views(of: NSButton.self, in: content).first(where: { $0.title == "Drop" }) else { throw DatabaseError.unsupported("No Drop button") }
            drop.performClick(nil)
            try await Task.sleep(nanoseconds: 500_000_000)
            try await waitFor(seconds: 20) { window.workspace.runningStatements == 0 }
            try await Task.sleep(nanoseconds: 300_000_000)
        case "holdsession":
            var parameters = window.workspace.session.parameters
            parameters.config.database = argument
            let session = DatabaseSession(parameters: parameters)
            try await session.connect()
            DatabasesAutoTest.heldSessions.append(session)
        case "releasesessions":
            for session in DatabasesAutoTest.heldSessions { await session.close() }
            DatabasesAutoTest.heldSessions.removeAll()
        case "dbstate":
            let workspace = window.workspace
            record("  database: \(workspace.currentDatabase ?? "-"), schema: \(workspace.currentSchema ?? "-"), config database: \(workspace.config.database)")
            record("  schemas: " + workspace.schemas.filter { !DatabaseObjectSQL.isSystemSchema($0) }.joined(separator: ", "))
            record("  databases: " + workspace.databases.joined(separator: ", "))
            let tabs = window.tabs.tabs.map { tab -> String in
                let title = tab.content.tabTitle
                let name = tab.table.map { [$0.schema, $0.name].compactMap { $0 }.joined(separator: ".") } ?? title
                return tab === window.tabs.selectedTab ? "[\(name)]" : name
            }
            record("  tabs: " + (tabs.isEmpty ? "none" : tabs.joined(separator: ", ")))
        default:
            break
        }
    }

    private static func views<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(of: type, in: $0) }
    }
}

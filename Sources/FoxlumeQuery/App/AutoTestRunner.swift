import AppKit
import FoxlumeQueryCore

/// Scripted UI walkthrough for verification, enabled only by `FOXLUME_AUTOTEST` (or `_FILE`).
/// Each line is a command; snapshots are rendered offscreen, so no screen recording permission is needed.
///
///     connect Local Postgres
///     open orders
///     snapshot orders.png
///     quit
@MainActor
final class AutoTestRunner {
    private(set) weak var app: AppDelegate?
    private let commands: [String]
    private(set) var snapshotDirectory: URL
    private var log: [String] = []

    init(app: AppDelegate, script: String) {
        self.app = app
        self.commands = script
            .components(separatedBy: CharacterSet(charactersIn: "\n"))
            .flatMap { $0.components(separatedBy: ";;") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let directory = ProcessInfo.processInfo.environment["FOXLUME_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? AppPaths.dataDirectory.appendingPathComponent("snapshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.snapshotDirectory = directory
    }

    static func scriptFromEnvironment() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["FOXLUME_AUTOTEST_FILE"], let text = try? String(contentsOfFile: path, encoding: .utf8) {
            return text
        }
        return environment["FOXLUME_AUTOTEST"]
    }

    func start() {
        // The app stays in the background, so no window is key; the editor would otherwise drop every answer.
        SQLTextView.assumesKeyWindow = true
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            for command in commands {
                record("> \(command)")
                do {
                    try await perform(command)
                } catch {
                    record("! \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    func record(_ line: String) {
        log.append(line)
        let url = snapshotDirectory.appendingPathComponent("autotest.log")
        try? (log.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    var workspace: WorkspaceWindowController? { app?.activeWorkspace }

    /// Scripted runs keep the app in the background, so there may be no key window: use the frontmost visible one.
    private var frontWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.orderedWindows.first { $0.isVisible && !($0 is NSPanel) } ?? NSApp.orderedWindows.first { $0.isVisible }
    }

    private func perform(_ line: String) async throws {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0]
        let argument = parts.count > 1 ? parts[1] : ""
        switch command {
        case "wait":
            try await Task.sleep(nanoseconds: UInt64((Double(argument) ?? 1) * 1_000_000_000))
        case "appearancemode":
            // Writes the Settings value, as the Appearance picker does.
            var settings = AppEnvironment.settings
            settings.appearance = AppearanceMode(rawValue: argument) ?? .system
            AppEnvironment.settings = settings
            try await Task.sleep(nanoseconds: 600_000_000)
        case "appearance":
            NSApp.appearance = NSAppearance(named: argument == "dark" ? .darkAqua : .aqua)
        case "welcome":
            app?.showWelcome(nil)
        case "form":
            if argument.isEmpty {
                app?.presentForm(for: nil)
            } else if let config = AppEnvironment.connections.all().first(where: { $0.displayName == argument }) {
                app?.presentForm(for: config)
            }
        case _ where TransferAutoTest.commands.contains(command):
            try await performTransfer(command, argument)
        case _ where SavedQueriesAutoTest.commands.contains(command):
            try await performSavedQueries(command, argument)
        case _ where ExplainAutoTest.commands.contains(command):
            try await performExplain(command, argument)
        case _ where GridAutoTest.commands.contains(command):
            try await performGrid(command, argument)
        case _ where RoutinesAutoTest.commands.contains(command):
            try await performRoutines(command, argument)
        case _ where ViewsAutoTest.commands.contains(command):
            try await performViews(command, argument)
        case _ where TLSAutoTest.commands.contains(command):
            try await performTLS(command, argument)
        case _ where DiagramsAutoTest.commands.contains(command):
            try await performDiagrams(command, argument)
        case _ where TabsAutoTest.commands.contains(command):
            try await performTabs(command, argument)
        case _ where EditorAutoTest.commands.contains(command):
            try await performEditor(command, argument)
        case _ where DatabasesAutoTest.commands.contains(command):
            try await performDatabases(command, argument)
        case _ where MaintenanceAutoTest.commands.contains(command):
            try await performMaintenance(command, argument)
        case _ where ActivityAutoTest.commands.contains(command):
            try await performActivity(command, argument)
        case _ where BackupAutoTest.commands.contains(command):
            try await performBackup(command, argument)
        case _ where FavouritesAutoTest.commands.contains(command):
            try await performFavourites(command, argument)
        case _ where TintAutoTest.commands.contains(command):
            try await performTint(command, argument)
        case "closesheet":
            TransferAutoTest.closeSheets()
            MaintenanceController.presented?.dismiss()
            BackupController.presented?.dismiss()
            RestoreController.presented?.dismiss()
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
        case "connect":
            guard let config = AppEnvironment.connections.all().first(where: { $0.displayName == argument }) else {
                throw DatabaseError.unsupported("No saved connection named \(argument)")
            }
            app?.connect(config)
            try await waitFor(seconds: 15) { self.app?.workspaces.contains { $0.workspace.config.id == config.id } == true }
            try await Task.sleep(nanoseconds: 600_000_000)
        case "database":
            try await workspace?.workspace.switchDatabase(argument)
        case "schema":
            await workspace?.workspace.switchSchema(argument)
        case "open", "newtab":
            guard let workspace else { throw DatabaseError.notConnected }
            let ref = TableRef(schema: workspace.workspace.kind.supportsSchemas ? workspace.workspace.currentSchema : nil, name: argument)
            workspace.tabs.openTable(ref, newTab: command == "newtab")
            try await waitForIdle()
        case "mode":
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.setMode(argument == "structure" ? .structure : .data)
            try await waitForIdle()
        case "section":
            if let table = workspace?.tabs.selectedTab?.content as? TableTabViewController {
                table.showStructureSection(Int(argument) ?? 0)
            }
            try await waitForIdle()
        case "filter":
            let pieces = argument.split(separator: " ", maxSplits: 2).map(String.init)
            guard pieces.count >= 2, let op = FilterOperator(rawValue: pieces[1]) else { throw DatabaseError.unsupported("filter <column> <operator> [value]") }
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.applyFilters([FilterRule(column: pieces[0], op: op, value: pieces.count > 2 ? pieces[2] : "")], raw: "")
            try await waitForIdle()
        case "showfilters":
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.toggleFilters(nil)
        case "edit":
            let pieces = argument.split(separator: " ", maxSplits: 2).map(String.init)
            guard pieces.count == 3, let row = Int(pieces[0]), let column = Int(pieces[1]) else { throw DatabaseError.unsupported("edit <row> <column> <value>") }
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.applyEdit(row: row, column: column, value: pieces[2] == "NULL" ? .null : .text(pieces[2]))
        case "delete":
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.markDeleted(row: Int(argument) ?? 0)
        case "undo":
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.undo(nil)
        case "redo":
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.redo(nil)
        case "valueeditor":
            let pieces = argument.split(separator: " ").compactMap { Int($0) }
            guard pieces.count == 2 else { throw DatabaseError.unsupported("valueeditor <row> <column>") }
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.showValueEditor(row: pieces[0], column: pieces[1])
        case "tab":
            workspace?.tabs.selectTab(at: (Int(argument) ?? 1) - 1)
        case "theme":
            // theme light|dark <theme id>
            let pieces = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { throw DatabaseError.unsupported("theme light|dark <id>") }
            var settings = AppEnvironment.settings
            if pieces[0] == "light" { settings.lightThemeID = pieces[1] } else { settings.darkThemeID = pieces[1] }
            AppEnvironment.settings = settings
            try await Task.sleep(nanoseconds: 400_000_000)
        case "importtheme":
            let imported = try ThemeStore.shared.importThemes(from: URL(fileURLWithPath: argument))
            record("  imported \(imported.map { "\($0.name) [\($0.id), \($0.appearance.rawValue)]" }.joined(separator: ", "))")
        case "pattern":
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.applyFilters([], raw: argument)
            try await waitForIdle()
        case "key":
            // key <type> <name>
            let pieces = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { throw DatabaseError.unsupported("key <type> <name>") }
            workspace?.openKey(pieces[1], type: pieces[0], newTab: true)
            try await waitForIdle()
        case "editorkey":
            // editorkey <name>: a key press in the query editor (down, up, left, right, return, tab, escape, space,
            // backspace, ctrl-space).
            guard let query = workspace?.tabs.selectedTab?.content as? QueryTabViewController else {
                throw DatabaseError.unsupported("editorkey needs a query tab")
            }
            guard query.sendKeyForTesting(argument) else { throw DatabaseError.unsupported("Unknown key \(argument)") }
            try await Task.sleep(nanoseconds: 600_000_000)
            recordCompletions(of: query)
        case "newdatabase":
            workspace?.newDatabase(nil)
            try await Task.sleep(nanoseconds: 500_000_000)
        case "dropdatabase":
            workspace?.dropDatabase(nil)
            try await Task.sleep(nanoseconds: 500_000_000)
        case "menu":
            // menu <title>: reports whether a main menu item is enabled for the front window, and its tooltip.
            let item = NSApp.mainMenu?.items.lazy.compactMap { $0.submenu?.items.first { $0.title == argument } }.first
            if let item, let action = item.action {
                // A background app has no key window, so ask the front workspace window the way its menu would.
                let target: Any? = workspace.flatMap { $0.responds(to: action) ? $0 : nil } ?? NSApp.target(forAction: action, to: nil, from: item)
                let enabled = (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? (target != nil)
                record("  \(argument): \(enabled ? "enabled" : "disabled")" + (item.toolTip.map { " (\($0))" } ?? ""))
            } else {
                record("  \(argument): not found")
            }
        case "find":
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.find(argument)
            try await Task.sleep(nanoseconds: 400_000_000)
        case "searchall":
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.searchAllRows(argument)
            try await waitForIdle()
        case "inspector":
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.toggleInspector(nil)
            try await Task.sleep(nanoseconds: 300_000_000)
        case "selectrow":
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.selectRow(Int(argument) ?? 0)
            try await Task.sleep(nanoseconds: 300_000_000)
        case "follow":
            // follow <row> <column>: clicks the foreign key arrow of that cell.
            let pieces = argument.split(separator: " ").compactMap { Int($0) }
            guard pieces.count == 2 else { throw DatabaseError.unsupported("follow <row> <column>") }
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.followReference(row: pieces[0], column: pieces[1])
            try await waitForIdle()
        case "addrow":
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.addRow(nil)
        case "save":
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.saveChanges(nil)
            try await waitForIdle()
        case "discard":
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.discardChanges(nil)
        case "truncate", "drop", "prompt":
            // truncate|drop <table> [fk] [cascade] stages directly; prompt truncate|drop <table> shows the question.
            var words = argument.split(separator: " ").map(String.init)
            let operationName = command == "prompt" ? (words.isEmpty ? "" : words.removeFirst()) : command
            guard let operation = TableOperationKind(rawValue: operationName), let name = words.first,
                  let workspace, let info = workspace.workspace.tables.first(where: { $0.name == name })
            else { throw DatabaseError.unsupported("\(command) <table> [fk] [cascade]") }
            let options = TableOperationOptions(ignoreForeignKeys: words.contains("fk"), cascade: words.contains("cascade"))
            workspace.toggleTableOperation(info, operation, options: command == "prompt" ? nil : options)
            try await Task.sleep(nanoseconds: 500_000_000)
        case "rename":
            let words = argument.split(separator: " ").map(String.init)
            guard words.count == 2, let workspace, let info = workspace.workspace.tables.first(where: { $0.name == words[0] }) else {
                throw DatabaseError.unsupported("rename <table> <new name>")
            }
            workspace.renameObject(info, to: words[1])
            try await waitForIdle()
        case "pagesize":
            (workspace?.tabs.selectedTab?.content as? TableTabViewController)?.setPageSize(Int(argument) ?? 100)
            try await waitForIdle()
        case "page":
            // page first|last|next|prev|<number>
            guard let table = workspace?.tabs.selectedTab?.content as? TableTabViewController else { return }
            switch argument {
            case "first": table.firstPage(nil)
            case "last": table.lastPage(nil)
            case "next": table.nextPage(nil)
            case "prev": table.previousPage(nil)
            default: table.goToPage((Int(argument) ?? 1) - 1)
            }
            try await waitForIdle()
        case "breaklink":
            // Shuts the socket down under the driver, as a dropped network would.
            try await workspace?.workspace.session.run { $0.abort() }
        case "healthcheck":
            await workspace?.workspace.checkHealth()
            try await waitForIdle()
        case "disconnect":
            workspace?.disconnect(nil)
            try await Task.sleep(nanoseconds: 800_000_000)
        case "reconnect":
            workspace?.reconnect(nil)
            try await Task.sleep(nanoseconds: 300_000_000)
            try await waitFor(seconds: 20) { self.workspace?.workspace.connectionState != .reconnecting }
        case "databases":
            record("  databases: " + (workspace?.workspace.databases.joined(separator: ", ") ?? ""))
        case "state":
            record("  state: \(String(describing: workspace?.workspace.connectionState))")
        case "refreshmeta":
            await workspace?.workspace.refreshMetadata()
        case "saveall":
            workspace?.saveAll(nil)
            try await waitForIdle()
        case "discardall":
            workspace?.discardAll(nil)
        case "previewsql":
            workspace?.previewSQL(nil)
            try await Task.sleep(nanoseconds: 500_000_000)
        case "sidebarmenu":
            // Lists the sidebar context menu for a table in the log.
            guard let workspace, let info = workspace.workspace.tables.first(where: { $0.name == argument }) else { throw DatabaseError.unsupported("sidebarmenu <table>") }
            record("  " + workspace.sidebarMenuTitles(for: info).joined(separator: " | "))
        case "query":
            workspace?.tabs.openQuery(sql: try Self.insertingFileHex(Self.queryText(argument)))
        case "run":
            (workspace?.tabs.selectedTab?.content as? QueryTabViewController)?.runAll(nil)
            try await waitForIdle()
        case "complete":
            // complete <snapshot.png>: opens the list at the end of the query, as ⌃Space does, and captures it.
            guard let query = workspace?.tabs.selectedTab?.content as? QueryTabViewController else { return }
            query.showCompletions()
            try await Task.sleep(nanoseconds: 600_000_000)
            recordCompletions(of: query)
            if let frame = query.completionFrame, let caret = query.completionCaretRect {
                record("  popup: \(Int(frame.width))x\(Int(frame.height)) at (\(Int(frame.minX)), \(Int(frame.minY))); caret (\(Int(caret.minX)), \(Int(caret.minY)))")
            }
            try snapshotWithChildWindows(named: argument.isEmpty ? "completion.png" : argument)
            query.hideCompletions()
        case "type":
            // type <text>: types at the caret one character at a time, so suggestions open as they would for a user.
            guard let query = workspace?.tabs.selectedTab?.content as? QueryTabViewController else { return }
            query.focusEditor()
            query.typeForTesting(Self.typedText(argument))
            try await Task.sleep(nanoseconds: 700_000_000)
            recordCompletions(of: query)
        case "accept":
            (workspace?.tabs.selectedTab?.content as? QueryTabViewController)?.acceptCompletionForTesting()
            try await Task.sleep(nanoseconds: 300_000_000)
        case "text":
            if let query = workspace?.tabs.selectedTab?.content as? QueryTabViewController {
                record("  text: " + query.sql.replacingOccurrences(of: "\n", with: "\\n") + "  [caret \(query.caretLocation)]")
            }
        case "keywordcase":
            // keywordcase upper|lower|matchTypedElseUpper|matchTypedElseLower, as the Settings picker writes it.
            guard let policy = KeywordCase(rawValue: argument) else { throw DatabaseError.unsupported("keywordcase <\(KeywordCase.allCases.map(\.rawValue).joined(separator: "|"))>") }
            var settings = AppEnvironment.settings
            settings.keywordCase = policy
            AppEnvironment.settings = settings
        case "autocomplete":
            // autocomplete on|off: the "Suggest completions while typing" setting.
            var settings = AppEnvironment.settings
            settings.autocompleteOnTyping = argument != "off"
            AppEnvironment.settings = settings
        case "rawtype", "rawkey":
            // rawtype <text> types into the filter bar's Raw SQL box; rawkey <down|up|return|tab|escape> presses a key there.
            guard let bar = filterBar else { throw DatabaseError.unsupported("No filter bar; use showfilters first") }
            if command == "rawtype" {
                bar.typeRawForTesting(Self.typedText(argument))
            } else if !bar.sendRawKeyForTesting(argument) {
                throw DatabaseError.unsupported("Unknown key \(argument)")
            }
            try await Task.sleep(nanoseconds: 600_000_000)
            let selected = bar.rawSelectedSuggestion.map { " [selected: \($0)]" } ?? " [no selection]"
            record("  raw suggestions (\(bar.rawSuggestionLabels.count)): " + bar.rawSuggestionLabels.joined(separator: ", ") + selected)
            record("  raw text: " + bar.rawTextForTesting)
        case "history":
            workspace?.toggleHistory(nil)
            try await Task.sleep(nanoseconds: 500_000_000)
        case "sidebarfilter":
            workspace?.applySidebarFilter(argument)
        case "settings":
            app?.showSettings(nil)
        case "about":
            app?.showAbout(nil)
        case "newtable", "newtablename", "newtablecomment", "newtablesection", "newtablecreate", "structureadd", "structureset",
             "structuredelete", "structurecomment", "structuresave", "structurestate", "structuremove", "structuremenu", "structuremenuitem",
             "structurekey", "confirm", "sidebarbackgroundmenu", "sheettext":
            try await performStructureCommand(command, argument)
        case "snapshot":
            try snapshot(named: argument.isEmpty ? "snapshot-\(log.count).png" : argument)
        case "snapshotpopup":
            // The window with an open suggestion list (editor popup or filter popover) drawn over it.
            try snapshotWithChildWindows(named: argument.isEmpty ? "popup-\(log.count).png" : argument)
        case "closewindow":
            frontWindow?.performClose(nil)
        case "quit":
            record("done")
            NSApp.terminate(nil)
        default:
            throw DatabaseError.unsupported("Unknown command \(command)")
        }
    }

    /// Replaces each `{{hexfile:/absolute/path}}` in a query with the file's bytes as hex digits, so scripts can seed
    /// binary columns from fixtures (`decode('{{hexfile:…}}', 'hex')`, `UNHEX('{{hexfile:…}}')`).
    static func insertingFileHex(_ sql: String) throws -> String {
        var result = sql
        while let start = result.range(of: "{{hexfile:"), let end = result.range(of: "}}", range: start.upperBound..<result.endIndex) {
            let path = String(result[start.upperBound..<end.lowerBound])
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            result.replaceSubrange(start.lowerBound..<end.upperBound, with: data.hexString)
        }
        return result
    }

    /// The SQL of a `query` command: `\\n` is a newline; everything else, a regex `\\s` included, is kept.
    static func queryText(_ argument: String) -> String {
        argument.replacingOccurrences(of: "\\n", with: "\n")
    }

    /// The keystrokes of `type` and `rawtype`. Commands are trimmed, so `\\s` stands for a space (a trailing one
    /// matters to completion) and `\\n` for Return.
    static func typedText(_ argument: String) -> String {
        queryText(argument).replacingOccurrences(of: "\\s", with: " ")
    }

    /// Every visible label of the editor's list, then the selected row.
    private func recordCompletions(of query: QueryTabViewController) {
        let labels = query.visibleCompletions
        let selected = query.selectedCompletion.map { " [selected: \($0)]" } ?? ""
        record("  suggestions (\(labels.count)): " + labels.joined(separator: ", ") + selected)
    }

    private var filterBar: FilterBarView? {
        guard let table = workspace?.tabs.selectedTab?.content as? TableTabViewController else { return nil }
        return Self.firstSubview(of: FilterBarView.self, in: table.view)
    }

    private static func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    // MARK: Structure editing and Create Table

    private var tableTab: TableTabViewController? { workspace?.tabs.selectedTab?.content as? TableTabViewController }

    /// The New Table sheet when it is open, otherwise the Structure view of the selected tab.
    private var draftEditor: StructureDraftEditor? {
        CreateTableController.presented?.editor ?? tableTab?.structureView.editor
    }

    private func performStructureCommand(_ command: String, _ argument: String) async throws {
        switch command {
        case "newtable":
            workspace?.newTable(nil)
            try await Task.sleep(nanoseconds: 500_000_000)
        case "newtablename":
            CreateTableController.presented?.setName(argument)
        case "newtablecomment":
            CreateTableController.presented?.setComment(argument)
        case "newtablesection":
            CreateTableController.presented?.showSection(StructureSection(rawValue: Int(argument) ?? 0) ?? .columns)
        case "newtablecreate":
            guard let sheet = CreateTableController.presented else { throw DatabaseError.unsupported("No New Table sheet") }
            sheet.create()
            try await Task.sleep(nanoseconds: 300_000_000)
            try await waitFor(seconds: 20) { !sheet.isCreating }
            try await waitForIdle()
        case "structureadd":
            if CreateTableController.presented == nil { tableTab?.addRow(nil) } else { draftEditor?.addRow() }
        case "structureset":
            // structureset <row> <key> <value>; `true`/`false` for checkboxes, `-` for an empty value.
            let pieces = argument.split(separator: " ", maxSplits: 2).map(String.init)
            guard pieces.count >= 2, let row = Int(pieces[0]) else { throw DatabaseError.unsupported("structureset <row> <key> <value>") }
            let raw = pieces.count > 2 ? pieces[2] : ""
            let checkKeys: Set<String> = ["nullable", "primary", "auto", "unique"]
            let value: StructureCellValue = checkKeys.contains(pieces[1]) ? .flag(raw == "true") : .text(raw == "-" ? "" : raw)
            draftEditor?.table.commitEditing()
            draftEditor?.setValue(value, row: row, key: pieces[1])
        case "structuredelete":
            draftEditor?.toggleDeletion(IndexSet(integer: Int(argument) ?? 0))
        case "structurecomment":
            tableTab?.structureView.setTableComment(argument == "-" ? "" : argument)
        case "structuremove":
            // structuremove <rows> <destination>: drops rows (comma-separated, from 0) above a row, as a drag would.
            let pieces = argument.split(separator: " ").map(String.init)
            let rows = IndexSet((pieces.first ?? "").split(separator: ",").compactMap { Int($0) })
            guard pieces.count == 2, let destination = Int(pieces[1]), !rows.isEmpty else { throw DatabaseError.unsupported("structuremove <rows> <destination>") }
            if draftEditor?.table.moveRows(rows, to: destination) != true { record("  refused: " + (tableTab?.structureView.reorderBlocker ?? "not movable")) }
        case "structuremenu":
            // Logs the context menu of a row: disabled items in brackets, with their tooltip.
            guard let editor = draftEditor, let row = Int(argument) else { throw DatabaseError.unsupported("structuremenu <row>") }
            editor.table.select(row: row)
            let items = editor.table.menuItems?(IndexSet(integer: row)) ?? []
            record("  menu: " + items.filter { !$0.isSeparatorItem }.map { item in
                item.isEnabled ? item.title : "[\(item.title)]" + (item.toolTip.map { " (\($0))" } ?? "")
            }.joined(separator: " | "))
        case "structuremenuitem":
            // structuremenuitem <row> <title>: chooses an item of that row's context menu.
            let pieces = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard let editor = draftEditor, pieces.count == 2, let row = Int(pieces[0]) else { throw DatabaseError.unsupported("structuremenuitem <row> <title>") }
            editor.table.select(row: row)
            guard let item = (editor.table.menuItems?(IndexSet(integer: row)) ?? []).first(where: { $0.title == pieces[1] }), let action = item.action else {
                throw DatabaseError.unsupported("No menu item \(pieces[1])")
            }
            if item.isEnabled { NSApp.sendAction(action, to: item.target, from: item) } else { record("  disabled: \(item.title)") }
        case "structurekey":
            // structurekey <row> up|down: ⌥⌘↑ / ⌥⌘↓ with the row selected and the list focused.
            let pieces = argument.split(separator: " ").map(String.init)
            guard let editor = draftEditor, pieces.count == 2, let row = Int(pieces[0]), let window = editor.window else { throw DatabaseError.unsupported("structurekey <row> up|down") }
            editor.table.select(row: row)
            window.makeFirstResponder(editor.table.tableView)
            let up = pieces[1] == "up"
            let characters = up ? "\u{F700}" : "\u{F701}"
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option, .numericPad, .function], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: up ? 126 : 125)
            else { return }
            if !window.performKeyEquivalent(with: event) { record("  key not handled") }
        case "structuresave":
            tableTab?.saveChanges(nil)
            try await Task.sleep(nanoseconds: 500_000_000)
        case "structurestate":
            if let draft = draftEditor?.draft {
                record("  pending: \(draft.changeCount), columns: \(draft.resultingColumns.map { "\($0.name) \($0.dataType)" }.joined(separator: ", "))")
            }
            if let preview = tableTab?.previewOfPendingChanges() {
                record("  preview: " + preview.replacingOccurrences(of: "\n", with: " | "))
            }
        case "confirm":
            // Presses the default button of the front sheet, as Return would.
            // The deepest sheet of any window: an alert can sit on top of the New Table sheet.
            var target = NSApp.windows.first { $0.attachedSheet != nil && $0.sheetParent == nil }
            while let sheet = target?.attachedSheet { target = sheet }
            // While the screen is locked a sheet waits unattached as a visible panel of its own.
            if target == nil {
                target = NSApp.orderedWindows.first { $0.isVisible && $0 is NSPanel && Self.defaultButton(in: $0.contentView) != nil }
            }
            // `confirm [title]`: the default button, else the named one, else the one that is not Cancel.
            let fallback = target.flatMap { Self.buttons(in: $0.contentView).last { argument.isEmpty ? $0.title != "Cancel" && !$0.title.isEmpty : $0.title == argument } }
            guard let target, let button = Self.defaultButton(in: target.contentView) ?? fallback else {
                let windows = NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) sheet=\($0.isSheet) attached=\($0.attachedSheet.map { "\(type(of: $0))" } ?? "-") buttons=\(Self.buttonTitles(in: $0.contentView))" }
                record("  windows: " + windows.joined(separator: " ; "))
                throw DatabaseError.unsupported("No sheet to confirm")
            }
            record("  pressed \(button.title)")
            button.performClick(nil)
            try await Task.sleep(nanoseconds: 300_000_000)
            if let tab = tableTab {
                try await waitFor(seconds: 20) { !tab.structureView.isSaving }
            }
            try await waitForIdle()
        case "sheettext":
            // Logs the labels of the front sheet, which offscreen snapshots cannot show for alerts.
            var target = NSApp.windows.first { $0.attachedSheet != nil && $0.sheetParent == nil }
            while let sheet = target?.attachedSheet { target = sheet }
            target = target ?? NSApp.orderedWindows.first { $0.isVisible && $0 is NSPanel }
            let texts = Self.labels(in: target?.contentView).filter { !$0.isEmpty }
            record("  sheet: " + texts.joined(separator: " | ").replacingOccurrences(of: "\n", with: " / "))
        case "sidebarbackgroundmenu":
            record("  " + (workspace?.sidebarBackgroundMenuTitles().joined(separator: " | ") ?? ""))
        default:
            break
        }
    }

    private static func labels(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { labels(in: $0) }
    }

    private static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }

    private static func buttonTitles(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSButton).map { ["\($0.title)[\($0.keyEquivalent == "\r" ? "return" : "")]"] } ?? []
        return own + view.subviews.flatMap { buttonTitles(in: $0) }
    }

    private static func defaultButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.keyEquivalent == "\r", button.isEnabled { return button }
        for child in view.subviews {
            if let found = defaultButton(in: child) { return found }
        }
        return nil
    }

    func waitFor(seconds: Double, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw DatabaseError.unsupported("Timed out") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func waitForIdle() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        try await waitFor(seconds: 20) { (self.workspace?.workspace.runningStatements ?? 0) == 0 }
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    /// Captures only Foxlume Query's frontmost window. `screencapture -l` renders materials exactly as on screen;
    /// when it is unavailable, the window is drawn offscreen instead (vibrant areas then render blank).
    func snapshot(named name: String) throws {
        let window = frontWindow
        guard let window, let frameView = window.contentView?.superview else { throw DatabaseError.unsupported("No window to snapshot") }
        // A sheet can carry its own sheet, such as an alert over New Table.
        var target = window
        while let sheet = target.attachedSheet { target = sheet }
        let url = snapshotDirectory.appendingPathComponent(name)
        if captureWindow(target.windowNumber, to: url) {
            record("  captured \(name)")
            return
        }
        try write(view: target.contentView?.superview ?? frameView, to: url)
    }

    /// The suggestion list is a child window. `screencapture -l` on a child window returns the parent with the child
    /// drawn over it, which is exactly the picture wanted. Region captures are avoided: the app runs in the
    /// background, so a region would show whatever window covers it.
    private func snapshotWithChildWindows(named name: String) throws {
        guard let window = frontWindow else { return record("  ! no window") }
        let target = window.childWindows?.first(where: \.isVisible) ?? window
        let url = snapshotDirectory.appendingPathComponent(name)
        if captureWindow(target.windowNumber, to: url) {
            return record("  captured \(name)")
        }
        // Without screen capture, draw the window and then the child window over it offscreen.
        guard let frameView = window.contentView?.superview, let image = Self.offscreenImage(of: frameView) else { return record("  ! capture failed") }
        let composite = NSImage(size: frameView.bounds.size)
        composite.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: frameView.bounds.size))
        if target !== window, let childView = target.contentView, let childImage = Self.offscreenImage(of: childView) {
            let origin = NSPoint(x: target.frame.minX - window.frame.minX, y: target.frame.minY - window.frame.minY)
            childImage.draw(in: NSRect(origin: origin, size: childView.bounds.size))
        }
        composite.unlockFocus()
        guard let tiff = composite.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return record("  ! capture failed")
        }
        try? png.write(to: url)
        record("  wrote \(name)")
    }

    private static func offscreenImage(of view: NSView) -> NSImage? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func captureWindow(_ windowNumber: Int, to url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(windowNumber)", url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
    }

    func write(view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
        record("  wrote \(url.lastPathComponent)")
    }
}

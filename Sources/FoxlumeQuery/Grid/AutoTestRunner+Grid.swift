import AppKit
import FoxlumeQueryCore

/// Scripted commands for the data grid: multi-column sort, advanced filters and presets, cell ranges, copy and paste.
/// They act on the grid of the selected tab (a table tab, or a query tab's results). Columns are named; rows count
/// from 0 on the page.
///
///     gridstate                         logs sort keys, cell selection, selected rows, status text and pending changes
///     sortclick <column> [shift]        a click (or Shift-click) on the column header
///     sortmenu <column> asc|desc|none   the header menu's Sort Ascending / Sort Descending / Don't Sort
///     headermenu <column>               logs the header menu
///     selectcells <row> <column> [<row> <column>]   a click, then a Shift-click on the second cell
///     cmdclick <row> <column>           ⌘-click: adds or removes one cell
///     selectcolumn <column> [add]       Select Column (or ⌘-click on the header with `add`)
///     cellkey <name>                    left|right|up|down, shift-…, cmd-shift-…, escape, shift-space
///     copycells [header]                ⌘C (⌥⌘C with `header`) and logs what was copied
///     pastetext <text>                  pastes text as ⌘V would; \t is a tab, \n a new line
///     cellmenu <row> <column>           logs the cell menu, the Filter submenu included
///     cellfilter <row> <column> <n>     chooses the n-th entry (from 1) of that cell's Filter submenu
///     fillcells                         Fill Selected Cells… (answer with fillvalue, then confirm)
///     fillcolumn <column>               the header menu's Fill Column…
///     fillvalue <text>|NULL             types into the open Fill sheet
///     filteradd <column> <op> [value] [| second] [matchcase]   adds a filter rule and applies
///     filterlogic and|or                how the rules combine, then applies
///     presetsave <name> / presetapply <name> / presetdelete <name> / presetlist   filter presets of the table
///     deleteselected / duplicateselected   the row commands on the selected rows
@MainActor
enum GridAutoTest {
    static let commands: Set<String> = [
        "gridstate", "sortclick", "sortmenu", "headermenu", "selectcells", "cmdclick", "selectcolumn", "cellkey", "copycells",
        "pastetext", "cellmenu", "cellfilter", "fillcells", "fillcolumn", "fillvalue", "filteradd", "filterlogic",
        "presetsave", "presetapply", "presetdelete", "presetlist", "deleteselected", "duplicateselected",
    ]
}

extension AutoTestRunner {
    func performGrid(_ command: String, _ argument: String) async throws {
        let words = argument.split(separator: " ").map(String.init)
        let tableTab = workspace?.tabs.selectedTab?.content as? TableTabViewController
        guard let grid = tableTab?.grid ?? (workspace?.tabs.selectedTab?.content as? QueryTabViewController)?.grid else {
            throw DatabaseError.unsupported("\(command) needs a table tab or query results")
        }
        func column(_ name: String) throws -> Int {
            if let index = grid.content.columns.firstIndex(where: { $0.name == name }) { return index }
            throw DatabaseError.unsupported("No column \(name)")
        }
        func cell(_ rowText: String, _ name: String) throws -> GridCell {
            guard let row = Int(rowText), let position = grid.displayPosition(ofDataColumn: try column(name)) else {
                throw DatabaseError.unsupported("\(command) <row> <column>")
            }
            return GridCell(row: row, column: position)
        }
        switch command {
        case "gridstate":
            logGridState(grid, tableTab: tableTab)
        case "sortclick":
            guard let name = words.first else { throw DatabaseError.unsupported("sortclick <column> [shift]") }
            grid.headerClicked(dataColumn: try column(name), additive: words.dropFirst().first == "shift")
            try await settle()
        case "sortmenu":
            guard words.count == 2 else { throw DatabaseError.unsupported("sortmenu <column> asc|desc|none") }
            let index = try column(words[0])
            let title = ["asc": "Sort Ascending", "desc": "Sort Descending", "none": "Don’t Sort"][words[1]] ?? ""
            guard let item = grid.headerMenu(forDataColumn: index)?.items.first(where: { $0.title == title }), let action = item.action else {
                throw DatabaseError.unsupported("No \(title) in the header menu")
            }
            NSApp.sendAction(action, to: item.target, from: item)
            try await settle()
        case "headermenu":
            guard let name = words.first, let menu = grid.headerMenu(forDataColumn: try column(name)) else { throw DatabaseError.unsupported("headermenu <column>") }
            record("  " + menu.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | "))
        case "selectcells":
            guard words.count == 2 || words.count == 4 else { throw DatabaseError.unsupported("selectcells <row> <column> [<row> <column>]") }
            var selection = GridSelection.single(try cell(words[0], words[1]))
            if words.count == 4 { selection.extend(to: try cell(words[2], words[3])) }
            grid.setCellSelection(selection)
            grid.window?.makeFirstResponder(grid.tableView)
        case "cmdclick":
            guard words.count == 2 else { throw DatabaseError.unsupported("cmdclick <row> <column>") }
            var selection = grid.cellSelection
            selection.toggle(try cell(words[0], words[1]))
            grid.setCellSelection(selection)
        case "selectcolumn":
            guard let name = words.first else { throw DatabaseError.unsupported("selectcolumn <column> [add]") }
            grid.selectColumn(try column(name), adding: words.dropFirst().first == "add")
        case "cellkey":
            guard let event = Self.keyEvent(argument, window: grid.window) else { throw DatabaseError.unsupported("Unknown key \(argument)") }
            grid.tableView.keyDown(with: event)
            try await Task.sleep(nanoseconds: 200_000_000)
        case "copycells":
            NSPasteboard.general.clearContents()
            if argument == "header" { grid.copyWithHeader(nil) } else { grid.copy(nil) }
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            record("  copied: " + copied.replacingOccurrences(of: "\t", with: "⇥").replacingOccurrences(of: "\r\n", with: " ⏎ ").replacingOccurrences(of: "\n", with: " ⏎ "))
        case "pastetext":
            grid.pasteText(Self.queryText(argument).replacingOccurrences(of: "\\t", with: "\t"))
            try await Task.sleep(nanoseconds: 300_000_000)
        case "cellmenu", "cellfilter":
            guard words.count >= 2, let row = Int(words[0]) else { throw DatabaseError.unsupported("\(command) <row> <column>") }
            let tableColumn = grid.tableView.tableColumns.firstIndex { $0.identifier.rawValue == "c\((try? column(words[1])) ?? -1)" } ?? -1
            // As a right-click would: a cell outside the selection is selected first.
            if tableColumn >= 0 {
                let frame = grid.tableView.frameOfCell(atColumn: tableColumn, row: row)
                grid.prepareContextSelection(at: NSPoint(x: frame.midX, y: frame.midY))
            }
            let menu = NSMenu()
            grid.populateContextMenu(menu, row: row, tableColumn: tableColumn)
            if command == "cellmenu" {
                record("  " + menu.items.map(Self.describe).joined(separator: " | "))
            } else {
                guard let index = words.dropFirst(2).first.flatMap(Int.init),
                      let item = menu.items.first(where: { $0.title == "Filter" })?.submenu?.items[safe: index - 1], let action = item.action
                else { throw DatabaseError.unsupported("cellfilter <row> <column> <n>") }
                record("  chose \(item.title)")
                NSApp.sendAction(action, to: item.target, from: item)
                try await settle()
            }
            grid.menuDidClose(menu)
        case "fillcells":
            grid.fillSelectedCells(nil)
            try await Task.sleep(nanoseconds: 400_000_000)
        case "fillcolumn":
            guard let name = words.first else { throw DatabaseError.unsupported("fillcolumn <column>") }
            grid.fillColumn(try column(name))
            try await Task.sleep(nanoseconds: 400_000_000)
        case "fillvalue":
            var sheet = NSApp.windows.first { $0.attachedSheet != nil }?.attachedSheet
            while let deeper = sheet?.attachedSheet { sheet = deeper }
            guard let sheet else { throw DatabaseError.unsupported("No Fill sheet") }
            if argument == "NULL" {
                Self.allSubviews(of: sheet.contentView).compactMap { $0 as? NSButton }.first { $0.title == "Set to NULL" }?.state = .on
            } else {
                Self.allSubviews(of: sheet.contentView).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "fillValue" }?.stringValue = argument
            }
        case "filteradd":
            guard let tableTab else { throw DatabaseError.unsupported("filteradd needs a table tab") }
            tableTab.applyFilters(tableTab.currentQuery.filters + [try Self.rule(argument)], raw: tableTab.currentQuery.rawWhere)
            try await settle()
        case "filterlogic":
            guard let tableTab else { throw DatabaseError.unsupported("filterlogic needs a table tab") }
            tableTab.applyFilters(tableTab.currentQuery.filters, raw: tableTab.currentQuery.rawWhere, logic: argument == "or" ? .or : .and)
            try await settle()
        case "presetsave", "presetapply", "presetdelete", "presetlist":
            guard let tableTab, let presets = tableTab.filterBar.presets else { throw DatabaseError.unsupported("\(command) needs a table tab with filters") }
            let saved = presets.store.presets(for: presets.scope)
            switch command {
            case "presetsave":
                tableTab.filterBar.configure(columns: grid.content.columns.map(\.name), rules: tableTab.currentQuery.filters, logic: tableTab.currentQuery.filterLogic,
                                             rawWhere: tableTab.currentQuery.rawWhere, capabilities: tableTab.workspace.capabilities)
                let preset = tableTab.filterBar.savePreset(named: argument)
                record("  saved \(preset?.name ?? "nothing")")
            case "presetapply":
                guard let preset = saved.first(where: { $0.name == argument }) else { throw DatabaseError.unsupported("No preset \(argument)") }
                if tableTab.filterBar.isHidden { tableTab.toggleFilters(nil) }
                tableTab.filterBar.applyPreset(preset)
                try await settle()
            case "presetdelete":
                guard let preset = saved.first(where: { $0.name == argument }) else { throw DatabaseError.unsupported("No preset \(argument)") }
                tableTab.filterBar.deletePreset(preset)
            default:
                record("  presets: " + saved.map { "\($0.name) [\($0.rules.map(\.summary).joined(separator: "; "))\($0.logic == .or ? " (any)" : "")]" }.joined(separator: ", "))
            }
        case "deleteselected":
            tableTab?.deleteSelectedRows(nil)
        case "duplicateselected":
            tableTab?.duplicateRows(nil)
        default:
            throw DatabaseError.unsupported("Unknown command \(command)")
        }
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        try await waitFor(seconds: 20) { (self.workspace?.workspace.runningStatements ?? 0) == 0 }
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private func logGridState(_ grid: DataGridView, tableTab: TableTabViewController?) {
        let sort = grid.sortKeys.enumerated().map { "\($0.offset + 1). \($0.element.column) \($0.element.ascending ? "asc" : "desc")" }
        record("  sort: " + (sort.isEmpty ? "none" : sort.joined(separator: ", ")))
        let headers = grid.tableView.tableColumns.compactMap { column -> String? in
            guard let cell = column.headerCell as? GridHeaderCell, cell.sortAscending != nil || cell.isColumnSelected else { return nil }
            let arrow = cell.sortAscending.map { $0 ? "▲" : "▼" } ?? ""
            let priority = (cell.sortPriority ?? 0) >= 2 ? "\(cell.sortPriority ?? 0)" : ""
            return "\(column.title)\(arrow)\(priority)\(cell.isColumnSelected ? "[selected]" : "")"
        }
        record("  header: " + (headers.isEmpty ? "plain" : headers.joined(separator: " ")))
        let selection = grid.cellSelection
        if selection.isEmpty {
            record("  cells: none")
        } else {
            let rects = selection.rectangles.map { rect -> String in
                let names = rect.columns.compactMap { grid.dataColumn(atDisplayPosition: $0).map { grid.content.columns[$0].name } }
                return "rows \(rect.rows.lowerBound)-\(rect.rows.upperBound) × \(names.joined(separator: ","))"
            }
            record("  cells: \(selection.cellCount) in " + rects.joined(separator: "; ") + (selection.active.map { " (active row \($0.row))" } ?? ""))
        }
        record("  selected rows: " + grid.selectedRows.map(String.init).joined(separator: ","))
        if let statistics = grid.selectionStatistics { record("  statistics: " + statistics.summary) }
        let ids = grid.content.rows.prefix(12).map { $0.first.map(DataGridView.displayText) ?? "" }
        record("  first column: " + ids.joined(separator: ", "))
        if let tableTab {
            let query = tableTab.currentQuery
            record("  filters: " + (query.filters.isEmpty ? "none" : query.filters.map(\.summary).joined(separator: query.filterLogic == .or ? " OR " : " AND ")))
            if let condition = query.whereClause(dialect: tableTab.workspace.dialect) { record("  where: " + condition) }
            record("  pending: \(grid.content.changes.changeCount) (\(grid.content.changes.updates.values.reduce(0) { $0 + $1.count }) cells, \(grid.content.changes.insertions.count) new, \(grid.content.changes.deletions.count) deleted)")
            if let preview = tableTab.previewOfPendingChanges() { record("  preview: " + preview.replacingOccurrences(of: "\n", with: " | ")) }
            record("  status: " + Self.label("tableStatus", in: tableTab.view))
        } else if let query = workspace?.tabs.selectedTab?.content as? QueryTabViewController {
            record("  status: " + Self.label("queryStatus", in: query.view) + " | selection: " + Self.label("querySelectionSummary", in: query.view))
        }
        if let refusal = grid.lastRefusal { record("  last refusal: " + refusal) }
    }

    private static func label(_ identifier: String, in view: NSView) -> String {
        allSubviews(of: view).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == identifier }?.stringValue ?? ""
    }

    private static func allSubviews(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private static func describe(_ item: NSMenuItem) -> String {
        if item.isSeparatorItem { return "—" }
        guard let submenu = item.submenu else { return item.title }
        return "\(item.title) [" + submenu.items.map(\.title).joined(separator: "; ") + "]"
    }

    /// `<column> <op> [value] [| second] [matchcase]`; the value may contain spaces.
    private static func rule(_ argument: String) throws -> FilterRule {
        var text = argument
        let matchCase = text.hasSuffix(" matchcase")
        if matchCase { text.removeLast(" matchcase".count) }
        let pieces = text.split(separator: " ", maxSplits: 2).map(String.init)
        guard pieces.count >= 2, let op = FilterOperator(rawValue: pieces[1]) else { throw DatabaseError.unsupported("filteradd <column> <op> [value] [| second] [matchcase]") }
        let values = (pieces.count > 2 ? pieces[2] : "").components(separatedBy: " | ")
        return FilterRule(column: pieces[0], op: op, value: values[0], secondValue: values.count > 1 ? values[1] : "", matchCase: matchCase)
    }

    private static func keyEvent(_ name: String, window: NSWindow?) -> NSEvent? {
        var parts = name.split(separator: "-").map(String.init)
        guard let key = parts.popLast() else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if parts.contains("shift") { flags.insert(.shift) }
        if parts.contains("cmd") { flags.insert(.command) }
        let codes: [String: (UInt16, String)] = ["left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
                                                 "escape": (53, "\u{1B}"), "space": (49, " "), "return": (36, "\r")]
        guard let (code, characters) = codes[key] else { return nil }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }
}

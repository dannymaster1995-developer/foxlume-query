import AppKit

/// Responder-chain selectors used by menu items. Declared here so the menu does not depend on the view controllers.
@objc protocol FoxlumeQueryActions {
    @objc optional func newQueryTab(_ sender: Any?)
    @objc optional func closeTab(_ sender: Any?)
    @objc optional func runCurrent(_ sender: Any?)
    @objc optional func runAll(_ sender: Any?)
    @objc optional func cancelQuery(_ sender: Any?)
    @objc optional func saveChanges(_ sender: Any?)
    @objc optional func discardChanges(_ sender: Any?)
    @objc optional func saveAll(_ sender: Any?)
    @objc optional func discardAll(_ sender: Any?)
    @objc optional func previewSQL(_ sender: Any?)
    @objc optional func reconnect(_ sender: Any?)
    @objc optional func disconnect(_ sender: Any?)
    @objc optional func addRow(_ sender: Any?)
    @objc optional func deleteSelectedRows(_ sender: Any?)
    @objc optional func refreshData(_ sender: Any?)
    @objc optional func refreshMetadata(_ sender: Any?)
    @objc optional func newTable(_ sender: Any?)
    @objc optional func newView(_ sender: Any?)
    @objc optional func toggleFilters(_ sender: Any?)
    @objc optional func showDataView(_ sender: Any?)
    @objc optional func showStructureView(_ sender: Any?)
    @objc optional func toggleHistory(_ sender: Any?)
    @objc optional func exportResults(_ sender: Any?)
    @objc optional func exportTables(_ sender: Any?)
    @objc optional func importCSV(_ sender: Any?)
    @objc optional func runSQLFile(_ sender: Any?)
    @objc optional func openSQLFile(_ sender: Any?)
    @objc optional func saveQueryAs(_ sender: Any?)
    @objc optional func openValueEditor(_ sender: Any?)
    @objc optional func formatQuery(_ sender: Any?)
    @objc optional func promptConnectionURL(_ sender: Any?)
    @objc optional func runWithoutLimit(_ sender: Any?)
    @objc optional func runStatementAndMoveToNext(_ sender: Any?)
    @objc optional func toggleWordWrap(_ sender: Any?)
    @objc optional func explainQuery(_ sender: Any?)
    @objc optional func explainAnalyzeQuery(_ sender: Any?)
    @objc optional func duplicateRows(_ sender: Any?)
    @objc optional func previousPage(_ sender: Any?)
    @objc optional func nextPage(_ sender: Any?)
    @objc optional func firstPage(_ sender: Any?)
    @objc optional func lastPage(_ sender: Any?)
    @objc optional func showGoToPage(_ sender: Any?)
    @objc optional func copyWithHeader(_ sender: Any?)
    @objc optional func copyAsJSON(_ sender: Any?)
    @objc optional func reopenClosedTab(_ sender: Any?)
    @objc optional func showDatabaseSwitcher(_ sender: Any?)
    @objc optional func toggleComment(_ sender: Any?)
    @objc optional func focusTableFilter(_ sender: Any?)
    @objc optional func openQuickly(_ sender: Any?)
    @objc optional func addToSavedQueries(_ sender: Any?)
    @objc optional func showSavedQueries(_ sender: Any?)
    @objc optional func selectNextTab(_ sender: Any?)
    @objc optional func selectPreviousTab(_ sender: Any?)
    @objc optional func selectTabByNumber(_ sender: Any?)
    @objc optional func showWelcome(_ sender: Any?)
    @objc optional func newConnection(_ sender: Any?)
    @objc optional func showSettings(_ sender: Any?)
    @objc optional func showAbout(_ sender: Any?)
    @objc optional func openProjectPage(_ sender: Any?)
    @objc optional func toggleInspector(_ sender: Any?)
    @objc optional func newDatabase(_ sender: Any?)
    @objc optional func dropDatabase(_ sender: Any?)
    @objc optional func newSchema(_ sender: Any?)
    @objc optional func dropSchema(_ sender: Any?)
    @objc optional func renameSchema(_ sender: Any?)
    @objc optional func renameDatabase(_ sender: Any?)
    @objc optional func copyDatabase(_ sender: Any?)
    @objc optional func reportIssue(_ sender: Any?)
    @objc optional func showERDiagram(_ sender: Any?)
    @objc optional func jumpToColumn(_ sender: Any?)
}

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("Foxlume Query", [
            item("About Foxlume Query", #selector(FoxlumeQueryActions.showAbout(_:))),
            .separator(),
            item("Settings…", #selector(FoxlumeQueryActions.showSettings(_:)), ","),
            .separator(),
            servicesItem(),
            .separator(),
            item("Hide Foxlume Query", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Foxlume Query", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("File", [
            item("New Connection…", #selector(FoxlumeQueryActions.newConnection(_:)), "n"),
            item("New Query Tab", #selector(FoxlumeQueryActions.newQueryTab(_:)), "t"),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            item("Open Connection URL…", #selector(FoxlumeQueryActions.promptConnectionURL(_:)), "k", [.command, .shift]),
            item("Open Quickly…", #selector(FoxlumeQueryActions.openQuickly(_:)), "o", [.command, .shift]),
            item("Save Query As…", #selector(FoxlumeQueryActions.saveQueryAs(_:)), "s", [.command, .shift]),
            item("Connections…", #selector(FoxlumeQueryActions.showWelcome(_:)), "0", [.command, .shift]),
            .separator(),
            item("Close Tab", #selector(FoxlumeQueryActions.closeTab(_:)), "w"),
            item("Reopen Closed Tab", #selector(FoxlumeQueryActions.reopenClosedTab(_:)), "t", [.command, .shift]),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
            .separator(),
            item("Export Results…", #selector(FoxlumeQueryActions.exportResults(_:)), "e", [.command, .shift]),
            item("Export Tables…", #selector(FoxlumeQueryActions.exportTables(_:)), "e", [.command, .option, .shift]),
            item("Import CSV into Table…", #selector(FoxlumeQueryActions.importCSV(_:)), "i", [.command, .shift]),
            item("Run SQL File…", #selector(FoxlumeQueryActions.runSQLFile(_:))),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            item("Copy with Headers", #selector(FoxlumeQueryActions.copyWithHeader(_:)), "c", [.command, .option]),
            item("Copy as JSON", #selector(FoxlumeQueryActions.copyAsJSON(_:)), "j", [.command, .option]),
            .separator(),
            item("Toggle Comment", #selector(FoxlumeQueryActions.toggleComment(_:)), "/"),
            .separator(),
            findMenu(),
        ]))
        main.addItem(submenu("Query", [
            item("Run Statement", #selector(FoxlumeQueryActions.runCurrent(_:)), "\r"),
            item("Run All", #selector(FoxlumeQueryActions.runAll(_:)), "\r", [.command, .shift]),
            item("Run Without Limit", #selector(FoxlumeQueryActions.runWithoutLimit(_:)), "\r", [.command, .option]),
            item("Run Statement and Move to Next", #selector(FoxlumeQueryActions.runStatementAndMoveToNext(_:)), "\r", [.command, .control]),
            item("Cancel Query", #selector(FoxlumeQueryActions.cancelQuery(_:)), "."),
            item("Explain", #selector(FoxlumeQueryActions.explainQuery(_:)), "e", [.command, .option]),
            item("Explain Analyze", #selector(FoxlumeQueryActions.explainAnalyzeQuery(_:)), "e", [.command, .control]),
            item("Format Query", #selector(FoxlumeQueryActions.formatQuery(_:)), "l", [.command, .shift]),
            item("Add to Saved Queries…", #selector(FoxlumeQueryActions.addToSavedQueries(_:)), "d"),
            .separator(),
            item("Save", #selector(FoxlumeQueryActions.saveAll(_:)), "s"),
            item("Discard Changes", #selector(FoxlumeQueryActions.discardAll(_:))),
            item("Preview SQL", #selector(FoxlumeQueryActions.previewSQL(_:)), "p", [.command, .shift]),
            item("Add Row", #selector(FoxlumeQueryActions.addRow(_:)), "n", [.command, .shift]),
            item("Duplicate Row", #selector(FoxlumeQueryActions.duplicateRows(_:)), "d", [.command, .shift]),
            item("Delete Selected Rows", #selector(FoxlumeQueryActions.deleteSelectedRows(_:)), "\u{8}", [.command]),
            item("Edit Cell Value…", #selector(FoxlumeQueryActions.openValueEditor(_:)), "\r", [.option]),
            .separator(),
            item("Filter Rows…", #selector(FoxlumeQueryActions.toggleFilters(_:)), "f", [.command, .shift]),
            item("Previous Page", #selector(FoxlumeQueryActions.previousPage(_:)), "[", [.command]),
            item("Next Page", #selector(FoxlumeQueryActions.nextPage(_:)), "]", [.command]),
            item("First Page", #selector(FoxlumeQueryActions.firstPage(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            item("Last Page", #selector(FoxlumeQueryActions.lastPage(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
            item("Go to Page…", #selector(FoxlumeQueryActions.showGoToPage(_:))),
            item("Refresh", #selector(FoxlumeQueryActions.refreshData(_:)), "r"),
        ]))
        main.addItem(submenu("Database", [
            item("Switch Database…", #selector(FoxlumeQueryActions.showDatabaseSwitcher(_:)), "k"),
            item("Refresh Table List", #selector(FoxlumeQueryActions.refreshMetadata(_:)), "r", [.command, .shift]),
            .separator(),
            item("New Table…", #selector(FoxlumeQueryActions.newTable(_:))),
            item("New View…", #selector(FoxlumeQueryActions.newView(_:))),
            item("New Database…", #selector(FoxlumeQueryActions.newDatabase(_:))),
            item("Rename Database…", #selector(FoxlumeQueryActions.renameDatabase(_:))),
            item("Copy Database…", #selector(FoxlumeQueryActions.copyDatabase(_:))),
            item("Drop Database…", #selector(FoxlumeQueryActions.dropDatabase(_:))),
            item("New Schema…", #selector(FoxlumeQueryActions.newSchema(_:))),
            item("Rename Schema…", #selector(FoxlumeQueryActions.renameSchema(_:))),
            item("Drop Schema…", #selector(FoxlumeQueryActions.dropSchema(_:))),
            .separator(),
            item("ER Diagram", #selector(FoxlumeQueryActions.showERDiagram(_:))),
            .separator(),
            item("Disconnect", #selector(FoxlumeQueryActions.disconnect(_:))),
            item("Reconnect", #selector(FoxlumeQueryActions.reconnect(_:))),
        ]))
        main.addItem(submenu("View", [
            item("Data", #selector(FoxlumeQueryActions.showDataView(_:)), "1", [.command, .option]),
            item("Structure", #selector(FoxlumeQueryActions.showStructureView(_:)), "2", [.command, .option]),
            .separator(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "0"),
            item("Query History", #selector(FoxlumeQueryActions.toggleHistory(_:)), "y"),
            item("Row Inspector", #selector(FoxlumeQueryActions.toggleInspector(_:)), "i", [.command, .option]),
            item("Saved Queries", #selector(FoxlumeQueryActions.showSavedQueries(_:))),
            item("Focus Sidebar Filter", #selector(FoxlumeQueryActions.focusTableFilter(_:)), "f", [.command, .option, .control]),
            item("Jump to Column…", #selector(FoxlumeQueryActions.jumpToColumn(_:)), "j", [.command, .control]),
            .separator(),
            item("Word Wrap", #selector(FoxlumeQueryActions.toggleWordWrap(_:)), "z", [.option]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        var windowItems: [NSMenuItem] = [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Show Next Tab", #selector(FoxlumeQueryActions.selectNextTab(_:)), "}", [.command]),
            item("Show Previous Tab", #selector(FoxlumeQueryActions.selectPreviousTab(_:)), "{", [.command]),
        ]
        for number in 1...9 {
            let tabItem = item(number == 9 ? "Last Tab" : "Tab \(number)", #selector(FoxlumeQueryActions.selectTabByNumber(_:)), "\(number)")
            tabItem.tag = number
            windowItems.append(tabItem)
        }
        windowItems += [.separator(), item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))]
        let window = submenu("Window", windowItems)
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        let help = submenu("Help", [
            item("Foxlume Query on GitHub", #selector(FoxlumeQueryActions.openProjectPage(_:))),
            item("Report an Issue…", #selector(FoxlumeQueryActions.reportIssue(_:))),
        ])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }

    private static func servicesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Services")
        item.submenu = menu
        NSApp.servicesMenu = menu
        return item
    }

    private static func findMenu() -> NSMenuItem {
        func find(_ title: String, _ tag: NSTextFinder.Action, _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let menuItem = item(title, #selector(NSResponder.performTextFinderAction(_:)), key, modifiers)
            menuItem.tag = tag.rawValue
            return menuItem
        }
        return submenu("Find", [
            find("Find…", .showFindInterface, "f"),
            find("Find and Replace…", .showReplaceInterface, "f", [.command, .option]),
            find("Find Next", .nextMatch, "g"),
            find("Find Previous", .previousMatch, "g", [.command, .shift]),
        ])
    }
}

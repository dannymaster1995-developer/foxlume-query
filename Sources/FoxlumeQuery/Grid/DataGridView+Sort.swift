import AppKit
import FoxlumeQueryCore

/// Multi-column sort from the header and the header's context menu. Table tabs sort on the server through the
/// delegate; query results (`isLocalSortEnabled`) are sorted here, in memory.
extension DataGridView {
    /// A click (or Shift-click with `additive`) on a column header.
    func headerClicked(dataColumn: Int, additive: Bool) {
        guard allowsColumnSort, let name = content.columns[safe: dataColumn]?.name else { return }
        changeSort(to: SortCycle.next(sortKeys, clicking: name, additive: additive))
    }

    /// Applies a new sort: in memory for query results, otherwise asks the delegate, which reloads the rows and
    /// then shows the sort it actually ran with `setSortIndicator`.
    func changeSort(to keys: [SortKey]) {
        guard allowsColumnSort else { return }
        if isLocalSortEnabled {
            sortKeys = keys
            applyLocalSort()
            setCellSelection(.empty)
            refreshFindMatches(keepPosition: false)
            tableView.reloadData()
            updateHeaderIndicators()
        } else {
            // Shown right away, so a second click before the rows arrive continues the cycle; the delegate puts the
            // old sort back with `setSortIndicator` when it refuses.
            sortKeys = keys
            updateHeaderIndicators()
            delegate?.dataGrid(self, didChangeSort: keys)
        }
    }

    /// Chevrons and key numbers on the header, plus the columns picked as a whole.
    func updateHeaderIndicators() {
        let fullColumns = cellSelection.fullColumns
        for tableColumn in tableView.tableColumns {
            guard let cell = tableColumn.headerCell as? GridHeaderCell, let column = dataColumnIndex(tableColumn) else { continue }
            let name = content.columns[safe: column]?.name
            let index = sortKeys.firstIndex { $0.column == name }
            let selected = displayPosition(ofDataColumn: column).map(fullColumns.contains) ?? false
            let ascending = index.map { sortKeys[$0].ascending }
            let priority = index.map { $0 + 1 }
            guard cell.sortAscending != ascending || cell.sortPriority != priority || cell.isColumnSelected != selected else { continue }
            cell.sortAscending = ascending
            cell.sortPriority = priority
            cell.isColumnSelected = selected
        }
        tableView.headerView?.needsDisplay = true
    }

    // MARK: Header menu

    func headerMenu(forDataColumn column: Int) -> NSMenu? {
        guard let name = content.columns[safe: column]?.name else { return nil }
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = column
            return item
        }
        if allowsColumnSort {
            menu.addItem(item("Sort Ascending", #selector(sortAscendingFromMenu(_:))))
            menu.addItem(item("Sort Descending", #selector(sortDescendingFromMenu(_:))))
            if !sortKeys.isEmpty {
                menu.addItem(item("Don’t Sort", #selector(clearSortFromMenu(_:))))
            }
            menu.addItem(.separator())
        }
        menu.addItem(item("Select Column", #selector(selectColumnFromMenu(_:))))
        let copyName = item("Copy Column Name", #selector(copyColumnName(_:)))
        copyName.representedObject = name
        menu.addItem(copyName)
        if isEditable, content.displayRowCount > 0, !isImmutable(column) {
            menu.addItem(item("Fill Column…", #selector(fillColumnFromMenu(_:))))
        }
        if allowsColumnFilter {
            menu.addItem(item("Filter with Column", #selector(filterWithColumn(_:))))
        }
        menu.addItem(.separator())
        addColumnItems(to: menu, column: column)
        return menu
    }

    @objc private func sortAscendingFromMenu(_ sender: NSMenuItem) { sortFromMenu(sender, ascending: true) }
    @objc private func sortDescendingFromMenu(_ sender: NSMenuItem) { sortFromMenu(sender, ascending: false) }

    private func sortFromMenu(_ sender: NSMenuItem, ascending: Bool) {
        guard let column = sender.representedObject as? Int, let name = content.columns[safe: column]?.name else { return }
        changeSort(to: [SortKey(column: name, ascending: ascending)])
    }

    @objc private func clearSortFromMenu(_ sender: NSMenuItem) {
        changeSort(to: [])
    }

    @objc private func selectColumnFromMenu(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? Int else { return }
        selectColumn(column, adding: false)
    }

    @objc private func copyColumnName(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
    }

    @objc private func fillColumnFromMenu(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? Int else { return }
        fillColumn(column)
    }

    @objc private func filterWithColumn(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? Int else { return }
        delegate?.dataGrid(self, filterColumn: column)
    }
}

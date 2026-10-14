import AppKit
import FoxlumeQueryCore

/// A cell position in the grid's data (display row, data column).
struct GridCellKey: Hashable {
    var row: Int
    var column: Int
}

/// ⌘F in a grid: find text in the loaded rows, step through matches, optionally search every row on the server.
extension DataGridView {
    func configureFindBar() {
        findBar.onChange = { [weak self] _ in self?.refreshFindMatches(keepPosition: false, jump: true) }
        findBar.onNext = { [weak self] in self?.stepFindMatch(by: 1) }
        findBar.onPrevious = { [weak self] in self?.stepFindMatch(by: -1) }
        findBar.onClose = { [weak self] in self?.hideFindBar() }
    }

    /// The Edit › Find menu (NSTextFinder actions) reaches the grid when it has focus.
    override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        switch NSTextFinder.Action(rawValue: tag) {
        case .nextMatch?:
            if findBar.isHidden { showFindBar() } else { stepFindMatch(by: 1) }
        case .previousMatch?:
            if findBar.isHidden { showFindBar() } else { stepFindMatch(by: -1) }
        default:
            showFindBar()
        }
    }

    func showFindBar() {
        findBar.onSearchServer = allowsServerSearch ? { [weak self] text in
            guard let self else { return }
            self.delegate?.dataGrid(self, searchServerFor: text)
        } : nil
        findBar.isHidden = false
        findBarHeight?.constant = 34
        window?.makeFirstResponder(findBar.field)
        refreshFindMatches(keepPosition: true)
    }

    func hideFindBar() {
        findBar.isHidden = true
        findBarHeight?.constant = 0
        findMatches = []
        findMatchSet = []
        currentFindMatch = nil
        tableView.reloadData()
        window?.makeFirstResponder(tableView)
    }

    /// Recomputes matches for the current text. `jump` moves to the first match after typing.
    func refreshFindMatches(keepPosition: Bool, jump: Bool = false) {
        let text = findBar.field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !findBar.isHidden, !text.isEmpty else {
            findMatches = []
            findMatchSet = []
            currentFindMatch = nil
            findBar.setCount(current: nil, total: 0, searching: false)
            if !findBar.isHidden { tableView.reloadData() }
            return
        }
        var matches: [GridCellKey] = []
        for row in 0..<content.displayRowCount {
            for column in content.columns.indices {
                guard let value = content.currentValue(row: row, column: column), !value.isAbsent else { continue }
                if value.displayString.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    matches.append(GridCellKey(row: row, column: column))
                }
            }
        }
        let previous = currentFindMatch.flatMap { findMatches[safe: $0] }
        findMatches = matches
        findMatchSet = Set(matches)
        if keepPosition, let previous, let index = matches.firstIndex(of: previous) {
            currentFindMatch = index
        } else {
            currentFindMatch = matches.isEmpty ? nil : 0
        }
        findBar.setCount(current: currentFindMatch, total: matches.count, searching: true)
        tableView.reloadData()
        if jump { revealCurrentFindMatch() }
    }

    func stepFindMatch(by delta: Int) {
        guard !findMatches.isEmpty else { return NSSound.beep() }
        let count = findMatches.count
        currentFindMatch = ((currentFindMatch ?? -delta) + delta + count) % count
        findBar.setCount(current: currentFindMatch, total: count, searching: true)
        tableView.reloadData()
        revealCurrentFindMatch()
    }

    private func revealCurrentFindMatch() {
        guard let index = currentFindMatch, let match = findMatches[safe: index] else { return }
        tableView.scrollRowToVisible(match.row)
        if let tableColumn = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "c\(match.column)" }) {
            tableView.scrollColumnToVisible(tableColumn)
        }
    }
}

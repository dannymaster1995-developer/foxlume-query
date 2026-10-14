import AppKit
import FoxlumeQueryCore

/// File › Open Quickly… (⇧⌘O): a search panel over the workspace window for tables, views, databases, schemas,
/// saved queries and recent history, ranked by fuzzy match and by how often and recently each was opened.
@MainActor
final class OpenQuicklyController: NSObject {
    /// The panel on screen; there is at most one.
    private(set) static weak var current: OpenQuicklyController?
    /// Keeps the shown panel alive; cleared when it closes.
    private static var retained: OpenQuicklyController?

    static let width: CGFloat = 640
    static let searchHeight: CGFloat = 50
    static let scopeHeight: CGFloat = 32
    static let footerHeight: CGFloat = 30
    static let rowHeight: CGFloat = 38
    static let headerHeight: CGFloat = 26
    static let visibleRows = 9

    private(set) weak var host: WorkspaceWindowController?
    private let catalog: OpenQuicklyCatalog
    private let panel = OpenQuicklyPanel()
    private let searchField = OpenQuicklySearchField()
    private let scopeBar = NSSegmentedControl(labels: QuickOpenScope.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let messageLabel = UI.label("", size: 13, color: .secondaryLabelColor)
    private let footer = UI.label("", size: 11, color: .tertiaryLabelColor)
    private let spinner = NSProgressIndicator()

    /// Chosen item and whether a new tab was asked for (⌘↩ / ⌥↩).
    var onCommit: ((QuickOpenItem, _ newTab: Bool) -> Void)?
    var onOpenStructure: ((QuickOpenItem) -> Void)?

    private enum Row {
        case header(String)
        case item(QuickOpenRow)
    }

    private var scope: QuickOpenScope = .all
    private var items: [QuickOpenItem] = []
    private var rows: [Row] = []
    private var frecency: [String: Double] = [:]
    private var recent: [String] = []
    /// Set once the user moves the selection; until then rows arriving late (other schemas) may take the top spot.
    private var userMovedSelection = false

    init(host: WorkspaceWindowController, others: [WorkspaceWindowController]) {
        self.host = host
        self.catalog = OpenQuicklyCatalog(host: host, others: others)
        super.init()
        let connection = host.workspace.config.id
        frecency = AppEnvironment.openQuicklyFrecency.scores(for: connection)
        recent = AppEnvironment.openQuicklyFrecency.recentKeys(for: connection, limit: QuickOpenFrecencyStore.itemsPerConnection)
        items = catalog.items()
        catalog.onChange = { [weak self] in self?.catalogChanged() }
        buildContent()
    }

    // MARK: Building

    private func buildContent() {
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.handle(event) ?? false }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = background

        let glass = NSImageView(image: Theme.image("magnifyingglass", "Search", size: 17) ?? NSImage())
        glass.contentTintColor = .secondaryLabelColor
        glass.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search tables, views, databases and queries"
        searchField.font = .systemFont(ofSize: 20)
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("openQuicklyField")
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false

        scopeBar.segmentStyle = .automatic
        scopeBar.controlSize = .small
        scopeBar.selectedSegment = 0
        scopeBar.target = self
        scopeBar.action = #selector(scopeChanged(_:))
        scopeBar.refusesFirstResponder = true
        scopeBar.translatesAutoresizingMaskIntoConstraints = false
        scopeBar.setAccessibilityIdentifier("openQuicklyScope")
        for (index, scope) in QuickOpenScope.allCases.enumerated() {
            scopeBar.setToolTip("\(scope.title) (⌘\(index + 1))", forSegment: index)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.floatsGroupRows = false
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.setAccessibilityIdentifier("openQuicklyResults")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.alignment = .center
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false

        let topLine = UI.separator()
        let bottomLine = UI.separator()
        for view in [glass, searchField, scopeBar, topLine, scroll, messageLabel, bottomLine, footer, spinner] as [NSView] {
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            glass.centerYAnchor.constraint(equalTo: background.topAnchor, constant: Self.searchHeight / 2),
            glass.widthAnchor.constraint(equalToConstant: 20),
            searchField.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            searchField.centerYAnchor.constraint(equalTo: glass.centerYAnchor),

            scopeBar.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.searchHeight),
            scopeBar.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            topLine.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.searchHeight + Self.scopeHeight),
            topLine.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: background.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: topLine.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomLine.topAnchor, constant: -4),
            messageLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -20),

            bottomLine.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.footerHeight),
            bottomLine.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            footer.centerYAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.footerHeight / 2),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -8),
            spinner.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            spinner.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        refilter()
    }

    // MARK: Showing

    func present() {
        guard let parent = host?.window else { return }
        Self.current?.close()
        Self.current = self
        Self.retained = self
        layoutPanel()
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func close() {
        guard Self.current === self || panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
        if Self.retained === self { Self.retained = nil }
        if let window = host?.window, window.isVisible { window.makeKeyAndOrderFront(nil) }
    }

    /// Centered on the window, its top a fifth of the way down; the height follows the rows.
    private func layoutPanel() {
        guard let parent = host?.window else { return }
        let width = min(Self.width, parent.frame.width - 40)
        var listHeight: CGFloat = 0
        var shownRows = 0
        for row in rows {
            guard shownRows < Self.visibleRows else { break }
            switch row {
            case .header: listHeight += Self.headerHeight
            case .item:
                listHeight += Self.rowHeight
                shownRows += 1
            }
        }
        if rows.isEmpty { listHeight = messageLabel.stringValue.isEmpty ? 0 : 64 }
        let height = Self.searchHeight + Self.scopeHeight + 1 + (listHeight > 0 ? listHeight + 8 : 0) + Self.footerHeight
        let top = parent.frame.maxY - parent.frame.height * 0.2
        let frame = NSRect(x: (parent.frame.midX - width / 2).rounded(), y: (top - height).rounded(), width: width, height: height)
        panel.setFrame(frame, display: true)
        scroll.isHidden = rows.isEmpty
    }

    // MARK: Filtering

    private var queryText: String { searchField.stringValue }

    private func refilter(keepSelection: Bool = false) {
        let previous = keepSelection ? selectedItem?.id : nil
        let sections = QuickOpenRanker.sections(items: items, query: queryText, scope: scope, frecency: frecency, recent: recent)
        rows = sections.flatMap { section -> [Row] in
            (section.title.map { [Row.header($0)] } ?? []) + section.rows.map(Row.item)
        }
        table.reloadData()
        let trimmed = queryText.trimmingCharacters(in: .whitespaces)
        if rows.isEmpty {
            messageLabel.stringValue = trimmed.isEmpty ? (catalog.isLoadingContainers ? "Loading…" : "Nothing to show here yet.") : "No results for “\(trimmed)”"
        } else {
            messageLabel.stringValue = ""
        }
        messageLabel.isHidden = !rows.isEmpty
        let target = previous.flatMap { id in rows.firstIndex { if case .item(let row) = $0 { return row.item.id == id } else { return false } } }
        selectRow(target ?? firstItemRow)
        updateFooter()
        if panel.isVisible { layoutPanel() }
    }

    private func catalogChanged() {
        items = catalog.items()
        refilter(keepSelection: userMovedSelection)
    }

    /// Other schemas are loaded once the user searches or picks a table scope, as they are only needed then.
    private func loadMoreIfNeeded() {
        if !queryText.trimmingCharacters(in: .whitespaces).isEmpty || scope == .tables || scope == .connections {
            catalog.loadOtherContainers()
        }
    }

    private func updateFooter() {
        let escape = queryText.isEmpty ? "⎋ Close" : "⎋ Clear"
        footer.stringValue = ["↩ Open", "⌘↩ New Tab", "⌘1–5 Scope", escape].joined(separator: "     ")
        if catalog.isLoadingContainers { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func scopeChanged(_ sender: Any?) {
        setScope(QuickOpenScope(rawValue: scopeBar.selectedSegment) ?? .all)
    }

    func setScope(_ newScope: QuickOpenScope) {
        scope = newScope
        userMovedSelection = false
        scopeBar.selectedSegment = newScope.rawValue
        loadMoreIfNeeded()
        refilter()
    }

    // MARK: Selection

    private func isHeader(_ index: Int) -> Bool {
        if case .header = rows[index] { return true }
        return false
    }

    private var firstItemRow: Int? {
        rows.firstIndex { if case .item = $0 { return true } else { return false } }
    }

    private var selectedItem: QuickOpenItem? {
        guard rows.indices.contains(table.selectedRow), case .item(let row) = rows[table.selectedRow] else { return nil }
        return row.item
    }

    private func selectRow(_ index: Int?) {
        guard let index else { return table.deselectAll(nil) }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    /// Moves by one item, skipping section headers and stopping at either end.
    private func moveSelection(by offset: Int) {
        guard !rows.isEmpty else { return }
        var index = table.selectedRow < 0 ? (offset > 0 ? -1 : rows.count) : table.selectedRow
        repeat {
            index += offset
            guard rows.indices.contains(index) else { return }
        } while isHeader(index)
        userMovedSelection = true
        selectRow(index)
    }

    // MARK: Keys

    /// Keys the panel handles before the search field sees them.
    private func handle(_ event: NSEvent) -> Bool {
        // Typing with an input method keeps its own Return, Escape and arrows.
        if let editor = searchField.currentEditor() as? NSTextView, editor.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (event.keyCode, flags) {
        case (125, []): return perform("down")
        case (126, []): return perform("up")
        case (36, []), (76, []): return perform("return")
        case (36, [.command]), (76, [.command]): return perform("cmd-return")
        case (36, [.option]), (76, [.option]): return perform("opt-return")
        case (53, []): return perform("escape")
        default: break
        }
        if flags == [.control], ["n", "p", "j", "k"].contains(characters) { return perform("ctrl-" + characters) }
        if flags == [.command], let digit = Int(characters), (1...QuickOpenScope.allCases.count).contains(digit) { return perform("cmd-\(digit)") }
        if flags == [.command, .shift], characters == "o" { return perform("toggle") }
        return false
    }

    /// One named key: down, up, return, cmd-return, opt-return, escape, ctrl-n/p/j/k, cmd-1…cmd-5, toggle.
    @discardableResult
    func perform(_ key: String) -> Bool {
        switch key {
        case "down", "ctrl-n", "ctrl-j": moveSelection(by: 1)
        case "up", "ctrl-p", "ctrl-k": moveSelection(by: -1)
        case "return": commit(newTab: false)
        case "cmd-return", "opt-return": commit(newTab: true)
        case "escape":
            if queryText.isEmpty {
                close()
            } else {
                setQuery("")
            }
        case "toggle": close()
        default:
            guard key.hasPrefix("cmd-"), let digit = Int(key.dropFirst(4)), let newScope = QuickOpenScope(rawValue: digit - 1) else { return false }
            setScope(newScope)
        }
        return true
    }

    /// Replaces the search text as typing would.
    func setQuery(_ text: String) {
        searchField.stringValue = text
        queryDidChange()
    }

    private func queryDidChange() {
        userMovedSelection = false
        loadMoreIfNeeded()
        refilter()
    }

    private func commit(newTab: Bool) {
        guard let item = selectedItem else { return NSSound.beep() }
        AppEnvironment.openQuicklyFrecency.record(item.key, connection: item.connectionID)
        close()
        onCommit?(item, newTab)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard table.clickedRow >= 0, case .item = rows[table.clickedRow] else { return }
        selectRow(table.clickedRow)
        commit(newTab: false)
    }

    // MARK: Scripted checks

    /// Section headers as "[Title]", then one line per row: "> " marks the selection, «» the highlighted characters.
    func rowDescriptions(limit: Int = 30) -> [String] {
        rows.prefix(limit).enumerated().map { index, row in
            switch row {
            case .header(let title): return "[\(title)]"
            case .item(let row):
                var title = row.item.title as NSString
                for range in row.highlights.reversed() where NSMaxRange(range) <= title.length {
                    title = title.replacingCharacters(in: range, with: "«" + title.substring(with: range) + "»") as NSString
                }
                let marker = index == table.selectedRow ? "> " : "  "
                let open = row.item.isOpen ? " {open}" : ""
                return "\(marker)\(row.item.kind.rawValue): \(title)\(open) — \(row.item.subtitle)"
            }
        }
    }

    var scopeTitle: String { scope.title }
    var panelFrame: NSRect { panel.frame }
}

// MARK: - Search field

extension OpenQuicklyController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        queryDidChange()
    }
}

extension OpenQuicklyController: NSWindowDelegate {
    /// Clicking elsewhere closes the panel, as a menu would.
    func windowDidResignKey(_ notification: Notification) {
        guard Self.current === self else { return }
        // A sheet or alert from the chosen item takes key after the panel already closed.
        DispatchQueue.main.async { [weak self] in
            guard let self, Self.current === self, !self.panel.isKeyWindow else { return }
            self.close()
        }
    }
}

// MARK: - Results

extension OpenQuicklyController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return Self.headerHeight }
        return Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    /// Only clicks ask; a clicked row keeps its selection when late rows arrive.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard case .item = rows[row] else { return false }
        userMovedSelection = true
        return true
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        OpenQuicklyRowBackground()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let identifier = NSUserInterfaceItemIdentifier("header")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? OpenQuicklyHeaderView ?? OpenQuicklyHeaderView(identifier: identifier)
            cell.title = title
            return cell
        case .item(let item):
            let identifier = NSUserInterfaceItemIdentifier("row")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? OpenQuicklyRowView ?? OpenQuicklyRowView(identifier: identifier)
            cell.configure(item, selected: row == tableView.selectedRow)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // The selected row shows what Return does instead of its subtitle.
        for index in 0..<table.numberOfRows {
            guard case .item(let item) = rows[index], let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? OpenQuicklyRowView else { continue }
            cell.configure(item, selected: index == table.selectedRow)
        }
    }
}

// MARK: - Context menu

extension OpenQuicklyController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard table.clickedRow >= 0, case .item(let row) = rows[table.clickedRow] else { return }
        selectRow(table.clickedRow)
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("Open", #selector(menuOpen(_:)))
        if row.item.kind.isTableLike || row.item.kind.isQuery { add("Open in New Tab", #selector(menuOpenInNewTab(_:))) }
        if row.item.kind.isTableLike, row.item.isCurrentConnection { add("Open Structure", #selector(menuStructure(_:))) }
        menu.addItem(.separator())
        add("Copy Name", #selector(menuCopyName(_:)))
        if row.item.sql != nil { add("Copy Query", #selector(menuCopyQuery(_:))) }
    }

    @objc private func menuOpen(_ sender: Any?) { commit(newTab: false) }
    @objc private func menuOpenInNewTab(_ sender: Any?) { commit(newTab: true) }

    @objc private func menuStructure(_ sender: Any?) {
        guard let item = selectedItem else { return }
        AppEnvironment.openQuicklyFrecency.record(item.key, connection: item.connectionID)
        close()
        onOpenStructure?(item)
    }

    @objc private func menuCopyName(_ sender: Any?) {
        guard let item = selectedItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.title, forType: .string)
    }

    @objc private func menuCopyQuery(_ sender: Any?) {
        guard let sql = selectedItem?.sql else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sql, forType: .string)
    }
}

/// Borderless, so it needs to opt in to key status for its search field. Keys are offered to the controller first.
final class OpenQuicklyPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: OpenQuicklyController.width, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = true
        setAccessibilityIdentifier("openQuickly")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Command keys reach the window before the main menu here, so ⌘1…⌘5 pick a scope instead of a tab.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

/// The search field, without the bezel and focus ring.
final class OpenQuicklySearchField: NSTextField {}

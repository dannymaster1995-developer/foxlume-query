import AppKit
import FoxlumeQueryCore

/// A table opened from the sidebar: paged data with editing, or its structure.
@MainActor
final class TableTabViewController: NSViewController, WorkspaceTabContent {
    enum Mode: Int {
        case data = 0
        case structure = 1
    }

    let workspace: ConnectionWorkspace
    let table: TableRef
    var onStateChange: (() -> Void)?
    /// Opens a table filtered to the rows a foreign key points at.
    var onOpenReference: ((TableRef, [FilterRule]) -> Void)?

    private var mode: Mode
    private var query: TableQuery
    private(set) var structure: TableStructure?
    private var totalRows: Int?
    private var loadGeneration = 0
    private var isLoading = false {
        didSet { updateEditability() }
    }
    private var isSaving = false {
        didSet { updateEditability() }
    }
    /// The database this tab's rows came from; MySQL table refs carry no database name.
    private let openedDatabase: String?

    let grid = DataGridView()
    private let inspector = RowInspectorView()
    /// Grid and, when shown, the row inspector beside it.
    private lazy var dataStack: NSStackView = {
        inspector.translatesAutoresizingMaskIntoConstraints = false
        inspector.widthAnchor.constraint(equalToConstant: 320).isActive = true
        inspector.isHidden = true
        let divider = UI.separator(vertical: true)
        divider.isHidden = true
        let stack = NSStackView(views: [grid, divider, inspector])
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .height
        stack.detachesHiddenViews = true
        stack.distribution = .fill
        grid.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }()
    private var inspectorDivider: NSView? { dataStack.arrangedSubviews[safe: 1] }
    /// Per-tab history of grid edits, separate from the window's text undo.
    private let editUndoManager = UndoManager()
    let filterBar = FilterBarView()
    private var filterBarHeight: NSLayoutConstraint?
    private lazy var structureController = StructureViewController(workspace: workspace, table: table)
    private let contentContainer = NSView()

    private let modePicker = NSSegmentedControl(labels: ["Data", "Structure"], trackingMode: .selectOne, target: nil, action: nil)
    private let statusLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator()
    private lazy var addRowButton = UI.iconButton("plus", tooltip: "Add Row (⇧⌘N)", target: self, action: #selector(addRow(_:)))
    private lazy var deleteRowButton = UI.iconButton("minus", tooltip: "Delete Selected Rows (⌫)", target: self, action: #selector(deleteSelectedRows(_:)))
    private lazy var discardButton = UI.button("Discard", target: self, action: #selector(discardChanges(_:)))
    private lazy var saveButton = UI.button("Save Changes", target: self, action: #selector(saveChanges(_:)))
    private lazy var filterButton = UI.button("Filters", symbol: "line.3.horizontal.decrease.circle", target: self, action: #selector(toggleFilters(_:)))
    private lazy var firstButton = UI.iconButton("chevron.backward.to.line", tooltip: "First Page (⌥⌘↑)", target: self, action: #selector(firstPage(_:)))
    private lazy var previousButton = UI.iconButton("chevron.left", tooltip: "Previous Page (⌘[)", target: self, action: #selector(previousPage(_:)))
    private lazy var nextButton = UI.iconButton("chevron.right", tooltip: "Next Page (⌘])", target: self, action: #selector(nextPage(_:)))
    private lazy var lastButton = UI.iconButton("chevron.forward.to.line", tooltip: "Last Page (⌥⌘↓)", target: self, action: #selector(lastPage(_:)))
    /// "2 of 9"; clicking it asks for a page to jump to.
    private lazy var pageButton: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(showGoToPage(_:)))
        button.isBordered = false
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Go to Page"
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    private let pageSizeButton = NSPopUpButton(frame: .zero, pullsDown: true)
    static let pageSizePresets = [5, 10, 20, 100, 500, 1_000]
    static let maximumPageSize = 1_000_000
    private lazy var refreshButton = UI.iconButton("arrow.clockwise", tooltip: "Refresh (⌘R)", target: self, action: #selector(refreshData(_:)))

    init(workspace: ConnectionWorkspace, table: TableRef, initialMode: Mode = .data, initialFilters: [FilterRule] = []) {
        self.workspace = workspace
        self.table = table
        self.mode = initialMode
        self.query = TableQuery(table: table, pageSize: workspace.capabilities.preferredPageSize ?? AppEnvironment.settings.rowsPerPage)
        self.query.filters = initialFilters
        self.openedDatabase = workspace.currentDatabase
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var tabTitle: String { table.name }
    var tabSymbol: String {
        let kind = workspace.tables.first { $0.ref == table }?.kind ?? .table
        return Theme.symbol(for: kind)
    }

    var hasUnsavedChanges: Bool { !grid.content.changes.isEmpty || structureController.hasPendingChanges }

    /// Save, Discard, Undo and Preview act on the structure edits while the Structure view is shown.
    private var structureMode: Bool { mode == .structure }

    private var isView: Bool {
        let kind = workspace.tables.first { $0.ref == table }?.kind ?? .table
        return kind == .view || kind == .materializedView
    }

    private var canEdit: Bool { !workspace.isReadOnly && !isView && !isStale }

    /// True after the connection switched to another database (for example `USE` in a query tab).
    private var isStale: Bool {
        // Redis tables are databases themselves, so a database switch never makes them stale.
        workspace.kind.supportsMultipleDatabases && workspace.capabilities.supportsDatabaseSwitching && workspace.currentDatabase != openedDatabase
    }

    /// Editing is paused while rows are loading or being saved, so no edit lands on rows about to be replaced.
    private func updateEditability() {
        grid.isEditable = canEdit && !isLoading && !isSaving
        grid.readOnlyReason = readOnlyReason
        updateControls()
    }

    /// Why the rows cannot be changed right now, for the paste and fill alerts.
    private var readOnlyReason: String? {
        if workspace.isReadOnly { return "This connection is read-only." }
        if isView { return "“\(table.name)” is a view; its rows cannot be edited here." }
        if isStale { return "The connection switched to another database. Reopen “\(table.name)” from the sidebar to edit it." }
        if isLoading || isSaving { return "The rows are being loaded or saved. Try again in a moment." }
        return nil
    }

    override func loadView() {
        let root = NSView()
        grid.delegate = self
        grid.allowsColumnSort = workspace.capabilities.supportsColumnSort
        if case .columns = workspace.capabilities.browseFilterStyle { grid.allowsColumnFilter = true }
        grid.immutableColumns = workspace.capabilities.immutableColumns
        grid.allowsSQLExpressions = workspace.kind.isSQL
        grid.allowsServerSearch = workspace.kind.isSQL
        grid.allowsDefaultKeyword = workspace.kind.isSQL && workspace.kind != .sqlite
        grid.isEditable = canEdit
        grid.readOnlyReason = readOnlyReason
        grid.tableNameForCopy = table.name
        grid.dialectForCopy = workspace.dialect
        grid.showsRowNumbers = AppEnvironment.settings.showRowNumbers
        grid.translatesAutoresizingMaskIntoConstraints = false

        filterBar.translatesAutoresizingMaskIntoConstraints = false
        filterBar.isHidden = true
        filterBar.onApply = { [weak self] rules, raw, logic in self?.applyFilters(rules, raw: raw, logic: logic) }
        filterBar.presets = (AppEnvironment.filterPresets, FilterPresetScope(connectionID: workspace.config.id, database: openedDatabase, schema: table.schema, table: table.name))
        filterBar.rawCompletion = workspace.rawFilterCompletion(for: table)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubviewFilling(dataStack)
        inspector.onEdit = { [weak self] column, value in
            guard let self, let row = self.inspectedRow else { return }
            self.applyEdit(row: row, column: column, value: value)
        }

        modePicker.selectedSegment = mode.rawValue
        modePicker.target = self
        modePicker.action = #selector(modeChanged(_:))
        modePicker.controlSize = .small
        modePicker.setAccessibilityIdentifier("tableMode")

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        saveButton.keyEquivalent = ""
        saveButton.bezelColor = .controlAccentColor
        saveButton.setAccessibilityIdentifier("saveChanges")
        discardButton.setAccessibilityIdentifier("discardChanges")
        addRowButton.setAccessibilityIdentifier("addRow")
        statusLabel.setAccessibilityIdentifier("tableStatus")
        statusLabel.alignment = .center

        let bottom = NSView()
        bottom.translatesAutoresizingMaskIntoConstraints = false
        let leading = UI.hstack([modePicker, UI.separator(vertical: true), addRowButton, deleteRowButton], spacing: 6)
        pageSizeButton.controlSize = .small
        pageSizeButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pageSizeButton.bezelStyle = .texturedRounded
        pageSizeButton.isBordered = false
        pageSizeButton.toolTip = "Rows per page"
        pageSizeButton.setAccessibilityIdentifier("pageSize")
        pageSizeButton.translatesAutoresizingMaskIntoConstraints = false
        pageButton.setAccessibilityIdentifier("pageIndicator")
        let navigation = UI.hstack([firstButton, previousButton, pageButton, nextButton, lastButton], spacing: 2)
        let trailing = UI.hstack([discardButton, saveButton, filterButton, pageSizeButton, navigation, refreshButton], spacing: 6)
        let center = UI.hstack([spinner, statusLabel], spacing: 6)
        bottom.addSubview(leading)
        bottom.addSubview(center)
        bottom.addSubview(trailing)
        let topLine = UI.separator()
        bottom.addSubview(topLine)
        NSLayoutConstraint.activate([
            bottom.heightAnchor.constraint(equalToConstant: 34),
            topLine.topAnchor.constraint(equalTo: bottom.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: bottom.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: bottom.trailingAnchor),
            leading.leadingAnchor.constraint(equalTo: bottom.leadingAnchor, constant: 10),
            leading.centerYAnchor.constraint(equalTo: bottom.centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: bottom.trailingAnchor, constant: -10),
            trailing.centerYAnchor.constraint(equalTo: bottom.centerYAnchor),
            center.centerXAnchor.constraint(equalTo: bottom.centerXAnchor).withPriority(.defaultLow),
            center.centerYAnchor.constraint(equalTo: bottom.centerYAnchor),
            center.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 12),
            center.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
            leading.heightAnchor.constraint(equalToConstant: 20),
        ])
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        root.addSubview(filterBar)
        root.addSubview(contentContainer)
        root.addSubview(bottom)
        NSLayoutConstraint.activate([
            filterBar.topAnchor.constraint(equalTo: root.topAnchor),
            filterBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        filterBarHeight = filterBar.heightAnchor.constraint(equalToConstant: 0)
        filterBarHeight?.isActive = true
        view = root
        updateControls()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(workspaceMetadataChanged), name: ConnectionWorkspace.metadataDidChange, object: workspace)
        addChild(structureController)
        structureController.canEdit = { [weak self] in self?.canEdit ?? false }
        structureController.saveBlocker = { [weak self] in
            self?.grid.content.changes.isEmpty == false ? "Save or discard the data edits in this tab before changing its structure." : nil
        }
        structureController.onChange = { [weak self] in self?.changesDidChange() }
        structureController.onSaved = { [weak self] in self?.reloadAfterStructureChange() }
        setMode(mode, force: true)
        loadStructureThenData()
    }

    // MARK: Mode

    func setMode(_ newMode: Mode, force: Bool = false) {
        guard newMode != mode || force else { return }
        mode = newMode
        modePicker.selectedSegment = newMode.rawValue
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        switch newMode {
        case .data:
            contentContainer.addSubviewFilling(dataStack)
        case .structure:
            contentContainer.addSubviewFilling(structureController.view)
            structureController.load()
        }
        updateControls()
    }

    @objc private func modeChanged(_ sender: Any?) {
        setMode(Mode(rawValue: modePicker.selectedSegment) ?? .data)
    }

    @objc func showDataView(_ sender: Any?) { setMode(.data) }
    @objc func showStructureView(_ sender: Any?) { setMode(.structure) }

    @objc private func workspaceMetadataChanged() {
        updateEditability()
    }

    // MARK: Loading

    /// Columns may be gone or renamed, so sorting and filters on them are dropped before the rows reload.
    private func reloadAfterStructureChange() {
        guard grid.content.changes.isEmpty else { return }
        let known = Set((workspace.cachedStructure(of: table) ?? structure)?.columns.map(\.name) ?? [])
        query.sort = []
        query.filters = query.filters.filter { known.contains($0.column) }
        query.page = 0
        totalRows = nil
        loadStructureThenData()
    }

    private func loadStructureThenData() {
        Task {
            structure = try? await workspace.structure(of: table)
            if let columns = structure?.columns.map(\.name), query.sort.isEmpty, let key = structure?.primaryKey.first, columns.contains(key) {
                query.sort = [SortKey(column: key, ascending: true)]
                grid.setSortIndicator(query.sort)
            }
            loadPage()
        }
    }

    private func loadPage(keepChanges: Bool = false) {
        guard !isStale else {
            lastError = DatabaseError.unsupported("The connection switched to database “\(workspace.currentDatabase ?? "")”. Reopen this table from the sidebar.")
            updateControls()
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        updateControls()
        let query = self.query
        Task {
            do {
                let started = Date()
                let result = try await workspace.fetchRows(query)
                guard generation == loadGeneration else { return }
                var content = DataGridContent(columns: result.columns, rows: result.rows, rowOffset: query.page * query.pageSize)
                if keepChanges {
                    content.changes = grid.content.changes
                } else {
                    // Undo steps refer to row positions on the page they were made on.
                    editUndoManager.removeAllActions()
                }
                grid.setContent(content)
                grid.setSortIndicator(query.sort)
                grid.referenceColumns = referenceColumnIndexes(for: result.columns)
                refreshInspector()
                lastLoadDuration = Date().timeIntervalSince(started)
                lastError = nil
                isLoading = false
                updateControls()
                onStateChange?()

                if let count = try? await workspace.countRows(query), generation == loadGeneration {
                    totalRows = count
                    updateControls()
                }
            } catch {
                guard generation == loadGeneration else { return }
                lastError = error
                isLoading = false
                updateControls()
            }
        }
    }

    private var lastLoadDuration: TimeInterval?
    private var lastError: Error?

    @objc func refreshData(_ sender: Any?) {
        guard !isSaving else { return NSSound.beep() }
        if mode == .structure {
            structureController.reload()
            return
        }
        guard !hasUnsavedChanges else {
            Alerts.confirm("Discard unsaved changes and reload?", detail: "Reloading replaces the rows on screen.", confirmTitle: "Discard and Reload", destructive: true, in: view.window) { [weak self] confirmed in
                guard confirmed, let self else { return }
                self.grid.setChanges(PendingChanges())
                self.editUndoManager.removeAllActions()
                self.loadPage()
            }
            return
        }
        loadPage()
    }

    // MARK: Row inspector

    private var inspectedRow: Int? {
        let rows = grid.selectedRows
        return rows.count == 1 ? rows.first : nil
    }

    @objc func toggleInspector(_ sender: Any?) {
        setMode(.data)
        inspector.isHidden.toggle()
        inspectorDivider?.isHidden = inspector.isHidden
        refreshInspector()
    }

    var isInspectorVisible: Bool { !inspector.isHidden }

    /// Selects one grid row, as a click would. Used by scripted UI checks.
    func selectRow(_ row: Int) {
        grid.selectRow(row)
    }

    private func refreshInspector() {
        guard !inspector.isHidden else { return }
        let font = Theme.monospaced(CGFloat(AppEnvironment.settings.gridFontSize))
        let selected = grid.selectedRows
        guard let row = inspectedRow else {
            let message = selected.count > 1 ? "\(selected.count) rows selected." : nil
            inspector.show(title: "Row", fields: [], font: font, message: message)
            return
        }
        let types = Dictionary((structure?.columns ?? []).map { ($0.name, $0.dataType) }, uniquingKeysWith: { first, _ in first })
        let deleted = grid.content.changes.deletions.contains(row)
        let fields = grid.content.columns.indices.map { column -> RowInspectorView.Field in
            let info = grid.content.columns[column]
            return RowInspectorView.Field(
                name: info.name,
                type: types[info.name] ?? info.typeName,
                value: grid.content.currentValue(row: row, column: column),
                editable: grid.isEditable && !deleted && !grid.isImmutable(column)
            )
        }
        inspector.show(title: "Row \((grid.content.rowOffset + row + 1).groupedText)", fields: fields, font: font)
    }

    // MARK: Foreign keys

    private func referenceColumnIndexes(for columns: [ResultColumn]) -> Set<Int> {
        let names = Set(structure?.foreignKeys.flatMap(\.columns) ?? [])
        return Set(columns.indices.filter { names.contains(columns[$0].name) })
    }

    /// The foreign key a column belongs to; a column in several keys uses the first.
    private func foreignKey(forColumn column: Int) -> ForeignKeyInfo? {
        guard let name = grid.content.columns[safe: column]?.name else { return nil }
        return structure?.foreignKeys.first { $0.columns.contains(name) }
    }

    /// Opens the referenced table filtered to the row this one points at (every column of a composite key).
    func followReference(row: Int, column: Int) {
        guard let key = foreignKey(forColumn: column) else { return NSSound.beep() }
        var rules: [FilterRule] = []
        for (own, referenced) in zip(key.columns, key.referencedColumns) {
            guard let index = grid.content.columns.firstIndex(where: { $0.name == own }),
                  let value = grid.content.currentValue(row: row, column: index)
            else { return NSSound.beep() }
            rules.append(value.isNull ? FilterRule(column: referenced, op: .isNull) : FilterRule(column: referenced, op: .equals, value: value.displayString))
        }
        onOpenReference?(key.referencedTable, rules)
    }

    @objc private func followReferenceFromMenu(_ sender: NSMenuItem) {
        guard let position = sender.representedObject as? [Int], position.count == 2 else { return }
        followReference(row: position[0], column: position[1])
    }

    // MARK: Paging

    private var pageCount: Int? {
        guard let totalRows else { return nil }
        return max(1, Int(ceil(Double(totalRows) / Double(query.pageSize))))
    }

    @objc func previousPage(_ sender: Any?) {
        guard query.page > 0 else { return }
        goToPage(query.page - 1)
    }

    @objc func nextPage(_ sender: Any?) {
        if let pageCount, query.page + 1 >= pageCount { return }
        goToPage(query.page + 1)
    }

    @objc func firstPage(_ sender: Any?) {
        goToPage(0)
    }

    /// Needs an exact row count, as in TablePro.
    @objc func lastPage(_ sender: Any?) {
        guard let pageCount else { return NSSound.beep() }
        goToPage(pageCount - 1)
    }

    /// Zero-based; clamped to the known pages.
    func goToPage(_ page: Int) {
        let target = max(0, pageCount.map { min(page, $0 - 1) } ?? page)
        guard target != query.page, confirmLeavingPage() else { return }
        query.page = target
        loadPage()
    }

    @objc func showGoToPage(_ sender: Any?) {
        guard let pageCount, pageCount > 1 else { return NSSound.beep() }
        let field = NSTextField(string: "\(query.page + 1)")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let alert = NSAlert()
        alert.messageText = "Go to Page"
        alert.informativeText = "1 to \(pageCount.groupedText)"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let number = Int(field.stringValue.filter(\.isNumber)), number >= 1 else { return }
            self?.goToPage(number - 1)
        }
    }

    /// Keeps the first row on screen visible after the change.
    func setPageSize(_ size: Int) {
        let size = min(max(1, size), Self.maximumPageSize)
        guard size != query.pageSize, confirmLeavingPage() else { return rebuildPageSizeMenu() }
        query.page = (query.page * query.pageSize) / size
        query.pageSize = size
        loadPage()
    }

    private func rebuildPageSizeMenu() {
        let menu = NSMenu()
        // A pull-down button shows its first item as the title.
        menu.addItem(NSMenuItem(title: query.pageSize.groupedText, action: nil, keyEquivalent: ""))
        var sizes = Self.pageSizePresets
        if !sizes.contains(query.pageSize) { sizes = (sizes + [query.pageSize]).sorted() }
        for size in sizes {
            let item = NSMenuItem(title: size.groupedText, action: #selector(pageSizeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = size
            item.state = size == query.pageSize ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let all = NSMenuItem(title: "All Rows…", action: totalRows == nil ? nil : #selector(showAllRows(_:)), keyEquivalent: "")
        all.target = self
        menu.addItem(all)
        let custom = NSMenuItem(title: "Custom…", action: #selector(customPageSize(_:)), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
        pageSizeButton.menu = menu
    }

    @objc private func pageSizeChosen(_ sender: NSMenuItem) {
        setPageSize(sender.tag)
    }

    @objc private func showAllRows(_ sender: Any?) {
        guard let totalRows else { return }
        guard totalRows > 10_000 else { return setPageSize(max(totalRows, 1)) }
        Alerts.confirm("Show all \(totalRows.groupedText) \(rowNouns) on one page?", detail: "Large pages take longer to load and use more memory.", confirmTitle: "Show All", in: view.window) { [weak self] confirmed in
            if confirmed { self?.setPageSize(totalRows) }
        }
    }

    @objc private func customPageSize(_ sender: Any?) {
        let field = NSTextField(string: "\(query.pageSize)")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        field.alignment = .right
        let alert = NSAlert()
        alert.messageText = "Rows per Page"
        alert.informativeText = "1 to \(Self.maximumPageSize.groupedText)"
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let size = Int(field.stringValue.filter(\.isNumber)), size >= 1 else { return }
            self?.setPageSize(size)
        }
    }

    private func confirmLeavingPage() -> Bool {
        guard hasUnsavedChanges else { return true }
        Alerts.showError(DatabaseError.unsupported("Save or discard your changes before changing page."), title: "Unsaved changes", in: view.window)
        return false
    }

    // MARK: Filters

    @objc func toggleFilters(_ sender: Any?) {
        setMode(.data)
        let show = filterBar.isHidden
        filterBar.isHidden = !show
        filterBarHeight?.isActive = !show
        if show {
            filterBar.configure(columns: grid.content.columns.map(\.name), rules: query.filters, logic: query.filterLogic, rawWhere: query.rawWhere, capabilities: workspace.capabilities)
            filterBar.addRuleIfEmpty()
        }
    }

    /// Opens the filter bar with a new rule for `column` (header menu "Filter with Column").
    func showFilters(adding rule: FilterRule) {
        if filterBar.isHidden {
            setMode(.data)
            filterBar.isHidden = false
            filterBarHeight?.isActive = false
            filterBar.configure(columns: grid.content.columns.map(\.name), rules: query.filters, logic: query.filterLogic, rawWhere: query.rawWhere, capabilities: workspace.capabilities)
        }
        filterBar.addFilterRule(rule)
    }

    /// `logic` nil keeps how the current rules combine (adding a rule from a cell menu).
    func applyFilters(_ rules: [FilterRule], raw: String, logic: FilterLogic? = nil) {
        guard confirmLeavingPage() else { return }
        query.filters = rules
        if let logic { query.filterLogic = logic }
        query.rawWhere = raw
        query.page = 0
        totalRows = nil
        loadPage()
    }

    // MARK: Editing

    @objc func addRow(_ sender: Any?) {
        if structureMode { return structureController.addRow() }
        guard grid.isEditable else { return NSSound.beep() }
        setMode(.data)
        var changes = grid.content.changes
        changes.addInsertion(columnCount: grid.content.columns.count)
        commit(changes, action: "Add Row")
        let row = grid.content.displayRowCount - 1
        grid.scrollToRow(row)
        DispatchQueue.main.async { self.grid.beginEditing(row: row, tableColumn: 1) }
    }

    @objc func deleteSelectedRows(_ sender: Any?) {
        if structureMode { return structureController.deleteSelectedRows() }
        guard grid.isEditable else { return NSSound.beep() }
        deleteRows(grid.targetRows())
    }

    private func deleteRows(_ rows: IndexSet) {
        var changes = grid.content.changes
        let loaded = grid.content.rows.count
        let insertions = rows.filter { $0 >= loaded }.map { $0 - loaded }
        let existing = rows.filter { $0 < loaded }
        let allDeleted = existing.allSatisfy { changes.deletions.contains($0) }
        for row in existing {
            if allDeleted || !changes.deletions.contains(row) { changes.toggleDeletion(row: row) }
        }
        changes.removeInsertions(insertions)
        commit(changes, action: allDeleted ? "Restore Rows" : "Delete Rows")
    }

    /// Copies the selected rows into new rows. Auto-increment keys and immutable columns start as DEFAULT.
    @objc func duplicateRows(_ sender: Any?) {
        guard grid.isEditable else { return NSSound.beep() }
        let rows = grid.targetRows()
        guard !rows.isEmpty else { return NSSound.beep() }
        let autoColumns = Set(structure?.columns.filter(\.isAutoIncrement).map(\.name) ?? [])
        let immutable = workspace.capabilities.immutableColumns
        var changes = grid.content.changes
        for row in rows {
            let values: [InsertValue] = grid.content.columns.indices.map { column in
                let name = grid.content.columns[column].name
                guard !autoColumns.contains(name), !immutable.contains(name),
                      let value = grid.content.currentValue(row: row, column: column), value != .missing
                else { return .useDefault }
                return .value(value)
            }
            changes.addInsertion(values)
        }
        commit(changes, action: rows.count == 1 ? "Duplicate Row" : "Duplicate Rows")
        grid.scrollToRow(grid.content.displayRowCount - 1)
    }

    func applyEdit(row: Int, column: Int, value: CellValue) {
        dataGrid(grid, didEditRow: row, column: column, value: value)
    }

    func showValueEditor(row: Int, column: Int) {
        setMode(.data)
        grid.scrollToRow(row)
        grid.presentValueEditor(row: row, column: column)
    }

    func markDeleted(row: Int) {
        deleteRows(IndexSet(integer: row))
    }

    /// For scripted checks of the structure editor.
    var structureView: StructureViewController { structureController }

    func showStructureSection(_ index: Int) {
        setMode(.structure)
        structureController.showSection(index)
    }

    @objc func exportResults(_ sender: Any?) {
        guard let window = view.window, !grid.content.rows.isEmpty else { return NSSound.beep() }
        ExportPanel.run(columns: grid.content.columns, rows: grid.content.rows, suggestedName: table.name, tableName: table.name, dialect: workspace.dialect, in: window)
    }

    @objc func discardChanges(_ sender: Any?) {
        if structureMode { return structureController.discardChanges() }
        guard !isSaving else { return NSSound.beep() }
        commit(PendingChanges(), action: "Discard Changes")
    }

    /// Applies new pending edits and records how to return to the current ones.
    func commit(_ changes: PendingChanges, action: String) {
        let previous = grid.content.changes
        editUndoManager.registerUndo(withTarget: self) { target in
            target.commit(previous, action: action)
        }
        editUndoManager.setActionName(action)
        grid.setChanges(changes)
        changesDidChange()
    }

    /// The field editor while a grid cell is being edited; typing undo belongs to it.
    private var activeCellEditor: NSTextView? {
        guard let editor = view.window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView, field.isDescendant(of: structureMode ? structureController.view : grid)
        else { return nil }
        return editor
    }

    @objc func undo(_ sender: Any?) {
        if let editor = activeCellEditor {
            editor.undoManager?.undo()
            return
        }
        activeUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        if let editor = activeCellEditor {
            editor.undoManager?.redo()
            return
        }
        activeUndoManager.redo()
    }

    /// Grid edits and structure edits keep separate histories.
    private var activeUndoManager: UndoManager {
        structureMode ? (structureController.undoManagerForEdits ?? editUndoManager) : editUndoManager
    }

    /// After a truncate: forget edits and show the table from its first page.
    func reloadAfterExternalChange() {
        grid.setChanges(PendingChanges())
        editUndoManager.removeAllActions()
        query.page = 0
        totalRows = nil
        changesDidChange()
        loadPage()
    }

    /// What Save would run for the grid edits, for Preview SQL. Nil without edits.
    func previewOfPendingChanges() -> String? {
        if structureMode { return structureController.previewOfPendingChanges() }
        let changes = grid.content.changes
        guard !changes.isEmpty else { return nil }
        guard workspace.kind.isSQL else {
            return "// \(changeSummary(changes))"
        }
        do {
            let statements = try SQLStatementGenerator.statements(
                table: table,
                columns: grid.content.columns.map(\.name),
                primaryKey: structure?.primaryKey ?? [],
                originalRows: grid.content.rows,
                changes: changes,
                dialect: workspace.dialect
            )
            return statements.map { $0 + ";" }.joined(separator: "\n")
        } catch {
            return "-- \(error.localizedDescription)"
        }
    }

    private func changeSummary(_ changes: PendingChanges) -> String {
        "Edit \(table.name): \(changes.updates.count) updated, \(changes.insertions.count) inserted, \(changes.deletions.count) deleted \(workspace.capabilities.rowNoun)s"
    }

    @objc func saveChanges(_ sender: Any?) {
        if structureMode { return structureController.saveChanges() }
        view.window?.makeFirstResponder(grid.tableView)
        let changes = grid.content.changes
        guard !changes.isEmpty, !isSaving else { return }
        guard !isStale else {
            Alerts.showError(DatabaseError.unsupported("The connection switched to another database, so these edits can no longer be saved to “\(table.name)”. Discard them and reopen the table."), title: "Changes were not saved", in: view.window)
            return
        }
        let primaryKey = structure?.primaryKey ?? []
        let batch = ChangeBatch(table: table, columns: grid.content.columns, primaryKey: primaryKey, originalRows: grid.content.rows, changes: changes)
        let summary: String
        let shownStatements: [String]
        if workspace.kind.isSQL {
            let statements: [String]
            do {
                statements = try SQLStatementGenerator.statements(
                    table: table,
                    columns: grid.content.columns.map(\.name),
                    primaryKey: primaryKey,
                    originalRows: grid.content.rows,
                    changes: changes,
                    dialect: workspace.dialect
                )
            } catch {
                Alerts.showError(error, title: "Could not prepare the changes", in: view.window)
                return
            }
            summary = ([workspace.dialect.beginStatement] + statements + ["COMMIT"]).joined(separator: ";\n")
            shownStatements = statements
        } else {
            summary = changeSummary(changes)
            shownStatements = [summary]
        }
        let needsUpdateOrDelete = !changes.updates.isEmpty || !changes.deletions.isEmpty
        let warnings = primaryKey.isEmpty && needsUpdateOrDelete && workspace.kind.isSQL
            ? "“\(table.name)” has no primary key. Rows are matched by all their current values; if a change matches several identical rows, nothing is saved."
            : nil
        let execute = { [weak self] in self?.execute(batch, summary: summary) }
        let count = changes.changeCount
        SafeModeGate.authorize(
            config: workspace.config,
            statements: shownStatements,
            writes: true,
            action: "Save \(count) change\(count == 1 ? "" : "s") to \(table.name)",
            extraDetail: warnings,
            in: view.window
        ) { confirmed in
            if confirmed { execute() }
        }
    }

    private func execute(_ batch: ChangeBatch, summary: String) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            do {
                try await workspace.applyChanges(batch, summary: summary)
                isSaving = false
                grid.setChanges(PendingChanges())
                editUndoManager.removeAllActions()
                changesDidChange()
                loadPage()
            } catch {
                isSaving = false
                Alerts.showError(error, title: "Changes were not saved", in: view.window)
            }
        }
    }

    private func changesDidChange() {
        updateControls()
        refreshInspector()
        onStateChange?()
    }

    // MARK: UI state

    private var rowNouns: String { workspace.capabilities.rowNoun + "s" }

    private func updateControls() {
        let changes = grid.content.changes
        let dirty = structureMode ? structureController.hasPendingChanges : !changes.isEmpty
        let count = structureMode ? structureController.pendingChangeCount : changes.changeCount
        let saving = structureMode ? structureController.isSaving : isSaving
        saveButton.isHidden = !dirty
        discardButton.isHidden = !dirty
        saveButton.isEnabled = !saving
        discardButton.isEnabled = !saving
        saveButton.title = dirty ? "Save \(count) Change\(count == 1 ? "" : "s")" : "Save Changes"
        addRowButton.isHidden = !canEdit || mode != .data
        deleteRowButton.isHidden = !canEdit || mode != .data
        addRowButton.isEnabled = grid.isEditable
        deleteRowButton.isEnabled = grid.isEditable
        filterButton.isHidden = mode != .data
        let filtered = !query.filters.filter(\.isEnabled).isEmpty || !query.rawWhere.isEmpty
        filterButton.contentTintColor = filtered ? .controlAccentColor : nil
        filterButton.title = filtered ? "Filters (\(query.filters.filter(\.isEnabled).count + (query.rawWhere.isEmpty ? 0 : 1)))" : "Filters"
        for control in [firstButton, previousButton, pageButton, nextButton, lastButton, pageSizeButton] as [NSView] {
            control.isHidden = mode != .data
        }
        let busy = isLoading || isSaving
        previousButton.isEnabled = query.page > 0 && !busy
        firstButton.isEnabled = query.page > 0 && !busy
        nextButton.isEnabled = (pageCount.map { query.page + 1 < $0 } ?? (grid.content.rows.count >= query.pageSize)) && !busy
        lastButton.isEnabled = pageCount.map { query.page + 1 < $0 } == true && !busy
        pageButton.isEnabled = (pageCount ?? 0) > 1 && !busy
        pageSizeButton.isEnabled = !busy
        pageButton.title = pageCount.map { "\((query.page + 1).groupedText) of \($0.groupedText)" } ?? "\(query.page + 1)"
        rebuildPageSizeMenu()

        if isLoading || isSaving {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        if let lastError {
            statusLabel.stringValue = lastError.localizedDescription
            statusLabel.textColor = .systemRed
            statusLabel.toolTip = lastError.localizedDescription
            return
        }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.toolTip = nil
        guard mode == .data else {
            statusLabel.stringValue = ""
            return
        }
        let loaded = grid.content.rows.count
        var parts: [String] = []
        let selected = grid.selectedRows.count
        if let statistics = grid.selectionStatistics {
            parts.append(statistics.summary)
        } else if selected > 0 {
            parts.append("\(selected) of \(loaded.groupedText) \(rowNouns) selected")
        } else if loaded == 0 {
            parts.append(isLoading ? "Loading…" : "No \(rowNouns)")
        } else {
            let first = query.page * query.pageSize + 1
            let range = "\(first.groupedText)–\((first + loaded - 1).groupedText)"
            parts.append(totalRows.map { "\(range) of \($0.groupedText) \(rowNouns)" } ?? "\(range) \(rowNouns)")
        }
        if let lastLoadDuration, !isLoading { parts.append(lastLoadDuration.durationText) }
        if isSaving { parts.append("saving…") }
        if workspace.isReadOnly { parts.append("read-only") } else if isView { parts.append("view") }
        statusLabel.stringValue = parts.joined(separator: " · ")
    }
}

extension TableTabViewController: DataGridViewDelegate {
    func dataGrid(_ grid: DataGridView, didEditRow row: Int, column: Int, value: CellValue) {
        guard grid.isEditable else { return NSSound.beep() }
        var changes = grid.content.changes
        if grid.content.isInserted(row) {
            changes.setInsertValue(.value(value), insertion: row - grid.content.rows.count, column: column)
        } else {
            guard let original = grid.content.rows[safe: row]?[safe: column] else { return }
            changes.setValue(value, row: row, column: column, original: original)
        }
        commit(changes, action: "Edit Cell")
    }

    func dataGrid(_ grid: DataGridView, didChangeSort sort: [SortKey]) {
        guard confirmLeavingPage() else {
            grid.setSortIndicator(query.sort)
            return
        }
        query.sort = sort
        query.page = 0
        loadPage()
    }

    func dataGridSelectionDidChange(_ grid: DataGridView) {
        updateControls()
        refreshInspector()
    }

    func dataGridDeleteSelectedRows(_ grid: DataGridView) {
        guard grid.isEditable else { return NSSound.beep() }
        deleteRows(grid.targetRows())
    }

    func dataGrid(_ grid: DataGridView, followReferenceAtRow row: Int, column: Int) {
        followReference(row: row, column: column)
    }

    /// Filters on the server to rows where any column contains `text`, as raw SQL so column filters stay as they are.
    func dataGrid(_ grid: DataGridView, searchServerFor text: String) {
        let columns = grid.content.columns.map(\.name)
        guard !columns.isEmpty else { return }
        applyFilters(query.filters, raw: TableQuery.anyColumnContains(text, columns: columns, dialect: workspace.dialect))
    }

    /// "Search All Rows" with `text`. Used by scripted UI checks.
    func searchAllRows(_ text: String) {
        dataGrid(grid, searchServerFor: text)
    }

    /// Opens the find bar with `text`. Used by scripted UI checks.
    func find(_ text: String) {
        setMode(.data)
        grid.showFindBar()
        grid.findBar.field.stringValue = text
        grid.refreshFindMatches(keepPosition: false, jump: true)
    }

    func dataGrid(_ grid: DataGridView, extraMenuItemsFor rows: IndexSet) -> [NSMenuItem] {
        guard let cell = grid.contextCell, let column = grid.dataColumnIndex(atTableColumn: cell.tableColumn) else { return [] }
        var items: [NSMenuItem] = []
        if workspace.capabilities.supportsFieldRemoval, grid.isEditable, !grid.isImmutable(column) {
            let remove = NSMenuItem(title: "Remove Field", action: #selector(removeField(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = column
            items.append(remove)
        }
        if cell.row < grid.content.rows.count, let key = foreignKey(forColumn: column) {
            let item = NSMenuItem(title: "Open Referenced Row in “\(key.referencedTable.name)”", action: #selector(followReferenceFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [cell.row, column]
            items.append(item)
        }
        if cell.row < grid.content.rows.count, case .columns = workspace.capabilities.browseFilterStyle,
           let filter = filterMenuItem(row: cell.row, column: column) {
            items.append(filter)
        }
        return items
    }

    /// MongoDB: drops the field from the selected documents on save (`$unset`).
    @objc private func removeField(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? Int else { return }
        for row in grid.targetRows() {
            dataGrid(grid, didEditRow: row, column: column, value: .missing)
        }
    }

    /// Adds a rule from the cell menu's Filter submenu to the filters in place.
    func addFilter(_ rule: FilterRule) {
        applyFilters(query.filters + [rule], raw: query.rawWhere)
    }

    var currentQuery: TableQuery { query }
}

extension TableTabViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            menuItem.title = activeUndoManager.undoMenuItemTitle
            return activeUndoManager.canUndo
        case #selector(redo(_:)):
            menuItem.title = activeUndoManager.redoMenuItemTitle
            return activeUndoManager.canRedo
        case #selector(toggleInspector(_:)):
            menuItem.state = isInspectorVisible ? .on : .off
            return true
        case #selector(saveChanges(_:)), #selector(discardChanges(_:)):
            if structureMode { return structureController.hasPendingChanges && !structureController.isSaving }
            return !grid.content.changes.isEmpty && !isSaving
        case #selector(addRow(_:)), #selector(deleteSelectedRows(_:)):
            return structureMode ? structureController.canEditNow : grid.isEditable
        case #selector(duplicateRows(_:)):
            return !structureMode && grid.isEditable
        case #selector(previousPage(_:)), #selector(firstPage(_:)):
            return mode == .data && query.page > 0
        case #selector(nextPage(_:)):
            return mode == .data && nextButton.isEnabled
        case #selector(lastPage(_:)):
            return mode == .data && lastButton.isEnabled
        case #selector(showGoToPage(_:)):
            return mode == .data && pageButton.isEnabled
        default:
            return true
        }
    }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

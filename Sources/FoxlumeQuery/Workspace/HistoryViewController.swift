import AppKit
import FoxlumeQueryCore

/// Searchable list of executed statements, shown beside the tabs.
@MainActor
final class HistoryViewController: NSViewController {
    private let workspace: ConnectionWorkspace
    var onOpen: ((String, _ run: Bool) -> Void)?
    /// "Add to Saved Queries…" on a row.
    var onSaveQuery: ((String) -> Void)?

    private let searchField = NSSearchField()
    private let scope = NSSegmentedControl(labels: ["This Connection", "All"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView()
    private var entries: [QueryHistoryEntry] = []
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    init(workspace: ConnectionWorkspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.setAccessibilityIdentifier("historyPanel")
        let title = UI.label("Query History", size: 13, weight: .semibold)
        let clear = UI.iconButton("trash", tooltip: "Clear History", target: self, action: #selector(clearHistory(_:)))

        searchField.placeholderString = "Search history"
        searchField.target = self
        searchField.action = #selector(reload)
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        scope.selectedSegment = 0
        scope.controlSize = .small
        scope.target = self
        scope.action = #selector(reload)
        scope.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.usesAutomaticRowHeights = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openEntry(_:))
        table.menu = NSMenu()
        table.menu?.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let header = UI.hstack([title, UI.flexibleSpace(), clear])
        root.addSubview(header)
        root.addSubview(searchField)
        root.addSubview(scope)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            searchField.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scope.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scope.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: scope.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: QueryHistoryStore.didChangeNotification, object: nil)
        reload()
    }

    @objc private func reload() {
        let connection = scope.selectedSegment == 0 ? workspace.config.id : nil
        entries = AppEnvironment.history.search(searchField.stringValue, connectionID: connection)
        table.reloadData()
    }

    @objc private func openEntry(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard let entry = entries[safe: row] else { return }
        onOpen?(entry.sql, false)
    }

    @objc private func runEntry(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard let entry = entries[safe: row] else { return }
        onOpen?(entry.sql, true)
    }

    @objc private func copyEntry(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard let entry = entries[safe: row] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.sql, forType: .string)
    }

    @objc private func saveEntry(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard let entry = entries[safe: row] else { return }
        onSaveQuery?(entry.sql)
    }

    /// Saves the newest entry shown, for scripted checks.
    func saveFirstEntry() {
        guard let entry = entries.first else { return }
        onSaveQuery?(entry.sql)
    }

    @objc private func deleteEntry(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard let entry = entries[safe: row] else { return }
        AppEnvironment.history.delete(id: entry.id)
    }

    @objc private func clearHistory(_ sender: Any?) {
        let connection = scope.selectedSegment == 0 ? workspace.config.id : nil
        Alerts.confirm(
            connection == nil ? "Clear all query history?" : "Clear history for this connection?",
            detail: "This cannot be undone.",
            confirmTitle: "Clear",
            destructive: true,
            in: view.window
        ) { confirmed in
            if confirmed { AppEnvironment.history.clear(connectionID: connection) }
        }
    }
}

extension HistoryViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let identifier = NSUserInterfaceItemIdentifier("historyCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryCellView ?? HistoryCellView(identifier: identifier)
        var meta = dateFormatter.string(from: entry.executedAt) + " · " + entry.duration.durationText
        if let rows = entry.rowCount { meta += " · \(rows.groupedText) rows" }
        if let database = entry.database, !database.isEmpty { meta += " · \(database)" }
        cell.configure(sql: entry.sql, meta: meta, failed: !entry.succeeded)
        cell.toolTip = entry.errorMessage ?? entry.sql
        return cell
    }
}

extension HistoryViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard table.clickedRow >= 0 else { return }
        for (title, action) in [("Open in Editor", #selector(openEntry(_:))), ("Run in New Tab", #selector(runEntry(_:))), ("Copy SQL", #selector(copyEntry(_:))),
                                ("Add to Saved Queries…", #selector(saveEntry(_:))), ("Delete", #selector(deleteEntry(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }
}

private final class HistoryCellView: NSTableCellView {
    private let sqlLabel = NSTextField(wrappingLabelWithString: "")
    private let metaLabel = UI.label("", size: 10, color: .secondaryLabelColor)
    private let marker = NSView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        sqlLabel.font = Theme.monospaced(11)
        sqlLabel.maximumNumberOfLines = 3
        sqlLabel.lineBreakMode = .byTruncatingTail
        sqlLabel.translatesAutoresizingMaskIntoConstraints = false
        sqlLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        marker.wantsLayer = true
        marker.layer?.cornerRadius = 3
        marker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(marker)
        addSubview(sqlLabel)
        addSubview(metaLabel)
        NSLayoutConstraint.activate([
            marker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            marker.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            marker.widthAnchor.constraint(equalToConstant: 6),
            marker.heightAnchor.constraint(equalToConstant: 6),
            sqlLabel.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 6),
            sqlLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            sqlLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            metaLabel.leadingAnchor.constraint(equalTo: sqlLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            metaLabel.topAnchor.constraint(equalTo: sqlLabel.bottomAnchor, constant: 3),
            metaLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(sql: String, meta: String, failed: Bool) {
        sqlLabel.stringValue = sql.count > 400 ? String(sql.prefix(400)) + "…" : sql
        metaLabel.stringValue = meta
        marker.layer?.backgroundColor = (failed ? NSColor.systemRed : NSColor.systemGreen).cgColor
    }
}

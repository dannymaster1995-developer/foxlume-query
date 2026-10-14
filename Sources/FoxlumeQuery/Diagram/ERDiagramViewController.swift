import AppKit
import FoxlumeQueryCore

/// The ER diagram of one schema (MySQL: one database) in a workspace tab: a toolbar with search, Types and Keys Only,
/// Reset Layout and Export; the zoomable canvas; a zoom bar. Columns and keys load in the background with progress;
/// the layout is computed off the main thread and merged with the positions the user saved by dragging.
@MainActor
final class ERDiagramViewController: NSViewController, WorkspaceTabContent {
    let workspace: ConnectionWorkspace
    let database: String?
    let schema: String?
    var onStateChange: (() -> Void)?
    var onOpenTable: ((TableRef) -> Void)?
    var onShowStructure: ((TableRef) -> Void)?

    var tabTitle: String { "ER Diagram: \(scopeName)" }
    var tabSymbol: String { "rectangle.3.group" }
    var hasUnsavedChanges: Bool { false }

    let scrollView = DiagramScrollView()
    let canvas = ERDiagramCanvas()
    private(set) var zoomBar: DiagramZoomBar!
    private let searchField = NSSearchField()
    private lazy var typesToggle = toggle("Types", symbol: "textformat", tooltip: "Show column types", action: #selector(toggleTypes(_:)), on: true)
    private lazy var keysToggle = toggle("Keys Only", symbol: "key", tooltip: "Show only primary and foreign key columns", action: #selector(toggleKeysOnly(_:)), on: false)
    private lazy var resetButton = UI.button("Reset Layout", symbol: "arrow.counterclockwise", target: self, action: #selector(resetLayout(_:)))
    private lazy var reloadButton = UI.iconButton("arrow.clockwise", tooltip: "Reload the schema", target: self, action: #selector(reload(_:)))
    private let exportButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let statusLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let overlay = NSStackView()
    private let overlayLabel = UI.label("", size: 13, color: .secondaryLabelColor)
    private let progress = NSProgressIndicator()
    private lazy var retryButton = UI.button("Retry", target: self, action: #selector(reload(_:)))

    let store: ERDiagramLayoutStore
    private(set) var graph = ERDiagramGraph.empty
    private(set) var isLoading = false
    private(set) var loadError: Error?
    private var loadTask: Task<Void, Never>?
    private var layoutTask: Task<Void, Never>?
    /// A table to select and scroll to once the diagram is drawn ("Show in ER Diagram").
    private var pendingFocus: String?
    private var searchMatches: [String] = []
    private var searchIndex = 0
    private var needsFit = false
    private var isLayingOut = false

    init(workspace: ConnectionWorkspace, database: String?, schema: String?, store: ERDiagramLayoutStore? = nil) {
        self.workspace = workspace
        self.database = database
        self.schema = schema
        self.store = store ?? AppEnvironment.erDiagramLayouts
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        loadTask?.cancel()
        layoutTask?.cancel()
    }

    var scope: ERDiagramScope {
        ERDiagramScope(connectionID: workspace.config.id, database: database, schema: schema)
    }

    /// `public`, a MySQL database name, or the file's name for SQLite.
    var scopeName: String {
        schema ?? database ?? (workspace.config.kind.isFileBased ? URL(fileURLWithPath: workspace.config.filePath).deletingPathExtension().lastPathComponent : workspace.config.displayName)
    }

    func matches(database: String?, schema: String?) -> Bool {
        self.database == database && self.schema == schema
    }

    override func loadView() {
        let root = NSView()
        root.setAccessibilityIdentifier("erDiagram")

        searchField.placeholderString = "Find Table"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.toolTip = "Highlight tables whose name contains the text; Return jumps to the next one"
        searchField.setAccessibilityIdentifier("erDiagramSearch")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        searchField.delegate = self

        resetButton.toolTip = "Forget dragged positions and lay the diagram out again"
        exportButton.controlSize = .small
        exportButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        exportButton.bezelStyle = .rounded
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        let exportTitle = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        exportTitle.image = Theme.image("square.and.arrow.up", "Export", size: 11)
        exportButton.menu?.addItem(exportTitle)
        for (title, action) in [("Export as PNG…", #selector(exportPNG(_:))), ("Export as PDF…", #selector(exportPDF(_:))), ("Copy as Image", #selector(copyImage(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            exportButton.menu?.addItem(item)
        }
        exportButton.toolTip = "Export the whole diagram, or copy it as an image"
        exportButton.setAccessibilityIdentifier("erDiagramExport")
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityIdentifier("erDiagramStatus")

        let toolbar = UI.hstack([searchField, typesToggle, keysToggle, statusLabel, UI.flexibleSpace(), reloadButton, resetButton, exportButton], spacing: 8)
        let toolbarContainer = NSView()
        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.addSubviewFilling(toolbar, insets: NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10))
        let line = UI.separator()

        scrollView.documentView = canvas
        canvas.scrollView = scrollView
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubviewFilling(scrollView)
        zoomBar = DiagramZoomBar(scrollView: scrollView, extras: [])
        zoomBar.place(in: content)
        scrollView.onZoomChange = { [weak self] in
            self?.zoomBar.update()
            self?.canvas.needsDisplay = true
        }

        progress.style = .bar
        progress.isIndeterminate = true
        progress.controlSize = .small
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 220).isActive = true
        overlayLabel.alignment = .center
        overlayLabel.lineBreakMode = .byWordWrapping
        overlayLabel.maximumNumberOfLines = 4
        overlayLabel.preferredMaxLayoutWidth = 420
        overlayLabel.setAccessibilityIdentifier("erDiagramMessage")
        overlay.orientation = .vertical
        overlay.spacing = 10
        overlay.setViews([progress, overlayLabel, retryButton], in: .center)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(overlay)

        for view in [toolbarContainer, line, content] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbarContainer.topAnchor.constraint(equalTo: root.topAnchor),
            toolbarContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.topAnchor.constraint(equalTo: toolbarContainer.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: line.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            overlay.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        canvas.onOpenTable = { [weak self] ref in self?.onOpenTable?(ref) }
        canvas.onShowStructure = { [weak self] ref in self?.onShowStructure?(ref) }
        canvas.onPositionsChanged = { [weak self] positions in self?.save(positions) }
        canvas.onSelectionChange = { [weak self] _ in self?.updateStatus() }
        canvas.backgroundMenuItems = { [weak self] in self?.backgroundMenuItems() ?? [] }
        view = root
        setOverlay("Loading tables…", progress: true)
        load()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard needsFit, scrollView.frame.width > 50, !graph.tables.isEmpty else { return }
        needsFit = false
        scrollView.fitToView()
        applyPendingFocus()
    }

    private func toggle(_ title: String, symbol: String, tooltip: String, action: Selector, on: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.state = on ? .on : .off
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    // MARK: Loading

    @objc func reload(_ sender: Any?) {
        load()
    }

    /// Reads tables, then columns and keys, then lays the diagram out. A reload keeps the zoom and the selection.
    func load() {
        loadTask?.cancel()
        isLoading = true
        loadError = nil
        setOverlay("Loading tables…", progress: true)
        let workspace = self.workspace, schema = self.schema
        loadTask = Task { [weak self] in
            do {
                let tables = try await workspace.diagramTables(schema: schema)
                guard !Task.isCancelled else { return }
                self?.setOverlay(tables.isEmpty ? "Loading…" : "Loading columns and keys of \(tables.count) \(tables.count == 1 ? "table" : "tables")…", progress: true)
                let structures = try await workspace.diagramStructures(schema: schema, tables: tables) { done, total in
                    self?.showProgress(done: done, total: total)
                }
                guard !Task.isCancelled, let self else { return }
                let graph = ERDiagramGraph.build(tables: tables, structures: structures)
                self.isLoading = false
                self.present(graph, refit: self.graph.tables.isEmpty)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isLoading = false
                self.loadError = error
                self.setOverlay("Could not load the schema.\n\(error.localizedDescription)", progress: false, retry: true)
                self.updateStatus()
            }
        }
    }

    private func showProgress(done: Int, total: Int) {
        guard isLoading, total > 0 else { return }
        progress.isIndeterminate = false
        progress.maxValue = Double(total)
        progress.doubleValue = Double(done)
        overlayLabel.stringValue = "Loading \(done) of \(total) tables…"
    }

    private func setOverlay(_ text: String?, progress showProgress: Bool, retry: Bool = false) {
        overlay.isHidden = text == nil
        overlayLabel.stringValue = text ?? ""
        progress.isHidden = !showProgress
        retryButton.isHidden = !retry
        if showProgress {
            progress.isIndeterminate = true
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
        scrollView.isHidden = text != nil && graph.tables.isEmpty
        zoomBar?.isHidden = scrollView.isHidden
    }

    /// Lays out off the main thread: saved positions stay, other tables are placed around them.
    private func present(_ graph: ERDiagramGraph, refit: Bool) {
        self.graph = graph
        let sizes = ERDiagramCanvas.boxSizes(for: graph, showTypes: canvas.showTypes, keysOnly: canvas.keysOnly)
        let saved = store.positions(for: scope)
        relayout(graph: graph, sizes: sizes, saved: saved, refit: refit)
    }

    private func relayout(graph: ERDiagramGraph, sizes: [String: CGSize], saved: [String: CGPoint], refit: Bool) {
        layoutTask?.cancel()
        isLayingOut = true
        let nodes = graph.tables.map { ERDiagramLayout.Node(id: $0.id, size: sizes[$0.id] ?? .zero) }
        let links = graph.relationships.map { ERDiagramLayout.Link(from: $0.from, to: $0.to) }
        layoutTask = Task { [weak self] in
            let positions = await Task.detached(priority: .userInitiated) {
                ERDiagramLayout.merge(saved: saved, nodes: nodes, links: links)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.isLayingOut = false
            self.canvas.show(graph, positions: positions, sizes: sizes)
            if graph.tables.isEmpty {
                self.setOverlay("No tables in \(self.scopeName).", progress: false)
            } else {
                self.setOverlay(nil, progress: false)
            }
            if refit {
                self.needsFit = true
                self.view.needsLayout = true
            } else {
                self.applyPendingFocus()
            }
            _ = self.canvas.highlight(self.searchField.stringValue)
            self.updateStatus()
            self.onStateChange?()
        }
    }

    /// Loading or laying out; scripted checks wait for this to clear.
    var isBusy: Bool { isLoading || isLayingOut }

    private func updateStatus() {
        guard !isLoading, loadError == nil else { return statusLabel.stringValue = "" }
        let tables = graph.tables.count, links = graph.relationships.count
        var parts = ["\(tables) \(tables == 1 ? "table" : "tables")", "\(links) \(links == 1 ? "relationship" : "relationships")"]
        let external = graph.externalReferences.values.reduce(0) { $0 + $1.count }
        if external > 0 { parts.append("\(external) to other schemas") }
        if canvas.isFiltering { parts.append("\(searchMatches.count) found") }
        if let selected = canvas.selectedID { parts.append(selected) }
        statusLabel.stringValue = parts.joined(separator: " · ")
    }

    // MARK: Focus and search

    /// Selects a table and brings it into view, now or once the diagram is drawn.
    func focus(table name: String) {
        pendingFocus = name
        if !isLoading, canvas.frame(of: name) != nil, !needsFit { applyPendingFocus() }
    }

    private func applyPendingFocus() {
        guard let name = pendingFocus, let frame = canvas.frame(of: name) else { return }
        pendingFocus = nil
        canvas.select(name)
        // Readable at the focused table: zoom in to at least 75 % when fitted far out.
        if scrollView.magnification < 0.75 { scrollView.zoom(to: 0.75) }
        scrollView.reveal(frame, centre: true)
        view.window?.makeFirstResponder(canvas)
        updateStatus()
    }

    @objc private func searchChanged(_ sender: Any?) {
        searchMatches = canvas.highlight(searchField.stringValue)
        searchIndex = 0
        updateStatus()
    }

    /// Return in the search field: the next match, selected and centred.
    func revealNextMatch() {
        guard !searchMatches.isEmpty else { return NSSound.beep() }
        let id = searchMatches[searchIndex % searchMatches.count]
        searchIndex += 1
        canvas.select(id)
        if let frame = canvas.frame(of: id) { scrollView.reveal(frame, centre: true) }
        updateStatus()
    }

    func search(_ text: String) {
        searchField.stringValue = text
        searchChanged(nil)
    }

    // MARK: Options

    @objc private func toggleTypes(_ sender: Any?) {
        setOptions(showTypes: typesToggle.state == .on, keysOnly: canvas.keysOnly)
    }

    @objc private func toggleKeysOnly(_ sender: Any?) {
        setOptions(showTypes: canvas.showTypes, keysOnly: keysToggle.state == .on)
    }

    /// Box sizes change, so tables keep their saved corners and the rest are laid out again.
    func setOptions(showTypes: Bool, keysOnly: Bool) {
        typesToggle.state = showTypes ? .on : .off
        keysToggle.state = keysOnly ? .on : .off
        canvas.showTypes = showTypes
        canvas.keysOnly = keysOnly
        guard !graph.tables.isEmpty else { return }
        let sizes = ERDiagramCanvas.boxSizes(for: graph, showTypes: showTypes, keysOnly: keysOnly)
        let saved = store.positions(for: scope)
        relayout(graph: graph, sizes: sizes, saved: saved, refit: false)
    }

    @objc func resetLayout(_ sender: Any?) {
        do {
            try store.clear(scope)
        } catch {
            Alerts.showError(error, title: "Could not reset the layout", in: view.window)
        }
        let sizes = ERDiagramCanvas.boxSizes(for: graph, showTypes: canvas.showTypes, keysOnly: canvas.keysOnly)
        relayout(graph: graph, sizes: sizes, saved: [:], refit: true)
    }

    private func save(_ positions: [String: CGPoint]) {
        do {
            try store.setPositions(positions, for: scope)
        } catch {
            Alerts.showError(error, title: "Could not save the diagram layout", in: view.window)
        }
    }

    var statusText: String { statusLabel.stringValue }

    var backgroundMenuForTesting: [NSMenuItem] { backgroundMenuItems() }

    private func backgroundMenuItems() -> [NSMenuItem] {
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        return [
            item("Fit to View", #selector(fitToView(_:))),
            item("Reset Layout", #selector(resetLayout(_:))),
            .separator(),
            item("Export as PNG…", #selector(exportPNG(_:))),
            item("Export as PDF…", #selector(exportPDF(_:))),
            item("Copy as Image", #selector(copyImage(_:))),
        ]
    }

    // MARK: Export

    @objc func fitToView(_ sender: Any?) { scrollView.fitToView() }

    var exportFileName: String { DiagramImageExporter.fileName("er-diagram", scopeName) }

    @objc func exportPNG(_ sender: Any?) {
        DiagramImageExporter.save(canvas, format: .png, suggestedName: exportFileName, appearance: view.effectiveAppearance, in: view.window)
    }

    @objc func exportPDF(_ sender: Any?) {
        DiagramImageExporter.save(canvas, format: .pdf, suggestedName: exportFileName, appearance: view.effectiveAppearance, in: view.window)
    }

    @objc func copyImage(_ sender: Any?) {
        DiagramImageExporter.copy(canvas, appearance: view.effectiveAppearance)
    }
}

extension ERDiagramViewController: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            revealNextMatch()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), !searchField.stringValue.isEmpty {
            search("")
            return true
        }
        return false
    }
}

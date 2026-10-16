import AppKit
import FoxlumeQueryCore
import UniformTypeIdentifiers

/// SQL editor on top, results below.
@MainActor
final class QueryTabViewController: NSViewController, WorkspaceTabContent {
    let workspace: ConnectionWorkspace
    var onStateChange: (() -> Void)?
    private(set) var tabTitle: String
    var tabSymbol: String { "chevron.left.forwardslash.chevron.right" }
    /// Scratch tabs are restored with the window, so only edits to an opened .sql file count as unsaved.
    var hasUnsavedChanges: Bool { fileURL != nil && editor.string != savedText }
    private var savedText = ""
    private var runToken: QueryToken?

    private let initialSQL: String
    private let editor = SQLEditorView()
    private let split = NSSplitView()
    let grid = DataGridView()
    private let messageView = NSTextView()
    private let messageScroll = NSScrollView()
    private let resultPicker = NSSegmentedControl()
    private let statusLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    /// Count, sum, average, minimum and maximum of the selected cells.
    private let selectionLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator()
    private lazy var runButton = UI.button("Run", symbol: "play.fill", target: self, action: #selector(runCurrent(_:)))
    private lazy var runAllButton = UI.button("Run All", target: self, action: #selector(runAll(_:)))
    private lazy var stopButton = UI.button("Stop", symbol: "stop.fill", target: self, action: #selector(cancelQuery(_:)))
    private lazy var exportButton = UI.button("Export", symbol: "square.and.arrow.up", target: self, action: #selector(exportResults(_:)))
    private lazy var formatButton = UI.button("Format", symbol: "text.alignleft", target: self, action: #selector(formatQuery(_:)))
    /// Explain and Explain Analyze; see QueryTabViewController+Explain.swift.
    private(set) lazy var explainControl = makeExplainControl()
    /// Goes up the responder chain to the window, which owns the saved queries.
    private lazy var saveQueryButton = UI.iconButton("star", tooltip: "Add to Saved Queries (⌘D)", target: nil, action: #selector(FoxlumeQueryActions.addToSavedQueries(_:)))

    private var results: [StatementResult] = []
    private var runError: Error?
    /// The last Explain's output, shown instead of results until the next run.
    private(set) var explainOutcome: ExplainOutcome?
    let planView = QueryPlanView()
    private(set) var isRunning = false
    private var runStarted: Date?
    private var totalElapsed: TimeInterval = 0

    /// The .sql file this tab was opened from or saved to.
    private(set) var fileURL: URL?
    /// The database and schema the editor's suggestions were made for.
    private var completionScope = ""

    init(workspace: ConnectionWorkspace, title: String, sql: String, fileURL: URL? = nil) {
        self.workspace = workspace
        self.tabTitle = fileURL?.lastPathComponent ?? title
        self.initialSQL = sql
        self.fileURL = fileURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var sql: String {
        get { editor.string }
        set { editor.string = newValue }
    }

    override func loadView() {
        let root = NSView()

        runButton.toolTip = "Run the selection or the statement at the cursor (⌘↩)"
        runButton.setAccessibilityIdentifier("runQuery")
        runAllButton.toolTip = "Run every statement (⇧⌘↩)"
        stopButton.toolTip = "Cancel the running query (⌘.)"
        stopButton.isEnabled = false
        exportButton.toolTip = "Export the selected result (⇧⌘E)"
        let limitLabel = UI.label("\(workspace.queryLanguage.displayName) · limit \(AppEnvironment.settings.queryRowLimit.groupedText) rows", size: 11, color: .tertiaryLabelColor)
        formatButton.toolTip = "Format the selection or the whole query (⇧⌘L)"
        formatButton.isHidden = !workspace.kind.isSQL
        saveQueryButton.setAccessibilityIdentifier("addToSavedQueries")
        let toolbar = UI.hstack([runButton, runAllButton, stopButton, explainControl, UI.separator(vertical: true), formatButton, saveQueryButton, UI.flexibleSpace(), limitLabel], spacing: 6)
        let toolbarContainer = NSView()
        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.addSubviewFilling(toolbar, insets: NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10))

        editor.completionProvider = self
        editor.language = workspace.queryLanguage
        // Columns load in the background so the first suggestions can already name them (spec 3.7).
        workspace.preloadCompletionColumns()
        completionScope = workspaceCompletionScope
        NotificationCenter.default.addObserver(self, selector: #selector(workspaceMetadataDidChange(_:)), name: ConnectionWorkspace.metadataDidChange, object: workspace)
        editor.applyFontSize(CGFloat(AppEnvironment.settings.editorFontSize))
        editor.string = initialSQL
        savedText = initialSQL
        editor.onTextChange = { [weak self] in
            guard let self, self.fileURL != nil else { return }
            self.onStateChange?()
        }

        grid.delegate = self
        grid.isEditable = false
        grid.readOnlyReason = "Query results are read-only. Open the table to edit its rows."
        grid.dialectForCopy = workspace.dialect
        grid.allowsInListCopy = workspace.kind.isSQL
        grid.showsRowNumbers = AppEnvironment.settings.showRowNumbers

        messageView.isEditable = false
        messageView.isRichText = true
        messageView.font = Theme.monospaced(12)
        messageView.textContainerInset = NSSize(width: 10, height: 10)
        messageView.autoresizingMask = [.width]
        messageView.setAccessibilityIdentifier("queryMessages")
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.autohidesScrollers = true
        messageScroll.isHidden = true

        resultPicker.segmentStyle = .rounded
        resultPicker.controlSize = .small
        resultPicker.trackingMode = .selectOne
        resultPicker.target = self
        resultPicker.action = #selector(resultPicked(_:))
        resultPicker.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.setAccessibilityIdentifier("queryStatus")
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        selectionLabel.setAccessibilityIdentifier("querySelectionSummary")
        selectionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let resultsHeader = UI.hstack([resultPicker, UI.flexibleSpace(), selectionLabel, spinner, statusLabel, exportButton], spacing: 8)
        let resultsHeaderContainer = NSView()
        resultsHeaderContainer.translatesAutoresizingMaskIntoConstraints = false
        resultsHeaderContainer.addSubviewFilling(resultsHeader, insets: NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10))

        let resultsBody = NSView()
        resultsBody.addSubviewFilling(grid)
        resultsBody.addSubviewFilling(messageScroll)
        resultsBody.addSubviewFilling(planView)
        planView.isHidden = true

        let resultsPane = NSView()
        let headerLine = UI.separator()
        resultsPane.addSubview(headerLine)
        resultsPane.addSubview(resultsHeaderContainer)
        resultsPane.addSubview(resultsBody)
        resultsBody.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            resultsHeaderContainer.topAnchor.constraint(equalTo: resultsPane.topAnchor),
            resultsHeaderContainer.leadingAnchor.constraint(equalTo: resultsPane.leadingAnchor),
            resultsHeaderContainer.trailingAnchor.constraint(equalTo: resultsPane.trailingAnchor),
            headerLine.topAnchor.constraint(equalTo: resultsHeaderContainer.bottomAnchor),
            headerLine.leadingAnchor.constraint(equalTo: resultsPane.leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: resultsPane.trailingAnchor),
            resultsBody.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            resultsBody.leadingAnchor.constraint(equalTo: resultsPane.leadingAnchor),
            resultsBody.trailingAnchor.constraint(equalTo: resultsPane.trailingAnchor),
            resultsBody.bottomAnchor.constraint(equalTo: resultsPane.bottomAnchor),
        ])

        let editorPane = NSView()
        let toolbarLine = UI.separator()
        editorPane.addSubview(toolbarContainer)
        editorPane.addSubview(toolbarLine)
        editorPane.addSubview(editor)
        editor.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbarContainer.topAnchor.constraint(equalTo: editorPane.topAnchor),
            toolbarContainer.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor),
            toolbarContainer.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor),
            toolbarLine.topAnchor.constraint(equalTo: toolbarContainer.bottomAnchor),
            toolbarLine.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor),
            toolbarLine.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor),
            editor.topAnchor.constraint(equalTo: toolbarLine.bottomAnchor),
            editor.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: editorPane.bottomAnchor),
        ])

        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(editorPane)
        split.addArrangedSubview(resultsPane)
        // The editor keeps its height when the window resizes; the results take the difference.
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        NSLayoutConstraint.activate([
            editorPane.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            resultsPane.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
        root.addSubviewFilling(split)
        view = root
        renderResults()
    }

    private var didPlaceDivider = false

    /// The split view has no size until the tab is first laid out, so place the divider then.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didPlaceDivider, split.frame.height > 300, view.window != nil else { return }
        didPlaceDivider = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.split.setPosition((self.split.frame.height * 0.42).rounded(), ofDividerAt: 0)
        }
    }

    func focusEditor() {
        view.window?.makeFirstResponder(editor.textView)
    }

    // MARK: Scripted completion checks

    var visibleCompletions: [String] { editor.textView.visibleCompletionLabels }
    var selectedCompletion: String? { editor.textView.selectedCompletionLabel }
    var completionFrame: NSRect? { editor.textView.completionFrameForTesting }
    var completionCaretRect: NSRect? { editor.textView.completionCaretRectForTesting }
    var caretLocation: Int { editor.textView.selectedRange().location }

    func hideCompletions() {
        editor.textView.hideCompletions()
    }

    func typeForTesting(_ text: String) {
        editor.textView.typeForTesting(text)
    }

    @discardableResult
    func sendKeyForTesting(_ name: String) -> Bool {
        editor.textView.sendKeyForTesting(name)
    }

    func acceptCompletionForTesting() {
        editor.textView.acceptSelectedCompletion()
    }

    /// Opens the list at the end of the text, as ⌃Space does there.
    func showCompletions() {
        focusEditor()
        editor.textView.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.textView.requestManualCompletion()
    }

    func setSQL(_ text: String) {
        editor.string = text
        focusEditor()
    }

    /// Adds `text` after the current text, a blank line apart, as one undoable change.
    func appendSQL(_ text: String) {
        let textView = editor.textView
        let current = textView.string as NSString
        var content = current.length
        while content > 0, let scalar = UnicodeScalar(current.character(at: content - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) {
            content -= 1
        }
        let tail = NSRange(location: content, length: current.length - content)
        let replacement = (content == 0 ? "" : "\n\n") + text
        guard textView.shouldChangeText(in: tail, replacementString: replacement) else { return }
        textView.replaceCharacters(in: tail, with: replacement)
        textView.didChangeText()
        textView.undoManager?.setActionName("Insert Saved Query")
        let end = NSRange(location: (textView.string as NSString).length, length: 0)
        textView.setSelectedRange(end)
        textView.scrollRangeToVisible(end)
        focusEditor()
    }

    /// What "Add to Saved Queries…" saves: the selection, or the whole text when nothing is selected.
    var textForSaving: String {
        let selection = editor.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return selection.isEmpty ? editor.string.trimmingCharacters(in: .whitespacesAndNewlines) : selection
    }

    // MARK: Running

    @objc func runCurrent(_ sender: Any?) {
        guard let statement = currentStatement() else { return NSSound.beep() }
        run(statement)
    }

    /// The selection, or else the statement at the caret (highlighted), as Run Statement and Explain pick it.
    func currentStatement() -> String? {
        let selection = editor.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selection.isEmpty { return selection }
        let location = editor.textView.selectedRange().location
        guard let statement = workspace.queryLanguage.statement(at: location, in: editor.string) else { return nil }
        editor.highlightRange(statement.range)
        return statement.text
    }

    /// Runs the selection or current statement and keeps every row, ignoring the row limit.
    @objc func runWithoutLimit(_ sender: Any?) {
        let selection = editor.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selection.isEmpty {
            run(selection, unlimited: true)
            return
        }
        guard let statement = workspace.queryLanguage.statement(at: editor.textView.selectedRange().location, in: editor.string) else {
            return NSSound.beep()
        }
        run(statement.text, unlimited: true)
    }

    @objc func runAll(_ sender: Any?) {
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return NSSound.beep() }
        run(text)
    }

    @objc func cancelQuery(_ sender: Any?) {
        guard isRunning, let runToken else { return }
        workspace.cancel(runToken)
        statusLabel.stringValue = "Cancelling…"
    }

    private func run(_ sql: String, unlimited: Bool = false) {
        guard !isRunning else { return NSSound.beep() }
        if workspace.kind.isSQL, AppEnvironment.settings.confirmUnboundedWrites {
            let unbounded = workspace.queryLanguage.split(sql).filter { SQLStatementSplitter.unboundedWrite($0.text) != nil }
            if !unbounded.isEmpty {
                Alerts.confirm(
                    "Run \(unbounded.count == 1 ? "a statement" : "\(unbounded.count) statements") without WHERE?",
                    detail: "These change every row of their table:\n\n" + unbounded.prefix(5).map(\.text).joined(separator: ";\n"),
                    confirmTitle: "Run Anyway",
                    destructive: true,
                    in: view.window
                ) { [weak self] confirmed in
                    if confirmed { self?.runAfterSafetyChecks(sql, unlimited: unlimited) }
                }
                return
            }
        }
        runAfterSafetyChecks(sql, unlimited: unlimited)
    }

    /// Production confirmation, then execution.
    private func runAfterSafetyChecks(_ sql: String, unlimited: Bool) {
        let limit: Int? = unlimited ? nil : AppEnvironment.settings.queryRowLimit
        let writes = workspace.writeStatements(in: sql)
        let all = workspace.queryLanguage.split(sql).map(\.text)
        let count = writes.isEmpty ? all.count : writes.count
        SafeModeGate.authorize(
            config: workspace.config,
            statements: writes.isEmpty ? all : writes.map(\.text),
            writes: !writes.isEmpty,
            action: writes.isEmpty
                ? "Run \(count) statement\(count == 1 ? "" : "s")"
                : "Run \(count) statement\(count == 1 ? "" : "s") that may change data",
            in: view.window
        ) { [weak self] confirmed in
            if confirmed { self?.execute(sql, limit: limit) }
        }
    }

    private func execute(_ sql: String, limit: Int?) {
        isRunning = true
        runError = nil
        explainOutcome = nil
        runStarted = Date()
        updateRunningState()
        let token = QueryToken()
        runToken = token
        Task {
            do {
                let output = try await workspace.execute(sql, rowLimit: limit, token: token)
                results = output
            } catch {
                results = []
                runError = error
            }
            totalElapsed = Date().timeIntervalSince(runStarted ?? Date())
            runToken = nil
            isRunning = false
            updateRunningState()
            renderResults()
        }
    }

    /// Runs a request built in QueryTabViewController+Explain.swift the way `execute` runs statements: cancellable
    /// with Stop, and its plan replaces the results.
    func runExplain(_ request: ExplainRequest) {
        isRunning = true
        runError = nil
        runStarted = Date()
        updateRunningState()
        let token = QueryToken()
        runToken = token
        Task {
            do {
                explainOutcome = try await workspace.explain(request, token: token)
            } catch {
                explainOutcome = nil
                runError = error
            }
            results = []
            totalElapsed = Date().timeIntervalSince(runStarted ?? Date())
            runToken = nil
            isRunning = false
            updateRunningState()
            renderResults()
        }
    }

    /// Shows why an Explain did not run, in place of the results.
    func showExplainRefusal(_ error: Error) {
        explainOutcome = nil
        results = []
        runError = error
        runStarted = runStarted ?? Date()
        renderResults()
        statusLabel.stringValue = "Not run"
    }

    private func updateRunningState() {
        runButton.isEnabled = !isRunning
        runAllButton.isEnabled = !isRunning
        stopButton.isEnabled = isRunning
        updateExplainControl()
        if isRunning {
            spinner.startAnimation(nil)
            statusLabel.stringValue = "Running…"
        } else {
            spinner.stopAnimation(nil)
        }
    }

    // MARK: Results

    private func renderResults() {
        resultPicker.segmentCount = 0
        planView.isHidden = true
        if let runError {
            showMessages(NSAttributedString(string: runError.localizedDescription, attributes: [.foregroundColor: NSColor.systemRed, .font: Theme.monospaced(12)]))
            resultPicker.isHidden = true
            statusLabel.stringValue = "Error · \(totalElapsed.durationText)"
            exportButton.isEnabled = false
            return
        }
        if let explainOutcome {
            planView.show(explainOutcome)
            planView.isHidden = false
            grid.isHidden = true
            messageScroll.isHidden = true
            resultPicker.isHidden = true
            exportButton.isEnabled = false
            statusLabel.stringValue = "\(explainOutcome.request.mode.title) · \(explainOutcome.elapsed.durationText)"
            return
        }
        guard !results.isEmpty else {
            showMessages(NSAttributedString(string: runStarted == nil ? "Run a query with ⌘↩ to see results here." : "No statements were run.", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]))
            resultPicker.isHidden = true
            statusLabel.stringValue = ""
            exportButton.isEnabled = false
            return
        }
        let resultSets = results.enumerated().filter { $0.element.hasResultSet }
        let hasMessages = results.contains { !$0.hasResultSet }
        resultPicker.segmentCount = resultSets.count + (hasMessages ? 1 : 0)
        for (segment, entry) in resultSets.enumerated() {
            resultPicker.setLabel("Result \(segment + 1)", forSegment: segment)
            resultPicker.setTag(entry.offset, forSegment: segment)
            resultPicker.setWidth(0, forSegment: segment)
        }
        if hasMessages {
            resultPicker.setLabel("Messages", forSegment: resultSets.count)
            resultPicker.setTag(-1, forSegment: resultSets.count)
        }
        resultPicker.isHidden = resultPicker.segmentCount <= 1
        resultPicker.selectedSegment = resultSets.isEmpty ? resultSets.count : resultSets.count - 1
        showSelectedResult()
    }

    @objc private func resultPicked(_ sender: Any?) {
        showSelectedResult()
    }

    private func showSelectedResult() {
        let segment = resultPicker.selectedSegment
        let tag = segment >= 0 ? resultPicker.tag(forSegment: segment) : -1
        if tag >= 0, let result = results[safe: tag] {
            grid.setContent(DataGridContent(columns: result.columns, rows: result.rows), localSort: true)
            grid.isHidden = false
            messageScroll.isHidden = true
            planView.isHidden = true
            exportButton.isEnabled = true
            var text = "\(result.rows.count.groupedText) row\(result.rows.count == 1 ? "" : "s")"
            if result.truncated { text += " (limited)" }
            statusLabel.stringValue = "\(text) · \(result.elapsed.durationText)"
            if results.count > 1 { statusLabel.stringValue += " · total \(totalElapsed.durationText)" }
        } else {
            let output = NSMutableAttributedString()
            for (index, result) in results.enumerated() {
                let line: String
                if result.hasResultSet {
                    line = "\(index + 1). \(result.rows.count.groupedText) rows returned"
                } else {
                    let affected = result.affectedRows.map { " · \($0.groupedText) rows affected" } ?? ""
                    line = "\(index + 1). \(result.message ?? "OK")\(affected)"
                }
                output.append(NSAttributedString(string: line + "  (\(result.elapsed.durationText))\n", attributes: [.font: Theme.monospaced(12), .foregroundColor: NSColor.labelColor]))
            }
            showMessages(output)
            exportButton.isEnabled = false
            statusLabel.stringValue = "\(results.count) statement\(results.count == 1 ? "" : "s") · \(totalElapsed.durationText)"
        }
    }

    private func showMessages(_ text: NSAttributedString) {
        messageView.textStorage?.setAttributedString(text)
        messageScroll.isHidden = false
        grid.isHidden = true
        planView.isHidden = true
    }

    var currentResult: StatementResult? {
        let segment = resultPicker.segmentCount == 0 ? -1 : resultPicker.selectedSegment
        let tag = segment >= 0 ? resultPicker.tag(forSegment: segment) : (results.firstIndex { $0.hasResultSet } ?? -1)
        return results[safe: tag]
    }

    /// Reformats the selection, or the whole text when nothing is selected. Undoable as one step.
    @objc func formatQuery(_ sender: Any?) {
        guard workspace.kind.isSQL else { return NSSound.beep() }
        let textView = editor.textView
        let text = textView.string as NSString
        var range = textView.selectedRange()
        if range.length == 0 { range = NSRange(location: 0, length: text.length) }
        let source = text.substring(with: range)
        let formatted = SQLFormatter.format(source, dialect: workspace.dialect)
        guard formatted != source, textView.shouldChangeText(in: range, replacementString: formatted) else { return }
        textView.replaceCharacters(in: range, with: formatted)
        textView.didChangeText()
        textView.undoManager?.setActionName("Format SQL")
        textView.setSelectedRange(NSRange(location: range.location, length: (formatted as NSString).length))
    }

    // MARK: Files

    /// ⌘S in a query tab saves the SQL text to its file.
    @objc func saveChanges(_ sender: Any?) {
        if let fileURL {
            write(to: fileURL)
        } else {
            saveQueryAs(sender)
        }
    }

    @objc func saveQueryAs(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? tabTitle.replacingOccurrences(of: " ", with: "_") + ".sql"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.write(to: url)
        }
    }

    private func write(to url: URL) {
        do {
            try editor.string.write(to: url, atomically: true, encoding: .utf8)
            savedText = editor.string
            fileURL = url
            tabTitle = url.lastPathComponent
            onStateChange?()
        } catch {
            Alerts.showError(error, title: "Could not save the query", in: view.window)
        }
    }

    @objc func exportResults(_ sender: Any?) {
        guard let result = currentResult, result.hasResultSet, let window = view.window else { return NSSound.beep() }
        ExportPanel.run(columns: grid.content.columns, rows: grid.content.rows, suggestedName: tabTitle, tableName: "query_result", dialect: workspace.dialect, in: window)
    }
}

extension QueryTabViewController: DataGridViewDelegate {
    func dataGridSelectionDidChange(_ grid: DataGridView) {
        selectionLabel.stringValue = grid.selectionStatistics?.summary ?? ""
    }

    /// ⌃⌘J on the results; their column layout is not remembered.
    @objc func jumpToColumn(_ sender: Any?) {
        guard canJumpToColumn else { return NSSound.beep() }
        grid.showJumpToColumn()
    }

    var canJumpToColumn: Bool { !grid.isHidden && !grid.content.columns.isEmpty }
}

extension QueryTabViewController: SQLCompletionProvider {
    var completionEngine: CompletionEngine? { workspace.completionEngine }
    var completionKeywordCase: KeywordCase { AppEnvironment.settings.keywordCase }
    var completesWhileTyping: Bool { AppEnvironment.settings.autocompleteOnTyping }

    fileprivate var workspaceCompletionScope: String {
        (workspace.currentDatabase ?? "") + "\u{1F}" + (workspace.currentSchema ?? "")
    }

    /// An open list names the previous database's objects, so a database or schema switch closes it (spec 1.6);
    /// a refresh that keeps the scope leaves it open.
    @objc fileprivate func workspaceMetadataDidChange(_ notification: Notification) {
        let scope = workspaceCompletionScope
        guard scope != completionScope else { return }
        completionScope = scope
        editor.textView.hideCompletions()
    }
}

/// Save panel with a format picker, shared by query results and table data.
@MainActor
enum ExportPanel {
    static func run(columns: [ResultColumn], rows: [[CellValue]], suggestedName: String, tableName: String, dialect: SQLDialect, in window: NSWindow) {
        let panel = NSSavePanel()
        let formatPopup = NSPopUpButton()
        for format in ExportFormat.allCases {
            formatPopup.addItem(withTitle: format.title)
        }
        let header = NSButton(checkboxWithTitle: "Include header row", target: nil, action: nil)
        header.state = .on
        let label = NSTextField(labelWithString: "Format:")
        let accessory = NSStackView(views: [label, formatPopup, header])
        accessory.orientation = .horizontal
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = accessory
        panel.nameFieldStringValue = suggestedName.replacingOccurrences(of: " ", with: "_") + ".csv"
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true

        let handler = FormatChangeHandler(panel: panel, popup: formatPopup)
        formatPopup.target = handler
        formatPopup.action = #selector(FormatChangeHandler.changed(_:))
        panel.beginSheetModal(for: window) { response in
            _ = handler
            guard response == .OK, let url = panel.url else { return }
            let format = ExportFormat.allCases[max(0, formatPopup.indexOfSelectedItem)]
            let text = ResultExporter.export(columns: columns, rows: rows, format: format, includeHeader: header.state == .on, tableName: tableName, dialect: dialect)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Alerts.showError(error, title: "Export failed", in: window)
            }
        }
    }

    @MainActor
    private final class FormatChangeHandler: NSObject {
        let panel: NSSavePanel
        let popup: NSPopUpButton

        init(panel: NSSavePanel, popup: NSPopUpButton) {
            self.panel = panel
            self.popup = popup
        }

        @objc func changed(_ sender: Any?) {
            let format = ExportFormat.allCases[max(0, popup.indexOfSelectedItem)]
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = base + "." + format.fileExtension
        }
    }
}

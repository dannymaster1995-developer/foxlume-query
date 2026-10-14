import AppKit
import FoxlumeQueryCore

/// Column / operator / value rules plus an optional raw WHERE clause.
final class FilterBarView: NSView {
    /// What the Raw SQL box asks the SQL engine.
    struct RawCompletion {
        /// Suggestions at a caret (UTF-16) in the box's text.
        var complete: @MainActor (_ fragment: String, _ caret: Int) async -> CompletionResult?
        /// The open list re-ranked for the live token, so its rows match the text until the next answer arrives.
        var refilter: @MainActor (_ result: CompletionResult, _ token: String) -> [CompletionItem]
    }

    var onApply: (([FilterRule], String) -> Void)?
    /// Set by the table tab for SQL engines; nil leaves the Raw SQL box without suggestions (spec 10).
    var rawCompletion: RawCompletion? {
        didSet { if rawCompletion == nil { closeRawSuggestions() } }
    }

    private var columns: [String] = []
    private var rules: [FilterRule] = []
    private let rowsStack = NSStackView()
    private let rawField = NSTextField()
    private let rawLabel = UI.label("WHERE", size: 11, weight: .semibold, color: .secondaryLabelColor)
    private let typePopup = NSPopUpButton()
    private var addButton: NSButton?
    private var style: BrowseFilterStyle = .columns
    private lazy var rawSuggestions = RawSuggestionList { [weak self] item in self?.acceptRawSuggestion(item) }
    private var rawRequest: Task<Void, Never>?
    private var rawResult: CompletionResult?
    /// Accepting edits the field; that edit must not ask again.
    private var isInsertingSuggestion = false
    /// The field editor whose caret moves are watched while the list is open.
    private weak var observedFieldEditor: NSTextView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 4
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        rawField.placeholderString = "Raw SQL condition, e.g. total > 100 AND status <> 'cancelled'"
        rawField.font = Theme.monospaced(11)
        rawField.controlSize = .small
        rawField.target = self
        rawField.action = #selector(apply(_:))
        rawField.translatesAutoresizingMaskIntoConstraints = false
        rawField.setAccessibilityIdentifier("rawWhere")
        rawField.delegate = self

        let add = UI.button("Add Filter", symbol: "plus", target: self, action: #selector(addRule(_:)))
        addButton = add
        typePopup.controlSize = .small
        typePopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        typePopup.isHidden = true
        typePopup.target = self
        typePopup.action = #selector(apply(_:))
        let apply = UI.button("Apply", target: self, action: #selector(apply(_:)))
        apply.keyEquivalent = ""
        apply.setAccessibilityIdentifier("applyFilters")
        let clear = UI.button("Clear", target: self, action: #selector(clear(_:)))
        let footer = UI.hstack([add, rawLabel, rawField, typePopup, apply, clear], spacing: 6)

        let stack = NSStackView(views: [rowsStack, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let separator = UI.separator()
        addSubview(separator)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -8),
            footer.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            rawField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(columns: [String], rules: [FilterRule], rawWhere: String, capabilities: EngineCapabilities) {
        self.columns = columns
        style = capabilities.browseFilterStyle
        rawLabel.stringValue = capabilities.rawFilterLabel.uppercased()
        rawField.placeholderString = capabilities.rawFilterPlaceholder
        rawField.stringValue = rawWhere
        if case .keyPattern(let types) = style {
            // Key browsing: one glob plus a type, no column rules.
            self.rules = []
            addButton?.isHidden = true
            typePopup.isHidden = false
            typePopup.removeAllItems()
            typePopup.addItem(withTitle: "All Types")
            typePopup.lastItem?.representedObject = ""
            for type in types {
                typePopup.addItem(withTitle: Self.typeTitle(type))
                typePopup.lastItem?.representedObject = type
            }
            let current = rules.first { $0.column == "Type" }?.value ?? ""
            if let index = typePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
                typePopup.selectItem(at: index)
            }
        } else {
            self.rules = rules
            addButton?.isHidden = false
            typePopup.isHidden = true
        }
        rebuild()
    }

    private static func typeTitle(_ type: String) -> String {
        switch type {
        case "zset": return "Sorted Set"
        default: return type.prefix(1).uppercased() + type.dropFirst()
        }
    }

    private var typeRules: [FilterRule] {
        guard case .keyPattern = style, let type = typePopup.selectedItem?.representedObject as? String, !type.isEmpty else { return [] }
        return [FilterRule(column: "Type", op: .equals, value: type)]
    }

    func addRuleIfEmpty() {
        if case .keyPattern = style {
            DispatchQueue.main.async { self.window?.makeFirstResponder(self.rawField) }
            return
        }
        if rules.isEmpty, let first = columns.first {
            rules.append(FilterRule(column: first, op: .equals))
            rebuild()
        }
        focusFirstValue()
    }

    private func focusFirstValue() {
        DispatchQueue.main.async {
            if let row = self.rowsStack.arrangedSubviews.last as? FilterRuleRow {
                self.window?.makeFirstResponder(row.valueField)
            }
        }
    }

    private func rebuild() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, rule) in rules.enumerated() {
            let row = FilterRuleRow(rule: rule, columns: columns)
            row.onChange = { [weak self] updated in
                guard let self, self.rules.indices.contains(index) else { return }
                self.rules[index] = updated
            }
            row.onRemove = { [weak self] in
                self?.rules.remove(at: index)
                self?.rebuild()
            }
            row.onSubmit = { [weak self] in self?.apply(nil) }
            rowsStack.addArrangedSubview(row)
            row.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor).isActive = true
        }
    }

    @objc private func addRule(_ sender: Any?) {
        guard let first = columns.first else { return }
        rules.append(FilterRule(column: first, op: .equals))
        rebuild()
        focusFirstValue()
    }

    @objc private func apply(_ sender: Any?) {
        closeRawSuggestions()
        window?.makeFirstResponder(nil)
        if case .keyPattern = style {
            onApply?(typeRules, rawField.stringValue)
        } else {
            onApply?(rules, rawField.stringValue)
        }
    }

    @objc private func clear(_ sender: Any?) {
        closeRawSuggestions()
        rules = []
        rawField.stringValue = ""
        typePopup.selectItem(at: 0)
        rebuild()
        onApply?([], "")
    }
}

// MARK: Raw SQL suggestions

extension FilterBarView: NSTextFieldDelegate {
    /// Asks on every edit, debounced (spec 10); meanwhile the open list is re-ranked for what is typed now.
    /// The list never preselects, so Return still applies the filter.
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === rawField, !isInsertingSuggestion else { return }
        refreshRawSuggestions()
        scheduleRawCompletion()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === rawField else { return }
        closeRawSuggestions()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === rawField, rawSuggestions.isShown else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            rawSuggestions.moveSelection(down: true)
            return true
        case #selector(NSResponder.moveUp(_:)):
            rawSuggestions.moveSelection(down: false)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let item = rawSuggestions.selectedItem {
                acceptRawSuggestion(item)
                return true
            }
            // Nothing chosen: Return applies the filter as usual.
            closeRawSuggestions()
            return false
        case #selector(NSResponder.insertTab(_:)):
            guard let item = rawSuggestions.selectedItem else {
                closeRawSuggestions()
                return false
            }
            acceptRawSuggestion(item)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeRawSuggestions()
            return true
        default:
            return false
        }
    }
}

extension FilterBarView {
    /// What the Raw SQL list shows, for scripted checks.
    var rawSuggestionLabels: [String] { rawSuggestions.isShown ? rawSuggestions.items.map(\.label) : [] }
    var rawSelectedSuggestion: String? { rawSuggestions.isShown ? rawSuggestions.selectedItem?.label : nil }
    var rawTextForTesting: String { rawField.currentEditor()?.string ?? rawField.stringValue }

    /// Types into the Raw SQL box one character at a time, as keystrokes would. Used by scripted UI checks.
    func typeRawForTesting(_ text: String) {
        if rawField.currentEditor() == nil { window?.makeFirstResponder(rawField) }
        guard let editor = rawField.currentEditor() as? NSTextView else { return }
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
    }

    /// Sends a named key through the field editor's command path, where the list claims it. False for an unknown name.
    @discardableResult
    func sendRawKeyForTesting(_ name: String) -> Bool {
        let selectors: [String: Selector] = [
            "down": #selector(NSResponder.moveDown(_:)),
            "up": #selector(NSResponder.moveUp(_:)),
            "return": #selector(NSResponder.insertNewline(_:)),
            "tab": #selector(NSResponder.insertTab(_:)),
            "escape": #selector(NSResponder.cancelOperation(_:)),
            "left": #selector(NSResponder.moveLeft(_:)),
            "right": #selector(NSResponder.moveRight(_:)),
            "cmd-right": #selector(NSResponder.moveToRightEndOfLine(_:)),
            "cmd-left": #selector(NSResponder.moveToLeftEndOfLine(_:)),
        ]
        guard let selector = selectors[name.lowercased()], let editor = rawField.currentEditor() as? NSTextView else { return false }
        editor.doCommand(by: selector)
        return true
    }

    private func scheduleRawCompletion() {
        rawRequest?.cancel()
        guard let rawCompletion, let editor = rawField.currentEditor() as? NSTextView,
              !editor.hasMarkedText(), !editor.string.isEmpty
        else { return closeRawSuggestions() }
        // The answer is for this text and caret; a caret move in the meantime drops it.
        let text = editor.string
        let selection = editor.selectedRange()
        rawRequest = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            await self?.runRawCompletion(rawCompletion, editor: editor, text: text, selection: selection)
        }
    }

    private func runRawCompletion(_ completer: RawCompletion, editor: NSTextView, text: String, selection: NSRange) async {
        guard selection.length == 0 else { return closeRawSuggestions() }
        guard isCurrent(editor, text: text, selection: selection), !editor.hasMarkedText() else { return }
        let result = await completer.complete(text, selection.location)
        // A newer edit supersedes this answer; so do a caret move and leaving the field.
        guard !Task.isCancelled, isCurrent(editor, text: text, selection: selection) else { return }
        guard let result, !result.items.isEmpty else { return closeRawSuggestions() }
        rawResult = result
        showRawSuggestions(result.items, editor: editor)
    }

    private func isCurrent(_ editor: NSTextView, text: String, selection: NSRange) -> Bool {
        rawField.currentEditor() === editor && editor.string == text && editor.selectedRange() == selection
    }

    /// Anchor to caret while the caret is still in the token the list was computed for (as in the editor, spec 1.5).
    private func liveRawToken(of result: CompletionResult) -> String? {
        guard let editor = rawField.currentEditor() as? NSTextView else { return nil }
        return CompletionTokenRule.sql.liveToken(in: editor.string as NSString, selection: editor.selectedRange(), anchor: result.replacementRange.location)
    }

    /// Re-ranks the open list for the live token, or closes it when the caret left the token or nothing matches.
    /// A request an edit just scheduled stays, so `users.` still gets its answer after `users` closed.
    private func refreshRawSuggestions() {
        guard let result = rawResult else { return }
        guard let rawCompletion, let editor = rawField.currentEditor() as? NSTextView, !editor.hasMarkedText(),
              let token = liveRawToken(of: result)
        else { return hideRawSuggestions() }
        guard token != result.token else { return }
        let items = token.isEmpty ? [] : rawCompletion.refilter(result, token)
        guard !items.isEmpty else { return hideRawSuggestions() }
        rawResult?.items = items
        rawResult?.token = token
        showRawSuggestions(items, editor: editor)
    }

    /// Splices the item over token start to the live caret and places the caret as the editor does.
    /// Nothing is inserted when the caret is no longer in that token or text is selected.
    private func acceptRawSuggestion(_ item: CompletionItem) {
        guard let result = rawResult, let editor = rawField.currentEditor() as? NSTextView,
              let token = liveRawToken(of: result)
        else { return closeRawSuggestions() }
        let range = NSRange(location: result.replacementRange.location, length: (token as NSString).length)
        closeRawSuggestions()
        // A click in the popover can take key status from the window that holds the field.
        rawField.window?.makeKey()
        isInsertingSuggestion = true
        editor.insertText(item.insertText, replacementRange: range)
        if item.caretOffsetFromEnd > 0 {
            let end = editor.selectedRange().location
            editor.setSelectedRange(NSRange(location: max(range.location, end - item.caretOffsetFromEnd), length: 0))
        }
        isInsertingSuggestion = false
    }

    private func showRawSuggestions(_ items: [CompletionItem], editor: NSTextView) {
        rawSuggestions.show(items, below: rawField)
        guard observedFieldEditor !== editor else { return }
        stopObservingFieldEditor()
        observedFieldEditor = editor
        NotificationCenter.default.addObserver(self, selector: #selector(rawSelectionDidChange(_:)), name: NSTextView.didChangeSelectionNotification, object: editor)
    }

    /// A click in the field, ⌘→, ⌃E, Home/End, ⇧-arrows or ⌘A move the caret without an edit (spec 1.6).
    @objc private func rawSelectionDidChange(_ notification: Notification) {
        guard !isInsertingSuggestion else { return }
        refreshRawSuggestions()
    }

    private func stopObservingFieldEditor() {
        if let observedFieldEditor {
            NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: observedFieldEditor)
        }
        observedFieldEditor = nil
    }

    /// Closes the list but keeps a pending request.
    private func hideRawSuggestions() {
        rawResult = nil
        rawSuggestions.close()
        stopObservingFieldEditor()
    }

    private func closeRawSuggestions() {
        rawRequest?.cancel()
        rawRequest = nil
        hideRawSuggestions()
    }
}

/// Label-only rows in a popover under the Raw SQL box. Nothing is selected until Down or Up enters the list.
@MainActor
private final class RawSuggestionList: NSObject {
    static let rowHeight: CGFloat = 22
    static let maximumRows = 8
    static let padding: CGFloat = 4
    static let minimumWidth: CGFloat = 160

    private let popover = NSPopover()
    private let scroll = NSScrollView()
    private let rows = RawSuggestionRows()
    private let onAccept: (CompletionItem) -> Void
    private(set) var items: [CompletionItem] = []
    private(set) var selectedIndex: Int?

    init(onAccept: @escaping (CompletionItem) -> Void) {
        self.onAccept = onAccept
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = false
        scroll.documentView = rows
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let controller = NSViewController()
        controller.view = scroll
        popover.contentViewController = controller
        rows.list = self
    }

    var isShown: Bool { popover.isShown }
    var selectedItem: CompletionItem? { selectedIndex.flatMap { items[safe: $0] } }

    func show(_ items: [CompletionItem], below field: NSView) {
        // Updating an open list keeps the row the user moved to; a new list starts with nothing selected.
        let kept = popover.isShown ? selectedItem : nil
        self.items = items
        selectedIndex = kept.flatMap { kept in
            items.firstIndex { $0.label == kept.label && $0.kind == kept.kind && $0.insertText == kept.insertText }
        }
        let width = max(field.bounds.width, Self.minimumWidth)
        let visibleRows = CGFloat(min(items.count, Self.maximumRows))
        rows.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(items.count) * Self.rowHeight + 2 * Self.padding)
        popover.contentSize = NSSize(width: width, height: visibleRows * Self.rowHeight + 2 * Self.padding)
        rows.needsDisplay = true
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        if let selectedIndex {
            rows.scrollToVisible(rows.rect(forRow: selectedIndex).insetBy(dx: 0, dy: -Self.padding))
        }
        guard !popover.isShown else { return }
        popover.show(relativeTo: field.bounds, of: field, preferredEdge: field.isFlipped ? .maxY : .minY)
        NSAccessibility.post(element: field, notification: .announcementRequested, userInfo: [
            .announcement: "\(items.count) suggestions available, press Down Arrow to browse",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    func close() {
        items = []
        selectedIndex = nil
        if popover.isShown { popover.close() }
    }

    /// Down enters at the first row and Up at the last; both clamp inside the list.
    func moveSelection(down: Bool) {
        guard !items.isEmpty else { return }
        if let current = selectedIndex {
            selectedIndex = down ? min(current + 1, items.count - 1) : max(current - 1, 0)
        } else {
            selectedIndex = down ? 0 : items.count - 1
        }
        rows.needsDisplay = true
        if let selectedIndex {
            rows.scrollToVisible(rows.rect(forRow: selectedIndex).insetBy(dx: 0, dy: -Self.padding))
        }
    }

    fileprivate func clicked(row: Int) {
        guard let item = items[safe: row] else { return }
        selectedIndex = row
        onAccept(item)
    }
}

private final class RawSuggestionRows: NSView {
    weak var list: RawSuggestionList?
    private let font = NSFont.preferredFont(forTextStyle: .callout)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func rect(forRow row: Int) -> NSRect {
        NSRect(x: 0, y: RawSuggestionList.padding + CGFloat(row) * RawSuggestionList.rowHeight, width: bounds.width, height: RawSuggestionList.rowHeight)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = Int((point.y - RawSuggestionList.padding) / RawSuggestionList.rowHeight)
        guard point.y >= RawSuggestionList.padding else { return }
        list?.clicked(row: row)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let list, !list.items.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        for (row, item) in list.items.enumerated() {
            let rowRect = rect(forRow: row)
            guard rowRect.intersects(dirtyRect) else { continue }
            let selected = row == list.selectedIndex
            if selected {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 4, dy: 0), xRadius: 4, yRadius: 4).fill()
            }
            let color: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
            let text = NSAttributedString(string: item.label, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
            let frame = NSRect(x: rowRect.minX + 10, y: (rowRect.midY - lineHeight / 2).rounded(), width: rowRect.width - 20, height: lineHeight)
            text.draw(with: frame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

private final class FilterRuleRow: NSView {
    var onChange: ((FilterRule) -> Void)?
    var onRemove: (() -> Void)?
    var onSubmit: (() -> Void)?
    let valueField = NSTextField()

    private var rule: FilterRule
    private let enabled = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let columnPopup = NSPopUpButton()
    private let operatorPopup = NSPopUpButton()

    init(rule: FilterRule, columns: [String]) {
        self.rule = rule
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        enabled.state = rule.isEnabled ? .on : .off
        enabled.target = self
        enabled.action = #selector(changed(_:))

        columnPopup.controlSize = .small
        columnPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        columnPopup.addItems(withTitles: columns)
        columnPopup.selectItem(withTitle: rule.column)
        columnPopup.target = self
        columnPopup.action = #selector(changed(_:))

        operatorPopup.controlSize = .small
        operatorPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for op in FilterOperator.allCases {
            operatorPopup.addItem(withTitle: op.title)
            operatorPopup.lastItem?.representedObject = op.rawValue
        }
        operatorPopup.selectItem(at: FilterOperator.allCases.firstIndex(of: rule.op) ?? 0)
        operatorPopup.target = self
        operatorPopup.action = #selector(changed(_:))

        valueField.stringValue = rule.value
        valueField.placeholderString = "Value"
        valueField.controlSize = .small
        valueField.font = Theme.monospaced(11)
        valueField.target = self
        valueField.action = #selector(submitted(_:))
        valueField.delegate = self
        valueField.isEnabled = rule.op.needsValue
        valueField.setAccessibilityIdentifier("filterValue")

        let remove = UI.iconButton("minus.circle", tooltip: "Remove Filter", target: self, action: #selector(removeClicked(_:)))
        let stack = UI.hstack([enabled, columnPopup, operatorPopup, valueField, remove], spacing: 6)
        addSubviewFilling(stack)
        columnPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        valueField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func changed(_ sender: Any?) {
        rule.isEnabled = enabled.state == .on
        rule.column = columnPopup.titleOfSelectedItem ?? rule.column
        if let raw = operatorPopup.selectedItem?.representedObject as? String, let op = FilterOperator(rawValue: raw) {
            rule.op = op
        }
        rule.value = valueField.stringValue
        valueField.isEnabled = rule.op.needsValue
        onChange?(rule)
    }

    @objc private func submitted(_ sender: Any?) {
        changed(nil)
        onSubmit?()
    }

    @objc private func removeClicked(_ sender: Any?) {
        onRemove?()
    }
}

extension FilterRuleRow: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        changed(nil)
    }
}

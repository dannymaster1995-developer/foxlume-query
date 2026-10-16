import AppKit
import Carbon.HIToolbox
import FoxlumeQueryCore

/// Supplies the completer and the settings it reads; both are read per request, so a change applies on the next keystroke.
@MainActor
protocol SQLCompletionProvider: AnyObject {
    /// Nil turns completion off.
    var completionEngine: CompletionEngine? { get }
    var completionKeywordCase: KeywordCase { get }
    /// "Suggest completions while typing". When false only ⌃Space and Escape open the list.
    var completesWhileTyping: Bool { get }
}

/// Which text still belongs to the token an open list was computed for; once the caret leaves it, the list closes
/// (spec 1.5, 2.3, 8.1). Engines may still reject a live token in `refilter`.
enum CompletionTokenRule {
    case sql, mongo, redis

    init(_ language: QueryLanguage) {
        switch language {
        case .sql: self = .sql
        case .mongo: self = .mongo
        case .redis: self = .redis
        }
    }

    /// Typing `character` keeps the caret inside the token.
    func continues(with character: Character) -> Bool {
        switch self {
        case .sql:
            if character == "_" || character == "`" || character == "\"" { return true }
            if character.isLetter || character.isNumber { return true }
            return !character.isASCII && character.unicodeScalars.first?.properties.isAlphabetic == true
        case .mongo:
            return (character.isASCII && (character.isLetter || character.isNumber)) || character == "_" || character == "$"
        case .redis:
            // The Redis engine's token starts at an argument's opening quote, so quotes belong to it.
            return !character.isWhitespace
        }
    }

    /// A quoted Redis argument runs to its closing quote, spaces included, as redis-cli splits it.
    func isToken(_ token: String) -> Bool {
        guard self == .redis, let quote = token.first, quote == "\"" || quote == "'" else {
            return token.allSatisfy(continues(with:))
        }
        var escaped = false
        for character in token.dropFirst() {
            if character.isNewline { return false }
            if escaped {
                escaped = false
            } else if character == "\\" && quote == "\"" {
                escaped = true
            } else if character == quote {
                return false
            }
        }
        return true
    }

    /// Anchor to caret when the caret is still in the token the list was opened for; nil when it left it.
    func liveToken(in text: NSString, selection: NSRange, anchor: Int) -> String? {
        guard selection.length == 0, anchor >= 0, selection.location <= text.length else { return nil }
        let length = selection.location - anchor
        guard length >= 0, length <= 500 else { return nil }
        let token = text.substring(with: NSRange(location: anchor, length: length))
        return isToken(token) ? token : nil
    }
}

/// Scrollable SQL editor with line numbers, highlighting and completion.
final class SQLEditorView: NSView {
    let textView: SQLTextView
    let scrollView = NSScrollView()
    private let ruler: LineNumberRulerView
    var onTextChange: (() -> Void)?
    weak var completionProvider: SQLCompletionProvider? {
        didSet { textView.completionProvider = completionProvider }
    }

    var string: String {
        get { textView.string }
        set {
            textView.string = newValue
            textView.didReplaceText()
        }
    }

    var isEditable: Bool {
        get { textView.isEditable }
        set { textView.isEditable = newValue }
    }

    var language: QueryLanguage {
        get { textView.language }
        set { textView.language = newValue }
    }

    /// Off: long lines run on and the editor scrolls horizontally.
    var wrapsLines = true {
        didSet { if wrapsLines != oldValue { applyWrapping() } }
    }

    /// Shades the statement at the caret when the text holds several.
    var highlightsCurrentStatement: Bool {
        get { textView.highlightsCurrentStatement }
        set { textView.highlightsCurrentStatement = newValue }
    }

    override init(frame frameRect: NSRect) {
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        textView = SQLTextView(frame: .zero, textContainer: container)
        ruler = LineNumberRulerView(textView: textView)
        super.init(frame: frameRect)

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.onChange = { [weak self] in self?.onTextChange?() }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editorBackground
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        ruler.observeScrolling(of: scrollView.contentView)
        addSubviewFilling(scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameDidChange), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The selection, or the statement under the cursor when nothing is selected.
    var selectedText: String {
        let range = textView.selectedRange()
        guard range.length > 0 else { return "" }
        return (textView.string as NSString).substring(with: range)
    }

    func highlightRange(_ range: NSRange) {
        textView.showFindIndicator(for: range)
    }

    func applyFontSize(_ size: CGFloat) {
        textView.font = Theme.monospaced(size)
        ruler.font = Theme.monospaced(max(9, size - 2))
        ruler.needsDisplay = true
    }

    /// Wrapping lets the text container follow the text view's width; without it the container is unbounded and
    /// the text view grows to the longest line, never narrower than the visible area.
    private func applyWrapping() {
        guard let container = textView.textContainer else { return }
        let width = visibleTextWidth
        if wrapsLines {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.minSize = NSSize(width: 0, height: 0)
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            container.containerSize = NSSize(width: max(0, width - textView.textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
            container.widthTracksTextView = true
            scrollView.contentView.scroll(to: NSPoint(x: -scrollView.contentView.contentInsets.left, y: scrollView.contentView.bounds.minY))
        } else {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            textView.minSize = NSSize(width: width, height: 0)
            scrollView.hasHorizontalScroller = true
            textView.sizeToFit()
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
        ruler.needsDisplay = true
        textView.needsDisplay = true
    }

    /// The width the text has beside the line numbers: the ruler lies over the clip view, which insets its content.
    var visibleTextWidth: CGFloat {
        scrollView.contentView.bounds.width - scrollView.contentView.contentInsets.left
    }

    /// Without wrapping the text view keeps at least the visible width, so the current line and statement band
    /// reach the right edge after the editor grows.
    @objc private func clipFrameDidChange() {
        guard !wrapsLines else { return }
        let width = visibleTextWidth
        guard textView.minSize.width != width else { return }
        textView.minSize = NSSize(width: width, height: 0)
        textView.sizeToFit()
    }
}

final class SQLTextView: NSTextView {
    weak var completionProvider: SQLCompletionProvider?
    var onChange: (() -> Void)?
    private var highlightWork: DispatchWorkItem?
    /// Decides highlighting rules; set before text is shown.
    var language: QueryLanguage = .sql(.postgresql) {
        didSet {
            lexCheckpoints = []
            scheduleHighlight(immediately: true)
            rebuildStatementMap()
        }
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        smartInsertDeleteEnabled = false
        font = Theme.monospaced(CGFloat(SettingsStore.shared.settings.editorFontSize))
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: ThemeManager.didChangeNotification, object: nil)
        if let textStorage {
            // Every character edit, typed, pasted, undone or set, invalidates the rewriter's lexer checkpoints after it.
            NotificationCenter.default.addObserver(self, selector: #selector(dropLexCheckpoints(_:)), name: NSTextStorage.didProcessEditingNotification, object: textStorage)
            NotificationCenter.default.addObserver(self, selector: #selector(shiftStatementMap(_:)), name: NSTextStorage.didProcessEditingNotification, object: textStorage)
        }
        setAccessibilityIdentifier("sqlEditor")
    }

    private func applyTheme() {
        textColor = Theme.editorForeground
        backgroundColor = Theme.editorBackground
        insertionPointColor = Theme.editorCursor
        selectedTextAttributes = [.backgroundColor: Theme.editorSelection]
        typingAttributes[.foregroundColor] = Theme.editorForeground
    }

    @objc private func themeChanged() {
        applyTheme()
        enclosingScrollView?.backgroundColor = Theme.editorBackground
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
        scheduleHighlight(immediately: true)
        needsDisplay = true
    }

    func didReplaceText() {
        endCompletionSession()
        scheduleHighlight(immediately: true)
        rebuildStatementMap()
        onChange?()
    }

    private func scheduleHighlight(immediately: Bool = false) {
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            SQLHighlighter.apply(to: self, language: self.language)
        }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.05), execute: work)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        scheduleHighlight(immediately: true)
    }

    // MARK: Current statement

    /// Set by the owner from Settings › SQL Editor; off by default so previews and sheets show no band.
    var highlightsCurrentStatement = false {
        didSet {
            guard highlightsCurrentStatement != oldValue else { return }
            rebuildStatementMap()
        }
    }

    /// The statements as last split; between an edit and the next split, shifted by the edit.
    private(set) var statementMap = StatementMap()
    /// The statement at the caret, with its `;`, while the band is shown.
    private(set) var statementBandRange: NSRange?
    private var statementMapWork: DispatchWorkItem?
    /// The pause after the last edit before the text is split again, so typing in a long script stays smooth.
    static var statementMapDelay: TimeInterval = 0.25

    /// Splits the text now, or empties the map when the band is off.
    func rebuildStatementMap() {
        statementMapWork?.cancel()
        statementMapWork = nil
        statementMap = highlightsCurrentStatement ? StatementMap(text: string, language: language) : StatementMap()
        updateStatementBand()
    }

    private func scheduleStatementMap() {
        guard highlightsCurrentStatement else { return }
        statementMapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildStatementMap() }
        statementMapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.statementMapDelay, execute: work)
    }

    /// The characters an edit replaces and the length of their replacement, from shouldChangeText. The storage's
    /// edited range can also cover attributes fixed around the edit, so it is used only when this is missing.
    private var pendingStatementEdit: (range: NSRange, newLength: Int)?

    @objc private func shiftStatementMap(_ notification: Notification) {
        let pending = pendingStatementEdit
        pendingStatementEdit = nil
        guard !statementMap.entries.isEmpty, let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters)
        else { return }
        let delta = storage.changeInLength
        var edited = storage.editedRange
        if let pending, pending.newLength - pending.range.length == delta {
            edited = NSRange(location: pending.range.location, length: pending.newLength)
        }
        statementMap = statementMap.shifted(byEditing: edited, changeInLength: delta)
    }

    private func updateStatementBand() {
        let selection = selectedRange()
        let band = highlightsCurrentStatement && selection.length == 0 ? statementMap.bandRange(at: selection.location) : nil
        guard band != statementBandRange else { return }
        statementBandRange = band
        needsDisplay = true
    }

    /// Full-width rect from the band's first line to its last, in view coordinates.
    private func statementBandRect(_ range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let length = (string as NSString).length
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        guard clamped.length > 0 else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let first = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = layoutManager.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        _ = textContainer
        return NSRect(x: 0, y: first.minY + textContainerOrigin.y, width: bounds.width, height: last.maxY - first.minY)
    }

    /// The band's rect in view coordinates, for tests and scripted checks.
    var statementBandRectForTesting: NSRect? { statementBandRange.flatMap(statementBandRect) }

    // MARK: Current line

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer, window?.firstResponder === self, selectedRange().length == 0 else { return }
        let band = statementBandRange
        if let band, let bandRect = statementBandRect(band)?.intersection(rect), !bandRect.isEmpty {
            Theme.statementBand.setFill()
            bandRect.fill()
        }
        let text = string as NSString
        let location = min(selectedRange().location, text.length)
        var lineRect: NSRect
        if text.length == 0 || location == text.length && (location == 0 || text.character(at: location - 1) == 10) {
            lineRect = layoutManager.extraLineFragmentRect
            if lineRect.isEmpty, text.length > 0 {
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: max(0, location - 1)), effectiveRange: nil)
            }
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(location, max(0, text.length - 1)))
            lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        guard !lineRect.isEmpty else { return }
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        lineRect.origin.y += textContainerOrigin.y
        _ = textContainer
        // The band always holds the caret's line.
        (band == nil ? Theme.currentLine : Theme.currentLineInBand).setFill()
        lineRect.fill()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
        updateStatementBand()
        // Edits handle the list once they finish; a plain caret move re-filters it or closes it (spec 1.5).
        guard completionSession != nil, !editingText, !isProgrammaticEdit, typedInsertDepth == 0, !hasMarkedText() else { return }
        refilterCompletionSession()
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            needsDisplay = true
            endCompletionSession()
        }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            endCompletionSession()
            stopObservingCompletionContext()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeCompletionContext()
    }

    // MARK: Editing helpers

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let selection = selectedRange()
        let location = selection.location
        let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        let line = text.substring(with: NSRange(location: lineRange.location, length: max(0, location - lineRange.location)))
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        if selection.length == 0 { rewriteKeywordCase(wordEndingAt: location) }
        isProgrammaticEdit = true
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
        isProgrammaticEdit = false
        // A newline ends the word but never asks for suggestions.
        endCompletionSession()
    }

    override func insertTab(_ sender: Any?) {
        if selectedRange().length == 0 { rewriteKeywordCase(wordEndingAt: selectedRange().location) }
        isProgrammaticEdit = true
        insertText("    ", replacementRange: selectedRange())
        isProgrammaticEdit = false
        endCompletionSession()
    }

    @objc func toggleComment(_ sender: Any?) {
        let text = string as NSString
        let lines = text.lineRange(for: selectedRange())
        let block = text.substring(with: lines)
        var parts = block.components(separatedBy: "\n")
        let trailingEmpty = parts.last == ""
        if trailingEmpty { parts.removeLast() }
        let allCommented = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
        let toggled = parts.map { line -> String in
            if allCommented {
                guard let range = line.range(of: "--") else { return line }
                var result = line
                result.removeSubrange(range)
                if result[range.lowerBound...].hasPrefix(" ") { result.remove(at: range.lowerBound) }
                return result
            }
            return line.trimmingCharacters(in: .whitespaces).isEmpty ? line : "-- " + line
        }.joined(separator: "\n") + (trailingEmpty ? "\n" : "")
        guard shouldChangeText(in: lines, replacementString: toggled) else { return }
        replaceCharacters(in: lines, with: toggled)
        didChangeText()
        setSelectedRange(NSRange(location: lines.location, length: (toggled as NSString).length))
    }

    // MARK: Completion

    /// Scripted UI checks run with the app in the background, where no window is key.
    static var assumesKeyWindow = false

    /// One open list: the engine's answer and the token start it belongs to (spec 1.5).
    private struct CompletionSession {
        var result: CompletionResult
        var anchor: Int
        /// Where the token start was on screen when the list was placed.
        var caretRect = NSRect.zero
    }

    private var completionSession: CompletionSession?
    private var completionRequest: Task<Void, Never>?
    /// The editor's own edits (accepting, indenting, case rewriting) never ask for suggestions.
    private var isProgrammaticEdit = false
    /// Between shouldChangeText and didChangeText the caret moves with the edit; the edit is handled once, after it.
    private var editingText = false
    /// Inside a typed insertText: the keystroke is handled when the insertion is complete.
    private var typedInsertDepth = 0
    private weak var observedWindow: NSWindow?
    private weak var observedClipView: NSClipView?
    private weak var observedScrollView: NSScrollView?
    private var completionPopup: CompletionPopup { .shared }
    private var tokenRule: CompletionTokenRule { CompletionTokenRule(language) }
    private var completionKeywordCase: KeywordCase { completionProvider?.completionKeywordCase ?? .matchTypedElseUpper }

    var isShowingCompletions: Bool { completionPopup.isShowing(for: self) }
    var visibleCompletionLabels: [String] { isShowingCompletions ? completionPopup.items.map(\.label) : [] }
    var selectedCompletionLabel: String? { isShowingCompletions ? completionPopup.selectedItem?.label : nil }
    /// The list's screen frame and the caret rect it was placed from, for scripted checks.
    var completionFrameForTesting: NSRect? { isShowingCompletions ? completionPopup.visibleFrame : nil }
    var completionCaretRectForTesting: NSRect? {
        completionSession.map { firstRect(forCharacterRange: NSRange(location: $0.anchor, length: 0), actualRange: nil) }
    }

    func acceptSelectedCompletion() {
        guard isShowingCompletions, let item = completionPopup.selectedItem else { return }
        acceptCompletion(item)
    }

    /// What ⌃Space does when the list is closed: ask with `manual` set, which skips the empty-prefix policy.
    func requestManualCompletion() {
        requestCompletions(manual: true)
    }

    func hideCompletions() {
        endCompletionSession()
    }

    override func keyDown(with event: NSEvent) {
        let chord = event.modifierFlags.intersection([.command, .control, .option])
        if chord == .control, Int(event.keyCode) == kVK_Space {
            return toggleCompletions()
        }
        // IME composition and every Cmd/Ctrl/Option chord stay with the editor (⌘↩ runs, ⌥↑ moves lines).
        guard chord.isEmpty, !hasMarkedText() else { return super.keyDown(with: event) }
        if isShowingCompletions {
            switch Int(event.keyCode) {
            case kVK_DownArrow: return completionPopup.moveSelection(by: 1)
            case kVK_UpArrow: return completionPopup.moveSelection(by: -1)
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab: return acceptSelectedCompletion()
            case kVK_Escape: return endCompletionSession()
            default: break
            }
        } else if Int(event.keyCode) == kVK_Escape {
            // As in Xcode, Escape with no list open asks for one.
            return requestCompletions(manual: true)
        }
        super.keyDown(with: event)
    }

    override func complete(_ sender: Any?) {
        toggleCompletions()
    }

    private func toggleCompletions() {
        if completionSession != nil || isShowingCompletions {
            endCompletionSession()
        } else {
            requestCompletions(manual: true)
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard !isProgrammaticEdit else { return super.insertText(string, replacementRange: replacementRange) }
        typedInsertDepth += 1
        super.insertText(string, replacementRange: replacementRange)
        typedInsertDepth -= 1
        let typed = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard typedInsertDepth == 0, let last = typed.last else { return }
        didType(last)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        editingText = allowed
        if allowed, let replacementString {
            pendingStatementEdit = (affectedCharRange, (replacementString as NSString).length)
        }
        return allowed
    }

    override func didChangeText() {
        super.didChangeText()
        editingText = false
        scheduleHighlight()
        scheduleStatementMap()
        updateStatementBand()
        onChange?()
        // Deletions, cuts and undo re-filter an open list (Backspace widens it) but never open one.
        guard completionSession != nil, !isProgrammaticEdit, typedInsertDepth == 0, !hasMarkedText() else { return }
        refilterCompletionSession()
    }

    /// After a typed insertion (spec 1.1, 1.5, 5.4).
    private func didType(_ character: Character) {
        if Self.isWordBoundary(character) {
            rewriteKeywordCase(wordEndingAt: selectedRange().location - character.utf16.count)
        }
        guard !hasMarkedText() else { return }
        if completionSession != nil, refilterCompletionSession() { return }
        if isCompletionTrigger(character) {
            if completionProvider?.completesWhileTyping == true { requestCompletions(manual: false) }
        } else if !tokenRule.continues(with: character) {
            // Leaving the token without a trigger (`=`, `;`) never opens a list, not even one already asked for.
            completionRequest?.cancel()
        }
    }

    private func requestCompletions(manual: Bool) {
        completionRequest?.cancel()
        guard let engine = completionProvider?.completionEngine else { return }
        completionRequest = Task { @MainActor [weak self] in
            // A newer keystroke cancels this request during the pause (spec 1.5).
            if !manual { try? await Task.sleep(nanoseconds: 50_000_000) }
            guard !Task.isCancelled else { return }
            await self?.runCompletionRequest(engine: engine, manual: manual)
        }
    }

    private func runCompletionRequest(engine: CompletionEngine, manual: Bool) async {
        guard canShowCompletions, !hasMarkedText(), selectedRange().length == 0 else { return }
        let text = string
        let caret = selectedRange().location
        let keywordCase = completionKeywordCase
        let answer = await engine.complete(text: text, caret: caret, manual: manual, keywordCase: keywordCase)
        guard !Task.isCancelled else { return }
        // Focus may have moved while the engine worked; then nothing is shown (spec 11.8).
        guard var result = answer, canShowCompletions, !hasMarkedText() else { return endCompletionSession() }
        let anchor = result.replacementRange.location
        if string != text || selectedRange() != NSRange(location: caret, length: 0) {
            // The user kept typing: re-rank the pool for the token that is there now.
            guard let token = liveToken(from: anchor) else { return endCompletionSession() }
            if token != result.token {
                guard !token.isEmpty else { return endCompletionSession() }
                result.items = engine.refilter(result, token: token, keywordCase: keywordCase)
                result.token = token
            }
        }
        guard !result.items.isEmpty else { return endCompletionSession() }
        showCompletionSession(CompletionSession(result: result, anchor: anchor))
    }

    private func showCompletionSession(_ session: CompletionSession) {
        guard let window else { return }
        var session = session
        let anchor = completionAnchor(at: session.anchor, in: window)
        session.caretRect = anchor.caretRect
        completionSession = session
        completionPopup.show(session.result.items, owner: self, anchor: anchor, parent: window)
    }

    private func completionAnchor(at location: Int, in window: NSWindow) -> CompletionAnchor {
        let caret = firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        let editor: NSView = enclosingScrollView ?? self
        let editorFrame = window.convertToScreen(editor.convert(editor.bounds, to: nil))
        return CompletionAnchor(caretRect: caret, editorFrame: editorFrame, font: font ?? Theme.monospaced(12))
    }

    /// Re-ranks the session's pool for the live token. Closes the list when the caret left the token,
    /// the token was deleted back to nothing, or nothing matches.
    @discardableResult
    private func refilterCompletionSession() -> Bool {
        guard let session = completionSession, let engine = completionProvider?.completionEngine,
              let token = liveToken(from: session.anchor)
        else {
            endCompletionSession()
            return false
        }
        guard token != session.result.token else { return true }
        let items = token.isEmpty ? [] : engine.refilter(session.result, token: token, keywordCase: completionKeywordCase)
        guard !items.isEmpty else {
            endCompletionSession()
            return false
        }
        completionSession?.result.items = items
        completionSession?.result.token = token
        completionPopup.update(items, for: self)
        return true
    }

    /// Anchor to caret when the caret is still in the token the list was opened for; nil when it left it.
    private func liveToken(from anchor: Int) -> String? {
        tokenRule.liveToken(in: string as NSString, selection: selectedRange(), anchor: anchor)
    }

    func endCompletionSession() {
        completionRequest?.cancel()
        completionRequest = nil
        completionSession = nil
        completionPopup.close(for: self)
    }

    /// Replaces token start to the live caret with the item (undoable), then places the caret (spec 5.1).
    private func acceptCompletion(_ item: CompletionItem) {
        guard let session = completionSession else { return }
        let length = (string as NSString).length
        let caret = min(selectedRange().location, length)
        let range = caret >= session.anchor
            ? NSRange(location: session.anchor, length: caret - session.anchor)
            : session.result.replacementRange
        endCompletionSession()
        guard NSMaxRange(range) <= length else { return }
        breakUndoCoalescing()
        isProgrammaticEdit = true
        insertText(item.insertText, replacementRange: range)
        if item.caretOffsetFromEnd > 0 {
            let end = selectedRange().location
            setSelectedRange(NSRange(location: max(range.location, end - item.caretOffsetFromEnd), length: 0))
        }
        isProgrammaticEdit = false
        breakUndoCoalescing()
    }

    private var canShowCompletions: Bool {
        guard let window, window.firstResponder === self else { return false }
        return window.isKeyWindow || Self.assumesKeyWindow
    }

    /// Letters and digits of any script, plus the engine's trigger characters (spec 1.1).
    private func isCompletionTrigger(_ character: Character) -> Bool {
        if character.isLetter || character.isNumber { return true }
        return completionProvider?.completionEngine?.triggerCharacters.contains(character) ?? false
    }

    private func observeCompletionContext() {
        stopObservingCompletionContext()
        guard let window else { return }
        let center = NotificationCenter.default
        observedWindow = window
        center.addObserver(self, selector: #selector(completionContextLost(_:)), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(completionContextLost(_:)), name: NSApplication.didResignActiveNotification, object: nil)
        if let scrollView = enclosingScrollView {
            let clip = scrollView.contentView
            observedScrollView = scrollView
            observedClipView = clip
            clip.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(clipViewBoundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: clip)
            // Dragging the scroller or a trackpad scroll closes the list like the scroll wheel (spec 11.7).
            center.addObserver(self, selector: #selector(completionContextLost(_:)), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        }
    }

    /// The clip view's bounds also change without the user scrolling: a ruler width change, a resized window or
    /// split view, typing near the edge, non-contiguous layout re-estimating the text height. The list follows its
    /// token while the token is in view and closes once it is not. A request still waiting places its list from
    /// the caret when it answers, so it is left alone.
    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard let session = completionSession, let window, isShowingCompletions else { return }
        let anchor = completionAnchor(at: session.anchor, in: window)
        guard anchor.caretRect.origin != session.caretRect.origin else { return }
        guard anchor.editorFrame.contains(NSPoint(x: anchor.caretRect.minX, y: anchor.caretRect.midY)) else {
            return endCompletionSession()
        }
        completionSession?.caretRect = anchor.caretRect
        completionPopup.move(to: anchor, for: self)
    }

    /// The user scrolling the editor closes the list; it does not follow the text (spec 11.7 recommendation).
    override func scrollWheel(with event: NSEvent) {
        if completionSession != nil || completionRequest != nil { endCompletionSession() }
        super.scrollWheel(with: event)
    }

    private func stopObservingCompletionContext() {
        let center = NotificationCenter.default
        if let observedWindow { center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedWindow) }
        if let observedClipView { center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView) }
        if let observedScrollView { center.removeObserver(self, name: NSScrollView.willStartLiveScrollNotification, object: observedScrollView) }
        center.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        observedWindow = nil
        observedClipView = nil
        observedScrollView = nil
    }

    @objc private func completionContextLost(_ notification: Notification) {
        guard completionSession != nil || completionRequest != nil else { return }
        endCompletionSession()
    }

    // MARK: Keyword case

    /// Typing one of these ends a word, which the UPPERCASE and lowercase policies re-case (spec 5.4).
    private static func isWordBoundary(_ character: Character) -> Bool {
        " \t\n\r(),;".contains(character)
    }

    /// Larger documents are left alone; lexing them on every word would lag.
    private static let keywordCaseDocumentLimit = 500_000

    /// Re-cases the keyword that ends at `end` for the absolute policies. Strings, comments, quoted names,
    /// `$$` bodies and qualified names (`t.select`) are left alone. Undoable.
    private func rewriteKeywordCase(wordEndingAt end: Int) {
        guard case .sql(let family) = language else { return }
        let policy = completionKeywordCase
        guard policy == .upper || policy == .lower else { return }
        let text = string as NSString
        guard text.length < Self.keywordCaseDocumentLimit, end > 0, end <= text.length else { return }
        var start = end
        while start > 0, Self.isWordCharacter(text.character(at: start - 1)) { start -= 1 }
        guard start < end, end - start <= 32, start == 0 || text.character(at: start - 1) != 46 else { return }
        let range = NSRange(location: start, length: end - start)
        let word = text.substring(with: range)
        let cased = policy == .upper ? word.uppercased() : word.lowercased()
        let keywords = Self.rewriteKeywords
        guard cased != word, keywords.contains(word.uppercased()) || keywords.contains(word.lowercased()),
              isBareWord(range, in: text, family: family)
        else { return }
        let selection = selectedRanges
        isProgrammaticEdit = true
        if shouldChangeText(in: range, replacementString: cased) {
            replaceCharacters(in: range, with: cased)
            didChangeText()
        }
        selectedRanges = selection
        isProgrammaticEdit = false
    }

    /// Word starts where the lexer is outside every string, comment and quoted name, so the rewriter lexes from the
    /// nearest one before a word instead of from the top. Sorted; an edit drops the ones at or after it.
    private var lexCheckpoints: [Int] = []
    private static let lexCheckpointSpacing = 4_096

    /// Only the text before the word decides whether a string, comment or quoted name is still open around it,
    /// so lexing from a checkpoint ends on the same token as lexing the whole prefix would.
    private func isBareWord(_ word: NSRange, in text: NSString, family: SQLDialect.Family) -> Bool {
        let baseIndex = lexCheckpoints.lastIndex { $0 <= word.location }
        let base = baseIndex.map { lexCheckpoints[$0] } ?? 0
        let tokens = SQLLexer.tokenize(text.substring(with: NSRange(location: base, length: NSMaxRange(word) - base)) as NSString, family: family)
        // A word token's start does not depend on what follows it, so later calls can restart there.
        var added: [Int] = []
        var last = base
        for token in tokens where token.kind == .word {
            let location = base + token.range.location
            guard location < word.location else { break }
            if location - last >= Self.lexCheckpointSpacing {
                added.append(location)
                last = location
            }
        }
        lexCheckpoints.insert(contentsOf: added, at: baseIndex.map { $0 + 1 } ?? 0)
        guard let token = tokens.last, token.kind == .word else { return false }
        return token.range == NSRange(location: word.location - base, length: word.length)
    }

    @objc private func dropLexCheckpoints(_ notification: Notification) {
        guard !lexCheckpoints.isEmpty, let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters)
        else { return }
        let edited = storage.editedRange.location
        if let first = lexCheckpoints.firstIndex(where: { $0 >= edited }) {
            lexCheckpoints.removeSubrange(first...)
        }
    }

    /// Lets tests run the rewriter without the vocabulary module's keyword list.
    static var keywordCaseVocabularyForTesting: Set<String>?

    private static var rewriteKeywords: Set<String> {
        keywordCaseVocabularyForTesting ?? SQLCompletionVocabulary.masterKeywords
    }

    private static func isWordCharacter(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
    }

    // MARK: Scripted checks

    /// Types `text` at the caret as keystrokes would, so suggestions open and re-filter as they do for a user.
    func typeForTesting(_ text: String) {
        for character in text {
            if character == "\n" {
                sendKeyForTesting("return")
            } else {
                insertText(String(character), replacementRange: selectedRange())
            }
        }
    }

    private static let testKeys: [String: (code: Int, characters: String, modifiers: NSEvent.ModifierFlags)] = [
        "down": (kVK_DownArrow, "\u{F701}", [.function, .numericPad]),
        "up": (kVK_UpArrow, "\u{F700}", [.function, .numericPad]),
        "left": (kVK_LeftArrow, "\u{F702}", [.function, .numericPad]),
        "right": (kVK_RightArrow, "\u{F703}", [.function, .numericPad]),
        "return": (kVK_Return, "\r", []),
        "tab": (kVK_Tab, "\t", []),
        "escape": (kVK_Escape, "\u{1B}", []),
        "space": (kVK_Space, " ", []),
        "backspace": (kVK_Delete, "\u{7F}", []),
        "ctrl-space": (kVK_Space, " ", [.control]),
    ]

    /// Sends a named key through keyDown, the path the keyboard takes. False for an unknown name.
    @discardableResult
    func sendKeyForTesting(_ name: String) -> Bool {
        guard let key = Self.testKeys[name.lowercased()], let window,
              let event = NSEvent.keyEvent(
                  with: .keyDown, location: .zero, modifierFlags: key.modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber, context: nil, characters: key.characters,
                  charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: UInt16(key.code)
              )
        else { return false }
        keyDown(with: event)
        return true
    }
}

extension SQLTextView: CompletionPopupOwner {
    func completionPopup(didAccept item: CompletionItem) {
        acceptCompletion(item)
    }

    func completionPopupDidClose() {
        completionRequest?.cancel()
        completionRequest = nil
        completionSession = nil
    }
}

/// Line numbers drawn beside the editor.
final class LineNumberRulerView: NSRulerView {
    var font = Theme.monospaced(11)
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
    }

    func observeScrolling(of clipView: NSClipView) {
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: clipView)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func refresh() {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        Theme.editorBackground.setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.editorLineNumber]
        let labels = visibleLineLabels()
        let digits = max(2, String((labels.first?.number ?? 1) + 200).count)
        let width = CGFloat(digits) * 8 + 14
        if abs(ruleThickness - width) > 1 { ruleThickness = width }
        for label in labels {
            let text = "\(label.number)" as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: label.midY - size.height / 2), withAttributes: attributes)
        }
    }

    struct LineLabel {
        var number: Int
        /// The vertical middle of the line's first fragment, in ruler coordinates.
        var midY: CGFloat
    }

    /// The line numbers in view and where they go. Only the vertical extent counts, so a horizontally scrolled
    /// editor without wrapping still numbers every visible line, short ones included.
    func visibleLineLabels() -> [LineLabel] {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return [] }
        let text = textView.string as NSString
        var visible = textView.visibleRect
        visible.origin.x = 0
        visible.size.width = textView.bounds.width
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        var lineNumber = 1
        if charRange.location > 0 {
            let prefix = text.substring(to: charRange.location)
            lineNumber = prefix.reduce(into: 1) { count, char in if char == "\n" { count += 1 } }
        }
        let origin = convert(NSPoint.zero, from: textView).y + textView.textContainerInset.height
        var labels: [LineLabel] = []
        var index = charRange.location
        let end = NSMaxRange(charRange)
        repeat {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: min(index, max(0, text.length - 1)))
            var fragment = text.length == 0 ? layoutManager.extraLineFragmentRect : layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if text.length == 0 { fragment.size.height = max(fragment.height, font.boundingRectForFont.height) }
            labels.append(LineLabel(number: lineNumber, midY: origin + fragment.midY))
            lineNumber += 1
            index = NSMaxRange(lineRange)
        } while index < end
        if text.length > 0, text.character(at: text.length - 1) == 10, end >= text.length {
            let fragment = layoutManager.extraLineFragmentRect
            labels.append(LineLabel(number: lineNumber, midY: origin + fragment.midY))
        }
        return labels
    }
}

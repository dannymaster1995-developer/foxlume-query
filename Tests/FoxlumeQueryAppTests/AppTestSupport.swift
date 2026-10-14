import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

/// Every app-level suite nests in this one: they share the completion panel, so they run one at a time.
@Suite("App completion", .serialized)
@MainActor
struct AppCompletionTests {}

/// Answers by prefix from a fixed word list and records what the editor asked.
@MainActor
final class StubCompletionEngine: CompletionEngine {
    var triggerCharacters: Set<Character> = [".", " "]
    var words: [CompletionItem]
    /// Where the token at the caret starts; letters, digits and `_` unless a test says otherwise.
    var tokenStart: (NSString, Int) -> Int = { text, caret in
        var start = caret
        while start > 0, let scalar = UnicodeScalar(text.character(at: start - 1)),
              CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
            start -= 1
        }
        return start
    }
    private(set) var requests: [(text: String, caret: Int, manual: Bool)] = []
    private(set) var refilters: [String] = []

    init(words: [String] = []) {
        self.words = words.map { CompletionItem(label: $0, kind: .column) }
    }

    func complete(text: String, caret: Int, manual: Bool, keywordCase: KeywordCase) async -> CompletionResult? {
        requests.append((text, caret, manual))
        let ns = text as NSString
        let start = tokenStart(ns, caret)
        let token = ns.substring(with: NSRange(location: start, length: caret - start))
        guard manual || !token.isEmpty else { return nil }
        let pool = words.filter { Self.matches($0, token) }
        guard !pool.isEmpty else { return nil }
        return CompletionResult(items: pool, pool: pool, replacementRange: NSRange(location: start, length: caret - start),
                                token: token, prefix: Self.unquoted(token), limit: 50)
    }

    func refilter(_ result: CompletionResult, token: String, keywordCase: KeywordCase) -> [CompletionItem] {
        refilters.append(token)
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else { return [] }
        return result.pool.filter { Self.matches($0, token) }
    }

    private static func unquoted(_ token: String) -> String {
        String(token.drop { $0 == "\"" || $0 == "'" || $0 == "`" })
    }

    private static func matches(_ item: CompletionItem, _ token: String) -> Bool {
        item.label.lowercased().hasPrefix(unquoted(token).lowercased())
    }
}

@MainActor
final class StubCompletionProvider: SQLCompletionProvider {
    var completionEngine: CompletionEngine?
    var completionKeywordCase: KeywordCase = .matchTypedElseUpper
    var completesWhileTyping = true
}

/// An editor in its own window, as a query tab hosts it.
@MainActor
final class EditorHarness {
    let window: NSWindow
    let editor: SQLEditorView
    let provider = StubCompletionProvider()
    let engine: StubCompletionEngine

    init(language: QueryLanguage = .sql(.postgresql), engine: StubCompletionEngine? = nil) {
        _ = NSApplication.shared
        SQLTextView.assumesKeyWindow = true
        let engine = engine ?? StubCompletionEngine()
        self.engine = engine
        window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 800, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        editor = SQLEditorView(frame: window.contentView!.bounds)
        editor.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(editor)
        editor.language = language
        provider.completionEngine = engine
        editor.completionProvider = provider
        window.orderFront(nil)
        window.makeFirstResponder(editor.textView)
    }

    var text: SQLTextView { editor.textView }
    var string: String { editor.textView.string }
    var showing: Bool { editor.textView.isShowingCompletions }
    var labels: [String] { editor.textView.visibleCompletionLabels }

    func type(_ characters: String) { editor.textView.typeForTesting(characters) }

    func moveCaret(to location: Int) {
        editor.textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    func close() {
        editor.textView.hideCompletions()
        window.orderOut(nil)
        window.close()
    }
}

/// A filter bar whose Raw SQL box completes from a word list; `users.` answers with that table's columns.
@MainActor
final class FilterHarness {
    let window: NSWindow
    let bar = FilterBarView(frame: NSRect(x: 0, y: 0, width: 700, height: 80))
    var words = ["created_at", "credit", "users"]
    var columns = ["id", "name"]
    private(set) var applied: [String] = []
    private(set) var requests = 0

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 300, y: 400, width: 700, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        bar.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(bar)
        bar.configure(columns: ["id", "name"], rules: [], rawWhere: "", capabilities: .relational(.postgresql))
        bar.onApply = { [weak self] _, raw, _ in self?.applied.append(raw) }
        bar.rawCompletion = FilterBarView.RawCompletion(
            complete: { [weak self] fragment, caret in self?.answer(fragment, caret) },
            refilter: { result, token in
                result.pool.filter { $0.label.hasPrefix(token.lowercased()) }
            }
        )
        window.orderFront(nil)
        window.displayIfNeeded()
    }

    private func answer(_ fragment: String, _ caret: Int) -> CompletionResult? {
        requests += 1
        let text = fragment as NSString
        var start = caret
        while start > 0, let scalar = UnicodeScalar(text.character(at: start - 1)),
              CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
            start -= 1
        }
        let token = text.substring(with: NSRange(location: start, length: caret - start))
        let afterDot = start > 0 && text.character(at: start - 1) == 46
        let names = afterDot ? columns : (token.isEmpty ? [] : words)
        let pool = names.filter { $0.hasPrefix(token.lowercased()) }.map { CompletionItem(label: $0, kind: .column) }
        guard !pool.isEmpty else { return nil }
        return CompletionResult(items: pool, pool: pool, replacementRange: NSRange(location: start, length: caret - start),
                                token: token, prefix: token, limit: 20)
    }

    var fieldEditor: NSTextView? { window.firstResponder as? NSTextView }
    var text: String { bar.rawTextForTesting }
    var labels: [String] { bar.rawSuggestionLabels }
    var selected: String? { bar.rawSelectedSuggestion }

    func type(_ characters: String) { bar.typeRawForTesting(characters) }
    func key(_ name: String) { bar.sendRawKeyForTesting(name) }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}

/// Lets the debounce (50 ms) and the async answer run.
@MainActor
func settle(_ milliseconds: UInt64 = 150) async {
    try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
}

/// Waits until `condition` holds, up to `seconds`, for answers that can arrive late on a busy machine.
@MainActor
func settle(until condition: () -> Bool, seconds: Double = 3) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

enum LiveServer {
    static func isOpen(_ port: Int) -> Bool {
        let transport = SocketTransport()
        defer { transport.close() }
        return (try? transport.connect(host: "127.0.0.1", port: port, timeout: 1)) != nil
    }

    static let postgres = isOpen(55432)
    static let mysql = isOpen(53306)
}

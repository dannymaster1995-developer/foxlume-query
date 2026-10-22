import AppKit
import Testing
@testable import FoxlumeQuery
@testable import FoxlumeQueryCore

/// Secrets kept in memory, for tests that must not touch the Keychain.
final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    var accounts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return secrets.keys.sorted()
    }

    func secret(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account]
    }

    func setSecret(_ secret: String, account: String) throws {
        lock.lock()
        secrets[account] = secret
        lock.unlock()
    }

    func deleteSecret(account: String) {
        lock.lock()
        secrets[account] = nil
        lock.unlock()
    }
}

/// Answers with canned suggestions after an optional delay and records what it was asked, cancellations included.
final class StubInlineSource: InlineSuggestionSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _answers: [Result<String?, Error>]
    private var _requests: [InlineSuggestionRequest] = []
    private var _cancelled = 0
    private var _accepted: [(String, Bool)] = []
    private var _dismissed: [String] = []
    let delay: UInt64

    init(_ answers: [Result<String?, Error>], delayMilliseconds: UInt64 = 0) {
        _answers = answers
        delay = delayMilliseconds * 1_000_000
    }

    convenience init(_ texts: String?..., delayMilliseconds: UInt64 = 0) {
        self.init(texts.map { .success($0) }, delayMilliseconds: delayMilliseconds)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var requests: [InlineSuggestionRequest] { locked { _requests } }
    var cancelled: Int { locked { _cancelled } }
    var accepted: [(String, Bool)] { locked { _accepted } }
    var dismissed: [String] { locked { _dismissed } }

    func suggestion(for request: InlineSuggestionRequest) async throws -> InlineSuggestion? {
        let answer: Result<String?, Error> = locked {
            _requests.append(request)
            return _answers.isEmpty ? .success(nil) : _answers.removeFirst()
        }
        if delay > 0 {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                locked { _cancelled += 1 }
                throw error
            }
        }
        guard let text = try answer.get() else { return nil }
        return InlineSuggestion(text: text, location: request.caret)
    }

    func didAccept(_ suggestion: InlineSuggestion, partially: Bool) { locked { _accepted.append((suggestion.text, partially)) } }
    func didDismiss(_ suggestion: InlineSuggestion) { locked { _dismissed.append(suggestion.text) } }
}

@MainActor
final class StubInlineHost: InlineSuggestionHost {
    var source: InlineSuggestionSource?
    var inlineSuggestionDebounce: TimeInterval = 0.05
    private(set) var statuses: [InlineSuggestionStatus] = []

    init(source: InlineSuggestionSource?) {
        self.source = source
    }

    var inlineSuggestionSource: InlineSuggestionSource? { source }

    func inlineSuggestionRequest(text: String, caret: Int, manual: Bool) -> InlineSuggestionRequest {
        InlineSuggestionRequest(text: text, caret: caret, dialect: "PostgreSQL", schema: nil, manual: manual)
    }

    func inlineSuggestionStatusDidChange(_ status: InlineSuggestionStatus) {
        statuses.append(status)
    }
}

/// A host whose source comes from Settings › AI and a connection's policy, as a query tab's does.
@MainActor
final class SettingsInlineHost: InlineSuggestionHost {
    let cache: InlineSuggestionSourceCache
    var connection: ConnectionConfig
    var language: QueryLanguage = .sql(.postgresql)
    var inlineSuggestionDebounce: TimeInterval = 0.05

    init(cache: InlineSuggestionSourceCache, connection: ConnectionConfig) {
        self.cache = cache
        self.connection = connection
    }

    var inlineSuggestionSource: InlineSuggestionSource? { cache.source(for: connection, language: language) }

    func inlineSuggestionRequest(text: String, caret: Int, manual: Bool) -> InlineSuggestionRequest {
        InlineSuggestionRequest(text: text, caret: caret, dialect: "PostgreSQL", schema: [AISchemaTable(name: "orders")], manual: manual)
    }

    func inlineSuggestionStatusDidChange(_ status: InlineSuggestionStatus) {}
}

/// A host behind an `InlineSuggestionGate`, as a query tab's: the connection's policy decides, Ask shows a prompt.
@MainActor
final class ConsentHost: InlineSuggestionHost {
    final class Box {
        var config: ConnectionConfig
        init(_ config: ConnectionConfig) { self.config = config }
    }

    let box: Box
    let gate: InlineSuggestionGate
    var inlineSuggestionDebounce: TimeInterval = 0.05
    private(set) var promptsShown = 0

    init(cache: InlineSuggestionSourceCache, connection: ConnectionConfig, consent: AISessionConsent? = nil) {
        let consent = consent ?? AISessionConsent()
        let box = Box(connection)
        self.box = box
        gate = InlineSuggestionGate(cache: cache, consent: consent, language: .sql(.postgresql), connection: { box.config },
                                    savePolicy: { box.config.aiPolicyLevel = $0 })
        gate.onPromptChange = { [weak self] showing in if showing { self?.promptsShown += 1 } }
    }

    /// Wires Allow to the editor, as the query tab does.
    func attach(to textView: SQLTextView) {
        gate.onAllowed = { [weak textView] manual in
            if manual { textView?.inlineSuggestions.requestNow() } else { textView?.inlineSuggestions.scheduleAfterEdit() }
        }
    }

    var inlineSuggestionSource: InlineSuggestionSource? { gate.source }
    var inlineSuggestionAwaitsConsent: Bool { gate.awaitsConsent }
    func inlineSuggestionRequestConsent(manual: Bool) { gate.requestConsent(manual: manual) }

    func inlineSuggestionRequest(text: String, caret: Int, manual: Bool) -> InlineSuggestionRequest {
        InlineSuggestionRequest(text: text, caret: caret, dialect: "PostgreSQL", schema: nil, manual: manual)
    }

    func inlineSuggestionStatusDidChange(_ status: InlineSuggestionStatus) {}
}

extension EditorHarness {
    var ghost: String? { text.inlineSuggestions.ghost?.text }
    var manager: InlineSuggestionManager { text.inlineSuggestions }
}

extension AppCompletionTests {
    @Suite("Inline suggestions")
    @MainActor
    struct InlineSuggestionTests {
        /// The editor holds its host weakly: keep the host alive for the whole test.
        private func harness(_ source: InlineSuggestionSource?, words: [String] = []) -> (EditorHarness, StubInlineHost) {
            let h = EditorHarness(engine: StubCompletionEngine(words: words))
            let host = StubInlineHost(source: source)
            h.editor.inlineSuggestionHost = host
            return (h, host)
        }

        @Test func ghostAppearsAfterAPauseAndTabAcceptsIt() async {
            let source = StubInlineSource("ers")
            let (h, host) = harness(source)
            defer { h.close(); withExtendedLifetime(host) {} }
            h.type("SELECT * FROM ord")
            #expect(h.ghost == nil, "asked before the pause")
            await settle(until: { h.ghost != nil })
            #expect(h.ghost == "ers")
            #expect(h.string == "SELECT * FROM ord", "the ghost is not part of the text")
            #expect(source.requests.count == 1)
            #expect(source.requests.first?.caret == 17)
            #expect(host.statuses.contains(.requesting))
            #expect(h.manager.status == .idle)

            h.text.sendKeyForTesting("tab")
            #expect(h.string == "SELECT * FROM orders")
            #expect(h.ghost == nil)
            #expect(h.text.selectedRange() == NSRange(location: 20, length: 0))
            #expect(source.accepted.map(\.0) == ["ers"])
            #expect(h.text.undoManager?.undoActionName == "Accept Suggestion")
        }

        @Test func acceptIsOneUndoStep() async {
            let source = StubInlineSource("FROM orders\nWHERE id = 1")
            let (h, host) = harness(source)
            defer { h.close(); withExtendedLifetime(host) {} }
            h.editor.string = "SELECT * "
            h.moveCaret(to: 9)
            h.text.suggestInline(nil)
            await settle(until: { h.ghost != nil })
            h.text.acceptInlineSuggestion(wordOnly: false)
            #expect(h.string == "SELECT * FROM orders\nWHERE id = 1")
            h.text.undoManager?.undo()
            #expect(h.string == "SELECT * ")
        }

        @Test func typingTheSuggestionKeepsTheRest() async {
            let source = StubInlineSource(" FROM orders", "other")
            let (h, host) = harness(source)
            defer { h.close(); withExtendedLifetime(host) {} }
            h.type("SELECT *")
            await settle(until: { h.ghost != nil })
            h.type(" FR")
            #expect(h.ghost == "OM orders")
            #expect(h.manager.ghost?.location == 11)
            #expect(source.requests.count == 1, "matching keystrokes asked again")
            // A character the suggestion does not continue with dismisses it and asks again after the pause.
            h.type("x")
            #expect(h.ghost == nil)
            #expect(source.dismissed == [" FROM orders"])
            await settle(until: { source.requests.count == 2 })
            #expect(source.requests.count == 2)
        }

        @Test func escapeDismissesAndOptionRightTakesAWord() async {
            let source = StubInlineSource("FROM orders o", "x")
            let (h, host) = harness(source)
            defer { h.close(); withExtendedLifetime(host) {} }
            h.type("SELECT * ")
            await settle(until: { h.ghost != nil })
            h.text.sendKeyForTesting("option-right")
            #expect(h.string == "SELECT * FROM")
            #expect(h.ghost == " orders o")
            h.text.sendKeyForTesting("option-right")
            #expect(h.string == "SELECT * FROM orders")
            #expect(h.ghost == " o")
            h.text.sendKeyForTesting("escape")
            #expect(h.ghost == nil)
            #expect(!h.showing, "Escape with a ghost only dismisses it")
            #expect(h.string == "SELECT * FROM orders")
        }

        @Test func tabKeepsItsMeaningWhileTheListIsOpen() async {
            let source = StubInlineSource("ers")
            let (h, host) = harness(source, words: ["orders", "order_items"])
            defer { h.close(); withExtendedLifetime(host) {} }
            // Longer than the list's own pause, so the list is open when the suggestion would be asked for.
            host.inlineSuggestionDebounce = 0.3
            // The list opens on "ord": no suggestion is asked for while it shows.
            h.type("SELECT * FROM ord")
            await settle(until: { h.showing })
            await settle(450)
            #expect(h.showing)
            #expect(source.requests.isEmpty, "asked while the completion list was open")
            h.text.sendKeyForTesting("tab")
            #expect(h.string == "SELECT * FROM orders", "Tab accepted the list's item")

            // With a ghost on screen, opening the list hides the ghost, and Tab goes to the list.
            h.editor.string = "SELECT * FROM "
            h.moveCaret(to: 14)
            h.text.suggestInline(nil)
            await settle(until: { h.ghost != nil })
            #expect(h.ghost == "ers")
            h.type("o")
            await settle(until: { h.showing })
            #expect(h.ghost == nil)
            h.text.sendKeyForTesting("tab")
            #expect(h.string.hasPrefix("SELECT * FROM order"))
            // Without either, Tab indents.
            h.editor.string = ""
            h.text.sendKeyForTesting("tab")
            #expect(h.string == "    ")
        }

        /// Escape closes the list; the usual pause follows and then the suggestion, without the Suggest command.
        @Test func closingTheListWithEscapeBringsASuggestion() async {
            let source = StubInlineSource("ers")
            let (h, host) = harness(source, words: ["orders", "order_items"])
            defer { h.close(); withExtendedLifetime(host) {} }
            host.inlineSuggestionDebounce = 0.3
            h.type("SELECT * FROM ord")
            await settle(until: { h.showing })
            await settle(450)
            #expect(h.showing)
            #expect(source.requests.isEmpty, "asked while the list was open")
            #expect(h.ghost == nil)
            h.text.sendKeyForTesting("escape")
            #expect(!h.showing)
            #expect(h.ghost == nil, "asked without the pause")
            await settle(until: { h.ghost != nil })
            #expect(h.ghost == "ers")
            #expect(source.requests.count == 1)
            #expect(h.string == "SELECT * FROM ord")
        }

        /// Accepting a list item closes the list; a suggestion for what follows the item comes after the pause.
        @Test func acceptingAListItemBringsASuggestion() async {
            let source = StubInlineSource(" o WHERE o.id = 1")
            let (h, host) = harness(source, words: ["orders", "order_items"])
            defer { h.close(); withExtendedLifetime(host) {} }
            host.inlineSuggestionDebounce = 0.3
            h.type("SELECT * FROM ord")
            await settle(until: { h.showing })
            h.text.sendKeyForTesting("tab")
            #expect(h.string == "SELECT * FROM orders")
            #expect(!h.showing)
            await settle(until: { h.ghost != nil })
            #expect(h.ghost == " o WHERE o.id = 1")
            #expect(source.requests.count == 1)
            #expect(source.requests.first?.caret == 20)
            // Tab now takes the suggestion, as one more undo step.
            h.text.sendKeyForTesting("tab")
            #expect(h.string == "SELECT * FROM orders o WHERE o.id = 1")
        }

        /// A suggestion answered while the list is open is dropped; the list owns the screen and Tab.
        @Test func noSuggestionWhileTheListIsOpen() async {
            let source = StubInlineSource("late", delayMilliseconds: 300)
            let (h, host) = harness(source, words: ["orders"])
            defer { h.close(); withExtendedLifetime(host) {} }
            h.editor.string = "SELECT * FROM "
            h.moveCaret(to: 14)
            h.text.suggestInline(nil)
            await settle(until: { source.requests.count == 1 })
            // The list opens before the answer arrives.
            h.text.requestManualCompletion()
            await settle(until: { h.showing })
            await settle(450)
            #expect(h.showing)
            #expect(h.ghost == nil, "a suggestion showed over the list")
        }

        /// Escape on a suggestion only dismisses it; nothing is asked again until the user types.
        @Test func escapeOnASuggestionDoesNotAskAgain() async {
            let source = StubInlineSource("FROM orders", "WHERE")
            let (h, host) = harness(source)
            defer { h.close(); withExtendedLifetime(host) {} }
            h.type("SELECT * ")
            await settle(until: { h.ghost != nil })
            h.text.sendKeyForTesting("escape")
            #expect(h.ghost == nil)
            #expect(!h.showing, "Escape on a suggestion opened the list")
            await settle(300)
            #expect(source.requests.count == 1, "Escape asked again")
            #expect(h.ghost == nil)
            #expect(!h.manager.isWaiting)
        }

        @Test func typingCancelsTheRequestInFlight() async {
            let source = StubInlineSource("stale", "fresh", delayMilliseconds: 400)
            let (h, host) = harness(source)
            defer { h.close(); withExtendedLifetime(host) {} }
            h.type("SELECT a")
            await settle(until: { source.requests.count == 1 })
            #expect(h.manager.status == .requesting)
            h.type(" ")
            await settle(until: { source.cancelled == 1 })
            #expect(source.cancelled == 1, "the request in flight was not cancelled")
            await settle(until: { h.ghost != nil })
            #expect(h.ghost == "fresh")
            #expect(source.requests.count == 2)
        }

        @Test func caretMovesCancelAndDismiss() async {
            let source = StubInlineSource("x", "y", delayMilliseconds: 300)
            let (h, host) = harness(source)
            defer { h.close(); withExtendedLifetime(host) {} }
            h.type("SELECT a")
            await settle(until: { source.requests.count == 1 })
            h.moveCaret(to: 2)
            await settle(until: { source.cancelled == 1 })
            #expect(source.cancelled == 1)
            await settle(400)
            #expect(h.ghost == nil)

            h.moveCaret(to: 8)
            h.text.suggestInline(nil)
            await settle(until: { h.ghost != nil })
            #expect(h.ghost == "y")
            h.moveCaret(to: 3)
            #expect(h.ghost == nil)
            #expect(source.dismissed == ["y"])
        }

        @Test func onlyAtSensibleSpots() async {
            let source = StubInlineSource("a", "b", "c")
            let (h, host) = harness(source)
            defer { h.close(); withExtendedLifetime(host) {} }
            h.editor.string = "SELECT idx FROM t"
            h.moveCaret(to: 9)
            // Typing in the middle of a word asks nothing.
            h.type("y")
            await settle(200)
            #expect(source.requests.isEmpty)
            // Before a closing bracket it does.
            h.editor.string = "SELECT count()"
            h.moveCaret(to: 13)
            h.type("*")
            await settle(until: { !source.requests.isEmpty })
            #expect(source.requests.count == 1)
            // The Suggest command asks anywhere.
            h.moveCaret(to: 3)
            h.text.suggestInline(nil)
            await settle(until: { source.requests.count == 2 })
            #expect(source.requests.last?.manual == true)
            // A selection blocks it.
            h.text.setSelectedRange(NSRange(location: 0, length: 6))
            h.text.suggestInline(nil)
            await settle(150)
            #expect(source.requests.count == 2)
        }

        @Test func noSourceSendsNothing() async {
            let (h, host) = harness(nil)
            defer { h.close(); withExtendedLifetime(host) {} }
            h.type("SELECT * FROM ")
            await settle(200)
            #expect(h.manager.requestCount == 0)
            #expect(!h.text.validateUserInterfaceItem(NSMenuItem(title: "Suggest", action: #selector(SQLTextView.suggestInline(_:)), keyEquivalent: "")))
        }

        @Test func failuresAreReported() async {
            let source = StubInlineSource([
                .failure(AIProviderError.keyRejected),
                .failure(AIProviderError.unavailable(status: 529)),
                .failure(AIProviderError.rateLimited(retryAfter: 60)),
                .success("never shown"),
            ])
            let (h, host) = harness(source)
            defer { h.close(); withExtendedLifetime(host) {} }
            h.type("SELECT 1")
            await settle(until: { h.manager.status != .idle && h.manager.status != .requesting })
            #expect(h.manager.status == .failed("API key rejected"))
            h.type(" ")
            await settle(until: { source.requests.count == 2 })
            await settle(100)
            #expect(h.manager.status == .idle, "a 529 is retried silently on the next keystroke")
            h.type("x ")
            await settle(until: { source.requests.count == 3 })
            await settle(100)
            #expect(h.manager.status == .failed("Rate limited: suggestions paused for 60 s"))
            #expect(h.manager.pausedUntil != nil)
            h.type("y ")
            await settle(200)
            #expect(source.requests.count == 3, "asked again during the pause")
            #expect(host.statuses.contains(.failed("API key rejected")))
        }

        @Test func ghostIsDrawnAfterTheCaretAndBelow() async {
            let source = StubInlineSource("id,\n  name")
            let (h, host) = harness(source)
            defer { h.close(); withExtendedLifetime(host) {} }
            h.type("SELECT ")
            await settle(until: { h.ghost != nil })
            let lines = h.text.ghostLineRects()
            #expect(lines.map(\.text) == ["id,", "  name"])
            guard lines.count == 2 else { return }
            let caret = h.text.caretOrigin(at: 7)
            #expect(lines[0].rect.minX == caret?.point.x)
            #expect(lines[1].rect.minY > lines[0].rect.minY)
            #expect(lines[1].rect.minX < lines[0].rect.minX)
            h.text.display()
            // Copying everything copies the text only.
            h.text.selectAll(nil)
            #expect(h.text.selectedRange().length == 7)
            #expect(h.ghost == nil, "a selection dismissed the ghost")
        }

        @Test func ghostColorFollowsTheTheme() {
            func luminance(_ color: NSColor) -> CGFloat {
                let c = color.usingColorSpace(.sRGB)!
                return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            }
            for (foreground, background) in [(NSColor.black, NSColor.white), (NSColor.white, NSColor(white: 0.12, alpha: 1)),
                                             (NSColor(srgbRed: 0.97, green: 0.97, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.16, green: 0.16, blue: 0.21, alpha: 1))] {
                let ghost = SQLTextView.ghostTextColor(foreground: foreground, background: background)
                let (f, g, b) = (luminance(foreground), luminance(ghost), luminance(background))
                #expect(min(f, b) < g && g < max(f, b), "the ghost sits between text and background")
                #expect(abs(g - b) > 0.2, "the ghost stands out from the background")
            }
        }

        @Test func policyNeverSendsNothing() async throws {
            let host = "ai-policy-app.test"
            defer { AIStubURLProtocol.reset(host: host) }
            let session = AIStubURLProtocol.session(host: host) { _ in
                AIStubURLProtocol.json(["choices": [["message": ["role": "assistant", "content": "FROM orders"], "finish_reason": "stop"]]])
            }
            var settings = AISettings()
            settings.enabled = true
            settings.upsert(AIProviderConfig(name: "Stub", kind: .openAICompatible, baseURL: "http://\(host)/v1", model: "stub-model"))
            // No key is read or written: OpenAI-compatible providers may go without one.
            let keys = AIKeyStore(store: FileCredentialStore(url: URL(fileURLWithPath: "/dev/null")))
            let cache = InlineSuggestionSourceCache(keys: keys, session: session, settings: { settings })
            let production = SettingsInlineHost(cache: cache, connection: ConnectionConfig(kind: .postgresql, environment: .production))
            let h = EditorHarness(engine: StubCompletionEngine())
            defer { h.close() }
            h.editor.inlineSuggestionHost = production
            h.type("SELECT * ")
            await settle(250)
            h.text.suggestInline(nil)
            await settle(150)
            #expect(h.manager.requestCount == 0)
            #expect(AIStubURLProtocol.requests(host: host).isEmpty, "a Never connection sent a request")

            // The same editor of an Allow connection asks the provider and shows its answer.
            production.connection.environment = .development
            production.connection.aiPolicyLevel = .allow
            h.type("\u{20}")
            await settle(until: { h.ghost != nil })
            #expect(h.ghost == "FROM orders")
            let sent = try #require(AIStubURLProtocol.requests(host: host).first)
            #expect(sent.url.absoluteString == "http://\(host)/v1/chat/completions")
            let body = try #require(sent.json)
            #expect((body["messages"] as? [[String: String]])?.last?["content"] == "SELECT *  <CURSOR>")

            // MongoDB and Redis editors get no source.
            #expect(cache.source(for: production.connection, language: .mongo) == nil)
            #expect(cache.source(for: production.connection, language: .redis) == nil)
        }

        /// A cache whose source answers from the stub server at `host`.
        private func stubCache(host: String, answer: String) -> InlineSuggestionSourceCache {
            let session = AIStubURLProtocol.session(host: host) { _ in
                AIStubURLProtocol.json(["choices": [["message": ["role": "assistant", "content": answer], "finish_reason": "stop"]]])
            }
            var settings = AISettings()
            settings.enabled = true
            settings.upsert(AIProviderConfig(name: "Stub", kind: .openAICompatible, baseURL: "http://\(host)/v1", model: "stub-model"))
            let keys = AIKeyStore(store: FileCredentialStore(url: URL(fileURLWithPath: "/dev/null")))
            return InlineSuggestionSourceCache(keys: keys, session: session, settings: { settings })
        }

        private func consentEditor(_ host: ConsentHost) -> EditorHarness {
            let h = EditorHarness(engine: StubCompletionEngine())
            h.editor.inlineSuggestionHost = host
            host.attach(to: h.text)
            return h
        }

        @Test func askShowsThePromptAndSendsNothing() async {
            let server = "ai-ask-prompt.test"
            defer { AIStubURLProtocol.reset(host: server) }
            let host = ConsentHost(cache: stubCache(host: server, answer: "FROM orders"), connection: ConnectionConfig(kind: .postgresql, environment: .development))
            #expect(host.box.config.aiPolicyLevel == .ask)
            let h = consentEditor(host)
            defer { h.close() }
            h.type("SELECT * ")
            await settle(until: { host.gate.isPrompting })
            #expect(host.gate.isPrompting)
            #expect(h.window.firstResponder === h.text, "the prompt took the keyboard")
            // Typing goes on; the prompt stays, shown once, and nothing is sent.
            h.type("x ")
            await settle(250)
            #expect(h.string == "SELECT * x ")
            #expect(host.promptsShown == 1)
            #expect(h.manager.requestCount == 0)
            #expect(h.ghost == nil)
            #expect(AIStubURLProtocol.requests(host: server).isEmpty, "sent before the answer")
        }

        @Test func allowStoresThePolicyAndThenAsks() async throws {
            let server = "ai-ask-allow.test"
            defer { AIStubURLProtocol.reset(host: server) }
            let host = ConsentHost(cache: stubCache(host: server, answer: "FROM orders"), connection: ConnectionConfig(kind: .postgresql, environment: .local))
            let h = consentEditor(host)
            defer { h.close() }
            h.type("SELECT * ")
            await settle(until: { host.gate.isPrompting })
            try host.gate.answer(.allow)
            #expect(!host.gate.isPrompting)
            #expect(host.box.config.aiPolicy == .allow)
            await settle(until: { h.ghost != nil })
            #expect(h.ghost == "FROM orders")
            #expect(AIStubURLProtocol.requests(host: server).count == 1)
        }

        @Test func suggestCommandAsksThenRequestsAtOnceAfterAllow() async throws {
            let server = "ai-ask-manual.test"
            defer { AIStubURLProtocol.reset(host: server) }
            let host = ConsentHost(cache: stubCache(host: server, answer: "id = 1"), connection: ConnectionConfig(kind: .postgresql, environment: .none))
            host.inlineSuggestionDebounce = 5
            let h = consentEditor(host)
            defer { h.close() }
            h.editor.string = "SELECT * FROM t WHERE "
            h.moveCaret(to: 22)
            #expect(h.text.validateUserInterfaceItem(NSMenuItem(title: "Suggest", action: #selector(SQLTextView.suggestInline(_:)), keyEquivalent: "")))
            h.text.suggestInline(nil)
            await settle(until: { host.gate.isPrompting })
            #expect(AIStubURLProtocol.requests(host: server).isEmpty)
            try host.gate.answer(.allow)
            // No five-second pause: the Suggest command asked, so the answer comes at once.
            await settle(until: { h.ghost != nil })
            #expect(h.ghost == "id = 1")
        }

        @Test func notNowSendsNothingUntilTheWorkspaceIsReopened() async throws {
            let server = "ai-ask-notnow.test"
            defer { AIStubURLProtocol.reset(host: server) }
            let cache = stubCache(host: server, answer: "FROM orders")
            let consent = AISessionConsent()
            let host = ConsentHost(cache: cache, connection: ConnectionConfig(kind: .postgresql, environment: .staging), consent: consent)
            let h = consentEditor(host)
            defer { h.close() }
            h.type("SELECT * ")
            await settle(until: { host.gate.isPrompting })
            try host.gate.answer(.notNow)
            #expect(!host.gate.isPrompting)
            #expect(host.box.config.aiPolicy == nil, "Not Now changes nothing on the connection")
            #expect(consent.declined)
            h.type("x ")
            await settle(250)
            h.text.suggestInline(nil)
            await settle(150)
            #expect(host.promptsShown == 1, "asked again after Not Now")
            #expect(h.manager.requestCount == 0)
            #expect(AIStubURLProtocol.requests(host: server).isEmpty)
            // Another tab of the same workspace shares the answer; a reopened workspace asks again.
            let sibling = ConsentHost(cache: cache, connection: host.box.config, consent: consent)
            #expect(!sibling.gate.awaitsConsent)
            let reopened = ConsentHost(cache: cache, connection: host.box.config, consent: AISessionConsent())
            #expect(reopened.gate.awaitsConsent)
        }

        @Test func neverStoresThePolicy() async throws {
            let server = "ai-ask-never.test"
            defer { AIStubURLProtocol.reset(host: server) }
            let host = ConsentHost(cache: stubCache(host: server, answer: "FROM orders"), connection: ConnectionConfig(kind: .postgresql, environment: .local))
            let h = consentEditor(host)
            defer { h.close() }
            h.type("SELECT * ")
            await settle(until: { host.gate.isPrompting })
            try host.gate.answer(.never)
            #expect(host.box.config.aiPolicy == .never)
            #expect(!host.gate.awaitsConsent)
            h.type("x ")
            await settle(250)
            #expect(host.promptsShown == 1)
            #expect(h.manager.requestCount == 0)
            #expect(AIStubURLProtocol.requests(host: server).isEmpty)
        }

        @Test func promptClosesWhenThePolicyChangesElsewhere() async {
            let server = "ai-ask-refresh.test"
            defer { AIStubURLProtocol.reset(host: server) }
            let host = ConsentHost(cache: stubCache(host: server, answer: "x"), connection: ConnectionConfig(kind: .postgresql, environment: .local))
            let h = consentEditor(host)
            defer { h.close() }
            h.type("SELECT * ")
            await settle(until: { host.gate.isPrompting })
            // Allowed in another tab, or set in the connection form.
            host.box.config.aiPolicyLevel = .allow
            host.gate.refresh()
            #expect(!host.gate.isPrompting)
        }

        /// The app keeps AI keys on their own Keychain service. Writing to the real Keychain from a test run opens a
        /// SecurityAgent prompt and stalls unattended runs, so the round trip goes through an in-memory store with the
        /// same interface.
        @Test func providerSettingsRoundTripThroughTheKeyStore() throws {
            #expect((CredentialStores.makeAIDefault(portable: false) as? KeychainCredentialStore)?.service == "com.foxlume.query.ai")
            #expect(CredentialStores.makeAIDefault(portable: true) is FileCredentialStore)
            #expect(KeychainCredentialStore().service == "com.foxlume.query.connection")
            let store = MemoryCredentialStore()
            let keys = AIKeyStore(store: store)
            let model = AIProviderEditorModel(provider: nil, keys: keys)
            model.changeKind(to: .anthropic)
            model.provider.name = "Claude"
            model.apiKey = "sk-ant-test-\(UUID().uuidString)"
            let id = model.provider.id
            defer { keys.deleteAPIKey(for: id) }
            #expect(model.validationMessage == nil)
            var settings = AISettings()
            try model.save(into: &settings)
            #expect(settings.providers.map(\.name) == ["Claude"])
            #expect(settings.activeProvider?.model == "claude-opus-5-5")
            #expect(settings.activeProvider?.baseURL == "https://api.anthropic.com/v1")
            #expect(keys.apiKey(for: id) == model.apiKey)
            #expect(store.accounts == ["ai." + id.uuidString])

            let reopened = AIProviderEditorModel(provider: settings.providers[0], keys: keys)
            #expect(reopened.apiKey == model.apiKey)
            reopened.apiKey = ""
            #expect(reopened.validationMessage == "Enter the API key.")
            reopened.changeKind(to: .openAICompatible)
            #expect(reopened.provider.baseURL == "https://api.openai.com/v1")
            reopened.provider.model = "gpt-4o-mini"
            try reopened.save(into: &settings)
            #expect(keys.apiKey(for: id) == nil, "an empty key removes the stored one")
            #expect(settings.providers.count == 1)

            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode({ var s = AppSettings(); s.ai = settings; return s }()))
            #expect(decoded.ai == settings)
        }

        @Test func presetsFillTheBaseURL() throws {
            let model = AIProviderEditorModel(provider: nil, keys: AIKeyStore(store: FileCredentialStore(url: URL(fileURLWithPath: "/dev/null"))))
            let ollama = try #require(AIProviderPreset.all.first { $0.name == "Ollama" })
            model.apply(ollama)
            #expect(model.provider.baseURL == "http://localhost:11434/v1")
            #expect(model.provider.name == "Ollama")
            model.provider.model = "llama3.1"
            #expect(model.validationMessage == nil, "local servers need no key")
        }
    }
}

import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

extension AppCompletionTests {
    @Suite("Editor completion session")
    @MainActor
    struct EditorSessionTests {
        /// The Redis engine's token starts at the argument's opening quote; typing inside it re-ranks locally.
        @Test func quotedRedisKeyRefiltersWithoutAskingAgain() async {
            let engine = StubCompletionEngine(words: ["user:1", "user:2", "user name", "session:9"])
            engine.triggerCharacters = [" "]
            engine.tokenStart = { text, caret in
                var start = caret
                while start > 0, text.character(at: start - 1) != 32 { start -= 1 }
                return start
            }
            let h = EditorHarness(language: .redis, engine: engine)
            defer { h.close() }
            h.type("GET \"u")
            await settle(until: { !h.labels.isEmpty })
            #expect(h.labels == ["user:1", "user:2", "user name"])
            let requests = engine.requests.count

            h.type("s")
            #expect(h.showing)
            #expect(engine.refilters.last == "\"us")
            await settle()
            #expect(engine.requests.count == requests, "a keystroke inside the quoted key asked the engine again")

            h.type("er:1")
            #expect(h.labels == ["user:1"])
            // The closing quote ends the argument.
            h.type("\"")
            #expect(!h.showing)
        }

        @Test func redisTokenRule() {
            let rule = CompletionTokenRule.redis
            #expect(rule.isToken("user:1"))
            #expect(rule.isToken("\"user na"))
            #expect(rule.isToken("'it\"s"))
            #expect(rule.isToken("\"a\\\"b"), "an escaped quote stays inside a double-quoted argument")
            #expect(!rule.isToken("\"user\""))
            #expect(!rule.isToken("us er"))
            #expect(!rule.isToken("\"a\nb"))
            #expect(!CompletionTokenRule.sql.isToken("a b"))
            #expect(CompletionTokenRule.sql.isToken("\"Na"))
        }

        /// The ruler settling its width right after the editor appears shifts the clip view's x origin; that is no scroll.
        @Test func firstKeystrokeInANewEditorOpensTheList() async {
            let h = EditorHarness(engine: StubCompletionEngine(words: ["users"]))
            defer { h.close() }
            h.type("us")
            await settle()
            #expect(h.labels == ["users"])
        }

        /// Re-tiles move the text without the user scrolling; the list moves with its token.
        @Test func reTilesMoveTheListWithItsToken() async {
            let h = EditorHarness(engine: StubCompletionEngine(words: ["users", "user_id"]))
            defer { h.close() }
            let line = "-- filler line\n"
            h.editor.string = String(repeating: line, count: 10)
            await settle()
            h.moveCaret(to: (line as NSString).length * 5)
            h.type("us")
            await settle()
            #expect(h.labels == ["users", "user_id"])
            let before = h.text.completionFrameForTesting ?? .zero

            h.editor.scrollView.verticalRulerView?.ruleThickness += 20
            h.editor.scrollView.tile()
            #expect(h.showing, "a wider ruler closed the list")
            #expect((h.text.completionFrameForTesting?.minX ?? 0) > before.minX, "the list stayed where the token was")

            h.window.setContentSize(NSSize(width: 700, height: 500))
            await settle()
            #expect(h.showing, "a narrower window closed the list")
        }

        @Test func scrollWheelClosesTheList() async {
            let h = EditorHarness(engine: StubCompletionEngine(words: ["users"]))
            defer { h.close() }
            h.type("us")
            await settle()
            #expect(h.showing)
            let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -20, wheel2: 0, wheel3: 0)
            guard let event = wheel.flatMap(NSEvent.init(cgEvent:)) else {
                Issue.record("no scroll wheel event")
                return
            }
            h.text.scrollWheel(with: event)
            #expect(!h.showing)
        }

        @Test func tokenScrolledOutOfViewClosesTheList() async {
            let h = EditorHarness(engine: StubCompletionEngine(words: ["users"]))
            defer { h.close() }
            let line = "-- filler line\n"
            h.editor.string = String(repeating: line, count: 300)
            await settle()
            h.moveCaret(to: (line as NSString).length * 5)
            h.type("us")
            await settle()
            #expect(h.showing)
            let clip = h.editor.scrollView.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: 2_000))
            h.editor.scrollView.reflectScrolledClipView(clip)
            #expect(!h.showing)
        }
    }

    @Suite("Keyword case rewriter")
    @MainActor
    struct KeywordRewriterTests {
        private static let keywords: Set<String> = ["SELECT", "FROM", "WHERE", "AND"]

        private func harness() -> EditorHarness {
            SQLTextView.keywordCaseVocabularyForTesting = Self.keywords
            let h = EditorHarness()
            h.provider.completionKeywordCase = .upper
            return h
        }

        private func typeAtEnd(_ h: EditorHarness, _ characters: String) {
            h.moveCaret(to: (h.string as NSString).length)
            h.type(characters)
        }

        /// Checkpoints after an edit are dropped, so a comment or string opened above the caret is still seen.
        @Test func editsAboveTheCaretInvalidateCheckpoints() async {
            let h = harness()
            defer {
                h.close()
                SQLTextView.keywordCaseVocabularyForTesting = nil
            }
            h.editor.string = String(repeating: "select a from t where b = 'x';\n", count: 1_000)
            typeAtEnd(h, "select ")
            #expect(h.string.hasSuffix("SELECT "))

            h.moveCaret(to: 0)
            h.type("/*")
            typeAtEnd(h, "from ")
            #expect(h.string.hasSuffix("from "), "rewrote a word inside a block comment opened at the top")

            h.text.insertText("", replacementRange: NSRange(location: 0, length: 2))
            typeAtEnd(h, "where ")
            #expect(h.string.hasSuffix("from WHERE "))

            // One more quote halfway down leaves the end inside a string.
            let middle = (h.string as NSString).length / 2
            h.text.insertText("'", replacementRange: NSRange(location: middle, length: 0))
            typeAtEnd(h, "and ")
            #expect(h.string.hasSuffix("WHERE and "))
        }

        /// Undo, paste and other edits that bypass typing reach the text storage too.
        @Test func storageEditsInvalidateCheckpoints() async {
            let h = harness()
            defer {
                h.close()
                SQLTextView.keywordCaseVocabularyForTesting = nil
            }
            h.editor.string = String(repeating: "select a from t;\n", count: 1_000)
            typeAtEnd(h, "select ")
            #expect(h.string.hasSuffix("SELECT "))
            h.text.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "/*")
            typeAtEnd(h, "from ")
            #expect(h.string.hasSuffix("SELECT from "))
        }

        /// Only the first boundary in a large document lexes from the top; later ones start at a checkpoint.
        @Test func boundaryKeystrokesStayFastInLargeDocuments() {
            let h = harness()
            defer {
                h.close()
                SQLTextView.keywordCaseVocabularyForTesting = nil
            }
            h.editor.string = String(repeating: "select a, b from t where c = 'x' and d = 1;\n", count: 11_000)
            #expect((h.string as NSString).length < 500_000)
            typeAtEnd(h, "select")
            let clock = ContinuousClock()
            let first = clock.measure { h.type(" ") }
            h.type("from")
            let second = clock.measure { h.type(" ") }
            #expect(h.string.hasSuffix("SELECT FROM "))
            #expect(second < .milliseconds(10), "first boundary \(first), second \(second)")
        }

        @Test func matchTypedPoliciesNeverRewrite() {
            let h = harness()
            defer {
                h.close()
                SQLTextView.keywordCaseVocabularyForTesting = nil
            }
            h.provider.completionKeywordCase = .matchTypedElseUpper
            h.type("select ")
            #expect(h.string == "select ")
        }
    }
}

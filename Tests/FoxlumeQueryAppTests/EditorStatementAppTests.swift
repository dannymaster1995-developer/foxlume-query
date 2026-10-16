import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

extension AppCompletionTests {
    /// The band behind the statement at the caret, word wrap, and Run Statement and Move to Next (⌃⌘↩).
    @Suite("Editor statements and wrapping")
    @MainActor
    struct EditorStatementAppTests {
        private func harness(_ text: String, language: QueryLanguage = .sql(.postgresql)) -> EditorHarness {
            let h = EditorHarness(language: language)
            h.editor.highlightsCurrentStatement = true
            h.editor.string = text
            return h
        }

        private func bandText(_ h: EditorHarness) -> String? {
            h.text.statementBandRange.map { (h.string as NSString).substring(with: $0) }
        }

        @Test func bandFollowsTheCaret() {
            let text = "SELECT 1;\n-- second\nSELECT 2\nFROM t;\n\nSELECT 3;"
            let h = harness(text)
            defer { h.close() }
            h.moveCaret(to: 3)
            #expect(bandText(h) == "SELECT 1;")
            h.moveCaret(to: (text as NSString).range(of: "FROM").location)
            #expect(bandText(h) == "-- second\nSELECT 2\nFROM t;")
            let rect = h.text.statementBandRectForTesting ?? .zero
            let lineHeight = h.text.layoutManager!.defaultLineHeight(for: h.text.font!)
            #expect(rect.height >= lineHeight * 3 - 1, "the band covers the statement's three lines")
            #expect(rect.width == h.text.bounds.width, "the band spans the editor's width")

            h.moveCaret(to: (text as NSString).range(of: "\n\n").location + 1)
            #expect(h.text.statementBandRange == nil, "no band on the blank line between statements")
            h.text.setSelectedRange(NSRange(location: 0, length: 5))
            #expect(h.text.statementBandRange == nil, "no band while text is selected")
            h.moveCaret(to: (text as NSString).length)
            #expect(bandText(h) == "SELECT 3;")
            h.window.display()
        }

        @Test func noBandForOneStatementOrWhenTurnedOff() {
            let h = harness("SELECT 1;\n")
            defer { h.close() }
            h.moveCaret(to: 3)
            #expect(h.text.statementBandRange == nil)

            h.editor.string = "SELECT 1; SELECT 2;"
            h.moveCaret(to: 3)
            #expect(bandText(h) == "SELECT 1;")
            h.editor.highlightsCurrentStatement = false
            #expect(h.text.statementBandRange == nil)
            #expect(h.text.statementMap.entries.isEmpty, "a turned-off band does not split the text")
            h.editor.highlightsCurrentStatement = true
            #expect(bandText(h) == "SELECT 1;")
        }

        @Test func mongoAndRedisUseTheirRunRules() {
            let mongo = harness("db.a.find({ x: 1 })\ndb.b.find()", language: .mongo)
            defer { mongo.close() }
            mongo.moveCaret(to: 3)
            #expect(bandText(mongo) == "db.a.find({ x: 1 })")

            let redis = harness("GET a\nSET b 1", language: .redis)
            defer { redis.close() }
            redis.moveCaret(to: 8)
            #expect(bandText(redis) == "SET b 1")
        }

        /// A keystroke shifts the last split; the text is split again only after the pause, so typing stays smooth.
        @Test func typingShiftsTheBandAndSplitsAfterThePause() async {
            let saved = SQLTextView.statementMapDelay
            SQLTextView.statementMapDelay = 0.1
            defer { SQLTextView.statementMapDelay = saved }
            let h = harness("SELECT 1;\nSELECT 2;\nSELECT 3;")
            defer { h.close() }
            h.moveCaret(to: 18)
            h.type("0")
            #expect(bandText(h) == "SELECT 20;", "the band grows with the typed character")
            h.type("; SELECT 4")
            #expect(h.text.statementMap.count == 3, "the text was split again on a keystroke")
            await settle(until: { h.text.statementMap.count == 4 })
            #expect(h.text.statementMap.count == 4)
            #expect(bandText(h) == "SELECT 4;")
        }

        /// 5,000 lines: keystrokes never split the whole text; one split after the pause is quick.
        @Test func largeScriptsStaySmooth() async {
            let saved = SQLTextView.statementMapDelay
            SQLTextView.statementMapDelay = 0.1
            defer { SQLTextView.statementMapDelay = saved }
            let script = (1...5_000).map { "SELECT \($0), 'a;b' FROM t WHERE id = \($0); -- line \($0)" }.joined(separator: "\n")
            let h = harness(script)
            defer { h.close() }
            #expect(h.text.statementMap.count == 5_000)
            let middle = (script as NSString).range(of: "SELECT 2500,").location
            h.moveCaret(to: middle + 7)
            let start = Date()
            h.type("12345 + ")
            let typing = Date().timeIntervalSince(start)
            #expect(typing < 1.0, "8 keystrokes took \(typing) s")
            #expect(bandText(h)?.hasPrefix("SELECT 12345 + 2500,") == true, "the comment trailing line 2499 stays out of the band")

            let splitStart = Date()
            let map = StatementMap(text: h.string, language: .sql(.postgresql))
            #expect(Date().timeIntervalSince(splitStart) < 0.5)
            await settle(until: { h.text.statementMap == map })
            #expect(h.text.statementMap == map)
        }

        @Test func wordWrapOffScrollsSidewaysWithCorrectLineNumbers() async {
            let long = "SELECT " + (1...80).map { "column_\($0)" }.joined(separator: ", ") + " FROM t;"
            let text = ([long] + (1...30).map { "SELECT \($0);" }).joined(separator: "\n")
            let h = EditorHarness()
            defer { h.close() }
            h.editor.string = text
            let layout = h.text.layoutManager!
            func fragments(ofLine characterRange: NSRange) -> Int {
                var count = 0
                let glyphs = layout.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
                layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in count += 1 }
                return count
            }
            let firstLine = NSRange(location: 0, length: (long as NSString).length)
            h.window.layoutIfNeeded()
            #expect(fragments(ofLine: firstLine) > 1, "wrapped by default")
            #expect(!h.editor.scrollView.hasHorizontalScroller)

            h.editor.wrapsLines = false
            h.window.layoutIfNeeded()
            #expect(fragments(ofLine: firstLine) == 1)
            #expect(h.editor.scrollView.hasHorizontalScroller)
            let clipWidth = h.editor.visibleTextWidth
            #expect(h.text.frame.width > clipWidth * 2, "the text view grows to the long line")

            // Scrolled far right, past the end of every short line, the ruler still numbers each visible line.
            let clip = h.editor.scrollView.contentView
            clip.scroll(to: NSPoint(x: h.text.frame.width - clipWidth, y: 0))
            h.editor.scrollView.reflectScrolledClipView(clip)
            let ruler = try? #require(h.editor.scrollView.verticalRulerView as? LineNumberRulerView)
            let labels = ruler?.visibleLineLabels() ?? []
            #expect(labels.first?.number == 1)
            #expect(labels.map(\.number) == Array(1...labels.count), "every line keeps its number")
            #expect(labels.count >= 10)
            let spacing = labels.count > 2 ? labels[2].midY - labels[1].midY : 0
            let lineHeight = layout.defaultLineHeight(for: h.text.font!)
            #expect(abs(abs(spacing) - lineHeight) < 1, "one label per line height")

            // A wider window keeps the text view at least as wide as the visible area.
            h.editor.string = "SELECT 1;"
            h.window.setContentSize(NSSize(width: 1000, height: 500))
            h.window.layoutIfNeeded()
            #expect(h.text.frame.width >= h.editor.visibleTextWidth - 0.5)

            h.editor.string = text
            h.editor.wrapsLines = true
            h.window.layoutIfNeeded()
            #expect(fragments(ofLine: firstLine) > 1)
            #expect(!h.editor.scrollView.hasHorizontalScroller)
            #expect(abs(h.text.frame.width - h.editor.visibleTextWidth) < 0.5)
            #expect(h.editor.scrollView.documentVisibleRect.minX <= 0, "scrolled back to the left edge")
        }

        /// View › Word Wrap writes the setting; open query tabs follow it and the menu item shows it.
        @Test func wordWrapMenuTogglesTheSettingAndOpenTabs() throws {
            let original = AppEnvironment.settings
            defer { AppEnvironment.settings = original }
            AppEnvironment.settings.editorWordWrap = true
            let workspace = ConnectionWorkspace(config: ConnectionConfig(name: "fqtest", kind: .postgresql, port: 1, database: "x"), password: "")
            let tab = QueryTabViewController(workspace: workspace, title: "Query", sql: "SELECT 1;")
            _ = tab.view
            #expect(tab.wrapsLines)

            let delegate = AppDelegate()
            let item = NSMenuItem(title: "Word Wrap", action: #selector(AppDelegate.toggleWordWrap(_:)), keyEquivalent: "z")
            #expect(delegate.validateMenuItem(item))
            #expect(item.state == .on)
            delegate.toggleWordWrap(nil)
            #expect(!AppEnvironment.settings.editorWordWrap)
            #expect(!tab.wrapsLines)
            _ = delegate.validateMenuItem(item)
            #expect(item.state == .off)

            AppEnvironment.settings.highlightCurrentStatement = false
            #expect(!tab.editorForTesting.highlightsCurrentStatement)
        }

        @Test func menuHasTheNewCommands() throws {
            _ = NSApplication.shared
            let menu = MainMenu.build()
            let query = try #require(menu.items.first { $0.title == "Query" }?.submenu)
            let runNext = try #require(query.items.first { $0.title == "Run Statement and Move to Next" })
            #expect(runNext.keyEquivalent == "\r")
            #expect(runNext.keyEquivalentModifierMask == [.command, .control])
            let view = try #require(menu.items.first { $0.title == "View" }?.submenu)
            let wrap = try #require(view.items.first { $0.title == "Word Wrap" })
            #expect(wrap.keyEquivalent == "z" && wrap.keyEquivalentModifierMask == [.option])
            // No other item uses ⌃⌘↩ or ⌥Z.
            let all = menu.items.compactMap(\.submenu).flatMap(\.items)
            #expect(all.filter { $0.keyEquivalent == "\r" && $0.keyEquivalentModifierMask == [.command, .control] }.count == 1)
            #expect(all.filter { $0.keyEquivalent == "z" && $0.keyEquivalentModifierMask == [.option] }.count == 1)
        }

        /// ⌃⌘↩ runs the statement at the caret, then moves to the next statement's code; at the last one it stays.
        @Test func runStatementAndMoveToNext() async throws {
            let directory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
            let url = directory.appendingPathComponent("run-next-\(UUID().uuidString).sqlite")
            let workspace = ConnectionWorkspace(config: ConnectionConfig(name: "fqtest", kind: .sqlite, filePath: url.path), password: "")
            try await workspace.connect()
            defer {
                Task { await workspace.disconnect() }
                for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
            }
            let sql = "SELECT 'first' AS v;\n\n-- the second one\nSELECT 'second' AS v;\nSELECT 'third' AS v;"
            let tab = QueryTabViewController(workspace: workspace, title: "Query", sql: sql)
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = tab
            window.orderFront(nil)
            defer {
                window.orderOut(nil)
                window.close()
            }
            func firstCell() -> String? {
                if case .text(let value) = tab.currentResult?.rows.first?.first { return value }
                return nil
            }
            func runNext() async {
                tab.runStatementAndMoveToNext(nil)
                await settle(until: { !tab.isRunning }, seconds: 10)
                await settle(50)
            }
            let ns = sql as NSString
            tab.placeCaret(at: 3)
            await runNext()
            #expect(firstCell() == "first")
            #expect(tab.caretLocation == ns.range(of: "SELECT 'second'").location, "the comment before the next statement is skipped")

            await runNext()
            #expect(firstCell() == "second")
            #expect(tab.caretLocation == ns.range(of: "SELECT 'third'").location)

            await runNext()
            #expect(firstCell() == "third")
            #expect(tab.caretLocation == ns.range(of: "SELECT 'third'").location, "the caret stays at the last statement")
        }
    }
}

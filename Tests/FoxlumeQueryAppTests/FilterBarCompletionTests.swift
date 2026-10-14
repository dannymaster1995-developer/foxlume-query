import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

extension AppCompletionTests {
    @Suite("Filter bar Raw SQL completion")
    @MainActor
    struct FilterBarTests {
        /// `cre| AND id = 1` with the list open.
        private func openedBeforeACondition() async -> FilterHarness {
            let f = FilterHarness()
            f.type(" AND id = 1")
            await settle()
            f.fieldEditor?.setSelectedRange(NSRange(location: 0, length: 0))
            f.type("cre")
            await settle()
            return f
        }

        @Test func caretMoveWithoutAnEditClosesTheList() async {
            let f = await openedBeforeACondition()
            defer { f.close() }
            #expect(f.labels == ["created_at", "credit"])
            f.key("cmd-right")
            #expect(f.labels.isEmpty)
            f.key("down")
            f.key("return")
            #expect(f.text == "cre AND id = 1", "accepting replaced text outside the token")
            #expect(f.applied == ["cre AND id = 1"])
        }

        @Test func clickElsewhereInTheFieldClosesTheList() async {
            let f = await openedBeforeACondition()
            defer { f.close() }
            f.fieldEditor?.setSelectedRange(NSRange(location: (f.text as NSString).length, length: 0))
            #expect(f.labels.isEmpty)
            await settle()
            #expect(f.labels.isEmpty, "a caret move asked for a new list")
            #expect(f.text == "cre AND id = 1")
        }

        @Test func selectingTextClosesTheList() async {
            let f = await openedBeforeACondition()
            defer { f.close() }
            f.fieldEditor?.setSelectedRange(NSRange(location: 0, length: 3))
            #expect(f.labels.isEmpty)
        }

        /// As in the editor, the pool of the opening answer is re-ranked, so moving back widens the list again.
        @Test func movingLeftInsideTheTokenWidensTheList() async {
            let f = FilterHarness()
            defer { f.close() }
            f.type("cre")
            await settle()
            f.type("d")
            #expect(f.labels == ["credit"])
            f.key("left")
            #expect(f.labels == ["created_at", "credit"])
            await settle()
            #expect(f.labels == ["created_at", "credit"], "the answer for the old caret replaced the list")
            #expect(f.requests == 1)
            f.key("left")
            f.key("left")
            f.key("left")
            #expect(f.labels.isEmpty, "the caret reached the token start")
        }

        /// Until the next answer arrives the rows follow what is typed, so a quick accept takes a matching row.
        @Test func quickAcceptAfterTypingUsesTheLiveToken() async {
            let f = FilterHarness()
            defer { f.close() }
            f.type("cre")
            await settle()
            f.type("d")
            #expect(f.labels == ["credit"])
            f.key("down")
            f.key("return")
            #expect(f.text == "credit")
        }

        @Test func theAnswerKeepsTheRowTheUserMovedTo() async {
            let f = FilterHarness()
            defer { f.close() }
            f.type("cre")
            await settle()
            f.key("up")
            #expect(f.selected == "credit")
            f.type("d")
            await settle()
            #expect(f.requests == 2)
            #expect(f.selected == "credit")
        }

        /// The edit that leaves the token still gets its own answer.
        @Test func typingADotSwitchesToTheQualifiersList() async {
            let f = FilterHarness()
            defer { f.close() }
            f.type("users")
            await settle()
            #expect(f.labels == ["users"])
            f.type(".")
            #expect(f.labels.isEmpty)
            await settle()
            #expect(f.labels == ["id", "name"])
            f.key("down")
            f.key("return")
            #expect(f.text == "users.id")
        }

        @Test func returnWithoutASelectionApplies() async {
            let f = FilterHarness()
            defer { f.close() }
            f.type("cre")
            await settle()
            #expect(f.selected == nil)
            f.key("return")
            #expect(f.applied == ["cre"])
            #expect(f.labels.isEmpty)
        }
    }
}

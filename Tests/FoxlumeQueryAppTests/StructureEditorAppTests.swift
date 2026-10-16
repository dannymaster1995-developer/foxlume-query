import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

extension AppCompletionTests {
    @Suite("Structure editor column order")
    @MainActor
    struct StructureEditorAppTests {
        /// The structure editor of a four-column MySQL table in a small window.
        private func makeEditor() -> (StructureDraftEditor, NSWindow) {
            let structure = TableStructure(table: TableRef(name: "t"), columns: [
                ColumnInfo(name: "a", dataType: "int", isNullable: false),
                ColumnInfo(name: "b", dataType: "int"),
                ColumnInfo(name: "c", dataType: "int"),
                ColumnInfo(name: "d", dataType: "int"),
            ])
            let editor = StructureDraftEditor(draft: StructureDraft(structure: structure, family: .mysql), generator: TableDDLGenerator(dialect: .mysql))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = editor
            window.layoutIfNeeded()
            editor.table.reload()
            return (editor, window)
        }

        private func names(_ editor: StructureDraftEditor) -> [String] {
            editor.draft.columns.map(\.current.name)
        }

        private func menu(_ editor: StructureDraftEditor, row: Int) -> [String: NSMenuItem] {
            editor.table.select(row: row)
            let items = editor.table.menuItems?(IndexSet(integer: row)) ?? []
            return Dictionary(items.filter { !$0.isSeparatorItem }.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
        }

        private func moveKey(_ window: NSWindow, up: Bool) -> Bool {
            let characters = up ? "\u{F700}" : "\u{F701}"
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option, .numericPad, .function], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: up ? 126 : 125)
            return event.map { window.performKeyEquivalent(with: $0) } ?? false
        }

        @Test func movesByMenuKeyAndDropAreUndoable() throws {
            let (editor, window) = makeEditor()
            defer { window.close() }

            let first = menu(editor, row: 0)
            #expect(first["Move Up"]?.isEnabled == false)
            #expect(first["Move to Top"]?.isEnabled == false)
            #expect(first["Move Down"]?.isEnabled == true)
            #expect(first["Move Down"]?.keyEquivalentModifierMask == [.command, .option])

            // ⌥⌘↓ on the focused list moves the selected row and keeps it selected.
            editor.table.select(row: 0)
            window.makeFirstResponder(editor.table.tableView)
            #expect(moveKey(window, up: false))
            #expect(names(editor) == ["b", "a", "c", "d"])
            #expect(editor.table.tableView.selectedRowIndexes == IndexSet(integer: 1))

            // A drop of two rows above the first.
            #expect(editor.table.moveRows(IndexSet([2, 3]), to: 0))
            #expect(names(editor) == ["c", "d", "b", "a"])
            #expect(editor.table.tableView.selectedRowIndexes == IndexSet([0, 1]))

            // The menu's Move to Bottom.
            let items = menu(editor, row: 0)
            let bottom = try #require(items["Move to Bottom"])
            NSApp.sendAction(try #require(bottom.action), to: bottom.target, from: bottom)
            #expect(names(editor) == ["d", "b", "a", "c"])

            editor.editUndoManager.undo()
            #expect(names(editor) == ["c", "d", "b", "a"])
            editor.editUndoManager.undo()
            editor.editUndoManager.undo()
            #expect(names(editor) == ["a", "b", "c", "d"])
            #expect(!editor.draft.hasChanges)
            editor.editUndoManager.redo()
            #expect(names(editor) == ["b", "a", "c", "d"])
        }

        @Test func aBlockerDisablesEveryWayToMove() {
            let (editor, window) = makeEditor()
            defer { window.close() }
            editor.reorderBlocker = { "PostgreSQL cannot reorder the columns of this table: it has triggers (audit)." }

            let items = menu(editor, row: 1)
            for title in ["Move Up", "Move Down", "Move to Top", "Move to Bottom"] {
                #expect(items[title]?.isEnabled == false)
                #expect(items[title]?.toolTip == "PostgreSQL cannot reorder the columns of this table: it has triggers (audit).")
            }
            #expect(!editor.table.moveRows(IndexSet(integer: 1), to: 0))
            #expect(editor.table.tableView(editor.table.tableView, pasteboardWriterForRow: 1) == nil)
            editor.table.select(row: 1)
            window.makeFirstResponder(editor.table.tableView)
            _ = moveKey(window, up: true)
            #expect(names(editor) == ["a", "b", "c", "d"])

            // Other sections never move rows.
            editor.reorderBlocker = { nil }
            editor.section = .indexes
            #expect(!editor.canMoveColumns)
        }
    }
}

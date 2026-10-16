import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

extension AppCompletionTests {
    /// Typed cell editors of a table tab on a scratch SQLite table: which columns get them, boolean toggles staged
    /// as one undo step, and the foreign key picker's rows.
    @Suite("Grid cell editors")
    @MainActor
    struct GridCellEditorAppTests {
        private func makeTab() async throws -> (TableTabViewController, ConnectionWorkspace, URL) {
            let directory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
            let url = directory.appendingPathComponent("grid-editors-\(UUID().uuidString).sqlite")
            let workspace = ConnectionWorkspace(config: ConnectionConfig(name: "fqtest", kind: .sqlite, filePath: url.path), password: "")
            try await workspace.connect()
            _ = try await workspace.execute("""
                CREATE TABLE fq_parent (id INTEGER PRIMARY KEY, title TEXT);
                INSERT INTO fq_parent VALUES (1, 'Alpha'), (2, 'Beta'), (3, 'Gamma');
                CREATE TABLE fq_items (id INTEGER PRIMARY KEY, flag BOOLEAN, born DATE, parent_id INTEGER REFERENCES fq_parent(id), note TEXT);
                INSERT INTO fq_items VALUES (1, 1, '2024-03-05', 1, 'a'), (2, 0, NULL, NULL, 'b'), (3, NULL, NULL, 2, 'c');
                """, recordHistory: false)
            await workspace.refreshMetadata()
            let tab = TableTabViewController(workspace: workspace, table: TableRef(name: "fq_items"))
            _ = tab.view
            await settle(until: { tab.grid.content.rows.count == 3 && tab.grid.isEditable && !tab.grid.columnEditors.isEmpty }, seconds: 5)
            return (tab, workspace, url)
        }

        private func tearDown(_ workspace: ConnectionWorkspace, _ url: URL) async {
            await workspace.disconnect()
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }

        @Test func columnsGetTheirEditors() async throws {
            let (tab, workspace, url) = try await makeTab()
            defer { Task { await tearDown(workspace, url) } }
            let editors = tab.grid.columnEditors
            #expect(editors[1]?.kind == .boolean(.numeric))
            #expect(editors[2]?.kind == .temporal(.date) && editors[2]?.hasPanel == true)
            #expect(editors[3]?.reference?.referencedTable.name == "fq_parent" && editors[3]?.hasPanel == true)
            #expect(editors[0] == nil && editors[4] == nil, "integer and text columns keep the plain editor")
            #expect(editors[1]?.hasPanel == false, "booleans toggle in place")
            #expect(tab.grid.toggleState(for: .text("1"), column: 1) == .on)
            #expect(tab.grid.toggleState(for: .null, column: 1) == .null)
            #expect(tab.grid.toggleState(for: .text("maybe"), column: 1) == nil)
            #expect(tab.grid.toggleState(for: .text("1"), column: 4) == nil)
        }

        @Test func spaceTogglesSelectedBooleansAsOneStep() async throws {
            let (tab, workspace, url) = try await makeTab()
            defer { Task { await tearDown(workspace, url) } }
            let grid = tab.grid
            // The active cell is row 2 (NULL), so every selected cell turns true.
            grid.selectCells(rows: 0...2, columns: 1...1)
            #expect(grid.toggleBooleanCells())
            #expect(grid.content.changes.value(row: 0, column: 1) == nil, "already true")
            #expect(grid.content.changes.value(row: 1, column: 1) == .text("1"))
            #expect(grid.content.changes.value(row: 2, column: 1) == .text("1"))
            tab.undo(nil)
            #expect(grid.content.changes.isEmpty, "one undo step takes the whole toggle back")

            grid.setCellSelection(.single(GridCell(row: 0, column: 1)))
            #expect(grid.toggleIfOnlyActiveCell(GridCell(row: 0, column: 1)))
            #expect(grid.content.changes.value(row: 0, column: 1) == .text("0"))
            #expect(!grid.toggleIfOnlyActiveCell(GridCell(row: 1, column: 1)), "a click on another cell's box only selects")

            grid.setCellSelection(.single(GridCell(row: 0, column: 4)))
            #expect(!grid.toggleBooleanCells(), "Space on a text cell is left to the table")
        }

        @Test func referencePickerListsAndSearchesRows() async throws {
            let (tab, workspace, url) = try await makeTab()
            defer { Task { await tearDown(workspace, url) } }
            let all = try await tab.dataGrid(tab.grid, referenceCandidatesForColumn: 3, matching: "")
            #expect(all == [ReferenceCandidate(key: .text("1"), label: "Alpha"), ReferenceCandidate(key: .text("2"), label: "Beta"), ReferenceCandidate(key: .text("3"), label: "Gamma")])
            let searched = try await tab.dataGrid(tab.grid, referenceCandidatesForColumn: 3, matching: "gam")
            #expect(searched.map(\.key) == [.text("3")])
            #expect(try await tab.dataGrid(tab.grid, referenceCandidatesForColumn: 1, matching: "").isEmpty, "no picker for other columns")
        }
    }
}

import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

/// Records what a grid asks its delegate.
@MainActor
private final class GridRecorder: DataGridViewDelegate {
    var sorts: [[SortKey]] = []
    var selectionChanges = 0
    func dataGrid(_ grid: DataGridView, didChangeSort sort: [SortKey]) { sorts.append(sort) }
    func dataGridSelectionDidChange(_ grid: DataGridView) { selectionChanges += 1 }
}

/// The titles of a cell menu built for `row` / data column `column`, as a right-click would build it.
@MainActor
private func cellMenu(_ grid: DataGridView, row: Int, column: Int) -> NSMenu {
    let tableColumn = grid.tableView.tableColumns.firstIndex { $0.identifier.rawValue == "c\(column)" } ?? -1
    let menu = NSMenu()
    grid.populateContextMenu(menu, row: row, tableColumn: tableColumn)
    return menu
}

private func scratchDatabase(_ name: String) -> URL {
    let directory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
    return directory.appendingPathComponent("\(name)-\(UUID().uuidString).sqlite")
}

extension AppCompletionTests {
    @Suite("Grid selection model")
    @MainActor
    struct GridSelectionModelTests {
        private func cell(_ row: Int, _ column: Int) -> GridCell { GridCell(row: row, column: column) }

        @Test func clickShiftClickAndArrows() {
            var selection = GridSelection.single(cell(2, 1))
            selection.extend(to: cell(0, 3))
            #expect(selection.rectangles == [GridRect(rows: 0...2, columns: 1...3)])
            #expect(selection.anchor == cell(2, 1) && selection.active == cell(0, 3))
            #expect(selection.cellCount == 9)
            #expect(selection.affectedRows == IndexSet(0...2))

            selection.extend(.right, toEdge: false, rowCount: 5, columnCount: 4)
            #expect(selection.rectangles == [GridRect(rows: 0...2, columns: 1...3)], "already at the last column")
            selection.extend(.down, toEdge: true, rowCount: 5, columnCount: 4)
            #expect(selection.rectangles == [GridRect(rows: 2...4, columns: 1...3)], "the anchor stays, the active end jumps to the last row")
            selection.move(.left, toEdge: false, rowCount: 5, columnCount: 4)
            #expect(selection == .single(cell(4, 2)))
            selection.move(.up, toEdge: true, rowCount: 5, columnCount: 4)
            #expect(selection == .single(cell(0, 2)))
        }

        @Test func commandClickAddsAndRemovesSingleCells() {
            var selection = GridSelection.single(cell(0, 0))
            selection.extend(to: cell(2, 2))
            selection.toggle(cell(1, 1))
            #expect(selection.cellCount == 8)
            #expect(!selection.contains(cell(1, 1)))
            #expect(selection.columns(inRow: 1) == IndexSet([0, 2]))
            selection.toggle(cell(1, 1))
            #expect(selection.cellCount == 9 && selection.active == cell(1, 1))
            selection.toggle(cell(4, 4))
            #expect(selection.cellCount == 10)
            #expect(selection.bounds == GridRect(rows: 0...4, columns: 0...4))
            #expect(selection.topLeft == cell(0, 0))

            var one = GridSelection.single(cell(3, 3))
            one.toggle(cell(3, 3))
            #expect(one.isEmpty)
        }

        @Test func wholeColumnsAndClamping() {
            var selection = GridSelection.empty
            selection.selectColumn(2, rowCount: 4, adding: false)
            #expect(selection.rectangles == [GridRect(rows: 0...3, columns: 2...2)])
            #expect(selection.fullColumns == IndexSet(integer: 2))
            selection.selectColumn(0, rowCount: 4, adding: true)
            #expect(selection.fullColumns == IndexSet([0, 2]) && selection.cellCount == 8)
            selection.selectColumn(2, rowCount: 4, adding: true)
            #expect(selection.fullColumns == IndexSet(integer: 0) && selection.cellCount == 4, "a second ⌘-click takes the column out")

            selection.clamp(rowCount: 2, columnCount: 3)
            #expect(selection.rectangles == [GridRect(rows: 0...1, columns: 0...0)])
            selection.clamp(rowCount: 0, columnCount: 3)
            #expect(selection.isEmpty)
        }

        /// The grid keeps the table's row selection on the rows the cells touch, so row commands keep working.
        @Test func gridSyncsRowsAndComputesStatistics() {
            let grid = DataGridView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            let recorder = GridRecorder()
            grid.delegate = recorder
            grid.setContent(DataGridContent(
                columns: [ResultColumn(name: "id", typeName: "int4", isNumeric: true), ResultColumn(name: "name", typeName: "text"), ResultColumn(name: "price", typeName: "numeric", isNumeric: true)],
                rows: [[.text("1"), .text("a"), .text("1.5")], [.text("2"), .null, .text("2.5")], [.text("3"), .text("c"), .null]]
            ))
            grid.selectCells(rows: 0...2, columns: 2...2)
            #expect(grid.selectedRows == IndexSet(0...2))
            #expect(recorder.selectionChanges == 1)
            #expect(grid.selectionStatistics?.summary == "Count 2 · Sum 4 · Average 2 · Min 1.5 · Max 2.5")
            grid.selectCells(rows: 0...1, columns: 0...1)
            #expect(grid.selectionStatistics?.summary == "Count 3 · Sum 3 · Average 1.5 · Min 1 · Max 2", "text columns count but do not add up")
            let copied = grid.cellSelectionText(includeHeader: true)
            #expect(copied == "id\tname\r\n1\ta\r\n2\t", "NULL copies as an empty field, as row copies do")
            grid.selectCells(rows: 1...1, columns: 1...1)
            #expect(grid.cellSelectionText(includeHeader: false) == "NULL")
            #expect(grid.selectionStatistics == nil, "one cell shows no figures")

            // Rows picked another way end the cell selection.
            grid.selectRow(2)
            #expect(grid.cellSelection.isEmpty)
            #expect(grid.selectedRows == IndexSet(integer: 2))
        }

        /// Set Value holds NULL and Empty String everywhere, DEFAULT on SQL engines but SQLite, and the current
        /// timestamp on SQL engines; read-only grids have no Set Value.
        @Test func setValueMenuPerEngineKind() {
            for kind in DatabaseKind.allCases {
                let grid = DataGridView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
                grid.setContent(DataGridContent(columns: [ResultColumn(name: "id", typeName: "int4", isNumeric: true), ResultColumn(name: "name", typeName: "text")], rows: [[.text("1"), .text("a")]]))
                grid.allowValueKeywords(for: kind)
                grid.isEditable = true
                let menu = cellMenu(grid, row: 0, column: 1)
                let titles = menu.items.map(\.title)
                let values = menu.items.first { $0.title == "Set Value" }?.submenu?.items.map(\.title)
                var expected = ["NULL", "Empty String"]
                if kind.isSQL && kind != .sqlite { expected.append("DEFAULT") }
                if kind.isSQL { expected.append("Current Timestamp (NOW())") }
                #expect(values == expected, "\(kind)")
                #expect(!titles.contains { $0.hasPrefix("Set ") && $0 != "Set Value" }, "\(kind): the old flat items are gone")
                if let index = titles.firstIndex(of: "Set Value") {
                    #expect(titles[index + 1] == "Fill Cell…", "\(kind): Fill stays right below Set Value")
                }
                #expect(titles.contains("Delete Row"))

                grid.isEditable = false
                #expect(!cellMenu(grid, row: 0, column: 1).items.contains { $0.title == "Set Value" }, "\(kind): read-only grids offer no Set Value")
            }
        }

        @Test func localSortCyclesThroughSeveralKeys() {
            let grid = DataGridView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            let recorder = GridRecorder()
            grid.delegate = recorder
            let rows: [[CellValue]] = [[.text("b"), .text("10")], [.text("a"), .text("9")], [.text("b"), .text("2")]]
            grid.setContent(DataGridContent(columns: [ResultColumn(name: "k", typeName: "text"), ResultColumn(name: "n", typeName: "int", isNumeric: true)], rows: rows), localSort: true)
            func order() -> [String] { grid.content.rows.map { $0.map(\.displayString).joined(separator: ":") } }

            grid.headerClicked(dataColumn: 0, additive: false)
            grid.headerClicked(dataColumn: 1, additive: true)
            #expect(grid.sortKeys == [SortKey(column: "k", ascending: true), SortKey(column: "n", ascending: true)])
            #expect(order() == ["a:9", "b:2", "b:10"])
            let header = grid.tableView.tableColumns.compactMap { $0.headerCell as? GridHeaderCell }
            #expect(header.map(\.sortPriority) == [1, 2])
            grid.headerClicked(dataColumn: 1, additive: true)
            #expect(order() == ["a:9", "b:10", "b:2"])
            grid.headerClicked(dataColumn: 0, additive: false)
            #expect(grid.sortKeys == [SortKey(column: "k", ascending: false)])
            grid.headerClicked(dataColumn: 0, additive: false)
            #expect(grid.sortKeys.isEmpty)
            #expect(order() == ["b:10", "a:9", "b:2"], "no sort shows the rows as they arrived")
            #expect(recorder.sorts.isEmpty, "query results never ask the server")
        }
    }

    /// Paste and range edits staged in a table tab on a scratch SQLite table.
    @Suite("Grid paste staging")
    @MainActor
    struct GridPasteStagingTests {
        private func makeTab() async throws -> (TableTabViewController, ConnectionWorkspace, URL) {
            let url = scratchDatabase("grid-paste")
            let workspace = ConnectionWorkspace(config: ConnectionConfig(name: "fqtest", kind: .sqlite, filePath: url.path), password: "")
            try await workspace.connect()
            _ = try await workspace.execute("""
                CREATE TABLE fq_grid_items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, qty INTEGER);
                INSERT INTO fq_grid_items (name, qty) VALUES ('a', 1), ('b', 2), ('c', 3);
                """, recordHistory: false)
            await workspace.refreshMetadata()
            let tab = TableTabViewController(workspace: workspace, table: TableRef(name: "fq_grid_items"))
            _ = tab.view
            await settle(until: { tab.grid.content.rows.count == 3 && tab.grid.isEditable }, seconds: 5)
            return (tab, workspace, url)
        }

        private func tearDown(_ workspace: ConnectionWorkspace, _ url: URL) async {
            await workspace.disconnect()
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }

        @Test func blockPastesIntoCellsAsOneUndoStep() async throws {
            let (tab, workspace, url) = try await makeTab()
            defer { Task { await tearDown(workspace, url) } }
            let grid = tab.grid
            #expect(grid.content.rows.count == 3)
            grid.selectCells(rows: 1...1, columns: 1...1)
            grid.pasteText("x\t7\ny\tNULL\nz\t9")
            #expect(grid.lastRefusal == nil)
            let changes = grid.content.changes
            #expect(changes.value(row: 1, column: 1) == .text("x") && changes.value(row: 1, column: 2) == .text("7"))
            #expect(changes.value(row: 2, column: 1) == .text("y") && changes.value(row: 2, column: 2) == .null)
            #expect(changes.insertions.isEmpty, "the third line runs past the last row and is left out, as in TablePro")
            #expect(grid.cellSelection.bounds == GridRect(rows: 1...2, columns: 1...2), "the pasted block stays selected")
            #expect(tab.previewOfPendingChanges()?.contains("UPDATE \"fq_grid_items\" SET \"name\" = 'x', \"qty\" = '7' WHERE \"id\" = '2'") == true)

            tab.undo(nil)
            #expect(grid.content.changes.isEmpty)
        }

        @Test func fullWidthRowsBecomeInsertionsWithDefaults() async throws {
            let (tab, workspace, url) = try await makeTab()
            defer { Task { await tearDown(workspace, url) } }
            let grid = tab.grid
            grid.pasteText("id\tname\tqty\n99\tnew\t\n\tother\t5\n")
            let insertions = grid.content.changes.insertions
            #expect(insertions.count == 2)
            #expect(insertions.first == [.useDefault, .value(.text("new")), .useDefault], "the auto-increment key and an empty field take their defaults")
            #expect(insertions.last == [.useDefault, .value(.text("other")), .value(.text("5"))])
            #expect(grid.selectedRows == IndexSet(3...4))
        }

        @Test func refusesFixedColumnsReadOnlyGridsAndMissingAnchor() async throws {
            let (tab, workspace, url) = try await makeTab()
            defer { Task { await tearDown(workspace, url) } }
            let grid = tab.grid
            grid.pasteText("x\ty")
            #expect(grid.lastRefusal == "Select the cell where the pasted values should start.")

            grid.immutableColumns = ["qty"]
            grid.selectCells(rows: 0...0, columns: 1...1)
            grid.pasteText("x\t5")
            #expect(grid.lastRefusal == "“qty” cannot be edited, so nothing was pasted.")
            #expect(grid.content.changes.isEmpty)

            grid.isEditable = false
            grid.readOnlyReason = "This connection is read-only."
            grid.pasteText("x")
            #expect(grid.lastRefusal == "This connection is read-only.")
            #expect(grid.content.changes.isEmpty)
        }

        @Test func setValueSubmenuEditsTheSelectedCellsAsOneStep() async throws {
            let (tab, workspace, url) = try await makeTab()
            defer { Task { await tearDown(workspace, url) } }
            let grid = tab.grid
            func choose(_ title: String, row: Int, column: Int) throws {
                let menu = cellMenu(grid, row: row, column: column)
                let item = try #require(menu.items.first { $0.title == "Set Value" }?.submenu?.items.first { $0.title == title })
                _ = (item.target as AnyObject).perform(try #require(item.action), with: item)
                grid.menuDidClose(menu)
            }
            #expect(cellMenu(grid, row: 0, column: 1).items.first { $0.title == "Set Value" }?.submenu?.items.map(\.title) == ["NULL", "Empty String", "Current Timestamp (NOW())"], "SQLite has no DEFAULT keyword")

            grid.selectCells(rows: 0...2, columns: 1...2)
            try choose("NULL", row: 1, column: 2)
            #expect(grid.content.changes.changeCount == 6)
            #expect(grid.content.changes.value(row: 2, column: 1) == .null)
            tab.undo(nil)
            #expect(grid.content.changes.isEmpty, "one undo step takes back every cell")

            grid.selectCells(rows: 0...0, columns: 1...1)
            try choose("Empty String", row: 0, column: 1)
            #expect(grid.content.changes.value(row: 0, column: 1) == .text(""))
            grid.selectCells(rows: 1...1, columns: 1...1)
            try choose("Current Timestamp (NOW())", row: 1, column: 1)
            #expect(grid.content.changes.value(row: 1, column: 1) == .expression("CURRENT_TIMESTAMP"))
            #expect(tab.previewOfPendingChanges()?.contains("SET \"name\" = CURRENT_TIMESTAMP WHERE \"id\" = '2'") == true)
        }

        @Test func rangeEditsAreOneStepAndSortRunsOnTheServer() async throws {
            let (tab, workspace, url) = try await makeTab()
            defer { Task { await tearDown(workspace, url) } }
            let grid = tab.grid
            grid.selectCells(rows: 0...2, columns: 1...2)
            let cells = grid.targetCellsForEditing()
            #expect(cells.count == 6)
            tab.dataGrid(grid, didEditCells: cells.map { GridCellEdit(row: $0.row, column: $0.column, value: .null) }, actionName: "Set NULL")
            #expect(grid.content.changes.changeCount == 6)
            tab.undo(nil)
            #expect(grid.content.changes.isEmpty)

            grid.headerClicked(dataColumn: 2, additive: false)
            await settle(until: { grid.content.rows.first?.first == .text("1") && tab.currentQuery.sort == [SortKey(column: "qty", ascending: true)] }, seconds: 5)
            grid.headerClicked(dataColumn: 2, additive: false)
            await settle(until: { grid.content.rows.first?.first == .text("3") }, seconds: 5)
            #expect(tab.currentQuery.sort == [SortKey(column: "qty", ascending: false)])
            grid.headerClicked(dataColumn: 1, additive: true)
            await settle(until: { tab.currentQuery.sort.count == 2 }, seconds: 5)
            #expect(tab.currentQuery.sort == [SortKey(column: "qty", ascending: false), SortKey(column: "name", ascending: true)])
            #expect(grid.sortKeys == tab.currentQuery.sort)
        }
    }
}

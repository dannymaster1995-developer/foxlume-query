import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

/// Records the column layouts a grid reports.
@MainActor
private final class LayoutRecorder: DataGridViewDelegate {
    var saved: GridColumnLayout?
    var changes: [GridColumnLayout?] = []
    func dataGridSavedColumnLayout(_ grid: DataGridView) -> GridColumnLayout? { saved }
    func dataGrid(_ grid: DataGridView, didChangeColumnLayout layout: GridColumnLayout?) { changes.append(layout) }
}

@MainActor
private func makeGrid(_ delegate: DataGridViewDelegate? = nil, rows: [[CellValue]]? = nil) -> DataGridView {
    let grid = DataGridView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    grid.delegate = delegate
    grid.setContent(DataGridContent(
        columns: [ResultColumn(name: "id", typeName: "int4", isNumeric: true), ResultColumn(name: "name", typeName: "text"), ResultColumn(name: "price", typeName: "numeric", isNumeric: true)],
        rows: rows ?? [[.text("1"), .text("a"), .text("1.5")], [.text("2"), .null, .text("2.5")], [.text("3"), .text("c"), .null]]
    ))
    return grid
}

@MainActor
private func names(_ grid: DataGridView) -> [String] {
    grid.displayedDataColumns.map { grid.content.columns[$0].name }
}

extension AppCompletionTests {
    @Suite("Grid columns")
    @MainActor
    struct GridColumnsTests {
        /// Hidden columns leave the screen and the cell selection, but row copies still carry them.
        @Test func hidingAffectsCellCopiesButNotRowCopies() throws {
            let recorder = LayoutRecorder()
            let grid = makeGrid(recorder)
            #expect(grid.setColumn(1, hidden: true))
            #expect(names(grid) == ["id", "price"])
            #expect(grid.isColumnHidden(1))
            #expect(recorder.changes.last??.columns.map(\.isHidden) == [false, true, false])

            grid.selectCells(rows: 0...1, columns: 0...2)
            #expect(grid.cellSelectionText(includeHeader: true) == "id\tprice\r\n1\t1.5\r\n2\t2.5")
            grid.copyRows(format: .tsv, includeHeader: true)
            #expect(NSPasteboard.general.string(forType: .string)?.hasPrefix("id\tname\tprice") == true, "row copies keep every column")

            // Hiding moves display positions, so the cell selection ends; the last column on screen stays.
            #expect(grid.setColumn(0, hidden: true))
            #expect(grid.cellSelection.isEmpty)
            #expect(!grid.canHideColumn)
            #expect(!grid.setColumn(2, hidden: true))
            #expect(names(grid) == ["price"])
            let hide = try #require(grid.headerMenu(forDataColumn: 2)?.items.first { $0.title == "Hide Column" })
            #expect(hide.action == nil, "Hide Column is disabled for the last column on screen")

            grid.showAllColumns()
            #expect(names(grid) == ["id", "name", "price"])
            let titles = grid.headerMenu(forDataColumn: 0)?.items.map(\.title) ?? []
            for title in ["Hide Column", "Show Columns…", "Jump to Column…", "Size Column to Fit", "Size All Columns to Fit", "Reset Column Layout"] {
                #expect(titles.contains(title), "\(title) in the header menu")
            }
            #expect(grid.headerMenuWithoutColumn()?.items.map(\.title).contains("Hide Column") == false)
        }

        @Test func columnsListTogglesAndShowsAll() throws {
            let grid = makeGrid()
            grid.showColumnsList()
            let picker = try #require(grid.columnPicker)
            #expect(picker.mode == .visibility)
            picker.filter("")
            #expect(picker.visibleTitles == ["id", "name", "price"])
            grid.setColumn(2, hidden: true)
            picker.filter("pr")
            #expect(picker.visibleTitles == ["price (hidden)"])
            let box = try #require(picker.tableView(picker.list, viewFor: nil, row: 0) as? NSButton)
            #expect(box.state == .off)
            box.performClick(nil)
            #expect(!grid.isColumnHidden(2))
            grid.setColumn(0, hidden: true)
            grid.setColumn(1, hidden: true)
            picker.filter("")
            let showAll = try #require(picker.view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Show All" })
            showAll.performClick(nil)
            #expect(names(grid) == ["id", "name", "price"])
        }

        @Test func sizeToFitMeasuresLoadedRowsWithACap() {
            let recorder = LayoutRecorder()
            let long = String(repeating: "wide text ", count: 8)
            let grid = makeGrid(recorder, rows: [[.text("1"), .text(long), .text("1")], [.text("2"), .text(String(repeating: "x", count: 5_000)), .text("2")]])
            let name = grid.tableColumn(forDataColumn: 1)
            let id = grid.tableColumn(forDataColumn: 0)
            #expect(name?.width == 360, "the starting width stops at 360")
            grid.sizeColumnToFit(1)
            #expect(name?.width == DataGridView.fitMaximumWidth, "a very long value stops at the cap")
            #expect(recorder.changes.count == 1)

            let tableIndex = grid.tableView.tableColumns.firstIndex { $0 === id } ?? -1
            let fitted = grid.tableView(grid.tableView, sizeToFitWidthOfColumn: tableIndex)
            #expect(fitted == grid.fitWidth(forDataColumn: 0))
            #expect(fitted >= DataGridView.minimumColumnWidth && fitted < 120)
            id?.width = 300
            grid.sizeAllColumnsToFit()
            #expect(id?.width == fitted)
            #expect(recorder.changes.count == 2)
        }

        @Test func jumpScrollsSelectsAndShowsHiddenColumns() throws {
            let grid = makeGrid()
            grid.setColumn(2, hidden: true)
            grid.selectCells(rows: 1...1, columns: 0...0)
            grid.showJumpToColumn()
            let picker = try #require(grid.columnPicker)
            #expect(picker.mode == .jump)
            picker.filter("PRI")
            #expect(picker.visibleTitles == ["price (hidden)"])
            picker.chooseSelected()
            #expect(!grid.isColumnHidden(2))
            #expect(grid.cellSelection.active == GridCell(row: 1, column: grid.displayPosition(ofDataColumn: 2) ?? -1), "the current row is kept")
            #expect(grid.columnPicker == nil)

            grid.clearCellSelection()
            grid.showJumpToColumn()
            grid.columnPicker?.filter("na")
            grid.columnPicker?.chooseSelected()
            #expect(grid.cellSelection.active == GridCell(row: 0, column: 1), "without a selection the first row is used")
        }

        /// A layout from the delegate arranges the columns once; Reset brings back the natural one.
        @Test func savedLayoutIsAppliedAndReset() {
            let recorder = LayoutRecorder()
            recorder.saved = GridColumnLayout(columns: [
                GridColumnLayout.Column(name: "price", width: 150),
                GridColumnLayout.Column(name: "gone", width: 99),
                GridColumnLayout.Column(name: "id", width: 70, isHidden: true),
            ])
            let grid = makeGrid(recorder)
            #expect(names(grid) == ["price", "name"])
            #expect(grid.columnLayout.columns.map(\.name) == ["price", "id", "name"])
            #expect(grid.tableColumn(forDataColumn: 2)?.width == 150)
            #expect(recorder.changes.isEmpty, "restoring is not a change")

            grid.resetColumnLayout()
            #expect(names(grid) == ["id", "name", "price"])
            #expect(recorder.changes.count == 1 && recorder.changes[0] == nil)
        }
    }
}

extension AppCompletionTests {
    /// The layout of a table tab, saved in a store and restored by a tab opened later on the same table.
    @Suite("Grid column layout of table tabs")
    @MainActor
    struct GridColumnLayoutTabTests {
        @Test func layoutIsRestoredWhenTheTableOpensAgain() async throws {
            let directory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
            let url = directory.appendingPathComponent("grid-layout-\(UUID().uuidString).sqlite")
            let storeURL = directory.appendingPathComponent("grid-layout-\(UUID().uuidString).json")
            let workspace = ConnectionWorkspace(config: ConnectionConfig(name: "fqtest", kind: .sqlite, filePath: url.path), password: "")
            defer {
                Task { await workspace.disconnect() }
                for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
                try? FileManager.default.removeItem(at: storeURL)
            }
            try await workspace.connect()
            _ = try await workspace.execute("""
                CREATE TABLE fq_layout (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER, note TEXT);
                INSERT INTO fq_layout (name, qty, note) VALUES ('a', 1, 'x'), ('b', 2, 'y');
                """, recordHistory: false)
            await workspace.refreshMetadata()

            func open() async -> TableTabViewController {
                let tab = TableTabViewController(workspace: workspace, table: TableRef(name: "fq_layout"), columnLayouts: GridColumnLayoutStore(url: storeURL))
                _ = tab.view
                await settle(until: { tab.grid.content.rows.count == 2 }, seconds: 5)
                return tab
            }

            let first = await open()
            let grid = first.grid
            grid.setColumn(2, hidden: true)
            let note = try #require(grid.tableColumn(forDataColumn: 3))
            grid.tableView.moveColumn(try #require(grid.tableView.tableColumns.firstIndex(of: note)), toColumn: 1)
            note.width = 210
            grid.columnLayoutDidChange()
            #expect(names(grid) == ["note", "id", "name"])

            // A new store reads the file, as after a relaunch.
            let second = await open()
            #expect(names(second.grid) == ["note", "id", "name"])
            #expect(second.grid.isColumnHidden(2))
            #expect(second.grid.tableColumn(forDataColumn: 3)?.width == 210)
            // Hidden columns stay in Save and Preview SQL.
            second.applyEdit(row: 0, column: 1, value: .text("changed"))
            #expect(second.previewOfPendingChanges()?.contains("\"name\" = 'changed'") == true)
            second.discardChanges(nil)

            // A dropped column is ignored and a new one comes last, visible.
            _ = try await workspace.execute("ALTER TABLE fq_layout DROP COLUMN note; ALTER TABLE fq_layout ADD COLUMN added TEXT;", recordHistory: false)
            await workspace.refreshMetadata()
            let third = await open()
            #expect(names(third.grid) == ["id", "name", "added"])
            #expect(third.grid.isColumnHidden(2))

            third.grid.resetColumnLayout()
            #expect(GridColumnLayoutStore(url: storeURL).layout(for: third.columnLayoutScope) == nil)
            #expect(names(third.grid) == ["id", "name", "qty", "added"])
        }
    }
}

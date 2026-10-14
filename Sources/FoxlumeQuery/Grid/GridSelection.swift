import Foundation

/// A cell by display row and column position on screen (left to right, data columns only).
struct GridCell: Hashable {
    var row: Int
    var column: Int
}

/// A rectangle of cells, both ranges inclusive.
struct GridRect: Hashable {
    var rows: ClosedRange<Int>
    var columns: ClosedRange<Int>

    init(rows: ClosedRange<Int>, columns: ClosedRange<Int>) {
        self.rows = rows
        self.columns = columns
    }

    init(cell: GridCell) {
        self.init(rows: cell.row...cell.row, columns: cell.column...cell.column)
    }

    static func between(_ a: GridCell, _ b: GridCell) -> GridRect {
        GridRect(rows: min(a.row, b.row)...max(a.row, b.row), columns: min(a.column, b.column)...max(a.column, b.column))
    }

    func contains(_ cell: GridCell) -> Bool { rows.contains(cell.row) && columns.contains(cell.column) }

    var cellCount: Int { rows.count * columns.count }
}

/// The cell selection of a grid, as in TablePro: one or more rectangles, the cell a Shift-click or Shift-arrow extends
/// from (`anchor`) and the cell the keyboard moves (`active`). Empty means the grid is in row selection.
struct GridSelection: Equatable {
    enum Direction {
        case up, down, left, right
    }

    private(set) var rectangles: [GridRect] = []
    private(set) var anchor: GridCell?
    private(set) var active: GridCell?
    /// Columns picked as a whole (a ⌘-click on the header or Select Column), so the header can show them.
    private(set) var fullColumns = IndexSet()

    static let empty = GridSelection()

    static func single(_ cell: GridCell) -> GridSelection {
        var selection = GridSelection()
        selection.rectangles = [GridRect(cell: cell)]
        selection.anchor = cell
        selection.active = cell
        return selection
    }

    var isEmpty: Bool { rectangles.isEmpty }

    func contains(_ cell: GridCell) -> Bool { rectangles.contains { $0.contains(cell) } }

    var affectedRows: IndexSet {
        var rows = IndexSet()
        for rect in rectangles { rows.insert(integersIn: rect.rows) }
        return rows
    }

    var affectedColumns: IndexSet {
        var columns = IndexSet()
        for rect in rectangles { columns.insert(integersIn: rect.columns) }
        return columns
    }

    /// The selected column positions in one row.
    func columns(inRow row: Int) -> IndexSet {
        var columns = IndexSet()
        for rect in rectangles where rect.rows.contains(row) { columns.insert(integersIn: rect.columns) }
        return columns
    }

    /// Distinct cells, counting overlaps once.
    var cellCount: Int {
        if rectangles.count == 1 { return rectangles[0].cellCount }
        return affectedRows.reduce(0) { $0 + columns(inRow: $1).count }
    }

    var bounds: GridRect? {
        guard let first = rectangles.first else { return nil }
        return rectangles.dropFirst().reduce(first) { result, rect in
            GridRect(rows: min(result.rows.lowerBound, rect.rows.lowerBound)...max(result.rows.upperBound, rect.rows.upperBound),
                     columns: min(result.columns.lowerBound, rect.columns.lowerBound)...max(result.columns.upperBound, rect.columns.upperBound))
        }
    }

    /// Where a paste starts: the top left cell of the selection.
    var topLeft: GridCell? { bounds.map { GridCell(row: $0.rows.lowerBound, column: $0.columns.lowerBound) } }

    // MARK: Changes

    /// Shift-click or Shift-drag: one rectangle from the anchor (or the active cell) to `cell`.
    mutating func extend(to cell: GridCell) {
        let origin = anchor ?? active ?? cell
        self = GridSelection(rectangles: [GridRect.between(origin, cell)], anchor: origin, active: cell)
    }

    /// A ⌘-drag: `base` plus a rectangle from `origin` to `cell`.
    mutating func add(from origin: GridCell, to cell: GridCell, base: GridSelection) {
        self = GridSelection(rectangles: base.rectangles + [GridRect.between(origin, cell)], anchor: origin, active: cell, fullColumns: base.fullColumns)
    }

    /// A ⌘-click: adds the cell, or takes it out when it was selected.
    mutating func toggle(_ cell: GridCell) {
        guard contains(cell) else {
            self = GridSelection(rectangles: rectangles + [GridRect(cell: cell)], anchor: cell, active: cell, fullColumns: fullColumns)
            return
        }
        let remaining = rectangles.flatMap { Self.subtract(cell, from: $0) }
        guard let last = remaining.last else {
            self = .empty
            return
        }
        let next = GridCell(row: last.rows.lowerBound, column: last.columns.lowerBound)
        var columns = fullColumns
        columns.remove(cell.column)
        self = GridSelection(rectangles: remaining, anchor: next, active: next, fullColumns: columns)
    }

    /// Every row of one column; with `adding`, ⌘-click on a header toggles it next to the current selection.
    mutating func selectColumn(_ column: Int, rowCount: Int, adding: Bool) {
        guard rowCount > 0, column >= 0 else { return }
        let rect = GridRect(rows: 0...(rowCount - 1), columns: column...column)
        let top = GridCell(row: 0, column: column)
        guard adding, !isEmpty else {
            self = GridSelection(rectangles: [rect], anchor: top, active: top, fullColumns: IndexSet(integer: column))
            return
        }
        if fullColumns.contains(column) {
            let remaining = rectangles.filter { $0 != rect }
            var columns = fullColumns
            columns.remove(column)
            guard let last = remaining.last else {
                self = .empty
                return
            }
            let next = GridCell(row: last.rows.lowerBound, column: last.columns.lowerBound)
            self = GridSelection(rectangles: remaining, anchor: next, active: next, fullColumns: columns)
            return
        }
        var columns = fullColumns
        columns.insert(column)
        self = GridSelection(rectangles: rectangles + [rect], anchor: top, active: top, fullColumns: columns)
    }

    /// Arrow keys: the active cell moves one step, or to the edge with ⌘, and becomes the only selected cell.
    mutating func move(_ direction: Direction, toEdge: Bool, rowCount: Int, columnCount: Int) {
        guard let active else { return }
        self = .single(Self.step(active, direction, toEdge: toEdge, rowCount: rowCount, columnCount: columnCount))
    }

    /// Shift-arrow keys: the active end of the rectangle moves; the anchor stays.
    mutating func extend(_ direction: Direction, toEdge: Bool, rowCount: Int, columnCount: Int) {
        guard let active else { return }
        let origin = anchor ?? active
        let next = Self.step(active, direction, toEdge: toEdge, rowCount: rowCount, columnCount: columnCount)
        self = GridSelection(rectangles: [GridRect.between(origin, next)], anchor: origin, active: next)
    }

    /// Keeps the selection inside a grid that shrank, or empties it when nothing is left.
    mutating func clamp(rowCount: Int, columnCount: Int) {
        guard rowCount > 0, columnCount > 0 else {
            self = .empty
            return
        }
        let clamped = rectangles.compactMap { rect -> GridRect? in
            guard rect.rows.lowerBound < rowCount, rect.columns.lowerBound < columnCount else { return nil }
            return GridRect(rows: rect.rows.lowerBound...min(rect.rows.upperBound, rowCount - 1),
                            columns: rect.columns.lowerBound...min(rect.columns.upperBound, columnCount - 1))
        }
        guard !clamped.isEmpty else {
            self = .empty
            return
        }
        func inside(_ cell: GridCell?) -> GridCell? {
            cell.map { GridCell(row: min($0.row, rowCount - 1), column: min($0.column, columnCount - 1)) }
        }
        self = GridSelection(rectangles: clamped, anchor: inside(anchor), active: inside(active), fullColumns: fullColumns.filteredIndexSet { $0 < columnCount })
    }

    private init(rectangles: [GridRect], anchor: GridCell?, active: GridCell?, fullColumns: IndexSet = []) {
        self.rectangles = rectangles
        self.anchor = anchor
        self.active = active
        self.fullColumns = fullColumns
    }

    init() {}

    private static func step(_ cell: GridCell, _ direction: Direction, toEdge: Bool, rowCount: Int, columnCount: Int) -> GridCell {
        let lastRow = max(0, rowCount - 1)
        let lastColumn = max(0, columnCount - 1)
        switch direction {
        case .up: return GridCell(row: toEdge ? 0 : max(0, cell.row - 1), column: cell.column)
        case .down: return GridCell(row: toEdge ? lastRow : min(lastRow, cell.row + 1), column: cell.column)
        case .left: return GridCell(row: cell.row, column: toEdge ? 0 : max(0, cell.column - 1))
        case .right: return GridCell(row: cell.row, column: toEdge ? lastColumn : min(lastColumn, cell.column + 1))
        }
    }

    /// `rect` without `cell`: up to four rectangles (above, below, left and right of it).
    private static func subtract(_ cell: GridCell, from rect: GridRect) -> [GridRect] {
        guard rect.contains(cell) else { return [rect] }
        var parts: [GridRect] = []
        if cell.row > rect.rows.lowerBound {
            parts.append(GridRect(rows: rect.rows.lowerBound...(cell.row - 1), columns: rect.columns))
        }
        if cell.row < rect.rows.upperBound {
            parts.append(GridRect(rows: (cell.row + 1)...rect.rows.upperBound, columns: rect.columns))
        }
        if cell.column > rect.columns.lowerBound {
            parts.append(GridRect(rows: cell.row...cell.row, columns: rect.columns.lowerBound...(cell.column - 1)))
        }
        if cell.column < rect.columns.upperBound {
            parts.append(GridRect(rows: cell.row...cell.row, columns: (cell.column + 1)...rect.columns.upperBound))
        }
        return parts
    }
}

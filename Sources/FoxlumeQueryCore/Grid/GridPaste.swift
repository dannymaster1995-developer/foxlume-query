import Foundation

/// Clipboard text split into a block of cells.
public enum GridPasteParser {
    public enum Format: Equatable, Sendable {
        /// Tab-separated, as Foxlume, TablePro and spreadsheets copy cells.
        case tsv
        /// Comma-separated, recognized only when every line has the same number of fields (two or more lines).
        case csv
        /// One value per line.
        case lines
    }

    /// Tabs mean TSV. Without tabs, several lines with the same number of comma-separated fields mean CSV.
    /// Anything else is one column, so a single value containing a comma stays one value.
    public static func detectFormat(_ text: String) -> Format {
        if text.contains("\t") { return .tsv }
        guard text.contains(",") else { return .lines }
        let records = parse(text, separator: ",")
        guard records.count >= 2, let width = records.first?.count, width > 1, records.allSatisfy({ $0.count == width }) else {
            return .lines
        }
        return .csv
    }

    public static func parse(_ text: String) -> [[String]] {
        switch detectFormat(text) {
        case .tsv: return parse(text, separator: "\t")
        case .csv: return parse(text, separator: ",")
        case .lines: return parse(text, separator: nil)
        }
    }

    /// Records split by CR, LF or CRLF. A field that starts with a double quote may hold separators, line breaks
    /// and doubled quotes, as the grid's own copy writes them. One trailing line break is not an extra record.
    /// With no separator every line is one field.
    public static func parse(_ text: String, separator: Character?) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var quoted = false
        var fieldStarted = false
        var characters = Array(text)
        // CR LF is a single Character in Swift.
        if let last = characters.last, last == "\n" || last == "\r" || last == "\r\n" { characters.removeLast() }
        var index = 0
        func endField() {
            record.append(field)
            field = ""
            fieldStarted = false
        }
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"", !fieldStarted, separator != nil {
                quoted = true
                fieldStarted = true
            } else if let separator, character == separator {
                endField()
            } else if character == "\n" || character == "\r" || character == "\r\n" {
                endField()
                records.append(record)
                record = []
            } else {
                field.append(character)
                fieldStarted = true
            }
            index += 1
        }
        if !characters.isEmpty || !record.isEmpty {
            endField()
            records.append(record)
        }
        return records
    }
}

/// Where a pasted block lands, following TablePro: a block exactly as wide as the table is a set of new rows;
/// any other block fills cells to the right of and below the anchor, clipped at the last row and column.
public struct GridPastePlan: Equatable, Sendable {
    public struct Cell: Equatable, Sendable {
        /// Display row.
        public var row: Int
        /// Column position on screen, left to right.
        public var column: Int
        public var text: String

        public init(row: Int, column: Int, text: String) {
            self.row = row
            self.column = column
            self.text = text
        }
    }

    public var cells: [Cell] = []
    /// Whole rows to append, one field per column in table order.
    public var newRows: [[String]] = []
    /// Lines of the block below the last row, and fields past the last column, that were left out.
    public var droppedRows = 0
    public var droppedColumns = 0

    public init(cells: [Cell] = [], newRows: [[String]] = [], droppedRows: Int = 0, droppedColumns: Int = 0) {
        self.cells = cells
        self.newRows = newRows
        self.droppedRows = droppedRows
        self.droppedColumns = droppedColumns
    }

    public enum Failure: Error, Equatable {
        case empty
        /// A partial block needs a cell to start from.
        case noAnchor
    }

    /// - Parameters:
    ///   - anchor: the focused cell (display row, column position), if any.
    ///   - columnNames: in table order; a first line equal to them is a header and is skipped for new rows.
    public static func make(block: [[String]], anchor: (row: Int, column: Int)?, rowCount: Int, columnNames: [String]) -> Result<GridPastePlan, Failure> {
        let columnCount = columnNames.count
        guard let first = block.first, !first.isEmpty, columnCount > 0 else { return .failure(.empty) }
        let singleValue = block.count == 1 && first.count == 1
        if !singleValue, block.allSatisfy({ $0.count == columnCount }) {
            var rows = block
            if rows.first == columnNames { rows.removeFirst() }
            guard !rows.isEmpty else { return .failure(.empty) }
            return .success(GridPastePlan(newRows: rows))
        }
        guard let anchor, anchor.row >= 0, anchor.row < rowCount, anchor.column >= 0, anchor.column < columnCount else {
            return .failure(.noAnchor)
        }
        var plan = GridPastePlan()
        for (offset, line) in block.enumerated() {
            let row = anchor.row + offset
            guard row < rowCount else {
                plan.droppedRows = block.count - offset
                break
            }
            for (columnOffset, text) in line.enumerated() {
                let column = anchor.column + columnOffset
                guard column < columnCount else {
                    plan.droppedColumns = max(plan.droppedColumns, line.count - columnOffset)
                    break
                }
                plan.cells.append(Cell(row: row, column: column, text: text))
            }
        }
        return .success(plan)
    }

    /// The value a pasted field stands for: the word NULL is SQL NULL, anything else is text.
    public static func value(for text: String) -> CellValue {
        text == "NULL" ? .null : .text(text)
    }
}

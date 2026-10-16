import Foundation

/// The grid's "Copy As ▸ IN List" and "Copy As ▸ SQL UPDATE" texts. Values are written as SQL INSERT copy writes
/// them: numbers of numeric columns bare, everything else through the dialect's literal.
public enum SQLRowCopy {
    /// `(1, 2, 3)` or `('a', 'b')`: the values in the order given, each once, NULLs left out. Nil when no value is left.
    public static func inList(_ values: [CellValue], column: ResultColumn, dialect: SQLDialect) -> String? {
        let encoding = ExportColumn(column)
        var seen: Set<String> = []
        var literals: [String] = []
        for value in values where !value.isAbsent {
            let literal = ExportValueEncoding.sqlLiteral(value, column: encoding, dialect: dialect)
            if seen.insert(literal).inserted { literals.append(literal) }
        }
        return literals.isEmpty ? nil : "(" + literals.joined(separator: ", ") + ")"
    }

    /// One loaded grid row: the values it shows now, and the values it was loaded with, whose key finds it.
    public struct UpdateRow: Sendable {
        public var current: [CellValue]
        public var original: [CellValue]

        public init(current: [CellValue], original: [CellValue]) {
            self.current = current
            self.original = original
        }
    }

    /// Why rows of these columns cannot be copied as UPDATE statements, or nil when they can.
    public static func updateUnavailableReason(columns: [String], primaryKey: [String]) -> String? {
        if primaryKey.isEmpty {
            return "This table has no primary key, so an UPDATE could not single out one row."
        }
        if let missing = primaryKey.first(where: { !columns.contains($0) }) {
            return "The key column “\(missing)” is not among the loaded columns."
        }
        if columns.allSatisfy(primaryKey.contains) {
            return "Every column is part of the primary key, so there is nothing to set."
        }
        return nil
    }

    /// `UPDATE <table> SET <col> = <val>, … WHERE <key> = <val> [AND …];` per row. SET lists every non-key column,
    /// plus key columns whose value was edited; WHERE matches the key as it was loaded. Empty when
    /// `updateUnavailableReason` gives a reason.
    public static func updates(table: TableRef, columns: [ResultColumn], primaryKey: [String], rows: [UpdateRow], dialect: SQLDialect) -> String {
        let names = columns.map(\.name)
        guard updateUnavailableReason(columns: names, primaryKey: primaryKey) == nil else { return "" }
        let encodings = columns.map(ExportColumn.init)
        let keyIndexes = primaryKey.compactMap { names.firstIndex(of: $0) }
        let qualified = dialect.qualifiedName(table)
        func value(_ row: [CellValue], _ index: Int) -> CellValue {
            row.indices.contains(index) ? row[index] : .null
        }
        func literal(_ row: [CellValue], _ index: Int) -> String {
            ExportValueEncoding.sqlLiteral(value(row, index), column: encodings[index], dialect: dialect)
        }
        let statements = rows.map { row -> String in
            let assignments = columns.indices.filter { index in
                !keyIndexes.contains(index) || value(row.current, index) != value(row.original, index)
            }.map { index in
                "\(dialect.quoteIdentifier(names[index])) = \(literal(row.current, index))"
            }
            let condition = keyIndexes.map { index -> String in
                let name = dialect.quoteIdentifier(names[index])
                return value(row.original, index).isAbsent ? "\(name) IS NULL" : "\(name) = \(literal(row.original, index))"
            }
            return "UPDATE \(qualified) SET \(assignments.joined(separator: ", ")) WHERE \(condition.joined(separator: " AND "));"
        }
        return statements.joined(separator: "\n") + (statements.isEmpty ? "" : "\n")
    }
}

import Foundation

/// A value for a new row: either an explicit value or the column default.
public enum InsertValue: Hashable, Sendable {
    case useDefault
    case value(CellValue)
}

/// Edits made in a table grid that have not been saved yet.
public struct PendingChanges: Sendable {
    /// Row index (in the loaded page) → column index → new value.
    public private(set) var updates: [Int: [Int: CellValue]] = [:]
    public private(set) var deletions: Set<Int> = []
    public private(set) var insertions: [[InsertValue]] = []

    public init() {}

    public var isEmpty: Bool { updates.isEmpty && deletions.isEmpty && insertions.isEmpty }

    public var changeCount: Int {
        updates.values.reduce(0) { $0 + $1.count } + deletions.count + insertions.count
    }

    /// Record an edit. Setting a cell back to its original value removes the edit.
    public mutating func setValue(_ value: CellValue, row: Int, column: Int, original: CellValue) {
        var rowChanges = updates[row] ?? [:]
        if value == original {
            rowChanges.removeValue(forKey: column)
        } else {
            rowChanges[column] = value
        }
        updates[row] = rowChanges.isEmpty ? nil : rowChanges
    }

    public func value(row: Int, column: Int) -> CellValue? {
        updates[row]?[column]
    }

    public func isModified(row: Int, column: Int) -> Bool {
        updates[row]?[column] != nil
    }

    public mutating func toggleDeletion(row: Int) {
        if deletions.contains(row) {
            deletions.remove(row)
        } else {
            deletions.insert(row)
        }
    }

    public mutating func markDeleted(rows: [Int]) {
        deletions.formUnion(rows)
    }

    public mutating func addInsertion(columnCount: Int) {
        insertions.append(Array(repeating: .useDefault, count: columnCount))
    }

    public mutating func addInsertion(_ values: [InsertValue]) {
        insertions.append(values)
    }

    public mutating func setInsertValue(_ value: InsertValue, insertion: Int, column: Int) {
        guard insertions.indices.contains(insertion), insertions[insertion].indices.contains(column) else { return }
        insertions[insertion][column] = value
    }

    public mutating func removeInsertions(_ indexes: [Int]) {
        for index in indexes.sorted(by: >) where insertions.indices.contains(index) {
            insertions.remove(at: index)
        }
    }

    public mutating func reset() {
        updates = [:]
        deletions = []
        insertions = []
    }
}

public enum StatementGenerationError: Error, LocalizedError {
    case missingOriginalRow(Int)

    public var errorDescription: String? {
        switch self {
        case .missingOriginalRow(let row): return "Row \(row + 1) is no longer loaded."
        }
    }
}

/// Turns grid edits into INSERT / UPDATE / DELETE statements.
public enum SQLStatementGenerator {
    /// - Parameters:
    ///   - primaryKey: key columns used to match rows. When empty, every column's original value is matched,
    ///     and MySQL / SQLite statements are limited to one row.
    public static func statements(
        table: TableRef,
        columns: [String],
        primaryKey: [String],
        originalRows: [[CellValue]],
        changes: PendingChanges,
        dialect: SQLDialect
    ) throws -> [String] {
        let qualified = dialect.qualifiedName(table)
        var statements: [String] = []

        for row in changes.deletions.sorted() {
            guard originalRows.indices.contains(row) else { throw StatementGenerationError.missingOriginalRow(row) }
            let condition = matchCondition(row: originalRows[row], columns: columns, primaryKey: primaryKey, dialect: dialect)
            statements.append("DELETE FROM \(qualified) WHERE \(condition)\(singleRowLimit(primaryKey: primaryKey, dialect: dialect))")
        }

        for row in changes.updates.keys.sorted() where !changes.deletions.contains(row) {
            guard let rowChanges = changes.updates[row], !rowChanges.isEmpty else { continue }
            guard originalRows.indices.contains(row) else { throw StatementGenerationError.missingOriginalRow(row) }
            let assignments = rowChanges.keys.sorted().map { column in
                "\(dialect.quoteIdentifier(columns[column])) = \(dialect.literal(rowChanges[column] ?? .null))"
            }
            let condition = matchCondition(row: originalRows[row], columns: columns, primaryKey: primaryKey, dialect: dialect)
            statements.append("UPDATE \(qualified) SET \(assignments.joined(separator: ", ")) WHERE \(condition)\(singleRowLimit(primaryKey: primaryKey, dialect: dialect))")
        }

        for values in changes.insertions {
            var names: [String] = []
            var literals: [String] = []
            for (index, value) in values.enumerated() where index < columns.count {
                if case .value(let cell) = value {
                    names.append(dialect.quoteIdentifier(columns[index]))
                    literals.append(dialect.literal(cell))
                }
            }
            if names.isEmpty {
                statements.append(dialect.family == .mysql ? "INSERT INTO \(qualified) () VALUES ()" : "INSERT INTO \(qualified) DEFAULT VALUES")
            } else {
                statements.append("INSERT INTO \(qualified) (\(names.joined(separator: ", "))) VALUES (\(literals.joined(separator: ", ")))")
            }
        }
        return statements
    }

    static func matchCondition(row: [CellValue], columns: [String], primaryKey: [String], dialect: SQLDialect) -> String {
        let keyColumns = primaryKey.isEmpty ? columns : primaryKey
        return keyColumns.compactMap { name -> String? in
            guard let index = columns.firstIndex(of: name), row.indices.contains(index) else { return nil }
            let value = row[index]
            if value.isNull { return "\(dialect.quoteIdentifier(name)) IS NULL" }
            return "\(dialect.quoteIdentifier(name)) = \(dialect.literal(value))"
        }.joined(separator: " AND ")
    }

    private static func singleRowLimit(primaryKey: [String], dialect: SQLDialect) -> String {
        guard primaryKey.isEmpty else { return "" }
        // SQLite only accepts LIMIT on UPDATE/DELETE when compiled with that option, which the system library is not.
        return dialect.family == .mysql ? " LIMIT 1" : ""
    }
}

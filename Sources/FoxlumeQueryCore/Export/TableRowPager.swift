import Foundation

/// Reads one table a page at a time, so an export never holds more than one page of rows in memory.
/// The first page always carries the columns, even when the table is empty.
protocol TableRowPager: AnyObject {
    /// The next page, or nil once every row has been handed out.
    func nextPage() throws -> StatementResult?
    /// Releases server resources. Safe to call more than once.
    func close()
}

enum TableRowPagers {
    /// The cheapest correct way to walk `table` on this engine.
    /// PostgreSQL reads through a cursor, which needs the transaction the exporter opens.
    /// Other engines page with LIMIT: by primary key when there is one (each page is an index range scan),
    /// otherwise by OFFSET, ordered by rowid where the engine has one.
    static func make(connection: DatabaseConnection, item: TableExportItem, condition: String, primaryKey: [String], fetchSize: Int) throws -> TableRowPager {
        let dialect = connection.dialect
        if dialect.family == .postgresql {
            return try PostgresCursorPager(connection: connection, item: item, condition: condition, fetchSize: fetchSize)
        }
        if !primaryKey.isEmpty, !primaryKey.contains("(expression)") {
            return KeysetPager(connection: connection, item: item, condition: condition, primaryKey: primaryKey, fetchSize: fetchSize)
        }
        let byRowID = (dialect.family == .sqlite || dialect.family == .duckdb) && !item.isView
        return OffsetPager(connection: connection, item: item, condition: condition, orderByRowID: byRowID, fetchSize: fetchSize)
    }

    /// ` WHERE (condition)`, with the closing parenthesis on its own line so a trailing `--` comment stays harmless.
    static func whereClause(_ conditions: [String]) -> String {
        let parts = conditions.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "" }
        return " WHERE " + parts.map { "(\($0)\n)" }.joined(separator: " AND ")
    }

    static func firstResultSet(_ results: [StatementResult]) -> StatementResult {
        results.last { $0.hasResultSet } ?? StatementResult()
    }
}

/// PostgreSQL: DECLARE a cursor inside the export transaction and FETCH it page by page.
final class PostgresCursorPager: TableRowPager {
    private let connection: DatabaseConnection
    private let fetchSize: Int
    private var isOpen = true
    private var exhausted = false
    static let cursorName = "foxlume_export_cursor"

    init(connection: DatabaseConnection, item: TableExportItem, condition: String, fetchSize: Int) throws {
        self.connection = connection
        self.fetchSize = max(1, fetchSize)
        let dialect = connection.dialect
        var select = "SELECT * FROM \(dialect.qualifiedName(item.table))" + TableRowPagers.whereClause([condition])
        if let limit = item.rowLimit { select += " LIMIT \(max(0, limit))" }
        _ = try connection.execute("DECLARE \(Self.cursorName) NO SCROLL CURSOR FOR \(select)", rowLimit: nil)
    }

    func nextPage() throws -> StatementResult? {
        guard !exhausted else { return nil }
        let page = TableRowPagers.firstResultSet(try connection.execute("FETCH FORWARD \(fetchSize) FROM \(Self.cursorName)", rowLimit: nil))
        if page.rows.count < fetchSize { exhausted = true }
        return page
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        _ = try? connection.execute("CLOSE \(Self.cursorName)", rowLimit: nil)
    }
}

/// Pages ordered by the primary key, each starting after the last key of the previous page.
final class KeysetPager: TableRowPager {
    private let connection: DatabaseConnection
    private let item: TableExportItem
    private let condition: String
    private let primaryKey: [String]
    private let fetchSize: Int
    private var lastKey: [String]?
    private var keyIndexes: [Int]?
    private var remaining: Int?
    private var exhausted = false
    private var fellBackToOffset: OffsetPager?

    init(connection: DatabaseConnection, item: TableExportItem, condition: String, primaryKey: [String], fetchSize: Int) {
        self.connection = connection
        self.item = item
        self.condition = condition
        self.primaryKey = primaryKey
        self.fetchSize = max(1, fetchSize)
        self.remaining = item.rowLimit.map { max(0, $0) }
    }

    func nextPage() throws -> StatementResult? {
        if let fellBackToOffset { return try fellBackToOffset.nextPage() }
        guard !exhausted else { return nil }
        let dialect = connection.dialect
        let pageSize = min(fetchSize, remaining ?? fetchSize)
        var conditions = [condition]
        if let lastKey { conditions.append(Self.afterKey(primaryKey, lastKey, dialect: dialect)) }
        let order = primaryKey.map(dialect.quoteIdentifier).joined(separator: ", ")
        let sql = "SELECT * FROM \(dialect.qualifiedName(item.table))" + TableRowPagers.whereClause(conditions)
            + " ORDER BY \(order) " + dialect.limitClause(limit: max(pageSize, 1), offset: 0)
        var page = TableRowPagers.firstResultSet(try connection.execute(sql, rowLimit: nil))
        if pageSize == 0 { page.rows = [] }
        if keyIndexes == nil {
            let names = page.columns.map(\.name)
            let indexes = primaryKey.compactMap { names.firstIndex(of: $0) }
            guard indexes.count == primaryKey.count else {
                // The key columns are not in the result (unusual names); page by offset instead.
                let fallback = OffsetPager(connection: connection, item: item, condition: condition, orderByRowID: false, fetchSize: fetchSize)
                fellBackToOffset = fallback
                return try fallback.nextPage()
            }
            keyIndexes = indexes
        }
        if let remaining { self.remaining = remaining - page.rows.count }
        if page.rows.count < pageSize || self.remaining == 0 || pageSize == 0 { exhausted = true }
        if let last = page.rows.last, let keyIndexes {
            let numeric = keyIndexes.map { page.columns[$0].isNumeric }
            lastKey = zip(keyIndexes, numeric).map { index, isNumeric in
                Self.keyLiteral(last[index], numeric: isNumeric, dialect: dialect)
            }
        }
        return page
    }

    func close() {}

    /// Numbers stay numbers, so a big integer key is not compared as a floating point string.
    static func keyLiteral(_ value: CellValue, numeric: Bool, dialect: SQLDialect) -> String {
        if case .text(let text) = value, numeric, ResultExporter.isJSONNumber(text) { return text }
        return dialect.literal(value)
    }

    /// Rows after `key` in key order. MySQL gets a row comparison, which it turns into an index range;
    /// other engines get the expanded form every SQL engine understands.
    static func afterKey(_ columns: [String], _ key: [String], dialect: SQLDialect) -> String {
        let names = columns.map(dialect.quoteIdentifier)
        if names.count == 1 { return "\(names[0]) > \(key[0])" }
        if dialect.family == .mysql {
            return "(\(names.joined(separator: ", "))) > (\(key.joined(separator: ", ")))"
        }
        var alternatives: [String] = []
        for position in names.indices {
            var parts = (0..<position).map { "\(names[$0]) = \(key[$0])" }
            parts.append("\(names[position]) > \(key[position])")
            alternatives.append("(" + parts.joined(separator: " AND ") + ")")
        }
        return alternatives.joined(separator: " OR ")
    }
}

/// LIMIT / OFFSET paging, for tables without a primary key and for views.
final class OffsetPager: TableRowPager {
    private let connection: DatabaseConnection
    private let item: TableExportItem
    private let condition: String
    private let orderByRowID: Bool
    private let fetchSize: Int
    private var offset = 0
    private var exhausted = false

    init(connection: DatabaseConnection, item: TableExportItem, condition: String, orderByRowID: Bool, fetchSize: Int) {
        self.connection = connection
        self.item = item
        self.condition = condition
        self.orderByRowID = orderByRowID
        self.fetchSize = max(1, fetchSize)
    }

    func nextPage() throws -> StatementResult? {
        guard !exhausted else { return nil }
        let dialect = connection.dialect
        let remaining = item.rowLimit.map { max(0, $0 - offset) }
        let pageSize = min(fetchSize, remaining ?? fetchSize)
        var sql = "SELECT * FROM \(dialect.qualifiedName(item.table))" + TableRowPagers.whereClause([condition])
        if orderByRowID { sql += " ORDER BY rowid" }
        sql += " " + dialect.limitClause(limit: max(pageSize, 1), offset: offset)
        var page = TableRowPagers.firstResultSet(try connection.execute(sql, rowLimit: nil))
        if pageSize == 0 { page.rows = [] }
        offset += page.rows.count
        if page.rows.count < pageSize || pageSize == 0 { exhausted = true }
        return page
    }

    func close() {}
}

import Foundation

// MARK: - Definitions

/// A column as the structure editor and Create Table edit it.
public struct ColumnDefinition: Hashable, Sendable {
    public var name: String
    /// Type as written in DDL, for example `varchar(255)` or `numeric(10,2)`.
    public var dataType: String
    public var isNullable: Bool
    /// The DEFAULT clause as raw SQL (`'pending'`, `0`, `CURRENT_TIMESTAMP`), nil for none. Strings need their quotes.
    public var defaultValue: String?
    public var isPrimaryKey: Bool
    public var isAutoIncrement: Bool
    public var comment: String?
    /// Engine details shown read-only, such as MySQL `on update CURRENT_TIMESTAMP` or a PostgreSQL identity.
    public var extra: String?
    /// Kept when the column is redefined, so a type change does not reset it. Not edited in the UI.
    public var collation: String?
    /// Expression of a generated column, restated when MySQL redefines it.
    public var generationExpression: String?

    public init(
        name: String,
        dataType: String,
        isNullable: Bool = true,
        defaultValue: String? = nil,
        isPrimaryKey: Bool = false,
        isAutoIncrement: Bool = false,
        comment: String? = nil,
        extra: String? = nil,
        collation: String? = nil,
        generationExpression: String? = nil
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
        self.isAutoIncrement = isAutoIncrement
        self.comment = comment
        self.extra = extra
        self.collation = collation
        self.generationExpression = generationExpression
    }

    /// Converts what a driver read back. MySQL reports literal defaults unquoted, so they become SQL literals here
    /// and every default in a definition is raw SQL, whatever the engine.
    public init(_ info: ColumnInfo, family: SQLDialect.Family) {
        let defaultValue: String?
        switch family {
        case .mysql:
            defaultValue = ColumnDefaultSQL.mysqlExpression(raw: info.defaultValue, dataType: info.dataType, extra: info.extra)
        case .postgresql, .sqlite, .duckdb:
            defaultValue = info.defaultValue
        }
        self.init(
            name: info.name,
            dataType: info.dataType,
            isNullable: info.isNullable,
            defaultValue: defaultValue,
            isPrimaryKey: info.isPrimaryKey,
            isAutoIncrement: info.isAutoIncrement,
            comment: info.comment.flatMap { $0.isEmpty ? nil : $0 },
            extra: info.extra,
            collation: info.collation,
            generationExpression: info.generationExpression.map { $0.replacingOccurrences(of: "\\'", with: "'") }
        )
    }

    /// A row of Create Table the user has not filled in at all; it is skipped.
    public var isBlank: Bool {
        name.trimmingCharacters(in: .whitespaces).isEmpty && dataType.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// PostgreSQL identity column (`GENERATED … AS IDENTITY`).
    var isIdentity: Bool {
        extra?.uppercased().contains("AS IDENTITY") == true
    }

    /// MySQL `VIRTUAL GENERATED` / `STORED GENERATED`, or a PostgreSQL `GENERATED ALWAYS AS (…)` column.
    var isGenerated: Bool {
        generationExpression != nil
    }

    /// `STORED` or `VIRTUAL` for a generated column.
    var generationStorage: String {
        extra?.uppercased().contains("STORED") == true ? "STORED" : "VIRTUAL"
    }
}

public struct IndexDefinition: Hashable, Sendable {
    public var name: String
    /// Column names; an entry with parentheses that is not a column is an expression.
    public var columns: [String]
    public var isUnique: Bool
    /// Access method (`btree`, `gin`, `HASH`, `FULLTEXT`…); nil or empty for the engine default.
    public var method: String?
    /// PostgreSQL index owned by a UNIQUE or EXCLUDE constraint, which has to be dropped as a constraint.
    public var isConstraint: Bool

    public init(name: String, columns: [String], isUnique: Bool = false, method: String? = nil, isConstraint: Bool = false) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.method = method
        self.isConstraint = isConstraint
    }

    public init(_ info: IndexInfo) {
        self.init(name: info.name, columns: info.columns, isUnique: info.isUnique, method: info.method, isConstraint: info.isConstraint)
    }
}

/// `ON UPDATE` / `ON DELETE` choices.
public enum ReferentialAction: String, CaseIterable, Sendable {
    case noAction = "NO ACTION"
    case restrict = "RESTRICT"
    case cascade = "CASCADE"
    case setNull = "SET NULL"
    case setDefault = "SET DEFAULT"

    /// Accepts what catalogs report (`NO ACTION`, `no action`, `NO_ACTION`); unknown or missing text means NO ACTION.
    public init(catalog text: String?) {
        let normalized = (text ?? "").uppercased().replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        self = ReferentialAction(rawValue: normalized) ?? .noAction
    }

    /// InnoDB rejects SET DEFAULT, so MySQL is not offered it.
    public static func offered(for family: SQLDialect.Family) -> [ReferentialAction] {
        family == .mysql ? [.noAction, .restrict, .cascade, .setNull] : allCases
    }
}

public struct ForeignKeyDefinition: Hashable, Sendable {
    /// Empty lets the server pick a name.
    public var name: String
    public var columns: [String]
    public var referencedTable: TableRef
    public var referencedColumns: [String]
    public var onUpdate: ReferentialAction
    public var onDelete: ReferentialAction

    public init(
        name: String,
        columns: [String],
        referencedTable: TableRef,
        referencedColumns: [String],
        onUpdate: ReferentialAction = .noAction,
        onDelete: ReferentialAction = .noAction
    ) {
        self.name = name
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    public init(_ info: ForeignKeyInfo) {
        self.init(
            name: info.name,
            columns: info.columns,
            referencedTable: info.referencedTable,
            referencedColumns: info.referencedColumns,
            onUpdate: ReferentialAction(catalog: info.onUpdate),
            onDelete: ReferentialAction(catalog: info.onDelete)
        )
    }
}

/// MySQL table options offered by Create Table. Empty values are left to the server.
public struct CreateTableOptions: Hashable, Sendable {
    public var engine: String
    public var charset: String
    public var collation: String

    public init(engine: String = "", charset: String = "", collation: String = "") {
        self.engine = engine
        self.charset = charset
        self.collation = collation
    }

    public static let mysqlDefaults = CreateTableOptions(engine: "InnoDB", charset: "utf8mb4", collation: "utf8mb4_unicode_ci")
}

// MARK: - Pending edits

public enum StructureRowState: Sendable, Hashable {
    case unchanged
    case inserted
    case modified
    case deleted
}

/// One row of an editable section: what the server has (`original`, nil for a new row) and what the user wants.
public struct StructureRow<Item: Hashable & Sendable>: Hashable, Sendable, Identifiable {
    /// Stable for the life of the draft, so the UI can keep its selection across edits.
    public let id: Int
    public let original: Item?
    public var current: Item
    public var isDeleted: Bool

    public init(id: Int, original: Item?, current: Item, isDeleted: Bool = false) {
        self.id = id
        self.original = original
        self.current = current
        self.isDeleted = isDeleted
    }

    public var isNew: Bool { original == nil }
}

/// Which part of a structure a row belongs to.
public enum StructureSection: Int, Sendable, CaseIterable {
    case columns
    case indexes
    case foreignKeys
}

/// The structure of one table with the user's unsaved edits on top, as a value so undo can keep snapshots.
/// Deleting a new row removes it; deleting an existing row marks it, and deleting it again restores it.
/// Editing a row back to what the server has clears the change.
public struct StructureDraft: Hashable, Sendable {
    public var table: TableRef
    public private(set) var columns: [StructureRow<ColumnDefinition>]
    public private(set) var indexes: [StructureRow<IndexDefinition>]
    public private(set) var foreignKeys: [StructureRow<ForeignKeyDefinition>]
    public let originalComment: String?
    public var comment: String?
    /// The existing primary key constraint (`orders_pkey`, MySQL `PRIMARY`), nil when there is none.
    public let primaryKeyName: String?
    public let originalPrimaryKey: [String]
    /// The primary key index as read from the server, shown read-only in the index list.
    public let primaryIndex: IndexInfo?
    /// True for Create Table, where every row is new.
    public let isNewTable: Bool
    /// Ids of existing columns a save has to move to reach the order of `columns`; see `movedColumnIDs(_:)`.
    public private(set) var movedColumns: Set<Int> = []
    /// Ids of columns the user moved, which `movedColumnIDs(_:)` prefers to mark as moved over the ones they passed.
    private var draggedColumns: Set<Int> = []
    private var nextID: Int

    /// The draft for an existing table.
    public init(structure: TableStructure, family: SQLDialect.Family) {
        table = structure.table
        var id = 0
        func nextRowID() -> Int {
            id += 1
            return id
        }
        let primaryKey = structure.primaryKey
        columns = structure.columns.map { info in
            var definition = ColumnDefinition(info, family: family)
            definition.isPrimaryKey = primaryKey.contains(info.name)
            return StructureRow(id: nextRowID(), original: definition, current: definition)
        }
        indexes = structure.indexes.filter { !$0.isPrimary }.map { info in
            let definition = IndexDefinition(info)
            return StructureRow(id: nextRowID(), original: definition, current: definition)
        }
        foreignKeys = structure.foreignKeys.map { info in
            let definition = ForeignKeyDefinition(info)
            return StructureRow(id: nextRowID(), original: definition, current: definition)
        }
        originalComment = structure.comment.flatMap { $0.isEmpty ? nil : $0 }
        comment = originalComment
        primaryIndex = structure.indexes.first(where: \.isPrimary)
        primaryKeyName = primaryIndex?.name ?? (!primaryKey.isEmpty && family == .mysql ? "PRIMARY" : nil)
        originalPrimaryKey = primaryKey
        isNewTable = false
        nextID = id + 1
    }

    /// An empty draft for Create Table.
    public init(newTable table: TableRef) {
        self.table = table
        columns = []
        indexes = []
        foreignKeys = []
        originalComment = nil
        comment = nil
        primaryKeyName = nil
        originalPrimaryKey = []
        primaryIndex = nil
        isNewTable = true
        nextID = 1
    }

    // MARK: State

    public var hasChanges: Bool { changeCount > 0 }

    /// Rows added, changed or deleted, plus one for a changed table comment.
    public var changeCount: Int {
        let rows = StructureSection.allCases.reduce(0) { total, section in
            total + (0..<rowCount(section)).filter { state(section, row: $0) != .unchanged }.count
        }
        return rows + (commentChanged ? 1 : 0)
    }

    public var commentChanged: Bool {
        Self.normalizedComment(comment) != originalComment
    }

    /// Whether existing columns change places. New columns placed among existing ones do not count.
    public var columnOrderChanged: Bool { !movedColumns.isEmpty }

    /// Whether the row is an existing column that changes place, which makes it a changed row.
    public func isColumnMoved(row: Int) -> Bool {
        guard let item = columns[draftRow: row], !item.isDeleted, item.original != nil else { return false }
        return movedColumns.contains(item.id)
    }

    /// New columns followed by an existing column, in table order: they are added somewhere other than the end.
    public var newColumnsAmongExisting: [ColumnDefinition] {
        var result: [ColumnDefinition] = []
        var pending: [ColumnDefinition] = []
        for row in columns where !row.isDeleted && !row.current.isBlank {
            if row.isNew {
                pending.append(row.current)
            } else {
                result += pending
                pending = []
            }
        }
        return result
    }

    /// Columns that will exist after saving, in table order.
    public var resultingColumns: [ColumnDefinition] {
        columns.filter { !$0.isDeleted }.map(\.current)
    }

    /// Current name → original name, for existing columns the user renamed.
    public var columnRenames: [String: String] {
        var renames: [String: String] = [:]
        for row in columns where !row.isDeleted {
            if let original = row.original, original.name != row.current.name {
                renames[row.current.name] = original.name
            }
        }
        return renames
    }

    /// Primary key after saving. Columns already in the key keep their key order; new ones follow in table order.
    public var primaryKey: [String] {
        primaryKeyRows.map(\.current.name)
    }

    private var primaryKeyRows: [StructureRow<ColumnDefinition>] {
        let marked = columns.filter { !$0.isDeleted && $0.current.isPrimaryKey && !$0.current.isBlank }
        let originalOrder = Dictionary(originalPrimaryKey.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: [(Int, StructureRow<ColumnDefinition>)] = []
        var added: [StructureRow<ColumnDefinition>] = []
        for row in marked {
            // A renamed key column keeps its place, found under its original name.
            if let original = row.original, original.isPrimaryKey, let position = originalOrder[original.name] {
                kept.append((position, row))
            } else {
                added.append(row)
            }
        }
        return kept.sorted { $0.0 < $1.0 }.map(\.1) + added
    }

    /// Whether the key's columns or their order change, comparing rows rather than names,
    /// so renaming a key column is not a key change but replacing it with a new column of the same name is.
    public var primaryKeyChanged: Bool {
        let current = primaryKeyRows.map { row -> String in
            if let original = row.original, original.isPrimaryKey { return "existing:" + original.name }
            return "new:\(row.id)"
        }
        return current != originalPrimaryKey.map { "existing:" + $0 }
    }

    public func rowCount(_ section: StructureSection) -> Int {
        switch section {
        case .columns: return columns.count
        case .indexes: return indexes.count
        case .foreignKeys: return foreignKeys.count
        }
    }

    /// Row state for coloring and counting. An index or foreign key that only follows a column rename is unchanged.
    public func state(_ section: StructureSection, row: Int) -> StructureRowState {
        switch section {
        case .columns:
            guard let item = columns[draftRow: row] else { return .unchanged }
            if !item.isDeleted, item.original != nil, movedColumns.contains(item.id) { return .modified }
            return Self.state(item, matches: { $0 == $1 })
        case .indexes:
            guard let item = indexes[draftRow: row] else { return .unchanged }
            return Self.state(item, matches: indexMatchesOriginal)
        case .foreignKeys:
            guard let item = foreignKeys[draftRow: row] else { return .unchanged }
            return Self.state(item, matches: foreignKeyMatchesOriginal)
        }
    }

    private static func state<Item>(_ row: StructureRow<Item>, matches: (Item, Item) -> Bool) -> StructureRowState {
        if row.isDeleted { return .deleted }
        guard let original = row.original else { return .inserted }
        return matches(row.current, original) ? .unchanged : .modified
    }

    func indexMatchesOriginal(_ current: IndexDefinition, _ original: IndexDefinition) -> Bool {
        let renames = columnRenames
        var mapped = current
        mapped.columns = current.columns.map { renames[$0] ?? $0 }
        return mapped == original
    }

    func foreignKeyMatchesOriginal(_ current: ForeignKeyDefinition, _ original: ForeignKeyDefinition) -> Bool {
        let renames = columnRenames
        var mapped = current
        mapped.columns = current.columns.map { renames[$0] ?? $0 }
        // A key that points at this table follows renames on that side too.
        if current.referencedTable == table {
            mapped.referencedColumns = current.referencedColumns.map { renames[$0] ?? $0 }
        }
        return mapped == original
    }

    // MARK: Editing

    @discardableResult
    public mutating func addColumn(_ column: ColumnDefinition) -> Int {
        columns.append(StructureRow(id: takeID(), original: nil, current: column))
        return columns.count - 1
    }

    /// Moves column rows to `destination`, an index of the list before the move (0 = top, `columns.count` = bottom),
    /// keeping their order, as a table view drop does. Returns where they ended up.
    @discardableResult
    public mutating func moveColumns(_ rows: IndexSet, to destination: Int) -> Range<Int> {
        let valid = rows.filteredIndexSet { columns.indices.contains($0) }
        guard !valid.isEmpty, (0...columns.count).contains(destination) else { return 0..<0 }
        let moving = valid.map { columns[$0] }
        var remaining = columns.indices.filter { !valid.contains($0) }.map { columns[$0] }
        let start = destination - valid.count(in: 0..<destination)
        remaining.insert(contentsOf: moving, at: start)
        columns = remaining
        draggedColumns.formUnion(moving.map(\.id))
        updateMovedColumns()
        return start..<(start + moving.count)
    }

    @discardableResult
    public mutating func addIndex(_ index: IndexDefinition) -> Int {
        indexes.append(StructureRow(id: takeID(), original: nil, current: index))
        return indexes.count - 1
    }

    @discardableResult
    public mutating func addForeignKey(_ key: ForeignKeyDefinition) -> Int {
        foreignKeys.append(StructureRow(id: takeID(), original: nil, current: key))
        return foreignKeys.count - 1
    }

    /// Edits a column and keeps dependent fields consistent. Renames follow into indexes and foreign keys.
    public mutating func updateColumn(at index: Int, _ change: (inout ColumnDefinition) -> Void) {
        guard columns.indices.contains(index), !columns[index].isDeleted else { return }
        let before = columns[index].current
        var updated = before
        change(&updated)
        // Key and auto increment columns never hold NULL.
        if (updated.isPrimaryKey && !before.isPrimaryKey) || (updated.isAutoIncrement && !before.isAutoIncrement) {
            updated.isNullable = false
        }
        if updated.isPrimaryKey && updated.isNullable && !before.isNullable {
            updated.isNullable = false
        }
        // A sequence default belongs to auto increment: it goes when auto increment is switched either way.
        if updated.isAutoIncrement != before.isAutoIncrement, updated.defaultValue?.lowercased().contains("nextval(") == true {
            updated.defaultValue = nil
        }
        if updated.isAutoIncrement && !before.isAutoIncrement {
            updated.defaultValue = nil
        }
        // A NOT NULL column cannot default to NULL.
        if !updated.isNullable, before.isNullable, updated.defaultValue?.uppercased() == "NULL" {
            updated.defaultValue = nil
        }
        columns[index].current = updated
        if updated.name != before.name, !before.name.isEmpty {
            renameColumnReferences(from: before.name, to: updated.name)
        }
        updateMovedColumns()
    }

    public mutating func updateIndex(at index: Int, _ change: (inout IndexDefinition) -> Void) {
        guard indexes.indices.contains(index), !indexes[index].isDeleted else { return }
        change(&indexes[index].current)
    }

    public mutating func updateForeignKey(at index: Int, _ change: (inout ForeignKeyDefinition) -> Void) {
        guard foreignKeys.indices.contains(index), !foreignKeys[index].isDeleted else { return }
        change(&foreignKeys[index].current)
    }

    /// Deletes rows, or restores them when every existing one among them is already marked deleted.
    public mutating func toggleDeletion(_ section: StructureSection, rows: IndexSet) {
        switch section {
        case .columns:
            Self.toggleDeletion(&columns, rows: rows)
            updateMovedColumns()
        case .indexes: Self.toggleDeletion(&indexes, rows: rows)
        case .foreignKeys: Self.toggleDeletion(&foreignKeys, rows: rows)
        }
    }

    /// Restores one row to what the server has; a new row is removed. A moved column also goes back to its place.
    public mutating func revert(_ section: StructureSection, row: Int) {
        switch section {
        case .columns:
            guard let item = columns[draftRow: row] else { return }
            let currentName = item.current.name
            let wasMoved = isColumnMoved(row: row)
            Self.revert(&columns, row: row)
            if let originalName = item.original?.name, originalName != currentName, !item.isDeleted {
                renameColumnReferences(from: currentName, to: originalName)
            }
            draggedColumns.remove(item.id)
            if wasMoved {
                // Back after the nearest existing column that comes before it on the server, else to the top.
                let restored = columns.remove(at: row)
                let before = columns.lastIndex { !$0.isNew && $0.id < restored.id }
                columns.insert(restored, at: before.map { $0 + 1 } ?? 0)
            }
            updateMovedColumns()
        case .indexes: Self.revert(&indexes, row: row)
        case .foreignKeys: Self.revert(&foreignKeys, row: row)
        }
    }

    /// Restores several rows. Columns are found by id, since a moved column going back shifts the others.
    public mutating func revert(_ section: StructureSection, rows: IndexSet) {
        guard section == .columns else {
            for row in rows.sorted(by: >) { revert(section, row: row) }
            return
        }
        let ids = rows.compactMap { columns[draftRow: $0]?.id }
        for id in ids {
            if let index = columns.firstIndex(where: { $0.id == id }) { revert(.columns, row: index) }
        }
    }

    private static func toggleDeletion<Item>(_ rows: inout [StructureRow<Item>], rows selection: IndexSet) {
        let valid = selection.filter { rows.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let existing = valid.filter { !rows[$0].isNew }
        let restore = !existing.isEmpty && existing.allSatisfy { rows[$0].isDeleted }
        for index in existing {
            rows[index].isDeleted = !restore
        }
        for index in valid.filter({ rows[$0].isNew }).sorted(by: >) {
            rows.remove(at: index)
        }
    }

    private static func revert<Item>(_ rows: inout [StructureRow<Item>], row: Int) {
        guard rows.indices.contains(row) else { return }
        guard let original = rows[row].original else {
            rows.remove(at: row)
            return
        }
        rows[row].current = original
        rows[row].isDeleted = false
    }

    private mutating func renameColumnReferences(from oldName: String, to newName: String) {
        for index in indexes.indices where !indexes[index].isDeleted {
            indexes[index].current.columns = indexes[index].current.columns.map { $0 == oldName ? newName : $0 }
        }
        for index in foreignKeys.indices where !foreignKeys[index].isDeleted {
            foreignKeys[index].current.columns = foreignKeys[index].current.columns.map { $0 == oldName ? newName : $0 }
            if foreignKeys[index].current.referencedTable == table {
                foreignKeys[index].current.referencedColumns = foreignKeys[index].current.referencedColumns.map { $0 == oldName ? newName : $0 }
            }
        }
    }

    private mutating func updateMovedColumns() {
        movedColumns = Self.movedColumnIDs(columns, dragged: draggedColumns)
    }

    /// The fewest existing columns to move so the rest keep their server order: every column outside the heaviest
    /// subsequence still in server order (row ids follow the server order). A column changed anyway weighs far less,
    /// since its own MODIFY can move it at no cost; then a column the user dragged weighs a little less than one it
    /// passed, so the dragged one is marked as moved. Remaining ties keep the columns that come first on the server.
    static func movedColumnIDs(_ columns: [StructureRow<ColumnDefinition>], dragged: Set<Int> = []) -> Set<Int> {
        let rows = columns.filter { !$0.isDeleted && $0.original != nil }
        guard rows.count > 1 else { return [] }
        let weights = rows.map { row -> Int in
            guard let original = row.original else { return 0 }
            var current = row.current
            current.isPrimaryKey = original.isPrimaryKey
            return (current == original ? 1_000_000 : 0) + (dragged.contains(row.id) ? 1 : 2)
        }
        // best[i]: weight of the heaviest increasing run that starts at row i.
        var best = Array(repeating: 0, count: rows.count)
        for index in rows.indices.reversed() {
            var tail = 0
            for next in (index + 1)..<rows.count where rows[next].id > rows[index].id {
                tail = max(tail, best[next])
            }
            best[index] = weights[index] + tail
        }
        var kept = Set<Int>()
        var remaining = best.max() ?? 0
        var lastID = Int.min
        var start = 0
        while remaining > 0 {
            let candidates = (start..<rows.count).filter { rows[$0].id > lastID && best[$0] == remaining }
            guard let pick = candidates.min(by: { rows[$0].id < rows[$1].id }) else { break }
            kept.insert(rows[pick].id)
            remaining -= weights[pick]
            lastID = rows[pick].id
            start = pick + 1
        }
        return Set(rows.map(\.id)).subtracting(kept)
    }

    private mutating func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    /// Empty comments mean "no comment" on both engines.
    static func normalizedComment(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

private extension Array {
    /// A row of a draft section, nil when the index is out of range.
    subscript(draftRow index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Default values

/// Converts catalog defaults to raw SQL and back, and recognises literals.
public enum ColumnDefaultSQL {
    private static let bareKeywords: Set<String> = [
        "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME", "LOCALTIME", "LOCALTIMESTAMP", "NOW",
        "NULL", "TRUE", "FALSE", "CURRENT_USER", "SESSION_USER", "USER",
    ]

    /// MySQL's `COLUMN_DEFAULT` as SQL. Literals come back unquoted, and expression defaults are flagged
    /// `DEFAULT_GENERATED` in EXTRA with their quotes escaped by a backslash.
    static func mysqlExpression(raw: String?, dataType: String, extra: String?) -> String? {
        guard let raw else { return nil }
        if extra?.uppercased().contains("DEFAULT_GENERATED") == true {
            let expression = raw.replacingOccurrences(of: "\\'", with: "'")
            return isTimeKeyword(expression) ? expression : "(" + expression + ")"
        }
        let lowerType = dataType.lowercased()
        if lowerType.hasPrefix("bit"), raw.lowercased().hasPrefix("b'") { return raw }
        if isNumericType(lowerType), Double(raw) != nil { return raw }
        return SQLDialect.mysql.quoteString(raw)
    }

    /// The default as MySQL 8 needs it: literals and the current-time keywords stay bare; any other expression
    /// is wrapped in parentheses, which MySQL requires for expression defaults.
    static func mysqlDefaultClause(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLiteral(text) || isTimeKeyword(text) { return text }
        if text.hasPrefix("(") && text.hasSuffix(")") { return text }
        return "(" + text + ")"
    }

    /// Quoted strings, numbers, TRUE / FALSE / NULL and bit or hex literals.
    static func isLiteral(_ text: String) -> Bool {
        if Double(text) != nil { return true }
        let upper = text.uppercased()
        if ["NULL", "TRUE", "FALSE"].contains(upper) { return true }
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") { return true }
        // Charset introducers such as _utf8mb4'x', and N'x'.
        if text.hasSuffix("'"), let quote = text.firstIndex(of: "'"), quote > text.startIndex {
            let prefix = text[..<quote].lowercased()
            if ["b", "x", "n"].contains(prefix) || (prefix.hasPrefix("_") && prefix.dropFirst().allSatisfy { $0.isLetter || $0.isNumber }) {
                return true
            }
        }
        if upper.hasPrefix("0X") || upper.hasPrefix("0B") { return true }
        return false
    }

    /// CURRENT_TIMESTAMP, NOW(), LOCALTIME(3) and the like, which MySQL accepts without parentheses.
    static func isTimeKeyword(_ text: String) -> Bool {
        let upper = text.uppercased().replacingOccurrences(of: " ", with: "")
        let timeWords: Set<String> = ["CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME", "LOCALTIME", "LOCALTIMESTAMP", "NOW"]
        if timeWords.contains(upper) { return upper != "NOW" }
        guard let open = upper.firstIndex(of: "("), upper.hasSuffix(")") else { return false }
        let name = String(upper[..<open])
        let argument = upper[upper.index(after: open)..<upper.index(before: upper.endIndex)]
        return timeWords.contains(name) && argument.allSatisfy(\.isNumber)
    }

    static func isNumericType(_ lowerType: String) -> Bool {
        let base = lowerType.split(whereSeparator: { $0 == "(" || $0 == " " }).first.map(String.init) ?? lowerType
        return ["tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric", "float", "double", "real", "dec", "fixed", "bool", "boolean"].contains(base)
    }
}

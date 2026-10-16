import Foundation

public enum StructureChangeError: Error, LocalizedError, Equatable {
    /// Problems the user has to fix before anything can be generated, one sentence each.
    case incomplete([String])

    public var errorDescription: String? {
        switch self {
        case .incomplete(let problems): return problems.joined(separator: "\n")
        }
    }

    public var problems: [String] {
        switch self {
        case .incomplete(let problems): return problems
        }
    }
}

/// ALTER TABLE scripts for structure edits and CREATE TABLE scripts, for PostgreSQL and MySQL.
///
/// Statements come in this order: drop foreign keys, drop indexes, drop the primary key, drop columns, change columns,
/// add columns, add the primary key, add indexes, add foreign keys, then comments. A changed index or foreign key is
/// dropped and added again. Dropping the key before columns keeps a dropped key column from taking the constraint
/// with it before the constraint is dropped by name.
///
/// Column order: MySQL moves columns with FIRST / AFTER on their MODIFY, CHANGE or ADD clause, and every column clause
/// then goes into one ALTER TABLE. PostgreSQL cannot move columns, so the table is rebuilt first (TableRebuild.swift)
/// and the other changes follow.
public struct TableDDLGenerator: Sendable {
    public let dialect: SQLDialect

    public init(dialect: SQLDialect) {
        self.dialect = dialect
    }

    /// Only the two engines structure editing supports.
    public init?(kind: DatabaseKind) {
        switch kind {
        case .postgresql: self.init(dialect: .postgresql)
        case .mysql: self.init(dialect: .mysql)
        case .mariadb, .sqlite, .duckdb, .mongodb, .redis: return nil
        }
    }

    private var isMySQL: Bool { dialect.family == .mysql }

    /// PostgreSQL runs schema changes in a transaction; MySQL commits every DDL statement on its own.
    public var runsInTransaction: Bool { dialect.family == .postgresql }

    /// Statements joined the way the preview and the confirmation show them.
    public static func script(_ statements: [String]) -> String {
        statements.map { $0 + ";" }.joined(separator: "\n")
    }

    // MARK: - Engine vocabulary

    /// Types offered by the type picker. Any other text is accepted as typed.
    public var commonTypes: [String] {
        if isMySQL {
            return [
                "int", "bigint", "smallint", "tinyint", "tinyint(1)", "mediumint", "int unsigned", "bigint unsigned",
                "decimal(10,2)", "float", "double", "bit(1)",
                "varchar(255)", "char(36)", "text", "mediumtext", "longtext",
                "date", "datetime", "datetime(3)", "timestamp", "time", "year",
                "json", "blob", "longblob", "binary(16)", "varbinary(255)", "enum('a','b')",
            ]
        }
        return [
            "integer", "bigint", "smallint", "serial", "bigserial",
            "numeric(10,2)", "real", "double precision", "boolean",
            "varchar(255)", "char(1)", "text", "uuid",
            "date", "time", "timestamp", "timestamptz", "interval",
            "json", "jsonb", "bytea", "inet", "text[]", "integer[]",
        ]
    }

    /// Suggestions for the Default cell. Typed text is used exactly, so strings need their quotes.
    public var defaultSuggestions: [String] {
        if isMySQL {
            return ["NULL", "''", "0", "CURRENT_TIMESTAMP", "(UUID())", "(CURRENT_DATE)"]
        }
        return ["NULL", "''", "0", "CURRENT_TIMESTAMP", "now()", "CURRENT_DATE", "gen_random_uuid()", "true", "false"]
    }

    public var indexMethods: [String] {
        isMySQL ? ["BTREE", "HASH", "FULLTEXT", "SPATIAL"] : ["btree", "hash", "gin", "gist", "brin", "spgist"]
    }

    public var referentialActions: [ReferentialAction] {
        ReferentialAction.offered(for: dialect.family)
    }

    // MARK: - Validation

    /// Everything that keeps the draft from being saved, as sentences for the user. Only rows the save adds or
    /// changes are checked, so a problem the server already lives with does not block unrelated edits.
    /// `rebuild` is what a PostgreSQL reorder needs; without it a reorder is a problem.
    public func problems(_ draft: StructureDraft, rebuild: TableRebuildInfo? = nil) -> [String] {
        var problems: [String] = []
        if draft.isNewTable {
            if draft.table.name.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("Enter a name for the table.")
            }
            if !draft.columns.contains(where: { !$0.current.isBlank }) {
                problems.append("Add at least one column.")
            }
        }

        let liveColumns = draft.columns.indices.filter { !draft.columns[$0].isDeleted && !(draft.isNewTable && draft.columns[$0].current.isBlank) }
        for index in liveColumns where draft.state(.columns, row: index) != .unchanged {
            let column = draft.columns[index].current
            let label = column.name.isEmpty ? "Column \(index + 1)" : "Column “\(column.name)”"
            if column.name.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("\(label) needs a name.")
            }
            if column.dataType.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("\(label) needs a type.")
            }
            if !column.isNullable, column.defaultValue?.trimmingCharacters(in: .whitespaces).uppercased() == "NULL" {
                problems.append("\(label) is NOT NULL, so its default cannot be NULL.")
            }
            let turnsOnAutoIncrement = column.isAutoIncrement && draft.columns[index].original?.isAutoIncrement != true
            if !isMySQL, turnsOnAutoIncrement, !Self.isPostgresInteger(column.dataType) {
                problems.append("\(label): auto increment needs an integer type (smallint, integer or bigint).")
            }
        }
        problems += duplicates(liveColumns.map { draft.columns[$0].current.name }, noun: "columns")

        let names = liveColumns.map { draft.columns[$0].current.name }
        for index in draft.indexes.indices where !draft.indexes[index].isDeleted && draft.state(.indexes, row: index) != .unchanged {
            let definition = draft.indexes[index].current
            let label = definition.name.isEmpty ? "Index \(index + 1)" : "Index “\(definition.name)”"
            if definition.name.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("\(label) needs a name.")
            } else if isMySQL, definition.name.uppercased() == "PRIMARY" {
                problems.append("An index cannot be named PRIMARY. Use the Primary Key checkboxes in Columns.")
            }
            if definition.columns.isEmpty {
                problems.append("\(label) needs at least one column.")
            }
            for entry in definition.columns where indexPart(entry, columns: names) == nil {
                problems.append("\(label) uses “\(entry)”, which is not a column of the table.")
            }
        }
        problems += duplicates(draft.indexes.filter { !$0.isDeleted }.map(\.current.name), noun: "indexes")

        for index in draft.foreignKeys.indices where !draft.foreignKeys[index].isDeleted && draft.state(.foreignKeys, row: index) != .unchanged {
            let key = draft.foreignKeys[index].current
            let label = key.name.isEmpty ? "Foreign key \(index + 1)" : "Foreign key “\(key.name)”"
            if key.columns.isEmpty {
                problems.append("\(label) needs at least one column.")
            }
            if key.referencedTable.name.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("\(label) needs a referenced table.")
            }
            if key.referencedColumns.isEmpty {
                problems.append("\(label) needs referenced columns.")
            } else if !key.columns.isEmpty, key.columns.count != key.referencedColumns.count {
                problems.append("\(label) lists \(key.columns.count) column\(key.columns.count == 1 ? "" : "s") but \(key.referencedColumns.count) referenced column\(key.referencedColumns.count == 1 ? "" : "s").")
            }
            for column in key.columns where !contains(names, column) {
                problems.append("\(label) uses “\(column)”, which is not a column of the table.")
            }
            if isMySQL, key.onDelete == .setDefault || key.onUpdate == .setDefault {
                problems.append("\(label): MySQL does not support SET DEFAULT.")
            }
        }
        problems += duplicates(draft.foreignKeys.filter { !$0.isDeleted }.map(\.current.name), noun: "foreign keys")
        problems += rebuildProblems(draft, rebuild: rebuild)
        return problems
    }

    private func duplicates(_ names: [String], noun: String) -> [String] {
        var seen = Set<String>()
        var reported = Set<String>()
        var problems: [String] = []
        for name in names where !name.isEmpty {
            let key = isMySQL ? name.lowercased() : name
            if !seen.insert(key).inserted, reported.insert(key).inserted {
                problems.append("Two \(noun) are named “\(name)”.")
            }
        }
        return problems
    }

    /// MySQL compares column names without case; PostgreSQL names are quoted, so case matters.
    private func contains(_ names: [String], _ name: String) -> Bool {
        isMySQL ? names.contains { $0.caseInsensitiveCompare(name) == .orderedSame } : names.contains(name)
    }

    static func isPostgresInteger(_ type: String) -> Bool {
        let base = type.lowercased().trimmingCharacters(in: .whitespaces)
        return ["smallint", "integer", "int", "bigint", "int2", "int4", "int8", "smallserial", "serial", "bigserial", "serial2", "serial4", "serial8"].contains(base)
    }

    // MARK: - ALTER TABLE

    /// The script that turns the server's structure into the draft. Throws `StructureChangeError.incomplete` first.
    /// A PostgreSQL draft with reordered columns needs `rebuild`; its script starts with the table rebuild.
    public func alterStatements(_ draft: StructureDraft, rebuild: TableRebuildInfo? = nil) throws -> [String] {
        let problems = problems(draft, rebuild: rebuild)
        guard problems.isEmpty else { throw StructureChangeError.incomplete(problems) }
        if isMySQL { return mysqlAlter(draft) }
        if needsRebuild(draft), let rebuild {
            return rebuildStatements(draft, rebuild: rebuild) + postgresAlter(draft)
        }
        return postgresAlter(draft)
    }

    private struct SectionPlan<Item> {
        var drops: [Item] = []
        var adds: [Item] = []
    }

    private func plan<Item>(_ rows: [StructureRow<Item>], section: StructureSection, in draft: StructureDraft) -> SectionPlan<Item> {
        var plan = SectionPlan<Item>()
        for (index, row) in rows.enumerated() {
            switch draft.state(section, row: index) {
            case .unchanged: continue
            case .deleted:
                if let original = row.original { plan.drops.append(original) }
            case .modified:
                if let original = row.original { plan.drops.append(original) }
                plan.adds.append(row.current)
            case .inserted:
                plan.adds.append(row.current)
            }
        }
        return plan
    }

    private func postgresAlter(_ draft: StructureDraft) -> [String] {
        let table = dialect.qualifiedName(draft.table)
        let alter = "ALTER TABLE \(table)"
        let names = draft.resultingColumns.map(\.name)
        let indexPlan = plan(draft.indexes, section: .indexes, in: draft)
        let keyPlan = plan(draft.foreignKeys, section: .foreignKeys, in: draft)
        var statements: [String] = []
        var comments: [String] = []

        for key in keyPlan.drops {
            statements.append("\(alter) DROP CONSTRAINT \(q(key.name))")
        }
        for index in indexPlan.drops {
            if index.isConstraint {
                statements.append("\(alter) DROP CONSTRAINT \(q(index.name))")
            } else {
                statements.append("DROP INDEX \(dialect.qualifiedName(TableRef(schema: draft.table.schema, name: index.name)))")
            }
        }
        if draft.primaryKeyChanged, !draft.originalPrimaryKey.isEmpty, let name = draft.primaryKeyName {
            statements.append("\(alter) DROP CONSTRAINT \(q(name))")
        }
        for row in draft.columns where row.isDeleted {
            guard let original = row.original else { continue }
            statements.append("\(alter) DROP COLUMN \(q(original.name))")
        }
        for (index, row) in draft.columns.enumerated() where draft.state(.columns, row: index) == .modified {
            guard let original = row.original else { continue }
            statements += postgresColumnChanges(from: original, to: row.current, table: table)
            if StructureDraft.normalizedComment(row.current.comment) != StructureDraft.normalizedComment(original.comment) {
                comments.append(postgresColumnComment(row.current, table: table))
            }
        }
        for row in draft.columns where row.isNew && !row.isDeleted && !row.current.isBlank {
            statements.append("\(alter) ADD COLUMN \(postgresColumnDefinition(row.current))")
            if StructureDraft.normalizedComment(row.current.comment) != nil {
                comments.append(postgresColumnComment(row.current, table: table))
            }
        }
        if draft.primaryKeyChanged, !draft.primaryKey.isEmpty {
            statements.append("\(alter) ADD PRIMARY KEY (\(columnList(draft.primaryKey)))")
        }
        for index in indexPlan.adds {
            statements.append(postgresCreateIndex(index, table: draft.table, columns: names))
        }
        for key in keyPlan.adds {
            statements.append("\(alter) ADD \(foreignKeyClause(key))")
        }
        if draft.commentChanged {
            comments.insert("COMMENT ON TABLE \(table) IS \(commentLiteral(draft.comment))", at: 0)
        }
        return statements + comments
    }

    /// One statement per changed attribute: rename, type, identity removal, default, nullability, identity.
    private func postgresColumnChanges(from original: ColumnDefinition, to current: ColumnDefinition, table: String) -> [String] {
        var statements: [String] = []
        if current.name != original.name {
            statements.append("ALTER TABLE \(table) RENAME COLUMN \(q(original.name)) TO \(q(current.name))")
        }
        let column = "ALTER TABLE \(table) ALTER COLUMN \(q(current.name))"
        if Self.normalizedType(current.dataType) != Self.normalizedType(original.dataType) {
            // No USING clause: the server's assignment cast refuses values that do not fit instead of cutting them.
            var statement = "\(column) TYPE \(current.dataType)"
            if let collation = current.collation, Self.isPostgresText(current.dataType) {
                statement += " COLLATE \(q(collation))"
            }
            statements.append(statement)
        }
        if original.isAutoIncrement, !current.isAutoIncrement, original.isIdentity {
            statements.append("\(column) DROP IDENTITY IF EXISTS")
        }
        let newDefault = current.defaultValue.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        if newDefault != original.defaultValue {
            statements.append(newDefault.map { "\(column) SET DEFAULT \($0)" } ?? "\(column) DROP DEFAULT")
        }
        if current.isNullable != original.isNullable {
            statements.append("\(column) \(current.isNullable ? "DROP" : "SET") NOT NULL")
        }
        if current.isAutoIncrement, !original.isAutoIncrement {
            statements.append("\(column) ADD GENERATED BY DEFAULT AS IDENTITY")
            // A new identity starts at 1; move it past the rows already in the table.
            let sequence = "pg_catalog.pg_get_serial_sequence(\(dialect.quoteString(table)), \(dialect.quoteString(current.name)))"
            statements.append("SELECT pg_catalog.setval(\(sequence), COALESCE(MAX(\(q(current.name))), 0) + 1, false) FROM \(table)")
        }
        return statements
    }

    private func postgresColumnDefinition(_ column: ColumnDefinition, inlinePrimaryKey: Bool = false) -> String {
        var parts = [q(column.name)]
        if column.isAutoIncrement {
            // Auto increment is written as a serial type, which brings its own sequence, default and NOT NULL.
            parts.append(Self.serialType(for: column.dataType))
        } else {
            parts.append(column.dataType)
            if let collation = column.collation, Self.isPostgresText(column.dataType) {
                parts.append("COLLATE \(q(collation))")
            }
            if let expression = column.generationExpression {
                parts.append("GENERATED ALWAYS AS (\(expression)) STORED")
            } else if let value = column.defaultValue?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                parts.append("DEFAULT \(value)")
            }
            if !column.isNullable && !inlinePrimaryKey {
                parts.append("NOT NULL")
            }
        }
        if inlinePrimaryKey {
            parts.append("PRIMARY KEY")
        }
        return parts.joined(separator: " ")
    }

    private func postgresColumnComment(_ column: ColumnDefinition, table: String) -> String {
        "COMMENT ON COLUMN \(table).\(q(column.name)) IS \(commentLiteral(column.comment))"
    }

    private func postgresCreateIndex(_ index: IndexDefinition, table: TableRef, columns: [String]) -> String {
        var statement = "CREATE \(index.isUnique ? "UNIQUE " : "")INDEX "
        if !index.name.isEmpty { statement += q(index.name) + " " }
        statement += "ON \(dialect.qualifiedName(table))"
        if let method = index.method?.trimmingCharacters(in: .whitespaces).lowercased(), !method.isEmpty, method != "btree" {
            statement += " USING \(method)"
        }
        return statement + " (\(index.columns.compactMap { indexPart($0, columns: columns) }.joined(separator: ", ")))"
    }

    static func serialType(for type: String) -> String {
        switch type.lowercased().trimmingCharacters(in: .whitespaces) {
        case "bigint", "int8", "bigserial", "serial8": return "bigserial"
        case "smallint", "int2", "smallserial", "serial2": return "smallserial"
        default: return "serial"
        }
    }

    static func isPostgresText(_ type: String) -> Bool {
        let lower = type.lowercased()
        return ["char", "varchar", "character", "text", "citext", "name"].contains { lower.hasPrefix($0) }
    }

    /// Lower case without spaces, so `VARCHAR(10)` and `varchar (10)` count as the same type.
    static func normalizedType(_ type: String) -> String {
        type.lowercased().filter { !$0.isWhitespace }
    }

    // MARK: MySQL

    private func mysqlAlter(_ draft: StructureDraft) -> [String] {
        let table = dialect.qualifiedName(draft.table)
        let alter = "ALTER TABLE \(table)"
        let names = draft.resultingColumns.map(\.name)
        let indexPlan = plan(draft.indexes, section: .indexes, in: draft)
        let keyPlan = plan(draft.foreignKeys, section: .foreignKeys, in: draft)
        var statements: [String] = []

        for key in keyPlan.drops {
            statements.append("\(alter) DROP FOREIGN KEY \(q(key.name))")
        }
        for index in indexPlan.drops {
            statements.append("\(alter) DROP INDEX \(q(index.name))")
        }

        var columnClauses: [String] = []
        for row in draft.columns where row.isDeleted {
            guard let original = row.original else { continue }
            columnClauses.append("DROP COLUMN \(q(original.name))")
        }
        // Existing columns in their new order. A moved one goes right after the existing column before it, which is
        // already in place: MySQL applies the clauses of one statement in turn, under the names they give.
        var previousExisting: String?
        for (index, row) in draft.columns.enumerated() where !row.isDeleted {
            guard let original = row.original else { continue }
            defer { previousExisting = row.current.name }
            let position = draft.isColumnMoved(row: index) ? " " + positionClause(after: previousExisting) : ""
            // Ticking Primary Key alone changes the key, not the column.
            var unkeyed = row.current
            unkeyed.isPrimaryKey = original.isPrimaryKey
            guard unkeyed != original || !position.isEmpty else { continue }
            if original.name != row.current.name {
                columnClauses.append("CHANGE COLUMN \(q(original.name)) \(mysqlColumnDefinition(row.current))\(position)")
            } else {
                columnClauses.append("MODIFY COLUMN \(mysqlColumnDefinition(row.current))\(position)")
            }
        }
        // New columns follow in table order; one with an existing column after it goes in place.
        let placedAmongExisting = Set(draft.newColumnsAmongExisting.map(\.name))
        var previous: String?
        for row in draft.columns where !row.isDeleted && !row.current.isBlank {
            defer { previous = row.current.name }
            guard row.isNew else { continue }
            let position = placedAmongExisting.contains(row.current.name) ? " " + positionClause(after: previous) : ""
            columnClauses.append("ADD COLUMN \(mysqlColumnDefinition(row.current))\(position)")
        }
        let movesColumns = draft.columnOrderChanged || !placedAmongExisting.isEmpty
        if draft.primaryKeyChanged || movesColumns {
            // An AUTO_INCREMENT column must be a key at every step, so a key change travels with the column
            // changes in one statement, which MySQL checks as a whole. Moves do too: MySQL rebuilds the table
            // for each statement that moves a column, so one statement rebuilds it once.
            var clauses: [String] = []
            if draft.primaryKeyChanged, !draft.originalPrimaryKey.isEmpty { clauses.append("DROP PRIMARY KEY") }
            clauses += columnClauses
            if draft.primaryKeyChanged, !draft.primaryKey.isEmpty { clauses.append("ADD PRIMARY KEY (\(columnList(draft.primaryKey)))") }
            statements.append(clauses.count == 1 ? "\(alter) \(clauses[0])" : "\(alter)\n    " + clauses.joined(separator: ",\n    "))
        } else {
            statements += columnClauses.map { "\(alter) \($0)" }
        }

        for index in indexPlan.adds {
            statements.append("\(alter) ADD \(mysqlIndexClause(index, columns: names))")
        }
        for key in keyPlan.adds {
            statements.append("\(alter) ADD \(foreignKeyClause(key))")
        }
        if draft.commentChanged {
            statements.append("\(alter) COMMENT = \(dialect.quoteString(draft.comment ?? ""))")
        }
        return statements
    }

    /// `FIRST`, or `AFTER` the named column.
    private func positionClause(after column: String?) -> String {
        column.map { "AFTER \(q($0))" } ?? "FIRST"
    }

    /// The whole column definition, which MODIFY / CHANGE COLUMN and ADD COLUMN need restated in full.
    func mysqlColumnDefinition(_ column: ColumnDefinition) -> String {
        var parts = [q(column.name), column.dataType]
        if let collation = column.collation, !column.dataType.lowercased().contains("collate") {
            parts.append("COLLATE \(collation)")
        }
        if let expression = column.generationExpression {
            parts.append("GENERATED ALWAYS AS (\(expression)) \(column.generationStorage)")
            parts.append(column.isNullable ? "NULL" : "NOT NULL")
        } else {
            parts.append(column.isNullable ? "NULL" : "NOT NULL")
            if let value = column.defaultValue?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                parts.append("DEFAULT \(ColumnDefaultSQL.mysqlDefaultClause(value))")
            }
            if column.isAutoIncrement {
                parts.append("AUTO_INCREMENT")
            }
            if let onUpdate = Self.mysqlOnUpdate(column.extra) {
                parts.append(onUpdate)
            }
        }
        if let comment = StructureDraft.normalizedComment(column.comment) {
            parts.append("COMMENT \(dialect.quoteString(comment))")
        }
        return parts.joined(separator: " ")
    }

    /// `ON UPDATE CURRENT_TIMESTAMP[(n)]` from MySQL's EXTRA column.
    static func mysqlOnUpdate(_ extra: String?) -> String? {
        guard let extra, let range = extra.range(of: #"on update current_timestamp(\(\d*\))?"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return extra[range].uppercased()
    }

    private func mysqlIndexClause(_ index: IndexDefinition, columns: [String], inline: Bool = false) -> String {
        let method = index.method?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        let kind: String
        switch method {
        case "FULLTEXT": kind = "FULLTEXT "
        case "SPATIAL": kind = "SPATIAL "
        default: kind = index.isUnique ? "UNIQUE " : ""
        }
        var clause = "\(kind)\(inline ? "KEY" : "INDEX") \(q(index.name)) (\(index.columns.compactMap { indexPart($0, columns: columns) }.joined(separator: ", ")))"
        if method == "HASH" { clause += " USING HASH" }
        return clause
    }

    // MARK: Shared pieces

    private func foreignKeyClause(_ key: ForeignKeyDefinition) -> String {
        var clause = key.name.isEmpty ? "" : "CONSTRAINT \(q(key.name)) "
        clause += "FOREIGN KEY (\(columnList(key.columns))) REFERENCES \(dialect.qualifiedName(key.referencedTable)) (\(columnList(key.referencedColumns)))"
        if key.onDelete != .noAction { clause += " ON DELETE \(key.onDelete.rawValue)" }
        if key.onUpdate != .noAction { clause += " ON UPDATE \(key.onUpdate.rawValue)" }
        return clause
    }

    /// A column of an index: a quoted column name, a MySQL prefix (`name(10)`), or an expression in parentheses.
    /// Nil when the entry is neither a column nor something that looks like an expression.
    func indexPart(_ entry: String, columns: [String]) -> String? {
        let text = entry.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let match = columns.first(where: { isMySQL ? $0.caseInsensitiveCompare(text) == .orderedSame : $0 == text }) {
            return q(match)
        }
        if isMySQL, let open = text.firstIndex(of: "("), text.hasSuffix(")") {
            let name = String(text[..<open])
            let length = text[text.index(after: open)..<text.index(before: text.endIndex)]
            if !length.isEmpty, length.allSatisfy(\.isNumber), let match = columns.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                return "\(q(match))(\(length))"
            }
        }
        guard text.contains("(") else { return nil }
        return text.hasPrefix("(") && text.hasSuffix(")") ? text : "(\(text))"
    }

    private func q(_ identifier: String) -> String {
        dialect.quoteIdentifier(identifier)
    }

    private func columnList(_ names: [String]) -> String {
        names.map(q).joined(separator: ", ")
    }

    private func commentLiteral(_ comment: String?) -> String {
        StructureDraft.normalizedComment(comment).map(dialect.quoteString) ?? "NULL"
    }

    // MARK: - CREATE TABLE

    /// The script for Create Table. Blank column rows are skipped. Throws `StructureChangeError.incomplete` first.
    public func createStatements(_ draft: StructureDraft, options: CreateTableOptions = CreateTableOptions()) throws -> [String] {
        let problems = problems(draft)
        guard problems.isEmpty else { throw StructureChangeError.incomplete(problems) }
        let columns = draft.columns.filter { !$0.isDeleted && !$0.current.isBlank }.map(\.current)
        let indexes = draft.indexes.filter { !$0.isDeleted }.map(\.current)
        let keys = draft.foreignKeys.filter { !$0.isDeleted }.map(\.current)
        var primaryKey = draft.primaryKey
        // MySQL needs an AUTO_INCREMENT column to be a key; with no key chosen it becomes the primary key.
        if isMySQL, primaryKey.isEmpty, let auto = columns.first(where: \.isAutoIncrement) {
            primaryKey = [auto.name]
        }
        return isMySQL
            ? mysqlCreate(draft, columns: columns, primaryKey: primaryKey, indexes: indexes, keys: keys, options: options)
            : postgresCreate(draft, columns: columns, primaryKey: primaryKey, indexes: indexes, keys: keys)
    }

    private func postgresCreate(_ draft: StructureDraft, columns: [ColumnDefinition], primaryKey: [String], indexes: [IndexDefinition], keys: [ForeignKeyDefinition]) -> [String] {
        let table = dialect.qualifiedName(draft.table)
        let inlineKey = primaryKey.count == 1 ? primaryKey.first : nil
        var lines = columns.map { "    " + postgresColumnDefinition($0, inlinePrimaryKey: $0.name == inlineKey) }
        if primaryKey.count > 1 {
            lines.append("    PRIMARY KEY (\(columnList(primaryKey)))")
        }
        lines += keys.map { "    " + foreignKeyClause($0) }
        var statements = ["CREATE TABLE \(table) (\n" + lines.joined(separator: ",\n") + "\n)"]
        let names = columns.map(\.name)
        statements += indexes.map { postgresCreateIndex($0, table: draft.table, columns: names) }
        if let comment = StructureDraft.normalizedComment(draft.comment) {
            statements.append("COMMENT ON TABLE \(table) IS \(dialect.quoteString(comment))")
        }
        for column in columns where StructureDraft.normalizedComment(column.comment) != nil {
            statements.append(postgresColumnComment(column, table: table))
        }
        return statements
    }

    private func mysqlCreate(_ draft: StructureDraft, columns: [ColumnDefinition], primaryKey: [String], indexes: [IndexDefinition], keys: [ForeignKeyDefinition], options: CreateTableOptions) -> [String] {
        let names = columns.map(\.name)
        var lines = columns.map { "    " + mysqlColumnDefinition($0) }
        if !primaryKey.isEmpty {
            lines.append("    PRIMARY KEY (\(columnList(primaryKey)))")
        }
        lines += indexes.map { "    " + mysqlIndexClause($0, columns: names, inline: true) }
        lines += keys.map { "    " + foreignKeyClause($0) }
        var statement = "CREATE TABLE \(dialect.qualifiedName(draft.table)) (\n" + lines.joined(separator: ",\n") + "\n)"
        var tableOptions: [String] = []
        let engine = options.engine.trimmingCharacters(in: .whitespaces)
        let charset = options.charset.trimmingCharacters(in: .whitespaces)
        let collation = options.collation.trimmingCharacters(in: .whitespaces)
        if !engine.isEmpty { tableOptions.append("ENGINE=\(engine)") }
        if !charset.isEmpty { tableOptions.append("DEFAULT CHARSET=\(charset)") }
        if !collation.isEmpty { tableOptions.append("COLLATE=\(collation)") }
        if let comment = StructureDraft.normalizedComment(draft.comment) { tableOptions.append("COMMENT=\(dialect.quoteString(comment))") }
        if !tableOptions.isEmpty { statement += " " + tableOptions.joined(separator: " ") }
        return [statement]
    }
}

// MARK: - Running a script

/// A schema script stopped at one statement.
public struct SchemaScriptError: Error, LocalizedError {
    public let statement: String
    /// 1-based position of the failing statement.
    public let position: Int
    public let total: Int
    /// True when the whole script was undone (PostgreSQL); false when earlier statements stay applied (MySQL).
    public let rolledBack: Bool
    public let underlying: Error

    public var errorDescription: String? {
        var text = underlying.localizedDescription
        if total > 1 {
            text += "\n\nStatement \(position) of \(total) failed:\n\(statement)"
            if rolledBack {
                text += "\n\nNothing was changed; the whole script was rolled back."
            } else if position == 2 {
                text += "\n\nThe statement before it stays applied, because MySQL commits each schema change on its own."
            } else if position > 2 {
                text += "\n\nThe \(position - 1) statements before it stay applied, because MySQL commits each schema change on its own."
            }
        }
        return text
    }
}

extension DatabaseConnection {
    /// Runs schema statements in order and stops at the first failure. With `transactional`, they run inside one
    /// transaction that is rolled back on failure.
    public func applySchemaStatements(_ statements: [String], transactional: Bool) throws {
        guard !statements.isEmpty else { return }
        if transactional {
            _ = try execute(dialect.beginStatement, rowLimit: nil)
        }
        for (index, statement) in statements.enumerated() {
            do {
                _ = try execute(statement, rowLimit: nil)
            } catch {
                if transactional { _ = try? execute("ROLLBACK", rowLimit: nil) }
                throw SchemaScriptError(statement: statement, position: index + 1, total: statements.count, rolledBack: transactional, underlying: error)
            }
        }
        if transactional {
            do {
                _ = try execute("COMMIT", rowLimit: nil)
            } catch {
                _ = try? execute("ROLLBACK", rowLimit: nil)
                throw error
            }
        }
    }
}

extension DatabaseSession {
    /// Runs a schema script as one session job, so nothing queued meanwhile lands inside its transaction.
    public func applySchemaStatements(_ statements: [String], transactional: Bool) async throws {
        try await run { try $0.applySchemaStatements(statements, transactional: transactional) }
    }
}

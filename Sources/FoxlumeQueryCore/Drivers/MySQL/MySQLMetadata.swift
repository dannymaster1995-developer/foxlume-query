import Foundation

/// Catalog queries. MySQL has no schemas below the database, so `TableRef.schema`, when set, names a database.
/// Result columns are read by position because MySQL and MariaDB disagree on the case of column names.
extension MySQLConnection {
    public func databases() throws -> [String] {
        try rows("SHOW DATABASES").compactMap { Self.string($0.first) }
    }

    public func schemas() throws -> [String] { [] }

    public var defaultSchema: String? { nil }

    public func tables(schema: String?) throws -> [TableInfo] {
        let rows = try rows("""
            SELECT TABLE_NAME, TABLE_TYPE, TABLE_ROWS, TABLE_COMMENT
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = \(databaseExpression(schema))
            """)
        let tableSchema = schema.flatMap { $0.isEmpty ? nil : $0 }
        let tables: [TableInfo] = rows.compactMap { row in
            guard let name = Self.cell(row, 0) else { return nil }
            let kind: TableKind
            switch Self.cell(row, 1)?.uppercased() {
            case "VIEW": kind = .view
            case "SYSTEM VIEW": kind = .systemTable
            default: kind = .table
            }
            var comment = Self.cell(row, 3)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if comment?.isEmpty == true || (kind == .view && comment == "VIEW") { comment = nil }
            return TableInfo(
                ref: TableRef(schema: tableSchema, name: name),
                kind: kind,
                estimatedRows: Self.cell(row, 2).flatMap { Int($0) },
                comment: comment
            )
        }
        return tables.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func structure(of table: TableRef) throws -> TableStructure {
        let dialect = self.dialect
        let database = databaseExpression(table.schema)
        let tableName = dialect.quoteString(table.name)
        let filter = "TABLE_SCHEMA = \(database) AND TABLE_NAME = \(tableName)"

        // Views report the word VIEW as their comment.
        let tableRow = try rows("SELECT TABLE_COMMENT, TABLE_TYPE, TABLE_COLLATION FROM information_schema.TABLES WHERE \(filter)").first
        let isView = tableRow.flatMap { Self.cell($0, 1) }?.uppercased() == "VIEW"
        let tableComment = isView ? nil : tableRow.flatMap { Self.cell($0, 0) }
        let tableCollation = tableRow.flatMap { Self.cell($0, 2) }

        let columnRows = try rows("""
            SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY, EXTRA, COLUMN_COMMENT,
                   COLLATION_NAME, GENERATION_EXPRESSION
            FROM information_schema.COLUMNS
            WHERE \(filter)
            ORDER BY ORDINAL_POSITION
            """)
        let columns: [ColumnInfo] = columnRows.compactMap { row in
            guard let name = Self.cell(row, 0) else { return nil }
            let extra = Self.cell(row, 5)?.trimmingCharacters(in: .whitespaces) ?? ""
            let comment = Self.cell(row, 6) ?? ""
            let collation = Self.cell(row, 7)
            let generation = Self.cell(row, 8) ?? ""
            return ColumnInfo(
                name: name,
                dataType: Self.cell(row, 1) ?? "",
                isNullable: Self.cell(row, 2)?.uppercased() == "YES",
                defaultValue: normalizedDefault(Self.cell(row, 3)),
                isPrimaryKey: Self.cell(row, 4)?.uppercased() == "PRI",
                isAutoIncrement: extra.range(of: "auto_increment", options: .caseInsensitive) != nil,
                comment: comment.isEmpty ? nil : comment,
                extra: extra.isEmpty ? nil : extra,
                collation: collation == tableCollation ? nil : collation,
                generationExpression: generation.isEmpty ? nil : generation
            )
        }

        let indexRows = try rows("""
            SELECT INDEX_NAME, COLUMN_NAME, NON_UNIQUE, INDEX_TYPE
            FROM information_schema.STATISTICS
            WHERE \(filter)
            ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX
            """)
        var indexes: [IndexInfo] = []
        var indexPositions: [String: Int] = [:]
        for row in indexRows {
            guard let name = Self.cell(row, 0) else { continue }
            // Functional key parts (MySQL 8) have no column name.
            let column = Self.cell(row, 1) ?? "(expression)"
            if let position = indexPositions[name] {
                indexes[position].columns.append(column)
                continue
            }
            indexPositions[name] = indexes.count
            let method = Self.cell(row, 3) ?? ""
            indexes.append(IndexInfo(
                name: name,
                columns: [column],
                isUnique: Self.cell(row, 2) == "0",
                isPrimary: name == "PRIMARY",
                method: method.isEmpty ? nil : method
            ))
        }

        let foreignKeyRows = try rows("""
            SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME,
                   k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE
            FROM information_schema.KEY_COLUMN_USAGE k
            JOIN information_schema.REFERENTIAL_CONSTRAINTS r
              ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA
             AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
             AND r.TABLE_NAME = k.TABLE_NAME
            WHERE k.TABLE_SCHEMA = \(database) AND k.TABLE_NAME = \(tableName)
              AND k.REFERENCED_TABLE_NAME IS NOT NULL
            ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION
            """)
        let owningDatabase = table.schema ?? currentDatabase
        var foreignKeys: [ForeignKeyInfo] = []
        var foreignKeyPositions: [String: Int] = [:]
        for row in foreignKeyRows {
            guard let name = Self.cell(row, 0), let column = Self.cell(row, 1) else { continue }
            let referencedColumn = Self.cell(row, 4) ?? ""
            if let position = foreignKeyPositions[name] {
                foreignKeys[position].columns.append(column)
                foreignKeys[position].referencedColumns.append(referencedColumn)
                continue
            }
            let referencedDatabase = Self.cell(row, 2)
            foreignKeyPositions[name] = foreignKeys.count
            foreignKeys.append(ForeignKeyInfo(
                name: name,
                columns: [column],
                referencedTable: TableRef(
                    schema: referencedDatabase == owningDatabase ? table.schema : referencedDatabase,
                    name: Self.cell(row, 3) ?? ""
                ),
                referencedColumns: [referencedColumn],
                onUpdate: Self.cell(row, 5),
                onDelete: Self.cell(row, 6)
            ))
        }

        return TableStructure(table: table, columns: columns, indexes: indexes, foreignKeys: foreignKeys, comment: tableComment?.isEmpty == false ? tableComment : nil)
    }

    /// `SHOW CREATE TABLE` returns `CREATE VIEW` for views; either way the statement is the second column.
    public func ddl(of table: TableRef) throws -> String {
        let rows = try rows("SHOW CREATE TABLE \(dialect.qualifiedName(table))")
        guard let statement = rows.first.flatMap({ Self.cell($0, 1) }) else {
            throw DatabaseError.server(message: "The server returned no definition for \(table.name).", code: nil)
        }
        return statement + ";"
    }

    // MARK: - Helpers

    private func rows(_ sql: String) throws -> [[CellValue]] {
        try runQuery(sql, rowLimit: nil).first?.rows ?? []
    }

    /// The database to filter catalog tables by: the named one, or the session's current database.
    private func databaseExpression(_ database: String?) -> String {
        guard let database, !database.isEmpty else { return "DATABASE()" }
        return dialect.quoteString(database)
    }

    private static func cell(_ row: [CellValue], _ index: Int) -> String? {
        guard index < row.count else { return nil }
        return string(row[index])
    }

    /// MariaDB 10.2.7+ reports defaults as SQL literals: `NULL` for none and quoted strings.
    private func normalizedDefault(_ raw: String?) -> String? {
        guard let raw, isMariaDB else { return raw }
        if raw == "NULL" { return nil }
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }
}

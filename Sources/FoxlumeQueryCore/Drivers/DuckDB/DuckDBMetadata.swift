import Foundation

/// Catalog queries over DuckDB's `duckdb_*()` table functions, scoped to the current database.
/// List columns are joined with a unit separator in SQL so names containing commas or brackets survive.
extension DuckDBConnection {
    public func databases() throws -> [String] {
        try rows("SELECT database_name FROM duckdb_databases() WHERE NOT internal ORDER BY database_name")
            .compactMap { $0.first?.textValue }
    }

    public var currentDatabase: String? {
        (try? rows("SELECT current_database()"))?.first?.first?.textValue
    }

    public func useDatabase(_ name: String) throws {
        _ = try execute("USE \(dialect.quoteIdentifier(name))", rowLimit: nil)
    }

    public func schemas() throws -> [String] {
        try rows("""
            SELECT schema_name FROM duckdb_schemas()
            WHERE database_name = current_database() AND schema_name NOT IN ('information_schema', 'pg_catalog')
            ORDER BY schema_name
            """).compactMap { $0.first?.textValue }
    }

    public var defaultSchema: String? {
        (try? rows("SELECT current_schema()"))?.first?.first?.textValue
    }

    public func tables(schema: String?) throws -> [TableInfo] {
        let schemaFilter = schemaExpression(schema)
        let rows = try rows("""
            SELECT schema_name, table_name, 'table', estimated_size, comment FROM duckdb_tables()
            WHERE database_name = current_database() AND schema_name = \(schemaFilter)
            UNION ALL
            SELECT schema_name, view_name, 'view', NULL, comment FROM duckdb_views()
            WHERE database_name = current_database() AND schema_name = \(schemaFilter) AND NOT internal
            ORDER BY 2
            """)
        return rows.compactMap { row in
            guard let schemaName = Self.cell(row, 0), let name = Self.cell(row, 1) else { return nil }
            return TableInfo(
                ref: TableRef(schema: schemaName, name: name),
                kind: Self.cell(row, 2) == "view" ? .view : .table,
                estimatedRows: Self.cell(row, 3).flatMap { Int($0) },
                comment: Self.cell(row, 4).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    public func structure(of table: TableRef) throws -> TableStructure {
        let filter = "database_name = current_database() AND schema_name = \(schemaExpression(table.schema)) AND table_name = \(dialect.quoteString(table.name))"
        let columnRows = try rows("""
            SELECT column_name, data_type, is_nullable, column_default, comment FROM duckdb_columns()
            WHERE \(filter) ORDER BY column_index
            """)
        let constraintRows = try rows("""
            SELECT constraint_type, constraint_name, array_to_string(constraint_column_names, chr(31)),
                   referenced_table, array_to_string(referenced_column_names, chr(31))
            FROM duckdb_constraints()
            WHERE \(filter) AND constraint_type IN ('PRIMARY KEY', 'UNIQUE', 'FOREIGN KEY')
            ORDER BY constraint_index
            """)

        var indexes: [IndexInfo] = []
        var foreignKeys: [ForeignKeyInfo] = []
        for row in constraintRows {
            let columns = Self.list(row, 2)
            switch Self.cell(row, 0) {
            case "PRIMARY KEY":
                indexes.insert(IndexInfo(name: Self.cell(row, 1) ?? "PRIMARY", columns: columns, isUnique: true, isPrimary: true), at: 0)
            case "UNIQUE":
                indexes.append(IndexInfo(name: Self.cell(row, 1) ?? "unique", columns: columns, isUnique: true, isPrimary: false))
            default:
                // DuckDB keeps foreign keys within one schema, so the referenced table shares the table's schema.
                foreignKeys.append(ForeignKeyInfo(
                    name: Self.cell(row, 1) ?? "fk_\(table.name)_\(foreignKeys.count)",
                    columns: columns,
                    referencedTable: TableRef(schema: table.schema, name: Self.cell(row, 3) ?? ""),
                    referencedColumns: Self.list(row, 4)
                ))
            }
        }
        let indexRows = try rows("""
            SELECT index_name, is_unique, is_primary, expressions FROM duckdb_indexes()
            WHERE \(filter) ORDER BY index_name
            """)
        for row in indexRows {
            indexes.append(IndexInfo(
                name: Self.cell(row, 0) ?? "",
                columns: Self.indexExpressions(Self.cell(row, 3) ?? ""),
                isUnique: Self.cell(row, 1) == "true",
                isPrimary: Self.cell(row, 2) == "true",
                method: "art"
            ))
        }

        let primaryKey = Set(indexes.first(where: \.isPrimary)?.columns ?? [])
        let columns = columnRows.map { row -> ColumnInfo in
            let name = Self.cell(row, 0) ?? ""
            let defaultValue = Self.cell(row, 3)
            return ColumnInfo(
                name: name,
                dataType: Self.cell(row, 1) ?? "",
                isNullable: Self.cell(row, 2) != "false",
                defaultValue: defaultValue,
                isPrimaryKey: primaryKey.contains(name),
                isAutoIncrement: defaultValue?.lowercased().hasPrefix("nextval(") == true,
                comment: Self.cell(row, 4).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        return TableStructure(table: table, columns: columns, indexes: indexes, foreignKeys: foreignKeys)
    }

    public func ddl(of table: TableRef) throws -> String {
        let filter = "database_name = current_database() AND schema_name = \(schemaExpression(table.schema))"
        let name = dialect.quoteString(table.name)
        let statements = try rows("""
            SELECT sql, 0 FROM duckdb_tables() WHERE \(filter) AND table_name = \(name)
            UNION ALL SELECT sql, 0 FROM duckdb_views() WHERE \(filter) AND view_name = \(name)
            UNION ALL SELECT sql, 1 FROM duckdb_indexes() WHERE \(filter) AND table_name = \(name) AND sql IS NOT NULL
            ORDER BY 2
            """).compactMap { Self.cell($0, 0) }
        return statements
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.hasSuffix(";") ? $0 : $0 + ";" }
            .joined(separator: "\n\n")
    }

    // MARK: - Helpers

    func rows(_ sql: String) throws -> [[CellValue]] {
        try execute(sql, rowLimit: nil).last?.rows ?? []
    }

    func schemaExpression(_ schema: String?) -> String {
        guard let schema, !schema.isEmpty else { return "current_schema()" }
        return dialect.quoteString(schema)
    }

    static func cell(_ row: [CellValue], _ index: Int) -> String? {
        guard row.indices.contains(index) else { return nil }
        return row[index].textValue
    }

    /// `duckdb_indexes().expressions` is the text of a VARCHAR list, for example `[user_id, '((ua + 1))']`,
    /// where DuckDB quotes elements with special characters and escapes quotes with a backslash.
    static func indexExpressions(_ text: String) -> [String] {
        var body = Substring(text.trimmingCharacters(in: .whitespaces))
        guard body.hasPrefix("["), body.hasSuffix("]") else { return text.isEmpty ? [] : [text] }
        body = body.dropFirst().dropLast()
        var items: [String] = []
        var current = ""
        var quoted = false
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if quoted {
                if character == "\\", body.index(after: index) < body.endIndex {
                    index = body.index(after: index)
                    current.append(body[index])
                } else if character == "'" {
                    quoted = false
                } else {
                    current.append(character)
                }
            } else if character == "'" {
                quoted = true
            } else if character == "," {
                items.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            index = body.index(after: index)
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !items.isEmpty { items.append(last) }
        return items
    }

    static func list(_ row: [CellValue], _ index: Int) -> [String] {
        guard let joined = cell(row, index), !joined.isEmpty else { return [] }
        return joined.components(separatedBy: "\u{1F}")
    }
}

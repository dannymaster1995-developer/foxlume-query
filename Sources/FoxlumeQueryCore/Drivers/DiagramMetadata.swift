import Foundation

/// Gathers catalog rows for a whole schema into one `TableStructure` per table, for the ER diagram: three queries
/// (columns, unique keys, foreign keys) instead of three per table. Table, key and foreign key order follow the rows,
/// which every query sorts.
struct DiagramStructureAssembler {
    private var order: [String] = []
    private var columns: [String: [ColumnInfo]] = [:]
    private var indexes: [String: [IndexInfo]] = [:]
    private var foreignKeys: [String: [ForeignKeyInfo]] = [:]
    /// Unique keys with an expression or partial part, which say nothing about a column set.
    private var unusableIndexes: Set<String> = []
    let schema: String?

    init(schema: String?) {
        self.schema = schema
    }

    mutating func addColumn(table: String, name: String, type: String, nullable: Bool, primaryKey: Bool) {
        if columns[table] == nil {
            order.append(table)
            columns[table] = []
        }
        columns[table]?.append(ColumnInfo(name: name, dataType: type, isNullable: nullable, isPrimaryKey: primaryKey))
    }

    /// One key column of a unique or primary index; nil column for an expression part.
    mutating func addIndexColumn(table: String, index: String, column: String?, isPrimary: Bool) {
        let key = "\(table)\u{0}\(index)"
        guard let column else {
            unusableIndexes.insert(key)
            return
        }
        var list = indexes[table] ?? []
        if let last = list.indices.last, list[last].name == index {
            list[last].columns.append(column)
        } else {
            list.append(IndexInfo(name: index, columns: [column], isUnique: true, isPrimary: isPrimary))
        }
        indexes[table] = list
    }

    mutating func addForeignKeyColumn(table: String, name: String, column: String, referencedTable: TableRef, referencedColumn: String, onUpdate: String?, onDelete: String?) {
        var list = foreignKeys[table] ?? []
        if let last = list.indices.last, list[last].name == name {
            list[last].columns.append(column)
            list[last].referencedColumns.append(referencedColumn)
        } else {
            list.append(ForeignKeyInfo(name: name, columns: [column], referencedTable: referencedTable, referencedColumns: [referencedColumn], onUpdate: onUpdate, onDelete: onDelete))
        }
        foreignKeys[table] = list
    }

    var structures: [TableStructure] {
        order.map { table in
            let usable = (indexes[table] ?? []).filter { !unusableIndexes.contains("\(table)\u{0}\($0.name)") }
            let primary = Set(usable.first(where: \.isPrimary)?.columns ?? [])
            var tableColumns = columns[table] ?? []
            if !primary.isEmpty {
                for index in tableColumns.indices where primary.contains(tableColumns[index].name) {
                    tableColumns[index].isPrimaryKey = true
                }
            }
            return TableStructure(table: TableRef(schema: schema, name: table), columns: tableColumns, indexes: usable, foreignKeys: foreignKeys[table] ?? [])
        }
    }
}

extension PostgresConnection {
    public func diagramStructures(schema: String?) throws -> [TableStructure]? {
        let schemaName = schema ?? defaultSchema ?? "public"
        let literal = dialect.quoteString(schemaName)
        var assembler = DiagramStructureAssembler(schema: schemaName)
        let columnRows = try rows("""
            SELECT c.relname, a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod), a.attnotnull
            FROM pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(literal) AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
              AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY c.relname, a.attnum
            """)
        for row in columnRows {
            guard row.count >= 4, let table = row[0].textValue, let name = row[1].textValue else { continue }
            assembler.addColumn(table: table, name: name, type: row[2].textValue ?? "", nullable: row[3].textValue != "t", primaryKey: false)
        }

        // Key columns only (INCLUDE columns are not part of a key from PostgreSQL 11); partial indexes are no
        // uniqueness guarantee for the column set and are left out.
        let keyCount = serverVersionNumber >= 110_000 ? "i.indnkeyatts" : "i.indnatts"
        let indexRows = try rows("""
            SELECT c.relname, ic.relname, i.indisprimary, a.attname
            FROM pg_catalog.pg_index i
            JOIN pg_catalog.pg_class c ON c.oid = i.indrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
            CROSS JOIN LATERAL pg_catalog.generate_series(1, \(keyCount)::integer) AS k(n)
            LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[k.n - 1] AND i.indkey[k.n - 1] <> 0
            WHERE n.nspname = \(literal) AND (i.indisunique OR i.indisprimary) AND i.indpred IS NULL
            ORDER BY c.relname, i.indisprimary DESC, ic.relname, k.n
            """)
        for row in indexRows {
            guard row.count >= 4, let table = row[0].textValue, let index = row[1].textValue else { continue }
            assembler.addIndexColumn(table: table, index: index, column: row[3].textValue, isPrimary: row[2].textValue == "t")
        }

        let keyRows = try rows("""
            SELECT c.relname, con.conname, a.attname, rn.nspname, rc.relname, ra.attname, con.confupdtype, con.confdeltype
            FROM pg_catalog.pg_constraint con
            JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_catalog.pg_class rc ON rc.oid = con.confrelid
            JOIN pg_catalog.pg_namespace rn ON rn.oid = rc.relnamespace
            CROSS JOIN LATERAL ROWS FROM (pg_catalog.unnest(con.conkey), pg_catalog.unnest(con.confkey))
                WITH ORDINALITY AS k(attnum, refnum, ord)
            JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
            JOIN pg_catalog.pg_attribute ra ON ra.attrelid = con.confrelid AND ra.attnum = k.refnum
            WHERE n.nspname = \(literal) AND con.contype = 'f'
            ORDER BY c.relname, con.conname, k.ord
            """)
        for row in keyRows {
            guard row.count >= 8, let table = row[0].textValue, let name = row[1].textValue,
                  let column = row[2].textValue, let referenced = row[4].textValue, let referencedColumn = row[5].textValue
            else { continue }
            assembler.addForeignKeyColumn(table: table, name: name, column: column,
                                          referencedTable: TableRef(schema: row[3].textValue, name: referenced),
                                          referencedColumn: referencedColumn,
                                          onUpdate: Self.referentialAction(row[6].textValue),
                                          onDelete: Self.referentialAction(row[7].textValue))
        }
        return assembler.structures
    }
}

extension MySQLConnection {
    /// `schema` names a database; nil is the current one, and table references then carry no database, as the
    /// sidebar's do.
    public func diagramStructures(schema: String?) throws -> [TableStructure]? {
        let tableSchema = schema.flatMap { $0.isEmpty ? nil : $0 }
        let database = databaseExpression(tableSchema)
        let owningDatabase = tableSchema ?? currentDatabase
        var assembler = DiagramStructureAssembler(schema: tableSchema)
        let columnRows = try rows("""
            SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = \(database)
            ORDER BY TABLE_NAME, ORDINAL_POSITION
            """)
        for row in columnRows {
            guard let table = Self.cell(row, 0), let name = Self.cell(row, 1) else { continue }
            assembler.addColumn(table: table, name: name, type: Self.cell(row, 2) ?? "",
                                nullable: Self.cell(row, 3)?.uppercased() == "YES",
                                primaryKey: Self.cell(row, 4)?.uppercased() == "PRI")
        }

        let indexRows = try rows("""
            SELECT TABLE_NAME, INDEX_NAME, COLUMN_NAME
            FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = \(database) AND NON_UNIQUE = 0
            ORDER BY TABLE_NAME, INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX
            """)
        for row in indexRows {
            guard let table = Self.cell(row, 0), let index = Self.cell(row, 1) else { continue }
            // Functional key parts (MySQL 8) have no column name.
            assembler.addIndexColumn(table: table, index: index, column: Self.cell(row, 2), isPrimary: index == "PRIMARY")
        }

        let keyRows = try rows("""
            SELECT k.TABLE_NAME, k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME,
                   k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE
            FROM information_schema.KEY_COLUMN_USAGE k
            JOIN information_schema.REFERENTIAL_CONSTRAINTS r
              ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA
             AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
             AND r.TABLE_NAME = k.TABLE_NAME
            WHERE k.TABLE_SCHEMA = \(database) AND k.REFERENCED_TABLE_NAME IS NOT NULL
            ORDER BY k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION
            """)
        for row in keyRows {
            guard let table = Self.cell(row, 0), let name = Self.cell(row, 1), let column = Self.cell(row, 2),
                  let referenced = Self.cell(row, 4)
            else { continue }
            let referencedDatabase = Self.cell(row, 3)
            assembler.addForeignKeyColumn(table: table, name: name, column: column,
                                          referencedTable: TableRef(schema: referencedDatabase == owningDatabase ? tableSchema : referencedDatabase, name: referenced),
                                          referencedColumn: Self.cell(row, 5) ?? "",
                                          onUpdate: Self.cell(row, 6), onDelete: Self.cell(row, 7))
        }
        return assembler.structures
    }
}

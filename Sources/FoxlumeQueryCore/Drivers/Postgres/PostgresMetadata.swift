import Foundation

/// Catalog queries. Every name reaches SQL as a string literal through `dialect.quoteString`, never spliced in raw;
/// OIDs are spliced as integers parsed from the server's own answer.
extension PostgresConnection {
    struct Relation {
        var oid: UInt32
        var schema: String
        var name: String
        /// `pg_class.relkind`: r table, p partitioned table, v view, m materialized view, f foreign table.
        var kind: String
        var comment: String?

        var ref: TableRef { TableRef(schema: schema, name: name) }
    }

    public func schemas() throws -> [String] {
        try rows("""
            SELECT nspname FROM pg_catalog.pg_namespace
            WHERE nspname NOT IN ('pg_catalog', 'information_schema') AND nspname !~ '^pg_(toast|temp_)'
            ORDER BY nspname
            """).compactMap { $0.first?.textValue }
    }

    public func tables(schema: String?) throws -> [TableInfo] {
        let schemaName = schema ?? defaultSchema ?? "public"
        let sql = """
            SELECT c.relname, c.relkind,
                   CASE WHEN c.reltuples < 0 THEN NULL ELSE c.reltuples::bigint END,
                   pg_catalog.obj_description(c.oid, 'pg_class')
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(dialect.quoteString(schemaName)) AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
            ORDER BY c.relname
            """
        return try rows(sql).compactMap { row in
            guard row.count >= 4, let name = row[0].textValue else { return nil }
            return TableInfo(
                ref: TableRef(schema: schemaName, name: name),
                kind: Self.tableKind(row[1].textValue ?? "r"),
                estimatedRows: row[2].textValue.flatMap { Int($0) },
                comment: row[3].textValue
            )
        }
    }

    private static func tableKind(_ relkind: String) -> TableKind {
        switch relkind {
        case "v": return .view
        case "m": return .materializedView
        case "f": return .foreignTable
        default: return .table
        }
    }

    /// Resolve a table reference to its OID. Without a schema, the search path decides, as it would in a query.
    func relation(_ table: TableRef) throws -> Relation {
        let dialect = self.dialect
        var condition = "c.relname = \(dialect.quoteString(table.name))"
        if let schema = table.schema, !schema.isEmpty {
            condition += " AND n.nspname = \(dialect.quoteString(schema))"
        } else {
            condition += " AND pg_catalog.pg_table_is_visible(c.oid)"
        }
        let sql = """
            SELECT c.oid, n.nspname, c.relname, c.relkind, pg_catalog.obj_description(c.oid, 'pg_class')
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE \(condition) AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
            """
        guard let row = try rows(sql).first, row.count >= 5,
              let oid = row[0].textValue.flatMap({ UInt32($0) }),
              let schema = row[1].textValue,
              let name = row[2].textValue
        else {
            throw DatabaseError.server(message: "relation \(dialect.qualifiedName(table)) does not exist", code: "42P01")
        }
        return Relation(oid: oid, schema: schema, name: name, kind: row[3].textValue ?? "r", comment: row[4].textValue)
    }

    // MARK: - Structure

    public func structure(of table: TableRef) throws -> TableStructure {
        try structure(of: try relation(table))
    }

    func structure(of relation: Relation) throws -> TableStructure {
        // attidentity arrived in PostgreSQL 10 and attgenerated in 12.
        let identity = serverVersionNumber >= 100_000 ? "a.attidentity" : "''"
        let generated = serverVersionNumber >= 120_000 ? "a.attgenerated" : "''"
        let columnRows = try rows("""
            SELECT a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod), a.attnotnull,
                   pg_catalog.pg_get_expr(d.adbin, d.adrelid), pg_catalog.col_description(a.attrelid, a.attnum),
                   \(identity), \(generated),
                   CASE WHEN a.attcollation <> 0 AND a.attcollation <> t.typcollation THEN co.collname END,
                   CASE WHEN t.typtype = 'e' THEN (SELECT json_agg(e.enumlabel ORDER BY e.enumsortorder)
                                                   FROM pg_catalog.pg_enum e WHERE e.enumtypid = t.oid) END
            FROM pg_catalog.pg_attribute a
            LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            LEFT JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
            LEFT JOIN pg_catalog.pg_collation co ON co.oid = a.attcollation
            WHERE a.attrelid = \(relation.oid) AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """)

        let isView = relation.kind == "v"
        let indexes = isView ? [] : try indexes(of: relation)
        let foreignKeys = isView ? [] : try foreignKeys(of: relation)
        let primaryColumns = Set(indexes.first(where: \.isPrimary)?.columns ?? [])

        let columns = columnRows.compactMap { row -> ColumnInfo? in
            guard row.count >= 7, let name = row[0].textValue else { return nil }
            let expression = row[3].textValue
            let identityKind = row[5].textValue ?? ""
            let generatedKind = row[6].textValue ?? ""
            var defaultValue = expression
            var extra: String?
            var generationExpression: String?
            switch identityKind {
            case "a": extra = "GENERATED ALWAYS AS IDENTITY"
            case "d": extra = "GENERATED BY DEFAULT AS IDENTITY"
            default: break
            }
            if !generatedKind.isEmpty, let expression {
                // For generated columns pg_attrdef holds the generation expression, not a default.
                extra = "GENERATED ALWAYS AS (\(expression)) \(generatedKind == "v" ? "VIRTUAL" : "STORED")"
                generationExpression = expression
                defaultValue = nil
            }
            return ColumnInfo(
                name: name,
                dataType: row[1].textValue ?? "",
                isNullable: row[2].textValue != "t",
                defaultValue: defaultValue,
                isPrimaryKey: primaryColumns.contains(name),
                isAutoIncrement: !identityKind.isEmpty || (defaultValue?.contains("nextval(") ?? false),
                comment: row[4].textValue,
                extra: extra,
                collation: row.count > 7 ? row[7].textValue : nil,
                generationExpression: generationExpression,
                enumValues: row.count > 8 ? Self.enumLabels(row[8].textValue) : nil
            )
        }
        return TableStructure(table: relation.ref, columns: columns, indexes: indexes, foreignKeys: foreignKeys, comment: relation.comment)
    }

    /// One row per index key column, grouped here so the key order survives. Expression keys use their text.
    /// The JSON array of labels the structure query returns for an enum column.
    static func enumLabels(_ json: String?) -> [String]? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    private func indexes(of relation: Relation) throws -> [IndexInfo] {
        // INCLUDE columns (PostgreSQL 11+) are not part of the key.
        let keyCount = serverVersionNumber >= 110_000 ? "i.indnkeyatts" : "i.indnatts"
        let indexRows = try rows("""
            SELECT ic.relname, i.indisunique, i.indisprimary, am.amname,
                   CASE WHEN i.indkey[k.n - 1] <> 0 THEN a.attname
                        ELSE pg_catalog.pg_get_indexdef(i.indexrelid, k.n, true) END,
                   EXISTS (SELECT 1 FROM pg_catalog.pg_constraint con
                           WHERE con.conindid = i.indexrelid AND con.conrelid = i.indrelid AND con.contype IN ('u', 'x'))
            FROM pg_catalog.pg_index i
            JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
            JOIN pg_catalog.pg_am am ON am.oid = ic.relam
            CROSS JOIN LATERAL pg_catalog.generate_series(1, \(keyCount)::integer) AS k(n)
            LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[k.n - 1]
            WHERE i.indrelid = \(relation.oid)
            ORDER BY i.indisprimary DESC, ic.relname, k.n
            """)
        var indexes: [IndexInfo] = []
        for row in indexRows {
            guard row.count >= 5, let name = row[0].textValue else { continue }
            let column = row[4].textValue ?? ""
            if let last = indexes.indices.last, indexes[last].name == name {
                indexes[last].columns.append(column)
            } else {
                indexes.append(IndexInfo(
                    name: name,
                    columns: [column],
                    isUnique: row[1].textValue == "t",
                    isPrimary: row[2].textValue == "t",
                    method: row[3].textValue,
                    isConstraint: row.count > 5 && row[5].textValue == "t"
                ))
            }
        }
        return indexes
    }

    private func foreignKeys(of relation: Relation) throws -> [ForeignKeyInfo] {
        let keyRows = try rows("""
            SELECT con.conname, rn.nspname, rc.relname, con.confupdtype, con.confdeltype, a.attname, ra.attname
            FROM pg_catalog.pg_constraint con
            JOIN pg_catalog.pg_class rc ON rc.oid = con.confrelid
            JOIN pg_catalog.pg_namespace rn ON rn.oid = rc.relnamespace
            CROSS JOIN LATERAL ROWS FROM (pg_catalog.unnest(con.conkey), pg_catalog.unnest(con.confkey))
                WITH ORDINALITY AS k(attnum, refnum, ord)
            JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
            JOIN pg_catalog.pg_attribute ra ON ra.attrelid = con.confrelid AND ra.attnum = k.refnum
            WHERE con.conrelid = \(relation.oid) AND con.contype = 'f'
            ORDER BY con.conname, k.ord
            """)
        var keys: [ForeignKeyInfo] = []
        for row in keyRows {
            guard row.count >= 7, let name = row[0].textValue,
                  let column = row[5].textValue, let referencedColumn = row[6].textValue
            else { continue }
            if let last = keys.indices.last, keys[last].name == name {
                keys[last].columns.append(column)
                keys[last].referencedColumns.append(referencedColumn)
            } else {
                keys.append(ForeignKeyInfo(
                    name: name,
                    columns: [column],
                    referencedTable: TableRef(schema: row[1].textValue, name: row[2].textValue ?? ""),
                    referencedColumns: [referencedColumn],
                    onUpdate: Self.referentialAction(row[3].textValue),
                    onDelete: Self.referentialAction(row[4].textValue)
                ))
            }
        }
        return keys
    }

    static func referentialAction(_ code: String?) -> String? {
        switch code {
        case "a": return "NO ACTION"
        case "r": return "RESTRICT"
        case "c": return "CASCADE"
        case "n": return "SET NULL"
        case "d": return "SET DEFAULT"
        default: return nil
        }
    }

    // MARK: - DDL

    public func ddl(of table: TableRef) throws -> String {
        let relation = try relation(table)
        switch relation.kind {
        case "v", "m":
            return try viewDDL(relation)
        default:
            return try tableDDL(relation)
        }
    }

    private func viewDDL(_ relation: Relation) throws -> String {
        let parts = try viewParts(relation)
        var blocks = [parts.create + ";"]
        if !parts.indexes.isEmpty { blocks.append(parts.indexes.joined(separator: "\n")) }
        if !parts.comments.isEmpty { blocks.append(parts.comments.joined(separator: "\n")) }
        return blocks.joined(separator: "\n\n")
    }

    public func viewDefinition(of view: TableRef) throws -> ViewDefinition {
        let relation = try relation(view)
        guard relation.kind == "v" || relation.kind == "m" else {
            throw DatabaseError.unsupported("\(dialect.qualifiedName(relation.ref)) is not a view.")
        }
        let parts = try viewParts(relation)
        return ViewDefinition(view: relation.ref, isMaterialized: relation.kind == "m", statement: parts.create, attachedStatements: parts.comments + parts.indexes)
    }

    /// The CREATE statement with the view's options (`security_barrier`, `check_option`, a materialized view's storage
    /// parameters) and WITH NO DATA for an unpopulated materialized view, then its indexes and comments.
    private func viewParts(_ relation: Relation) throws -> (create: String, indexes: [String], comments: [String]) {
        let isMaterialized = relation.kind == "m"
        let objectType = isMaterialized ? "MATERIALIZED VIEW" : "VIEW"
        let row = try rows("""
            SELECT pg_catalog.pg_get_viewdef(c.oid, true), pg_catalog.array_to_string(c.reloptions, ', '), c.relispopulated
            FROM pg_catalog.pg_class c WHERE c.oid = \(relation.oid)
            """).first ?? []
        var body = (row.first?.textValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix(";") { body.removeLast() }
        let options = row.count > 1 ? (row[1].textValue ?? "") : ""
        let populated = row.count > 2 ? row[2].textValue != "f" : true

        var create = "CREATE \(objectType) \(dialect.qualifiedName(relation.ref))"
        if !options.isEmpty { create += " WITH (\(options))" }
        create += " AS\n\(body)"
        if isMaterialized, !populated { create += "\nWITH NO DATA" }
        let indexes = isMaterialized ? try otherIndexDefinitions(relation) : []
        let columns = try structure(of: relation).columns
        return (create, indexes, commentStatements(relation, objectType: objectType, columns: columns))
    }

    private func tableDDL(_ relation: Relation) throws -> String {
        let dialect = self.dialect
        let structure = try structure(of: relation)
        let quote = dialect.quoteIdentifier
        let columnList: ([String]) -> String = { $0.map(quote).joined(separator: ", ") }

        var lines = structure.columns.map { column -> String in
            var line = "    \(quote(column.name)) \(column.dataType)"
            if let extra = column.extra { line += " " + extra }
            if let defaultValue = column.defaultValue { line += " DEFAULT " + defaultValue }
            if !column.isNullable { line += " NOT NULL" }
            return line
        }
        if let primary = structure.indexes.first(where: \.isPrimary) {
            lines.append("    CONSTRAINT \(quote(primary.name)) PRIMARY KEY (\(columnList(primary.columns)))")
        }
        for key in structure.foreignKeys {
            var line = "    CONSTRAINT \(quote(key.name)) FOREIGN KEY (\(columnList(key.columns))) "
                + "REFERENCES \(dialect.qualifiedName(key.referencedTable)) (\(columnList(key.referencedColumns)))"
            if let onUpdate = key.onUpdate, onUpdate != "NO ACTION" { line += " ON UPDATE " + onUpdate }
            if let onDelete = key.onDelete, onDelete != "NO ACTION" { line += " ON DELETE " + onDelete }
            lines.append(line)
        }
        // UNIQUE, CHECK and EXCLUDE constraints keep the server's own rendering.
        let otherConstraints = try rows("""
            SELECT conname, pg_catalog.pg_get_constraintdef(oid, true)
            FROM pg_catalog.pg_constraint
            WHERE conrelid = \(relation.oid) AND contype IN ('u', 'c', 'x')
            ORDER BY CASE contype WHEN 'u' THEN 0 WHEN 'c' THEN 1 ELSE 2 END, conname
            """)
        for row in otherConstraints {
            guard row.count >= 2, let name = row[0].textValue, let definition = row[1].textValue else { continue }
            lines.append("    CONSTRAINT \(quote(name)) \(definition)")
        }

        let isForeign = relation.kind == "f"
        var create = "CREATE \(isForeign ? "FOREIGN " : "")TABLE \(dialect.qualifiedName(relation.ref)) (\n"
            + lines.joined(separator: ",\n") + "\n)"
        if relation.kind == "p",
           let key = try rows("SELECT pg_catalog.pg_get_partkeydef(\(relation.oid)::pg_catalog.oid)").first?.first?.textValue {
            create += " PARTITION BY " + key
        }
        if isForeign,
           let server = try rows("""
               SELECT s.srvname FROM pg_catalog.pg_foreign_table ft
               JOIN pg_catalog.pg_foreign_server s ON s.oid = ft.ftserver
               WHERE ft.ftrelid = \(relation.oid)
               """).first?.first?.textValue {
            create += " SERVER " + quote(server)
        }

        var blocks = [create + ";"]
        let indexStatements = try otherIndexDefinitions(relation)
        if !indexStatements.isEmpty { blocks.append(indexStatements.joined(separator: "\n")) }
        let comments = commentStatements(relation, objectType: isForeign ? "FOREIGN TABLE" : "TABLE", columns: structure.columns)
        if !comments.isEmpty { blocks.append(comments.joined(separator: "\n")) }
        return blocks.joined(separator: "\n\n")
    }

    /// Indexes not created by a PRIMARY KEY, UNIQUE or EXCLUDE constraint, which the table body already declares.
    private func otherIndexDefinitions(_ relation: Relation) throws -> [String] {
        try rows("""
            SELECT pg_catalog.pg_get_indexdef(i.indexrelid)
            FROM pg_catalog.pg_index i
            JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
            WHERE i.indrelid = \(relation.oid)
              AND NOT EXISTS (
                SELECT 1 FROM pg_catalog.pg_constraint con
                WHERE con.conindid = i.indexrelid AND con.conrelid = i.indrelid AND con.contype IN ('p', 'u', 'x'))
            ORDER BY ic.relname
            """).compactMap { $0.first?.textValue.map { $0 + ";" } }
    }

    private func commentStatements(_ relation: Relation, objectType: String, columns: [ColumnInfo]) -> [String] {
        let dialect = self.dialect
        let name = dialect.qualifiedName(relation.ref)
        var statements: [String] = []
        if let comment = relation.comment {
            statements.append("COMMENT ON \(objectType) \(name) IS \(dialect.quoteString(comment));")
        }
        for column in columns {
            guard let comment = column.comment else { continue }
            statements.append("COMMENT ON COLUMN \(name).\(dialect.quoteIdentifier(column.name)) IS \(dialect.quoteString(comment));")
        }
        return statements
    }
}

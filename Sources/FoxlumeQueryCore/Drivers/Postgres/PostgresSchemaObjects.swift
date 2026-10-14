import Foundation

/// Procedures, functions, triggers and types of one schema, and the triggers and CHECK constraints of one table.
/// Names reach SQL as string literals through `dialect.quoteString`; OIDs are integers parsed from the server's answers.
extension PostgresConnection {
    public func schemaObjects(_ kind: SchemaObjectKind, schema: String?) throws -> [SchemaObject] {
        let schemaName = schema ?? defaultSchema ?? "public"
        switch kind {
        case .function, .procedure: return try routines(kind, schema: schemaName)
        case .trigger: return try triggerObjects(schema: schemaName)
        case .type: return try userTypes(schema: schemaName)
        }
    }

    /// Extension members (pg_depend deptype 'e') are left out, as are aggregates and window functions, which
    /// pg_get_functiondef cannot print. Procedures exist from PostgreSQL 11.
    private func routines(_ kind: SchemaObjectKind, schema: String) throws -> [SchemaObject] {
        let hasProkind = serverVersionNumber >= 110_000
        let kindFilter: String
        if hasProkind {
            kindFilter = "p.prokind = '\(kind == .procedure ? "p" : "f")'"
        } else {
            guard kind == .function else { return [] }
            kindFilter = "NOT p.proisagg AND NOT p.proiswindow"
        }
        let sql = """
            SELECT p.oid, p.proname, pg_catalog.pg_get_function_identity_arguments(p.oid),
                   pg_catalog.oidvectortypes(p.proargtypes), pg_catalog.pg_get_function_result(p.oid), l.lanname,
                   p.provolatile, p.prosecdef, pg_catalog.pg_get_userbyid(p.proowner), pg_catalog.obj_description(p.oid, 'pg_proc')
            FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            JOIN pg_catalog.pg_language l ON l.oid = p.prolang
            WHERE n.nspname = \(dialect.quoteString(schema)) AND \(kindFilter)
              AND NOT EXISTS (
                SELECT 1 FROM pg_catalog.pg_depend d
                WHERE d.classid = 'pg_catalog.pg_proc'::pg_catalog.regclass AND d.objid = p.oid AND d.deptype = 'e')
            ORDER BY p.proname, 3
            """
        return try rows(sql).compactMap { row in
            guard row.count >= 10, let name = row[1].textValue else { return nil }
            var attributes: [SchemaObjectAttribute] = []
            switch row[6].textValue {
            case "i": attributes.append(.init("Volatility", "IMMUTABLE"))
            case "s": attributes.append(.init("Volatility", "STABLE"))
            case "v": attributes.append(.init("Volatility", "VOLATILE"))
            default: break
            }
            attributes.append(.init("Security", row[7].textValue == "t" ? "DEFINER" : "INVOKER"))
            if let owner = row[8].textValue { attributes.append(.init("Owner", owner)) }
            if let comment = row[9].textValue, !comment.isEmpty { attributes.append(.init("Comment", comment)) }
            return SchemaObject(
                kind: kind,
                schema: schema,
                name: name,
                arguments: row[2].textValue ?? "",
                identityArguments: row[3].textValue ?? "",
                returnType: kind == .function ? row[4].textValue : nil,
                detail: row[5].textValue,
                attributes: attributes,
                oid: row[0].textValue
            )
        }
    }

    /// Triggers of the schema's tables, or of one table (by OID), without the internal ones behind foreign keys.
    private func triggerRows(_ condition: String) throws -> [[CellValue]] {
        try rows("""
            SELECT t.oid, t.tgname, n.nspname, c.relname, t.tgtype, t.tgenabled, pg_catalog.pg_get_triggerdef(t.oid),
                   t.tgfoid::pg_catalog.regprocedure::text
            FROM pg_catalog.pg_trigger t
            JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE \(condition) AND NOT t.tgisinternal
            ORDER BY c.relname, t.tgname
            """)
    }

    private func triggerObjects(schema: String) throws -> [SchemaObject] {
        try triggerRows("n.nspname = \(dialect.quoteString(schema))").compactMap { row in
            guard row.count >= 8, let info = Self.triggerInfo(row), let table = row[3].textValue else { return nil }
            var attributes = [
                SchemaObjectAttribute("Timing", info.timing),
                SchemaObjectAttribute("Event", info.events.joined(separator: " OR ")),
                SchemaObjectAttribute("Level", info.orientation),
            ]
            if let enabled = info.isEnabled { attributes.append(.init("Enabled", enabled ? "YES" : "NO")) }
            attributes.append(.init("Function", info.action))
            return SchemaObject(kind: .trigger, schema: row[2].textValue ?? schema, name: info.name, table: table,
                                detail: "\(info.timing) \(info.events.joined(separator: " OR "))", attributes: attributes, oid: row[0].textValue)
        }
    }

    /// Decodes `tgtype`: bit 0 row-level, bit 1 BEFORE, bit 6 INSTEAD OF; bits 2–5 INSERT, DELETE, UPDATE, TRUNCATE.
    static func triggerInfo(_ row: [CellValue]) -> TriggerInfo? {
        guard row.count >= 8, let name = row[1].textValue, let type = row[4].textValue.flatMap({ Int($0) }) else { return nil }
        let timing = type & 64 != 0 ? "INSTEAD OF" : type & 2 != 0 ? "BEFORE" : "AFTER"
        var events: [String] = []
        if type & 4 != 0 { events.append("INSERT") }
        if type & 16 != 0 { events.append("UPDATE") }
        if type & 8 != 0 { events.append("DELETE") }
        if type & 32 != 0 { events.append("TRUNCATE") }
        let definition = row[6].textValue
        var condition: String?
        if let definition, let range = definition.range(of: #" WHEN \((.*)\) EXECUTE "#, options: .regularExpression) {
            condition = String(definition[range]).replacingOccurrences(of: #"^ WHEN \((.*)\) EXECUTE $"#, with: "$1", options: .regularExpression)
        }
        return TriggerInfo(
            name: name,
            timing: timing,
            events: events,
            orientation: type & 1 != 0 ? "ROW" : "STATEMENT",
            condition: condition,
            action: row[7].textValue ?? "",
            isEnabled: row[5].textValue != "D",
            definition: definition
        )
    }

    /// Enums, standalone composites, domains and ranges; table row types, arrays, multiranges and extension types are not
    /// listed.
    private func userTypes(schema: String) throws -> [SchemaObject] {
        let sql = """
            SELECT t.oid, t.typname, t.typtype, pg_catalog.pg_get_userbyid(t.typowner), pg_catalog.obj_description(t.oid, 'pg_type')
            FROM pg_catalog.pg_type t
            JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
            LEFT JOIN pg_catalog.pg_class c ON c.oid = t.typrelid
            WHERE n.nspname = \(dialect.quoteString(schema)) AND t.typtype IN ('e', 'c', 'd', 'r')
              AND (t.typtype <> 'c' OR c.relkind = 'c')
              AND NOT EXISTS (
                SELECT 1 FROM pg_catalog.pg_depend d
                WHERE d.classid = 'pg_catalog.pg_type'::pg_catalog.regclass AND d.objid = t.oid AND d.deptype = 'e')
            ORDER BY t.typname
            """
        return try rows(sql).compactMap { row in
            guard row.count >= 5, let name = row[1].textValue else { return nil }
            var attributes: [SchemaObjectAttribute] = []
            if let owner = row[3].textValue { attributes.append(.init("Owner", owner)) }
            if let comment = row[4].textValue, !comment.isEmpty { attributes.append(.init("Comment", comment)) }
            return SchemaObject(kind: .type, schema: schema, name: name, detail: Self.typeKind(row[2].textValue), attributes: attributes, oid: row[0].textValue)
        }
    }

    static func typeKind(_ typtype: String?) -> String {
        switch typtype {
        case "e": return "enum"
        case "c": return "composite"
        case "d": return "domain"
        case "r": return "range"
        default: return "type"
        }
    }

    // MARK: - Definitions

    public func definition(of object: SchemaObject) throws -> SchemaObjectDefinition {
        let schema = object.schema ?? defaultSchema ?? "public"
        switch object.kind {
        case .function, .procedure:
            // By name and argument types rather than OID, so a tab reopened after a re-create still finds it.
            let signature = dialect.quoteIdentifier(schema) + "." + dialect.quoteIdentifier(object.name) + "(\(object.identityArguments ?? ""))"
            let text = try rows("SELECT pg_catalog.pg_get_functiondef(\(dialect.quoteString(signature))::pg_catalog.regprocedure)").first?.first?.textValue
            guard let text else { throw notFound(object) }
            return SchemaObjectDefinition(statement: text)
        case .trigger:
            guard let table = object.table else { throw notFound(object) }
            let row = try rows("""
                SELECT pg_catalog.pg_get_triggerdef(t.oid), t.tgconstraint <> 0,
                       CASE WHEN fn.nspname <> 'pg_catalog' THEN pg_catalog.pg_get_functiondef(t.tgfoid) END
                FROM pg_catalog.pg_trigger t
                JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
                JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                JOIN pg_catalog.pg_proc p ON p.oid = t.tgfoid
                JOIN pg_catalog.pg_namespace fn ON fn.oid = p.pronamespace
                WHERE n.nspname = \(dialect.quoteString(schema)) AND c.relname = \(dialect.quoteString(table))
                  AND t.tgname = \(dialect.quoteString(object.name))
                """).first
            guard let row, row.count >= 3, let statement = row[0].textValue else { throw notFound(object) }
            return SchemaObjectDefinition(
                statement: statement,
                triggerFunction: row[2].textValue,
                isConstraintTrigger: row[1].textValue == "t",
                canReplaceTrigger: serverVersionNumber >= 140_000
            )
        case .type:
            return SchemaObjectDefinition(statement: try typeDefinition(object, schema: schema))
        }
    }

    private func notFound(_ object: SchemaObject) -> DatabaseError {
        .server(message: "\(object.kind.label) \(object.qualifiedSignature) does not exist", code: "42704")
    }

    /// PostgreSQL has no function that prints CREATE TYPE, so the statement is rebuilt from the catalog.
    private func typeDefinition(_ object: SchemaObject, schema: String) throws -> String {
        guard let row = try rows("""
            SELECT t.oid, t.typtype, t.typrelid, pg_catalog.format_type(t.typbasetype, t.typtypmod), t.typnotnull, t.typdefault,
                   pg_catalog.obj_description(t.oid, 'pg_type')
            FROM pg_catalog.pg_type t
            JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
            WHERE n.nspname = \(dialect.quoteString(schema)) AND t.typname = \(dialect.quoteString(object.name))
            """).first, row.count >= 7, let oid = row[0].textValue.flatMap({ UInt32($0) })
        else { throw notFound(object) }
        let name = dialect.qualifiedName(TableRef(schema: schema, name: object.name))
        let quote = dialect.quoteIdentifier
        var statement: String
        switch row[1].textValue {
        case "e":
            let labels = try rows("SELECT enumlabel FROM pg_catalog.pg_enum WHERE enumtypid = \(oid) ORDER BY enumsortorder")
                .compactMap { $0.first?.textValue }
            statement = "CREATE TYPE \(name) AS ENUM (\n" + labels.map { "    " + dialect.quoteString($0) }.joined(separator: ",\n") + "\n)"
        case "c":
            let relid = row[2].textValue.flatMap { UInt32($0) } ?? 0
            let fields = try rows("""
                SELECT a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod)
                FROM pg_catalog.pg_attribute a
                WHERE a.attrelid = \(relid) AND a.attnum > 0 AND NOT a.attisdropped
                ORDER BY a.attnum
                """).compactMap { field -> String? in
                guard field.count >= 2, let column = field[0].textValue else { return nil }
                return "    \(quote(column)) \(field[1].textValue ?? "")"
            }
            statement = "CREATE TYPE \(name) AS (\n" + fields.joined(separator: ",\n") + "\n)"
        case "d":
            statement = "CREATE DOMAIN \(name) AS \(row[3].textValue ?? "")"
            if let defaultValue = row[5].textValue { statement += "\n    DEFAULT \(defaultValue)" }
            if row[4].textValue == "t" { statement += "\n    NOT NULL" }
            for constraint in try rows("""
                SELECT conname, pg_catalog.pg_get_constraintdef(oid, true) FROM pg_catalog.pg_constraint
                WHERE contypid = \(oid) AND contype = 'c' ORDER BY conname
                """) {
                guard constraint.count >= 2, let constraintName = constraint[0].textValue, let check = constraint[1].textValue else { continue }
                statement += "\n    CONSTRAINT \(quote(constraintName)) \(check)"
            }
        case "r":
            let subtype = try rows("SELECT pg_catalog.format_type(rngsubtype, NULL) FROM pg_catalog.pg_range WHERE rngtypid = \(oid)")
                .first?.first?.textValue ?? ""
            statement = "CREATE TYPE \(name) AS RANGE (\n    SUBTYPE = \(subtype)\n)"
        default:
            throw notFound(object)
        }
        if let comment = row[6].textValue, !comment.isEmpty {
            statement += ";\n\nCOMMENT ON \(row[1].textValue == "d" ? "DOMAIN" : "TYPE") \(name) IS \(dialect.quoteString(comment))"
        }
        return statement
    }

    // MARK: - One table

    public func triggers(of table: TableRef) throws -> [TriggerInfo] {
        let relation = try relation(table)
        return try triggerRows("t.tgrelid = \(relation.oid)").compactMap(Self.triggerInfo)
    }

    /// `NOT VALID` constraints count as not enforced: rows from before they were added are not checked.
    public func checkConstraints(of table: TableRef) throws -> [CheckConstraintInfo] {
        let relation = try relation(table)
        let constraintRows = try rows("""
            SELECT con.conname, pg_catalog.pg_get_constraintdef(con.oid, true), con.convalidated,
                   (SELECT pg_catalog.string_agg(a.attname, ', ' ORDER BY a.attnum) FROM pg_catalog.pg_attribute a
                    WHERE a.attrelid = con.conrelid AND a.attnum = ANY (con.conkey))
            FROM pg_catalog.pg_constraint con
            WHERE con.conrelid = \(relation.oid) AND con.contype = 'c'
            ORDER BY con.conname
            """)
        return constraintRows.compactMap { row in
            guard row.count >= 4, let name = row[0].textValue, var expression = row[1].textValue else { return nil }
            if expression.hasPrefix("CHECK ") { expression.removeFirst(6) }
            if expression.hasSuffix(" NOT VALID") { expression.removeLast(10) }
            let columns = row[3].textValue.map { $0.components(separatedBy: ", ") } ?? []
            return CheckConstraintInfo(name: name, expression: expression, columns: columns, isEnforced: row[2].textValue == "t")
        }
    }
}

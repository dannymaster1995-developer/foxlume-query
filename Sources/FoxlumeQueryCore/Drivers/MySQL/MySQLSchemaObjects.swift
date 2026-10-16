import Foundation

/// Procedures, functions and triggers of the current database, and the triggers and CHECK constraints of one table.
/// Definitions come from SHOW CREATE; when that is refused or returns no body (missing privileges), they are rebuilt
/// from information_schema where it still has the text.
extension MySQLConnection {
    public func schemaObjects(_ kind: SchemaObjectKind, schema: String?) throws -> [SchemaObject] {
        switch kind {
        case .function, .procedure: return try routines(kind, database: schema)
        case .trigger: return try triggerObjects(database: schema)
        case .type: return []
        }
    }

    /// SHOW CREATE VIEW, with ALGORITHM, DEFINER and SQL SECURITY as the server keeps them.
    public func viewDefinition(of view: TableRef) throws -> ViewDefinition {
        guard let statement = try rows("SHOW CREATE VIEW \(dialect.qualifiedName(view))").first.flatMap({ Self.cell($0, 1) }) else {
            throw DatabaseError.server(message: "The server returned no definition for \(view.name).", code: nil)
        }
        return ViewDefinition(view: view, statement: statement)
    }

    /// The parameter list is built from information_schema.PARAMETERS (ordinal 0 is a function's return value).
    /// Functions leave out the IN mode every parameter has.
    private func routines(_ kind: SchemaObjectKind, database: String?) throws -> [SchemaObject] {
        let type = kind == .procedure ? "PROCEDURE" : "FUNCTION"
        let sql = """
            SELECT r.ROUTINE_NAME, r.ROUTINE_SCHEMA, r.DTD_IDENTIFIER, r.SQL_DATA_ACCESS, r.IS_DETERMINISTIC, r.SECURITY_TYPE,
                   r.DEFINER, r.ROUTINE_COMMENT,
                   (SELECT GROUP_CONCAT(CONCAT_WS(' ', IF(r.ROUTINE_TYPE = 'FUNCTION', NULL, p.PARAMETER_MODE), p.PARAMETER_NAME,
                                                  p.DTD_IDENTIFIER) ORDER BY p.ORDINAL_POSITION SEPARATOR ', ')
                    FROM information_schema.PARAMETERS p
                    WHERE p.SPECIFIC_SCHEMA = r.ROUTINE_SCHEMA AND p.SPECIFIC_NAME = r.SPECIFIC_NAME
                      AND p.ROUTINE_TYPE = r.ROUTINE_TYPE AND p.ORDINAL_POSITION > 0)
            FROM information_schema.ROUTINES r
            WHERE r.ROUTINE_SCHEMA = \(databaseExpression(database)) AND r.ROUTINE_TYPE = '\(type)'
            ORDER BY r.ROUTINE_NAME
            """
        return try rows(sql).compactMap { row in
            guard let name = Self.cell(row, 0) else { return nil }
            var attributes: [SchemaObjectAttribute] = []
            if let access = Self.cell(row, 3) { attributes.append(.init("Data Access", access)) }
            if let deterministic = Self.cell(row, 4) { attributes.append(.init("Deterministic", deterministic)) }
            if let security = Self.cell(row, 5) { attributes.append(.init("Security", security)) }
            if let definer = Self.cell(row, 6) { attributes.append(.init("Definer", definer)) }
            if let comment = Self.cell(row, 7), !comment.isEmpty { attributes.append(.init("Comment", comment)) }
            return SchemaObject(
                kind: kind,
                schema: Self.cell(row, 1),
                name: name,
                arguments: Self.cell(row, 8) ?? "",
                returnType: kind == .function ? Self.cell(row, 2) : nil,
                detail: "SQL",
                attributes: attributes
            )
        }
    }

    private func triggerRows(database: String?, table: String?) throws -> [[CellValue]] {
        var condition = "TRIGGER_SCHEMA = \(databaseExpression(database))"
        if let table { condition += " AND EVENT_OBJECT_TABLE = \(dialect.quoteString(table))" }
        return try rows("""
            SELECT TRIGGER_NAME, EVENT_OBJECT_TABLE, ACTION_TIMING, EVENT_MANIPULATION, ACTION_ORIENTATION, ACTION_STATEMENT,
                   DEFINER, TRIGGER_SCHEMA, ACTION_ORDER
            FROM information_schema.TRIGGERS
            WHERE \(condition)
            ORDER BY EVENT_OBJECT_TABLE, ACTION_TIMING, EVENT_MANIPULATION, ACTION_ORDER, TRIGGER_NAME
            """)
    }

    private func triggerObjects(database: String?) throws -> [SchemaObject] {
        try triggerRows(database: database, table: nil).compactMap { row in
            guard let name = Self.cell(row, 0), let table = Self.cell(row, 1) else { return nil }
            let timing = Self.cell(row, 2) ?? ""
            let event = Self.cell(row, 3) ?? ""
            var attributes = [
                SchemaObjectAttribute("Timing", timing),
                SchemaObjectAttribute("Event", event),
                SchemaObjectAttribute("Level", Self.cell(row, 4) ?? "ROW"),
            ]
            if let definer = Self.cell(row, 6) { attributes.append(.init("Definer", definer)) }
            return SchemaObject(kind: .trigger, schema: Self.cell(row, 7), name: name, table: table, detail: "\(timing) \(event)", attributes: attributes)
        }
    }

    // MARK: - Definitions

    public func definition(of object: SchemaObject) throws -> SchemaObjectDefinition {
        let name = dialect.qualifiedName(TableRef(schema: object.schema, name: object.name))
        switch object.kind {
        case .function, .procedure:
            // Column 3 is NULL when the account may call the routine but not read it.
            if let text = try? rows("SHOW CREATE \(object.kind.keyword) \(name)").first.flatMap({ Self.cell($0, 2) }) {
                return SchemaObjectDefinition(statement: text)
            }
            return SchemaObjectDefinition(statement: try routineFromCatalog(object))
        case .trigger:
            if let text = try? rows("SHOW CREATE TRIGGER \(name)").first.flatMap({ Self.cell($0, 2) }) {
                return SchemaObjectDefinition(statement: text)
            }
            return SchemaObjectDefinition(statement: try triggerFromCatalog(object))
        case .type:
            throw DatabaseError.unsupported("\(kind.displayName) has no user-defined types.")
        }
    }

    private func notFound(_ object: SchemaObject) -> DatabaseError {
        .server(message: "\(object.kind.label) \(object.name) does not exist, or your account may not read its definition.", code: "1305")
    }

    /// CREATE FUNCTION / PROCEDURE rebuilt from information_schema.ROUTINES and PARAMETERS. ROUTINE_DEFINITION is NULL
    /// for accounts that may not read the body; then there is nothing to show.
    private func routineFromCatalog(_ object: SchemaObject) throws -> String {
        let database = databaseExpression(object.schema)
        let type = object.kind == .procedure ? "PROCEDURE" : "FUNCTION"
        guard let row = try rows("""
            SELECT ROUTINE_DEFINITION, DTD_IDENTIFIER, IS_DETERMINISTIC, SQL_DATA_ACCESS, SECURITY_TYPE, ROUTINE_COMMENT, DEFINER
            FROM information_schema.ROUTINES
            WHERE ROUTINE_SCHEMA = \(database) AND ROUTINE_NAME = \(dialect.quoteString(object.name)) AND ROUTINE_TYPE = '\(type)'
            """).first, let body = Self.cell(row, 0)
        else { throw notFound(object) }
        let parameters = try rows("""
            SELECT PARAMETER_MODE, PARAMETER_NAME, DTD_IDENTIFIER FROM information_schema.PARAMETERS
            WHERE SPECIFIC_SCHEMA = \(database) AND SPECIFIC_NAME = \(dialect.quoteString(object.name))
              AND ROUTINE_TYPE = '\(type)' AND ORDINAL_POSITION > 0
            ORDER BY ORDINAL_POSITION
            """).map { parameter -> String in
            let mode = object.kind == .procedure ? Self.cell(parameter, 0) : nil
            return [mode, Self.cell(parameter, 1).map(dialect.quoteIdentifier), Self.cell(parameter, 2)].compactMap { $0 }.joined(separator: " ")
        }
        var lines = ["CREATE\(Self.definerClause(Self.cell(row, 6))) \(type) \(dialect.quoteIdentifier(object.name))(\(parameters.joined(separator: ", ")))"]
        if object.kind == .function, let returns = Self.cell(row, 1) { lines[0] += " RETURNS \(returns)" }
        if Self.cell(row, 2) == "YES" { lines.append("    DETERMINISTIC") }
        if let access = Self.cell(row, 3), access != "CONTAINS SQL" { lines.append("    \(access)") }
        if Self.cell(row, 4) == "INVOKER" { lines.append("    SQL SECURITY INVOKER") }
        if let comment = Self.cell(row, 5), !comment.isEmpty { lines.append("    COMMENT \(dialect.quoteString(comment))") }
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    /// CREATE TRIGGER rebuilt from information_schema.TRIGGERS, for accounts SHOW CREATE TRIGGER refuses.
    private func triggerFromCatalog(_ object: SchemaObject) throws -> String {
        guard let row = try triggerRows(database: object.schema, table: object.table).first(where: { Self.cell($0, 0) == object.name }),
              let table = Self.cell(row, 1), let body = Self.cell(row, 5)
        else { throw notFound(object) }
        return "CREATE\(Self.definerClause(Self.cell(row, 6))) TRIGGER \(dialect.quoteIdentifier(object.name)) "
            + "\(Self.cell(row, 2) ?? "") \(Self.cell(row, 3) ?? "") ON \(dialect.quoteIdentifier(table)) FOR EACH ROW\n\(body)"
    }

    /// ` DEFINER=`user`@`host`` from information_schema's `user@host`.
    static func definerClause(_ definer: String?) -> String {
        guard let definer, let at = definer.lastIndex(of: "@") else { return "" }
        let quote = SQLDialect.mysql.quoteIdentifier
        return " DEFINER=\(quote(String(definer[..<at])))@\(quote(String(definer[definer.index(after: at)...])))"
    }

    // MARK: - One table

    public func triggers(of table: TableRef) throws -> [TriggerInfo] {
        try triggerRows(database: table.schema, table: table.name).compactMap { row in
            guard let name = Self.cell(row, 0) else { return nil }
            return TriggerInfo(
                name: name,
                timing: Self.cell(row, 2) ?? "",
                events: [Self.cell(row, 3) ?? ""],
                orientation: Self.cell(row, 4) ?? "ROW",
                action: Self.cell(row, 5) ?? ""
            )
        }
    }

    /// MySQL enforces CHECK from 8.0.16 and MariaDB from 10.2.1; older servers parse and ignore it, so nothing is listed.
    public func checkConstraints(of table: TableRef) throws -> [CheckConstraintInfo] {
        let database = databaseExpression(table.schema)
        let tableName = dialect.quoteString(table.name)
        if isMariaDB {
            guard Self.version(serverVersion, atLeast: [10, 2, 1]) else { return [] }
            return try rows("""
                SELECT CONSTRAINT_NAME, CHECK_CLAUSE FROM information_schema.CHECK_CONSTRAINTS
                WHERE CONSTRAINT_SCHEMA = \(database) AND TABLE_NAME = \(tableName)
                ORDER BY CONSTRAINT_NAME
                """).compactMap { row in
                guard let name = Self.cell(row, 0) else { return nil }
                return CheckConstraintInfo(name: name, expression: Self.cell(row, 1) ?? "")
            }
        }
        guard Self.version(serverVersion, atLeast: [8, 0, 16]) else { return [] }
        return try rows("""
            SELECT cc.CONSTRAINT_NAME, cc.CHECK_CLAUSE, tc.ENFORCED
            FROM information_schema.TABLE_CONSTRAINTS tc
            JOIN information_schema.CHECK_CONSTRAINTS cc
              ON cc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
            WHERE tc.TABLE_SCHEMA = \(database) AND tc.TABLE_NAME = \(tableName) AND tc.CONSTRAINT_TYPE = 'CHECK'
            ORDER BY cc.CONSTRAINT_NAME
            """).compactMap { row in
            guard let name = Self.cell(row, 0) else { return nil }
            return CheckConstraintInfo(name: name, expression: Self.cell(row, 1) ?? "", isEnforced: Self.cell(row, 2).map { $0.uppercased() == "YES" })
        }
    }

    /// Compares the leading numbers of a version string such as `8.4.9` or `10.11.6-MariaDB`.
    static func version(_ text: String, atLeast minimum: [Int]) -> Bool {
        let numbers = text.prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap { Int($0) }
        for (index, required) in minimum.enumerated() {
            let actual = index < numbers.count ? numbers[index] : 0
            if actual != required { return actual > required }
        }
        return true
    }
}

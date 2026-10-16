import Foundation

/// DuckDB macros (scalar and table), listed as functions, and CHECK constraints from duckdb_constraints().
extension DuckDBConnection {
    public func schemaObjects(_ kind: SchemaObjectKind, schema: String?) throws -> [SchemaObject] {
        guard kind == .function else { return [] }
        return try macroRows(schema: schema, name: nil).compactMap { row in
            guard let schemaName = Self.cell(row, 0), let name = Self.cell(row, 1) else { return nil }
            let type = Self.cell(row, 2) ?? "macro"
            return SchemaObject(kind: .function, schema: schemaName, name: name, arguments: Self.cell(row, 3) ?? "",
                                detail: type, attributes: [SchemaObjectAttribute("Kind", type == "table_macro" ? "table macro" : "macro")])
        }
    }

    private func macroRows(schema: String?, name: String?) throws -> [[CellValue]] {
        var filter = "database_name = current_database() AND schema_name = \(schemaExpression(schema))"
        if let name { filter += " AND function_name = \(dialect.quoteString(name))" }
        return try rows("""
            SELECT schema_name, function_name, function_type, array_to_string(parameters, ', '), macro_definition
            FROM duckdb_functions()
            WHERE \(filter) AND function_type IN ('macro', 'table_macro') AND NOT internal
            ORDER BY function_name
            """)
    }

    /// Rebuilt as CREATE OR REPLACE MACRO; DuckDB keeps only the macro's body.
    public func definition(of object: SchemaObject) throws -> SchemaObjectDefinition {
        guard object.kind == .function,
              let row = try macroRows(schema: object.schema, name: object.name).first(where: { object.arguments == nil || Self.cell($0, 3) == object.arguments })
        else {
            throw DatabaseError.server(message: "Macro \(object.name) does not exist", code: nil)
        }
        let isTable = Self.cell(row, 2) == "table_macro"
        let name = dialect.qualifiedName(TableRef(schema: Self.cell(row, 0), name: object.name))
        return SchemaObjectDefinition(statement: "CREATE OR REPLACE MACRO \(name)(\(Self.cell(row, 3) ?? "")) AS \(isTable ? "TABLE " : "")\(Self.cell(row, 4) ?? "")")
    }

    /// duckdb_views() keeps the CREATE VIEW statement.
    public func viewDefinition(of view: TableRef) throws -> ViewDefinition {
        let filter = "database_name = current_database() AND schema_name = \(schemaExpression(view.schema)) AND view_name = \(dialect.quoteString(view.name))"
        guard let row = try rows("SELECT schema_name, sql FROM duckdb_views() WHERE \(filter) AND NOT internal").first,
              let statement = Self.cell(row, 1)
        else {
            throw DatabaseError.server(message: "View \(view.name) does not exist", code: nil)
        }
        return ViewDefinition(view: TableRef(schema: Self.cell(row, 0), name: view.name), statement: statement)
    }

    public func checkConstraints(of table: TableRef) throws -> [CheckConstraintInfo] {
        try rows("""
            SELECT constraint_name, expression, array_to_string(constraint_column_names, ', ')
            FROM duckdb_constraints()
            WHERE database_name = current_database() AND schema_name = \(schemaExpression(table.schema))
              AND table_name = \(dialect.quoteString(table.name)) AND constraint_type = 'CHECK'
            ORDER BY constraint_index
            """).compactMap { row in
            guard let name = Self.cell(row, 0) else { return nil }
            let columns = Self.cell(row, 2).map { $0.components(separatedBy: ", ").filter { !$0.isEmpty } } ?? []
            return CheckConstraintInfo(name: name, expression: Self.cell(row, 1) ?? "", columns: columns)
        }
    }
}

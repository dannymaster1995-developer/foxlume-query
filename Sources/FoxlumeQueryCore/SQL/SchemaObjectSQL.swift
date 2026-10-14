import Foundation

/// DROP statements, edit scripts and templates for procedures, functions, triggers and types, written per engine.
public struct SchemaObjectSQL: Sendable {
    public let kind: DatabaseKind

    public init(kind: DatabaseKind) {
        self.kind = kind
    }

    private var dialect: SQLDialect {
        switch kind {
        case .postgresql: return .postgresql
        case .mysql, .mariadb: return .mysql
        case .duckdb: return .duckdb
        case .sqlite, .mongodb, .redis: return .sqlite
        }
    }

    /// The kinds the sidebar lists for this engine.
    public var kinds: [SchemaObjectKind] { SchemaObjectKind.kinds(for: kind) }

    private func qualified(_ schema: String?, _ name: String) -> String {
        dialect.qualifiedName(TableRef(schema: schema, name: name))
    }

    // MARK: Drop

    public func canDrop(_ object: SchemaObject) -> Bool {
        kinds.contains(object.kind)
    }

    /// `DROP … IF EXISTS`, naming a PostgreSQL routine by its argument types so only that overload goes.
    public func dropStatement(_ object: SchemaObject) -> String? {
        guard canDrop(object) else { return nil }
        let name = qualified(object.schema, object.name)
        switch kind {
        case .postgresql:
            switch object.kind {
            case .function, .procedure:
                return "DROP \(object.kind.keyword) IF EXISTS \(name)(\(object.identityArguments ?? ""))"
            case .trigger:
                guard let table = object.table else { return nil }
                return "DROP TRIGGER IF EXISTS \(dialect.quoteIdentifier(object.name)) ON \(qualified(object.schema, table))"
            case .type:
                return "DROP \(object.detail == "domain" ? "DOMAIN" : "TYPE") IF EXISTS \(name)"
            }
        case .mysql, .mariadb:
            return "DROP \(object.kind.keyword) IF EXISTS \(name)"
        case .sqlite:
            return "DROP TRIGGER IF EXISTS \(dialect.quoteIdentifier(object.name))"
        case .duckdb:
            return "DROP MACRO \(object.detail == "table_macro" ? "TABLE " : "")IF EXISTS \(name)"
        case .mongodb, .redis:
            return nil
        }
    }

    // MARK: Showing and editing

    /// The text of the read-only source tab and of Copy Definition: the statement, then a PostgreSQL trigger's function.
    public func displayText(_ definition: SchemaObjectDefinition) -> String {
        var text = Self.terminated(definition.statement)
        if let function = definition.triggerFunction {
            text += "\n\n-- Trigger function\n" + Self.terminated(function)
        }
        return text
    }

    /// A script that replaces the object with its current definition, for "Edit in Query Tab".
    /// PostgreSQL routines are already CREATE OR REPLACE; a PostgreSQL trigger comes after its function, as
    /// CREATE OR REPLACE TRIGGER on PostgreSQL 14+ (DROP + CREATE before, or for a constraint trigger). MySQL, MariaDB
    /// and SQLite get DROP … IF EXISTS before the CREATE. No DELIMITER is needed: the statement splitter keeps
    /// BEGIN … END bodies whole and MySQL reads several statements per request.
    public func editScript(for object: SchemaObject, definition: SchemaObjectDefinition) -> String {
        let statement = Self.terminated(definition.statement)
        switch kind {
        case .postgresql:
            guard object.kind == .trigger else { return statement }
            var parts: [String] = []
            if let function = definition.triggerFunction { parts.append(Self.terminated(function)) }
            if definition.canReplaceTrigger, !definition.isConstraintTrigger, let replaced = Self.orReplaceTrigger(definition.statement) {
                parts.append(Self.terminated(replaced))
            } else {
                if let drop = dropStatement(object) { parts.append(drop + ";") }
                parts.append(statement)
            }
            return parts.joined(separator: "\n\n")
        case .mysql, .mariadb, .sqlite:
            guard let drop = dropStatement(object) else { return statement }
            return drop + ";\n\n" + statement
        case .duckdb, .mongodb, .redis:
            return statement
        }
    }

    /// `CREATE TRIGGER` → `CREATE OR REPLACE TRIGGER`; nil when the text does not start that way.
    static func orReplaceTrigger(_ statement: String) -> String? {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: #"^CREATE\s+TRIGGER\b"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return "CREATE OR REPLACE TRIGGER" + trimmed[range.upperBound...]
    }

    /// Adds the closing `;` unless the text already ends with one.
    static func terminated(_ statement: String) -> String {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(";") ? trimmed : trimmed + ";"
    }

    // MARK: Templates

    /// Whether "New Trigger…" has a template for this engine.
    public var hasTriggerTemplate: Bool { kinds.contains(.trigger) }

    /// A trigger to fill in, in a query tab. PostgreSQL needs a trigger function first.
    /// - Parameters:
    ///   - table: the table it fires on; a placeholder when nil.
    ///   - replaceable: whether the server accepts CREATE OR REPLACE TRIGGER (PostgreSQL 14+).
    public func triggerTemplate(table: TableRef?, replaceable: Bool = true) -> String? {
        guard hasTriggerTemplate else { return nil }
        let target = table.map { dialect.qualifiedName($0) } ?? dialect.quoteIdentifier("table_name")
        let base = table?.name ?? "table"
        let triggerName = dialect.quoteIdentifier("\(base)_before_insert")
        switch kind {
        case .postgresql:
            let functionName = qualified(table?.schema, "\(base)_before_insert_fn")
            return """
                CREATE OR REPLACE FUNCTION \(functionName)()
                 RETURNS trigger
                 LANGUAGE plpgsql
                AS $function$
                BEGIN
                    -- Change NEW here, or RAISE EXCEPTION to reject the row.
                    RETURN NEW;
                END;
                $function$;

                CREATE \(replaceable ? "OR REPLACE " : "")TRIGGER \(triggerName)
                    BEFORE INSERT ON \(target)
                    FOR EACH ROW
                    EXECUTE FUNCTION \(functionName)();
                """
        case .mysql, .mariadb:
            return """
                CREATE TRIGGER \(triggerName)
                    BEFORE INSERT ON \(target)
                    FOR EACH ROW
                BEGIN
                    -- SET NEW.column = value;
                END;
                """
        case .sqlite:
            return """
                CREATE TRIGGER \(dialect.quoteIdentifier("\(base)_after_insert"))
                    AFTER INSERT ON \(target)
                    FOR EACH ROW
                BEGIN
                    -- UPDATE … WHERE id = NEW.id;
                    SELECT 1;
                END;
                """
        case .duckdb, .mongodb, .redis:
            return nil
        }
    }
}

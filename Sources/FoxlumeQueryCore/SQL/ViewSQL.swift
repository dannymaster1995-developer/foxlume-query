import Foundation

/// New View templates, Edit View scripts and the statements around them, written per engine.
///
/// Editing keeps what the server reports: PostgreSQL, MySQL, MariaDB and DuckDB views are replaced in place with
/// CREATE OR REPLACE VIEW (MySQL and MariaDB keep ALGORITHM, DEFINER and SQL SECURITY as SHOW CREATE VIEW gives them,
/// so a DEFINER other than the current user needs the SET_USER_ID or SUPER privilege). SQLite has no OR REPLACE for
/// views, so its script is DROP VIEW + CREATE VIEW + the triggers on the view, run in one transaction. A PostgreSQL
/// materialized view is always dropped and created again, which computes its data again.
public struct ViewSQL: Sendable {
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

    // MARK: What the engine offers

    /// Whether New View… and Edit View… are offered.
    public var supportsViews: Bool {
        switch kind {
        case .postgresql, .mysql, .mariadb, .sqlite, .duckdb: return true
        case .mongodb, .redis: return false
        }
    }

    public func canEdit(_ objectKind: TableKind) -> Bool {
        switch objectKind {
        case .view: return supportsViews
        case .materializedView: return kind == .postgresql
        case .table, .foreignTable, .systemTable, .keyspace: return false
        }
    }

    /// Whether Save View runs a script of several statements in one transaction. MySQL and MariaDB commit every
    /// CREATE and DROP on their own, so a transaction would not undo anything there.
    public var runsScriptsInTransaction: Bool {
        switch kind {
        case .postgresql, .sqlite, .duckdb: return true
        case .mysql, .mariadb, .mongodb, .redis: return false
        }
    }

    // MARK: New View

    /// A view to fill in: `CREATE VIEW <name> AS SELECT * FROM <source>`, with a placeholder table when none is given.
    public func template(name: String, schema: String?, source: TableRef? = nil) -> String? {
        guard supportsViews, !name.isEmpty else { return nil }
        let view = dialect.qualifiedName(TableRef(schema: kind.supportsSchemas ? schema : nil, name: name))
        let from = source.map { dialect.qualifiedName($0) } ?? dialect.quoteIdentifier("table_name")
        return """
            CREATE VIEW \(view) AS
            SELECT
                *
            FROM \(from);
            """
    }

    // MARK: Edit View

    /// The comment that heads a materialized view's edit script.
    public static let materializedViewWarning = "-- Saving drops the materialized view and creates it again: its data is computed again, "
        + "and objects that depend on it make the DROP fail."

    /// A script that replaces the view with its current definition, for Edit View….
    public func editScript(_ definition: ViewDefinition) -> String {
        let name = dialect.qualifiedName(definition.view)
        if definition.isMaterialized {
            let create = Self.rewritingHead(of: definition.statement, family: dialect.family, orReplace: false, view: definition.view, dialect: dialect)
            let parts = ["DROP MATERIALIZED VIEW \(name);", SchemaObjectSQL.terminated(create)] + definition.attachedStatements
            return Self.materializedViewWarning + "\n" + parts.joined(separator: "\n\n")
        }
        switch kind {
        case .sqlite:
            let create = Self.rewritingHead(of: definition.statement, family: dialect.family, orReplace: false, view: definition.view, dialect: dialect)
            let parts = ["DROP VIEW IF EXISTS \(name);", SchemaObjectSQL.terminated(create)] + definition.attachedStatements
            return parts.joined(separator: "\n\n")
        case .postgresql, .mysql, .mariadb, .duckdb:
            return SchemaObjectSQL.terminated(Self.rewritingHead(of: definition.statement, family: dialect.family, orReplace: true, view: definition.view, dialect: dialect))
        case .mongodb, .redis:
            return SchemaObjectSQL.terminated(definition.statement)
        }
    }

    /// PostgreSQL's CREATE OR REPLACE VIEW cannot drop, rename or retype columns (SQLSTATE 42P16).
    public static func needsRecreate(_ error: Error) -> Bool {
        guard case let .server(message, code, _)? = error as? DatabaseError, code == "42P16" else { return false }
        let lower = message.lowercased()
        return lower.contains("view column") || lower.contains("columns from view")
    }

    /// The edited script as DROP VIEW + CREATE VIEW, for when PostgreSQL refuses CREATE OR REPLACE. The view's own
    /// comment is set again; grants and column comments are not kept. Nil when the script creates no plain view.
    public func recreateScript(replacing sql: String, definition: ViewDefinition? = nil) -> String? {
        guard kind == .postgresql else { return nil }
        let statements = QueryLanguage.sql(dialect.family).split(sql).map(\.text)
        guard let index = statements.firstIndex(where: { Self.head(of: $0, family: dialect.family).map { !$0.isMaterialized } == true }),
              let head = Self.head(of: statements[index], family: dialect.family)
        else { return nil }
        var parts = ["DROP VIEW \(dialect.qualifiedName(head.view));"]
        for (offset, statement) in statements.enumerated() {
            let text = offset == index
                ? Self.rewritingHead(of: statement, family: dialect.family, orReplace: false, view: head.view, dialect: dialect)
                : statement
            parts.append(SchemaObjectSQL.terminated(text))
        }
        if let definition, Self.sameView(definition.view, head.view), !sql.uppercased().contains("COMMENT ON VIEW") {
            parts += definition.attachedStatements.filter { $0.uppercased().hasPrefix("COMMENT ON VIEW") }
        }
        return parts.joined(separator: "\n\n")
    }

    /// `REFRESH MATERIALIZED VIEW`, PostgreSQL only.
    public func refreshStatement(_ view: TableRef) -> String? {
        guard kind == .postgresql else { return nil }
        return "REFRESH MATERIALIZED VIEW \(dialect.qualifiedName(view))"
    }

    // MARK: Reading CREATE VIEW

    /// The view the last CREATE VIEW of a script makes, so the sidebar can select it. Unquoted PostgreSQL names are
    /// folded to lower case as the server folds them; the schema is nil when the script does not name one.
    public func createdView(in sql: String) -> TableRef? {
        QueryLanguage.sql(dialect.family).split(sql).reversed().lazy.compactMap { Self.head(of: $0.text, family: self.dialect.family)?.view }.first
    }

    /// The part of a CREATE VIEW statement up to the view's name.
    struct Head {
        /// UTF-16 range from CREATE to the end of the name.
        var range: NSRange
        var isOrReplace: Bool
        var isMaterialized: Bool
        /// MySQL ALGORITHM, DEFINER and SQL SECURITY or PostgreSQL TEMP / RECURSIVE, as written.
        var options: String
        var view: TableRef
    }

    /// Words that may stand between CREATE and VIEW; anything else means the statement makes something else.
    private static let optionWords: Set<String> = [
        "TEMP", "TEMPORARY", "RECURSIVE", "ALGORITHM", "UNDEFINED", "MERGE", "TEMPTABLE", "DEFINER", "CURRENT_USER",
        "SQL", "SECURITY", "INVOKER",
    ]

    static func head(of statement: String, family: SQLDialect.Family) -> Head? {
        let text = statement as NSString
        let tokens = SQLLexer.tokenize(text, family: family).filter { $0.kind != .comment }
        guard let first = tokens.first, first.isWord("CREATE") else { return nil }
        var index = 1
        var isOrReplace = false
        if index + 1 < tokens.count, tokens[index].isWord("OR"), tokens[index + 1].isWord("REPLACE") {
            isOrReplace = true
            index += 2
        }
        let optionsStart = index
        var isMaterialized = false
        while index < tokens.count, !tokens[index].isWord("VIEW") {
            let token = tokens[index]
            if token.isWord("MATERIALIZED") {
                isMaterialized = true
            } else if token.kind == .word, !optionWords.contains(token.upper) {
                // A DEFINER = user@host value is the only place a free word may appear.
                guard index > optionsStart, tokens[index - 1].text == "=" || tokens[index - 1].kind == .parameter || tokens[index - 1].text == "@" else { return nil }
            } else if token.isPunctuation(";") || (token.isPunctuation("(") && !tokens[index - 1].isWord("CURRENT_USER")) {
                return nil
            }
            index += 1
        }
        guard index < tokens.count else { return nil }
        let viewToken = index
        index += 1
        if index + 2 < tokens.count, tokens[index].isWord("IF"), tokens[index + 1].isWord("NOT"), tokens[index + 2].isWord("EXISTS") {
            index += 3
        }
        var parts: [String] = []
        var nameEnd = 0
        // A bare AS where the name belongs means the name is missing.
        while index < tokens.count, tokens[index].isIdentifier, !(parts.isEmpty && tokens[index].isWord("AS")) {
            let token = tokens[index]
            parts.append(token.kind == .word && family == .postgresql ? token.value.lowercased() : token.value)
            nameEnd = NSMaxRange(token.range)
            if index + 2 < tokens.count, tokens[index + 1].isPunctuation("."), tokens[index + 2].isIdentifier {
                index += 2
            } else {
                break
            }
        }
        guard let name = parts.last else { return nil }
        // MATERIALIZED comes right before VIEW in PostgreSQL, so it is never inside the option text.
        let optionTokens = tokens[optionsStart..<viewToken].filter { !$0.isWord("MATERIALIZED") }
        var options = ""
        if let firstOption = optionTokens.first, let lastOption = optionTokens.last {
            options = text.substring(with: NSRange(location: firstOption.range.location, length: NSMaxRange(lastOption.range) - firstOption.range.location))
        }
        return Head(
            range: NSRange(location: first.range.location, length: nameEnd - first.range.location),
            isOrReplace: isOrReplace,
            isMaterialized: isMaterialized,
            options: options,
            view: TableRef(schema: parts.count > 1 ? parts[parts.count - 2] : nil, name: name)
        )
    }

    /// The statement with its head written again: `CREATE [OR REPLACE] [options] [MATERIALIZED] VIEW <view>`, the rest
    /// as it was. Unchanged when it is not a CREATE VIEW.
    static func rewritingHead(of statement: String, family: SQLDialect.Family, orReplace: Bool, view: TableRef, dialect: SQLDialect) -> String {
        guard let head = head(of: statement, family: family) else { return statement }
        var replacement = "CREATE "
        if orReplace { replacement += "OR REPLACE " }
        if !head.options.isEmpty { replacement += head.options + " " }
        if head.isMaterialized { replacement += "MATERIALIZED " }
        replacement += "VIEW " + dialect.qualifiedName(view)
        return (statement as NSString).replacingCharacters(in: head.range, with: replacement)
    }

    /// The same view, when one side names no schema.
    static func sameView(_ lhs: TableRef, _ rhs: TableRef) -> Bool {
        guard lhs.name == rhs.name else { return false }
        return lhs.schema == nil || rhs.schema == nil || lhs.schema == rhs.schema
    }
}

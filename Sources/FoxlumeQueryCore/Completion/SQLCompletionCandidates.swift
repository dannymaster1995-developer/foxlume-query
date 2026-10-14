import Foundation

/// Candidate generation per clause (spec 2.5). Generation order is the ranking tie-breaker, so each list is
/// built in the order the spec gives.
extension SQLCompletionEngine {
    static let joinKinds = [
        "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "LEFT OUTER JOIN", "RIGHT OUTER JOIN", "FULL OUTER JOIN",
        "CROSS JOIN", "NATURAL JOIN", "JOIN",
    ]
    static let fromKeywords = joinKinds + ["ON", "USING", "WHERE", "ORDER BY", "GROUP BY", "HAVING", "LIMIT", "UNION", "INTERSECT", "EXCEPT"]
    static let selectKeywords = ["DISTINCT", "ALL", "AS", "FROM", "CASE", "WHEN", "INTO", "UNION", "INTERSECT", "EXCEPT"]
    static let predicateKeywords = [
        "AND", "OR", "NOT", "IN", "LIKE", "ILIKE", "BETWEEN", "IS", "NULL", "NOT NULL", "TRUE", "FALSE", "EXISTS",
        "NOT EXISTS", "ANY", "ALL", "SOME", "REGEXP", "RLIKE", "SIMILAR TO", "IS NULL", "IS NOT NULL",
    ]
    static let whereTransitions = ["ORDER BY", "GROUP BY", "HAVING", "LIMIT", "UNION", "INTERSECT", "EXCEPT"]
    static let onTransitions = joinKinds + ["WHERE", "ORDER BY", "GROUP BY", "HAVING", "LIMIT", "UNION", "INTERSECT", "EXCEPT"]
    static let alterTableKeywords = [
        "ADD", "DROP", "MODIFY", "CHANGE", "RENAME", "COLUMN", "INDEX", "PRIMARY", "FOREIGN", "KEY", "CONSTRAINT",
        "ENGINE", "CHARSET", "COLLATE", "AUTO_INCREMENT", "COMMENT", "DEFAULT", "CHARACTER SET", "PRIMARY KEY",
        "FOREIGN KEY", "UNIQUE", "CHECK",
    ]
    static let foreignKeyKeywords = ["REFERENCES", "ON DELETE", "ON UPDATE", "CASCADE", "RESTRICT", "SET NULL", "NO ACTION"]
    static let columnConstraintKeywords = ["PRIMARY", "KEY", "FOREIGN", "UNIQUE", "NOT", "NULL", "DEFAULT", "AUTO_INCREMENT", "SERIAL", "CHECK", "CONSTRAINT", "INDEX"]
    static let fallbackTableOptions = ["ENGINE", "CHARSET", "COLLATE", "COMMENT", "TABLESPACE"]
    static let columnDefinitionKeywords = [
        "NOT", "NULL", "DEFAULT", "AUTO_INCREMENT", "SERIAL", "PRIMARY", "KEY", "UNIQUE", "REFERENCES", "CHECK",
        "UNSIGNED", "SIGNED", "FIRST", "AFTER", "COMMENT", "COLLATE", "CHARACTER SET", "ON UPDATE", "ON DELETE",
        "CASCADE", "RESTRICT", "SET NULL", "NO ACTION",
    ]
    static let windowKeywords = [
        "PARTITION BY", "ORDER BY", "ASC", "DESC", "ROWS", "RANGE", "GROUPS", "BETWEEN", "UNBOUNDED", "PRECEDING",
        "FOLLOWING", "CURRENT ROW",
    ]

    /// Drops the clause keywords the dialect lacks: MySQL has no RETURNING or ON CONFLICT (MariaDB's RETURNING on
    /// INSERT and DELETE shares the family and is left out too), the others have no ON DUPLICATE KEY UPDATE.
    func supported(_ keywords: [String]) -> [String] {
        switch family {
        case .mysql?: return keywords.filter { $0 != "RETURNING" && $0 != "ON CONFLICT" }
        case .postgresql?, .sqlite?, .duckdb?: return keywords.filter { $0 != "ON DUPLICATE KEY UPDATE" }
        case nil: return keywords
        }
    }

    func candidates(for context: SQLCompletionContext) async -> [CompletionItem] {
        let build = SQLCompletionItemBuilder(family: family, token: context.token)
        let scope = SQLColumnScope(context: context, provider: schema, build: build)
        if let qualifier = context.qualifier {
            return await qualifiedCandidates(qualifier, context: context, scope: scope, build: build)
        }
        var items: [CompletionItem] = []
        switch context.clause {
        case .selectList where context.currentFunction != nil:
            items = await functionCallItems(context.currentFunction ?? "", scope: scope, build: build)
        case .functionArgument:
            items = await functionCallItems(context.currentFunction ?? "", scope: scope, build: build)
        case .selectList:
            items.append(build.star(priority: 50))
            items += context.references.map(build.tableStar)
            items += await scope.columnsInScope()
            items += functions(build)
            items += build.keywords(Self.selectKeywords)
        case .from, .join:
            items += await tables(build)
            items += await qualifierNames(build)
            items += build.keywords(Self.fromKeywords)
        case .into:
            items += await tables(build)
            items += build.keywords(["VALUES", "SELECT", "SET"] + Self.fromKeywords)
        case .on:
            items += await scope.valueSuggestions()
            items += await scope.columnsInScope()
            items += await scope.qualifiedColumnsForOn()
            items += operators(build)
            items += build.keywords(["AND", "OR", "NOT", "IS", "NULL", "TRUE", "FALSE"] + Self.onTransitions)
        case .whereClause, .and, .having:
            items += await scope.valueSuggestions()
            items += await scope.columnsInScope()
            items += operators(build)
            items += build.keywords(Self.predicateKeywords)
            items += functions(build)
            items += build.keywords(Self.whereTransitions)
        case .groupBy:
            items += await scope.columnsInScope()
            items += build.keywords(["HAVING", "ORDER BY", "LIMIT", "UNION", "INTERSECT", "EXCEPT"])
        case .orderBy:
            items += await scope.columnsInScope()
            items += build.keywords(["ASC", "DESC", "NULLS FIRST", "NULLS LAST", "LIMIT", "OFFSET", "UNION", "INTERSECT", "EXCEPT"])
        case .set:
            items += await scope.targetColumns()
            items += build.keywords(supported(["WHERE", "RETURNING"]))
        case .insertColumns, .alterTableColumn:
            items += await scope.targetColumns()
        case .values where context.nestingLevel > 0:
            // Inside a tuple: values, the value keywords ahead of the long function lists.
            items += build.keywords(["NULL", "DEFAULT", "TRUE", "FALSE"], priority: 250)
            items += functions(build)
        case .values:
            // After the last tuple only what can follow it; functions would crowd these out on PostgreSQL.
            items += build.keywords(supported(["ON CONFLICT", "ON DUPLICATE KEY UPDATE", "RETURNING"]))
        case .caseExpression:
            items += await scope.columnsInScope()
            items += build.keywords(["WHEN", "THEN", "ELSE", "END", "AND", "OR", "IS", "NULL", "TRUE", "FALSE"])
            items += operators(build)
            items += functions(build)
        case .inList:
            items += await scope.columnsInScope()
            items += build.keywords(["SELECT", "NULL", "TRUE", "FALSE"])
            items += functions(build)
        case .limit:
            items += build.keywords(["OFFSET", "FETCH", "NEXT", "ROWS", "ONLY"])
        case .alterTable:
            items += build.keywords(Self.alterTableKeywords)
        case .createTable where context.insideCreateTableColumns:
            items += build.keywords(Self.foreignKeyKeywords, priority: 300)
            items += build.keywords(Self.columnConstraintKeywords)
            items += dataTypes(build)
        case .createTable:
            items.append(build.keyword("IF NOT EXISTS"))
            items += build.keywords(SQLCompletionVocabulary.tableOptions(family) ?? Self.fallbackTableOptions)
        case .columnDefinition:
            items += dataTypes(build)
            items += build.keywords(Self.columnDefinitionKeywords)
        case .returning:
            items += await scope.columnsInScope()
            items.append(build.star(priority: CompletionKind.keyword.basePriority))
        case .union:
            items += build.keywords(["SELECT", "ALL"])
        case .using:
            items += await scope.columnsInScope()
        case .window:
            items += await scope.columnsInScope()
            items += build.keywords(Self.windowKeywords)
        case .dropObject:
            items += await tables(build)
            items += build.keywords(["IF EXISTS", "CASCADE", "RESTRICT"])
        case .createIndex where context.nestingLevel > 0:
            items += await scope.columnsInScope()
            items += build.keywords(["USING", "BTREE", "HASH", "GIN", "GIST"])
        case .createIndex:
            items += await tables(build)
            items.append(build.keyword("ON"))
        case .createView:
            items += build.keywords(["SELECT", "AS"])
            items += await tables(build)
        case .castTarget:
            items += castTypes(build)
        case .unknown:
            items += build.keywords(SQLCompletionVocabulary.statementStart(family))
            items += await tables(build)
        }
        items += favorites(prefix: context.prefix, build: build)
        return items
    }

    /// `x.|` (spec 3.3): a derived table's columns, a table's columns, a schema's tables, or a database's schemas.
    private func qualifiedCandidates(_ qualifier: String, context: SQLCompletionContext, scope: SQLColumnScope, build: SQLCompletionItemBuilder) async -> [CompletionItem] {
        guard !qualifier.isEmpty else { return [] }
        let key = qualifier.lowercased()
        let refs = context.references
        if let derived = refs.first(where: { $0.identifier.lowercased() == key && !($0.derivedColumns ?? []).isEmpty }) {
            return (derived.derivedColumns ?? []).map { build.derivedColumn([$0], from: qualifier) }
        }
        guard let schema else { return [] }
        var table: TableRef?
        if let ref = refs.first(where: { $0.alias?.lowercased() == key }) ?? refs.first(where: { $0.table.lowercased() == key }) {
            table = TableRef(schema: ref.schema, name: ref.table)
        } else if let info = await schema.unqualifiedTables().first(where: { $0.name.lowercased() == key }) {
            table = info.ref
        }
        if let table, let columns = await scope.columns(of: table), !columns.isEmpty {
            return columns.map { build.column($0, table: table.name, segments: [$0.name]) }
        }
        if let name = await schema.schemaNames().first(where: { $0.lowercased() == key }), let tables = await schema.tables(inSchema: name) {
            return tables.map(build.table)
        }
        if await schema.databaseNames().contains(where: { $0.lowercased() == key }) {
            return await schema.schemaNames().map(build.schema)
        }
        return []
    }

    /// Inside `f(…)` (spec 2.5): COUNT gets `*` and `DISTINCT` first; then columns, functions and literals.
    private func functionCallItems(_ function: String, scope: SQLColumnScope, build: SQLCompletionItemBuilder) async -> [CompletionItem] {
        var items: [CompletionItem] = []
        let isCount = function.uppercased() == "COUNT"
        if isCount {
            items.append(build.star(priority: 10, documentation: "Count all rows"))
            items.append(build.keyword("DISTINCT", priority: 20))
        }
        items += await scope.columnsInScope()
        items += functions(build)
        items += build.keywords(["NULL", "TRUE", "FALSE"])
        if !isCount { items.append(build.keyword("DISTINCT")) }
        return items
    }

    /// Tables and views nameable without a schema (spec 3.5).
    private func tables(_ build: SQLCompletionItemBuilder) async -> [CompletionItem] {
        guard let schema else { return [] }
        return await schema.unqualifiedTables().map(build.table)
    }

    /// Databases, then schemas other than the implicit one, offered as qualifiers in FROM/JOIN.
    private func qualifierNames(_ build: SQLCompletionItemBuilder) async -> [CompletionItem] {
        guard let schema else { return [] }
        let databases = await schema.databaseNames()
        let implicit = await schema.implicitSchema()?.lowercased()
        let known = Set(databases.map { $0.lowercased() })
        let schemas = await schema.schemaNames().filter { $0.lowercased() != implicit && !known.contains($0.lowercased()) }
        return databases.map(build.database) + schemas.map(build.schema)
    }

    /// The generic catalogue adjusted for the dialect, then its extras (MySQL `USER()` keeps its parentheses).
    private func functions(_ build: SQLCompletionItemBuilder) -> [CompletionItem] {
        SQLCompletionVocabulary.functions(family).map(build.function)
    }

    private func operators(_ build: SQLCompletionItemBuilder) -> [CompletionItem] {
        (SQLCompletionVocabulary.genericOperators + SQLCompletionVocabulary.dialectOperators(family)).map(build.operator)
    }

    private func dataTypes(_ build: SQLCompletionItemBuilder) -> [CompletionItem] {
        SQLCompletionVocabulary.dataTypes(family)
            .sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
            .map(build.dataType)
    }

    /// Lowercased dialect types after `::`, without the ones a cast rejects (`serial`); none without a dialect.
    private func castTypes(_ build: SQLCompletionItemBuilder) -> [CompletionItem] {
        guard family != nil else { return [] }
        var seen = Set<String>()
        return SQLCompletionVocabulary.castTargetTypes(family)
            .filter { seen.insert($0).inserted }
            .map(build.castType)
    }

    /// Favorites whose keyword starts with the typed prefix, A–Z (spec 7).
    private func favorites(prefix: String, build: SQLCompletionItemBuilder) -> [CompletionItem] {
        guard !prefix.isEmpty, let schema else { return [] }
        let needle = prefix.lowercased()
        return schema.favorites()
            .filter { $0.keyword.lowercased().hasPrefix(needle) }
            .sorted { $0.keyword.lowercased() < $1.keyword.lowercased() }
            .map(build.favorite)
    }
}

/// Columns visible at the caret (spec 3.4–3.6), fetched at most once per table per request.
@MainActor
final class SQLColumnScope {
    let context: SQLCompletionContext
    weak var provider: CompletionSchemaProvider?
    let build: SQLCompletionItemBuilder
    private var fetched: [String: [ColumnInfo]?] = [:]

    init(context: SQLCompletionContext, provider: CompletionSchemaProvider?, build: SQLCompletionItemBuilder) {
        self.context = context
        self.provider = provider
        self.build = build
    }

    func columns(of table: TableRef) async -> [ColumnInfo]? {
        let key = "\(table.schema?.lowercased() ?? "")\u{1}\(table.name.lowercased())"
        if let cached = fetched[key] { return cached }
        let columns = await provider?.columns(of: table)
        fetched[key] = columns
        return columns
    }

    private func columns(of ref: SQLTableReference) async -> [ColumnInfo]? {
        await columns(of: TableRef(schema: ref.schema, name: ref.table))
    }

    /// One reference: plain names. Several: `alias.column`. None: every cached column (spec 3.4).
    func columnsInScope() async -> [CompletionItem] {
        let refs = context.references
        guard !refs.isEmpty else { return cachedColumns(defaultSchema: await provider?.implicitSchema()) }
        let qualify = refs.count >= 2
        var items: [CompletionItem] = []
        for ref in refs {
            let prefix = qualify ? [ref.identifier] : []
            if let derived = ref.derivedColumns {
                items += derived.map { build.derivedColumn(prefix + [$0], from: ref.identifier) }
                continue
            }
            guard let columns = await columns(of: ref) else { continue }
            items += columns.map { build.column($0, table: ref.table, segments: prefix + [$0.name]) }
        }
        return items
    }

    /// The statement's target (UPDATE/INSERT/ALTER), else the first table in scope; plain names.
    func targetColumns() async -> [CompletionItem] {
        guard let ref = context.targetTable ?? context.references.first else { return [] }
        if let derived = ref.derivedColumns { return derived.map { build.derivedColumn([$0], from: ref.identifier) } }
        guard let columns = await columns(of: ref) else { return [] }
        return columns.map { build.column($0, table: ref.table, segments: [$0.name]) }
    }

    /// ON: every column of every table again as `qualifier.column` (priority 80).
    func qualifiedColumnsForOn() async -> [CompletionItem] {
        var items: [CompletionItem] = []
        for ref in context.references {
            if let derived = ref.derivedColumns {
                items += derived.map {
                    var item = build.derivedColumn([ref.identifier, $0], from: ref.identifier)
                    item.priority = 80
                    return item
                }
                continue
            }
            guard let columns = await columns(of: ref) else { continue }
            items += columns.map { build.column($0, table: ref.table, segments: [ref.identifier, $0.name], priority: 80, withDetail: false) }
        }
        return items
    }

    /// Columns of every cached table, never fetching: qualified only where a name is ambiguous, and with the
    /// schema for tables outside the default one (priority 150).
    private func cachedColumns(defaultSchema: String?) -> [CompletionItem] {
        guard let provider else { return [] }
        let cached = provider.cachedColumns().sorted {
            let left = ($0.table.schema ?? "", $0.table.name)
            let right = ($1.table.schema ?? "", $1.table.name)
            return left < right
        }
        let lowered = cached.map { $0.columns.map { $0.name.lowercased() } }
        var occurrences: [String: Int] = [:]
        for names in lowered {
            for name in Set(names) { occurrences[name, default: 0] += 1 }
        }
        let defaultSchema = defaultSchema?.lowercased()
        var items: [CompletionItem] = []
        items.reserveCapacity(lowered.reduce(0) { $0 + $1.count })
        for (entry, names) in zip(cached, lowered) {
            // Without an implicit schema (MySQL) every cached table counts as default.
            let foreignSchema = defaultSchema == nil ? nil : entry.table.schema.flatMap { $0.lowercased() == defaultSchema ? nil : $0 }
            for (column, name) in zip(entry.columns, names) {
                var segments = [column.name]
                if let foreignSchema {
                    segments = [foreignSchema, entry.table.name, column.name]
                } else if occurrences[name, default: 0] > 1 {
                    segments = [entry.table.name, column.name]
                }
                items.append(build.column(column, table: entry.table.name, segments: segments, priority: 150))
            }
        }
        return items
    }

    /// `'value'` rows for the compared column's allowed values (spec 3.6).
    func valueSuggestions() async -> [CompletionItem] {
        guard let name = context.comparisonColumn?.lowercased() else { return [] }
        var column: ColumnInfo?
        if context.references.isEmpty {
            column = provider?.cachedColumns().lazy.flatMap(\.columns).first { $0.name.lowercased() == name }
        } else {
            for ref in context.references where ref.derivedColumns == nil {
                if let match = await columns(of: ref)?.first(where: { $0.name.lowercased() == name }) {
                    column = match
                    break
                }
            }
        }
        guard let column else { return [] }
        return SQLCompletionItemBuilder.allowedValues(of: column).map { build.value($0, column: column.name) }
    }
}

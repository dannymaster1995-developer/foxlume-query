import Foundation

/// MongoDB shell completion (spec 8).
@MainActor
public final class MongoCompletionEngine: CompletionEngine {
    public weak var schema: CompletionSchemaProvider?

    /// The re-filter pool is the whole list up to this size, else the shown matches cut to it (spec 8.5).
    static let poolLimit = 400
    static let maxRefilterToken = 500

    public init(schema: CompletionSchemaProvider?) {
        self.schema = schema
    }

    public var triggerCharacters: Set<Character> { [".", "$", "{", "[", "\"", "'", ":", " "] }

    /// The token an accepted item replaces: `[A-Za-z0-9_]*` left of the caret plus up to two `$` before it (spec 8.1).
    nonisolated public static func tokenRange(in text: String, caret: Int) -> NSRange {
        let units = Array(text.utf16)
        let caret = min(max(0, caret), units.count)
        let start = MongoCompletionScanner.tokenStart(units, caret: caret)
        return NSRange(location: start, length: caret - start)
    }

    public func complete(text: String, caret: Int, manual: Bool, keywordCase: KeywordCase) async -> CompletionResult? {
        let analysis = MongoCompletionScanner.analyze(text, caret: caret)
        guard let position = analysis.position else { return nil }
        let generated: [CompletionItem]
        if let qualifier = analysis.fieldQualifier {
            // A dotted path is a field reference only inside a string (`"address.ci|`, `"$items.s|`); outside one
            // it is JavaScript member access (`Math.ro|`, `$items.s|`), where no key or operator belongs.
            guard analysis.inString, let collection = position.documentCollection else { return nil }
            // Like a SQL qualifier, `address.` opens the list of its sub-fields with nothing typed.
            generated = await subfieldItems(collection, qualifier: qualifier)
        } else {
            guard manual || !analysis.token.isEmpty || position.opensWithoutPrefix else { return nil }
            generated = await candidates(for: position, inString: analysis.inString)
        }
        let items = ShellCompletionMatcher.deduplicated(generated)
        let shown = Self.rank(items, token: analysis.token)
        guard !shown.isEmpty else { return nil }
        let pool = items.count <= Self.poolLimit ? items : Array(shown.prefix(Self.poolLimit))
        return CompletionResult(
            items: shown,
            pool: pool,
            replacementRange: analysis.tokenRange,
            token: analysis.token,
            prefix: analysis.token,
            limit: .max,
            refilterState: CompletionRefilterState(context: position.tag)
        )
    }

    /// Everything in Mongo keeps its case, so `keywordCase` is ignored.
    public func refilter(_ result: CompletionResult, token: String, keywordCase: KeywordCase) -> [CompletionItem] {
        guard !token.isEmpty, token.utf16.count <= Self.maxRefilterToken, MongoCompletionScanner.isToken(token) else { return [] }
        return Self.rank(result.pool, token: token)
    }

    /// Keeps prefix and substring matches. With a prefix: exact first, then prefix before substring, then priority,
    /// then code-point label order. With nothing typed the generation order stays (spec 8.5).
    static func rank(_ items: [CompletionItem], token: String) -> [CompletionItem] {
        var kept = ShellCompletionMatcher.matches(items, prefix: token)
        guard !token.isEmpty else { return kept.map(\.item) }
        kept.sort { lhs, rhs in
            if lhs.match != rhs.match { return lhs.match < rhs.match }
            if lhs.item.priority != rhs.item.priority { return lhs.item.priority < rhs.item.priority }
            if lhs.item.label != rhs.item.label { return ShellCompletionMatcher.codePointPrecedes(lhs.item.label, rhs.item.label) }
            return lhs.index < rhs.index
        }
        return kept.map(\.item)
    }

    // MARK: - Candidates

    typealias Vocabulary = MongoCompletionVocabulary

    func candidates(for position: MongoCompletionPosition, inString: Bool) async -> [CompletionItem] {
        switch position {
        case .statementStart:
            let commands = Vocabulary.shellCommands.map { Self.keyword($0) }
            let favorites = (schema?.favorites() ?? []).map(ShellCompletionMatcher.favoriteItem)
            let db = CompletionItem(label: "db", kind: .keyword, detail: "Current database", documentation: "The current database; collections are its properties")
            return commands + favorites + [db]
        case .shellArgument(let command):
            guard command == "use" else { return Vocabulary.showTargets.map { Self.keyword($0) } }
            return (await schema?.databaseNames() ?? []).map { CompletionItem(label: $0, kind: .database, detail: "Database") }
        case .databaseMember:
            return await collectionItems() + Vocabulary.databaseMethods.map { Self.method($0) }
        case .collectionMethod:
            return Vocabulary.collectionMethods.map { Self.method($0) }
                + Vocabulary.deprecatedCollectionMethods.map { Self.method($0, deprecated: true) }
        case .cursorMethod:
            return Vocabulary.cursorMethods.map { Self.method($0) }
        case .filterDocument(let collection):
            return await fieldItems(collection, inString: inString) + Vocabulary.queryOperators.map { Self.dollar($0, kind: .operator) }
        case .projectionDocument(let collection):
            return await fieldItems(collection, inString: inString) + Vocabulary.projectionOperators.map { Self.dollar($0, kind: .operator) }
        case .plainDocument(let collection):
            return await fieldItems(collection, inString: inString) + Vocabulary.bsonConstructors.map { Self.method($0) }
        case .fieldNames(let collection):
            return await fieldItems(collection, inString: inString)
        case let .updateDocument(collection, insideOperator):
            let operators = Vocabulary.updateOperators.map { Self.dollar($0, kind: .operator) }
            guard insideOperator else { return operators }
            return await fieldItems(collection, inString: inString) + operators
        case .updatePipelineStage:
            return Vocabulary.updatePipelineStageNames
                .compactMap { name in Vocabulary.pipelineStages.first { $0.name == name } }
                .map { Self.dollar($0, kind: .keyword) }
        case .pipelineStage:
            return Vocabulary.pipelineStages.map { Self.dollar($0, kind: .keyword) }
        case .stageExpression(let collection):
            let operators = (Vocabulary.expressionOperators + Vocabulary.accumulators).map { Self.dollar($0, kind: .operator) }
            let variables = Vocabulary.systemVariables.map { Self.reference($0.name, kind: .keyword, documentation: $0.summary, inString: inString) }
            return operators + variables + (await fieldReferenceItems(collection, inString: inString))
        }
    }

    /// Collections and views nameable after `db.`; names that are not dotted identifiers go through `getCollection`.
    private func collectionItems() async -> [CompletionItem] {
        let tables = await schema?.unqualifiedTables() ?? []
        return tables.map { table in
            let isView = table.kind == .view || table.kind == .materializedView
            let insert = Self.isCollectionPath(table.name) ? table.name : "getCollection(\(Self.quoted(table.name)))"
            return CompletionItem(label: table.name, kind: isView ? .view : .table, detail: isView ? "View" : "Collection", insertText: insert)
        }
    }

    /// Sampled field paths of `collection`, falling back to the provider's columns when sampling found nothing.
    private func fields(of collection: String?) async -> [CompletionField] {
        guard let collection, let schema else { return [] }
        let sampled = await schema.documentFields(of: collection)
        if !sampled.isEmpty { return sampled }
        let columns = await schema.columns(of: TableRef(name: collection)) ?? []
        return columns.map { CompletionField(path: $0.name, typeName: $0.dataType) }
    }

    /// Field paths as keys: priority 100 + nesting depth; dotted paths are quoted unless typed inside a string.
    private func fieldItems(_ collection: String?, inString: Bool) async -> [CompletionItem] {
        await fields(of: collection).map { field in
            let depth = field.path.utf16.filter { $0 == 0x2E }.count
            let insert = inString || Self.isIdentifier(field.path) ? field.path : Self.quoted(field.path)
            return CompletionItem(label: field.path, kind: .column, detail: field.typeName, insertText: insert, priority: CompletionKind.column.basePriority + depth)
        }
    }

    /// After `"path.` inside a document only the sub-fields of `path` fit, named relative to it so accepting
    /// completes the segment being typed instead of repeating the path. A dot after anything that is not a field
    /// (`"x".`, `"$$NOW.`) offers nothing.
    private func subfieldItems(_ collection: String?, qualifier: String) async -> [CompletionItem] {
        guard let path = Self.fieldPath(qualifier: qualifier) else { return [] }
        let lead = path.isEmpty ? "" : path + "."
        return await fields(of: collection).compactMap { field in
            guard field.path.hasPrefix(lead), field.path.utf16.count > lead.utf16.count else { return nil }
            let rest = String(field.path.dropFirst(lead.count))
            let depth = rest.utf16.filter { $0 == 0x2E }.count
            return CompletionItem(label: rest, kind: .column, detail: field.typeName, priority: CompletionKind.column.basePriority + depth)
        }
    }

    /// The field path a qualifier names: `$items` is the `items` field, `$$ROOT.a` is `a`, `$$ROOT` the top level.
    /// Nil for other variables and for a dot with no name before it.
    static func fieldPath(qualifier: String) -> String? {
        for root in ["$$ROOT", "$$CURRENT"] {
            if qualifier == root { return "" }
            if qualifier.hasPrefix(root + ".") { return String(qualifier.dropFirst(root.count + 1)) }
        }
        guard !qualifier.isEmpty, !qualifier.hasPrefix("$$") else { return nil }
        let path = qualifier.hasPrefix("$") ? String(qualifier.dropFirst()) : qualifier
        return path.isEmpty ? nil : path
    }

    /// Field paths as `$path` values inside stage expressions (priority 100, depth not added).
    private func fieldReferenceItems(_ collection: String?, inString: Bool) async -> [CompletionItem] {
        await fields(of: collection).map { field in
            var item = Self.reference("$" + field.path, kind: .column, documentation: nil, inString: inString)
            item.detail = field.typeName
            return item
        }
    }

    // MARK: - Item builders

    /// Methods and constructors insert `name()` with the caret between the parentheses.
    static func method(_ term: MongoCompletionTerm, deprecated: Bool = false) -> CompletionItem {
        CompletionItem(
            label: term.name,
            kind: .function,
            detail: term.detail ?? "()",
            documentation: term.summary,
            insertText: term.name + "()",
            caretOffsetFromEnd: 1,
            // Superseded methods follow their replacements among equally good matches.
            priority: CompletionKind.function.basePriority + (deprecated ? 1 : 0),
            isDeprecated: deprecated
        )
    }

    static func keyword(_ term: MongoCompletionTerm) -> CompletionItem {
        CompletionItem(label: term.name, kind: .keyword, detail: term.detail, documentation: term.summary)
    }

    /// Operators and stages are object keys, inserted as typed: the user's `$` is part of the token.
    static func dollar(_ term: MongoCompletionTerm, kind: CompletionKind) -> CompletionItem {
        CompletionItem(label: term.name, kind: kind, documentation: term.summary)
    }

    /// `$field` and `$$VARIABLE` are string values; outside a string they are inserted with quotes.
    static func reference(_ name: String, kind: CompletionKind, documentation: String?, inString: Bool) -> CompletionItem {
        CompletionItem(label: name, kind: kind, documentation: documentation, insertText: inString ? name : quoted(name))
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A JavaScript identifier usable as an unquoted object key: letters of any script, digits, marks, `_` and `$`,
    /// not starting with a digit or a mark (`név` stays bare).
    static func isIdentifier(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard let first = scalars.first, first.properties.generalCategory != .decimalNumber, !MongoCompletionScanner.isMark(first) else { return false }
        return scalars.allSatisfy { $0 == "$" || MongoCompletionScanner.isWordScalar($0) }
    }

    /// `db.<name>` resolves for identifiers joined by dots (`db.my.coll`).
    static func isCollectionPath(_ name: String) -> Bool {
        name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { isIdentifier(String($0)) }
    }
}

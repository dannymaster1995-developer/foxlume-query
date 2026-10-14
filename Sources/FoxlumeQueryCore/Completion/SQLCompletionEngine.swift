import Foundation

/// SQL completion: context analysis, candidates per clause, matching, ranking and casing (spec 1–7, 10).
@MainActor
public final class SQLCompletionEngine: CompletionEngine {
    public let family: SQLDialect.Family?
    public weak var schema: CompletionSchemaProvider?

    public init(family: SQLDialect.Family?, schema: CompletionSchemaProvider?) {
        self.family = family
        self.schema = schema
    }

    public var triggerCharacters: Set<Character> { [".", " ", ":", "(", ","] }

    /// Re-filtering gives up on tokens longer than this (spec 1.5).
    static let maxRefilterTokenLength = 500

    public func complete(text: String, caret: Int, manual: Bool, keywordCase: KeywordCase) async -> CompletionResult? {
        guard let context = SQLContextAnalyzer.analyze(text: text, caret: caret, family: family) else { return nil }
        return await complete(context: context, manual: manual, keywordCase: keywordCase)
    }

    /// Candidates, ranking, limits and casing for an analyzed position.
    func complete(context: SQLCompletionContext, manual: Bool, keywordCase: KeywordCase) async -> CompletionResult? {
        if !manual, Self.staysShut(context) { return nil }
        let candidates = await candidates(for: context)
        let state = Self.refilterState(context)
        let limit = SQLCompletionRanking.limit(for: context.clause)
        // The pool is cut before casing so re-filtering starts from canonical text.
        let pool = SQLCompletionRanking.rank(candidates, prefix: context.prefix, state: state, keep: limit * 10)
        guard !pool.isEmpty else { return nil }
        let items = KeywordCasing.apply(items: Array(pool.prefix(limit)), prefix: context.prefix, policy: keywordCase)
        return CompletionResult(
            items: items,
            pool: pool,
            replacementRange: context.replacementRange,
            token: context.token,
            prefix: context.prefix,
            limit: limit,
            refilterState: state
        )
    }

    public func refilter(_ result: CompletionResult, token: String, keywordCase: KeywordCase) -> [CompletionItem] {
        guard !token.isEmpty, token.utf16.count <= Self.maxRefilterTokenLength else { return [] }
        // A bare quote re-ranks to nothing; the next character asks again with a proper analysis.
        guard token.contains(where: { $0 != "`" && $0 != "\"" }) else { return [] }
        let prefix = SQLCaretScanner.stripQuotes(token)
        let ranked = SQLCompletionRanking.rank(result.pool, prefix: prefix, state: result.refilterState, keep: result.limit)
        return KeywordCasing.apply(items: ranked, prefix: prefix, policy: keywordCase)
    }

    /// The filter bar's Raw SQL box: `fragment` is analyzed as `WHERE <fragment>` with `table` as the only table (spec 10).
    public func completeFilter(fragment: String, caret: Int, table: TableRef, keywordCase: KeywordCase) async -> CompletionResult? {
        guard !fragment.isEmpty else { return nil }
        let lead = "WHERE "
        let offset = (lead as NSString).length
        let caret = min(max(caret, 0), (fragment as NSString).length)
        guard var context = SQLContextAnalyzer.analyze(text: lead + fragment, caret: caret + offset, family: family) else { return nil }
        let forced = SQLTableReference(schema: table.schema, table: table.name)
        context.references = [forced]
        context.targetTable = forced
        context.replacementRange.location -= offset
        context.statementRange = NSRange(location: 0, length: (fragment as NSString).length)
        // Same trigger policy as typing in the editor: a finished condition shows nothing, so Return applies it.
        return await complete(context: context, manual: false, keywordCase: keywordCase)
    }

    // MARK: Policy

    /// Clauses with a short, closed list that open with nothing typed (spec 1.2).
    static let opensWithoutPrefix: Set<SQLClause> = [
        .from, .join, .into, .set, .insertColumns, .on, .alterTableColumn, .returning, .using, .dropObject,
        .createIndex, .castTarget,
    ]

    /// An automatic request with nothing typed stays shut outside the clauses above (spec 1.2).
    static func staysShut(_ context: SQLCompletionContext) -> Bool {
        guard context.prefix.isEmpty, context.token.isEmpty, context.qualifier == nil else { return false }
        if context.clause == .selectList { return context.isAfterComma }
        return !opensWithoutPrefix.contains(context.clause)
    }

    static func refilterState(_ context: SQLCompletionContext) -> CompletionRefilterState {
        CompletionRefilterState(
            context: context.clause.rawValue,
            hasTablesInScope: !context.references.isEmpty,
            isAfterComma: context.isAfterComma,
            expectsObjectName: context.expectsObjectName
        )
    }
}

import Foundation

/// What a suggestion stands for; decides its badge and base priority (see analysis/autocomplete-spec.md 4.1).
public enum CompletionKind: String, Sendable, CaseIterable {
    case favorite
    case column
    case alias
    case table
    case view
    case function
    case `operator`
    case keyword
    case schema
    case database
    /// Redis keys in the key tree.
    case key

    /// SF Symbol drawn as the row badge.
    public var symbolName: String {
        switch self {
        case .favorite: return "star.circle.fill"
        case .column: return "c.circle.fill"
        case .alias: return "a.circle.fill"
        case .table: return "t.circle.fill"
        case .view: return "v.circle.fill"
        case .function: return "f.circle.fill"
        case .operator: return "equal.circle.fill"
        case .keyword: return "k.circle.fill"
        case .schema: return "s.circle.fill"
        case .database: return "d.circle.fill"
        case .key: return "key.fill"
        }
    }

    /// Lower ranks first among equally good matches.
    public var basePriority: Int {
        switch self {
        case .favorite: return 50
        case .column: return 100
        case .alias: return 150
        case .table: return 200
        case .view: return 210
        case .key: return 220
        case .function: return 300
        case .operator: return 350
        case .keyword: return 400
        case .schema, .database: return 500
        }
    }
}

/// One row of the suggestion list.
public struct CompletionItem: Hashable, Sendable {
    /// What the list shows. Typing filters on `filterText`.
    public var label: String
    public var kind: CompletionKind
    /// Secondary text after the label, for example `PK, NOT NULL, INT` or `COUNT(expr)`.
    public var detail: String?
    /// Longer help; the popup shows its first line under the list.
    public var documentation: String?
    /// Text that replaces the typed token.
    public var insertText: String
    /// Where the caret lands, counted back from the end of `insertText` (1 puts it inside `()`).
    public var caretOffsetFromEnd: Int
    /// Ranking priority (lower first); defaults to the kind's base priority.
    public var priority: Int
    /// Lowercased text matched against the typed prefix; defaults to the lowercased label.
    public var filterText: String
    /// Keywords, functions, operators and types follow the keyword-case setting; names never do.
    public var followsKeywordCase: Bool
    /// UTF-16 ranges of `label` matched by the typed prefix; drawn bold.
    public var highlights: [NSRange]
    /// Drawn grey with a warning sign (deprecated Mongo shell methods).
    public var isDeprecated: Bool

    public init(
        label: String,
        kind: CompletionKind,
        detail: String? = nil,
        documentation: String? = nil,
        insertText: String? = nil,
        caretOffsetFromEnd: Int = 0,
        priority: Int? = nil,
        filterText: String? = nil,
        followsKeywordCase: Bool = false,
        isDeprecated: Bool = false
    ) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText ?? label
        self.caretOffsetFromEnd = caretOffsetFromEnd
        self.priority = priority ?? kind.basePriority
        self.filterText = filterText ?? label.lowercased()
        self.followsKeywordCase = followsKeywordCase
        self.highlights = []
        self.isDeprecated = isDeprecated
    }
}

/// The answer for one caret position. `items` is what the popup shows; `pool` is the wider, already ranked
/// list (canonical case) kept so typing can re-filter locally without a new analysis (spec 1.5).
public struct CompletionResult: Sendable {
    public var items: [CompletionItem]
    public var pool: [CompletionItem]
    /// UTF-16 range in the editor text that an accepted item replaces: token start to caret.
    public var replacementRange: NSRange
    /// The typed token, quotes included.
    public var token: String
    /// The token with identifier quotes stripped; what matching used.
    public var prefix: String
    /// Rows shown at most (40 or 20 for SQL; Int.max for Mongo).
    public var limit: Int
    /// Opaque engine state needed to re-rank the pool for a longer or shorter token.
    public var refilterState: CompletionRefilterState

    public init(items: [CompletionItem], pool: [CompletionItem], replacementRange: NSRange, token: String, prefix: String, limit: Int, refilterState: CompletionRefilterState = CompletionRefilterState()) {
        self.items = items
        self.pool = pool
        self.replacementRange = replacementRange
        self.token = token
        self.prefix = prefix
        self.limit = limit
        self.refilterState = refilterState
    }
}

/// What an engine remembers from the analysis to re-rank its pool as the user keeps typing.
public struct CompletionRefilterState: Sendable, Hashable {
    /// Engine-defined tag (for example the SQL clause's raw value), used for clause bonuses.
    public var context: String
    public var hasTablesInScope: Bool
    public var isAfterComma: Bool
    public var expectsObjectName: Bool

    public init(context: String = "", hasTablesInScope: Bool = false, isAfterComma: Bool = false, expectsObjectName: Bool = false) {
        self.context = context
        self.hasTablesInScope = hasTablesInScope
        self.isAfterComma = isAfterComma
        self.expectsObjectName = expectsObjectName
    }
}

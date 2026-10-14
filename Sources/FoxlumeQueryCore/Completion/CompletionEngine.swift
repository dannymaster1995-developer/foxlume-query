import Foundation

/// How completed keywords are cased (spec 5.3). Names (tables, columns…) are never re-cased.
public enum KeywordCase: String, Codable, CaseIterable, Sendable {
    case upper
    case lower
    /// Follow the first cased letter typed; UPPERCASE when there is none. The default.
    case matchTypedElseUpper
    case matchTypedElseLower

    public var title: String {
        switch self {
        case .upper: return "UPPERCASE"
        case .lower: return "lowercase"
        case .matchTypedElseUpper: return "Match what I type, otherwise UPPERCASE"
        case .matchTypedElseLower: return "Match what I type, otherwise lowercase"
        }
    }
}

/// A saved query offered when its keyword is typed (spec 7). Foxlume Query has no favorites store yet; providers return [].
public struct CompletionFavorite: Sendable, Hashable {
    public var keyword: String
    public var name: String
    public var query: String

    public init(keyword: String, name: String, query: String) {
        self.keyword = keyword
        self.name = name
        self.query = query
    }
}

/// A dotted document field path sampled from a MongoDB collection, with its BSON type name.
public struct CompletionField: Sendable, Hashable {
    public var path: String
    public var typeName: String

    public init(path: String, typeName: String) {
        self.path = path
        self.typeName = typeName
    }
}

/// Everything an engine may ask about the connection. Implemented by the app's workspace, which caches
/// and loads lazily; every method may suspend for a server round trip. Called on the main actor.
@MainActor
public protocol CompletionSchemaProvider: AnyObject {
    /// Tables and views nameable without a schema (spec 3.5).
    func unqualifiedTables() async -> [TableInfo]
    /// Tables and views of one schema, loaded on demand; nil when the schema is unknown.
    func tables(inSchema schema: String) async -> [TableInfo]?
    func schemaNames() async -> [String]
    func databaseNames() async -> [String]
    /// The schema unqualified names resolve to (`public`, `main`), if the engine has one.
    func implicitSchema() async -> String?
    /// Columns of a table, fetched on first use and cached; nil when the table is unknown or unreadable.
    func columns(of table: TableRef) async -> [ColumnInfo]?
    /// Columns already cached, for completion with no table in scope (never triggers a fetch).
    func cachedColumns() -> [(table: TableRef, columns: [ColumnInfo])]
    /// MongoDB: dotted field paths sampled from a collection.
    func documentFields(of collection: String) async -> [CompletionField]
    /// Redis: key names starting with `prefix`, from the key tree.
    func keyNames(prefix: String, limit: Int) async -> [String]
    func favorites() -> [CompletionFavorite]
}

/// A completer for one query language.
@MainActor
public protocol CompletionEngine: AnyObject {
    /// Characters (besides letters and digits) whose insertion asks for suggestions (spec 1.1).
    var triggerCharacters: Set<Character> { get }
    /// Suggestions at `caret` (UTF-16) in `text`, or nil for no popup. `manual` is ⌃Space / Escape:
    /// it skips the empty-prefix trigger policy but not the hard suppressions.
    func complete(text: String, caret: Int, manual: Bool, keywordCase: KeywordCase) async -> CompletionResult?
    /// Re-filters and re-ranks `result.pool` for the live token (typing or backspacing inside the same token).
    /// Returns the visible items, cased and limited; empty means close the popup.
    func refilter(_ result: CompletionResult, token: String, keywordCase: KeywordCase) -> [CompletionItem]
}

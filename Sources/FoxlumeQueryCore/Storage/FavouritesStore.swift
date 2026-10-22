import Foundation

/// A table, view, collection, procedure, function, trigger or type as the sidebar's Favourites and Recent sections
/// keep it: where it lives (database and schema) and what it is, enough to open it again without the catalog.
public struct SidebarItemRef: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case table
        case view
        case materializedView
        case foreignTable
        case systemTable
        case procedure
        case function
        case trigger
        case type

        public init?(_ kind: TableKind) {
            switch kind {
            case .table: self = .table
            case .view: self = .view
            case .materializedView: self = .materializedView
            case .foreignTable: self = .foreignTable
            case .systemTable: self = .systemTable
            // Redis logical databases are browsed, not kept.
            case .keyspace: return nil
            }
        }

        public init(_ kind: SchemaObjectKind) {
            switch kind {
            case .procedure: self = .procedure
            case .function: self = .function
            case .trigger: self = .trigger
            case .type: self = .type
            }
        }

        public var tableKind: TableKind? {
            switch self {
            case .table: return .table
            case .view: return .view
            case .materializedView: return .materializedView
            case .foreignTable: return .foreignTable
            case .systemTable: return .systemTable
            case .procedure, .function, .trigger, .type: return nil
            }
        }

        public var objectKind: SchemaObjectKind? {
            switch self {
            case .procedure: return .procedure
            case .function: return .function
            case .trigger: return .trigger
            case .type: return .type
            case .table, .view, .materializedView, .foreignTable, .systemTable: return nil
            }
        }
    }

    public var kind: Kind
    /// The database the session used when the item was kept; nil for engines that report none.
    public var database: String?
    /// The table ref's schema (PostgreSQL, DuckDB) or the object's schema; nil where the engine has none.
    public var schema: String?
    public var name: String
    /// A trigger's table.
    public var table: String?
    /// A routine's argument list and argument types, as `SchemaObject` has them.
    public var arguments: String?
    public var identityArguments: String?
    /// A routine's language or a type's kind, for the icon.
    public var detail: String?

    public init(kind: Kind, database: String?, schema: String?, name: String, table: String? = nil,
                arguments: String? = nil, identityArguments: String? = nil, detail: String? = nil) {
        self.kind = kind
        self.database = database
        self.schema = schema
        self.name = name
        self.table = table
        self.arguments = arguments
        self.identityArguments = identityArguments
        self.detail = detail
    }

    /// A table, view or collection of `database`; nil for a Redis keyspace.
    public init?(table: TableRef, kind: TableKind, database: String?) {
        guard let kind = Kind(kind) else { return nil }
        self.init(kind: kind, database: database, schema: table.schema, name: table.name)
    }

    public init(object: SchemaObject, database: String?) {
        self.init(kind: Kind(object.kind), database: database, schema: object.schema, name: object.name, table: object.table,
                  arguments: object.arguments, identityArguments: object.identityArguments, detail: object.detail)
    }

    public var isTableLike: Bool { kind.tableKind != nil }

    /// The table to open, for tables, views and collections.
    public var tableRef: TableRef? {
        isTableLike ? TableRef(schema: schema, name: name) : nil
    }

    /// The object to open, for procedures, functions, triggers and types. Its source is read again when it opens.
    public var schemaObject: SchemaObject? {
        guard let objectKind = kind.objectKind else { return nil }
        return SchemaObject(kind: objectKind, schema: schema, name: name, arguments: arguments,
                            identityArguments: identityArguments, table: table, detail: detail)
    }

    /// What tells two items apart: tables and views share one namespace (a table that became a view is the same
    /// entry); objects are told apart by kind, table and argument types as `SchemaObject.id` does.
    public var identity: String {
        let place = [database ?? "", schema ?? ""]
        if isTableLike { return (["t"] + place + [name]).joined(separator: "\u{1F}") }
        return (["o", kind.rawValue] + place + [table ?? "", name, identityArguments ?? arguments ?? ""]).joined(separator: "\u{1F}")
    }

    /// Words the sidebar filter matches: the name, and a trigger's table.
    public var searchText: String {
        [name, table].compactMap { $0 }.joined(separator: " ")
    }

    /// Whether the item lies in the database and schema the sidebar browses. Objects of engines without schemas carry
    /// their database as schema (MySQL), so only the database is compared for them.
    public func isIn(database currentDatabase: String?, schema currentSchema: String?, schemasMatter: Bool) -> Bool {
        guard database == currentDatabase else { return false }
        if !schemasMatter { return isTableLike ? schema == nil || schema == currentSchema : true }
        return schema == currentSchema
    }

    /// "shop", "shop.sales" or "sales": where the item lives, for rows outside the browsed database and schema.
    public func locationLabel(currentDatabase: String?) -> String {
        let schemaPart = schema.flatMap { $0.isEmpty || $0 == database ? nil : $0 }
        if database != currentDatabase, let database, !database.isEmpty {
            return [database, schemaPart].compactMap { $0 }.joined(separator: ".")
        }
        return schemaPart ?? database ?? ""
    }
}

/// Favourite and recently opened sidebar items per connection, and which of the two sections are collapsed, in one
/// JSON file in the data folder. Favourites keep the order the user gave them; Recent keeps the last
/// `recentLimit` tables and views opened, newest first. A file that cannot be read in full is moved aside untouched,
/// and whatever still decodes is kept.
public final class FavouritesStore: @unchecked Sendable {
    public static let recentLimit = 10
    /// Posted after every change, with the store as object.
    public static let didChangeNotification = Notification.Name("FoxlumeQuery.FavouritesStore.didChange")

    public enum Section: String, Codable, Sendable, CaseIterable {
        case favourites
        case recent
    }

    private let url: URL
    private let lock = NSLock()
    private var cache: File?

    /// Set when the file could not be read in full: the original was moved here.
    public private(set) var setAsideFile: URL?

    public init(url: URL = AppPaths.favouritesFile) {
        self.url = url
    }

    struct Lists: Codable, Equatable {
        var favourites: [SidebarItemRef] = []
        var recent: [SidebarItemRef] = []

        var isEmpty: Bool { favourites.isEmpty && recent.isEmpty }
    }

    struct File: Codable {
        var version: Int? = 1
        /// Connection id → its lists.
        var connections: [String: Lists] = [:]
        var collapsed: [Section] = []
    }

    // MARK: Reading

    public func favourites(for connection: UUID) -> [SidebarItemRef] {
        file.connections[connection.uuidString]?.favourites ?? []
    }

    /// Newest first.
    public func recent(for connection: UUID) -> [SidebarItemRef] {
        file.connections[connection.uuidString]?.recent ?? []
    }

    public func isFavourite(_ item: SidebarItemRef, connection: UUID) -> Bool {
        favourites(for: connection).contains { $0.identity == item.identity }
    }

    /// The kept copy of an item (for its kind when the caller does not know it), favourites first.
    public func stored(_ item: SidebarItemRef, connection: UUID) -> SidebarItemRef? {
        let lists = file.connections[connection.uuidString]
        return (lists?.favourites ?? []).first { $0.identity == item.identity } ?? (lists?.recent ?? []).first { $0.identity == item.identity }
    }

    public func isCollapsed(_ section: Section) -> Bool {
        file.collapsed.contains(section)
    }

    // MARK: Favourites

    /// Adds the item at the end; an item already there is only refreshed (its kind and details).
    public func addFavourite(_ item: SidebarItemRef, connection: UUID) throws {
        try mutate(connection) { lists in
            if let index = lists.favourites.firstIndex(where: { $0.identity == item.identity }) {
                lists.favourites[index] = item
            } else {
                lists.favourites.append(item)
            }
        }
    }

    public func removeFavourite(_ item: SidebarItemRef, connection: UUID) throws {
        try mutate(connection) { lists in lists.favourites.removeAll { $0.identity == item.identity } }
    }

    /// Adds or removes; returns whether the item is a favourite afterwards.
    @discardableResult
    public func toggleFavourite(_ item: SidebarItemRef, connection: UUID) throws -> Bool {
        if isFavourite(item, connection: connection) {
            try removeFavourite(item, connection: connection)
            return false
        }
        try addFavourite(item, connection: connection)
        return true
    }

    /// Moves a favourite in front of `before`, or to the end when `before` is nil or not a favourite.
    public func moveFavourite(_ item: SidebarItemRef, before: SidebarItemRef?, connection: UUID) throws {
        guard item.identity != before?.identity else { return }
        try mutate(connection) { lists in
            guard let from = lists.favourites.firstIndex(where: { $0.identity == item.identity }) else { return }
            let moving = lists.favourites.remove(at: from)
            let to = before.flatMap { target in lists.favourites.firstIndex { $0.identity == target.identity } } ?? lists.favourites.endIndex
            lists.favourites.insert(moving, at: to)
        }
    }

    // MARK: Recent

    /// Puts a table or view first in Recent; the oldest beyond `recentLimit` are forgotten. Objects are not kept.
    public func recordOpened(_ item: SidebarItemRef, connection: UUID) throws {
        guard item.isTableLike else { return }
        guard recent(for: connection).first != item else { return }
        try mutate(connection) { lists in
            lists.recent.removeAll { $0.identity == item.identity }
            lists.recent.insert(item, at: 0)
            if lists.recent.count > Self.recentLimit { lists.recent.removeLast(lists.recent.count - Self.recentLimit) }
        }
    }

    public func removeRecent(_ item: SidebarItemRef, connection: UUID) throws {
        try mutate(connection) { lists in lists.recent.removeAll { $0.identity == item.identity } }
    }

    public func clearRecent(connection: UUID) throws {
        try mutate(connection) { lists in lists.recent.removeAll() }
    }

    // MARK: Renames and drops

    /// The object was renamed (Rename in the sidebar): both lists follow, in place.
    public func renameObject(_ item: SidebarItemRef, to newName: String, connection: UUID) throws {
        try moveItems(connection: connection) { stored in
            guard stored.identity == item.identity else { return nil }
            var renamed = stored
            renamed.name = newName
            return renamed
        }
    }

    /// The object was dropped: it leaves both lists.
    public func removeObject(_ item: SidebarItemRef, connection: UUID) throws {
        try mutate(connection) { lists in
            lists.favourites.removeAll { $0.identity == item.identity }
            lists.recent.removeAll { $0.identity == item.identity }
        }
    }

    /// Gives items `rename` maps a new location or name. When two items end up the same, the first one stays.
    func moveItems(connection: UUID, _ rename: (SidebarItemRef) -> SidebarItemRef?) throws {
        let lists = file.connections[connection.uuidString] ?? Lists()
        guard (lists.favourites + lists.recent).contains(where: { rename($0) != nil }) else { return }
        try mutate(connection) { lists in
            func moved(_ items: [SidebarItemRef]) -> [SidebarItemRef] {
                var seen = Set<String>()
                return items.map { rename($0) ?? $0 }.filter { seen.insert($0.identity).inserted }
            }
            lists.favourites = moved(lists.favourites)
            lists.recent = moved(lists.recent)
        }
    }

    /// Forgets a deleted connection.
    public func removeConnection(_ connection: UUID) throws {
        guard file.connections[connection.uuidString] != nil else { return }
        try write { file in file.connections[connection.uuidString] = nil }
    }

    // MARK: Sections

    public func setCollapsed(_ section: Section, _ collapsed: Bool) throws {
        guard isCollapsed(section) != collapsed else { return }
        try write { file in
            file.collapsed.removeAll { $0 == section }
            if collapsed { file.collapsed.append(section) }
        }
    }

    // MARK: File

    private var file: File {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let loaded = load()
        cache = loaded
        return loaded
    }

    private func load() -> File {
        guard let data = try? Data(contentsOf: url) else { return File() }
        if let file = try? JSONDecoder().decode(File.self, from: data) { return file }
        let partial = (try? JSONDecoder().decode(LossyFile.self, from: data))?.file ?? File()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var aside = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).unreadable-\(stamp).json")
        if FileManager.default.fileExists(atPath: aside.path) {
            aside = aside.deletingPathExtension().appendingPathExtension("\(UUID().uuidString.prefix(8)).json")
        }
        if (try? FileManager.default.moveItem(at: url, to: aside)) != nil {
            setAsideFile = aside
        }
        return partial
    }

    /// Keeps every item and section that still decodes from a damaged file.
    private struct LossyFile: Decodable {
        var file = File()

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let connections = (try? container.decode([String: LossyLists].self, forKey: .connections)) ?? [:]
            file.connections = connections.mapValues { Lists(favourites: $0.favourites, recent: $0.recent) }.filter { !$0.value.isEmpty }
            file.collapsed = ((try? container.decode([Lossy<Section>].self, forKey: .collapsed)) ?? []).compactMap(\.value)
        }

        enum CodingKeys: String, CodingKey {
            case connections
            case collapsed
        }
    }

    private struct LossyLists: Decodable {
        var favourites: [SidebarItemRef]
        var recent: [SidebarItemRef]

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            favourites = ((try? container?.decode([Lossy<SidebarItemRef>].self, forKey: .favourites)) ?? []).compactMap(\.value)
            recent = ((try? container?.decode([Lossy<SidebarItemRef>].self, forKey: .recent)) ?? []).compactMap(\.value)
        }

        enum CodingKeys: String, CodingKey {
            case favourites
            case recent
        }
    }

    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private func mutate(_ connection: UUID, _ change: (inout Lists) -> Void) throws {
        let key = connection.uuidString
        let before = file.connections[key] ?? Lists()
        var lists = before
        change(&lists)
        guard lists != before else { return }
        try write { file in file.connections[key] = lists.isEmpty ? nil : lists }
    }

    private func write(_ change: (inout File) -> Void) throws {
        var updated = file
        change(&updated)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(updated)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        lock.lock()
        cache = updated
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

/// The rows of the sidebar's Favourites and Recent sections, from the stored lists and what the sidebar browses.
public enum SidebarSections {
    public struct Row: Hashable, Sendable {
        public var item: SidebarItemRef
        /// Where the item lives, shown after its name; nil inside the browsed database and schema.
        public var location: String?
        /// The browsed database and schema were read and the item is not in them.
        public var isMissing: Bool

        public init(item: SidebarItemRef, location: String? = nil, isMissing: Bool = false) {
            self.item = item
            self.location = location
            self.isMissing = isMissing
        }
    }

    /// What the sidebar shows: the database and schema, and whether its lists of tables and objects are complete.
    public struct Browsed: Sendable {
        public var database: String?
        public var schema: String?
        /// PostgreSQL and DuckDB; elsewhere an item's schema is not compared.
        public var schemasMatter: Bool
        /// Names of the tables, views and collections listed, or nil while they are not known.
        public var tables: Set<String>?
        /// `SidebarItemRef.identity` of the objects listed per kind, for the kinds whose list is known.
        public var objects: [SchemaObjectKind: Set<String>]

        public init(database: String?, schema: String?, schemasMatter: Bool, tables: Set<String>? = nil, objects: [SchemaObjectKind: Set<String>] = [:]) {
            self.database = database
            self.schema = schema
            self.schemasMatter = schemasMatter
            self.tables = tables
            self.objects = objects
        }

        public func contains(_ item: SidebarItemRef) -> Bool {
            item.isIn(database: database, schema: schema, schemasMatter: schemasMatter)
        }

        /// nil when it cannot be told: outside the browsed scope, or its list is not loaded.
        public func exists(_ item: SidebarItemRef) -> Bool? {
            guard contains(item) else { return nil }
            if item.isTableLike { return tables.map { $0.contains(item.name) } }
            guard let kind = item.kind.objectKind, let known = objects[kind] else { return nil }
            return known.contains(item.identity)
        }
    }

    /// Favourites in the user's order. Items that are not there any more stay, marked missing.
    public static func favouriteRows(_ items: [SidebarItemRef], browsed: Browsed, filter: String) -> [Row] {
        items.filter { matches($0, filter) }.map { row($0, browsed) }
    }

    /// Recent tables and views of the browsed database and schema first, then the others, each newest first. Items
    /// known to be gone are left out.
    public static func recentRows(_ items: [SidebarItemRef], browsed: Browsed, filter: String, limit: Int = FavouritesStore.recentLimit) -> [Row] {
        let rows = items.prefix(limit).filter { matches($0, filter) }.map { row($0, browsed) }.filter { !$0.isMissing }
        return rows.filter { $0.location == nil } + rows.filter { $0.location != nil }
    }

    static func matches(_ item: SidebarItemRef, _ filter: String) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty || item.searchText.lowercased().contains(needle)
    }

    private static func row(_ item: SidebarItemRef, _ browsed: Browsed) -> Row {
        let inside = browsed.contains(item)
        return Row(item: item, location: inside ? nil : item.locationLabel(currentDatabase: browsed.database),
                   isMissing: browsed.exists(item) == false)
    }
}

import Foundation

/// A query the user keeps for later ("SQL favorite" in TablePro). Typing its keyword in the editor offers it.
public struct SavedQuery: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var sql: String
    /// Completion shortcut: typing it in the editor offers this query. No whitespace; nil when unset.
    public var keyword: String?
    public var folderID: UUID?
    /// The one connection this query belongs to; nil offers it on every connection.
    public var connectionID: UUID?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        sql: String,
        keyword: String? = nil,
        folderID: UUID? = nil,
        connectionID: UUID? = nil,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.sql = sql
        self.keyword = keyword
        self.folderID = folderID
        self.connectionID = connectionID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Shown on `connectionID`: queries for every connection plus the ones saved for it.
    public func isVisible(on connectionID: UUID?) -> Bool {
        self.connectionID == nil || self.connectionID == connectionID
    }

    /// The first statement line, for list subtitles.
    public var preview: String {
        sql.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

/// A folder of saved queries. Folders nest through `parentID`.
public struct SavedQueryFolder: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    /// A folder for one connection holds only that connection's queries; nil holds any.
    public var connectionID: UUID?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        connectionID: UUID? = nil,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.connectionID = connectionID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public func isVisible(on connectionID: UUID?) -> Bool {
        self.connectionID == nil || self.connectionID == connectionID
    }

    /// A folder for every connection can hold anything; a connection's folder only that connection's queries.
    public func canHold(scope: UUID?) -> Bool {
        connectionID == nil || connectionID == scope
    }
}

/// Every saved query and folder, as stored.
public struct SavedQueryLibrary: Codable, Hashable, Sendable {
    public var folders: [SavedQueryFolder]
    public var queries: [SavedQuery]

    public init(folders: [SavedQueryFolder] = [], queries: [SavedQuery] = []) {
        self.folders = folders
        self.queries = queries
    }

    /// What one connection's window shows, folders and queries ordered for display.
    public func visible(on connectionID: UUID?) -> SavedQueryLibrary {
        let shownFolders = folders.filter { $0.isVisible(on: connectionID) }
        let folderIDs = Set(shownFolders.map(\.id))
        // A query in a folder that is not shown here (or no longer exists) appears at the top level.
        let shownQueries = queries.filter { $0.isVisible(on: connectionID) }.map { query -> SavedQuery in
            var query = query
            if let folder = query.folderID, !folderIDs.contains(folder) { query.folderID = nil }
            return query
        }
        return SavedQueryLibrary(folders: shownFolders.sorted(by: Self.folderOrder), queries: shownQueries.sorted(by: Self.queryOrder))
    }

    public func folder(id: UUID?) -> SavedQueryFolder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    public func query(id: UUID) -> SavedQuery? {
        queries.first { $0.id == id }
    }

    public func childFolders(of parent: UUID?) -> [SavedQueryFolder] {
        folders.filter { $0.parentID == parent }.sorted(by: Self.folderOrder)
    }

    public func queries(in folder: UUID?) -> [SavedQuery] {
        queries.filter { $0.folderID == folder }.sorted(by: Self.queryOrder)
    }

    /// `folder` and every folder below it.
    public func subtree(of folder: UUID) -> Set<UUID> {
        var result: Set<UUID> = [folder]
        var frontier = [folder]
        while let next = frontier.popLast() {
            for child in folders where child.parentID == next && !result.contains(child.id) {
                result.insert(child.id)
                frontier.append(child.id)
            }
        }
        return result
    }

    /// "Reports / Monthly" for a folder nested in "Reports".
    public func path(of folder: UUID?) -> String {
        var names: [String] = []
        var current = self.folder(id: folder)
        var seen: Set<UUID> = []
        while let folder = current, seen.insert(folder.id).inserted {
            names.insert(folder.name, at: 0)
            current = self.folder(id: folder.parentID)
        }
        return names.joined(separator: " / ")
    }

    /// How deep `folder` sits: 1 for a top-level folder, 0 for none.
    public func depth(of folder: UUID?) -> Int {
        var depth = 0
        var current = self.folder(id: folder)
        var seen: Set<UUID> = []
        while let folder = current, seen.insert(folder.id).inserted {
            depth += 1
            current = self.folder(id: folder.parentID)
        }
        return depth
    }

    static func folderOrder(_ lhs: SavedQueryFolder, _ rhs: SavedQueryFolder) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    static func queryOrder(_ lhs: SavedQuery, _ rhs: SavedQuery) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

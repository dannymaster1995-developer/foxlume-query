import Foundation

/// Saved queries and their folders, persisted as one JSON file in the data folder.
public final class SavedQueryStore: @unchecked Sendable {
    public static let didChangeNotification = Notification.Name("FoxlumeQuery.SavedQueryStore.didChange")

    private let url: URL
    private let lock = NSLock()
    private var cache: SavedQueryLibrary?

    public init(url: URL = AppPaths.savedQueriesFile) {
        self.url = url
    }

    /// Set when the file could not be read in full: the original was moved here untouched, so the next save
    /// cannot overwrite queries that failed to decode.
    public private(set) var setAsideFile: URL?

    public var library: SavedQueryLibrary {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let loaded = load()
        cache = loaded
        return loaded
    }

    /// What a connection's window shows: queries and folders for every connection plus its own.
    public func library(visibleOn connectionID: UUID?) -> SavedQueryLibrary {
        library.visible(on: connectionID)
    }

    private struct File: Codable {
        /// Format version, for future migrations; files without one are version 1.
        var version: Int? = 1
        var folders: [SavedQueryFolder]
        var queries: [SavedQuery]
    }

    private func load() -> SavedQueryLibrary {
        guard let data = try? Data(contentsOf: url) else { return SavedQueryLibrary() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(File.self, from: data) {
            return SavedQueryLibrary(folders: file.folders, queries: file.queries)
        }
        // Keep every entry that still decodes, and move the file aside before anything is written over it.
        let partial = try? decoder.decode(LossyFile.self, from: data)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = url.deletingLastPathComponent().appendingPathComponent("saved-queries.unreadable-\(stamp).json")
        if (try? FileManager.default.moveItem(at: url, to: aside)) != nil {
            setAsideFile = aside
        }
        return SavedQueryLibrary(folders: partial?.folders.compactMap(\.value) ?? [], queries: partial?.queries.compactMap(\.value) ?? [])
    }

    private struct LossyFile: Decodable {
        var folders: [Lossy<SavedQueryFolder>]
        var queries: [Lossy<SavedQuery>]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            folders = (try? container.decode([Lossy<SavedQueryFolder>].self, forKey: .folders)) ?? []
            queries = (try? container.decode([Lossy<SavedQuery>].self, forKey: .queries)) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case folders
            case queries
        }
    }

    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    // MARK: Queries

    public func query(id: UUID) -> SavedQuery? {
        library.query(id: id)
    }

    /// Adds or replaces a query; `updatedAt` is set to now.
    @discardableResult
    public func save(_ query: SavedQuery) throws -> SavedQuery {
        var saved = query
        saved.updatedAt = Date()
        try mutate { library in
            if let index = library.queries.firstIndex(where: { $0.id == saved.id }) {
                library.queries[index] = saved
            } else {
                library.queries.append(saved)
            }
        }
        return saved
    }

    public func deleteQuery(id: UUID) throws {
        try mutate { $0.queries.removeAll { $0.id == id } }
    }

    /// A copy named "<name> copy" in the same folder and scope. Keywords must stay unique, so the copy has none.
    @discardableResult
    public func duplicateQuery(id: UUID) throws -> SavedQuery? {
        guard let original = query(id: id) else { return nil }
        let copy = SavedQuery(name: original.name + " copy", sql: original.sql, keyword: nil, folderID: original.folderID,
                              connectionID: original.connectionID, sortOrder: original.sortOrder)
        return try save(copy)
    }

    /// Moves a query into `folder` (nil: the top level). A folder for another connection cannot hold it.
    public func moveQuery(id: UUID, to folder: UUID?) throws {
        try mutate { library in
            guard let index = library.queries.firstIndex(where: { $0.id == id }) else { return }
            if let target = library.folder(id: folder), !target.canHold(scope: library.queries[index].connectionID) {
                throw SavedQueryError.folderScope(target.name)
            }
            library.queries[index].folderID = folder
            library.queries[index].updatedAt = Date()
        }
    }

    // MARK: Folders

    @discardableResult
    public func saveFolder(_ folder: SavedQueryFolder) throws -> SavedQueryFolder {
        var saved = folder
        saved.updatedAt = Date()
        try mutate { library in
            // A folder can never sit inside itself or one of its own subfolders.
            if let parent = saved.parentID, library.subtree(of: saved.id).contains(parent) {
                throw SavedQueryError.folderCycle
            }
            if let index = library.folders.firstIndex(where: { $0.id == saved.id }) {
                library.folders[index] = saved
            } else {
                library.folders.append(saved)
            }
        }
        return saved
    }

    /// Deletes a folder; its queries and subfolders move up to its parent.
    public func deleteFolder(id: UUID) throws {
        try mutate { library in
            guard let folder = library.folder(id: id) else { return }
            for index in library.queries.indices where library.queries[index].folderID == id {
                library.queries[index].folderID = folder.parentID
            }
            for index in library.folders.indices where library.folders[index].parentID == id {
                library.folders[index].parentID = folder.parentID
            }
            library.folders.removeAll { $0.id == id }
        }
    }

    // MARK: Connections

    /// Removes the queries and folders that belonged only to a deleted connection.
    public func removeConnection(_ connectionID: UUID) throws {
        let current = library
        guard current.queries.contains(where: { $0.connectionID == connectionID }) || current.folders.contains(where: { $0.connectionID == connectionID }) else { return }
        try mutate { library in
            let removed = Set(library.folders.filter { $0.connectionID == connectionID }.map(\.id))
            library.queries.removeAll { $0.connectionID == connectionID }
            library.folders.removeAll { $0.connectionID == connectionID }
            // Global records inside a removed folder move to the top level; their subfolders lose the parent.
            for index in library.queries.indices where library.queries[index].folderID.map(removed.contains) == true {
                library.queries[index].folderID = nil
            }
            for index in library.folders.indices where library.folders[index].parentID.map(removed.contains) == true {
                library.folders[index].parentID = nil
            }
        }
    }

    /// Queries with a keyword that `connectionID` may complete. When two share a keyword, the connection's own wins,
    /// then the oldest.
    public func completionFavorites(for connectionID: UUID?) -> [CompletionFavorite] {
        let candidates = library.queries
            .filter { $0.isVisible(on: connectionID) && !($0.keyword ?? "").isEmpty }
            .sorted { lhs, rhs in
                if (lhs.connectionID != nil) != (rhs.connectionID != nil) { return lhs.connectionID != nil }
                return lhs.createdAt < rhs.createdAt
            }
        var seen: Set<String> = []
        return candidates.compactMap { query in
            guard let keyword = query.keyword, seen.insert(keyword.lowercased()).inserted else { return nil }
            return CompletionFavorite(keyword: keyword, name: query.name, query: query.sql)
        }
    }

    // MARK: Writing

    private func mutate(_ change: (inout SavedQueryLibrary) throws -> Void) throws {
        var updated = library
        try change(&updated)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(File(folders: updated.folders, queries: updated.queries))
        try data.write(to: url, options: .atomic)
        lock.lock()
        cache = updated
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

public enum SavedQueryError: LocalizedError, Equatable {
    case folderScope(String)
    case folderCycle

    public var errorDescription: String? {
        switch self {
        case .folderScope(let name): return "“\(name)” belongs to one connection and cannot hold this query."
        case .folderCycle: return "A folder cannot be moved into one of its own subfolders."
        }
    }
}

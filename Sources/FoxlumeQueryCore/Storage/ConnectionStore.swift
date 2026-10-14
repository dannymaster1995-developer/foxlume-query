import Foundation

/// Saved connections, persisted as JSON. Passwords are kept in `CredentialStore`, never here.
public final class ConnectionStore: @unchecked Sendable {
    public static let didChangeNotification = Notification.Name("FoxlumeQuery.ConnectionStore.didChange")

    private let url: URL
    private let lock = NSLock()
    private var cache: [ConnectionConfig]?

    public init(url: URL = AppPaths.connectionsFile) {
        self.url = url
    }

    /// Set when connections.json could not be read in full: the original was moved here untouched, so the next
    /// save cannot overwrite connections that failed to decode. The app tells the user about it.
    public private(set) var setAsideFile: URL?

    public func all() -> [ConnectionConfig] {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let loaded = load()
        cache = loaded
        return loaded
    }

    private func load() -> [ConnectionConfig] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([ConnectionConfig].self, from: data) { return list }
        // Keep whatever still decodes, and move the file aside before anything is written over it.
        let readable = (try? decoder.decode([Lossy].self, from: data))?.compactMap(\.value) ?? []
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = url.deletingLastPathComponent().appendingPathComponent("connections.unreadable-\(stamp).json")
        if (try? FileManager.default.moveItem(at: url, to: aside)) != nil {
            setAsideFile = aside
        }
        return readable
    }

    private struct Lossy: Decodable {
        var value: ConnectionConfig?
        init(from decoder: Decoder) throws {
            value = try? ConnectionConfig(from: decoder)
        }
    }

    public func connection(id: UUID) -> ConnectionConfig? {
        all().first { $0.id == id }
    }

    public func save(_ connection: ConnectionConfig) throws {
        var list = all()
        if let index = list.firstIndex(where: { $0.id == connection.id }) {
            list[index] = connection
        } else {
            list.append(connection)
        }
        try persist(list)
    }

    public func delete(id: UUID) throws {
        try persist(all().filter { $0.id != id })
    }

    public func markUsed(id: UUID) {
        guard var connection = connection(id: id) else { return }
        connection.lastUsedAt = Date()
        try? save(connection)
    }

    private func persist(_ list: [ConnectionConfig]) throws {
        try JSONFile.write(list, to: url)
        lock.lock()
        cache = list
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

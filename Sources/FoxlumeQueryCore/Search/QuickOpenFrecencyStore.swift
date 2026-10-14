import Foundation

/// When Open Quickly items were last opened, per connection, so often and recently used ones rank first.
/// Each item keeps its last few visits; a visit's weight halves every week. Stored as JSON in the data folder;
/// an unreadable file is simply started over, since it only orders results.
public final class QuickOpenFrecencyStore: @unchecked Sendable {
    public static let visitsPerItem = 10
    public static let itemsPerConnection = 100
    /// Opening the same item again this soon replaces the last visit instead of adding one, so flipping
    /// between two tabs does not inflate their counts.
    public static let repeatInterval: TimeInterval = 30
    static let halfLife: TimeInterval = 7 * 24 * 3600
    /// Visit weight that counts as fully "frecent" (score 1).
    static let saturation = 5.0

    private let url: URL
    private let lock = NSLock()
    /// Connection id → item key → visit times (seconds since 1970), oldest first.
    private var visits: [String: [String: [Double]]]

    public init(url: URL = AppPaths.openQuicklyFile) {
        self.url = url
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: [String: [Double]]].self, from: data) {
            visits = decoded
        } else {
            visits = [:]
        }
    }

    public func record(_ key: String, connection: UUID, at date: Date = Date()) {
        lock.lock()
        var items = visits[connection.uuidString] ?? [:]
        var times = items[key] ?? []
        let now = date.timeIntervalSince1970
        if let last = times.last, now - last < Self.repeatInterval {
            times[times.count - 1] = now
        } else {
            times.append(now)
        }
        items[key] = Array(times.suffix(Self.visitsPerItem))
        if items.count > Self.itemsPerConnection {
            // Forget the items whose last visit is oldest.
            let keep = items.sorted { ($0.value.last ?? 0) > ($1.value.last ?? 0) }.prefix(Self.itemsPerConnection)
            items = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        visits[connection.uuidString] = items
        let snapshot = visits
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 0…1 per item key: the visits' decayed weights summed, divided by `saturation` and capped at 1.
    public func scores(for connection: UUID, now: Date = Date()) -> [String: Double] {
        lock.lock()
        let items = visits[connection.uuidString] ?? [:]
        lock.unlock()
        return items.mapValues { times in
            let total = times.reduce(0) { sum, time in
                let age = max(0, now.timeIntervalSince1970 - time)
                return sum + pow(0.5, age / Self.halfLife)
            }
            return min(1, total / Self.saturation)
        }
    }

    /// Item keys of a connection, most recently opened first.
    public func recentKeys(for connection: UUID, limit: Int = QuickOpenRanker.recentLimit) -> [String] {
        lock.lock()
        let items = visits[connection.uuidString] ?? [:]
        lock.unlock()
        return items
            .sorted { ($0.value.last ?? 0) > ($1.value.last ?? 0) }
            .prefix(limit)
            .map(\.key)
    }

    /// Forgets a deleted connection.
    public func removeConnection(_ connection: UUID) {
        lock.lock()
        let removed = visits.removeValue(forKey: connection.uuidString) != nil
        let snapshot = visits
        lock.unlock()
        guard removed, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

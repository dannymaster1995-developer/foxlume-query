import CoreGraphics
import Foundation

/// The diagram a set of table positions belongs to: one connection, database and schema. MySQL has no schemas, so
/// the database tells its diagrams apart; SQLite and DuckDB files have one database.
public struct ERDiagramScope: Codable, Hashable, Sendable {
    public var connectionID: UUID
    public var database: String?
    public var schema: String?

    public init(connectionID: UUID, database: String?, schema: String?) {
        self.connectionID = connectionID
        self.database = database
        self.schema = schema
    }
}

/// Table positions the user arranged by dragging, per ER diagram, in one JSON file in the data folder. A file that
/// cannot be read in full is moved aside untouched, and whatever still decodes is kept.
public final class ERDiagramLayoutStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var cache: [Entry]?

    /// Set when the file could not be read in full: the original was moved here.
    public private(set) var setAsideFile: URL?

    public init(url: URL = AppPaths.erDiagramLayoutsFile) {
        self.url = url
    }

    struct Point: Codable, Hashable {
        var x: Double
        var y: Double
    }

    struct Entry: Codable {
        var scope: ERDiagramScope
        var tables: [String: Point]
    }

    private struct File: Codable {
        var version: Int? = 1
        var diagrams: [Entry]
    }

    /// Saved top-left corners by table name; empty when the diagram was never arranged.
    public func positions(for scope: ERDiagramScope) -> [String: CGPoint] {
        guard let entry = entries.first(where: { $0.scope == scope }) else { return [:] }
        return entry.tables.mapValues { CGPoint(x: $0.x, y: $0.y) }
    }

    /// Replaces the saved positions of one diagram. Positions that are not finite are dropped.
    public func setPositions(_ positions: [String: CGPoint], for scope: ERDiagramScope) throws {
        let points = positions.compactMapValues { point -> Point? in
            guard point.x.isFinite, point.y.isFinite else { return nil }
            return Point(x: (Double(point.x) * 10).rounded() / 10, y: (Double(point.y) * 10).rounded() / 10)
        }
        try mutate { entries in
            entries.removeAll { $0.scope == scope }
            if !points.isEmpty { entries.append(Entry(scope: scope, tables: points)) }
        }
    }

    /// Reset Layout: forget the arrangement of one diagram.
    public func clear(_ scope: ERDiagramScope) throws {
        guard entries.contains(where: { $0.scope == scope }) else { return }
        try mutate { entries in entries.removeAll { $0.scope == scope } }
    }

    // MARK: File

    private var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let loaded = load()
        cache = loaded
        return loaded
    }

    private func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let file = try? JSONDecoder().decode(File.self, from: data) { return file.diagrams }
        let partial = (try? JSONDecoder().decode(LossyFile.self, from: data))?.diagrams ?? []
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var aside = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).unreadable-\(stamp).json")
        if FileManager.default.fileExists(atPath: aside.path) {
            aside = aside.deletingPathExtension().appendingPathExtension("\(UUID().uuidString.prefix(8)).json")
        }
        if (try? FileManager.default.moveItem(at: url, to: aside)) != nil {
            setAsideFile = aside
        }
        return partial.compactMap { entry in
            guard let scope = entry.scope else { return nil }
            let tables = entry.tables.compactMapValues(\.value)
            return tables.isEmpty ? nil : Entry(scope: scope, tables: tables)
        }
    }

    private struct LossyFile: Decodable {
        var diagrams: [LossyEntry]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            diagrams = (try? container.decode([Lossy<LossyEntry>].self, forKey: .diagrams))?.compactMap(\.value) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case diagrams
        }
    }

    private struct LossyEntry: Decodable {
        var scope: ERDiagramScope?
        var tables: [String: Lossy<Point>]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scope = try? container.decode(ERDiagramScope.self, forKey: .scope)
            tables = (try? container.decode([String: Lossy<Point>].self, forKey: .tables)) ?? [:]
        }

        enum CodingKeys: String, CodingKey {
            case scope
            case tables
        }
    }

    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private func mutate(_ change: (inout [Entry]) throws -> Void) throws {
        var updated = entries
        try change(&updated)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(diagrams: updated))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        lock.lock()
        cache = updated
        lock.unlock()
    }
}

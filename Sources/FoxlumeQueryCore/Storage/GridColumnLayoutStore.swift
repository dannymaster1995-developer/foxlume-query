import Foundation

/// The table a grid column layout belongs to. MySQL tables carry no schema, so the database tells them apart.
public struct GridColumnLayoutScope: Codable, Hashable, Sendable {
    public var connectionID: UUID
    public var database: String?
    public var schema: String?
    public var table: String

    public init(connectionID: UUID, database: String?, schema: String?, table: String) {
        self.connectionID = connectionID
        self.database = database
        self.schema = schema
        self.table = table
    }
}

/// How the columns of a table's grid were arranged: their order, widths and which ones are hidden.
public struct GridColumnLayout: Codable, Hashable, Sendable {
    public struct Column: Codable, Hashable, Sendable {
        public var name: String
        /// Nil keeps the automatic width.
        public var width: Double?
        public var isHidden: Bool

        public init(name: String, width: Double? = nil, isHidden: Bool = false) {
            self.name = name
            self.width = width
            self.isHidden = isHidden
        }

        private enum CodingKeys: String, CodingKey {
            case name, width, isHidden = "hidden"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            width = try? container.decodeIfPresent(Double.self, forKey: .width)
            isHidden = (try? container.decodeIfPresent(Bool.self, forKey: .isHidden)) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(width, forKey: .width)
            if isHidden { try container.encode(true, forKey: .isHidden) }
        }
    }

    /// In on-screen order.
    public var columns: [Column]

    public init(columns: [Column]) {
        self.columns = columns
    }

    /// Where one of the grid's columns goes: its index in the result, its width (nil for automatic) and visibility.
    public struct Placement: Equatable, Sendable {
        public var index: Int
        public var width: Double?
        public var isHidden: Bool

        public init(index: Int, width: Double? = nil, isHidden: Bool = false) {
            self.index = index
            self.width = width
            self.isHidden = isHidden
        }
    }

    /// Places the result's columns (`names`, in result order). Saved columns that still exist keep their order, width
    /// and visibility; columns the layout does not know follow at the end, visible and at their automatic width;
    /// saved columns that no longer exist are ignored. When nothing would be visible, every column is shown.
    public func arrange(_ names: [String]) -> [Placement] {
        // Repeated names (possible in query results) are matched in order of appearance.
        var unplaced: [String: [Int]] = [:]
        for (index, name) in names.enumerated() { unplaced[name, default: []].append(index) }
        var placements: [Placement] = []
        for column in columns {
            guard var indexes = unplaced[column.name], !indexes.isEmpty else { continue }
            let index = indexes.removeFirst()
            unplaced[column.name] = indexes
            let width = column.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            placements.append(Placement(index: index, width: width, isHidden: column.isHidden))
        }
        let placed = Set(placements.map(\.index))
        placements += names.indices.filter { !placed.contains($0) }.map { Placement(index: $0) }
        if !placements.isEmpty, placements.allSatisfy(\.isHidden) {
            for index in placements.indices { placements[index].isHidden = false }
        }
        return placements
    }

    /// The natural arrangement: result order, automatic widths, nothing hidden.
    public static func defaultPlacements(count: Int) -> [Placement] {
        (0..<max(count, 0)).map { Placement(index: $0) }
    }
}

/// Column layouts of table grids, per connection, database, schema and table, in one JSON file in the data folder.
/// A file that cannot be read in full is moved aside untouched, and whatever still decodes is kept.
public final class GridColumnLayoutStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var cache: [Entry]?

    /// Set when the file could not be read in full: the original was moved here.
    public private(set) var setAsideFile: URL?

    public init(url: URL = AppPaths.gridColumnLayoutsFile) {
        self.url = url
    }

    struct Entry: Codable {
        var scope: GridColumnLayoutScope
        var layout: GridColumnLayout
    }

    private struct File: Codable {
        var version: Int? = 1
        var tables: [Entry]
    }

    /// The saved layout of one table, or nil when it was never changed (or was reset).
    public func layout(for scope: GridColumnLayoutScope) -> GridColumnLayout? {
        entries.first { $0.scope == scope }?.layout
    }

    /// Replaces the saved layout of one table. Widths are rounded to a tenth of a point; widths that are not finite
    /// or not positive fall back to automatic.
    public func setLayout(_ layout: GridColumnLayout, for scope: GridColumnLayoutScope) throws {
        var cleaned = layout
        for index in cleaned.columns.indices {
            cleaned.columns[index].width = cleaned.columns[index].width.flatMap { width in
                width.isFinite && width > 0 ? (width * 10).rounded() / 10 : nil
            }
        }
        try mutate { entries in
            entries.removeAll { $0.scope == scope }
            if !cleaned.columns.isEmpty { entries.append(Entry(scope: scope, layout: cleaned)) }
        }
    }

    /// Reset Column Layout: forget the arrangement of one table.
    public func clear(_ scope: GridColumnLayoutScope) throws {
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
        if let file = try? JSONDecoder().decode(File.self, from: data) { return file.tables }
        let partial = (try? JSONDecoder().decode(LossyFile.self, from: data))?.tables ?? []
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
            let columns = entry.columns.compactMap(\.value)
            return columns.isEmpty ? nil : Entry(scope: scope, layout: GridColumnLayout(columns: columns))
        }
    }

    private struct LossyFile: Decodable {
        var tables: [LossyEntry]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tables = (try? container.decode([Lossy<LossyEntry>].self, forKey: .tables))?.compactMap(\.value) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case tables
        }
    }

    private struct LossyEntry: Decodable {
        var scope: GridColumnLayoutScope?
        var columns: [Lossy<GridColumnLayout.Column>]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scope = try? container.decode(GridColumnLayoutScope.self, forKey: .scope)
            let layout = try? container.nestedContainer(keyedBy: LayoutKeys.self, forKey: .layout)
            columns = (try? layout?.decode([Lossy<GridColumnLayout.Column>].self, forKey: .columns)) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case scope
            case layout
        }

        enum LayoutKeys: String, CodingKey {
            case columns
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
        let data = try encoder.encode(File(tables: updated))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        lock.lock()
        cache = updated
        lock.unlock()
    }
}

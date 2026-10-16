import Foundation

/// A named set of filter-bar rules saved for one table.
public struct FilterPreset: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var rules: [FilterRule]
    public var logic: FilterLogic
    public var rawWhere: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, rules: [FilterRule], logic: FilterLogic = .and, rawWhere: String = "", createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.rules = rules
        self.logic = logic
        self.rawWhere = rawWhere
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, rules, logic, rawWhere, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        rules = try container.decodeIfPresent([FilterRule].self, forKey: .rules) ?? []
        logic = try container.decodeIfPresent(FilterLogic.self, forKey: .logic) ?? .and
        rawWhere = try container.decodeIfPresent(String.self, forKey: .rawWhere) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// Columns the rules name that `columns` lacks; such a preset still applies, those rules simply match nothing.
    public func missingColumns(in columns: [String]) -> [String] {
        let known = Set(columns)
        var missing: [String] = []
        for rule in rules where !known.contains(rule.column) && !missing.contains(rule.column) {
            missing.append(rule.column)
        }
        return missing
    }
}

/// The table a preset belongs to. MySQL tables carry no schema, so the database tells them apart.
public struct FilterPresetScope: Codable, Hashable, Sendable {
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

/// Filter presets for every table, in one JSON file in the data folder. A file that cannot be read in full is
/// moved aside untouched, and whatever still decodes is kept.
public final class FilterPresetStore: @unchecked Sendable {
    public static let didChangeNotification = Notification.Name("FoxlumeQuery.FilterPresetStore.didChange")

    private let url: URL
    private let lock = NSLock()
    private var cache: [Entry]?

    /// Set when the file could not be read in full: the original was moved here.
    public private(set) var setAsideFile: URL?

    public init(url: URL = AppPaths.filterPresetsFile) {
        self.url = url
    }

    private struct Entry: Codable {
        var scope: FilterPresetScope
        var presets: [FilterPreset]
    }

    private struct File: Codable {
        /// Format version, for future migrations.
        var version: Int? = 1
        var tables: [Entry]
    }

    /// The presets of one table, by name.
    public func presets(for scope: FilterPresetScope) -> [FilterPreset] {
        let presets = entries.first { $0.scope == scope }?.presets ?? []
        return presets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves the rules under `name`; a name the table already uses gets " (2)", " (3)"… as in TablePro.
    @discardableResult
    public func save(name: String, rules: [FilterRule], logic: FilterLogic, rawWhere: String, for scope: FilterPresetScope) throws -> FilterPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FilterPresetError.emptyName }
        var preset = FilterPreset(name: trimmed, rules: rules, logic: logic, rawWhere: rawWhere)
        try mutate { entries in
            let index = entries.firstIndex { $0.scope == scope } ?? {
                entries.append(Entry(scope: scope, presets: []))
                return entries.count - 1
            }()
            preset.name = Self.uniqueName(trimmed, taken: Set(entries[index].presets.map(\.name)))
            entries[index].presets.append(preset)
        }
        return preset
    }

    public func delete(id: UUID, for scope: FilterPresetScope) throws {
        try mutate { entries in
            guard let index = entries.firstIndex(where: { $0.scope == scope }) else { return }
            entries[index].presets.removeAll { $0.id == id }
            if entries[index].presets.isEmpty { entries.remove(at: index) }
        }
    }

    static func uniqueName(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base) (\(counter))") { counter += 1 }
        return "\(base) (\(counter))"
    }

    /// Gives entries whose scope `rename` maps a new scope; an entry already at a new scope is replaced.
    func moveEntries(_ rename: (FilterPresetScope) -> FilterPresetScope?) throws {
        let moves = entries.compactMap { entry in rename(entry.scope).map { (entry.scope, $0) } }
        guard !moves.isEmpty else { return }
        try mutate { entries in
            let targets = Set(moves.map(\.1))
            let sources = Set(moves.map(\.0))
            entries.removeAll { targets.contains($0.scope) && !sources.contains($0.scope) }
            for index in entries.indices {
                if let scope = rename(entries[index].scope) { entries[index].scope = scope }
            }
        }
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(File.self, from: data) { return file.tables }
        // Keep every preset that still decodes, and move the file aside before anything is written over it.
        let partial = (try? decoder.decode(LossyFile.self, from: data))?.tables ?? []
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
            let presets = entry.presets.compactMap(\.value)
            return presets.isEmpty ? nil : Entry(scope: scope, presets: presets)
        }
    }

    private struct LossyFile: Decodable {
        var tables: [LossyEntry]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tables = (try? container.decode([LossyEntry].self, forKey: .tables)) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case tables
        }
    }

    private struct LossyEntry: Decodable {
        var scope: FilterPresetScope?
        var presets: [Lossy<FilterPreset>]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scope = try? container.decode(FilterPresetScope.self, forKey: .scope)
            presets = (try? container.decode([Lossy<FilterPreset>].self, forKey: .presets)) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case scope
            case presets
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
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(File(tables: updated))
        try data.write(to: url, options: .atomic)
        lock.lock()
        cache = updated
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

public enum FilterPresetError: LocalizedError, Equatable {
    case emptyName

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Give the preset a name."
        }
    }
}

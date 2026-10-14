import Foundation

/// Built-in themes plus the user's own, stored one JSON file per theme in the data folder.
public final class ThemeStore: @unchecked Sendable {
    public static let shared = ThemeStore()
    public static let didChangeNotification = Notification.Name("FoxlumeQuery.ThemeStore.didChange")

    private let directory: URL
    private let lock = NSLock()
    private var userThemes: [ThemeDefinition] = []

    public init(directory: URL = AppPaths.dataDirectory.appendingPathComponent("themes", isDirectory: true)) {
        self.directory = directory
        reload()
    }

    public var themes: [ThemeDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return BuiltInThemes.all + userThemes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func theme(id: String) -> ThemeDefinition? {
        themes.first { $0.id == id }
    }

    public func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let loaded = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ThemeDefinition? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ThemeDefinition.self, from: data)
            }
        lock.lock()
        userThemes = loaded
        lock.unlock()
    }

    /// Saves a user theme, giving it a unique id and name when they clash with existing ones.
    @discardableResult
    public func save(_ theme: ThemeDefinition) throws -> ThemeDefinition {
        var theme = theme
        theme.isBuiltIn = false
        let others = themes.filter { $0.id != theme.id || $0.isBuiltIn }
        if others.contains(where: { $0.id == theme.id }) {
            theme.id += "-" + UUID().uuidString.prefix(6).lowercased()
        }
        if others.contains(where: { $0.name == theme.name }) {
            var number = 2
            while others.contains(where: { $0.name == "\(theme.name) \(number)" }) { number += 1 }
            theme.name = "\(theme.name) \(number)"
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(theme).write(to: fileURL(for: theme.id), options: .atomic)
        reload()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return theme
    }

    public func delete(id: String) {
        guard theme(id: id)?.isBuiltIn == false else { return }
        try? FileManager.default.removeItem(at: fileURL(for: id))
        reload()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Imports a VS Code theme (`.json`), an extension package (`.vsix`) or an Foxlume Query theme file.
    /// Returns the saved themes.
    public func importThemes(from url: URL) throws -> [ThemeDefinition] {
        let imported: [ThemeDefinition]
        if url.pathExtension.lowercased() == "vsix" {
            imported = try Self.themesFromVSIX(url)
        } else {
            let data = try Data(contentsOf: url)
            if let own = try? JSONDecoder().decode(ThemeDefinition.self, from: data), !own.colors.isEmpty {
                imported = [own]
            } else {
                let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-color-theme", with: "")
                imported = [try VSCodeThemeImporter.importTheme(from: data, fallbackName: name) { include in
                    try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(include))
                }]
            }
        }
        return try imported.map { try save($0) }
    }

    public func export(_ theme: ThemeDefinition, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(theme).write(to: url, options: .atomic)
    }

    private func fileURL(for id: String) -> URL {
        let safe = id.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    /// A `.vsix` is a zip; unpack it with the system unzip into a temporary folder.
    static func themesFromVSIX(_ url: URL) throws -> [ThemeDefinition] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("foxlume-vsix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", url.path, "-d", folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ThemeImportError.unreadable("the .vsix archive could not be unpacked") }
        return try VSCodeThemeImporter.themes(inExtensionAt: folder)
    }
}

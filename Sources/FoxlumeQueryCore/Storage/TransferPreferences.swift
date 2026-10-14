import Foundation

/// The last options used in the export and import sheets, kept in the data folder.
public struct TransferPreferences: Codable, Equatable, Sendable {
    public var export = TableExportOptions()
    public var csvImport = CSVImportOptions()
    public var sqlFile = SQLFileRunOptions()

    public init() {}

    public static var fileURL: URL { AppPaths.dataDirectory.appendingPathComponent("transfer-options.json") }

    /// The saved choices, or the defaults when nothing was saved or the file cannot be read.
    public static func load() -> TransferPreferences {
        JSONFile.read(TransferPreferences.self, from: fileURL) ?? TransferPreferences()
    }

    public func save() {
        try? JSONFile.write(self, to: Self.fileURL)
    }

    public init(from decoder: Decoder) throws {
        // Missing keys keep their defaults, so files from older versions still load.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        export = (try? container.decode(TableExportOptions.self, forKey: .export)) ?? TableExportOptions()
        csvImport = (try? container.decode(CSVImportOptions.self, forKey: .csvImport)) ?? CSVImportOptions()
        sqlFile = (try? container.decode(SQLFileRunOptions.self, forKey: .sqlFile)) ?? SQLFileRunOptions()
    }
}

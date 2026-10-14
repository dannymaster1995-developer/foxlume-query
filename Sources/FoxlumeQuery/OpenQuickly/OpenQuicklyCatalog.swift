import AppKit
import FoxlumeQueryCore

/// Everything Open Quickly can offer from the window it was opened in and the other open connections: tables and
/// views, databases, schemas, procedures, functions, triggers and types, saved queries and recent history. Tables of the connection's other schemas (MySQL:
/// other databases) are loaded on first need, through the completion cache, so a second visit costs nothing.
@MainActor
final class OpenQuicklyCatalog {
    static let historyFetchLimit = 200
    static let historyPerConnection = 50
    static let containerLimit = 40

    private weak var host: WorkspaceWindowController?
    private let others: [WorkspaceWindowController]
    private(set) var isLoadingContainers = false
    private var didRequestContainers = false
    private var otherContainerTables: [TableInfo] = []
    /// Called after the lazily loaded tables arrive.
    var onChange: (() -> Void)?

    init(host: WorkspaceWindowController, others: [WorkspaceWindowController]) {
        self.host = host
        self.others = others
    }

    func items() -> [QuickOpenItem] {
        guard let host else { return [] }
        var items = connectionItems(host, isCurrent: true)
        for other in others {
            items += connectionItems(other, isCurrent: false)
        }
        return items
    }

    // MARK: One connection

    private func connectionItems(_ window: WorkspaceWindowController, isCurrent: Bool) -> [QuickOpenItem] {
        let workspace = window.workspace
        let config = workspace.config
        let name = config.displayName
        let openTables = Set(window.tabs.tabs.compactMap(\.table))
        let currentContainer = workspace.kind.supportsSchemas ? workspace.currentSchema : workspace.currentDatabase
        func make(_ kind: QuickOpenKind, _ title: String, _ subtitle: String, _ target: QuickOpenItem.Target,
                  container: String? = nil, keyword: String? = nil, sql: String? = nil) -> QuickOpenItem {
            QuickOpenItem(kind: kind, title: title, subtitle: subtitle, target: target, connectionID: config.id, connectionName: name,
                          isCurrentConnection: isCurrent, container: container, keyword: keyword, sql: sql)
        }

        var items: [QuickOpenItem] = []
        let location = isCurrent ? (currentContainer ?? "") : Self.path([name, workspace.currentDatabase, workspace.kind.supportsSchemas ? workspace.currentSchema : nil])
        for info in workspace.tables where info.kind != .keyspace {
            var item = make(QuickOpenKind.kind(of: info.kind), info.name, location, .table(info.ref), container: info.ref.schema ?? currentContainer)
            item.isOpen = openTables.contains(info.ref)
            items.append(item)
        }
        if isCurrent {
            for info in otherContainerTables {
                let container = info.ref.schema ?? ""
                var item = make(QuickOpenKind.kind(of: info.kind), info.name, container, .table(info.ref), container: container)
                item.isOpen = openTables.contains(info.ref)
                item.isOutsideCurrentScope = true
                items.append(item)
            }
            if workspace.kind.supportsMultipleDatabases, workspace.capabilities.supportsDatabaseSwitching {
                for database in workspace.databases {
                    items.append(make(.database, database, database == workspace.currentDatabase ? "Current database" : "Database", .database(database)))
                }
            }
            if workspace.kind.supportsSchemas {
                for schema in workspace.schemas {
                    items.append(make(.schema, schema, schema == workspace.currentSchema ? "Current schema" : "Schema", .schema(schema)))
                }
            }
            // Procedures, functions, triggers and types of the browsed schema, labeled as in the sidebar.
            let objects = workspace.schemaObjects
            let labels = SchemaObject.labels(for: objects)
            for object in objects {
                let subtitle = object.kind == .trigger ? (object.table ?? location) : location
                items.append(make(QuickOpenKind.kind(of: object.kind), labels[object.id] ?? object.name, subtitle, .schemaObject(object),
                                  container: object.schema ?? currentContainer))
            }
        }

        // The current connection lists every query it can see; another one only adds the queries saved for it alone.
        let library = AppEnvironment.savedQueries.library(visibleOn: config.id)
        for query in library.queries where isCurrent || query.connectionID == config.id {
            let folder = library.path(of: query.folderID)
            var parts = [query.keyword, folder.isEmpty ? nil : folder].compactMap { $0 }
            if parts.isEmpty { parts = [query.preview] }
            if !isCurrent { parts.insert(name, at: 0) }
            items.append(make(.savedQuery, query.name, parts.joined(separator: " · "), .savedQuery(query.id), keyword: query.keyword, sql: query.sql))
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        var seen: Set<String> = []
        for entry in AppEnvironment.history.search("", connectionID: config.id, limit: Self.historyFetchLimit) {
            let text = entry.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(text).inserted else { continue }
            var parts = [formatter.localizedString(for: entry.executedAt, relativeTo: Date())]
            if let database = entry.database, !database.isEmpty { parts.append(database) }
            if !isCurrent { parts.insert(name, at: 0) }
            items.append(make(.history, QuickOpenItem.singleLine(text), parts.joined(separator: " · "), .history(entry.id), sql: entry.sql))
            if seen.count == Self.historyPerConnection { break }
        }
        return items
    }

    private static func path(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
    }

    // MARK: Other schemas

    /// Starts loading the tables of the other schemas (MySQL: databases) once; `onChange` reports the result.
    func loadOtherContainers() {
        guard !didRequestContainers, let workspace = host?.workspace, workspace.kind.isSQL else { return }
        didRequestContainers = true
        let names: [String]
        if workspace.kind.supportsSchemas {
            names = workspace.schemas.filter { $0 != workspace.currentSchema && !Self.isSystemSchema($0) }
        } else if workspace.kind.supportsMultipleDatabases {
            names = workspace.databases.filter { $0 != workspace.currentDatabase }
        } else {
            names = []
        }
        guard !names.isEmpty else { return }
        isLoadingContainers = true
        onChange?()
        Task { [weak self, workspace] in
            var loaded: [TableInfo] = []
            for name in names.prefix(Self.containerLimit) {
                guard self != nil else { return }
                let tables = await workspace.tables(inSchema: name) ?? []
                // A MySQL database's tables name their database, so they can be opened without switching.
                loaded += tables.filter { $0.kind != .keyspace && $0.kind != .systemTable }.map { info in
                    var info = info
                    if info.ref.schema == nil { info.ref.schema = name }
                    return info
                }
            }
            guard let self else { return }
            self.otherContainerTables = loaded
            self.isLoadingContainers = false
            self.onChange?()
        }
    }

    /// Catalog schemas whose tables would bury the user's own.
    static func isSystemSchema(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == "information_schema" || lowered.hasPrefix("pg_") || lowered == "mysql" || lowered == "performance_schema" || lowered == "sys"
    }
}

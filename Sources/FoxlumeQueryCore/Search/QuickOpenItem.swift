import Foundation

/// What an Open Quickly row stands for. The order is the order of the sections shown with nothing typed.
public enum QuickOpenKind: String, Sendable, CaseIterable, Comparable {
    case table
    case view
    case systemTable
    case database
    case schema
    case savedQuery
    case history

    public var sectionTitle: String {
        switch self {
        case .table: return "Tables"
        case .view: return "Views"
        case .systemTable: return "System Tables"
        case .database: return "Databases"
        case .schema: return "Schemas"
        case .savedQuery: return "Saved Queries"
        case .history: return "Recent Queries"
        }
    }

    /// Multiplies the match score: objects first, history last.
    var weight: Double {
        switch self {
        case .table: return 1.0
        case .view: return 0.98
        case .database: return 0.95
        case .schema: return 0.93
        case .savedQuery: return 0.9
        case .systemTable: return 0.85
        case .history: return 0.7
        }
    }

    public var isTableLike: Bool { self == .table || self == .view || self == .systemTable }
    public var isQuery: Bool { self == .savedQuery || self == .history }

    public static func < (lhs: QuickOpenKind, rhs: QuickOpenKind) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    public static func kind(of table: TableKind) -> QuickOpenKind {
        switch table {
        case .view, .materializedView: return .view
        case .systemTable: return .systemTable
        case .table, .foreignTable, .keyspace: return .table
        }
    }
}

/// The scope bar of Open Quickly (⌘1…⌘5).
public enum QuickOpenScope: Int, Sendable, CaseIterable {
    case all
    case tables
    case databases
    case queries
    case connections

    public var title: String {
        switch self {
        case .all: return "All"
        case .tables: return "Tables"
        case .databases: return "Databases"
        case .queries: return "Queries"
        case .connections: return "Connections"
        }
    }

    /// Whether a row belongs to this scope. Only Queries and Connections reach other open connections.
    public func includes(_ item: QuickOpenItem) -> Bool {
        switch self {
        case .all: return item.isCurrentConnection
        case .tables: return item.isCurrentConnection && item.kind.isTableLike
        case .databases: return item.isCurrentConnection && (item.kind == .database || item.kind == .schema)
        case .queries: return item.kind.isQuery
        case .connections: return item.kind.isTableLike
        }
    }
}

/// One thing Open Quickly can open.
public struct QuickOpenItem: Sendable, Hashable, Identifiable {
    public enum Target: Sendable, Hashable {
        case table(TableRef)
        case database(String)
        case schema(String)
        case savedQuery(UUID)
        case history(Int64)
    }

    public var kind: QuickOpenKind
    public var title: String
    /// Secondary text: schema, connection path, keyword or run time.
    public var subtitle: String
    public var target: Target
    public var connectionID: UUID
    public var connectionName: String
    public var isCurrentConnection: Bool
    /// The schema or database holding a table, matched by `schema.table` searches.
    public var container: String?
    /// A saved query's keyword, matched like the name.
    public var keyword: String?
    /// The SQL of a saved query or history entry.
    public var sql: String?
    /// A table already shown in a tab of its window.
    public var isOpen = false
    /// A table of a schema other than the one the sidebar shows.
    public var isOutsideCurrentScope = false

    public init(kind: QuickOpenKind, title: String, subtitle: String = "", target: Target, connectionID: UUID, connectionName: String,
                isCurrentConnection: Bool = true, container: String? = nil, keyword: String? = nil, sql: String? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.target = target
        self.connectionID = connectionID
        self.connectionName = connectionName
        self.isCurrentConnection = isCurrentConnection
        self.container = container
        self.keyword = keyword
        self.sql = sql
    }

    /// Identifies the item across launches for recency, within its connection.
    public var key: String {
        switch target {
        case .table(let ref): return Self.tableKey(ref)
        case .database(let name): return "database:" + name
        case .schema(let name): return "schema:" + name
        case .savedQuery(let id): return "saved:" + id.uuidString
        case .history: return "history:" + Self.historyKey(sql ?? title)
        }
    }

    public var id: String { connectionID.uuidString + "|" + key }

    /// The recency key of a table, also recorded when its tab is opened outside Open Quickly.
    public static func tableKey(_ ref: TableRef) -> String {
        "table:" + (ref.schema.map { $0 + "." } ?? "") + ref.name
    }

    /// History entries are remembered by their text, so a re-run of the same SQL is the same item.
    static func historyKey(_ sql: String) -> String {
        // FNV-1a over the trimmed text: stable across launches, unlike `hashValue`.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in sql.trimmingCharacters(in: .whitespacesAndNewlines).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    /// One line of SQL for a row title: whitespace runs collapsed, at most 200 characters.
    public static func singleLine(_ sql: String) -> String {
        let collapsed = sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.count > 200 ? String(collapsed.prefix(200)) + "…" : collapsed
    }
}

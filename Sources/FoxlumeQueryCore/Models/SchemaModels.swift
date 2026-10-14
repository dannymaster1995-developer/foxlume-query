import Foundation

public struct TableRef: Hashable, Sendable, Codable {
    /// Schema for PostgreSQL, nil elsewhere.
    public var schema: String?
    public var name: String

    public init(schema: String? = nil, name: String) {
        self.schema = schema
        self.name = name
    }
}

public enum TableKind: String, Sendable, Codable {
    case table
    case view
    case materializedView
    case foreignTable
    case systemTable
    /// A Redis logical database (db0, db1, …) browsed as a list of keys.
    case keyspace
}

public struct TableInfo: Hashable, Sendable, Identifiable {
    public var ref: TableRef
    public var kind: TableKind
    /// Approximate row count from catalog statistics, when cheap to get.
    public var estimatedRows: Int?
    public var comment: String?

    public var id: TableRef { ref }
    public var name: String { ref.name }

    public init(ref: TableRef, kind: TableKind = .table, estimatedRows: Int? = nil, comment: String? = nil) {
        self.ref = ref
        self.kind = kind
        self.estimatedRows = estimatedRows
        self.comment = comment
    }
}

public struct ColumnInfo: Hashable, Sendable {
    public var name: String
    /// Full type as declared, for example `character varying(255)` or `int(11) unsigned`.
    public var dataType: String
    public var isNullable: Bool
    public var defaultValue: String?
    public var isPrimaryKey: Bool
    public var isAutoIncrement: Bool
    public var comment: String?
    /// Extra engine details such as MySQL `on update CURRENT_TIMESTAMP`.
    public var extra: String?
    /// Collation, only when it differs from the default of the type (PostgreSQL) or the table (MySQL).
    public var collation: String?
    /// Expression of a generated (computed) column.
    public var generationExpression: String?

    public init(
        name: String,
        dataType: String,
        isNullable: Bool = true,
        defaultValue: String? = nil,
        isPrimaryKey: Bool = false,
        isAutoIncrement: Bool = false,
        comment: String? = nil,
        extra: String? = nil,
        collation: String? = nil,
        generationExpression: String? = nil
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
        self.isAutoIncrement = isAutoIncrement
        self.comment = comment
        self.extra = extra
        self.collation = collation
        self.generationExpression = generationExpression
    }
}

public struct IndexInfo: Hashable, Sendable {
    public var name: String
    public var columns: [String]
    public var isUnique: Bool
    public var isPrimary: Bool
    /// Access method, for example `btree`.
    public var method: String?
    /// Owned by a UNIQUE or EXCLUDE constraint (PostgreSQL), so it is dropped as a constraint, not as an index.
    public var isConstraint: Bool

    public init(name: String, columns: [String], isUnique: Bool, isPrimary: Bool, method: String? = nil, isConstraint: Bool = false) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.method = method
        self.isConstraint = isConstraint
    }
}

public struct ForeignKeyInfo: Hashable, Sendable {
    public var name: String
    public var columns: [String]
    public var referencedTable: TableRef
    public var referencedColumns: [String]
    public var onUpdate: String?
    public var onDelete: String?

    public init(
        name: String,
        columns: [String],
        referencedTable: TableRef,
        referencedColumns: [String],
        onUpdate: String? = nil,
        onDelete: String? = nil
    ) {
        self.name = name
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }
}

public struct TableStructure: Sendable {
    public var table: TableRef
    public var columns: [ColumnInfo]
    public var indexes: [IndexInfo]
    public var foreignKeys: [ForeignKeyInfo]
    /// Table comment, for engines whose structure reader fills it in (PostgreSQL, MySQL).
    public var comment: String?

    public init(table: TableRef, columns: [ColumnInfo], indexes: [IndexInfo] = [], foreignKeys: [ForeignKeyInfo] = [], comment: String? = nil) {
        self.table = table
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.comment = comment
    }

    public var primaryKey: [String] {
        if let primary = indexes.first(where: { $0.isPrimary }), !primary.columns.isEmpty {
            return primary.columns
        }
        return columns.filter(\.isPrimaryKey).map(\.name)
    }
}

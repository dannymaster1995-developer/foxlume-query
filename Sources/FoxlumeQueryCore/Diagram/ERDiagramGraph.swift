import Foundation

/// One column as an ER diagram shows it.
public struct ERDiagramColumn: Hashable, Sendable {
    public var name: String
    public var dataType: String
    public var isNullable: Bool
    public var isPrimaryKey: Bool
    public var isForeignKey: Bool

    public init(name: String, dataType: String, isNullable: Bool, isPrimaryKey: Bool, isForeignKey: Bool) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.isForeignKey = isForeignKey
    }
}

/// One table (or view) box. Its id is the table name, which is unique inside the one schema a diagram shows.
public struct ERDiagramTable: Hashable, Sendable, Identifiable {
    public var ref: TableRef
    public var kind: TableKind
    public var columns: [ERDiagramColumn]

    public var id: String { ref.name }
    public var name: String { ref.name }

    public init(ref: TableRef, kind: TableKind, columns: [ERDiagramColumn]) {
        self.ref = ref
        self.kind = kind
        self.columns = columns
    }

    /// The columns a compact ("Keys Only") diagram keeps: primary and foreign key columns, or every column when the
    /// table has neither.
    public var keyColumns: [ERDiagramColumn] {
        let keys = columns.filter { $0.isPrimaryKey || $0.isForeignKey }
        return keys.isEmpty ? columns : keys
    }
}

/// How many rows of the referencing table can point at one referenced row, and whether they must.
public struct ERCardinality: Hashable, Sendable {
    /// The foreign key columns are the primary key or a unique key of their table: at most one row per parent.
    public var isUnique: Bool
    /// Every foreign key column is NOT NULL: each row must have a parent.
    public var isMandatory: Bool

    public init(isUnique: Bool, isMandatory: Bool) {
        self.isUnique = isUnique
        self.isMandatory = isMandatory
    }

    /// `one or many`, `zero or one` and so on, for tooltips and copied text.
    public var label: String {
        switch (isUnique, isMandatory) {
        case (true, true): return "one to one"
        case (true, false): return "zero or one to one"
        case (false, true): return "one or many to one"
        case (false, false): return "zero or many to one"
        }
    }
}

/// A foreign key between two tables of the diagram.
public struct ERDiagramRelationship: Hashable, Sendable, Identifiable {
    public var name: String
    /// The referencing (child) table id and its key columns.
    public var from: String
    public var fromColumns: [String]
    /// The referenced (parent) table id and its columns.
    public var to: String
    public var toColumns: [String]
    public var cardinality: ERCardinality
    public var onDelete: String?
    public var onUpdate: String?

    public var id: String { "\(from).\(name)" }
    public var isSelfReference: Bool { from == to }

    public init(name: String, from: String, fromColumns: [String], to: String, toColumns: [String], cardinality: ERCardinality, onDelete: String? = nil, onUpdate: String? = nil) {
        self.name = name
        self.from = from
        self.fromColumns = fromColumns
        self.to = to
        self.toColumns = toColumns
        self.cardinality = cardinality
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }
}

/// The tables of one schema and the foreign keys between them.
public struct ERDiagramGraph: Sendable {
    /// Ordered by name.
    public var tables: [ERDiagramTable]
    public var relationships: [ERDiagramRelationship]
    /// Foreign keys that point outside the diagram (another schema or database), by referencing table.
    public var externalReferences: [String: [ForeignKeyInfo]]
    /// The connected group of each table that has a relationship, numbered from 0 by the group's first name;
    /// tables with no relationship have none.
    public var groups: [String: Int]

    public init(tables: [ERDiagramTable], relationships: [ERDiagramRelationship], externalReferences: [String: [ForeignKeyInfo]] = [:]) {
        self.tables = tables.sorted { $0.name < $1.name }
        self.relationships = relationships.sorted { ($0.from, $0.name) < ($1.from, $1.name) }
        self.externalReferences = externalReferences
        self.groups = Self.connectedGroups(tables: self.tables.map(\.id), relationships: self.relationships)
    }

    public static let empty = ERDiagramGraph(tables: [], relationships: [])

    public func table(_ id: String) -> ERDiagramTable? {
        tables.first { $0.id == id }
    }

    /// Builds the graph from table structures. `tables` gives the order-independent list and kinds; a table whose
    /// structure is missing is shown with no columns.
    public static func build(tables: [TableInfo], structures: [TableStructure]) -> ERDiagramGraph {
        let byName = Dictionary(structures.map { ($0.table.name, $0) }, uniquingKeysWith: { first, _ in first })
        let names = Set(tables.map(\.name))
        var diagramTables: [ERDiagramTable] = []
        var relationships: [ERDiagramRelationship] = []
        var external: [String: [ForeignKeyInfo]] = [:]
        for info in tables {
            let structure = byName[info.name]
            let foreignKeyColumns = Set(structure?.foreignKeys.flatMap(\.columns) ?? [])
            let primaryKey = Set(structure?.primaryKey ?? [])
            let columns = (structure?.columns ?? []).map {
                ERDiagramColumn(name: $0.name, dataType: $0.dataType, isNullable: $0.isNullable,
                                isPrimaryKey: $0.isPrimaryKey || primaryKey.contains($0.name),
                                isForeignKey: foreignKeyColumns.contains($0.name))
            }
            diagramTables.append(ERDiagramTable(ref: info.ref, kind: info.kind, columns: columns))
            guard let structure else { continue }
            let uniqueSets: [Set<String>] = [primaryKey].filter { !$0.isEmpty }
                + structure.indexes.filter { $0.isUnique || $0.isPrimary }.map { Set($0.columns) }
            let nullable = Dictionary(structure.columns.map { ($0.name, $0.isNullable) }, uniquingKeysWith: { first, _ in first })
            for key in structure.foreignKeys {
                let target = key.referencedTable
                // MySQL names the other database only when the key leaves the table's own database.
                let sameSchema = target.schema == nil || target.schema == info.ref.schema
                guard names.contains(target.name), sameSchema else {
                    external[info.name, default: []].append(key)
                    continue
                }
                let columns = Set(key.columns)
                let cardinality = ERCardinality(
                    isUnique: uniqueSets.contains(columns),
                    isMandatory: key.columns.allSatisfy { nullable[$0] == false }
                )
                relationships.append(ERDiagramRelationship(name: key.name, from: info.name, fromColumns: key.columns,
                                                           to: target.name, toColumns: key.referencedColumns,
                                                           cardinality: cardinality, onDelete: key.onDelete, onUpdate: key.onUpdate))
            }
        }
        return ERDiagramGraph(tables: diagramTables, relationships: relationships, externalReferences: external)
    }

    static func connectedGroups(tables: [String], relationships: [ERDiagramRelationship]) -> [String: Int] {
        var parent = Dictionary(uniqueKeysWithValues: tables.map { ($0, $0) })
        func find(_ id: String) -> String {
            var root = id
            while let next = parent[root], next != root { root = next }
            var cursor = id
            while let next = parent[cursor], next != root {
                parent[cursor] = root
                cursor = next
            }
            return root
        }
        var linked = Set<String>()
        for relationship in relationships where !relationship.isSelfReference {
            guard parent[relationship.from] != nil, parent[relationship.to] != nil else { continue }
            linked.insert(relationship.from)
            linked.insert(relationship.to)
            let a = find(relationship.from), b = find(relationship.to)
            if a != b {
                // The smaller name wins, so the root does not depend on the order relationships arrive in.
                if a < b { parent[b] = a } else { parent[a] = b }
            }
        }
        var roots: [String: [String]] = [:]
        for table in tables where linked.contains(table) {
            roots[find(table), default: []].append(table)
        }
        var groups: [String: Int] = [:]
        for (index, members) in roots.values.sorted(by: { ($0.min() ?? "") < ($1.min() ?? "") }).enumerated() {
            for member in members { groups[member] = index }
        }
        return groups
    }
}

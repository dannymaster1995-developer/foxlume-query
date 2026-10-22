import Foundation

/// The schema facts an AI request may carry: table and column names, types, primary keys, NOT NULL and foreign keys.
/// Comments, defaults, enum labels kept apart from the type, indexes and row counts are left out on purpose.
public struct AISchemaTable: Sendable, Hashable {
    public struct Column: Sendable, Hashable {
        public var name: String
        public var type: String
        public var isPrimaryKey: Bool
        public var isNullable: Bool

        public init(name: String, type: String, isPrimaryKey: Bool = false, isNullable: Bool = true) {
            self.name = name
            self.type = type
            self.isPrimaryKey = isPrimaryKey
            self.isNullable = isNullable
        }
    }

    public struct ForeignKey: Sendable, Hashable {
        public var columns: [String]
        public var referencedTable: String
        public var referencedColumns: [String]

        public init(columns: [String], referencedTable: String, referencedColumns: [String]) {
            self.columns = columns
            self.referencedTable = referencedTable
            self.referencedColumns = referencedColumns
        }
    }

    /// Qualified with its schema when it is not in the editor's current schema.
    public var name: String
    /// Empty when the table's columns have not been loaded yet; only the name is sent then.
    public var columns: [Column]
    public var foreignKeys: [ForeignKey]

    public init(name: String, columns: [Column] = [], foreignKeys: [ForeignKey] = []) {
        self.name = name
        self.columns = columns
        self.foreignKeys = foreignKeys
    }
}

public enum AISchemaContext {
    /// Picks at most `limit` tables: those the editor text names first (in the order they appear), then the rest by
    /// name. `tables` lists every table of the current schema; `structures` the ones whose columns are loaded
    /// (other schemas' tables only come in through a loaded structure). Nothing is fetched for this.
    public static func tables(
        tables: [TableRef],
        structures: [TableStructure],
        currentSchema: String?,
        editorText: String,
        limit: Int
    ) -> [AISchemaTable] {
        guard limit > 0 else { return [] }
        var byRef: [TableRef: TableStructure] = [:]
        for structure in structures { byRef[structure.table] = structure }
        var refs: [TableRef] = []
        var seen = Set<TableRef>()
        for ref in tables + structures.map(\.table) where seen.insert(ref).inserted {
            refs.append(ref)
        }

        func displayName(_ ref: TableRef) -> String {
            guard let schema = ref.schema, !schema.isEmpty, schema != currentSchema else { return ref.name }
            return schema + "." + ref.name
        }

        let mentioned = mentionedPositions(of: refs.map(\.name), in: editorText)
        let ordered = refs.sorted { a, b in
            switch (mentioned[a.name.lowercased()], mentioned[b.name.lowercased()]) {
            case let (x?, y?): return x != y ? x < y : displayName(a) < displayName(b)
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                // The current schema's tables come before other schemas' at the same rank.
                let aLocal = a.schema == nil || a.schema == currentSchema
                let bLocal = b.schema == nil || b.schema == currentSchema
                if aLocal != bLocal { return aLocal }
                return displayName(a).localizedStandardCompare(displayName(b)) == .orderedAscending
            }
        }

        return ordered.prefix(limit).map { ref in
            guard let structure = byRef[ref] else { return AISchemaTable(name: displayName(ref)) }
            let primary = Set(structure.primaryKey)
            let columns = structure.columns.map {
                AISchemaTable.Column(name: $0.name, type: $0.dataType, isPrimaryKey: primary.contains($0.name), isNullable: $0.isNullable)
            }
            let keys = structure.foreignKeys.map {
                AISchemaTable.ForeignKey(columns: $0.columns, referencedTable: displayName($0.referencedTable), referencedColumns: $0.referencedColumns)
            }
            return AISchemaTable(name: displayName(ref), columns: columns, foreignKeys: keys)
        }
    }

    /// One line per table: `orders(id integer PK, customer_id integer NOT NULL, total numeric) FK customer_id -> customers(id)`.
    public static func text(for tables: [AISchemaTable]) -> String {
        tables.map { table in
            var line = table.name
            if !table.columns.isEmpty {
                let columns = table.columns.map { column -> String in
                    var parts = [column.name]
                    if !column.type.isEmpty { parts.append(column.type) }
                    if column.isPrimaryKey { parts.append("PK") } else if !column.isNullable { parts.append("NOT NULL") }
                    return parts.joined(separator: " ")
                }
                line += "(" + columns.joined(separator: ", ") + ")"
            }
            for key in table.foreignKeys {
                line += " FK \(key.columns.joined(separator: ", ")) -> \(key.referencedTable)(\(key.referencedColumns.joined(separator: ", ")))"
            }
            return line
        }.joined(separator: "\n")
    }

    /// Where each name first appears in `text` as a whole word, ignoring case; keyed by the lowercased name.
    static func mentionedPositions(of names: [String], in text: String) -> [String: Int] {
        let haystack = text.lowercased() as NSString
        var positions: [String: Int] = [:]
        for name in Set(names.map { $0.lowercased() }) where !name.isEmpty {
            var searchRange = NSRange(location: 0, length: haystack.length)
            while true {
                let found = haystack.range(of: name, options: .literal, range: searchRange)
                guard found.location != NSNotFound else { break }
                let before = found.location == 0 ? nil : haystack.character(at: found.location - 1)
                let afterIndex = NSMaxRange(found)
                let after = afterIndex < haystack.length ? haystack.character(at: afterIndex) : nil
                if !isWordCharacter(before), !isWordCharacter(after) {
                    positions[name] = found.location
                    break
                }
                searchRange = NSRange(location: afterIndex, length: haystack.length - afterIndex)
            }
        }
        return positions
    }

    private static func isWordCharacter(_ c: unichar?) -> Bool {
        guard let c else { return false }
        return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
    }
}

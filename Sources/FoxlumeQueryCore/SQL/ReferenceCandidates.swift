import Foundation

/// What the foreign key value picker asks for: rows of the referenced table, searched on the server.
public struct ReferenceCandidateRequest: Hashable, Sendable {
    public var table: TableRef
    public var keyColumn: String
    /// A text column shown beside the key, when the table has one.
    public var labelColumn: String?
    /// Matched case-insensitively anywhere in the key or the label; empty lists the first rows.
    public var search: String
    public var limit: Int

    public init(table: TableRef, keyColumn: String, labelColumn: String?, search: String = "", limit: Int = ReferenceCandidates.defaultLimit) {
        self.table = table
        self.keyColumn = keyColumn
        self.labelColumn = labelColumn
        self.search = search
        self.limit = limit
    }
}

/// One row the picker offers: the key value it writes and a label to recognise the row by.
public struct ReferenceCandidate: Hashable, Sendable {
    public var key: CellValue
    public var label: String?

    public init(key: CellValue, label: String?) {
        self.key = key
        self.label = label
    }
}

public enum ReferenceCandidates {
    public static let defaultLimit = 100

    /// `SELECT key, label FROM table [WHERE key or label contains search] ORDER BY key LIMIT n`. The search goes in as
    /// a string literal with LIKE wildcards escaped, as in "Search All Rows".
    public static func sql(_ request: ReferenceCandidateRequest, dialect: SQLDialect) -> String {
        let key = dialect.quoteIdentifier(request.keyColumn)
        var columns = [key]
        if let label = request.labelColumn { columns.append(dialect.quoteIdentifier(label)) }
        var sql = "SELECT " + columns.joined(separator: ", ") + " FROM " + dialect.qualifiedName(request.table)
        let search = request.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            let searched = [request.keyColumn] + (request.labelColumn.map { [$0] } ?? [])
            sql += " WHERE " + TableQuery.anyColumnContains(search, columns: searched, dialect: dialect)
        }
        sql += " ORDER BY \(key) ASC " + dialect.limitClause(limit: max(1, request.limit), offset: 0)
        return sql
    }

    /// Rows of the query above; rows with a NULL key are skipped (nothing can reference them).
    public static func candidates(from result: StatementResult, hasLabel: Bool) -> [ReferenceCandidate] {
        result.rows.compactMap { row in
            guard let key = row.first, !key.isAbsent else { return nil }
            let label = hasLabel && row.count > 1 ? row[1].textValue : nil
            return ReferenceCandidate(key: key, label: label)
        }
    }

    /// The first text column of the referenced table other than the key, shown as the row's label (`name`, `title`).
    public static func labelColumn(in structure: TableStructure, key: String) -> String? {
        structure.columns.first { $0.name != key && isTextType($0.dataType) }?.name
    }

    /// Character types on every SQL engine: `text`, `character varying(40)`, `varchar(255)`, `nvarchar`, `citext`,
    /// `VARCHAR`, `STRING`.
    static func isTextType(_ dataType: String) -> Bool {
        let type = dataType.lowercased()
        if type.hasSuffix("]") { return false }
        return ["char", "text", "string", "citext", "clob"].contains { type.contains($0) }
    }
}


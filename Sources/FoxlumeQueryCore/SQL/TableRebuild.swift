import Foundation

/// What PostgreSQL needs to rebuild a table with its columns in another order, read from the catalog
/// (`PostgresConnection.tableRebuildInfo(of:)`). PostgreSQL cannot move a column, so the table is copied into a new
/// one with the columns in the wanted order, and everything the old table carried is put back on the new one.
/// Anything the rebuild cannot carry over is a blocker, and then columns are not reordered at all.
public struct TableRebuildInfo: Hashable, Sendable {
    public struct Column: Hashable, Sendable {
        public var name: String
        /// `format_type` of the column, for example `character varying(20)`.
        public var dataType: String
        public var isNotNull: Bool
        /// Name of the NOT NULL constraint (PostgreSQL 18 names them); nil lets the server pick one.
        public var notNullConstraint: String?
        public var defaultExpression: String?
        /// `a` (ALWAYS) or `d` (BY DEFAULT) for an identity column.
        public var identity: String?
        /// The identity sequence, with its options as `CREATE SEQUENCE` writes them.
        public var identitySequence: TableRef?
        public var identityOptions: String?
        public var generationExpression: String?
        /// `s` (STORED) or `v` (VIRTUAL) for a generated column.
        public var generationKind: String?
        /// A non-default collation as SQL, already quoted (`"C"`, `"public"."german"`).
        public var collation: String?
        public var comment: String?
        public var privileges: [Privilege]

        public init(
            name: String, dataType: String, isNotNull: Bool = false, notNullConstraint: String? = nil,
            defaultExpression: String? = nil, identity: String? = nil, identitySequence: TableRef? = nil,
            identityOptions: String? = nil, generationExpression: String? = nil, generationKind: String? = nil,
            collation: String? = nil, comment: String? = nil, privileges: [Privilege] = []
        ) {
            self.name = name
            self.dataType = dataType
            self.isNotNull = isNotNull
            self.notNullConstraint = notNullConstraint
            self.defaultExpression = defaultExpression
            self.identity = identity
            self.identitySequence = identitySequence
            self.identityOptions = identityOptions
            self.generationExpression = generationExpression
            self.generationKind = generationKind
            self.collation = collation
            self.comment = comment
            self.privileges = privileges
        }
    }

    /// A constraint as `pg_get_constraintdef` writes it, put back with ALTER TABLE … ADD CONSTRAINT.
    public struct Constraint: Hashable, Sendable {
        public var name: String
        /// `p` primary key, `u` unique, `x` exclusion, `c` check, `f` foreign key.
        public var kind: String
        public var definition: String
        public var comment: String?
        /// Comment of the index behind a primary key, unique or exclusion constraint.
        public var indexComment: String?

        public init(name: String, kind: String, definition: String, comment: String? = nil, indexComment: String? = nil) {
            self.name = name
            self.kind = kind
            self.definition = definition
            self.comment = comment
            self.indexComment = indexComment
        }
    }

    /// An index that belongs to no constraint, as `pg_get_indexdef` writes it.
    public struct Index: Hashable, Sendable {
        public var name: String
        public var definition: String
        public var comment: String?

        public init(name: String, definition: String, comment: String? = nil) {
            self.name = name
            self.definition = definition
            self.comment = comment
        }
    }

    /// One granted privilege. A nil grantee is PUBLIC.
    public struct Privilege: Hashable, Sendable {
        public var grantee: String?
        public var privilege: String
        public var isGrantable: Bool

        public init(grantee: String?, privilege: String, isGrantable: Bool = false) {
            self.grantee = grantee
            self.privilege = privilege
            self.isGrantable = isGrantable
        }
    }

    /// A serial column's sequence, owned by the column, so dropping the old table would drop it too.
    public struct OwnedSequence: Hashable, Sendable {
        public var sequence: TableRef
        public var column: String

        public init(sequence: TableRef, column: String) {
            self.sequence = sequence
            self.column = column
        }
    }

    public var table: TableRef
    /// Why the table cannot be rebuilt safely, one phrase each (“views depend on it: public.v”). Empty when it can.
    public var blockers: [String]
    /// In table order.
    public var columns: [Column]
    public var constraints: [Constraint]
    public var indexes: [Index]
    public var ownedSequences: [OwnedSequence]
    public var comment: String?
    /// Set only when it differs from the user who runs the rebuild, who would otherwise own the new table.
    public var owner: String?
    public var privileges: [Privilege]
    public var isUnlogged: Bool
    /// Storage parameters (`fillfactor=70`).
    public var options: [String]
    public var tablespace: String?
    /// `d` default, `n` nothing, `f` full, `i` index.
    public var replicaIdentity: String
    public var replicaIdentityIndex: String?
    public var clusterIndex: String?

    public init(
        table: TableRef, blockers: [String] = [], columns: [Column], constraints: [Constraint] = [], indexes: [Index] = [],
        ownedSequences: [OwnedSequence] = [], comment: String? = nil, owner: String? = nil, privileges: [Privilege] = [],
        isUnlogged: Bool = false, options: [String] = [], tablespace: String? = nil, replicaIdentity: String = "d",
        replicaIdentityIndex: String? = nil, clusterIndex: String? = nil
    ) {
        self.table = table
        self.blockers = blockers
        self.columns = columns
        self.constraints = constraints
        self.indexes = indexes
        self.ownedSequences = ownedSequences
        self.comment = comment
        self.owner = owner
        self.privileges = privileges
        self.isUnlogged = isUnlogged
        self.options = options
        self.tablespace = tablespace
        self.replicaIdentity = replicaIdentity
        self.replicaIdentityIndex = replicaIdentityIndex
        self.clusterIndex = clusterIndex
    }

    /// The sentence the UI shows when columns cannot be reordered, or nil when they can.
    public var blockerSentence: String? {
        guard !blockers.isEmpty else { return nil }
        return "PostgreSQL cannot reorder the columns of this table: " + blockers.joined(separator: "; ") + "."
    }
}

extension TableDDLGenerator {
    /// Shown at the top of the preview and in the confirmation when a save rebuilds a PostgreSQL table.
    public static let rebuildWarningLines = [
        "PostgreSQL cannot reorder columns in place, so this script rebuilds the table:",
        "it copies every row into a new table and replaces the old one.",
        "The table is locked against reads and writes until it finishes, and the time grows with the number of rows.",
    ]

    public static var rebuildWarning: String { rebuildWarningLines.joined(separator: " ") }

    /// Whether saving the draft rebuilds the table (PostgreSQL with existing columns in a new order).
    public func needsRebuild(_ draft: StructureDraft) -> Bool {
        dialect.family == .postgresql && !draft.isNewTable && draft.columnOrderChanged
    }

    /// Problems of a PostgreSQL reorder, as sentences for the user.
    func rebuildProblems(_ draft: StructureDraft, rebuild: TableRebuildInfo?) -> [String] {
        guard dialect.family == .postgresql, !draft.isNewTable else { return [] }
        var problems: [String] = []
        if let column = draft.newColumnsAmongExisting.first {
            let label = column.name.isEmpty ? "the new column" : "“\(column.name)”"
            problems.append("PostgreSQL adds new columns at the end of the table: move \(label) below the existing columns, or save it first and move it afterwards.")
        }
        guard draft.columnOrderChanged else { return problems }
        guard let rebuild else {
            problems.append("PostgreSQL cannot reorder columns of an existing table until its dependencies have been checked. Reload the structure and try again.")
            return problems
        }
        if let sentence = rebuild.blockerSentence {
            problems.append(sentence)
        } else if Set(rebuild.columns.map(\.name)) != Set(draft.columns.compactMap(\.original?.name)) {
            problems.append("The columns of \(draft.table.name) changed on the server. Reload the structure and try again.")
        }
        return problems
    }

    /// The statements that rebuild the table with the existing columns in the draft's order, before any other change
    /// of the draft is applied. Everything the table carries keeps its name. Runs inside the save's transaction.
    func rebuildStatements(_ draft: StructureDraft, rebuild: TableRebuildInfo) -> [String] {
        let order = draft.columns.compactMap(\.original?.name)
        let byName = Dictionary(rebuild.columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let columns = order.compactMap { byName[$0] }
        let table = dialect.qualifiedName(rebuild.table)
        let schema = rebuild.table.schema
        let temporary = TableRef(schema: schema, name: rebuild.table.name + "_fq_reorder")
        let newTable = dialect.qualifiedName(temporary)
        func temporarySequence(_ sequence: TableRef) -> TableRef {
            TableRef(schema: sequence.schema, name: sequence.name + "_fq_reorder")
        }

        var statements = ["LOCK TABLE \(table) IN ACCESS EXCLUSIVE MODE"]

        // The new table: columns only. Keys, checks and indexes come back after the copy, under their own names.
        let lines = columns.map { column -> String in
            var parts = [q(column.name), column.dataType]
            if let collation = column.collation { parts.append("COLLATE \(collation)") }
            if let expression = column.generationExpression {
                parts.append("GENERATED ALWAYS AS (\(expression)) \(column.generationKind == "v" ? "VIRTUAL" : "STORED")")
            } else if let expression = column.defaultExpression, column.identity == nil {
                parts.append("DEFAULT \(expression)")
            }
            if let identity = column.identity, let sequence = column.identitySequence {
                var options = "SEQUENCE NAME \(dialect.qualifiedName(temporarySequence(sequence)))"
                if let more = column.identityOptions, !more.isEmpty { options += " " + more }
                parts.append("GENERATED \(identity == "a" ? "ALWAYS" : "BY DEFAULT") AS IDENTITY (\(options))")
            }
            if column.isNotNull {
                parts.append(column.notNullConstraint.map { "CONSTRAINT \(q($0)) NOT NULL" } ?? "NOT NULL")
            }
            return "    " + parts.joined(separator: " ")
        }
        var create = "CREATE \(rebuild.isUnlogged ? "UNLOGGED " : "")TABLE \(newTable) (\n" + lines.joined(separator: ",\n") + "\n)"
        if !rebuild.options.isEmpty { create += " WITH (\(rebuild.options.joined(separator: ", ")))" }
        if let tablespace = rebuild.tablespace { create += " TABLESPACE \(q(tablespace))" }
        statements.append(create)

        // Generated columns compute themselves; identity values are copied as they are.
        let copied = columnList(columns.filter { $0.generationExpression == nil }.map(\.name))
        let overriding = columns.contains { $0.identity != nil } ? " OVERRIDING SYSTEM VALUE" : ""
        statements.append("INSERT INTO \(newTable) (\(copied))\(overriding) SELECT \(copied) FROM \(table)")
        for column in columns {
            guard column.identity != nil, let sequence = column.identitySequence else { continue }
            let target = dialect.quoteString(dialect.qualifiedName(temporarySequence(sequence)))
            statements.append("SELECT pg_catalog.setval(\(target), last_value, is_called) FROM \(dialect.qualifiedName(sequence))")
        }
        // A serial sequence belongs to its column and would be dropped with the old table.
        for owned in rebuild.ownedSequences {
            statements.append("ALTER SEQUENCE \(dialect.qualifiedName(owned.sequence)) OWNED BY NONE")
        }
        statements.append("DROP TABLE \(table)")
        statements.append("ALTER TABLE \(newTable) RENAME TO \(q(rebuild.table.name))")
        for column in columns {
            guard column.identity != nil, let sequence = column.identitySequence else { continue }
            statements.append("ALTER SEQUENCE \(dialect.qualifiedName(temporarySequence(sequence))) RENAME TO \(q(sequence.name))")
        }
        for owned in rebuild.ownedSequences {
            statements.append("ALTER SEQUENCE \(dialect.qualifiedName(owned.sequence)) OWNED BY \(table).\(q(owned.column))")
        }

        // Keys and checks first, foreign keys last, then plain indexes.
        let rank = ["p": 0, "u": 1, "x": 2, "c": 3, "f": 4]
        let constraints = rebuild.constraints.enumerated()
            .sorted { (rank[$0.element.kind] ?? 5, $0.offset) < (rank[$1.element.kind] ?? 5, $1.offset) }
            .map(\.element)
        for constraint in constraints {
            statements.append("ALTER TABLE \(table) ADD CONSTRAINT \(q(constraint.name)) \(constraint.definition)")
        }
        statements += rebuild.indexes.map(\.definition)
        switch rebuild.replicaIdentity {
        case "f": statements.append("ALTER TABLE \(table) REPLICA IDENTITY FULL")
        case "n": statements.append("ALTER TABLE \(table) REPLICA IDENTITY NOTHING")
        case "i":
            if let index = rebuild.replicaIdentityIndex {
                statements.append("ALTER TABLE \(table) REPLICA IDENTITY USING INDEX \(q(index))")
            }
        default: break
        }
        if let index = rebuild.clusterIndex {
            statements.append("ALTER TABLE \(table) CLUSTER ON \(q(index))")
        }

        if let owner = rebuild.owner {
            statements.append("ALTER TABLE \(table) OWNER TO \(q(owner))")
        }
        statements += grants(rebuild.privileges, on: table, columns: nil)
        for column in columns {
            statements += grants(column.privileges, on: table, columns: column.name)
        }

        if let comment = StructureDraft.normalizedComment(rebuild.comment) {
            statements.append("COMMENT ON TABLE \(table) IS \(dialect.quoteString(comment))")
        }
        for column in columns {
            if let comment = StructureDraft.normalizedComment(column.comment) {
                statements.append("COMMENT ON COLUMN \(table).\(q(column.name)) IS \(dialect.quoteString(comment))")
            }
        }
        for constraint in constraints {
            if let comment = StructureDraft.normalizedComment(constraint.comment) {
                statements.append("COMMENT ON CONSTRAINT \(q(constraint.name)) ON \(table) IS \(dialect.quoteString(comment))")
            }
            if let comment = StructureDraft.normalizedComment(constraint.indexComment) {
                statements.append("COMMENT ON INDEX \(dialect.qualifiedName(TableRef(schema: schema, name: constraint.name))) IS \(dialect.quoteString(comment))")
            }
        }
        for index in rebuild.indexes {
            if let comment = StructureDraft.normalizedComment(index.comment) {
                statements.append("COMMENT ON INDEX \(dialect.qualifiedName(TableRef(schema: schema, name: index.name))) IS \(dialect.quoteString(comment))")
            }
        }
        return statements
    }

    /// GRANT statements, one per grantee and grant option, privileges in the order read.
    private func grants(_ privileges: [TableRebuildInfo.Privilege], on table: String, columns column: String?) -> [String] {
        var order: [String] = []
        var grouped: [String: (grantee: String?, grantable: Bool, privileges: [String])] = [:]
        for privilege in privileges {
            let key = (privilege.grantee ?? "") + (privilege.isGrantable ? "\u{1}+" : "\u{1}-")
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = (privilege.grantee, privilege.isGrantable, [])
            }
            if grouped[key]?.privileges.contains(privilege.privilege) == false {
                grouped[key]?.privileges.append(privilege.privilege)
            }
        }
        return order.compactMap { key in
            guard let entry = grouped[key] else { return nil }
            let list = entry.privileges.map { privilege in column.map { "\(privilege) (\(q($0)))" } ?? privilege }.joined(separator: ", ")
            let grantee = entry.grantee.map(q) ?? "PUBLIC"
            return "GRANT \(list) ON TABLE \(table) TO \(grantee)\(entry.grantable ? " WITH GRANT OPTION" : "")"
        }
    }

    private func q(_ identifier: String) -> String {
        dialect.quoteIdentifier(identifier)
    }

    private func columnList(_ names: [String]) -> String {
        names.map(q).joined(separator: ", ")
    }
}

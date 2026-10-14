import Foundation

/// The clause the caret sits in (spec 2.4 / 2.5).
public enum SQLClause: String, Sendable, CaseIterable {
    case selectList
    case from
    case join
    case on
    case whereClause
    case and
    case groupBy
    case orderBy
    case having
    case set
    case into
    case values
    case insertColumns
    case functionArgument
    case caseExpression
    case inList
    case limit
    case alterTable
    case alterTableColumn
    case createTable
    case columnDefinition
    case returning
    case union
    case using
    case window
    case dropObject
    case createIndex
    case createView
    case castTarget
    case unknown
}

/// A table named by the statement (spec 3.1–3.2).
public struct SQLTableReference: Sendable, Hashable {
    public var schema: String?
    public var table: String
    public var alias: String?
    /// Output columns of a derived table or CTE, in order; nil for real tables.
    public var derivedColumns: [String]?

    public init(schema: String? = nil, table: String, alias: String? = nil, derivedColumns: [String]? = nil) {
        self.schema = schema
        self.table = table
        self.alias = alias
        self.derivedColumns = derivedColumns
    }

    /// The name columns are qualified with: the alias when there is one.
    public var identifier: String { alias ?? table }
}

/// Everything the SQL engine needs to know about the caret position.
public struct SQLCompletionContext: Sendable {
    /// UTF-16 range of the statement the caret is in.
    public var statementRange: NSRange
    /// Token start to caret (includes a typed opening quote).
    public var replacementRange: NSRange
    public var token: String
    /// Token without identifier quotes.
    public var prefix: String
    /// `x` in `x.pre|` (one level; quotes stripped).
    public var qualifier: String?
    public var clause: SQLClause
    /// FROM/JOIN/INTO only: the caret is where a table name goes (spec 2.4 step 3).
    public var expectsObjectName: Bool
    /// The last non-space character before the caret is `,`.
    public var isAfterComma: Bool
    /// Name of the innermost function whose `(` is open, e.g. `COUNT` in `SELECT COUNT(|`.
    public var currentFunction: String?
    /// The column compared before the caret, e.g. `status` in `WHERE status = |` (spec 3.6).
    public var comparisonColumn: String?
    /// Unclosed `(` before the caret.
    public var nestingLevel: Int
    /// Inside the column list of CREATE TABLE (nesting ≥ 1) as opposed to after it.
    public var insideCreateTableColumns: Bool
    /// Tables of the whole statement, before and after the caret, in discovery order.
    public var references: [SQLTableReference]
    public var cteNames: [String]
    /// The table a DML/DDL statement acts on (UPDATE, INSERT INTO, ALTER TABLE, CREATE INDEX ON), if any.
    public var targetTable: SQLTableReference?

    public init(
        statementRange: NSRange,
        replacementRange: NSRange,
        token: String,
        prefix: String,
        qualifier: String? = nil,
        clause: SQLClause,
        expectsObjectName: Bool = false,
        isAfterComma: Bool = false,
        currentFunction: String? = nil,
        comparisonColumn: String? = nil,
        nestingLevel: Int = 0,
        insideCreateTableColumns: Bool = false,
        references: [SQLTableReference] = [],
        cteNames: [String] = [],
        targetTable: SQLTableReference? = nil
    ) {
        self.statementRange = statementRange
        self.replacementRange = replacementRange
        self.token = token
        self.prefix = prefix
        self.qualifier = qualifier
        self.clause = clause
        self.expectsObjectName = expectsObjectName
        self.isAfterComma = isAfterComma
        self.currentFunction = currentFunction
        self.comparisonColumn = comparisonColumn
        self.nestingLevel = nestingLevel
        self.insideCreateTableColumns = insideCreateTableColumns
        self.references = references
        self.cteNames = cteNames
        self.targetTable = targetTable
    }
}

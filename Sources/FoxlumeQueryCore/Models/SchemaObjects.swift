import Foundation

/// Kinds of schema objects other than tables and views, listed in their own sidebar groups (in this order).
public enum SchemaObjectKind: String, Sendable, Codable, CaseIterable, Hashable {
    case procedure
    case function
    case trigger
    case type

    /// Sidebar group title.
    public var title: String {
        switch self {
        case .procedure: return "Procedures"
        case .function: return "Functions"
        case .trigger: return "Triggers"
        case .type: return "Types"
        }
    }

    /// What prompts and menus call one object: "function", "trigger"…
    public var noun: String { rawValue }

    /// "Function", for tab titles and prompts.
    public var label: String { rawValue.capitalized }

    /// The keyword of CREATE and DROP statements.
    public var keyword: String { rawValue.uppercased() }

    /// Functions and procedures, the objects that have arguments.
    public var isRoutine: Bool { self == .function || self == .procedure }

    /// The kinds an engine lists, in sidebar order. MongoDB and Redis have none.
    public static func kinds(for engine: DatabaseKind) -> [SchemaObjectKind] {
        switch engine {
        case .postgresql: return [.procedure, .function, .trigger, .type]
        case .mysql, .mariadb: return [.procedure, .function, .trigger]
        case .sqlite: return [.trigger]
        // DuckDB macros, filed as functions.
        case .duckdb: return [.function]
        case .mongodb, .redis: return []
        }
    }
}

/// One label and value of an object's details, such as "Language: plpgsql".
public struct SchemaObjectAttribute: Hashable, Sendable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// One procedure, function, trigger or type of the current schema (MySQL: database).
public struct SchemaObject: Hashable, Sendable, Identifiable {
    public var kind: SchemaObjectKind
    /// Schema for PostgreSQL and DuckDB, database for MySQL; nil for SQLite.
    public var schema: String?
    public var name: String
    /// Argument list as the server prints it, names included (`a integer, b text`), for routines.
    public var arguments: String?
    /// Argument types only (`integer, text`): what identifies a PostgreSQL routine in DROP and catalog lookups.
    public var identityArguments: String?
    /// Return type of a function.
    public var returnType: String?
    /// The table a trigger fires on.
    public var table: String?
    /// The language of a routine, the kind of a type (enum, composite, domain, range), or a macro's kind.
    public var detail: String?
    /// Further facts for the tooltip and the source tab: volatility, security, timing, events…
    public var attributes: [SchemaObjectAttribute]
    /// The engine's own identifier for the object, such as a PostgreSQL OID, when it is known.
    public var oid: String?

    public init(
        kind: SchemaObjectKind,
        schema: String? = nil,
        name: String,
        arguments: String? = nil,
        identityArguments: String? = nil,
        returnType: String? = nil,
        table: String? = nil,
        detail: String? = nil,
        attributes: [SchemaObjectAttribute] = [],
        oid: String? = nil
    ) {
        self.kind = kind
        self.schema = schema
        self.name = name
        self.arguments = arguments
        self.identityArguments = identityArguments
        self.returnType = returnType
        self.table = table
        self.detail = detail
        self.attributes = attributes
        self.oid = oid
    }

    /// Stable across refreshes, unlike the OID-free fields' order: kind, schema, table, name and argument types.
    public var id: String {
        [kind.rawValue, schema ?? "", table ?? "", name, identityArguments ?? arguments ?? ""].joined(separator: "\u{1F}")
    }

    /// `name(arguments)`, or the name alone when the arguments are unknown or the object is not a routine.
    public var signatureName: String {
        guard kind.isRoutine, let arguments else { return name }
        return "\(name)(\(arguments))"
    }

    /// The schema-qualified name with the signature, for "Copy with Signature" and tooltips.
    public var qualifiedSignature: String {
        let base = [schema, signatureName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ".")
        if kind == .trigger, let table { return base + " on " + table }
        return base
    }

    /// Words the sidebar filter and Open Quickly match: the name, and a trigger's table.
    public var searchText: String {
        [name, table].compactMap { $0 }.joined(separator: " ")
    }

    /// The tooltip: qualified name, return type, language or kind, then each attribute.
    public var tooltip: String {
        var lines = [qualifiedSignature]
        if let returnType, kind == .function { lines.append("Returns \(returnType)") }
        if let detail { lines.append(kind.isRoutine ? "Language \(detail)" : detail) }
        lines += attributes.map { "\($0.label): \($0.value)" }
        return lines.joined(separator: "\n")
    }

    /// Row labels for a list of objects, keyed by id. A routine shows its signature only when another routine of the
    /// same kind shares its name (an overload); everything else shows the bare name.
    public static func labels(for objects: [SchemaObject]) -> [String: String] {
        var counts: [String: Int] = [:]
        for object in objects where object.kind.isRoutine {
            counts[object.kind.rawValue + "\u{1F}" + object.name, default: 0] += 1
        }
        var labels: [String: String] = [:]
        for object in objects {
            let overloaded = object.kind.isRoutine && (counts[object.kind.rawValue + "\u{1F}" + object.name] ?? 0) > 1
            labels[object.id] = overloaded ? object.signatureName : object.name
        }
        return labels
    }
}

/// A trigger of one table, for the Structure view.
public struct TriggerInfo: Hashable, Sendable {
    public var name: String
    /// BEFORE, AFTER or INSTEAD OF.
    public var timing: String
    /// INSERT, UPDATE, DELETE, TRUNCATE; `UPDATE OF a, b` keeps its columns.
    public var events: [String]
    /// ROW or STATEMENT.
    public var orientation: String
    /// The WHEN condition, when the trigger has one.
    public var condition: String?
    /// The trigger function (PostgreSQL) or the trigger body (MySQL, SQLite).
    public var action: String
    /// Whether the trigger fires; nil when the engine has no switch for it.
    public var isEnabled: Bool?
    /// The full CREATE TRIGGER statement.
    public var definition: String?

    public init(name: String, timing: String, events: [String], orientation: String = "ROW", condition: String? = nil,
                action: String, isEnabled: Bool? = nil, definition: String? = nil) {
        self.name = name
        self.timing = timing
        self.events = events
        self.orientation = orientation
        self.condition = condition
        self.action = action
        self.isEnabled = isEnabled
        self.definition = definition
    }
}

/// A CHECK constraint of one table, for the Structure view.
public struct CheckConstraintInfo: Hashable, Sendable {
    public var name: String
    /// The condition as the server prints it, without the CHECK keyword, for example `(qty >= 0)`.
    public var expression: String
    /// Columns the condition reads, when the engine reports them (PostgreSQL).
    public var columns: [String]
    /// False for a MySQL `NOT ENFORCED` or a PostgreSQL `NOT VALID` constraint; nil when the engine does not say.
    public var isEnforced: Bool?

    public init(name: String, expression: String, columns: [String] = [], isEnforced: Bool? = nil) {
        self.name = name
        self.expression = expression
        self.columns = columns
        self.isEnforced = isEnforced
    }
}

/// The source of one schema object, as a driver reads it.
public struct SchemaObjectDefinition: Hashable, Sendable {
    /// The object's own CREATE statement, without a trailing semicolon.
    public var statement: String
    /// For a PostgreSQL trigger: the CREATE OR REPLACE FUNCTION of the function it runs, unless that is built in.
    public var triggerFunction: String?
    /// A PostgreSQL constraint trigger, which CREATE OR REPLACE TRIGGER cannot replace.
    public var isConstraintTrigger: Bool
    /// Whether the server accepts CREATE OR REPLACE TRIGGER (PostgreSQL 14 and later).
    public var canReplaceTrigger: Bool

    public init(statement: String, triggerFunction: String? = nil, isConstraintTrigger: Bool = false, canReplaceTrigger: Bool = false) {
        self.statement = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        self.triggerFunction = triggerFunction?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isConstraintTrigger = isConstraintTrigger
        self.canReplaceTrigger = canReplaceTrigger
    }
}

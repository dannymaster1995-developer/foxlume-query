import AppKit
import FoxlumeQueryCore

/// What the workspace knows about the browsed schema's procedures, functions, triggers and types.
@MainActor
final class SchemaObjectCatalog {
    /// The objects of `scope`, in sidebar order (kind, then the driver's order).
    fileprivate(set) var objects: [SchemaObject] = []
    /// Kinds whose last load failed, with why.
    fileprivate(set) var failures: [SchemaObjectKind: Error] = [:]
    /// Database and schema the objects belong to.
    fileprivate(set) var scope: String?
    fileprivate(set) var isLoading = false
    fileprivate var task: Task<Void, Never>?
    fileprivate var generation = 0

    func cancel() {
        task?.cancel()
        task = nil
    }
}

extension ConnectionWorkspace {
    /// The kinds this engine lists in the sidebar.
    var schemaObjectKinds: [SchemaObjectKind] { SchemaObjectKind.kinds(for: kind) }

    var schemaObjectSQL: SchemaObjectSQL { SchemaObjectSQL(kind: kind) }

    private var schemaObjectScope: String { (currentDatabase ?? "") + "\u{1F}" + (currentSchema ?? "") }

    /// The objects of the schema the sidebar shows; empty while those of another schema are still the latest loaded.
    var schemaObjects: [SchemaObject] {
        schemaObjectCatalog.scope == schemaObjectScope ? schemaObjectCatalog.objects : []
    }

    var isLoadingSchemaObjects: Bool { schemaObjectCatalog.isLoading }

    func schemaObjectFailure(_ kind: SchemaObjectKind) -> Error? {
        schemaObjectCatalog.scope == schemaObjectScope ? schemaObjectCatalog.failures[kind] : nil
    }

    /// Loads the objects after the tables, as their own session jobs, so the table list never waits for them and a
    /// user query can run in between. Each kind fails on its own. The previous list stays until the new one is in.
    func loadSchemaObjects() {
        let kinds = schemaObjectKinds
        let catalog = schemaObjectCatalog
        catalog.cancel()
        guard !kinds.isEmpty else { return }
        catalog.generation += 1
        let generation = catalog.generation
        let scope = schemaObjectScope
        let schema = kind.supportsSchemas ? currentSchema : nil
        let session = self.session
        catalog.isLoading = true
        catalog.task = Task { [weak self] in
            var loaded: [SchemaObject] = []
            var failures: [SchemaObjectKind: Error] = [:]
            for objectKind in kinds {
                guard !Task.isCancelled else { return }
                do {
                    loaded += try await session.run { try $0.schemaObjects(objectKind, schema: schema) }
                } catch {
                    failures[objectKind] = error
                }
            }
            guard let self, !Task.isCancelled, catalog.generation == generation else { return }
            catalog.objects = loaded
            catalog.failures = failures
            catalog.scope = scope
            catalog.isLoading = false
            catalog.task = nil
            self.notifyMetadata()
        }
    }

    /// Reloads only the objects, for the group rows' Refresh.
    func refreshSchemaObjects() {
        loadSchemaObjects()
        notifyMetadata()
    }

    func definition(of object: SchemaObject) async throws -> SchemaObjectDefinition {
        try await tracked { try await session.run { try $0.definition(of: object) } }
    }

    func triggers(of table: TableRef) async throws -> [TriggerInfo] {
        try await tracked { try await session.run { try $0.triggers(of: table) } }
    }

    func checkConstraints(of table: TableRef) async throws -> [CheckConstraintInfo] {
        try await tracked { try await session.run { try $0.checkConstraints(of: table) } }
    }

    /// Runs the object's DROP right away (the caller has asked and passed Safe Mode); the catalog then reloads.
    func drop(_ object: SchemaObject) async throws {
        guard !isReadOnly else { throw DatabaseError.unsupported("This connection is read-only.") }
        guard let statement = schemaObjectSQL.dropStatement(object) else {
            throw DatabaseError.unsupported("\(kind.displayName) cannot drop this \(object.kind.noun).")
        }
        _ = try await execute(statement)
    }
}

import AppKit
import FoxlumeQueryCore

/// Engine and caches behind editor completion, held by the workspace because extensions cannot store.
@MainActor
final class CompletionCatalog {
    /// Made on first use for the connection's query language; tests may set their own.
    var engine: CompletionEngine?
    /// Tables of schemas other than the current one, keyed by database and schema. Empty lists are kept too.
    fileprivate let schemaTables = CompletionCache<[TableInfo]>()
    /// Sampled MongoDB field paths, keyed by database and collection.
    fileprivate let documentFields = CompletionCache<[CompletionField]>()
    /// Bumped by every catalog refresh; lists cached under an older one are refetched on next use.
    fileprivate(set) var generation = 0
    fileprivate var preloadTask: Task<Void, Never>?
    /// Tells a finished preload whether it is still the current one.
    fileprivate var preloadRun = 0
    /// The database and schema the bulk preload last ran for; it runs once per scope and catalog refresh, so a table
    /// that fails to load is not retried on every keystroke (it still loads on demand when a statement names it).
    fileprivate(set) var preloadedScope: String?

    nonisolated init() {}

    /// A refresh (DDL, Refresh, reconnect, a database or schema switch) may have changed every list: cached ones
    /// turn stale but are still served if their refetch fails, and the column preload runs again (spec 3.7).
    func catalogDidRefresh() {
        generation += 1
        stopPreload()
    }

    /// The preload's tables belong to the scope being left; loading them would fill the cache with another scope's names.
    func stopPreload() {
        preloadTask?.cancel()
        preloadTask = nil
        preloadedScope = nil
        preloadRun += 1
    }

    /// Stops background loads; used when the connection closes.
    func cancelLoads() {
        stopPreload()
        schemaTables.cancelAll()
        documentFields.cancelAll()
    }
}

/// Lists fetched once per key and catalog generation; concurrent callers share one fetch (spec 3.7).
@MainActor
final class CompletionCache<Value: Sendable> {
    private var values: [String: (value: Value, generation: Int)] = [:]
    private var tasks: [String: (task: Task<Value, Error>, generation: Int)] = [:]

    /// The cached value while it is current, otherwise the shared fetch's. A failed fetch serves the stale value,
    /// if any, and is retried on the next call.
    func value(for key: String, generation: Int, fetch: @escaping @MainActor () async throws -> Value) async -> Value? {
        if let cached = values[key], cached.generation >= generation { return cached.value }
        let task: Task<Value, Error>
        if let running = tasks[key], running.generation == generation {
            task = running.task
        } else {
            task = Task { try await fetch() }
            tasks[key] = (task, generation)
        }
        let result = await task.result
        if tasks[key]?.generation == generation { tasks[key] = nil }
        guard case .success(let value) = result else { return values[key]?.value }
        // A fetch that started before a newer one finished never overwrites it.
        if (values[key]?.generation ?? .min) <= generation { values[key] = (value, generation) }
        return value
    }

    func cancelAll() {
        tasks.values.forEach { $0.task.cancel() }
        tasks = [:]
    }
}

/// Engines that can complete the filter bar's Raw SQL box (spec 10).
@MainActor
protocol RawFilterCompleting: AnyObject {
    func completeFilter(fragment: String, caret: Int, table: TableRef, keywordCase: KeywordCase) async -> CompletionResult?
}

extension SQLCompletionEngine: RawFilterCompleting {}

extension ConnectionWorkspace {
    /// The completer for this connection's query language, made on first use: MongoDB and Redis have their own,
    /// every other engine uses SQL with its dialect.
    var completionEngine: CompletionEngine {
        if let engine = completionCatalog.engine { return engine }
        let engine = makeCompletionEngine()
        completionCatalog.engine = engine
        return engine
    }

    private func makeCompletionEngine() -> CompletionEngine {
        switch queryLanguage {
        case .sql: return SQLCompletionEngine(family: dialect.family, schema: self)
        case .mongo: return MongoCompletionEngine(schema: self)
        case .redis: return RedisCompletionEngine(schema: self)
        }
    }

    /// Raw SQL suggestions for the filter bar of `table`; nil for engines without SQL.
    func rawFilterCompletion(for table: TableRef) -> FilterBarView.RawCompletion? {
        let engine = completionEngine
        guard kind.isSQL, engine is RawFilterCompleting else { return nil }
        return FilterBarView.RawCompletion(
            complete: { [weak engine] fragment, caret in
                await (engine as? RawFilterCompleting)?.completeFilter(fragment: fragment, caret: caret, table: table, keywordCase: AppEnvironment.settings.keywordCase)
            },
            refilter: { [weak engine] result, token in
                engine?.refilter(result, token: token, keywordCase: AppEnvironment.settings.keywordCase) ?? []
            }
        )
    }

    /// Loads every column list in the background when the current schema has at most 300 tables (spec 3.7);
    /// larger schemas are filled per table on demand. Each table is its own session job, so queries interleave.
    func preloadCompletionColumns() {
        // Until the table list arrives there is nothing to load; a later request tries again.
        guard kind.isSQL, completionCatalog.preloadTask == nil, !tables.isEmpty, tables.count <= 300 else { return }
        let scope = completionCacheKey(currentSchema ?? "")
        guard completionCatalog.preloadedScope != scope else { return }
        completionCatalog.preloadedScope = scope
        let targets = tables.filter { $0.kind != .keyspace && $0.kind != .systemTable && cachedStructure(of: $0.ref) == nil }.map(\.ref)
        guard !targets.isEmpty else { return }
        completionCatalog.preloadRun += 1
        let run = completionCatalog.preloadRun
        completionCatalog.preloadTask = Task { [weak self] in
            for table in targets where !Task.isCancelled {
                guard let self else { return }
                if self.cachedStructure(of: table) == nil {
                    _ = try? await self.structure(of: table)
                }
            }
            if self?.completionCatalog.preloadRun == run { self?.completionCatalog.preloadTask = nil }
        }
    }

    /// Caches are per database, so switching databases never shows the previous one's names.
    private func completionCacheKey(_ name: String) -> String {
        (currentDatabase ?? "") + "\u{1F}" + name
    }

    /// The catalog's own ref for a table the editor named, matched exactly first, then ignoring case.
    private func resolveCompletionTable(_ table: TableRef) async -> TableRef? {
        func match(_ list: [TableInfo]) -> TableRef? {
            let candidates = list.filter { $0.kind != .keyspace }
            return (candidates.first { $0.name == table.name } ?? candidates.first { $0.name.caseInsensitiveCompare(table.name) == .orderedSame })?.ref
        }
        let current = kind.supportsSchemas ? currentSchema : currentDatabase
        if let schema = table.schema, schema.caseInsensitiveCompare(current ?? "") != .orderedSame {
            guard let list = await tables(inSchema: schema) else { return nil }
            return match(list)
        }
        return match(tables)
    }

    /// MySQL and MariaDB call a database a schema (`orders.items`), so their databases are the schemas.
    private var databasesAreSchemas: Bool {
        kind.isSQL && !kind.supportsSchemas && kind.supportsMultipleDatabases
    }
}

extension ConnectionWorkspace: CompletionSchemaProvider {
    func unqualifiedTables() async -> [TableInfo] {
        tables.filter { $0.kind != .keyspace && ($0.ref.schema == nil || $0.ref.schema == currentSchema) }
    }

    /// Engines without schemas (MySQL) treat a database name as the schema, as their SQL does.
    func tables(inSchema schema: String) async -> [TableInfo]? {
        let known = kind.supportsSchemas ? schemas : databases
        guard let name = known.first(where: { $0.caseInsensitiveCompare(schema) == .orderedSame }) else { return nil }
        if name == (kind.supportsSchemas ? currentSchema : currentDatabase) {
            return tables.filter { $0.kind != .keyspace }
        }
        let session = self.session
        let loaded = await completionCatalog.schemaTables.value(for: completionCacheKey(name), generation: completionCatalog.generation) {
            try await session.run { try $0.tables(schema: name) }
        }
        return loaded ?? []
    }

    /// Databases for MySQL and MariaDB, so an engine resolving `orders.` as a schema finds the database's tables.
    func schemaNames() async -> [String] {
        databasesAreSchemas ? databases : schemas
    }

    func databaseNames() async -> [String] {
        databases
    }

    func implicitSchema() async -> String? {
        kind.supportsSchemas ? currentSchema : nil
    }

    /// Shares the structure cache and its in-flight loads with the table tabs.
    func columns(of table: TableRef) async -> [ColumnInfo]? {
        guard let ref = await resolveCompletionTable(table) else { return nil }
        return try? await structure(of: ref).columns
    }

    /// Ordered by schema, then table, so the list is stable across launches; starts the bulk preload if needed.
    func cachedColumns() -> [(table: TableRef, columns: [ColumnInfo])] {
        preloadCompletionColumns()
        return cachedStructures
            .sorted { ($0.table.schema ?? "", $0.table.name) < ($1.table.schema ?? "", $1.table.name) }
            .map { (table: $0.table, columns: $0.columns) }
    }

    func documentFields(of collection: String) async -> [CompletionField] {
        guard kind == .mongodb else { return [] }
        let session = self.session
        let fields = await completionCatalog.documentFields.value(for: completionCacheKey(collection), generation: completionCatalog.generation) {
            try await session.run { try ($0 as? MongoConnection)?.completionFields(collection: collection) ?? [] }
        }
        return fields ?? []
    }

    /// From the key tree already loaded for the sidebar; no extra SCAN.
    func keyNames(prefix: String, limit: Int) async -> [String] {
        guard limit > 0, let keys = keyListing?.keys else { return [] }
        var names: [String] = []
        for key in keys where prefix.isEmpty || key.name.hasPrefix(prefix) {
            names.append(key.name)
            if names.count == limit { break }
        }
        return names
    }

    /// Saved queries with a keyword, for every connection plus this one (spec 7).
    func favorites() -> [CompletionFavorite] {
        AppEnvironment.savedQueries.completionFavorites(for: config.id)
    }
}

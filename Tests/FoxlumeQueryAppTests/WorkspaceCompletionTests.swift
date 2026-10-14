import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

private struct FetchFailed: Error {}

extension AppCompletionTests {
    @Suite("Completion cache")
    @MainActor
    struct CompletionCacheTests {
        @Test func concurrentCallersShareOneFetch() async {
            let cache = CompletionCache<[String]>()
            var fetches = 0
            let fetch: @MainActor () async throws -> [String] = {
                fetches += 1
                try await Task.sleep(nanoseconds: 20_000_000)
                return ["products"]
            }
            async let first = cache.value(for: "shop", generation: 0, fetch: fetch)
            async let second = cache.value(for: "shop", generation: 0, fetch: fetch)
            let (a, b) = await (first, second)
            #expect(a == ["products"] && b == ["products"])
            #expect(fetches == 1)
            _ = await cache.value(for: "shop", generation: 0, fetch: fetch)
            #expect(fetches == 1, "a current value is served from the cache")
        }

        @Test func emptyListsAreCached() async {
            let cache = CompletionCache<[String]>()
            var fetches = 0
            for _ in 0..<2 {
                _ = await cache.value(for: "empty", generation: 0) {
                    fetches += 1
                    return []
                }
            }
            #expect(fetches == 1)
        }

        /// After a catalog refresh the next use refetches; until that succeeds the old list is still served.
        @Test func refreshRefetchesAndFailuresServeTheStaleList() async {
            let cache = CompletionCache<[String]>()
            _ = await cache.value(for: "shop", generation: 0) { ["products"] }
            let failed = await cache.value(for: "shop", generation: 1) { throw FetchFailed() }
            #expect(failed == ["products"])
            var fetches = 0
            let refreshed = await cache.value(for: "shop", generation: 1) {
                fetches += 1
                return ["products", "reviews"]
            }
            #expect(refreshed == ["products", "reviews"])
            #expect(fetches == 1, "a failed fetch is retried on the next call")
            let unknown = await cache.value(for: "other", generation: 1) { throw FetchFailed() }
            #expect(unknown == nil)
        }

        @Test func aSlowerOlderFetchNeverOverwritesANewerList() async {
            let cache = CompletionCache<[String]>()
            async let old = cache.value(for: "shop", generation: 0) {
                try await Task.sleep(nanoseconds: 60_000_000)
                return ["old"]
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
            let new = await cache.value(for: "shop", generation: 1) { ["new"] }
            #expect(new == ["new"])
            #expect(await old == ["old"])
            let served = await cache.value(for: "shop", generation: 1) { ["refetched"] }
            #expect(served == ["new"])
        }
    }

    @Suite("Workspace completion provider", .enabled(if: LiveServer.postgres || LiveServer.mysql, "needs a test database server"))
    @MainActor
    struct WorkspaceProviderTests {
        private func postgres() async throws -> ConnectionWorkspace {
            let config = ConnectionConfig(kind: .postgresql, host: "127.0.0.1", port: 55432, user: "postgres", database: "foxlume", sslMode: .prefer)
            let workspace = ConnectionWorkspace(config: config, password: "postgres")
            try await workspace.connect()
            return workspace
        }

        /// DDL and Refresh make cached schema lists stale and run the column preload again for the scope (spec 3.7).
        @Test(.enabled(if: LiveServer.postgres)) func refreshInvalidatesCachesAndRestartsThePreload() async throws {
            let workspace = try await postgres()
            let catalog = workspace.completionCatalog
            #expect(await workspace.tables(inSchema: "shop")?.map(\.name) == ["products"])
            _ = workspace.cachedColumns()
            let scope = catalog.preloadedScope
            #expect(scope != nil)
            let generation = catalog.generation

            await workspace.refreshMetadata()
            #expect(catalog.generation == generation + 1)
            #expect(catalog.preloadedScope == nil)
            _ = workspace.cachedColumns()
            #expect(catalog.preloadedScope == scope)
            #expect(await workspace.tables(inSchema: "shop")?.map(\.name) == ["products"])

            await workspace.switchSchema("shop")
            #expect(catalog.preloadedScope != scope, "the previous schema's preload kept running")
            await workspace.disconnect()
        }

        /// MySQL calls a database a schema, so `orders.` must resolve through schemaNames() as well.
        @Test(.enabled(if: LiveServer.mysql)) func mysqlDatabasesAreSchemas() async throws {
            let config = ConnectionConfig(kind: .mysql, host: "127.0.0.1", port: 53306, user: "root", database: "foxlume", sslMode: .prefer)
            let workspace = ConnectionWorkspace(config: config, password: "root")
            try await workspace.connect()
            let schemas = await workspace.schemaNames()
            let databases = await workspace.databaseNames()
            #expect(schemas == databases)
            #expect(schemas.contains("foxlume"))
            #expect(await workspace.implicitSchema() == nil)
            for name in schemas where name != workspace.currentDatabase {
                if let tables = await workspace.tables(inSchema: name), !tables.isEmpty {
                    #expect(tables.allSatisfy { $0.kind != .keyspace })
                    break
                }
            }
            await workspace.disconnect()
        }

        /// A database or schema switch closes an open list; a refresh that keeps the scope does not (spec 1.6).
        @Test(.enabled(if: LiveServer.postgres)) func scopeSwitchClosesTheQueryEditorsList() async throws {
            SQLTextView.assumesKeyWindow = true
            let workspace = try await postgres()
            workspace.completionCatalog.engine = StubCompletionEngine(words: ["users", "user_id"])
            let tab = QueryTabViewController(workspace: workspace, title: "Query", sql: "SELECT * FROM us")
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = tab
            window.orderFront(nil)
            defer {
                tab.hideCompletions()
                window.orderOut(nil)
                window.close()
            }
            tab.showCompletions()
            await settle()
            #expect(tab.visibleCompletions == ["users", "user_id"])

            await workspace.refreshMetadata()
            #expect(tab.visibleCompletions == ["users", "user_id"], "a refresh in the same scope closed the list")

            await workspace.switchSchema("shop")
            #expect(tab.visibleCompletions.isEmpty)
            await workspace.disconnect()
        }
    }

    @Suite("Scripted UI commands")
    @MainActor
    struct AutoTestRunnerTextTests {
        @Test func onlyTypedTextTurnsBackslashSIntoASpace() {
            #expect(AutoTestRunner.typedText("SELECT\\s") == "SELECT ")
            #expect(AutoTestRunner.typedText("a\\nb") == "a\nb")
            #expect(AutoTestRunner.queryText("SELECT regexp_replace(x, '\\s+', ' ')\\nFROM t") == "SELECT regexp_replace(x, '\\s+', ' ')\nFROM t")
        }
    }
}

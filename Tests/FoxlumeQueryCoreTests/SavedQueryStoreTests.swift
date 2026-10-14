import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct SavedQueryStoreTests {
    private func makeStore() throws -> (SavedQueryStore, URL, URL) {
        let folder = TestFiles.url("saved-queries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("saved-queries.json")
        return (SavedQueryStore(url: file), file, folder)
    }

    @Test func savesAndReloadsQueriesAndFolders() throws {
        let (store, file, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports = try store.saveFolder(SavedQueryFolder(name: "Reports"))
        let monthly = try store.saveFolder(SavedQueryFolder(name: "Monthly", parentID: reports.id))
        let query = try store.save(SavedQuery(name: "Revenue", sql: "SELECT sum(total) FROM orders", keyword: "rev", folderID: monthly.id))

        let reloaded = SavedQueryStore(url: file).library
        // Dates are stored to the second.
        #expect(reloaded.queries.map(\.id) == [query.id])
        #expect(reloaded.queries.first.map { [$0.name, $0.sql, $0.keyword ?? ""] } == ["Revenue", "SELECT sum(total) FROM orders", "rev"])
        #expect(reloaded.queries.first?.folderID == monthly.id)
        #expect(abs(reloaded.queries[0].createdAt.timeIntervalSince(query.createdAt)) < 1)
        #expect(reloaded.folders.map(\.name).sorted() == ["Monthly", "Reports"])
        #expect(reloaded.path(of: monthly.id) == "Reports / Monthly")
        #expect(reloaded.depth(of: monthly.id) == 2)
        #expect(reloaded.childFolders(of: reports.id).map(\.name) == ["Monthly"])
        #expect(reloaded.queries(in: monthly.id).map(\.name) == ["Revenue"])
    }

    @Test func updatingKeepsTheIdAndCreationDate() throws {
        let (store, _, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        var query = try store.save(SavedQuery(name: "A", sql: "SELECT 1", createdAt: Date(timeIntervalSince1970: 1000)))
        query.name = "B"
        let updated = try store.save(query)
        #expect(store.library.queries.count == 1)
        #expect(store.library.queries[0].name == "B")
        #expect(updated.createdAt == Date(timeIntervalSince1970: 1000))
        #expect(updated.updatedAt > updated.createdAt)
    }

    @Test func eachConnectionSeesGlobalQueriesAndItsOwn() throws {
        let (store, _, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mine = UUID(), other = UUID()
        try store.save(SavedQuery(name: "Everywhere", sql: "SELECT 1"))
        try store.save(SavedQuery(name: "Mine", sql: "SELECT 2", connectionID: mine))
        try store.save(SavedQuery(name: "Theirs", sql: "SELECT 3", connectionID: other))
        try store.saveFolder(SavedQueryFolder(name: "Their folder", connectionID: other))

        let visible = store.library(visibleOn: mine)
        #expect(visible.queries.map(\.name) == ["Everywhere", "Mine"])
        #expect(visible.folders.isEmpty)
        #expect(store.library(visibleOn: other).queries.map(\.name) == ["Everywhere", "Theirs"])
    }

    /// A global query in another connection's folder is listed at the top level elsewhere.
    @Test func queriesInFoldersThatAreNotShownMoveToTheTopLevel() throws {
        let (store, _, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let owner = UUID()
        let private_ = try store.saveFolder(SavedQueryFolder(name: "Private", connectionID: owner))
        try store.save(SavedQuery(name: "Shared", sql: "SELECT 1", folderID: private_.id))
        #expect(store.library(visibleOn: owner).queries[0].folderID == private_.id)
        #expect(store.library(visibleOn: UUID()).queries[0].folderID == nil)
    }

    @Test func deletingAFolderMovesItsContentsUp() throws {
        let (store, _, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let top = try store.saveFolder(SavedQueryFolder(name: "Top"))
        let middle = try store.saveFolder(SavedQueryFolder(name: "Middle", parentID: top.id))
        let bottom = try store.saveFolder(SavedQueryFolder(name: "Bottom", parentID: middle.id))
        let query = try store.save(SavedQuery(name: "Q", sql: "SELECT 1", folderID: middle.id))

        try store.deleteFolder(id: middle.id)
        let library = store.library
        #expect(library.folder(id: middle.id) == nil)
        #expect(library.folder(id: bottom.id)?.parentID == top.id)
        #expect(library.query(id: query.id)?.folderID == top.id)
    }

    @Test func foldersCannotMoveIntoTheirOwnSubfolders() throws {
        let (store, _, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        var top = try store.saveFolder(SavedQueryFolder(name: "Top"))
        let child = try store.saveFolder(SavedQueryFolder(name: "Child", parentID: top.id))
        top.parentID = child.id
        #expect(throws: SavedQueryError.folderCycle) { try store.saveFolder(top) }
    }

    @Test func moveDuplicateAndDelete() throws {
        let (store, _, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let connection = UUID()
        let shared = try store.saveFolder(SavedQueryFolder(name: "Shared"))
        let own = try store.saveFolder(SavedQueryFolder(name: "Own", connectionID: connection))
        let global = try store.save(SavedQuery(name: "Global", sql: "SELECT 1", keyword: "g"))

        try store.moveQuery(id: global.id, to: shared.id)
        #expect(store.query(id: global.id)?.folderID == shared.id)
        #expect(throws: SavedQueryError.folderScope("Own")) { try store.moveQuery(id: global.id, to: own.id) }

        let copy = try #require(try store.duplicateQuery(id: global.id))
        #expect(copy.name == "Global copy")
        #expect(copy.keyword == nil)
        #expect(copy.folderID == shared.id)
        #expect(copy.id != global.id)

        try store.deleteQuery(id: global.id)
        #expect(store.library.queries.map(\.name) == ["Global copy"])
    }

    @Test func removingAConnectionDeletesOnlyItsRecords() throws {
        let (store, _, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gone = UUID()
        let goneFolder = try store.saveFolder(SavedQueryFolder(name: "Gone", connectionID: gone))
        try store.save(SavedQuery(name: "Scoped", sql: "SELECT 1", connectionID: gone))
        let kept = try store.save(SavedQuery(name: "Kept", sql: "SELECT 2", folderID: goneFolder.id))
        try store.removeConnection(gone)
        #expect(store.library.folders.isEmpty)
        #expect(store.library.queries.map(\.name) == ["Kept"])
        #expect(store.query(id: kept.id)?.folderID == nil)
    }

    @Test func completionOffersVisibleKeywordsAndPrefersTheConnectionsOwn() throws {
        let (store, _, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mine = UUID()
        try store.save(SavedQuery(name: "Global users", sql: "SELECT * FROM users", keyword: "us", createdAt: Date(timeIntervalSince1970: 1)))
        try store.save(SavedQuery(name: "My users", sql: "SELECT id FROM users", keyword: "US", connectionID: mine, createdAt: Date(timeIntervalSince1970: 2)))
        try store.save(SavedQuery(name: "Other", sql: "SELECT 1", keyword: "ot", connectionID: UUID()))
        try store.save(SavedQuery(name: "No keyword", sql: "SELECT 2"))

        let favorites = store.completionFavorites(for: mine)
        #expect(favorites == [CompletionFavorite(keyword: "US", name: "My users", query: "SELECT id FROM users")])
        #expect(store.completionFavorites(for: UUID()).map(\.name) == ["Global users"])
    }

    @Test func damagedFileIsSetAsideAndReadableEntriesSurvive() throws {
        let (_, file, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = SavedQuery(name: "Kept", sql: "SELECT 1")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let goodJSON = String(decoding: try encoder.encode(good), as: UTF8.self)
        try "{\"version\": 1, \"folders\": [{\"name\": 3}], \"queries\": [\(goodJSON), {\"sql\": \"no name\"}]}".write(to: file, atomically: true, encoding: .utf8)

        let store = SavedQueryStore(url: file)
        #expect(store.library.queries.map(\.name) == ["Kept"])
        #expect(store.library.folders.isEmpty)
        let aside = try #require(store.setAsideFile)
        #expect(aside.lastPathComponent.hasPrefix("saved-queries.unreadable-"))
        #expect(try String(contentsOf: aside, encoding: .utf8).contains("no name"))

        // The next save writes a fresh file and leaves the set-aside copy alone.
        try store.save(SavedQuery(name: "New", sql: "SELECT 2"))
        #expect(SavedQueryStore(url: file).library.queries.map(\.name) == ["Kept", "New"])
        #expect(FileManager.default.fileExists(atPath: aside.path))
    }

    @Test func unparsableFileIsSetAsideToo() throws {
        let (_, file, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "not json at all".write(to: file, atomically: true, encoding: .utf8)
        let store = SavedQueryStore(url: file)
        #expect(store.library.queries.isEmpty)
        #expect(store.setAsideFile != nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func missingFileMeansAnEmptyLibrary() throws {
        let store = SavedQueryStore(url: TestFiles.url("absent-\(UUID().uuidString).json"))
        #expect(store.library.queries.isEmpty && store.library.folders.isEmpty)
        #expect(store.setAsideFile == nil)
    }
}

@Suite struct SavedQueryValidationTests {
    private let mine = UUID()
    private let other = UUID()

    private let library: SavedQueryLibrary

    init() {
        library = SavedQueryLibrary(queries: [
            SavedQuery(name: "Global", sql: "SELECT 1", keyword: "glob"),
            SavedQuery(name: "Mine", sql: "SELECT 2", keyword: "mine", connectionID: mine),
            SavedQuery(name: "Theirs", sql: "SELECT 3", keyword: "theirs", connectionID: other),
        ])
    }

    private func issues(name: String = "Name", sql: String = "SELECT 1", keyword: String?, scope: UUID?, editing: UUID? = nil) -> [SavedQueryValidation.Issue] {
        SavedQueryValidation.issues(name: name, sql: sql, keyword: keyword, scope: scope, editing: editing, in: library)
    }

    @Test func nameAndQueryAreRequired() {
        let found = issues(name: "  ", sql: "\n", keyword: nil, scope: mine)
        #expect(found.map(\.field) == [.name, .sql])
        #expect(!SavedQueryValidation.canSave(found))
        #expect(SavedQueryValidation.canSave(issues(keyword: "", scope: mine)))
    }

    @Test func keywordsCannotContainSpaces() {
        let found = issues(keyword: "two words", scope: mine)
        #expect(found.first?.message == "A keyword cannot contain spaces.")
        #expect(!SavedQueryValidation.canSave(found))
        #expect(SavedQueryValidation.normalizedKeyword("  kw \n") == "kw")
        #expect(SavedQueryValidation.normalizedKeyword("   ") == nil)
    }

    @Test func keywordClashesFollowTheScopes() {
        // A connection's query clashes with global ones and its own connection's, ignoring case.
        #expect(!SavedQueryValidation.canSave(issues(keyword: "GLOB", scope: mine)))
        #expect(!SavedQueryValidation.canSave(issues(keyword: "mine", scope: mine)))
        #expect(SavedQueryValidation.canSave(issues(keyword: "theirs", scope: mine)))
        // A global query clashes with every query.
        #expect(!SavedQueryValidation.canSave(issues(keyword: "theirs", scope: nil)))
        // The query being edited keeps its own keyword.
        let own = library.queries[1]
        #expect(SavedQueryValidation.canSave(issues(keyword: "mine", scope: mine, editing: own.id)))
        #expect(issues(keyword: "glob", scope: mine).first?.message == "“glob” is already the keyword of “Global”.")
    }

    @Test func sqlKeywordsOnlyWarn() {
        let found = issues(keyword: "select", scope: mine)
        #expect(found.count == 1)
        #expect(found[0].isError == false)
        #expect(SavedQueryValidation.canSave(found))
    }

    @Test func suggestedNames() {
        #expect(SavedQueryValidation.suggestedName(for: "\n  SELECT * FROM users\nWHERE id = 1") == "SELECT * FROM users")
        #expect(SavedQueryValidation.suggestedName(for: "-- Active customers\nSELECT 1") == "Active customers")
        #expect(SavedQueryValidation.suggestedName(for: "--\nSELECT 2") == "SELECT 2")
        #expect(SavedQueryValidation.suggestedName(for: "   ") == "Untitled")
        #expect(SavedQueryValidation.suggestedName(for: String(repeating: "x", count: 80)).count == 50)
    }
}

import AppKit
import Testing
@testable import FoxlumeQuery
@testable import FoxlumeQueryCore

extension AppCompletionTests {
    /// The import sheet's model with JSON and XLSX files on a scratch SQLite table: the file kind, the sheet
    /// picker, the header toggle, the source fields and their mapping, and row numbers in the summary.
    @Suite("Import sheet")
    @MainActor
    struct ImportSheetAppTests {
        private let table = TableRef(name: "fq_import_people")

        private func scratchURL(_ name: String, _ ext: String) -> URL {
            let directory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
            return directory.appendingPathComponent("import-\(name)-\(UUID().uuidString).\(ext)")
        }

        private func makeWorkspace(_ url: URL) async throws -> ConnectionWorkspace {
            let session = DatabaseSession(parameters: ConnectionParameters(config: ConnectionConfig(kind: .sqlite, filePath: url.path), password: ""))
            try await session.connect()
            _ = try await session.execute("CREATE TABLE fq_import_people (id INTEGER PRIMARY KEY, full_name TEXT, born DATE)")
            await session.close()
            let workspace = ConnectionWorkspace(config: ConnectionConfig(name: "fqtest", kind: .sqlite, filePath: url.path), password: "")
            try await workspace.connect()
            return workspace
        }

        private func close(_ workspace: ConnectionWorkspace, _ files: [URL]) async {
            await workspace.disconnect()
            for file in files {
                for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
            }
        }

        /// Waits for the preview and the table's columns, which load in the background.
        private func settle(_ model: ImportCSVModel, until done: () -> Bool) async throws {
            for _ in 0..<200 where !done() {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        @Test func xlsxFileShowsSheetsAndMapsByHeader() async throws {
            let database = scratchURL("db", "sqlite")
            let workbook = scratchURL("people", "xlsx")
            let workspace = try await makeWorkspace(database)
            defer { Task { await close(workspace, [database, workbook]) } }
            let columns = [ResultColumn(name: "id", typeName: "integer", isNumeric: true), ResultColumn(name: "full_name", typeName: "text"), ResultColumn(name: "born", typeName: "date")]
            let warnings = try ResultExporter.write(columns: columns, rows: [[.text("1"), .text("Ada"), .text("1815-12-10")], [.text("2"), .null, .text("1906-12-09")]],
                                                    format: .xlsx, sheetName: "People", to: workbook)
            #expect(warnings.isEmpty)

            let model = ImportCSVModel(workspace: workspace, table: table, file: workbook)
            model.options.hasHeaderRow = true
            model.reloadPreview()
            try await settle(model) { !model.previewRecords.isEmpty && !model.columns.isEmpty && model.sources.count == 3 }
            #expect(model.kind == .xlsx)
            #expect(model.lineWord == "Row")
            #expect(model.sheetNames == ["People"])
            #expect(model.sheet == "People")
            #expect(model.previewError == nil)
            #expect(model.rowsInPreview.count == 2)
            #expect(model.sources.map(\.name) == ["id", "full_name", "born"])
            #expect(model.mapping.map(\.column) == ["id", "full_name", "born"])
            #expect(model.mappingProblem == nil)

            // Without the header row the first row is data and the fields are positional.
            model.options.hasHeaderRow = false
            model.rebuildSources()
            #expect(model.rowsInPreview.count == 3)
            #expect(model.sources.map(\.name) != ["id", "full_name", "born"])
        }

        @Test func jsonFileUsesItsKeysAsFields() async throws {
            let database = scratchURL("db", "sqlite")
            let file = scratchURL("people", "ndjson")
            let workspace = try await makeWorkspace(database)
            defer { Task { await close(workspace, [database, file]) } }
            try Data("{\"full_name\":\"Ada\",\"id\":1}\n{\"id\":2,\"born\":\"1906-12-09\"}\n".utf8).write(to: file)

            let model = ImportCSVModel(workspace: workspace, table: table, file: file)
            try await settle(model) { !model.previewRecords.isEmpty && !model.columns.isEmpty && model.sources.count == 3 }
            #expect(model.kind == .json)
            #expect(model.lineWord == "Line")
            #expect(!model.usesHeaderRow)
            #expect(model.rowsInPreview.count == 2)
            #expect(Set(model.sources.map(\.name)) == ["id", "full_name", "born"])
            #expect(Set(model.mapping.map(\.column)) == ["id", "full_name", "born"])
            #expect(model.mappingProblem == nil)
        }

        @Test func fileKindFollowsTheExtensionOrTheZipSignature() throws {
            let disguised = scratchURL("book", "dat")
            defer { try? FileManager.default.removeItem(at: disguised) }
            _ = try ResultExporter.write(columns: [ResultColumn(name: "a")], rows: [[.text("x")]], format: .xlsx, to: disguised)
            #expect(ImportCSVModel.FileKind.of(disguised) == .xlsx)
            #expect(ImportCSVModel.FileKind.of(URL(fileURLWithPath: "/nonexistent/a.jsonl")) == .json)
            #expect(ImportCSVModel.FileKind.of(URL(fileURLWithPath: "/nonexistent/a.XLSX")) == .xlsx)
            #expect(ImportCSVModel.FileKind.of(URL(fileURLWithPath: "/nonexistent/a.tsv")) == .csv)
        }

        @Test func summaryNamesSheetRows() {
            let failure = ImportIssue(line: 7, snippet: "x", message: "bad date")
            let report = CSVImportReport(rowsRead: 7, rowsImported: 0, rowsSkipped: 0, issues: [], failure: failure, cancelled: false, rolledBack: true, elapsed: 0)
            let summary = ImportCSVModel.summary(report, table: table, file: URL(fileURLWithPath: "/nonexistent/a.xlsx"), lineWord: "Row")
            #expect(summary.title == "Import failed at row 7; nothing was imported")
        }
    }
}

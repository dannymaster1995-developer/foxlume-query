import AppKit
import FoxlumeQueryCore

/// Scripted commands for the transfer sheets. File panels are skipped: paths come from the script.
///
///     exporttables users,orders        open Export Tables with these ticked (none: empty selection)
///     exportformat sql                 csv | json | ndjson | xlsx | sql
///     exportoption rowsPerInsert 100   filePerTable, rowsPerInsert, compress, csvHeader, csvDelimiter, jsonPrettyPrint
///     exportfilter users country = 'DE'
///     exportrun /path/out.sql          a file, or a folder when each table gets its own file
///     exportstart /path/out.csv        starts without waiting; exportstop presses Stop
///     importcsv users /path/in.csv     open the import sheet for a table and a CSV, JSON, NDJSON or XLSX file
///     importfile users /path/in.xlsx   the same
///     importoption policy skipAndContinue   policy, header, emptyAsNull, deleteExisting, delimiter, nullToken, sheet
///     exportresult /path/out.xlsx      writes the selected tab's rows as Export Results does (format from the extension)
///     xlsxinfo /path/file.xlsx         logs a workbook's sheets, row counts and first rows
///     importrun
///     runsqlfile /path/in.sql          open Run SQL File for a file
///     sqlfileoption policy stopAndKeep policy, fk
///     sqlfilerun
///     sheets                           logs the sheets stacked on each window (alerts show their message)
///     confirmsheet                     presses the first button of the alert in front (for production prompts)
@MainActor
enum TransferAutoTest {
    static let commands: Set<String> = [
        "exporttables", "exportformat", "exportoption", "exportfilter", "exportrun", "exportstart", "exportstop",
        "importcsv", "importfile", "importoption", "importrun", "exportresult", "xlsxinfo", "runsqlfile", "sqlfileoption", "sqlfilerun", "sheets", "confirmsheet",
    ]

    static func closeSheets() {
        TransferSheets.exportSheet?.dismiss()
        TransferSheets.importSheet?.dismiss()
        TransferSheets.sqlFileSheet?.dismiss()
    }
}

extension AutoTestRunner {
    func performTransfer(_ command: String, _ argument: String) async throws {
        guard let workspace else { throw DatabaseError.notConnected }
        let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
        let key = words.first ?? ""
        let value = words.count > 1 ? words[1] : ""
        switch command {
        case "exporttables":
            let names = argument.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let refs = workspace.workspace.tables.filter { names.contains($0.name) }.map(\.ref)
            workspace.presentExport(preselecting: refs)
            try await Task.sleep(nanoseconds: 900_000_000)
        case "exportformat":
            guard let model = TransferSheets.exportSheet?.model, let format = TableExportFormat(rawValue: argument) else {
                throw DatabaseError.unsupported("exportformat csv|json|ndjson|xlsx|sql")
            }
            model.options.format = format
            try await Task.sleep(nanoseconds: 400_000_000)
        case "exportoption":
            guard let model = TransferSheets.exportSheet?.model else { throw DatabaseError.unsupported("No export sheet") }
            switch key {
            case "filePerTable": model.options.filePerTable = value == "true"
            case "rowsPerInsert": model.options.rowsPerInsert = Int(value) ?? 500
            case "compress": model.options.compress = value == "true"
            case "csvHeader": model.options.csvHeader = value == "true"
            case "csvDelimiter": model.options.csvDelimiter = CSVDelimiter.allCases.first { $0.title.lowercased() == value.lowercased() } ?? .comma
            case "jsonPrettyPrint": model.options.jsonPrettyPrint = value == "true"
            default: throw DatabaseError.unsupported("Unknown export option \(key)")
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        case "exportfilter":
            guard let model = TransferSheets.exportSheet?.model, let index = model.rows.firstIndex(where: { $0.info.name == key }) else {
                throw DatabaseError.unsupported("exportfilter <table> <condition>")
            }
            model.rows[index].whereClause = value
            model.setSelected(index, true)
            try await Task.sleep(nanoseconds: 300_000_000)
        case "exportstop":
            guard let model = TransferSheets.exportSheet?.model else { throw DatabaseError.unsupported("No export sheet") }
            model.cancel()
            try await waitFor(seconds: 30) { !model.isRunning }
            record("  export: \(model.message ?? "stopped")")
            try await Task.sleep(nanoseconds: 300_000_000)
        case "exportrun", "exportstart":
            guard let model = TransferSheets.exportSheet?.model else { throw DatabaseError.unsupported("No export sheet") }
            switch model.items() {
            case .failure(let error):
                record("  export refused: \(error.localizedDescription)")
            case .success(let items):
                let url = URL(fileURLWithPath: argument)
                let folder = model.options.writesFilePerTable(tableCount: items.count)
                if folder { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
                model.start(items: items, destination: folder ? .directory(url) : .file(url))
                if command == "exportstart" {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    record("  export: \(model.progressText)")
                    return
                }
                try await waitFor(seconds: 180) { !model.isRunning }
                switch model.phase {
                case .finished(let summary): record("  export: \(summary.title) — \(summary.detail)")
                case .failed(let error): record("  export failed: \(error)")
                case .editing, .running: record("  export: \(model.message ?? "not finished")")
                }
            }
        case "importcsv", "importfile":
            guard let table = workspace.workspace.importableTables.first(where: { $0.name == key }) else {
                throw DatabaseError.unsupported("\(command) <table> <file>")
            }
            workspace.presentImportCSV(into: table.ref, file: URL(fileURLWithPath: value))
            try await Task.sleep(nanoseconds: 1_200_000_000)
            if let model = TransferSheets.importSheet?.model {
                if model.kind == .xlsx { record("  sheets: \(model.sheetNames.joined(separator: ", ")) (importing \(model.sheet ?? "none"))") }
                if let error = model.previewError { record("  preview: \(error)") }
                record("  mapping: " + model.sources.map { "\($0.name)→\($0.column ?? "skip")" }.joined(separator: ", "))
            }
        case "importoption":
            guard let model = TransferSheets.importSheet?.model else { throw DatabaseError.unsupported("No import sheet") }
            switch key {
            case "policy": model.options.errorPolicy = ImportErrorPolicy(rawValue: value) ?? .stopAndRollBack
            case "header":
                model.options.hasHeaderRow = value == "true"
                model.rebuildSources()
                model.autoMap(byName: model.options.hasHeaderRow)
            case "emptyAsNull": model.options.emptyAsNull = value == "true"
            case "deleteExisting": model.options.deleteExistingRows = value == "true"
            case "nullToken": model.options.nullToken = value
            case "sheet":
                model.setSheet(value)
                try await Task.sleep(nanoseconds: 600_000_000)
                record("  mapping: " + model.sources.map { "\($0.name)→\($0.column ?? "skip")" }.joined(separator: ", "))
            case "delimiter":
                model.options.delimiter = CSVDelimiter.allCases.first { $0.title.lowercased() == value.lowercased() }
                model.reloadPreview()
            default: throw DatabaseError.unsupported("Unknown import option \(key)")
            }
            try await Task.sleep(nanoseconds: 600_000_000)
        case "importrun":
            guard let model = TransferSheets.importSheet?.model else { throw DatabaseError.unsupported("No import sheet") }
            model.importClicked()
            try await Task.sleep(nanoseconds: 300_000_000)
            try await waitFor(seconds: 180) { !model.isRunning }
            switch model.phase {
            case .finished(let summary): record("  import: \(summary.title) — \(summary.detail) — issues: \(summary.issues.map { "line \($0.line)" }.joined(separator: ", "))")
            case .failed(let error): record("  import failed: \(error)")
            case .editing, .running: record("  import: \(model.message ?? model.mappingProblem ?? "not started")")
            }
        case "exportresult":
            let url = URL(fileURLWithPath: argument)
            guard let format = ExportFormat.allCases.first(where: { $0.fileExtension == url.pathExtension.lowercased() }) else {
                throw DatabaseError.unsupported("exportresult /path/file.<csv|tsv|json|sql|md|xlsx>")
            }
            let content = workspace.tabs.selectedTab?.content
            let grid: DataGridView
            let name: String
            if let query = content as? QueryTabViewController {
                grid = query.grid
                name = query.tabTitle
            } else if let tableTab = content as? TableTabViewController {
                grid = tableTab.grid
                name = tableTab.table.name
            } else {
                throw DatabaseError.unsupported("exportresult needs a query or table tab")
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let warnings = try ExportPanel.write(columns: grid.content.columns, rows: grid.content.rows, format: format, includeHeader: true,
                                                 suggestedName: name, tableName: name, dialect: workspace.workspace.dialect, to: url)
            record("  exported \(grid.content.rows.count) rows to \(url.lastPathComponent)" + (warnings.isEmpty ? "" : " — " + warnings.joined(separator: " ")))
        case "xlsxinfo":
            let workbook = try XLSXWorkbook(url: URL(fileURLWithPath: argument))
            for sheet in workbook.sheets {
                let reader = try workbook.reader(for: sheet)
                var rows: [CSVRecord] = []
                var count = 0
                while let record = try reader.next() {
                    if rows.count < 3 { rows.append(record) }
                    count += 1
                }
                record("  sheet \(sheet.name): \(count) rows")
                for row in rows {
                    record("    " + row.fields.map { $0.isNull ? "∅" : $0.text }.joined(separator: " | "))
                }
            }
        case "runsqlfile":
            workspace.presentRunSQLFile(file: URL(fileURLWithPath: argument))
            try await Task.sleep(nanoseconds: 1_200_000_000)
            if let model = TransferSheets.sqlFileSheet?.model { record("  sql file: \(model.countText)") }
        case "sqlfileoption":
            guard let model = TransferSheets.sqlFileSheet?.model else { throw DatabaseError.unsupported("No SQL file sheet") }
            switch key {
            case "policy": model.options.errorPolicy = ImportErrorPolicy(rawValue: value) ?? .stopAndRollBack
            case "fk": model.options.disableForeignKeyChecks = value == "true"
            default: throw DatabaseError.unsupported("Unknown SQL file option \(key)")
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        case "sqlfilerun":
            guard let model = TransferSheets.sqlFileSheet?.model else { throw DatabaseError.unsupported("No SQL file sheet") }
            model.runClicked()
            try await Task.sleep(nanoseconds: 300_000_000)
            try await waitFor(seconds: 180) { !model.isRunning }
            switch model.phase {
            case let .finished(title, detail, _, issues): record("  sql file: \(title) — \(detail) — issues: \(issues.map { "line \($0.line)" }.joined(separator: ", "))")
            case .failed(let error): record("  sql file failed: \(error)")
            case .editing, .running: record("  sql file: \(model.message ?? "not started")")
            }
        case "sheets":
            for window in NSApp.windows where window.isVisible {
                var chain: [String] = []
                var sheet = window.attachedSheet
                while let current = sheet {
                    chain.append(Self.describe(current))
                    sheet = current.attachedSheet
                }
                if !chain.isEmpty { record("  \(window.title) ⟶ " + chain.joined(separator: " ⟶ ")) }
            }
        case "confirmsheet":
            for window in NSApp.windows {
                var sheet = window.attachedSheet
                while let current = sheet, current.attachedSheet != nil { sheet = current.attachedSheet }
                guard let alertWindow = sheet else { continue }
                // Destructive confirmations have no Return key equivalent; take the button that is not Cancel.
                let candidates = Self.buttons(in: alertWindow.contentView).filter { !$0.title.isEmpty }
                guard let button = candidates.first(where: { $0.keyEquivalent == "\r" }) ?? candidates.first(where: { $0.title != "Cancel" }) else { continue }
                record("  pressed \(button.title)")
                button.performClick(nil)
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        default:
            throw DatabaseError.unsupported("Unknown command \(command)")
        }
    }

    /// A sheet's title, or for an alert its message text.
    private static func describe(_ window: NSWindow) -> String {
        if !window.title.isEmpty { return window.title }
        let texts = labels(in: window.contentView).filter { !$0.isEmpty }
        return texts.first.map { "alert: \($0)" } ?? window.className
    }

    private static func labels(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { labels(in: $0) }
    }

    private static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        let own = (view as? NSButton).map { [$0] } ?? []
        return own + view.subviews.flatMap { buttons(in: $0) }
    }
}

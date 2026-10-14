import Foundation
import Testing
@testable import FoxlumeQueryCore

/// Scratch files for import and export tests, removed by the caller.
enum TransferFiles {
    static func write(_ text: String, name: String = "fq-io-\(UUID().uuidString).csv") throws -> URL {
        let url = TestFiles.url(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    static func write(bytes: [UInt8], name: String = "fq-io-\(UUID().uuidString).csv") throws -> URL {
        let url = TestFiles.url(name)
        try Data(bytes).write(to: url)
        return url
    }

    static func folder() throws -> URL {
        let url = TestFiles.url("fq-io-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    static func records(_ url: URL, delimiter: CSVDelimiter = .comma, encoding: ImportTextEncoding = .automatic, chunkSize: Int = 1 << 16) throws -> [CSVRecord] {
        let reader = try CSVReader(url: url, delimiter: delimiter, encoding: encoding, chunkSize: chunkSize)
        var records: [CSVRecord] = []
        while let record = try reader.next() { records.append(record) }
        return records
    }
}

@Suite struct CSVReaderTests {
    @Test func parsesQuotedFieldsWithDelimitersQuotesAndNewlines() throws {
        let url = try TransferFiles.write("id,text\r\n1,\"a,b\"\r\n2,\"say \"\"hi\"\"\"\r\n3,\"line1\nline2\"\r\n4,plain\r\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let records = try TransferFiles.records(url)
        #expect(records.map(\.texts) == [["id", "text"], ["1", "a,b"], ["2", "say \"hi\""], ["3", "line1\nline2"], ["4", "plain"]])
        #expect(records.map(\.line) == [1, 2, 3, 4, 6])
    }

    @Test(arguments: [1, 2, 3, 7, 64])
    func tinyChunksGiveTheSameRecords(chunkSize: Int) throws {
        let text = "naïve,\"Zoë, \"\"Müller\"\"\"\r\n😀 emoji,\"multi\r\nline\"\n,\"\"\nlast,row"
        let url = try TransferFiles.write(text)
        defer { try? FileManager.default.removeItem(at: url) }
        let records = try TransferFiles.records(url, chunkSize: chunkSize)
        #expect(records.map(\.texts) == [["naïve", "Zoë, \"Müller\""], ["😀 emoji", "multi\r\nline"], ["", ""], ["last", "row"]])
        #expect(records[2].fields.map(\.wasQuoted) == [false, true])
    }

    @Test func skipsBlankLinesAndKeepsTrailingEmptyField() throws {
        let url = try TransferFiles.write("a,b\n\n1,\n\r\n2,x\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try TransferFiles.records(url).map(\.texts) == [["a", "b"], ["1", ""], ["2", "x"]])
    }

    @Test func toleratesStrayQuotes() throws {
        let url = try TransferFiles.write("5\" disk,\"quoted\"tail\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try TransferFiles.records(url).map(\.texts) == [["5\" disk", "quotedtail"]])
    }

    @Test func reportsUnclosedQuote() throws {
        let url = try TransferFiles.write("a,b\n1,\"never closed\n2,3\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: DatabaseError.self) { try TransferFiles.records(url) }
    }

    @Test func stripsUTF8ByteOrderMark() throws {
        let url = try TransferFiles.write(bytes: [0xEF, 0xBB, 0xBF] + Array("id,name\n1,Zoë\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let records = try TransferFiles.records(url)
        #expect(records.first?.texts == ["id", "name"])
        #expect(records.last?.texts == ["1", "Zoë"])
    }

    @Test(arguments: [ImportTextEncoding.utf16LittleEndian, .utf16BigEndian])
    func readsUTF16WithByteOrderMark(encoding: ImportTextEncoding) throws {
        let text = "id\tname\n1\tZoë 😀\n"
        var bytes: [UInt8] = encoding == .utf16LittleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]
        bytes += Array(text.data(using: encoding.foundationEncoding) ?? Data())
        let url = try TransferFiles.write(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        for chunkSize in [3, 5, 1 << 16] {
            let records = try TransferFiles.records(url, delimiter: .tab, chunkSize: chunkSize)
            #expect(records.map(\.texts) == [["id", "name"], ["1", "Zoë 😀"]])
        }
    }

    @Test func detectsWindows1252WhenNotUTF8() throws {
        // "café" with é as the single byte 0xE9.
        let url = try TransferFiles.write(bytes: Array("name\ncaf".utf8) + [0xE9] + [0x0A])
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try CSVReader(url: url, delimiter: .comma)
        #expect(reader.encoding == .windows1252)
        var texts: [[String]] = []
        while let record = try reader.next() { texts.append(record.texts) }
        #expect(texts == [["name"], ["café"]])
    }

    @Test func invalidUTF8IsAnErrorWhenUTF8IsChosen() throws {
        let url = try TransferFiles.write(bytes: Array("name\ncaf".utf8) + [0xE9, 0x0A])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: DatabaseError.self) { try TransferFiles.records(url, encoding: .utf8) }
    }

    @Test func detectsDelimiters() {
        #expect(CSVReader.detectDelimiter(in: "a;b;c\n1;2;3\n4;5;6\n") == .semicolon)
        #expect(CSVReader.detectDelimiter(in: "a\tb\n1\t2\n") == .tab)
        #expect(CSVReader.detectDelimiter(in: "a|b|c\n1|2|3\n") == .pipe)
        #expect(CSVReader.detectDelimiter(in: "name,note\n\"x;y;z\",1\n\"p;q\",2\n") == .comma)
        #expect(CSVReader.detectDelimiter(in: "single column\nvalue\n") == .comma)
    }

    @Test func previewDetectsSettings() throws {
        let url = try TransferFiles.write("id;name\n1;Zoë\n2;Bob\n3;Al\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = try CSVReader.preview(url: url, delimiter: nil, encoding: .automatic, limit: 2)
        #expect(preview.delimiter == .semicolon)
        #expect(preview.encoding == .utf8)
        #expect(preview.records.map(\.texts) == [["id", "name"], ["1", "Zoë"]])
    }
}

@Suite struct ExportEncodingTests {
    let text = ExportColumn(name: "t")
    let number = ExportColumn(name: "n", isNumeric: true)
    let flag = ExportColumn(name: "f", isBoolean: true)

    @Test func csvFields() {
        let options = TableExportOptions()
        #expect(ExportValueEncoding.csvField(.text("plain"), column: text, options: options) == "plain")
        #expect(ExportValueEncoding.csvField(.text("a,b"), column: text, options: options) == "\"a,b\"")
        #expect(ExportValueEncoding.csvField(.text("say \"hi\""), column: text, options: options) == "\"say \"\"hi\"\"\"")
        #expect(ExportValueEncoding.csvField(.text("two\nlines"), column: text, options: options) == "\"two\nlines\"")
        #expect(ExportValueEncoding.csvField(.text(""), column: text, options: options) == "\"\"")
        #expect(ExportValueEncoding.csvField(.null, column: text, options: options) == "")
        #expect(ExportValueEncoding.csvField(.bytes(Data([0xDE, 0xAD])), column: text, options: options) == "0xDEAD")
        #expect(ExportValueEncoding.csvField(.text("Zoë 😀"), column: text, options: options) == "Zoë 😀")
    }

    @Test func csvOptions() {
        var options = TableExportOptions()
        options.csvNullAsEmpty = false
        options.csvQuoting = .always
        options.csvDelimiter = .semicolon
        options.csvLineEnding = .crlf
        #expect(ExportValueEncoding.csvRow([.text("1"), .null, .text("a;b")], columns: [number, text, text], options: options) == "\"1\";NULL;\"a;b\"\r\n")
        options = TableExportOptions()
        options.csvLineBreaksAsSpaces = true
        options.csvProtectFormulas = true
        #expect(ExportValueEncoding.csvField(.text("a\r\nb"), column: text, options: options) == "a b")
        #expect(ExportValueEncoding.csvField(.text("=SUM(A1)"), column: text, options: options) == "\"'=SUM(A1)\"")
        #expect(ExportValueEncoding.csvField(.text("-5"), column: number, options: options) == "-5")
        #expect(ExportValueEncoding.csvHeader([number, ExportColumn(name: "a,b")], options: options) == "n,\"a,b\"\n")
    }

    @Test func jsonValues() {
        let options = TableExportOptions()
        let row: [CellValue] = [.text("12.5"), .text("t"), .text("x\"\n"), .null, .bytes(Data([1, 2]))]
        let columns = [number, flag, text, text, ExportColumn(name: "b")]
        #expect(ExportValueEncoding.jsonObject(row, columns: columns, options: options, spaced: false) == #"{"n":12.5,"f":true,"t":"x\"\n","t":null,"b":"AQI="}"#)
        var withoutNulls = options
        withoutNulls.jsonIncludeNulls = false
        #expect(ExportValueEncoding.jsonObject([.text("NaN"), .null], columns: [number, text], options: withoutNulls, spaced: true) == #"{"n": "NaN"}"#)
    }

    @Test func sqlLiteralsPerDialect() {
        let value = CellValue.text("It's a \\ backslash")
        #expect(ExportValueEncoding.sqlLiteral(value, column: text, dialect: .postgresql) == "'It''s a \\ backslash'")
        #expect(ExportValueEncoding.sqlLiteral(value, column: text, dialect: .mysql) == "'It''s a \\\\ backslash'")
        #expect(ExportValueEncoding.sqlLiteral(.text("42"), column: number, dialect: .mysql) == "42")
        #expect(ExportValueEncoding.sqlLiteral(.text("42abc"), column: number, dialect: .mysql) == "'42abc'")
        #expect(ExportValueEncoding.sqlLiteral(.bytes(Data([0xDE, 0xAD])), column: text, dialect: .mysql) == "X'dead'")
        #expect(ExportValueEncoding.sqlLiteral(.bytes(Data([0xDE, 0xAD])), column: text, dialect: .postgresql) == "decode('dead', 'hex')")
        #expect(ExportValueEncoding.sqlLiteral(.null, column: number, dialect: .postgresql) == "NULL")
        #expect(ExportValueEncoding.sqlLiteral(.text("nul\0byte"), column: text, dialect: .mysql) == "'nul\\0byte'")
    }

    @Test func rowFiltersRefuseSecondStatements() throws {
        #expect(try TableExportItem.validatedCondition(" id > 3 ; ") == "id > 3")
        #expect(try TableExportItem.validatedCondition("note = 'a;b'") == "note = 'a;b'")
        #expect(throws: DatabaseError.self) { try TableExportItem.validatedCondition("1=1; DROP TABLE users") }
    }

    @Test func fileNamesAreUniqueAndSafe() {
        let names = TableExporter.fileNames(for: [
            TableRef(schema: "public", name: "users"),
            TableRef(schema: "shop", name: "users"),
            TableRef(schema: "public", name: "a/b"),
            TableRef(name: ".hidden"),
        ], extension: "csv")
        #expect(names == ["public.users.csv", "shop.users.csv", "a_b.csv", "_hidden.csv"])
    }

    @Test func dependencyOrderPutsParentsFirstAndViewsLast() {
        let parent = TableRef(schema: "public", name: "users")
        let child = TableRef(schema: "public", name: "orders")
        let view = TableRef(schema: "public", name: "summary")
        let childStructure = TableStructure(table: child, columns: [], foreignKeys: [
            ForeignKeyInfo(name: "fk", columns: ["user_id"], referencedTable: parent, referencedColumns: ["id"]),
        ])
        let order = TableExporter.dependencyOrder([
            (TableExportItem(table: view, kind: .view), nil),
            (TableExportItem(table: child), childStructure),
            (TableExportItem(table: parent), TableStructure(table: parent, columns: [])),
        ])
        #expect(order == [2, 1, 0])
    }

    @Test func serialSequenceNames() {
        #expect(TableExporter.serialSequence(in: "nextval('users_id_seq'::regclass)") == "users_id_seq")
        #expect(TableExporter.serialSequence(in: "nextval('shop.\"Odd''s_seq\"'::regclass)") == "shop.\"Odd's_seq\"")
        #expect(TableExporter.serialSequence(in: "now()") == nil)
    }

    @Test func gzipRoundTrip() throws {
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("dump.sql.gz")
        let writer = try ExportFileWriter(destination: url, compress: true)
        var expected = ""
        for index in 0..<5000 {
            let line = "INSERT INTO t VALUES (\(index), 'Zoë 😀 \(index)');\n"
            expected += line
            try writer.write(line)
        }
        try writer.commit()
        let compressed = try Data(contentsOf: url)
        #expect(compressed.starts(with: [0x1F, 0x8B]))
        #expect(compressed.count < expected.utf8.count / 4)
        let source = try TextChunkSource(url: url, encoding: .automatic, chunkSize: 4096)
        #expect(source.isCompressed)
        var bytes: [UInt8] = []
        while let chunk = try source.next() { bytes += chunk }
        #expect(String(decoding: bytes, as: UTF8.self) == expected)
        // Only the finished file is left in the folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["dump.sql.gz"])
    }

    @Test func discardedWriterLeavesExistingFileAlone() throws {
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("keep.csv")
        try Data("original".utf8).write(to: url)
        let writer = try ExportFileWriter(destination: url, compress: false)
        try writer.write("partial")
        writer.discard()
        #expect(try TransferFiles.read(url) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["keep.csv"])
    }

    @Test func mysqlDefinitionsDropCounterAndDefiner() throws {
        final class Stub: DatabaseConnection {
            var kind: DatabaseKind { .mysql }
            var dialect: SQLDialect { .mysql }
            func connect() throws {}
            func close() {}
            var serverVersion: String { "8.4" }
            func execute(_ sql: String, rowLimit: Int?) throws -> [StatementResult] { [] }
            func cancel() {}
            func databases() throws -> [String] { [] }
            var currentDatabase: String? { "db" }
            func useDatabase(_ name: String) throws {}
            func schemas() throws -> [String] { [] }
            var defaultSchema: String? { nil }
            func tables(schema: String?) throws -> [TableInfo] { [] }
            func structure(of table: TableRef) throws -> TableStructure { TableStructure(table: table, columns: []) }
            func ddl(of table: TableRef) throws -> String { "" }
        }
        let exporter = TableExporter(connection: Stub(), options: TableExportOptions())
        let table = "CREATE TABLE `t` (\n  `id` int NOT NULL AUTO_INCREMENT\n) ENGINE=InnoDB AUTO_INCREMENT=42 DEFAULT CHARSET=utf8mb4;"
        #expect(exporter.cleanedDDL(table, isView: false) == "CREATE TABLE `t` (\n  `id` int NOT NULL AUTO_INCREMENT\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;")
        let view = "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `v` AS select 1;"
        #expect(exporter.cleanedDDL(view, isView: true) == "CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `v` AS select 1;")
        #expect(exporter.dropStatement(TableExportItem(table: TableRef(name: "t"))) == "DROP TABLE IF EXISTS `t`;")
    }
}

@Suite struct ImportMappingTests {
    @Test func headerNamesAreCleaned() {
        #expect(CSVImportMapping.headerNames([" id ", "", "Name", "name", "name"]) == ["id", "Column 2", "Name", "name 2", "name 3"])
    }

    @Test func matchesByNameThenIgnoringCase() {
        let mapping = CSVImportMapping.byName(sources: ["EMAIL", "id", "Extra", "email"], columns: ["id", "email", "country"])
        #expect(mapping == [CSVColumnMapping(sourceIndex: 1, column: "id"), CSVColumnMapping(sourceIndex: 3, column: "email")])
        #expect(CSVImportMapping.byPosition(sourceCount: 2, columns: ["a", "b", "c"]) == [CSVColumnMapping(sourceIndex: 0, column: "a"), CSVColumnMapping(sourceIndex: 1, column: "b")])
    }

    @Test func mappingProblems() {
        let columns = [ColumnInfo(name: "id", dataType: "int"), ColumnInfo(name: "total", dataType: "int", extra: "STORED GENERATED")]
        #expect(CSVImportMapping.problem(with: [], columns: columns) != nil)
        #expect(CSVImportMapping.problem(with: [CSVColumnMapping(sourceIndex: 0, column: "id"), CSVColumnMapping(sourceIndex: 1, column: "id")], columns: columns)?.contains("Two fields") == true)
        #expect(CSVImportMapping.problem(with: [CSVColumnMapping(sourceIndex: 0, column: "total")], columns: columns)?.contains("generated") == true)
        #expect(CSVImportMapping.problem(with: [CSVColumnMapping(sourceIndex: 0, column: "id")], columns: columns) == nil)
    }

    @Test func literalsFollowTheOptions() {
        var options = CSVImportOptions()
        let text = ColumnInfo(name: "t", dataType: "varchar(20)")
        let number = ColumnInfo(name: "n", dataType: "int")
        let blob = ColumnInfo(name: "b", dataType: "blob")
        let bit = ColumnInfo(name: "f", dataType: "bit(1)")
        func literal(_ field: CSVField, _ column: ColumnInfo, _ dialect: SQLDialect = .mysql) -> String {
            CSVImporter.literal(field, column: column, options: options, dialect: dialect)
        }
        #expect(literal(CSVField(""), text) == "NULL")
        #expect(literal(CSVField("", quoted: true), text) == "''")
        #expect(literal(CSVField("", quoted: true), number) == "NULL")
        #expect(literal(CSVField("O'Brien \\ x"), text) == "'O''Brien \\\\ x'")
        #expect(literal(CSVField("O'Brien \\ x"), text, .postgresql) == "'O''Brien \\ x'")
        #expect(literal(CSVField("0xDEAD"), blob) == "X'dead'")
        #expect(literal(CSVField("0xDEAD"), text) == "'0xDEAD'")
        #expect(literal(CSVField("true"), number) == "1")
        #expect(literal(CSVField("1"), bit) == "1")
        #expect(literal(CSVField("true"), number, .postgresql) == "'true'")
        options.nullToken = "\\N"
        #expect(literal(CSVField("\\N"), text) == "NULL")
        options.emptyAsNull = false
        #expect(literal(CSVField(""), text) == "''")
        options.trimWhitespace = true
        #expect(literal(CSVField("  x  "), text) == "'x'")
    }
}

@Suite struct ChunkedSplitterTests {
    @Test(arguments: [1, 2, 5, 13, 1000])
    func splitsAcrossChunkBoundaries(chunk: Int) {
        let sql = """
        -- header comment
        CREATE TABLE t (id int, note text);
        INSERT INTO t VALUES (1, 'semi;colon'), (2, 'it''s');

        /* block; comment */
        INSERT INTO t VALUES (3, $$dollar;quoted$$);
        SELECT 1
        """
        var splitter = ChunkedStatementSplitter(family: .postgresql)
        var statements: [SQLFileStatement] = []
        var index = sql.startIndex
        while index < sql.endIndex {
            let end = sql.index(index, offsetBy: chunk, limitedBy: sql.endIndex) ?? sql.endIndex
            splitter.append(String(sql[index..<end]))
            statements += splitter.completeStatements(final: false)
            index = end
        }
        statements += splitter.completeStatements(final: true)
        #expect(statements.map(\.text) == [
            "-- header comment\nCREATE TABLE t (id int, note text)",
            "INSERT INTO t VALUES (1, 'semi;colon'), (2, 'it''s')",
            "/* block; comment */\nINSERT INTO t VALUES (3, $$dollar;quoted$$)",
            "SELECT 1",
        ])
        #expect(statements.map(\.line) == [1, 3, 5, 7])
    }

    @Test func mysqlExecutableCommentsAreStatements() {
        let dump = "/*!40101 SET NAMES utf8mb4 */;\n/* plain comment */;\n/*!50001 CREATE VIEW v AS SELECT 1 */;\nSELECT 2;"
        #expect(SQLStatementSplitter.split(dump, family: .mysql).map(\.text) == ["/*!40101 SET NAMES utf8mb4 */", "/*!50001 CREATE VIEW v AS SELECT 1 */", "SELECT 2"])
        #expect(SQLStatementSplitter.split(dump, family: .postgresql).map(\.text) == ["SELECT 2"])
    }

    @Test func incompleteUTF8Suffixes() {
        let bytes = Array("aé😀".utf8)
        #expect(SQLFileRunner.incompleteUTF8Suffix(bytes).isEmpty)
        #expect(SQLFileRunner.incompleteUTF8Suffix(Array(bytes.dropLast())) == Array(bytes.suffix(4).dropLast()))
        #expect(SQLFileRunner.incompleteUTF8Suffix(Array(bytes.prefix(2))) == [bytes[1]])
    }
}

/// Export and import against a scratch SQLite file, so the whole pipeline runs without servers.
@Suite(.serialized) struct SQLiteTransferTests {
    func makeConnection() throws -> (SQLiteConnection, URL) {
        let url = TestFiles.url("fq-io-\(UUID().uuidString).sqlite")
        let connection = SQLiteConnection(parameters: ConnectionParameters(config: ConnectionConfig(kind: .sqlite, filePath: url.path), password: ""))
        try connection.connect()
        _ = try connection.execute("""
            CREATE TABLE fq_io_people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT, score REAL);
            INSERT INTO fq_io_people VALUES (1, 'Zoë, "Z"', 'line1
            line2', 1.5), (2, 'O''Brien \\ x', NULL, NULL), (3, '', '😀', -2);
            """, rowLimit: nil)
        return (connection, url)
    }

    func rows(_ connection: SQLiteConnection, _ table: String) throws -> [[CellValue]] {
        try connection.execute("SELECT * FROM \(table) ORDER BY id", rowLimit: nil).last?.rows ?? []
    }

    @Test func csvRoundTripKeepsNullsEmptyStringsAndText() throws {
        let (connection, url) = try makeConnection()
        defer { connection.close(); TestFiles.removeDatabase(url) }
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("people.csv")
        var options = TableExportOptions()
        options.format = .csv
        options.fetchSize = 2
        let report = try TableExporter(connection: connection, options: options).export([TableExportItem(table: TableRef(name: "fq_io_people"))], to: .file(file))
        #expect(report.totalRows == 3)
        let text = try TransferFiles.read(file)
        #expect(text.hasPrefix("id,name,note,score\n1,\"Zoë, \"\"Z\"\"\",\"line1\nline2\",1.5\n"))

        _ = try connection.execute("CREATE TABLE fq_io_copy (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT, score REAL)", rowLimit: nil)
        let structure = try connection.structure(of: TableRef(name: "fq_io_copy"))
        let mapping = CSVImportMapping.byName(sources: ["id", "name", "note", "score"], columns: structure.columns.map(\.name))
        var importOptions = CSVImportOptions()
        importOptions.rowsPerInsert = 2
        let result = try CSVImporter(connection: connection, table: TableRef(name: "fq_io_copy"), structure: structure, mapping: mapping, options: importOptions).run(file: file)
        #expect(result.rowsImported == 3)
        #expect(result.failure == nil)
        #expect(try rows(connection, "fq_io_copy") == rows(connection, "fq_io_people"))
    }

    @Test func sqlRoundTripRebuildsTheTable() throws {
        let (connection, url) = try makeConnection()
        defer { connection.close(); TestFiles.removeDatabase(url) }
        let before = try rows(connection, "fq_io_people")
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("people.sql")
        var options = TableExportOptions()
        options.format = .sql
        options.rowsPerInsert = 2
        _ = try TableExporter(connection: connection, options: options).export([TableExportItem(table: TableRef(name: "fq_io_people"))], to: .file(file))
        let sql = try TransferFiles.read(file)
        #expect(sql.contains("DROP TABLE IF EXISTS \"fq_io_people\";"))
        #expect(sql.contains("INSERT INTO \"fq_io_people\" (\"id\", \"name\", \"note\", \"score\") VALUES\n(1, "))

        var runOptions = SQLFileRunOptions()
        runOptions.disableForeignKeyChecks = false
        let report = try SQLFileRunner(connection: connection, options: runOptions).run(file: file)
        #expect(report.failure == nil)
        #expect(report.statementsRun >= 3)
        #expect(try rows(connection, "fq_io_people") == before)
    }

    @Test func importErrorPolicies() throws {
        let (connection, url) = try makeConnection()
        defer { connection.close(); TestFiles.removeDatabase(url) }
        _ = try connection.execute("CREATE TABLE fq_io_strict (id INTEGER PRIMARY KEY, name TEXT NOT NULL)", rowLimit: nil)
        let file = try TransferFiles.write("id,name\n1,a\n2,\n3,c\n1,dup\n4,d\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let table = TableRef(name: "fq_io_strict")
        let structure = try connection.structure(of: table)
        let mapping = CSVImportMapping.byName(sources: ["id", "name"], columns: ["id", "name"])
        func count() throws -> String? { try connection.execute("SELECT COUNT(*) FROM fq_io_strict", rowLimit: nil).last?.rows.first?.first?.textValue }

        var options = CSVImportOptions()
        options.errorPolicy = .stopAndRollBack
        var report = try CSVImporter(connection: connection, table: table, structure: structure, mapping: mapping, options: options).run(file: file)
        #expect(report.rolledBack)
        // The batch failed as a whole; replaying it names the exact row.
        #expect(report.failure?.line == 3)
        #expect(try count() == "0")

        options.errorPolicy = .stopAndKeep
        report = try CSVImporter(connection: connection, table: table, structure: structure, mapping: mapping, options: options).run(file: file)
        #expect(report.failure?.line == 3)
        #expect(report.rowsImported == 1)
        #expect(try count() == "1")

        options.errorPolicy = .skipAndContinue
        options.deleteExistingRows = true
        report = try CSVImporter(connection: connection, table: table, structure: structure, mapping: mapping, options: options).run(file: file)
        #expect(report.rowsImported == 3)
        #expect(report.rowsSkipped == 2)
        #expect(report.issues.map(\.line) == [3, 5])
        #expect(try count() == "3")
    }

    @Test func sqlFileSkipsOrStops() throws {
        let (connection, url) = try makeConnection()
        defer { connection.close(); TestFiles.removeDatabase(url) }
        let file = try TransferFiles.write("""
            CREATE TABLE fq_io_log (id INTEGER PRIMARY KEY);
            INSERT INTO fq_io_log VALUES (1);
            INSERT INTO fq_io_missing VALUES (1);
            INSERT INTO fq_io_log VALUES (2);
            """, name: "fq-io-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try SQLFileRunner.countStatements(in: file, family: .sqlite) == 4)

        var options = SQLFileRunOptions()
        options.errorPolicy = .stopAndRollBack
        var report = try SQLFileRunner(connection: connection, options: options).run(file: file)
        #expect(report.rolledBack)
        #expect(report.failure?.line == 3)
        #expect(try connection.execute("SELECT name FROM sqlite_master WHERE name = 'fq_io_log'", rowLimit: nil).last?.rows.isEmpty == true)

        options.errorPolicy = .skipAndContinue
        report = try SQLFileRunner(connection: connection, options: options).run(file: file)
        #expect(report.statementsRun == 3)
        #expect(report.statementsFailed == 1)
        #expect(report.issues.first?.line == 3)
        #expect(try rows(connection, "fq_io_log") == [[.text("1")], [.text("2")]])
    }

    @Test func cancelledImportRollsBack() throws {
        let (connection, url) = try makeConnection()
        defer { connection.close(); TestFiles.removeDatabase(url) }
        _ = try connection.execute("CREATE TABLE fq_io_many (id INTEGER PRIMARY KEY, name TEXT)", rowLimit: nil)
        let file = try TransferFiles.write("id,name\n" + (1...50).map { "\($0),row \($0)" }.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let table = TableRef(name: "fq_io_many")
        let cancellation = OperationCancellation()
        var options = CSVImportOptions()
        options.rowsPerInsert = 5
        let importer = CSVImporter(connection: connection, table: table, structure: try connection.structure(of: table), mapping: CSVImportMapping.byName(sources: ["id", "name"], columns: ["id", "name"]), options: options, cancellation: cancellation)
        let report = try importer.run(file: file) { progress in
            if progress.rowsImported >= 10 { cancellation.cancel() }
        }
        #expect(report.cancelled)
        #expect(report.rolledBack)
        #expect(try connection.execute("SELECT COUNT(*) FROM fq_io_many", rowLimit: nil).last?.rows.first?.first?.textValue == "0")
    }

    @Test func cancelledSQLFileStopsBetweenStatements() throws {
        let (connection, url) = try makeConnection()
        defer { connection.close(); TestFiles.removeDatabase(url) }
        let file = try TransferFiles.write("CREATE TABLE fq_io_steps (id INTEGER);\n" + (1...20).map { "INSERT INTO fq_io_steps VALUES (\($0));" }.joined(separator: "\n"), name: "fq-io-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: file) }
        let cancellation = OperationCancellation()
        var options = SQLFileRunOptions()
        options.errorPolicy = .stopAndKeep
        let report = try SQLFileRunner(connection: connection, options: options, cancellation: cancellation).run(file: file) { progress in
            if progress.statementsRun >= 5 { cancellation.cancel() }
        }
        #expect(report.cancelled)
        #expect(report.statementsRun == 5)
        #expect(try connection.execute("SELECT COUNT(*) FROM fq_io_steps", rowLimit: nil).last?.rows.first?.first?.textValue == "4")
    }

    @Test func cancelledExportLeavesNothing() throws {
        let (connection, url) = try makeConnection()
        defer { connection.close(); TestFiles.removeDatabase(url) }
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cancellation = OperationCancellation()
        var options = TableExportOptions()
        options.fetchSize = 1
        let exporter = TableExporter(connection: connection, options: options, cancellation: cancellation)
        #expect(throws: DatabaseError.self) {
            _ = try exporter.export([TableExportItem(table: TableRef(name: "fq_io_people"))], to: .file(folder.appendingPathComponent("x.csv"))) { progress in
                if progress.tableRows >= 1 { cancellation.cancel() }
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}

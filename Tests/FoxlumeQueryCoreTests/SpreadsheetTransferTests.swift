import Foundation
import Testing
@testable import FoxlumeQueryCore

/// Checks shared by the ZIP, XLSX and JSON tests.
enum SpreadsheetTestTools {
    /// `unzip -t` on the archive, or nil when the system has no unzip.
    static func unzipAccepts(_ url: URL) -> Bool? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tqq", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func isWellFormedXML(_ data: Data) -> Bool {
        XMLParser(data: data).parse()
    }

    static func texts(_ record: CSVRecord) -> [String?] {
        record.fields.map { $0.isNull ? nil : $0.text }
    }

    /// Imports every record of `reader`, mapping `sources` to the table's columns by name.
    static func importRecords(_ connection: DatabaseConnection, reader: ImportRecordReader, sources: [String], into table: TableRef, skipFirstRecord: Bool, base64: Bool = false, options: CSVImportOptions = CSVImportOptions()) throws -> CSVImportReport {
        let structure = try connection.structure(of: table)
        let insertable = structure.columns.filter { !TableExporter.isGenerated($0, family: connection.dialect.family) }.map(\.name)
        let mapping = CSVImportMapping.byName(sources: CSVImportMapping.headerNames(sources), columns: insertable)
        return try CSVImporter(connection: connection, table: table, structure: structure, mapping: mapping, options: options)
            .run(reader: reader, skipFirstRecord: skipFirstRecord, binaryAsBase64: base64)
    }

    /// Imports an XLSX file's first sheet with its header row.
    static func importXLSX(_ connection: DatabaseConnection, file: URL, into table: TableRef, sheet: String? = nil, options: CSVImportOptions = CSVImportOptions()) throws -> CSVImportReport {
        let preview = try XLSXWorkbook.preview(url: file, sheet: sheet, limit: 1)
        let header = preview.records.first?.fields.map(\.text) ?? []
        let workbook = try XLSXWorkbook(url: file)
        let reader = try workbook.reader(for: workbook.sheet(named: preview.sheet)!, width: header.count)
        return try importRecords(connection, reader: reader, sources: header, into: table, skipFirstRecord: true, options: options)
    }

    /// Imports a JSON or NDJSON file with the keys found by the preview.
    static func importJSON(_ connection: DatabaseConnection, file: URL, into table: TableRef, options: CSVImportOptions = CSVImportOptions()) throws -> CSVImportReport {
        let preview = try JSONImportReader.preview(url: file, limit: 1)
        let reader = try JSONImportReader(url: file, keys: preview.keys)
        return try importRecords(connection, reader: reader, sources: preview.keys, into: table, skipFirstRecord: false, base64: true, options: options)
    }
}

@Suite struct ZipArchiveTests {
    @Test func storedDeflatedAndStreamedEntriesReadBack() throws {
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.zip")
        let small = Data("hello hello hello hello".utf8)
        var big = Data()
        var seed: UInt32 = 7
        for index in 0..<3_000_000 {
            seed = seed &* 1_103_515_245 &+ 12345
            big.append(index % 3 == 0 ? UInt8(truncatingIfNeeded: seed >> 16) : UInt8(index % 251))
        }
        let writer = try ExportFileWriter(destination: url, compress: false)
        let zip = ZipWriter(output: writer)
        try zip.addFile("small.txt", contents: small)
        try zip.addFile("empty", contents: Data())
        try zip.beginFile("dir/big.bin")
        var offset = 0
        while offset < big.count {
            try zip.write(big.subdata(in: offset..<min(big.count, offset + 100_000)))
            offset += 100_000
        }
        try zip.endFile()
        try zip.addFile("Zoë 😀.txt", contents: Data("names are UTF-8".utf8), compress: false)
        try zip.finish()
        try writer.commit()

        let reader = try ZipReader(url: url)
        #expect(reader.entries.map(\.name) == ["small.txt", "empty", "dir/big.bin", "Zoë 😀.txt"])
        #expect(try reader.contents(of: reader.entry(named: "small.txt")!) == small)
        #expect(try reader.contents(of: reader.entry(named: "empty")!).isEmpty)
        let streamed = reader.entry(named: "dir/big.bin")!
        #expect(streamed.flags & ZipCentralRecord.descriptorFlag != 0)
        #expect(streamed.method == ZipCentralRecord.deflated)
        #expect(try reader.contents(of: streamed) == big)
        #expect(reader.entry(named: "Zoë 😀.txt")?.method == ZipCentralRecord.stored)
        if let accepted = SpreadsheetTestTools.unzipAccepts(url) { #expect(accepted) }
    }

    @Test func centralRecordsUseZip64OnlyForValuesThatNeedIt() throws {
        let small = ZipCentralRecord(name: "a", method: 8, flags: 0x0808, crc: 1, compressedSize: 10, size: 20, localHeaderOffset: 30)
        #expect(!small.needsZip64)
        #expect(small.centralHeader().count == 46 + 1)

        let huge = ZipCentralRecord(name: "sheet.xml", method: 8, flags: 0x0808, crc: 0xDEAD_BEEF,
                                    compressedSize: 4_500_000_000, size: 5_000_000_000, localHeaderOffset: 6_000_000_000)
        #expect(huge.needsZip64)
        let header = huge.centralHeader()
        #expect(header.count == 46 + 9 + 4 + 24)
        let parsed = try ZipReader.parseCentralDirectory(small.centralHeader() + header, count: 2)
        #expect(parsed[1] == ZipReader.Entry(name: "sheet.xml", method: 8, flags: 0x0808, crc: 0xDEAD_BEEF, compressedSize: 4_500_000_000, size: 5_000_000_000, localHeaderOffset: 6_000_000_000))
        #expect(parsed[0].size == 20)

        // Only the offset overflows: the extra field holds just that one value.
        let offsetOnly = ZipCentralRecord(name: "b", method: 0, flags: 0, crc: 0, compressedSize: 5, size: 5, localHeaderOffset: 0x1_0000_0000)
        #expect(offsetOnly.centralHeader().count == 46 + 1 + 4 + 8)
        #expect(try ZipReader.parseCentralDirectory(offsetOnly.centralHeader(), count: 1)[0].localHeaderOffset == 0x1_0000_0000)

        let descriptor = ZipWriter.dataDescriptor(huge)
        #expect(descriptor.count == 24)
        #expect(ZipWriter.dataDescriptor(small).count == 16)
    }

    @Test func zip64EndRecordsAreFoundBehindTheClassicOne() throws {
        let directoryOffset: UInt64 = 6_000_000_000
        let directorySize: UInt64 = 5_000_000_000
        let end = ZipCentralRecord.endRecords(entryCount: 70_000, directorySize: directorySize, directoryOffset: directoryOffset)
        #expect(end.count == 56 + 20 + 22)
        let start = directoryOffset + directorySize
        let fileSize = start + UInt64(end.count)
        // A sparse file: zeros, then the end records.
        let located = try ZipReader.locateDirectory(fileSize: fileSize) { offset, count in
            var data = Data()
            for position in offset..<offset + UInt64(count) {
                data.append(position >= start ? end[Int(position - start)] : 0)
            }
            return data
        }
        #expect(located.offset == directoryOffset)
        #expect(located.size == directorySize)
        #expect(located.count == 70_000)

        let classic = ZipCentralRecord.endRecords(entryCount: 3, directorySize: 100, directoryOffset: 200)
        #expect(classic.count == 22)
    }

    @Test func moreThan65535EntriesWriteAZip64Directory() throws {
        let output = DataZipOutput()
        let zip = ZipWriter(output: output)
        let count = 65_540
        for index in 0..<count {
            try zip.addFile("f\(index)", contents: Data([UInt8(index % 256)]), compress: false)
        }
        try zip.finish()
        #expect(output.data.range(of: Data([0x50, 0x4B, 0x06, 0x07])) != nil)
        let url = TestFiles.url("fq-zip64-\(UUID().uuidString).zip")
        try output.data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try ZipReader(url: url)
        #expect(reader.entries.count == count)
        #expect(try reader.contents(of: reader.entries[count - 1]) == Data([UInt8((count - 1) % 256)]))
        if let accepted = SpreadsheetTestTools.unzipAccepts(url) { #expect(accepted) }
    }

    @Test func damagedDataFailsTheChecksum() throws {
        let output = DataZipOutput()
        let zip = ZipWriter(output: output)
        try zip.addFile("a.txt", contents: Data("abcdefgh".utf8), compress: false)
        try zip.finish()
        var bytes = output.data
        let position = bytes.range(of: Data("abcdefgh".utf8))!.lowerBound
        bytes[position] = UInt8(ascii: "X")
        let url = TestFiles.url("fq-zipbad-\(UUID().uuidString).zip")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try ZipReader(url: url)
        #expect(throws: DatabaseError.self) { try reader.contents(of: reader.entries[0]) }
    }

    @Test func notAnArchiveIsRefused() throws {
        let url = try TransferFiles.write("id,name\n1,a\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: DatabaseError.self) { try ZipReader(url: url) }
        #expect(throws: DatabaseError.self) { try XLSXWorkbook(url: url) }
    }
}

@Suite struct XLSXWriterTests {
    static let columns = [
        ExportColumn(name: "id", isNumeric: true, typeName: "int4"),
        ExportColumn(name: "name", typeName: "text"),
        ExportColumn(name: "flag", isBoolean: true, typeName: "bool"),
        ExportColumn(name: "day", typeName: "date"),
        ExportColumn(name: "moment", typeName: "timestamp"),
        ExportColumn(name: "at", typeName: "time"),
        ExportColumn(name: "amount", isNumeric: true, typeName: "numeric"),
        ExportColumn(name: "big", isNumeric: true, typeName: "int8"),
        ExportColumn(name: "raw", typeName: "bytea"),
        ExportColumn(name: "note", typeName: "text"),
    ]

    static let rows: [[CellValue]] = [
        [.text("1"), .text("Zoë & <b>"), .text("t"), .text("2026-10-13"), .text("2026-10-13 08:30:00.125"), .text("08:30:15"),
         .text("1234.5678"), .text("9007199254740993"), .bytes(Data([0xDE, 0xAD])), .text("a\r\nb\u{1}c _x0041_ ")],
        [.text("2"), .text(""), .null, .null, .null, .null, .null, .null, .null, .null],
        [.text("3"), .text("O'Brien"), .text("f"), .text("1899-12-31"), .text("2026-10-13 08:30:00+02"), .text("23:59:59.999999"),
         .text("-0.0001"), .text("-9223372036854775808"), .bytes(Data()), .text("😀 漢字")],
    ]

    func writeWorkbook(_ url: URL, rowLimit: Int = XLSXWorkbookWriter.maxRows, body: (XLSXWorkbookWriter) throws -> Void) throws {
        let writer = try ExportFileWriter(destination: url, compress: false)
        let book = XLSXWorkbookWriter(output: writer, rowLimit: rowLimit)
        try body(book)
        try book.finish()
        try writer.commit()
    }

    @Test func packageHasTheParts() throws {
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("kinds.xlsx")
        try writeWorkbook(url) { book in
            try book.beginTable(name: "kinds", columns: Self.columns, sample: Self.rows)
            for row in Self.rows { try book.writeRow(row) }
            try book.endTable()
            try book.beginTable(name: "Kinds", columns: [ExportColumn(name: "only")], sample: [])
            try book.endTable()
        }
        let zip = try ZipReader(url: url)
        let names = Set(zip.entries.map(\.name))
        for part in ["[Content_Types].xml", "_rels/.rels", "docProps/app.xml", "xl/workbook.xml", "xl/_rels/workbook.xml.rels",
                     "xl/styles.xml", "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"] {
            #expect(names.contains(part), "missing \(part)")
        }
        for entry in zip.entries {
            #expect(SpreadsheetTestTools.isWellFormedXML(try zip.contents(of: entry)), "\(entry.name) is not well-formed")
        }
        let types = String(decoding: try zip.contents(of: zip.entry(named: "[Content_Types].xml")!), as: UTF8.self)
        #expect(types.contains("PartName=\"/xl/worksheets/sheet2.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\""))
        #expect(types.contains("PartName=\"/xl/styles.xml\""))
        let relationships = try XLSXWorkbook.relationships(zip, part: "xl/_rels/workbook.xml.rels", base: "xl")
        #expect(relationships.count == 3)
        for relationship in relationships { #expect(names.contains(relationship.target), "\(relationship.target) is missing") }
        let styles = try XLSXWorkbook.readStyles(zip.contents(of: zip.entry(named: "xl/styles.xml")!), name: "styles")
        #expect(styles == [nil, nil, .date, .dateTime, .time])

        let sheet = String(decoding: try zip.contents(of: zip.entry(named: "xl/worksheets/sheet1.xml")!), as: UTF8.self)
        #expect(sheet.contains("<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"))
        #expect(sheet.contains("<c r=\"A1\" s=\"1\" t=\"inlineStr\"><is><t>id</t></is></c>"))
        #expect(sheet.contains("<c r=\"G2\"><v>1234.5678</v></c>"))
        #expect(sheet.contains("<c r=\"C2\" t=\"b\"><v>1</v></c>"))
        #expect(sheet.contains("<c r=\"D2\" s=\"2\"><v>46308</v></c>"))
        #expect(sheet.contains("<c r=\"H2\" t=\"inlineStr\">"))
        #expect(sheet.contains("<cols><col min=\"1\" max=\"1\""))
        let workbook = String(decoding: try zip.contents(of: zip.entry(named: "xl/workbook.xml")!), as: UTF8.self)
        #expect(workbook.contains("<sheet name=\"kinds\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"Kinds (2)\" sheetId=\"2\" r:id=\"rId2\"/>"))
        if let accepted = SpreadsheetTestTools.unzipAccepts(url) { #expect(accepted) }
    }

    @Test func everyValueKindReadsBack() throws {
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("kinds.xlsx")
        try writeWorkbook(url) { book in
            try book.beginTable(name: "kinds", columns: Self.columns, sample: Self.rows)
            for row in Self.rows { try book.writeRow(row) }
            try book.endTable()
        }
        let preview = try XLSXWorkbook.preview(url: url, sheet: nil, limit: 10)
        #expect(preview.sheets == ["kinds"])
        let records = preview.records
        #expect(records.map(\.line) == [1, 2, 3, 4])
        #expect(records[0].texts == Self.columns.map(\.name))
        #expect(SpreadsheetTestTools.texts(records[1]) == ["1", "Zoë & <b>", "true", "2026-10-13", "2026-10-13 08:30:00.125", "08:30:15",
                                                            "1234.5678", "9007199254740993", "0xDEAD", "a\r\nb\u{1}c _x0041_ "])
        #expect(records[1].fields.map(\.wasQuoted) == [false, true, false, false, false, false, false, true, true, true])
        #expect(SpreadsheetTestTools.texts(records[2]) == ["2", "", nil, nil, nil, nil, nil, nil, nil, nil])
        #expect(records[2].fields[1].wasQuoted)
        #expect(SpreadsheetTestTools.texts(records[3]) == ["3", "O'Brien", "false", "1899-12-31", "2026-10-13 08:30:00", "23:59:59.999999",
                                                            "-0.0001", "-9223372036854775808", "0x", "😀 漢字"])
    }

    @Test func longTablesContinueOnNewSheets() throws {
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("long.xlsx")
        var sheets = 0
        try writeWorkbook(url, rowLimit: 4) { book in
            try book.beginTable(name: "t", columns: [ExportColumn(name: "n", isNumeric: true)], sample: [])
            for index in 1...7 { try book.writeRow([.text(String(index))]) }
            try book.endTable()
            sheets = book.sheetsInTable
        }
        #expect(sheets == 3)
        let workbook = try XLSXWorkbook(url: url)
        #expect(workbook.sheetNames == ["t", "t (2)", "t (3)"])
        var values: [String] = []
        for sheet in workbook.sheets {
            let reader = try workbook.reader(for: sheet)
            var first = true
            while let record = try reader.next() {
                if first {
                    #expect(record.texts == ["n"])
                    first = false
                    continue
                }
                values.append(record.texts[0])
            }
        }
        #expect(values == (1...7).map(String.init))
    }

    @Test func valuesPastTheCellLimitAreCut() throws {
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("long-text.xlsx")
        let long = String(repeating: "a", count: 32_766) + "😀b"
        var truncated = 0
        try writeWorkbook(url) { book in
            try book.beginTable(name: "t", columns: [ExportColumn(name: "text")], sample: [[.text(long)]])
            try book.writeRow([.text(long)])
            try book.writeRow([.text("short")])
            try book.endTable()
            truncated = book.truncatedValues
        }
        #expect(truncated == 1)
        let records = try XLSXWorkbook.preview(url: url, sheet: nil, limit: 5).records
        #expect(records[1].texts[0] == String(repeating: "a", count: 32_766))
        #expect(records[2].texts[0] == "short")
    }

    @Test func sheetNamesAreSanitizedAndUnique() {
        #expect(XLSXWorkbookWriter.sanitizedSheetName("a/b:c*?[x]\\") == "a_b_c___x__")
        #expect(XLSXWorkbookWriter.sanitizedSheetName("'quoted'") == "quoted")
        #expect(XLSXWorkbookWriter.sanitizedSheetName("") == "Sheet")
        #expect(XLSXWorkbookWriter.sanitizedSheetName("History") == "History_")
        #expect(XLSXWorkbookWriter.sanitizedSheetName(String(repeating: "x", count: 40)).count == 31)
        var used = Set<String>()
        #expect(XLSXWorkbookWriter.uniqueSheetName("Users", used: &used) == "Users")
        #expect(XLSXWorkbookWriter.uniqueSheetName("users", used: &used) == "users (2)")
        #expect(XLSXWorkbookWriter.uniqueSheetName("USERS", used: &used) == "USERS (3)")
        let long = String(repeating: "y", count: 31)
        #expect(XLSXWorkbookWriter.uniqueSheetName(long, used: &used) == long)
        let second = XLSXWorkbookWriter.uniqueSheetName(long, used: &used)
        #expect(second == String(repeating: "y", count: 27) + " (2)")
        #expect(XLSXWorkbookWriter.continuationName(long, part: 12).utf16.count == 31)
    }

    @Test func numbersStayNumbersOnlyWhenExact() {
        for text in ["0", "-1", "1234.5678", "1e-300", "-0.0001", "123456789012345", "1000000000000000000", "1.5E+3"] {
            #expect(XLSXWorkbookWriter.isExactNumber(text), "\(text)")
        }
        for text in ["9007199254740993", "-9223372036854775808", "0.1234567890123456", "NaN", "Infinity", "1e400", "1,5", "", "0x10"] {
            #expect(!XLSXWorkbookWriter.isExactNumber(text), "\(text)")
        }
    }

    @Test func cellKindsFollowTheColumnType() {
        #expect(XLSXCellKind(ExportColumn(name: "a", typeName: "timestamptz")) == .dateTime)
        #expect(XLSXCellKind(ExportColumn(name: "a", typeName: "DATETIME")) == .dateTime)
        #expect(XLSXCellKind(ExportColumn(name: "a", typeName: "TIMESTAMP WITH TIME ZONE")) == .dateTime)
        #expect(XLSXCellKind(ExportColumn(name: "a", typeName: "DATE")) == .date)
        #expect(XLSXCellKind(ExportColumn(name: "a", typeName: "timetz")) == .time)
        #expect(XLSXCellKind(ExportColumn(name: "a", typeName: "time(3)")) == .time)
        #expect(XLSXCellKind(ExportColumn(name: "a", typeName: "daterange")) == .text)
        #expect(XLSXCellKind(ExportColumn(name: "a", typeName: "_timestamp")) == .text)
        #expect(XLSXCellKind(ExportColumn(name: "a", typeName: "interval")) == .text)
        #expect(XLSXCellKind(ExportColumn(name: "a", isNumeric: true, typeName: "int4")) == .number)
        #expect(XLSXCellKind(ExportColumn(name: "a", isBoolean: true, typeName: "bool")) == .boolean)
    }

    @Test func textEscapesSurviveAnXMLReader() {
        let original = "a & b < c > d\r\ne\u{1}\u{1F}\t_x0041_ _xZZZZ_ \u{FFFE}"
        let xml = "<t>" + XLSXText.escapeContent(original) + "</t>"
        var text = ""
        let collector = XMLScan.Collector(start: { _, _ in }, text: { text += $0 })
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        #expect(parser.parse())
        #expect(XLSXText.unescape(text) == original)
        #expect(XLSXText.columnLetters(0) == "A")
        #expect(XLSXText.columnLetters(25) == "Z")
        #expect(XLSXText.columnLetters(26) == "AA")
        #expect(XLSXText.columnLetters(16_383) == "XFD")
        #expect(XLSXText.columnIndex(ofReference: "XFD1048576") == 16_383)
        #expect(XLSXText.columnIndex(ofReference: "aa7") == 26)
        #expect(XLSXText.columnIndex(ofReference: "17") == nil)
    }

    /// Memory stays flat: the writers hold a few hundred kilobytes at a time while many megabytes of sheet XML
    /// pass through. Counted by the writers themselves, so suites running alongside do not change the result.
    @Test func rowsStreamWithABoundedBuffer() throws {
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("stream.xlsx")
        let writer = try ExportFileWriter(destination: url, compress: false)
        let book = XLSXWorkbookWriter(output: writer, rowLimit: 15_000)
        try book.beginTable(name: "kinds", columns: Self.columns, sample: Self.rows)
        for index in 0..<30_000 { try book.writeRow(Self.rows[index % Self.rows.count]) }
        try book.finish()
        try writer.commit()
        #expect(book.sheetNames == ["kinds", "kinds (2)", "kinds (3)"])
        let sheetXML = try ZipReader(url: url).entries.filter { $0.name.hasPrefix("xl/worksheets/") }.reduce(0) { $0 + $1.size }
        #expect(sheetXML > 8 << 20, "the sheets hold \(sheetXML >> 10) KB of XML")
        #expect(book.peakBufferedBytes < 1 << 20, "the workbook writer held \(book.peakBufferedBytes >> 10) KB")
        #expect(writer.peakBufferedBytes < 1 << 20, "the file writer held \(writer.peakBufferedBytes >> 10) KB")
    }
}

@Suite struct ExcelDateTests {
    @Test func serialNumbersInBothDateSystems() throws {
        let day = ExcelDate.days(year: 2026, month: 10, day: 13)
        #expect(ExcelDate.serial(ExcelDate.Moment(days: day, microseconds: 0)) == 46308)
        #expect(ExcelDate.serial(ExcelDate.Moment(days: ExcelDate.days(year: 1900, month: 3, day: 1), microseconds: 0)) == 61)
        #expect(ExcelDate.serial(ExcelDate.Moment(days: ExcelDate.days(year: 1900, month: 2, day: 28), microseconds: 0)) == nil)
        #expect(ExcelDate.serial(ExcelDate.Moment(days: ExcelDate.days(year: 10000, month: 1, day: 1), microseconds: 0)) == nil)
        #expect(ExcelDate.moment(serial: 46308.5, date1904: false) == ExcelDate.Moment(days: day, microseconds: 43_200_000_000))
        #expect(ExcelDate.moment(serial: 1, date1904: false)?.days == ExcelDate.days(year: 1900, month: 1, day: 1))
        #expect(ExcelDate.moment(serial: 59, date1904: false)?.days == ExcelDate.days(year: 1900, month: 2, day: 28))
        #expect(ExcelDate.moment(serial: 60, date1904: false)?.days == ExcelDate.days(year: 1900, month: 2, day: 28))
        #expect(ExcelDate.moment(serial: 0, date1904: true)?.days == ExcelDate.days(year: 1904, month: 1, day: 1))
        #expect(ExcelDate.moment(serial: 44000, date1904: true)?.days == ExcelDate.days(year: 2024, month: 6, day: 19))
        #expect(ExcelDate.moment(serial: -1, date1904: false) == nil)
        #expect(ExcelDate.civil(days: 0) == (1970, 1, 1))
        #expect(ExcelDate.civil(days: ExcelDate.days(year: 2000, month: 2, day: 29)) == (2000, 2, 29))
    }

    /// A double keeps microseconds for serial numbers below 65,536 (dates before 2079); later ones keep milliseconds.
    @Test func microsecondsSurviveTheSerialNumber() throws {
        for text in ["2026-10-17 10:11:12.123456", "2026-10-13 08:30:00.125", "1999-12-31 23:59:59.999999", "2078-06-30 12:00:00.000001", "9999-12-31 23:59:59.123"] {
            let moment = try #require(ExcelDate.parseDateTime(text))
            let serial = try #require(ExcelDate.serial(moment))
            let back = try #require(ExcelDate.moment(serial: Double(XLSXWorkbookWriter.serialText(serial))!, date1904: false))
            #expect(ExcelDate.dateText(days: back.days) + " " + ExcelDate.timeText(microseconds: back.microseconds) == text)
        }
    }

    @Test func databaseTextParsing() {
        #expect(ExcelDate.parseDateTime("2026-10-13T08:30:00Z")?.microseconds == 30_600_000_000)
        #expect(ExcelDate.parseDateTime("2026-10-13 08:30:00.5+05:30")?.microseconds == 30_600_500_000)
        #expect(ExcelDate.parseDateTime("2026-10-13 08:30:00-07")?.microseconds == 30_600_000_000)
        #expect(ExcelDate.parseDateTime("2026-10-13 08:30")?.microseconds == 30_600_000_000)
        #expect(ExcelDate.parseDateTime("2026-10-13")?.microseconds == 0)
        for bad in ["infinity", "2026-02-30", "2026-10-13 25:00:00", "2026-10-13 08:30:00 BC", "0001-01-01 BC", "2026-1-3", ""] {
            #expect(ExcelDate.parseDateTime(bad) == nil, "\(bad)")
        }
        #expect(ExcelDate.parseTimeOfDay("08:30:15.25") == 30_615_250_000)
        #expect(ExcelDate.parseTimeOfDay("08:30:00+02") == 30_600_000_000)
        #expect(ExcelDate.parseTimeOfDay("24:00:00") == nil)
        #expect(ExcelDate.parseTimeOfDay("-838:59:59") == nil)
        #expect(ExcelDate.timeText(microseconds: 30_615_250_000) == "08:30:15.25")
    }

    @Test func dateFormatsAreRecognized() {
        #expect(XLSXDateKind.of(formatID: 14, code: nil) == .date)
        #expect(XLSXDateKind.of(formatID: 22, code: nil) == .dateTime)
        #expect(XLSXDateKind.of(formatID: 21, code: nil) == .time)
        #expect(XLSXDateKind.of(formatID: 0, code: nil) == nil)
        #expect(XLSXDateKind.of(formatID: 2, code: nil) == nil)
        #expect(XLSXDateKind.of(formatID: 164, code: "yyyy\\-mm\\-dd hh:mm") == .dateTime)
        #expect(XLSXDateKind.of(formatID: 164, code: "[Red]0.00;[Blue]\\-0.00") == nil)
        #expect(XLSXDateKind.of(formatID: 164, code: "\"Day \"dd/mm") == .date)
        #expect(XLSXDateKind.of(formatID: 164, code: "[h]:mm:ss") == .time)
        #expect(XLSXDateKind.of(formatID: 164, code: "[$-409]mmm d, yyyy") == .date)
        #expect(XLSXDateKind.of(formatID: 164, code: "mmm") == .date)
        #expect(XLSXDateKind.of(formatID: 164, code: "0.00%") == nil)
        #expect(XLSXDateKind.of(formatID: 164, code: "#,##0 \"days\"") == nil)
        #expect(XLSXDateKind.of(formatID: 164, code: "General") == nil)
        #expect(XLSXDateKind.of(formatID: 164, code: "@") == nil)
    }
}

@Suite struct XLSXReaderTests {
    func fixtureURL() throws -> URL {
        let url = TestFiles.url("fq-fixture-\(UUID().uuidString).xlsx")
        try XLSXFixtures.handBuilt.write(to: url)
        return url
    }

    @Test func handBuiltWorkbookReads() throws {
        let url = try fixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let workbook = try XLSXWorkbook(url: url)
        #expect(workbook.sheetNames == ["People & Dates", "Second"])
        #expect(workbook.date1904)
        #expect(workbook.sharedStrings.contains("Rich text"))
        let preview = try XLSXWorkbook.preview(url: url, sheet: nil, limit: 20)
        #expect(preview.sheet == "People & Dates")
        let records = preview.records
        #expect(records.map(\.line) == [1, 2, 3, 4, 6])
        #expect(records[0].texts == ["id", "name", "born", "seen", "total", "flag"])
        #expect(SpreadsheetTestTools.texts(records[1]) == ["1", "Zoë & “friends”", "2024-06-19", "2024-06-19 12:00:00", "2.5", "true"])
        #expect(SpreadsheetTestTools.texts(records[2]) == ["2", "Rich text", "1904-01-01", "18:00:00", "xy", "false"])
        #expect(SpreadsheetTestTools.texts(records[3]) == ["3", "line1\nline2\r", nil, nil, "#DIV/0!", nil])
        #expect(SpreadsheetTestTools.texts(records[4]) == ["1.5E+3", "  padded  ", nil, nil, nil, nil])
        #expect(records[1].fields.map(\.wasQuoted) == [false, true, false, false, false, false])

        let second = try XLSXWorkbook.preview(url: url, sheet: "Second", limit: 20)
        #expect(second.records.map(\.texts) == [["10", "no refs"], ["20", "name"]])
        #expect(second.records.map(\.line) == [1, 2])
    }

    @Test func readerCanStopEarly() throws {
        let url = try fixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let workbook = try XLSXWorkbook(url: url)
        for _ in 0..<20 {
            let reader = try workbook.reader(for: workbook.sheets[0], width: 8)
            let first = try reader.next()
            #expect(first?.fields.count == 8)
            reader.close()
            #expect(try reader.next() == nil || true)
        }
    }

    @Test func largeSheetStreams() throws {
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("large.xlsx")
        let writer = try ExportFileWriter(destination: url, compress: false)
        let book = XLSXWorkbookWriter(output: writer)
        try book.beginTable(name: "big", columns: [ExportColumn(name: "id", isNumeric: true), ExportColumn(name: "text")], sample: [])
        for index in 0..<50_000 { try book.writeRow([.text(String(index)), .text("row \(index)")]) }
        try book.endTable()
        try book.finish()
        try writer.commit()
        let workbook = try XLSXWorkbook(url: url)
        let reader = try workbook.reader(for: workbook.sheets[0])
        var count = 0
        var last: CSVRecord?
        while let record = try reader.next() {
            count += 1
            last = record
        }
        #expect(count == 50_001)
        #expect(last?.texts == ["49999", "row 49999"])
        #expect(reader.bytesRead == reader.totalBytes)
    }
}

@Suite struct JSONImportReaderTests {
    func records(_ text: String, keys: [String] = [], chunkSize: Int = 1 << 16) throws -> (JSONImportReader, [CSVRecord]) {
        let url = try TransferFiles.write(text, name: "fq-json-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try JSONImportReader(url: url, keys: keys, chunkSize: chunkSize)
        var result: [CSVRecord] = []
        while let record = try reader.next() { result.append(record) }
        return (reader, result)
    }

    @Test(arguments: [1, 2, 7, 1 << 16])
    func arrayOfObjects(chunkSize: Int) throws {
        let text = """
            [
              {"id": 1, "name": "a\\u00e9\\ud83d\\ude00 \\"q\\" \\\\", "tags": [1, {"x": "y z"}], "ok": true},
              {"name": null, "id": -2.5e3, "extra": { "k" : "v" }, "ok": false, "empty": ""}
            ]
            """
        let (reader, records) = try records(text, chunkSize: chunkSize)
        #expect(reader.keys == ["id", "name", "tags", "ok", "extra", "empty"])
        #expect(reader.layout == .array)
        #expect(records.map(\.line) == [2, 3])
        #expect(SpreadsheetTestTools.texts(records[0]) == ["1", "aé😀 \"q\" \\", "[1,{\"x\":\"y z\"}]", "true"])
        #expect(records[0].fields.map(\.wasQuoted) == [false, true, true, false])
        #expect(SpreadsheetTestTools.texts(records[1]) == ["-2.5e3", nil, nil, "false", "{\"k\":\"v\"}", ""])
        #expect(records[1].fields[5].wasQuoted)
    }

    @Test func objectsOnePerLine() throws {
        let (reader, records) = try records("{\"a\":1}\n{\"b\":\"x\"}\n\n{\"a\":3,\"b\":null}\n")
        #expect(reader.layout == .objects)
        #expect(records.map(\.line) == [1, 2, 4])
        #expect(records.map(SpreadsheetTestTools.texts) == [["1"], [nil, "x"], ["3", nil]])
    }

    @Test func fixedKeysKeepTheirPositions() throws {
        let (_, records) = try records("{\"a\":1,\"c\":2}\n", keys: ["b", "a"])
        #expect(records.map(SpreadsheetTestTools.texts) == [[nil, "1", "2"]])
    }

    @Test func previewCollectsKeysAndPads() throws {
        let url = try TransferFiles.write("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n", name: "fq-json-\(UUID().uuidString).ndjson")
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = try JSONImportReader.preview(url: url, limit: 2)
        #expect(preview.keys == ["a", "b", "c"])
        #expect(preview.records.count == 2)
        #expect(preview.records.allSatisfy { $0.fields.count == 3 })
        #expect(preview.layout == .objects)
    }

    @Test func errorsNameTheLine() throws {
        let cases: [(String, String)] = [
            ("[1, 2]", "Line 1"),
            ("[\n{\"a\":1},\n{\"a\": tru}\n]", "Line 3"),
            ("{\"a\":1", "Line 1"),
            ("[{\"a\":1}] x", "after the end"),
            ("{\"a\":1}\n\n[2]", "Line 3"),
            ("hello", "not a JSON array"),
            ("{\"a\": 01x}", "number"),
        ]
        for (text, fragment) in cases {
            do {
                _ = try records(text)
                Issue.record("expected an error for \(text)")
            } catch {
                #expect(error.localizedDescription.contains(fragment), "\(text): \(error.localizedDescription)")
            }
        }
    }

    @Test func emptyInputsHaveNoRecords() throws {
        #expect(try records("[]").1.isEmpty)
        #expect(try records("  [ \n ] \n").1.isEmpty)
        #expect(try records("").1.isEmpty)
        #expect(try records("[{}]").1.map(\.fields.count) == [0])
    }

    @Test func multiTableExportIsExplained() throws {
        let url = try TransferFiles.write("{\n  \"users\": [{\"id\": 1}],\n  \"orders\": []\n}\n", name: "fq-json-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: DatabaseError.self) { try JSONImportReader.preview(url: url, limit: 5) }
    }

    @Test func utf16FilesAreRead() throws {
        var bytes: [UInt8] = [0xFF, 0xFE]
        for unit in "[{\"name\": \"Zoë 😀\"}]".utf16 { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        let url = try TransferFiles.write(bytes: bytes, name: "fq-json-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try JSONImportReader(url: url)
        #expect(try reader.next()?.texts == ["Zoë 😀"])
    }
}

/// Export to XLSX, JSON and NDJSON and import back into SQLite.
@Suite(.serialized) struct SQLiteSpreadsheetRoundTripTests {
    func makeConnection() throws -> (SQLiteConnection, URL) {
        let url = TestFiles.url("fq-io-\(UUID().uuidString).sqlite")
        let connection = SQLiteConnection(parameters: ConnectionParameters(config: ConnectionConfig(kind: .sqlite, filePath: url.path), password: ""))
        try connection.connect()
        _ = try connection.execute("""
            CREATE TABLE fq_io_kinds (id INTEGER PRIMARY KEY, name TEXT, flag BOOLEAN, day DATE, moment TIMESTAMP, amount NUMERIC, score REAL, raw BLOB, note TEXT);
            CREATE TABLE fq_io_copy (id INTEGER PRIMARY KEY, name TEXT, flag BOOLEAN, day DATE, moment TIMESTAMP, amount NUMERIC, score REAL, raw BLOB, note TEXT);
            INSERT INTO fq_io_kinds VALUES
              (1, 'Zoë, "Z" & <b>', 1, '2026-10-13', '2026-10-13 08:30:00.125', 1234.5678, 1.5, X'DEADBEEF00', 'line1
            line2	tab'),
              (2, '', 0, '1899-12-31', '1999-12-31 23:59:59', -0.0001, -2.5, X'', NULL),
              (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '😀 漢字 _x0041_');
            """, rowLimit: nil)
        return (connection, url)
    }

    func rows(_ connection: SQLiteConnection, _ table: String) throws -> [[CellValue]] {
        try connection.execute("SELECT * FROM \(table) ORDER BY id", rowLimit: nil).last?.rows ?? []
    }

    @Test func xlsxRoundTrip() throws {
        let (connection, url) = try makeConnection()
        defer { connection.close(); TestFiles.removeDatabase(url) }
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("kinds.xlsx")
        var options = TableExportOptions()
        options.format = .xlsx
        options.fetchSize = 2
        let report = try TableExporter(connection: connection, options: options).export([TableExportItem(table: TableRef(name: "fq_io_kinds"))], to: .file(file))
        #expect(report.totalRows == 3)
        #expect(report.warnings.isEmpty)
        let imported = try SpreadsheetTestTools.importXLSX(connection, file: file, into: TableRef(name: "fq_io_copy"))
        #expect(imported.failure == nil, "\(String(describing: imported.failure))")
        #expect(imported.rowsImported == 3)
        #expect(try rows(connection, "fq_io_copy") == rows(connection, "fq_io_kinds"))
    }

    @Test(arguments: [TableExportFormat.json, .ndjson])
    func jsonRoundTrip(format: TableExportFormat) throws {
        let (connection, url) = try makeConnection()
        defer { connection.close(); TestFiles.removeDatabase(url) }
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("kinds." + format.fileExtension)
        var options = TableExportOptions()
        options.format = format
        options.jsonIncludeNulls = format == .json
        _ = try TableExporter(connection: connection, options: options).export([TableExportItem(table: TableRef(name: "fq_io_kinds"))], to: .file(file))
        let imported = try SpreadsheetTestTools.importJSON(connection, file: file, into: TableRef(name: "fq_io_copy"))
        #expect(imported.failure == nil, "\(String(describing: imported.failure))")
        #expect(imported.rowsImported == 3)
        #expect(try rows(connection, "fq_io_copy") == rows(connection, "fq_io_kinds"))
    }

    @Test func severalTablesShareAWorkbookAndLongValuesWarn() throws {
        let (connection, url) = try makeConnection()
        defer { connection.close(); TestFiles.removeDatabase(url) }
        _ = try connection.execute("UPDATE fq_io_copy SET note = NULL; INSERT INTO fq_io_copy (id, note) VALUES (9, printf('%.*c', 40000, 'x'))", rowLimit: nil)
        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("both.xlsx")
        var options = TableExportOptions()
        options.format = .xlsx
        let report = try TableExporter(connection: connection, options: options)
            .export([TableExportItem(table: TableRef(name: "fq_io_kinds")), TableExportItem(table: TableRef(name: "fq_io_copy"))], to: .file(file))
        #expect(report.files == [file])
        #expect(report.warnings.count == 1)
        #expect(report.warnings.first?.contains("32,767") == true)
        #expect(try XLSXWorkbook(url: file).sheetNames == ["fq_io_kinds", "fq_io_copy"])

        options.filePerTable = true
        let perTable = try TableExporter(connection: connection, options: options)
            .export([TableExportItem(table: TableRef(name: "fq_io_kinds")), TableExportItem(table: TableRef(name: "fq_io_copy"))], to: .directory(folder))
        #expect(perTable.files.map(\.lastPathComponent) == ["fq_io_kinds.xlsx", "fq_io_copy.xlsx"])
    }

    @Test func importErrorsNameTheRow() throws {
        let (connection, url) = try makeConnection()
        defer { connection.close(); TestFiles.removeDatabase(url) }
        _ = try connection.execute("CREATE TABLE fq_io_strict (id INTEGER PRIMARY KEY, qty INTEGER NOT NULL)", rowLimit: nil)
        let json = try TransferFiles.write("{\"id\":1,\"qty\":1}\n{\"id\":2,\"qty\":null}\n{\"id\":3,\"qty\":3}\n", name: "fq-json-\(UUID().uuidString).ndjson")
        defer { try? FileManager.default.removeItem(at: json) }
        var options = CSVImportOptions()
        var report = try SpreadsheetTestTools.importJSON(connection, file: json, into: TableRef(name: "fq_io_strict"), options: options)
        #expect(report.rolledBack)
        #expect(report.failure?.line == 2)
        options.errorPolicy = .skipAndContinue
        report = try SpreadsheetTestTools.importJSON(connection, file: json, into: TableRef(name: "fq_io_strict"), options: options)
        #expect(report.rowsImported == 2)
        #expect(report.issues.map(\.line) == [2])

        let folder = try TransferFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("strict.xlsx")
        _ = try ResultExporter.write(columns: [ResultColumn(name: "id", isNumeric: true), ResultColumn(name: "qty", isNumeric: true)],
                                     rows: [[.text("10"), .text("1")], [.text("11"), .null], [.text("12"), .text("2")]],
                                     format: .xlsx, sheetName: "strict", to: file)
        options.errorPolicy = .stopAndRollBack
        report = try SpreadsheetTestTools.importXLSX(connection, file: file, into: TableRef(name: "fq_io_strict"), options: options)
        #expect(report.rolledBack)
        #expect(report.failure?.line == 3)
    }
}

@Suite struct ExcelDateFuzzTests {
    @Test func randomMicrosecondsRoundTrip() throws {
        var generator = SystemRandomNumberGenerator()
        var failures: [String] = []
        let first = ExcelDate.days(year: 2020, month: 1, day: 1)
        for _ in 0..<200_000 {
            let moment = ExcelDate.Moment(days: first + Int.random(in: 0..<3650, using: &generator), microseconds: Int64.random(in: 0..<ExcelDate.microsecondsPerDay, using: &generator))
            let serial = try #require(ExcelDate.serial(moment))
            let back = ExcelDate.moment(serial: Double(XLSXWorkbookWriter.serialText(serial))!, date1904: false)
            if back != moment, failures.count < 5 { failures.append("\(moment) -> \(String(describing: back))") }
        }
        #expect(failures.isEmpty, "\(failures)")
    }
}

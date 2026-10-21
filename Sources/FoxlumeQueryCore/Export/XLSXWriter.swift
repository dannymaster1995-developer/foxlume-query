import Foundation

/// How a column's values go into cells.
enum XLSXCellKind: Equatable {
    case text
    case number
    case boolean
    case date
    case dateTime
    case time

    init(_ column: ExportColumn) {
        if column.isBoolean {
            self = .boolean
            return
        }
        if column.isNumeric {
            self = .number
            return
        }
        var type = column.typeName.lowercased()
        if let paren = type.firstIndex(of: "(") { type = String(type[..<paren]) }
        type = type.trimmingCharacters(in: .whitespaces)
        if type.hasSuffix("[]") || type.hasPrefix("_") {
            self = .text
        } else if type.hasPrefix("timestamp") || type.hasPrefix("datetime") || type == "smalldatetime" {
            self = .dateTime
        } else if type == "date" {
            self = .date
        } else if type == "time" || type == "timetz" || type.hasPrefix("time with") || type.hasPrefix("time without") {
            self = .time
        } else {
            self = .text
        }
    }
}

/// Streams an Excel workbook (Office Open XML, `.xlsx`) into an `ExportFileWriter`: one or more worksheets
/// per table, written row by row and deflated on the fly, so memory stays flat however many rows there are.
/// Each sheet starts with a bold, frozen header row; numbers, booleans and dates become typed cells, NULL
/// an empty cell, and other values inline strings.
final class XLSXWorkbookWriter {
    /// Excel's limits: rows per sheet, columns per sheet, characters per cell.
    static let maxRows = 1_048_576
    static let maxColumns = 16_384
    static let maxCellCharacters = 32_767

    private enum Style {
        static let header = 1
        static let date = 2
        static let dateTime = 3
        static let time = 4
    }

    private let zip: ZipWriter
    private var sheets: [(name: String, path: String)] = []
    private var usedNames = Set<String>()
    private var buffer = ""
    private let bufferLimit = 1 << 18
    private var finished = false

    private struct Table {
        var baseName: String
        var columns: [ExportColumn]
        var kinds: [XLSXCellKind]
        var widths: [Double]
        var references: [String]
        var sheetCount = 0
        var rowInSheet = 0
    }

    private var table: Table?
    private var lastTable: Table?
    /// Values cut to Excel's cell limit in the current or last table.
    private(set) var truncatedValues = 0
    /// Sheets the current or last table needed (more than one past Excel's row limit).
    var sheetsInTable: Int { (table ?? lastTable)?.sheetCount ?? 0 }
    /// Names of the sheets written so far, in order.
    var sheetNames: [String] { sheets.map(\.name) }

    /// `rowLimit` is Excel's, lowered by tests to exercise the continuation sheets.
    private let rowLimit: Int

    init(output: ZipOutput, date: Date = Date(), rowLimit: Int = XLSXWorkbookWriter.maxRows) {
        zip = ZipWriter(output: output, date: date)
        self.rowLimit = max(2, rowLimit)
    }

    // MARK: Tables

    /// Starts a table. `sample` (usually the first page of rows) sets the column widths.
    func beginTable(name: String, columns: [ExportColumn], sample: [[CellValue]]) throws {
        try endTable()
        let kept = Array(columns.prefix(Self.maxColumns))
        let kinds = kept.map(XLSXCellKind.init)
        table = Table(
            baseName: Self.sanitizedSheetName(name),
            columns: kept,
            kinds: kinds,
            widths: Self.columnWidths(columns: kept, kinds: kinds, sample: sample),
            references: kept.indices.map(XLSXText.columnLetters)
        )
        truncatedValues = 0
        try startSheet()
    }

    func writeRow(_ row: [CellValue]) throws {
        guard var current = table else { throw DatabaseError.unsupported("No worksheet is open.") }
        if current.rowInSheet >= rowLimit {
            try closeSheet()
            try startSheet()
            current = table ?? current
        }
        let number = current.rowInSheet + 1
        var line = "<row r=\"\(number)\">"
        for index in current.columns.indices {
            let value = index < row.count ? row[index] : .null
            line += cell(value, kind: current.kinds[index], reference: current.references[index] + String(number))
        }
        line += "</row>"
        table?.rowInSheet = number
        try append(line)
    }

    /// Closes the table's last sheet.
    func endTable() throws {
        guard table != nil else { return }
        try closeSheet()
        lastTable = table
        table = nil
    }

    private func startSheet() throws {
        guard var current = table else { return }
        current.sheetCount += 1
        let name = Self.uniqueSheetName(current.sheetCount == 1 ? current.baseName : Self.continuationName(current.baseName, part: current.sheetCount), used: &usedNames)
        let path = "xl/worksheets/sheet\(sheets.count + 1).xml"
        sheets.append((name, path))
        try zip.beginFile(path)
        var head = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            """
        head += "<sheetViews><sheetView workbookViewId=\"0\"\(sheets.count == 1 ? " tabSelected=\"1\"" : "")>"
        head += "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/><selection pane=\"bottomLeft\" activeCell=\"A2\" sqref=\"A2\"/>"
        head += "</sheetView></sheetViews><sheetFormatPr defaultRowHeight=\"15\"/>"
        if !current.columns.isEmpty {
            head += "<cols>"
            for (index, width) in current.widths.enumerated() {
                head += "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(String(format: "%.1f", width))\" customWidth=\"1\"/>"
            }
            head += "</cols>"
        }
        head += "<sheetData>"
        if !current.columns.isEmpty {
            head += "<row r=\"1\">"
            for (index, column) in current.columns.enumerated() {
                head += "<c r=\"\(current.references[index])1\" s=\"\(Style.header)\" t=\"inlineStr\"><is>\(inlineText(column.name, count: false))</is></c>"
            }
            head += "</row>"
        }
        current.rowInSheet = 1
        table = current
        try append(head)
    }

    private func closeSheet() throws {
        try append("</sheetData></worksheet>")
        try flush()
        try zip.endFile()
    }

    private func append(_ text: String) throws {
        buffer += text
        if buffer.utf8.count >= bufferLimit { try flush() }
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try zip.write(Data(buffer.utf8))
        buffer.removeAll(keepingCapacity: true)
    }

    // MARK: Cells

    private func cell(_ value: CellValue, kind: XLSXCellKind, reference: String) -> String {
        if value.isAbsent { return "" }
        if case .bytes(let data) = value {
            return stringCell("0x" + data.hexString.uppercased(), reference: reference)
        }
        let text = value.textValue ?? ""
        switch kind {
        case .number:
            if Self.isExactNumber(text) { return "<c r=\"\(reference)\"><v>\(text)</v></c>" }
        case .boolean:
            switch text.lowercased() {
            case "t", "true", "1": return "<c r=\"\(reference)\" t=\"b\"><v>1</v></c>"
            case "f", "false", "0": return "<c r=\"\(reference)\" t=\"b\"><v>0</v></c>"
            default: break
            }
        case .date, .dateTime:
            if let moment = ExcelDate.parseDateTime(text), let serial = ExcelDate.serial(moment) {
                let style = kind == .date && moment.microseconds == 0 ? Style.date : Style.dateTime
                return "<c r=\"\(reference)\" s=\"\(style)\"><v>\(Self.serialText(serial))</v></c>"
            }
        case .time:
            if let micros = ExcelDate.parseTimeOfDay(text) {
                let serial = Double(micros) / Double(ExcelDate.microsecondsPerDay)
                return "<c r=\"\(reference)\" s=\"\(Style.time)\"><v>\(Self.serialText(serial))</v></c>"
            }
        case .text:
            break
        }
        return stringCell(text, reference: reference)
    }

    private func stringCell(_ text: String, reference: String) -> String {
        "<c r=\"\(reference)\" t=\"inlineStr\"><is>\(inlineText(text, count: true))</is></c>"
    }

    /// `<t>` with the text cut to Excel's cell limit; spaces at either end are kept.
    private func inlineText(_ text: String, count: Bool) -> String {
        var value = text
        if value.utf16.count > Self.maxCellCharacters {
            value = Self.truncated(value, to: Self.maxCellCharacters)
            if count { truncatedValues += 1 }
        }
        let preserve = value.first.map { $0.isWhitespace } == true || value.last.map { $0.isWhitespace } == true
        return (preserve ? "<t xml:space=\"preserve\">" : "<t>") + XLSXText.escapeContent(value) + "</t>"
    }

    /// The longest prefix of whole characters within `limit` UTF-16 units.
    static func truncated(_ text: String, to limit: Int) -> String {
        var units = 0
        var end = text.startIndex
        for index in text.indices {
            let next = text[index].utf16.count
            if units + next > limit { break }
            units += next
            end = text.index(after: index)
        }
        return String(text[..<end])
    }

    /// The shortest text that reads back as the same double.
    static func serialText(_ serial: Double) -> String {
        if serial == serial.rounded() { return String(Int(serial)) }
        return String(serial)
    }

    /// A number Excel keeps exactly: valid as a JSON number, finite as a double and at most 15 significant
    /// digits. Longer numbers (64-bit keys, wide decimals) go in as text so no digit is lost.
    static func isExactNumber(_ text: String) -> Bool {
        guard ResultExporter.isJSONNumber(text), let value = Double(text), value.isFinite else { return false }
        if value != 0, abs(value) < 1e-300 { return false }
        var mantissa = Substring(text)
        if let exponent = mantissa.firstIndex(where: { $0 == "e" || $0 == "E" }) { mantissa = mantissa[..<exponent] }
        var digits = mantissa.filter(\.isNumber)
        while digits.first == "0" { digits.removeFirst() }
        while digits.last == "0" { digits.removeLast() }
        return digits.count <= 15
    }

    // MARK: Names and widths

    /// A valid sheet name: no `[ ] : * ? / \`, no apostrophe at either end, at most 31 characters, not empty
    /// and not Excel's reserved "History".
    static func sanitizedSheetName(_ raw: String) -> String {
        var name = String(raw.unicodeScalars.map { scalar -> Character in
            if "[]:*?/\\".unicodeScalars.contains(scalar) || scalar.value < 0x20 { return "_" }
            return Character(scalar)
        })
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "'").union(.whitespaces))
        name = truncated(name, to: 31)
        if name.isEmpty { name = "Sheet" }
        if name.lowercased() == "history" { name += "_" }
        return name
    }

    static func continuationName(_ base: String, part: Int) -> String {
        let suffix = " (\(part))"
        return truncated(base, to: 31 - suffix.utf16.count) + suffix
    }

    /// `name`, or `name (2)`, `name (3)`… when a sheet already has it (Excel compares without case).
    static func uniqueSheetName(_ name: String, used: inout Set<String>) -> String {
        var candidate = name
        var counter = 2
        while used.contains(candidate.lowercased()) {
            candidate = continuationName(name, part: counter)
            counter += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// Widths in characters from the header and the sampled values, between 6 and 80.
    static func columnWidths(columns: [ExportColumn], kinds: [XLSXCellKind], sample: [[CellValue]]) -> [Double] {
        columns.indices.map { index in
            var longest = columns[index].name.count + 2
            switch kinds[index] {
            case .date: longest = max(longest, 10)
            case .dateTime: longest = max(longest, 19)
            case .time: longest = max(longest, 8)
            case .text, .number, .boolean: break
            }
            for row in sample.prefix(1000) where index < row.count {
                let value = row[index]
                if value.isAbsent { continue }
                let length: Int
                if case .bytes(let data) = value {
                    length = 2 + data.count * 2
                } else {
                    let text = value.textValue ?? ""
                    // The first line is what a cell shows.
                    length = text.utf8.count > 400 ? 80 : (text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first?.count ?? 0)
                }
                if kinds[index] == .date || kinds[index] == .dateTime || kinds[index] == .time { continue }
                longest = max(longest, length)
            }
            return min(80, max(6, Double(longest) * 1.1 + 1))
        }
    }

    // MARK: Package

    /// Writes the workbook, styles and package parts after the sheets. The output is complete afterwards.
    func finish() throws {
        guard !finished else { return }
        try endTable()
        if sheets.isEmpty {
            // A workbook needs at least one sheet.
            try beginTable(name: "Sheet1", columns: [], sample: [])
            try endTable()
        }
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let package = "http://schemas.openxmlformats.org/package/2006/relationships"
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

        var types = header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        types += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        types += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        types += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        for sheet in sheets {
            types += "<Override PartName=\"/\(sheet.path)\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        types += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        types += "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
        types += "</Types>"
        try zip.addFile("[Content_Types].xml", contents: Data(types.utf8))

        var rootRels = header + "<Relationships xmlns=\"\(package)\">"
        rootRels += "<Relationship Id=\"rId1\" Type=\"\(relationships)/officeDocument\" Target=\"xl/workbook.xml\"/>"
        rootRels += "<Relationship Id=\"rId2\" Type=\"\(relationships)/extended-properties\" Target=\"docProps/app.xml\"/>"
        rootRels += "</Relationships>"
        try zip.addFile("_rels/.rels", contents: Data(rootRels.utf8))

        let app = header + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>Foxlume Query</Application></Properties>"
        try zip.addFile("docProps/app.xml", contents: Data(app.utf8))

        var workbook = header + "<workbook xmlns=\"\(main)\" xmlns:r=\"\(relationships)\"><workbookPr/>"
        workbook += "<bookViews><workbookView activeTab=\"0\"/></bookViews><sheets>"
        for (index, sheet) in sheets.enumerated() {
            workbook += "<sheet name=\"\(XLSXText.escapeAttribute(sheet.name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }
        workbook += "</sheets></workbook>"
        try zip.addFile("xl/workbook.xml", contents: Data(workbook.utf8))

        var workbookRels = header + "<Relationships xmlns=\"\(package)\">"
        for (index, sheet) in sheets.enumerated() {
            let target = sheet.path.dropFirst("xl/".count)
            workbookRels += "<Relationship Id=\"rId\(index + 1)\" Type=\"\(relationships)/worksheet\" Target=\"\(target)\"/>"
        }
        workbookRels += "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"\(relationships)/styles\" Target=\"styles.xml\"/>"
        workbookRels += "</Relationships>"
        try zip.addFile("xl/_rels/workbook.xml.rels", contents: Data(workbookRels.utf8))

        try zip.addFile("xl/styles.xml", contents: Data((header + Self.styles).utf8))
        try zip.finish()
        finished = true
    }

    /// Cell formats by index: 0 default, 1 bold header, 2 date, 3 date and time, 4 time.
    static let styles = """
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <numFmts count="3"><numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd"/>\
        <numFmt numFmtId="165" formatCode="yyyy\\-mm\\-dd\\ hh:mm:ss"/><numFmt numFmtId="166" formatCode="hh:mm:ss"/></numFmts>\
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font>\
        <font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="5"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        </styleSheet>
        """
}

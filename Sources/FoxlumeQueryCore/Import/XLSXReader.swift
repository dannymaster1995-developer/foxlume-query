import Foundation

/// How a cell format shows numbers that are dates.
enum XLSXDateKind: Equatable {
    case date
    case dateTime
    case time

    /// The kind for a number format, or nil when it does not show a date or time. Built-in formats go by id;
    /// custom ones by their code, ignoring quoted text, escaped characters and colour or locale brackets.
    static func of(formatID: Int, code: String?) -> XLSXDateKind? {
        switch formatID {
        case 14...17, 27...31, 34...36, 50...58: return .date
        case 18...21, 32, 33, 45...47: return .time
        case 22: return .dateTime
        default: break
        }
        guard let code, formatID >= 164 || formatID == 0 || code != "General" else { return nil }
        let section = code.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        var letters = ""
        var index = section.startIndex
        while index < section.endIndex {
            let character = section[index]
            switch character {
            case "\"":
                index = section[section.index(after: index)...].firstIndex(of: "\"") ?? section.endIndex
            case "\\", "_", "*":
                index = section.index(after: index)
            case "[":
                let close = section[index...].firstIndex(of: "]") ?? section.endIndex
                let inner = section[section.index(after: index)..<close].lowercased()
                // Elapsed time ([h], [mm], [ss]) is a time; colours and locales are not.
                if !inner.isEmpty, inner.allSatisfy({ "hms".contains($0) }) { letters += inner }
                index = close
            default:
                letters += character.lowercased()
            }
            if index < section.endIndex { index = section.index(after: index) }
        }
        if letters.contains("general") { return nil }
        let hasTime = letters.contains("h") || letters.contains("s")
        let hasDate = letters.contains("y") || letters.contains("d") || (letters.contains("m") && !hasTime)
        if hasDate, hasTime { return .dateTime }
        if hasTime { return .time }
        if hasDate { return .date }
        return nil
    }
}

/// An Excel workbook (`.xlsx`) opened for import: its sheets, shared strings, date formats and date system.
public final class XLSXWorkbook {
    public struct Sheet: Hashable, Sendable {
        public var name: String
        /// The worksheet part inside the package.
        var path: String
    }

    public let url: URL
    public let sheets: [Sheet]
    public let date1904: Bool
    let zip: ZipReader
    let sharedStrings: [String]
    /// Date kinds of the cell formats (`s` attribute of a cell), by index.
    let styleKinds: [XLSXDateKind?]

    public init(url: URL) throws {
        self.url = url
        do {
            zip = try ZipReader(url: url)
        } catch {
            throw DatabaseError.unsupported("\(url.lastPathComponent) is not an Excel workbook (.xlsx): \(error.localizedDescription)")
        }
        let rootRelationships = try Self.relationships(zip, part: "_rels/.rels", base: "")
        let workbookPath = rootRelationships.first { $0.type.hasSuffix("/officeDocument") }?.target ?? "xl/workbook.xml"
        guard let workbookEntry = zip.entry(named: workbookPath) else {
            throw DatabaseError.unsupported("\(url.lastPathComponent) has no workbook. Is it an Excel .xlsx file (not .xls or .xlsb)?")
        }
        let base = (workbookPath as NSString).deletingLastPathComponent
        let relationshipsPath = (base.isEmpty ? "" : base + "/") + "_rels/" + (workbookPath as NSString).lastPathComponent + ".rels"
        let workbookRelationships = try Self.relationships(zip, part: relationshipsPath, base: base)
        let targets = Dictionary(workbookRelationships.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var found: [Sheet] = []
        var uses1904 = false
        try XMLScan.parse(try zip.contents(of: workbookEntry), name: workbookPath) { element, attributes in
            switch element {
            case "workbookPr":
                let value = XMLScan.attribute(attributes, "date1904")?.lowercased()
                uses1904 = value == "1" || value == "true"
            case "sheet":
                guard let name = XMLScan.attribute(attributes, "name"), let id = XMLScan.attribute(attributes, "id"),
                      let relationship = targets[id], relationship.type.hasSuffix("/worksheet") else { return }
                found.append(Sheet(name: name, path: relationship.target))
            default:
                break
            }
        }
        guard !found.isEmpty else { throw DatabaseError.unsupported("\(url.lastPathComponent) has no worksheets.") }
        sheets = found
        date1904 = uses1904

        let stylesPath = workbookRelationships.first { $0.type.hasSuffix("/styles") }?.target ?? (base.isEmpty ? "" : base + "/") + "styles.xml"
        let archive = zip
        styleKinds = try archive.entry(named: stylesPath).map { try Self.readStyles(archive.contents(of: $0), name: stylesPath) } ?? []
        let stringsPath = workbookRelationships.first { $0.type.hasSuffix("/sharedStrings") }?.target ?? (base.isEmpty ? "" : base + "/") + "sharedStrings.xml"
        sharedStrings = try archive.entry(named: stringsPath).map { try Self.readSharedStrings(archive.stream(of: $0), name: stringsPath) } ?? []
    }

    public var sheetNames: [String] { sheets.map(\.name) }

    public func sheet(named name: String) -> Sheet? {
        sheets.first { $0.name == name }
    }

    /// A reader over the sheet's non-empty rows. Every record has at least `width` fields.
    public func reader(for sheet: Sheet, width: Int = 0) throws -> XLSXSheetReader {
        guard let entry = zip.entry(named: sheet.path) else {
            throw DatabaseError.unsupported("The sheet \(sheet.name) is missing from \(url.lastPathComponent).")
        }
        return XLSXSheetReader(workbook: self, source: try zip.stream(of: entry), name: sheet.path, width: width)
    }

    /// Sheet names, the chosen sheet (the first when `sheet` is nil or unknown) and its first `limit` records.
    public static func preview(url: URL, sheet: String?, limit: Int) throws -> (sheets: [String], sheet: String, records: [CSVRecord]) {
        let workbook = try XLSXWorkbook(url: url)
        let chosen = sheet.flatMap { workbook.sheet(named: $0) } ?? workbook.sheets[0]
        let reader = try workbook.reader(for: chosen)
        var records: [CSVRecord] = []
        while records.count < limit, let record = try reader.next() { records.append(record) }
        let width = records.map(\.fields.count).max() ?? 0
        records = records.map { record in
            var padded = record
            if padded.fields.count < width { padded.fields += Array(repeating: CSVField.null, count: width - padded.fields.count) }
            return padded
        }
        return (workbook.sheetNames, chosen.name, records)
    }

    // MARK: Parts

    struct Relationship {
        var id: String
        var type: String
        var target: String
    }

    /// Relationships of a part, with targets resolved to package paths.
    static func relationships(_ zip: ZipReader, part: String, base: String) throws -> [Relationship] {
        guard let entry = zip.entry(named: part) else { return [] }
        var result: [Relationship] = []
        try XMLScan.parse(try zip.contents(of: entry), name: part) { element, attributes in
            guard element == "Relationship", let id = attributes["Id"], let type = attributes["Type"], let target = attributes["Target"],
                  attributes["TargetMode"] != "External" else { return }
            result.append(Relationship(id: id, type: type, target: resolve(target, base: base)))
        }
        return result
    }

    /// `target` relative to the folder `base`, or absolute when it starts with a slash.
    static func resolve(_ target: String, base: String) -> String {
        let joined = target.hasPrefix("/") ? String(target.dropFirst()) : (base.isEmpty ? target : base + "/" + target)
        var parts: [Substring] = []
        for part in joined.split(separator: "/") {
            if part == ".." {
                _ = parts.popLast()
            } else if part != "." {
                parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    static func readStyles(_ data: Data, name: String) throws -> [XLSXDateKind?] {
        var formats: [Int: String] = [:]
        var inCellFormats = false
        var pendingIDs: [Int] = []
        try XMLScan.parse(data, name: name, end: { element in
            if element == "cellXfs" { inCellFormats = false }
        }) { element, attributes in
            switch element {
            case "numFmt":
                if let id = attributes["numFmtId"].flatMap({ Int($0) }), let code = attributes["formatCode"] { formats[id] = code }
            case "cellXfs":
                inCellFormats = true
            case "xf" where inCellFormats:
                pendingIDs.append(attributes["numFmtId"].flatMap { Int($0) } ?? 0)
            default:
                break
            }
        }
        // Custom formats may in theory come after the cell formats that use them.
        return pendingIDs.map { XLSXDateKind.of(formatID: $0, code: formats[$0]) }
    }

    static func readSharedStrings(_ source: ZipEntrySource, name: String) throws -> [String] {
        var strings: [String] = []
        var current = ""
        var inText = false
        var phoneticDepth = 0
        let collector = XMLScan.Collector(
            start: { element, _ in
                switch element {
                case "si": current = ""
                case "rPh": phoneticDepth += 1
                case "t": inText = phoneticDepth == 0
                default: break
                }
            },
            end: { element in
                switch element {
                case "si": strings.append(XLSXText.unescape(current))
                case "rPh": phoneticDepth -= 1
                case "t": inText = false
                default: break
                }
            },
            text: { text in
                if inText { current += text }
            }
        )
        let stream = RawSourceInputStream(source)
        try XMLScan.run(XMLParser(stream: stream), collector: collector, stream: stream, name: name)
        return strings
    }
}

/// Reads one worksheet's rows. The XML is parsed on a thread of its own (XMLParser pushes, the importer
/// pulls), a bounded queue between them, so memory stays flat for large sheets. Rows without any value are
/// skipped; record line numbers are the sheet's row numbers.
public final class XLSXSheetReader: ImportRecordReader {
    private let channel: RowChannel
    private let source: ZipEntrySource
    private let width: Int
    private var started = false
    private let thread: Thread

    init(workbook: XLSXWorkbook, source: ZipEntrySource, name: String, width: Int) {
        let channel = RowChannel(totalBytes: source.totalBytes)
        self.channel = channel
        self.source = source
        self.width = width
        let builder = SheetRowBuilder(workbook: workbook, channel: channel, source: source, width: width)
        thread = Thread {
            let stream = RawSourceInputStream(source)
            let parser = XMLParser(stream: stream)
            builder.parser = parser
            do {
                try XMLScan.run(parser, collector: builder.collector, stream: stream, name: name)
                channel.finish(error: nil)
            } catch {
                channel.finish(error: channel.isStopped ? nil : error)
            }
            builder.parser = nil
        }
        thread.stackSize = 1 << 21
        thread.name = "XLSX sheet reader"
    }

    deinit { channel.stop() }

    public var bytesRead: Int64 { channel.bytesRead }
    public var totalBytes: Int64 { channel.totalBytes }

    public func next() throws -> CSVRecord? {
        if !started {
            started = true
            thread.start()
        }
        return try channel.take()
    }

    /// Stops the parsing thread; `next` returns nil afterwards.
    public func close() { channel.stop() }

    public func snippet(_ record: CSVRecord) -> String {
        TransferText.snippet(record.fields.map { $0.isNull ? "" : $0.text }.joined(separator: " | "))
    }
}

/// Turns the parser's callbacks for a worksheet into records.
private final class SheetRowBuilder {
    private let workbook: XLSXWorkbook
    private let channel: RowChannel
    private let source: ZipEntrySource
    private let width: Int
    weak var parser: XMLParser?

    private var rowNumber = 0
    private var cells: [Int: CSVField] = [:]
    private var maxColumn = -1
    private var column = 0
    private var cellType = ""
    private var cellStyle = 0
    private var value = ""
    private var inline = ""
    private var capturing: Capture = .none
    private var phoneticDepth = 0

    private enum Capture {
        case none
        case value
        case inline
    }

    init(workbook: XLSXWorkbook, channel: RowChannel, source: ZipEntrySource, width: Int) {
        self.workbook = workbook
        self.channel = channel
        self.source = source
        self.width = width
    }

    lazy var collector = XMLScan.Collector(
        start: { [unowned self] element, attributes in self.start(element, attributes) },
        end: { [unowned self] element in self.end(element) },
        text: { [unowned self] text in
            switch self.capturing {
            case .none: break
            case .value: self.value += text
            case .inline: self.inline += text
            }
        }
    )

    private func start(_ element: String, _ attributes: [String: String]) {
        switch element {
        case "row":
            rowNumber = attributes["r"].flatMap { Int($0) } ?? rowNumber + 1
            cells.removeAll(keepingCapacity: true)
            maxColumn = -1
            column = -1
        case "c":
            column = attributes["r"].flatMap(XLSXText.columnIndex(ofReference:)) ?? column + 1
            cellType = attributes["t"] ?? ""
            cellStyle = attributes["s"].flatMap { Int($0) } ?? 0
            value = ""
            inline = ""
        case "v":
            capturing = .value
        case "rPh":
            phoneticDepth += 1
        case "t":
            if phoneticDepth == 0 { capturing = .inline }
        default:
            break
        }
    }

    private func end(_ element: String) {
        switch element {
        case "v", "t":
            capturing = .none
        case "rPh":
            phoneticDepth -= 1
        case "c":
            if let field = cellField(), column >= 0, column < XLSXWorkbookWriter.maxColumns {
                cells[column] = field
                maxColumn = max(maxColumn, column)
            }
        case "row":
            guard maxColumn >= 0 else { return }
            var fields = Array(repeating: CSVField.null, count: max(maxColumn + 1, width))
            for (index, field) in cells { fields[index] = field }
            if !channel.put(CSVRecord(fields: fields, line: rowNumber), bytesRead: source.consumedBytes) {
                parser?.abortParsing()
            }
        default:
            break
        }
    }

    /// The cell's value, or nil for an empty cell (no value, or a formula without a cached result).
    private func cellField() -> CSVField? {
        switch cellType {
        case "s":
            guard let index = Int(value.trimmingCharacters(in: .whitespaces)), workbook.sharedStrings.indices.contains(index) else { return nil }
            return CSVField(workbook.sharedStrings[index], quoted: true)
        case "inlineStr":
            return CSVField(XLSXText.unescape(inline), quoted: true)
        case "str", "e":
            return value.isEmpty && cellType == "e" ? nil : CSVField(XLSXText.unescape(value), quoted: true)
        case "b":
            let text = value.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return CSVField(text == "1" || text.lowercased() == "true" ? "true" : "false")
        case "d":
            let text = value.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return CSVField(text.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: ""))
        default:
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if cellStyle < workbook.styleKinds.count, let kind = workbook.styleKinds[cellStyle],
               let serial = Double(text), let moment = ExcelDate.moment(serial: serial, date1904: workbook.date1904) {
                return CSVField(Self.dateText(moment, kind: kind, serial: serial))
            }
            return CSVField(text)
        }
    }

    static func dateText(_ moment: ExcelDate.Moment, kind: XLSXDateKind, serial: Double) -> String {
        switch kind {
        case .time where serial < 1:
            return ExcelDate.timeText(microseconds: moment.microseconds)
        case .date where moment.microseconds == 0:
            return ExcelDate.dateText(days: moment.days)
        case .date, .dateTime, .time:
            return ExcelDate.dateText(days: moment.days) + " " + ExcelDate.timeText(microseconds: moment.microseconds)
        }
    }
}

/// A bounded queue of rows between the parsing thread and the importer.
private final class RowChannel: @unchecked Sendable {
    private let condition = NSCondition()
    private var rows: [CSVRecord] = []
    private var head = 0
    private var done = false
    private var failure: Error?
    private var stopped = false
    private var consumed: Int64 = 0
    private let capacity = 256
    let totalBytes: Int64

    init(totalBytes: Int64) {
        self.totalBytes = totalBytes
    }

    var bytesRead: Int64 {
        condition.lock()
        defer { condition.unlock() }
        return consumed
    }

    var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    /// Waits for room; false when the reader was stopped.
    func put(_ row: CSVRecord, bytesRead: Int64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while rows.count - head >= capacity, !stopped { condition.wait() }
        guard !stopped else { return false }
        rows.append(row)
        consumed = bytesRead
        condition.broadcast()
        return true
    }

    func take() throws -> CSVRecord? {
        condition.lock()
        defer { condition.unlock() }
        while head == rows.count, !done, !stopped { condition.wait() }
        if head < rows.count {
            let row = rows[head]
            head += 1
            if head >= 1024 {
                rows.removeFirst(head)
                head = 0
            }
            condition.broadcast()
            return row
        }
        if let failure, !stopped { throw failure }
        return nil
    }

    func finish(error: Error?) {
        condition.lock()
        done = true
        failure = error
        consumed = totalBytes
        condition.broadcast()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }
}

/// An InputStream over a `RawByteSource`, so XMLParser can parse a ZIP entry as it is inflated.
final class RawSourceInputStream: InputStream {
    private let source: RawByteSource
    private var pending: [UInt8] = []
    private var offset = 0
    private var status: Stream.Status = .notOpen
    /// The error that ended reading, reported instead of the parser's own.
    private(set) var failure: Error?

    init(_ source: RawByteSource) {
        self.source = source
        super.init(data: Data())
    }

    override func open() { status = .open }
    override func close() { status = .closed }
    override var streamStatus: Stream.Status { status }
    override var streamError: Error? { failure }
    override var hasBytesAvailable: Bool { status == .open }
    override var delegate: StreamDelegate? {
        get { nil }
        set {}
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength length: Int) -> Int {
        if offset >= pending.count {
            do {
                guard let chunk = try source.read() else {
                    status = .atEnd
                    return 0
                }
                pending = chunk
                offset = 0
            } catch {
                failure = error
                status = .error
                return -1
            }
        }
        let count = min(length, pending.count - offset)
        pending.withUnsafeBufferPointer { bytes in
            buffer.update(from: bytes.baseAddress! + offset, count: count)
        }
        offset += count
        return count
    }

    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length: UnsafeMutablePointer<Int>) -> Bool { false }
    override func property(forKey key: Stream.PropertyKey) -> Any? { nil }
    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool { false }
    override func schedule(in runLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from runLoop: RunLoop, forMode mode: RunLoop.Mode) {}
}

/// XMLParser with closures, element names without their namespace prefix.
enum XMLScan {
    final class Collector: NSObject, XMLParserDelegate {
        let start: (String, [String: String]) -> Void
        let end: (String) -> Void
        let text: (String) -> Void

        init(start: @escaping (String, [String: String]) -> Void, end: @escaping (String) -> Void = { _ in }, text: @escaping (String) -> Void = { _ in }) {
            self.start = start
            self.end = end
            self.text = text
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
            start(XMLScan.localName(elementName), attributes)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            end(XMLScan.localName(elementName))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text(string)
        }
    }

    static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    /// An attribute by local name, whatever its prefix (`r:id`, `id`).
    static func attribute(_ attributes: [String: String], _ name: String) -> String? {
        if let value = attributes[name] { return value }
        return attributes.first { localName($0.key) == name }?.value
    }

    static func parse(_ data: Data, name: String, end: @escaping (String) -> Void = { _ in }, start: @escaping (String, [String: String]) -> Void) throws {
        try run(XMLParser(data: data), collector: Collector(start: start, end: end), stream: nil, name: name)
    }

    static func run(_ parser: XMLParser, collector: Collector, stream: RawSourceInputStream?, name: String) throws {
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        if let failure = stream?.failure { throw failure }
        guard parsed else {
            if let error = parser.parserError as NSError?, error.code == XMLParser.ErrorCode.delegateAbortedParseError.rawValue {
                throw DatabaseError.cancelled
            }
            throw DatabaseError.unsupported("\(name) in the workbook is not valid XML (line \(parser.lineNumber)): \(parser.parserError?.localizedDescription ?? "unknown error").")
        }
    }
}

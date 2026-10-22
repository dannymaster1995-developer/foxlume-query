import Foundation

/// Options of the Run SQL File sheet. Codable so the last choices can be remembered.
public struct SQLFileRunOptions: Hashable, Sendable, Codable {
    public var encoding: ImportTextEncoding = .automatic
    /// Stop and Roll Back wraps the file in one transaction; the other policies commit statement by statement.
    public var errorPolicy: ImportErrorPolicy = .stopAndRollBack
    /// MySQL, MariaDB and SQLite: switch foreign key checks off while the file runs, and back afterwards.
    public var disableForeignKeyChecks = true

    public init() {}
}

/// One statement of a SQL file and the line it starts on.
public struct SQLFileStatement: Hashable, Sendable {
    public var text: String
    public var line: Int
}

public struct SQLFileProgress: Sendable, Equatable {
    public var statementsRun: Int
    public var statementsFailed: Int
    public var bytesRead: Int64
    public var totalBytes: Int64
}

public struct SQLFileReport: Sendable {
    /// Statements that succeeded.
    public var statementsRun: Int
    public var statementsFailed: Int
    /// Failures that were skipped (at most `CSVImporter.maxIssues`).
    public var issues: [ImportIssue]
    /// The failure that stopped the run, if any.
    public var failure: ImportIssue?
    public var affectedRows: Int
    public var cancelled: Bool
    /// True when the transaction was rolled back.
    public var rolledBack: Bool
    public var elapsed: TimeInterval
}

/// Runs a .sql (or .sql.gz) file statement by statement. The file is read in chunks and split with
/// `SQLStatementSplitter`, so a dump far larger than memory still runs.
public final class SQLFileRunner {
    private let connection: DatabaseConnection
    private let options: SQLFileRunOptions
    private let cancellation: OperationCancellation

    public init(connection: DatabaseConnection, options: SQLFileRunOptions, cancellation: OperationCancellation = OperationCancellation()) {
        self.connection = connection
        self.options = options
        self.cancellation = cancellation
    }

    // MARK: Reading statements

    /// Calls `body` with each statement of the file in order. `body` returns false to stop early.
    public static func forEachStatement(
        in url: URL,
        family: SQLDialect.Family,
        encoding: ImportTextEncoding = .automatic,
        cancellation: OperationCancellation? = nil,
        progress: ((_ bytesRead: Int64, _ totalBytes: Int64) -> Void)? = nil,
        body: (SQLFileStatement) throws -> Bool
    ) throws {
        let source = try TextChunkSource(url: url, encoding: encoding, chunkSize: 1 << 18)
        var splitter = ChunkedStatementSplitter(family: family)
        var directives = ClientDirectiveFilter(family: family)
        var carry: [UInt8] = []
        var appendedSinceSplit = 0
        while let chunk = try source.next() {
            try cancellation?.check()
            let text: String
            switch source.encoding {
            case .isoLatin1, .windows1252, .macRoman:
                text = source.decode(chunk[...]) ?? String(decoding: chunk, as: UTF8.self)
            case .automatic, .utf8, .utf16LittleEndian, .utf16BigEndian:
                var bytes = carry + chunk
                carry = Self.incompleteUTF8Suffix(bytes)
                bytes.removeLast(carry.count)
                guard let decoded = String(bytes: bytes, encoding: .utf8) else {
                    throw DatabaseError.unsupported("The file is not valid \(source.encoding.title) text near line \(splitter.line). Choose another encoding.")
                }
                text = decoded
            }
            splitter.append(directives.filter(text, final: false))
            appendedSinceSplit += text.utf16.count
            // Splitting rescans the pending text, so wait until enough new text arrived to keep the total work linear.
            guard appendedSinceSplit >= splitter.pendingLength / 2 else { continue }
            appendedSinceSplit = 0
            for statement in splitter.completeStatements(final: false) {
                guard try body(statement) else { return }
            }
            progress?(source.bytesRead, source.totalBytes)
        }
        if !carry.isEmpty {
            throw DatabaseError.unsupported("The file ends in the middle of a UTF-8 character.")
        }
        splitter.append(directives.filter("", final: true))
        for statement in splitter.completeStatements(final: true) {
            guard try body(statement) else { return }
        }
        progress?(source.bytesRead, source.totalBytes)
    }

    /// The start of the file as text, for the preview, with the encoding in use and whether it was gzip.
    public static func preview(of url: URL, encoding: ImportTextEncoding = .automatic, maxBytes: Int = 32 << 10) throws -> (text: String, encoding: ImportTextEncoding, isCompressed: Bool) {
        let source = try TextChunkSource(url: url, encoding: encoding, chunkSize: maxBytes)
        var bytes = try source.next() ?? []
        if bytes.count > maxBytes { bytes.removeLast(bytes.count - maxBytes) }
        let text: String
        switch source.encoding {
        case .isoLatin1, .windows1252, .macRoman:
            text = source.decode(bytes[...]) ?? ""
        case .automatic, .utf8, .utf16LittleEndian, .utf16BigEndian:
            bytes.removeLast(incompleteUTF8Suffix(bytes).count)
            text = String(decoding: bytes, as: UTF8.self)
        }
        return (text, source.encoding, source.isCompressed)
    }

    /// Statements in the file, for the progress total. Reads the whole file once.
    public static func countStatements(in url: URL, family: SQLDialect.Family, encoding: ImportTextEncoding = .automatic, cancellation: OperationCancellation? = nil) throws -> Int {
        var count = 0
        try forEachStatement(in: url, family: family, encoding: encoding, cancellation: cancellation) { _ in
            count += 1
            return true
        }
        return count
    }

    /// Bytes at the end of `bytes` that start a UTF-8 sequence the chunk cut short.
    static func incompleteUTF8Suffix(_ bytes: [UInt8]) -> [UInt8] {
        var back = 0
        while back < 3, back < bytes.count, bytes[bytes.count - 1 - back] & 0xC0 == 0x80 { back += 1 }
        guard back < bytes.count else { return [] }
        let lead = bytes[bytes.count - 1 - back]
        let needed = lead >= 0xF0 ? 3 : lead >= 0xE0 ? 2 : lead >= 0xC0 ? 1 : 0
        return needed > back ? Array(bytes.suffix(back + 1)) : []
    }

    // MARK: Running

    public func run(file: URL, progress: @escaping (SQLFileProgress) -> Void = { _ in }) throws -> SQLFileReport {
        let started = Date()
        let family = connection.dialect.family
        let inTransaction = options.errorPolicy == .stopAndRollBack
        var run = 0
        var failed = 0
        var affected = 0
        var issues: [ImportIssue] = []
        var failure: ImportIssue?
        var bytes: (Int64, Int64) = (0, 0)

        func report(cancelled: Bool, rolledBack: Bool) -> SQLFileReport {
            SQLFileReport(statementsRun: run, statementsFailed: failed, issues: issues, failure: failure, affectedRows: affected, cancelled: cancelled, rolledBack: rolledBack, elapsed: Date().timeIntervalSince(started))
        }

        let restoreChecks = try switchForeignKeyChecksOff(family: family)
        defer { restoreChecks() }
        if inTransaction { _ = try connection.execute(connection.dialect.beginStatement, rowLimit: nil) }
        do {
            try Self.forEachStatement(in: file, family: family, encoding: options.encoding, cancellation: cancellation, progress: { bytes = ($0, $1) }) { statement in
                try cancellation.check()
                do {
                    // Statements that return rows keep only a page; a dump has no use for result sets.
                    let rowLimit = SQLStatementSplitter.looksReadOnly(statement.text) ? 1000 : nil
                    let results = try connection.execute(statement.text, rowLimit: rowLimit)
                    run += 1
                    affected += results.compactMap(\.affectedRows).reduce(0, +)
                } catch let error as DatabaseError where CSVImporter.isRowError(error) {
                    try cancellation.check()
                    failed += 1
                    let issue = ImportIssue(line: statement.line, snippet: TransferText.snippet(statement.text), message: TransferText.message(error))
                    if options.errorPolicy == .skipAndContinue {
                        if issues.count < CSVImporter.maxIssues { issues.append(issue) }
                    } else {
                        failure = issue
                        return false
                    }
                }
                progress(SQLFileProgress(statementsRun: run, statementsFailed: failed, bytesRead: bytes.0, totalBytes: bytes.1))
                return true
            }
            progress(SQLFileProgress(statementsRun: run, statementsFailed: failed, bytesRead: bytes.1, totalBytes: bytes.1))
            if inTransaction {
                if failure != nil {
                    _ = try? connection.execute("ROLLBACK", rowLimit: nil)
                    return report(cancelled: false, rolledBack: true)
                }
                _ = try connection.execute("COMMIT", rowLimit: nil)
            }
            return report(cancelled: false, rolledBack: false)
        } catch {
            if inTransaction { _ = try? connection.execute("ROLLBACK", rowLimit: nil) }
            if cancellation.isCancelled { return report(cancelled: true, rolledBack: inTransaction) }
            throw error
        }
    }

    /// Turns foreign key checks off where a session switch exists, and returns how to put them back.
    private func switchForeignKeyChecksOff(family: SQLDialect.Family) throws -> () -> Void {
        guard options.disableForeignKeyChecks else { return {} }
        let connection = self.connection
        switch family {
        case .mysql:
            // The value is kept here rather than in a session variable, which the file itself might overwrite.
            let previous = (try connection.execute("SELECT @@FOREIGN_KEY_CHECKS", rowLimit: 1)).last?.rows.first?.first?.textValue == "0" ? 0 : 1
            _ = try connection.execute("SET FOREIGN_KEY_CHECKS = 0", rowLimit: nil)
            return { _ = try? connection.execute("SET FOREIGN_KEY_CHECKS = \(previous)", rowLimit: nil) }
        case .sqlite:
            // The pragma is ignored inside a transaction, so it runs before BEGIN.
            let wasOn = (try? connection.execute("PRAGMA foreign_keys", rowLimit: 1))?.first?.rows.first?.first?.textValue == "1"
            guard wasOn else { return {} }
            _ = try connection.execute("PRAGMA foreign_keys = OFF", rowLimit: nil)
            return { _ = try? connection.execute("PRAGMA foreign_keys = ON", rowLimit: nil) }
        case .postgresql, .duckdb:
            return {}
        }
    }
}

/// Handles the client commands dump tools write, which servers do not understand, line by line before splitting:
///
/// - MySQL and MariaDB: `DELIMITER ;;` (mysqldump around triggers, routines and events). The line is dropped, and
///   while another delimiter is in force, a line ending with it ends the statement as `;` would. Bodies keep their
///   inner `;`: the splitter keeps BEGIN … END blocks whole, and mysqldump puts trigger bodies in `/*!…*/` comments.
/// - PostgreSQL: psql's `\restrict` and `\unrestrict` (pg_dump 17.6, 16.10 and later, around the whole script).
///
/// Dropped lines become empty lines, so statement line numbers stay those of the file.
struct ClientDirectiveFilter {
    let family: SQLDialect.Family
    private(set) var delimiter = ";"
    /// The last line of the text so far when it has no line break yet.
    private var pendingLine = ""

    init(family: SQLDialect.Family) {
        self.family = family
    }

    mutating func filter(_ text: String, final: Bool) -> String {
        guard family == .mysql || family == .postgresql else { return text }
        var complete = pendingLine + text
        pendingLine = ""
        if !final {
            // Hold back a line cut by the chunk boundary; a directive must be seen whole.
            if let lastBreak = complete.lastIndex(of: "\n") {
                pendingLine = String(complete[complete.index(after: lastBreak)...])
                complete = String(complete[...lastBreak])
            } else {
                pendingLine = complete
                return ""
            }
        }
        let marker = family == .mysql ? "delimiter" : "restrict"
        if delimiter == ";", complete.range(of: marker, options: .caseInsensitive) == nil { return complete }
        var lines = complete.components(separatedBy: "\n")
        for index in lines.indices {
            lines[index] = filterLine(lines[index])
        }
        return lines.joined(separator: "\n")
    }

    private mutating func filterLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        switch family {
        case .mysql:
            if trimmed.count > 10, trimmed.prefix(10).uppercased() == "DELIMITER " {
                let value = trimmed.dropFirst(10).trimmingCharacters(in: .whitespaces)
                if let word = value.split(separator: " ").first, !word.isEmpty {
                    delimiter = String(word)
                    return ""
                }
            }
            guard delimiter != ";" else { return line }
            var end = line.endIndex
            while end > line.startIndex, line[line.index(before: end)].isWhitespace { end = line.index(before: end) }
            let body = line[..<end]
            guard body.hasSuffix(delimiter) else { return line }
            return String(body.dropLast(delimiter.count)) + ";"
        case .postgresql:
            if trimmed == "\\restrict" || trimmed == "\\unrestrict" || trimmed.hasPrefix("\\restrict ") || trimmed.hasPrefix("\\unrestrict ") {
                return ""
            }
            return line
        case .sqlite, .duckdb:
            return line
        }
    }
}

/// Feeds text in pieces to `SQLStatementSplitter` and hands back only statements known to be complete:
/// every statement but the last, and the last once a `;` follows it (or the text has ended).
struct ChunkedStatementSplitter {
    let family: SQLDialect.Family
    private var pending = ""
    /// Line of the first character of `pending`.
    private(set) var line = 1

    init(family: SQLDialect.Family) {
        self.family = family
    }

    var pendingLength: Int { pending.utf16.count }

    mutating func append(_ text: String) {
        pending += text
    }

    mutating func completeStatements(final: Bool) -> [SQLFileStatement] {
        let statements = SQLStatementSplitter.split(pending, family: family)
        guard !statements.isEmpty else {
            if final { pending = "" }
            return []
        }
        let units = Array(pending.utf16)
        var complete = statements
        var consumed = 0
        if final {
            consumed = units.count
        } else {
            let last = statements[statements.count - 1]
            if let semicolon = Self.terminator(after: last.range, in: units) {
                consumed = semicolon + 1
            } else {
                complete.removeLast()
                if let previous = complete.last, let semicolon = Self.terminator(after: previous.range, in: units) {
                    consumed = semicolon + 1
                } else {
                    consumed = complete.last.map { NSMaxRange($0.range) } ?? 0
                }
            }
        }
        var result: [SQLFileStatement] = []
        var lineAt = line
        var scanned = 0
        for statement in complete {
            lineAt += Self.lineBreaks(in: units, from: scanned, to: statement.range.location)
            scanned = statement.range.location
            result.append(SQLFileStatement(text: statement.text, line: lineAt))
        }
        guard consumed > 0 else { return result }
        line = lineAt + Self.lineBreaks(in: units, from: scanned, to: consumed)
        pending = String(decoding: units[consumed...], as: UTF16.self)
        return result
    }

    /// Position of the `;` that ends the statement in `range`, skipping whitespace; nil when none follows yet.
    private static func terminator(after range: NSRange, in units: [UInt16]) -> Int? {
        var index = NSMaxRange(range)
        while index < units.count {
            switch units[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            case 0x3B: return index
            default: return nil
            }
        }
        return nil
    }

    /// Line breaks between two UTF-16 offsets; CRLF counts once.
    private static func lineBreaks(in units: [UInt16], from start: Int, to end: Int) -> Int {
        guard start < end else { return 0 }
        var count = 0
        var index = start
        while index < end {
            if units[index] == 0x0A {
                count += 1
            } else if units[index] == 0x0D {
                count += 1
                if index + 1 < units.count, units[index + 1] == 0x0A { index += 1 }
            }
            index += 1
        }
        return count
    }
}

import Foundation

/// A stop request shared between the UI and a running export or import. The worker checks it between
/// round trips; the UI also cancels the running statement on the session so a long query stops at once.
public final class OperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func check() throws {
        if isCancelled { throw DatabaseError.cancelled }
    }
}

/// What to do when a row or statement fails during an import.
public enum ImportErrorPolicy: String, CaseIterable, Sendable, Identifiable, Codable {
    /// Stop and undo everything (needs the transaction).
    case stopAndRollBack
    /// Stop, keeping what was imported before the failure.
    case stopAndKeep
    /// Record the failure and carry on with the next row or statement.
    case skipAndContinue

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .stopAndRollBack: return "Stop and Roll Back"
        case .stopAndKeep: return "Stop and Keep Imported Rows"
        case .skipAndContinue: return "Skip and Continue"
        }
    }

    public var stops: Bool { self != .skipAndContinue }
}

/// One failed row or statement. `line` is the 1-based line where it starts in the file.
public struct ImportIssue: Hashable, Sendable {
    public var line: Int
    /// The statement or row text, shortened.
    public var snippet: String
    public var message: String

    public init(line: Int, snippet: String, message: String) {
        self.line = line
        self.snippet = snippet
        self.message = message
    }
}

enum TransferText {
    /// At most `limit` characters on one line, for error lists.
    static func snippet(_ text: String, limit: Int = 200) -> String {
        let flat = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }

    /// The message of an error as shown to the user.
    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

extension SQLDialect.Family {
    /// SAVEPOINT support, which lets one failed statement be undone inside a transaction.
    var supportsSavepoints: Bool { self != .duckdb }
}

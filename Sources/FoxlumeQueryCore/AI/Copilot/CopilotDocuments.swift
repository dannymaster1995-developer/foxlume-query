import Foundation

/// A notification to send to the language server.
public struct LSPNotification: Sendable, Equatable {
    public var method: String
    public var params: JSONValue

    public init(method: String, params: JSONValue) {
        self.method = method
        self.params = params
    }
}

/// The query documents the language server has open: one virtual file per query tab (`query-<n>.sql` in a context
/// folder that holds no files), its version and the text last sent. Pure: it says what to send; the service sends it.
public struct CopilotDocuments: Sendable {
    public struct Document: Sendable, Equatable {
        public var uri: String
        public var version: Int
        /// The whole document as the server has it (preamble included).
        public var text: String
    }

    /// How the server wants changes: the whole text, or only the edited range (the default).
    public enum SyncKind: Sendable {
        case full
        case incremental
    }

    public let folder: URL
    public var syncKind: SyncKind = .incremental
    private(set) public var open: [UUID: Document] = [:]
    /// The document the server was last told has the focus.
    private(set) public var focused: String?
    private var nextNumber = 1
    private var numbers: [UUID: Int] = [:]

    public init(folder: URL) {
        self.folder = folder
    }

    public func uri(for key: UUID) -> String? {
        numbers[key].map { folder.appendingPathComponent("query-\($0).sql").absoluteString }
    }

    /// Opens the document of `key` or brings the server's copy up to `text`; then focuses it.
    public mutating func sync(_ key: UUID, text: String) -> [LSPNotification] {
        var messages: [LSPNotification] = []
        if numbers[key] == nil {
            numbers[key] = nextNumber
            nextNumber += 1
        }
        let uri = uri(for: key)!
        if var document = open[key] {
            if document.text != text {
                let change: JSONValue
                switch syncKind {
                case .full:
                    change = ["text": .string(text)]
                case .incremental:
                    let edit = Self.edit(from: document.text, to: text)
                    change = ["range": edit.range.json, "text": .string(edit.text)]
                }
                document.version += 1
                document.text = text
                open[key] = document
                messages.append(LSPNotification(method: "textDocument/didChange", params: [
                    "textDocument": ["uri": .string(uri), "version": JSONValue(document.version)],
                    "contentChanges": [change],
                ]))
            }
        } else {
            open[key] = Document(uri: uri, version: 0, text: text)
            messages.append(LSPNotification(method: "textDocument/didOpen", params: [
                "textDocument": ["uri": .string(uri), "languageId": "sql", "version": 0, "text": .string(text)],
            ]))
        }
        if focused != uri {
            focused = uri
            messages.append(LSPNotification(method: "textDocument/didFocus", params: ["textDocument": ["uri": .string(uri)]]))
        }
        return messages
    }

    /// Closes the document of `key`; nothing when the server does not have it.
    public mutating func close(_ key: UUID) -> [LSPNotification] {
        guard let document = open.removeValue(forKey: key) else { return [] }
        if focused == document.uri { focused = nil }
        return [LSPNotification(method: "textDocument/didClose", params: ["textDocument": ["uri": .string(document.uri)]])]
    }

    public mutating func closeAll() -> [LSPNotification] {
        open.keys.sorted { (numbers[$0] ?? 0) < (numbers[$1] ?? 0) }.flatMap { close($0) }
    }

    /// A new server process knows no documents: they are opened again on their next request. Their file names stay.
    public mutating func serverDidRestart() {
        open = [:]
        focused = nil
    }

    /// The smallest single edit turning `old` into `new`: the range it replaces in `old` and its text. Never splits a
    /// surrogate pair or a `\r\n`.
    public static func edit(from old: String, to new: String) -> (range: LSPRange, text: String) {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        while prefix > 0, isUnsplittable(a, at: prefix) || isUnsplittable(b, at: prefix) { prefix -= 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        while suffix > 0, isUnsplittable(a, at: a.count - suffix) || isUnsplittable(b, at: b.count - suffix) { suffix -= 1 }
        let range = LSPRange(start: LSPText.position(of: prefix, in: old), end: LSPText.position(of: a.count - suffix, in: old))
        let inserted = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        return (range, inserted)
    }

    /// True when a cut before `index` would split a surrogate pair or a `\r\n`.
    private static func isUnsplittable(_ units: [UInt16], at index: Int) -> Bool {
        guard index > 0, index < units.count else { return false }
        if UTF16.isTrailSurrogate(units[index]), UTF16.isLeadSurrogate(units[index - 1]) { return true }
        return units[index - 1] == 13 && units[index] == 10
    }
}

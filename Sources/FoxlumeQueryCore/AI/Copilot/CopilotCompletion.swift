import Foundation

/// One item of a `textDocument/inlineCompletion` answer.
public struct CopilotCompletionItem: Sendable, Equatable {
    public var insertText: String
    /// The document range `insertText` replaces; nil inserts at the caret.
    public var range: LSPRange?
    /// Run with `workspace/executeCommand` once the user accepts the item.
    public var command: LSPCommand?

    public init(insertText: String, range: LSPRange? = nil, command: LSPCommand? = nil) {
        self.insertText = insertText
        self.range = range
        self.command = command
    }

    /// Reads `{items: [...]}` or a bare array; items without text are left out.
    public static func items(from result: JSONValue) -> [CopilotCompletionItem] {
        let list = result["items"]?.array ?? result.array ?? []
        return list.compactMap { item in
            // The specification allows a snippet object as well as a string.
            guard let text = item["insertText"]?.string ?? item["insertText"]?["value"]?.string else { return nil }
            return CopilotCompletionItem(insertText: text, range: LSPRange(item["range"]), command: LSPCommand(item["command"]))
        }
    }
}

public struct LSPCommand: Sendable, Equatable {
    public var command: String
    public var arguments: [JSONValue]?

    public init(command: String, arguments: [JSONValue]? = nil) {
        self.command = command
        self.arguments = arguments
    }

    init?(_ json: JSONValue?) {
        guard let command = json?["command"]?.string else { return nil }
        self.init(command: command, arguments: json?["arguments"]?.array)
    }

    var executeParams: JSONValue {
        var params: [String: JSONValue] = ["command": .string(command)]
        if let arguments { params["arguments"] = .array(arguments) }
        return .object(params)
    }
}

public enum CopilotCompletionMapper {
    /// The grey text for `item` at the editor's caret: what the item adds after what is already typed. The item's range
    /// usually starts at the beginning of the line, so its text repeats what is typed before the caret; that part is
    /// dropped, and so is text the range covers after the caret when the suggestion ends with it. Nil when the item
    /// would change text before the caret, or adds nothing.
    public static func ghostText(for item: CopilotCompletionItem, editorText: String, caret: Int, preamble: CopilotPreamble) -> String? {
        let insert = item.insertText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard let range = item.range else { return insert.isEmpty ? nil : insert }
        guard let start = preamble.editorOffset(of: range.start, in: editorText),
              let end = preamble.editorOffset(of: range.end, in: editorText),
              start <= caret, end >= start
        else { return nil }
        let text = editorText as NSString
        let typed = text.substring(with: NSRange(location: start, length: caret - start))
        guard insert.utf16.count >= typed.utf16.count, insert.hasPrefix(typed) || insert.utf16.starts(with: typed.utf16) else { return nil }
        var ghost = String(decoding: Array(insert.utf16).dropFirst(typed.utf16.count), as: UTF16.self)
        if end > caret {
            let after = text.substring(with: NSRange(location: caret, length: end - caret))
            if ghost.hasSuffix(after) {
                ghost = String(ghost.dropLast(after.count))
            } else if !after.allSatisfy(\.isWhitespace) {
                // The item rewrites text after the caret in a way grey text cannot show.
                return nil
            }
        }
        return ghost.isEmpty ? nil : ghost
    }
}

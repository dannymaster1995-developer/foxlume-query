import Foundation

/// A position in a document as LSP counts it: a zero-based line and a UTF-16 offset in that line.
public struct LSPPosition: Sendable, Hashable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    var json: JSONValue { ["line": JSONValue(line), "character": JSONValue(character)] }

    init?(_ json: JSONValue?) {
        guard let line = json?["line"]?.int, let character = json?["character"]?.int else { return nil }
        self.init(line: line, character: character)
    }
}

public struct LSPRange: Sendable, Hashable {
    public var start: LSPPosition
    public var end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }

    var json: JSONValue { ["start": start.json, "end": end.json] }

    init?(_ json: JSONValue?) {
        guard let start = LSPPosition(json?["start"]), let end = LSPPosition(json?["end"]) else { return nil }
        self.init(start: start, end: end)
    }
}

/// Converts between UTF-16 offsets and LSP positions. Lines end at `\n`, `\r\n` or `\r`, as the LSP specification says.
public enum LSPText {
    public static func position(of offset: Int, in text: String) -> LSPPosition {
        let units = text.utf16
        let target = min(max(0, offset), units.count)
        var line = 0
        var lineStart = 0
        var index = 0
        var iterator = units.makeIterator()
        var previousWasCR = false
        while index < target, let unit = iterator.next() {
            index += 1
            if unit == 10 {
                line += previousWasCR ? 0 : 1
                lineStart = index
                previousWasCR = false
            } else if unit == 13 {
                line += 1
                lineStart = index
                previousWasCR = true
            } else {
                previousWasCR = false
            }
        }
        return LSPPosition(line: line, character: target - lineStart)
    }

    /// The UTF-16 offset of `position`; a character past the end of its line stops at the line's end, a line past the
    /// end of the text at the text's end.
    public static func offset(of position: LSPPosition, in text: String) -> Int {
        let units = Array(text.utf16)
        var line = 0
        var index = 0
        while line < position.line, index < units.count {
            let unit = units[index]
            index += 1
            if unit == 13 {
                if index < units.count, units[index] == 10 { index += 1 }
                line += 1
            } else if unit == 10 {
                line += 1
            }
        }
        guard line == position.line else { return units.count }
        var end = index
        while end < units.count, units[end] != 10, units[end] != 13 { end += 1 }
        return min(index + max(0, position.character), end)
    }
}

/// The schema notes Copilot gets at the top of every query document, as SQL comments: the dialect, then one line per
/// table from the same schema context (and the same Include schema and table limit) as the chat providers. The
/// editor's lines follow, so editor line N is document line N + `lineCount`.
public struct CopilotPreamble: Sendable, Equatable {
    public let text: String
    /// How many lines the preamble adds before the editor's first line.
    public let lineCount: Int

    public init(dialect: String, schema: [AISchemaTable]?) {
        var lines = ["-- Dialect: " + dialect.components(separatedBy: .newlines).joined(separator: " ")]
        if let schema, !schema.isEmpty {
            // One comment line per table, even when a name holds a line break.
            lines += schema.map { table in
                "-- " + AISchemaContext.text(for: [table]).components(separatedBy: .newlines).joined(separator: " ")
            }
        }
        text = lines.map { $0 + "\n" }.joined()
        lineCount = lines.count
    }

    /// The document Copilot sees for `editorText`.
    public func document(for editorText: String) -> String {
        text + editorText
    }

    /// The document position of the editor's UTF-16 `offset`.
    public func documentPosition(ofEditorOffset offset: Int, in editorText: String) -> LSPPosition {
        var position = LSPText.position(of: offset, in: editorText)
        position.line += lineCount
        return position
    }

    /// The editor's UTF-16 offset of a document position; nil inside the preamble.
    public func editorOffset(of position: LSPPosition, in editorText: String) -> Int? {
        guard position.line >= lineCount else { return nil }
        return LSPText.offset(of: LSPPosition(line: position.line - lineCount, character: position.character), in: editorText)
    }
}

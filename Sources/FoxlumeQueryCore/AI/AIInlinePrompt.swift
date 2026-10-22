import Foundation

/// What an inline suggestion source is asked: the editor's text and caret, the dialect and the schema. Each source
/// decides how much of it leaves the Mac (the chat source sends `AIInlinePrompt`'s caps).
public struct InlineSuggestionRequest: Sendable, Equatable {
    public var text: String
    /// UTF-16 offset of the caret in `text`.
    public var caret: Int
    /// The engine's name, such as "PostgreSQL" or "MariaDB".
    public var dialect: String
    /// Nil when Settings › AI › Include schema is off.
    public var schema: [AISchemaTable]?
    /// Asked with the Suggest command rather than after a pause in typing.
    public var manual: Bool
    /// How the editor indents (Tab inserts this many spaces); the language server formats its answer to match.
    public var tabSize: Int
    public var insertSpaces: Bool

    public init(text: String, caret: Int, dialect: String, schema: [AISchemaTable]? = nil, manual: Bool = false,
                tabSize: Int = 4, insertSpaces: Bool = true) {
        self.text = text
        self.caret = caret
        self.dialect = dialect
        self.schema = schema
        self.manual = manual
        self.tabSize = tabSize
        self.insertSpaces = insertSpaces
    }
}

/// The prompt both chat providers get: stable instructions, the dialect and schema, then the editor text around the caret.
public struct AIInlinePrompt: Sendable, Equatable {
    public static let maxCharactersBefore = 2_000
    public static let maxCharactersAfter = 500
    public static let cursorMarker = "<CURSOR>"

    /// The editor text before the caret, at most `maxCharactersBefore` characters.
    public var textBefore: String
    /// The editor text after the caret, at most `maxCharactersAfter` characters.
    public var textAfter: String
    public var dialect: String
    /// Empty when no schema is sent.
    public var schemaText: String

    public init(textBefore: String, textAfter: String, dialect: String, schemaText: String = "") {
        self.textBefore = textBefore
        self.textAfter = textAfter
        self.dialect = dialect
        self.schemaText = schemaText
    }

    /// Cuts the text around the caret to the caps, never inside a surrogate pair.
    public init(request: InlineSuggestionRequest) {
        let text = request.text as NSString
        let caret = min(max(0, request.caret), text.length)
        var start = max(0, caret - Self.maxCharactersBefore)
        if start > 0, start < text.length, CFStringIsSurrogateLowCharacter(text.character(at: start)) { start += 1 }
        var end = min(text.length, caret + Self.maxCharactersAfter)
        if end < text.length, end > caret, CFStringIsSurrogateLowCharacter(text.character(at: end)) { end -= 1 }
        let schema = request.schema.map(AISchemaContext.text(for:)) ?? ""
        self.init(
            textBefore: text.substring(with: NSRange(location: start, length: caret - start)),
            textAfter: text.substring(with: NSRange(location: caret, length: end - caret)),
            dialect: request.dialect,
            schemaText: schema
        )
    }

    /// The same for every request, so providers can cache it.
    public static let instructions = """
        You are an SQL autocomplete engine inside a database client. The user message is the query editor's text \
        with the cursor marked as \(cursorMarker). Reply with only the text to insert at the cursor.
        Rules:
        - Return raw SQL only: no markdown, no backticks, no quotes around the answer, no explanations.
        - Never repeat text that is already before the cursor.
        - If the cursor is in the middle of a word, finish the word without adding a space first.
        - Keep it short: one or two lines.
        - Match the SQL dialect and the style of the existing query (keyword case, indentation, quoting).
        - Use only tables and columns from the schema when one is given.
        - If nothing useful fits, reply with an empty message.
        """

    /// Dialect and schema: stable while the user types in one connection.
    public var contextText: String {
        var text = "SQL dialect: \(dialect)"
        if !schemaText.isEmpty {
            text += "\n\nSchema (table(column type), PK = primary key, FK = foreign key):\n" + schemaText
        }
        return text
    }

    /// The volatile part: the editor text with the cursor marker.
    public var userMessage: String {
        textBefore + Self.cursorMarker + textAfter
    }
}

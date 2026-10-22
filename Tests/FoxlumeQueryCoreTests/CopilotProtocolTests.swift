import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite("LSP framing and JSON-RPC")
struct LSPFramingTests {
    @Test func framesSplitAnywhereAndBatched() throws {
        let first = JSONRPCMessage.request(id: .number(1), method: "initialize", params: ["a": "é😀"]).framed
        let second = JSONRPCMessage.notification(method: "initialized", params: [:]).framed
        let stream = first + second
        // Byte by byte.
        var decoder = LSPFrameDecoder()
        var bodies: [Data] = []
        for byte in stream { bodies += try decoder.append(Data([byte])) }
        #expect(bodies.count == 2)
        #expect(try JSONRPCMessage(body: bodies[0]) == .request(id: .number(1), method: "initialize", params: ["a": "é😀"]))
        // All at once.
        var batch = LSPFrameDecoder()
        #expect(try batch.append(stream).count == 2)
        // Header in two pieces, body in a third.
        var pieces = LSPFrameDecoder()
        #expect(try pieces.append(first.prefix(10)).isEmpty)
        #expect(try pieces.append(first.dropFirst(10).prefix(12)).isEmpty)
        #expect(try pieces.append(first.dropFirst(22)).count == 1)
    }

    @Test func headersAreCaseInsensitiveAndMayHaveContentType() throws {
        let body = Data(#"{"jsonrpc":"2.0","method":"x"}"#.utf8)
        var decoder = LSPFrameDecoder()
        let framed = Data("content-length: \(body.count)\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n".utf8) + body
        #expect(try decoder.append(framed) == [body])
        #expect(LSPFraming.encode(body) == Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body)
    }

    @Test func brokenHeadersThrow() {
        var missing = LSPFrameDecoder()
        #expect(throws: LSPFramingError.missingContentLength) { try missing.append(Data("Content-Type: x\r\n\r\n{}".utf8)) }
        var invalid = LSPFrameDecoder()
        #expect(throws: LSPFramingError.invalidContentLength("ten")) { try invalid.append(Data("Content-Length: ten\r\n\r\n".utf8)) }
        var negative = LSPFrameDecoder()
        #expect(throws: LSPFramingError.invalidContentLength("-1")) { try negative.append(Data("Content-Length: -1\r\n\r\n".utf8)) }
        var endless = LSPFrameDecoder()
        #expect(throws: LSPFramingError.headerTooLong) { try endless.append(Data(repeating: 65, count: 9000)) }
    }

    @Test func messagesParseAndEncode() throws {
        func parse(_ text: String) throws -> JSONRPCMessage { try JSONRPCMessage(body: Data(text.utf8)) }
        #expect(try parse(#"{"jsonrpc":"2.0","id":7,"method":"m","params":{"x":1}}"#) == .request(id: .number(7), method: "m", params: ["x": 1]))
        #expect(try parse(#"{"jsonrpc":"2.0","id":"fake-1","method":"m"}"#) == .request(id: .string("fake-1"), method: "m", params: nil))
        #expect(try parse(#"{"jsonrpc":"2.0","method":"n","params":[1,true,null]}"#) == .notification(method: "n", params: [1, true, nil]))
        #expect(try parse(#"{"jsonrpc":"2.0","id":3,"result":null}"#) == .response(id: .number(3), result: .success(.null)))
        let failure = try parse(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32800,"message":"Request cancelled"}}"#)
        #expect(failure == .response(id: .number(4), result: .failure(JSONRPCError(code: -32800, message: "Request cancelled"))))
        #expect(throws: JSONRPCError.self) { try parse("not json") }
        #expect(throws: JSONRPCError.self) { try parse(#"{"jsonrpc":"2.0"}"#) }
        // Integers stay integers on the wire; booleans stay booleans.
        let encoded = String(decoding: JSONRPCMessage.request(id: .number(12), method: "m", params: ["line": 3, "ok": true, "x": .number(1.5)]).json.encoded(), as: UTF8.self)
        #expect(encoded == #"{"id":12,"jsonrpc":"2.0","method":"m","params":{"line":3,"ok":true,"x":1.5}}"#)
        #expect(try JSONValue.decode(Data("[true,1,0]".utf8)) == [true, 1, 0])
    }

    @Test func cancellationCodesMapToCancelled() {
        #expect(AIProviderError.from(JSONRPCError(code: JSONRPCError.serverCancelled, message: "x")) == .cancelled)
        #expect(AIProviderError.from(JSONRPCError(code: JSONRPCError.requestCancelled, message: "x")) == .cancelled)
        #expect(AIProviderError.from(CopilotInstallError.checksumMismatch("package")).isTransient == false)
    }
}

/// An endpoint wired to a scripted server in memory: what the endpoint writes is decoded and handed to `server`.
private final class Loopback: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = LSPFrameDecoder()
    private var sent: [JSONRPCMessage] = []
    var server: (@Sendable (JSONRPCMessage, Loopback) -> Void)?
    private(set) var endpoint: LSPEndpoint!

    init(timeout: TimeInterval = 5) {
        endpoint = LSPEndpoint(defaultTimeout: timeout) { [weak self] data in
            guard let self else { return false }
            let messages: [JSONRPCMessage] = self.lock.withLock {
                let bodies = (try? self.decoder.append(data)) ?? []
                let parsed = bodies.compactMap { try? JSONRPCMessage(body: $0) }
                self.sent += parsed
                return parsed
            }
            let server = self.lock.withLock { self.server }
            for message in messages { server?(message, self) }
            return true
        }
    }

    var messages: [JSONRPCMessage] { lock.withLock { sent } }

    func reply(_ message: JSONRPCMessage) {
        endpoint.receive(message.framed)
    }

    func methods() -> [String] {
        messages.compactMap {
            switch $0 {
            case .request(_, let method, _), .notification(let method, _): return method
            case .response: return nil
            }
        }
    }
}

@Suite("LSP endpoint")
struct LSPEndpointTests {
    @Test func answersMatchTheirRequestsInAnyOrder() async throws {
        let loop = Loopback()
        let pending = PendingIDs()
        loop.server = { message, loop in
            guard case .request(let id, let method, _) = message else { return }
            pending.add(id, method)
            // Answer both once the second arrives, the second first.
            guard pending.count == 2 else { return }
            for (id, method) in pending.all.reversed() {
                loop.reply(.response(id: id, result: .success(.string(method))))
            }
        }
        async let a = loop.endpoint.request("first")
        async let b = loop.endpoint.request("second")
        let (x, y) = try await (a, b)
        #expect(x == "first")
        #expect(y == "second")
        #expect(loop.endpoint.pendingCount == 0)
    }

    @Test func errorsThrowTheServersError() async {
        let loop = Loopback()
        loop.server = { message, loop in
            guard case .request(let id, _, _) = message else { return }
            loop.reply(.response(id: id, result: .failure(JSONRPCError(code: -32602, message: "bad params"))))
        }
        await #expect(throws: JSONRPCError(code: -32602, message: "bad params")) { try await loop.endpoint.request("x") }
    }

    @Test func timeoutCancelsAtTheServer() async {
        let loop = Loopback()
        await #expect(throws: LSPError.timedOut(method: "slow")) { try await loop.endpoint.request("slow", timeout: 0.1) }
        let cancel = loop.messages.last
        #expect(cancel == .notification(method: "$/cancelRequest", params: ["id": 1]))
        #expect(loop.endpoint.pendingCount == 0)
    }

    @Test func cancellingTheTaskCancelsAtTheServer() async throws {
        let loop = Loopback()
        let task = Task { try await loop.endpoint.request("textDocument/inlineCompletion") }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(loop.methods() == ["textDocument/inlineCompletion", "$/cancelRequest"])
        // A late answer for the cancelled request is ignored.
        loop.reply(.response(id: .number(1), result: .success(.null)))
        #expect(loop.endpoint.pendingCount == 0)
    }

    @Test func serverRequestsAreAnsweredAndUnknownOnesRefused() async throws {
        let loop = Loopback()
        let notes = Recorder()
        loop.endpoint.setHandlers(
            request: { method, params in
                method == "workspace/configuration" ? .success([(params?["items"]?.array?.count).map { JSONValue($0) } ?? .null]) :
                    .failure(JSONRPCError(code: JSONRPCError.methodNotFound, message: method))
            },
            notification: { method, _ in notes.add(method) }
        )
        loop.reply(.request(id: .string("fake-1"), method: "workspace/configuration", params: ["items": [["section": "telemetry"]]]))
        loop.reply(.request(id: .number(9), method: "unknown/thing", params: nil))
        loop.reply(.notification(method: "window/logMessage", params: ["message": "hi"]))
        try await waitFor { loop.messages.count == 2 }
        #expect(loop.messages.contains(.response(id: .string("fake-1"), result: .success([1]))))
        #expect(loop.messages.contains(.response(id: .number(9), result: .failure(JSONRPCError(code: JSONRPCError.methodNotFound, message: "unknown/thing")))))
        #expect(notes.items == ["window/logMessage"])
    }

    @Test func closingFailsWaitingAndLaterRequests() async throws {
        let loop = Loopback()
        let task = Task { try await loop.endpoint.request("waits") }
        try await Task.sleep(nanoseconds: 50_000_000)
        loop.endpoint.close(reason: "The language server exited (code 3)")
        await #expect(throws: LSPError.connectionClosed("The language server exited (code 3)")) { try await task.value }
        await #expect(throws: LSPError.self) { try await loop.endpoint.request("later") }
        #expect(!loop.endpoint.notify("x"))
        // A broken stream closes it too.
        let broken = Loopback()
        broken.endpoint.receive(Data("Content-Length: nope\r\n\r\n".utf8))
        #expect(broken.endpoint.isClosed)
    }
}

final class PendingIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(JSONRPCID, String)] = []
    func add(_ id: JSONRPCID, _ method: String) { lock.withLock { items.append((id, method)) } }
    var count: Int { lock.withLock { items.count } }
    var all: [(JSONRPCID, String)] { lock.withLock { items } }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ item: String) { lock.withLock { stored.append(item) } }
    var items: [String] { lock.withLock { stored } }
}

func waitFor(seconds: Double = 5, _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(await condition(), "timed out waiting")
}

@Suite("Copilot preamble, positions and documents")
struct CopilotDocumentTests {
    private let schema = [
        AISchemaTable(name: "orders", columns: [
            .init(name: "id", type: "integer", isPrimaryKey: true, isNullable: false),
            .init(name: "customer_id", type: "integer", isNullable: false),
            .init(name: "total", type: "numeric"),
        ], foreignKeys: [.init(columns: ["customer_id"], referencedTable: "customers", referencedColumns: ["id"])]),
        AISchemaTable(name: "sales.customers"),
    ]

    @Test func preambleIsSQLCommentsWithTheSchema() {
        let preamble = CopilotPreamble(dialect: "PostgreSQL", schema: schema)
        #expect(preamble.text == """
            -- Dialect: PostgreSQL
            -- orders(id integer PK, customer_id integer NOT NULL, total numeric) FK customer_id -> customers(id)
            -- sales.customers

            """)
        #expect(preamble.lineCount == 3)
        let bare = CopilotPreamble(dialect: "MySQL", schema: nil)
        #expect(bare.text == "-- Dialect: MySQL\n")
        #expect(bare.lineCount == 1)
        // A line break in a name stays inside its comment line.
        let odd = CopilotPreamble(dialect: "SQLite", schema: [AISchemaTable(name: "a\nb")])
        #expect(odd.lineCount == 2)
        #expect(!odd.text.contains("a\nb"))
    }

    @Test func linesAreOffsetBothWays() {
        let preamble = CopilotPreamble(dialect: "PostgreSQL", schema: schema)
        let text = "SELECT *\nFROM ord"
        let caret = (text as NSString).length
        let position = preamble.documentPosition(ofEditorOffset: caret, in: text)
        #expect(position == LSPPosition(line: 4, character: 8))
        #expect(preamble.editorOffset(of: position, in: text) == caret)
        #expect(preamble.editorOffset(of: LSPPosition(line: 3, character: 2), in: text) == 2)
        #expect(preamble.editorOffset(of: LSPPosition(line: 1, character: 0), in: text) == nil, "inside the preamble")
        // The document's line at the position is the editor's line.
        let document = preamble.document(for: text).components(separatedBy: "\n")
        #expect(document[position.line] == "FROM ord")
    }

    @Test func positionsCountUTF16AndEveryLineBreak() {
        let text = "a😀b\r\nc\rd\ne"
        #expect(LSPText.position(of: 3, in: text) == LSPPosition(line: 0, character: 3))
        #expect(LSPText.position(of: 6, in: text) == LSPPosition(line: 1, character: 0))
        #expect(LSPText.position(of: 8, in: text) == LSPPosition(line: 2, character: 0))
        #expect(LSPText.position(of: 10, in: text) == LSPPosition(line: 3, character: 0))
        #expect(LSPText.offset(of: LSPPosition(line: 1, character: 0), in: text) == 6)
        #expect(LSPText.offset(of: LSPPosition(line: 2, character: 1), in: text) == 9)
        #expect(LSPText.offset(of: LSPPosition(line: 0, character: 99), in: text) == 4, "past the end of the line")
        #expect(LSPText.offset(of: LSPPosition(line: 9, character: 0), in: text) == (text as NSString).length)
    }

    private func apply(_ edit: (range: LSPRange, text: String), to text: String) -> String {
        let start = LSPText.offset(of: edit.range.start, in: text)
        let end = LSPText.offset(of: edit.range.end, in: text)
        return (text as NSString).replacingCharacters(in: NSRange(location: start, length: end - start), with: edit.text)
    }

    @Test func incrementalEditsRebuildTheText() {
        let pairs = [
            ("SELECT * FROM ord", "SELECT * FROM orders"),
            ("SELECT * FROM orders", "SELECT * FROM ord"),
            ("SELECT 1\nFROM t", "SELECT 1, 2\nFROM t\nWHERE x"),
            ("", "abc"),
            ("abc", ""),
            ("a😀b", "a😁b"),
            ("x\r\ny", "x\ny"),
            ("same", "same"),
            ("-- Dialect: PostgreSQL\n-- a(id)\nSELECT", "-- Dialect: PostgreSQL\n-- b(id)\n-- a(id)\nSELECT"),
        ]
        for (old, new) in pairs {
            let edit = CopilotDocuments.edit(from: old, to: new)
            #expect(apply(edit, to: old) == new, "\(old) -> \(new)")
        }
        // The smallest edit: only the typed characters.
        let typed = CopilotDocuments.edit(from: "SELECT * FROM ord", to: "SELECT * FROM orders")
        #expect(typed.range == LSPRange(start: LSPPosition(line: 0, character: 17), end: LSPPosition(line: 0, character: 17)))
        #expect(typed.text == "ers")
        // Never half of a surrogate pair.
        let emoji = CopilotDocuments.edit(from: "a😀b", to: "a😁b")
        #expect(emoji.text == "😁")
    }

    @Test func documentsOpenChangeFocusAndClose() {
        let folder = CopilotService.neutralDocumentFolder(id: UUID(uuidString: "6B1E0000-0000-4000-8000-000000000121")!)
        #expect(folder.absoluteString == "file:///foxlume-query/6b1e0000-0000-4000-8000-000000000121/")
        var documents = CopilotDocuments(folder: folder)
        let first = UUID()
        let second = UUID()
        let opened = documents.sync(first, text: "SELECT")
        #expect(opened.map(\.method) == ["textDocument/didOpen", "textDocument/didFocus"])
        #expect(opened[0].params["textDocument"]?["uri"]?.string == "file:///foxlume-query/6b1e0000-0000-4000-8000-000000000121/query-1.sql")
        #expect(opened[0].params["textDocument"]?["languageId"] == "sql")
        #expect(opened[0].params["textDocument"]?["version"] == 0)
        #expect(documents.sync(first, text: "SELECT").isEmpty, "nothing changed")
        let changed = documents.sync(first, text: "SELECT 1")
        #expect(changed.map(\.method) == ["textDocument/didChange"])
        #expect(changed[0].params["textDocument"]?["version"] == 1)
        #expect(changed[0].params["contentChanges"]?.array?.first?["text"] == " 1")
        #expect(changed[0].params["contentChanges"]?.array?.first?["range"] != nil)
        // A second tab is another file; switching back focuses again.
        #expect(documents.sync(second, text: "x").map(\.method) == ["textDocument/didOpen", "textDocument/didFocus"])
        #expect(documents.uri(for: second)?.hasSuffix("query-2.sql") == true)
        #expect(documents.sync(first, text: "SELECT 1").map(\.method) == ["textDocument/didFocus"])
        // Full sync sends the whole text.
        documents.syncKind = .full
        let full = documents.sync(first, text: "SELECT 2")
        #expect(full[0].params["contentChanges"] == [["text": "SELECT 2"]])
        #expect(documents.close(first).map(\.method) == ["textDocument/didClose"])
        #expect(documents.close(first).isEmpty)
        #expect(documents.closeAll().map { $0.params["textDocument"]?["uri"]?.string?.hasSuffix("query-2.sql") } == [true])
        // After a restart the server knows nothing: the same tab opens again under its old name.
        _ = documents.sync(second, text: "y")
        documents.serverDidRestart()
        let reopened = documents.sync(second, text: "y")
        #expect(reopened.first?.method == "textDocument/didOpen")
        #expect(reopened.first?.params["textDocument"]?["uri"]?.string?.hasSuffix("query-2.sql") == true)
    }
}

@Suite("Copilot completion mapping")
struct CopilotCompletionTests {
    private let preamble = CopilotPreamble(dialect: "PostgreSQL", schema: nil)

    private func item(_ text: String, line: Int = 1, from start: Int, to end: Int) -> CopilotCompletionItem {
        CopilotCompletionItem(insertText: text, range: LSPRange(start: LSPPosition(line: line, character: start), end: LSPPosition(line: line, character: end)))
    }

    @Test func typedPartIsStripped() {
        let text = "SELECT * FROM ord"
        let ghost = CopilotCompletionMapper.ghostText(for: item("SELECT * FROM orders o", from: 0, to: 17), editorText: text, caret: 17, preamble: preamble)
        #expect(ghost == "ers o")
        // On a later line, with the range starting mid-line.
        let multi = "SELECT *\nFROM ord"
        let later = CopilotCompletionMapper.ghostText(for: item("ord o\nWHERE o.id = 1", line: 2, from: 5, to: 8), editorText: multi, caret: 17, preamble: preamble)
        #expect(later == " o\nWHERE o.id = 1")
    }

    @Test func textAfterTheCaretTheItemRepeatsIsDropped() {
        let text = "SELECT count(|)".replacingOccurrences(of: "|", with: "")
        let ghost = CopilotCompletionMapper.ghostText(for: item("SELECT count(*)", from: 0, to: 14), editorText: text, caret: 13, preamble: preamble)
        #expect(ghost == "*")
        // Text after the caret the item would rewrite cannot be shown.
        let rewrite = CopilotCompletionMapper.ghostText(for: item("SELECT count(*) AS n", from: 0, to: 14), editorText: "SELECT count(x)", caret: 13, preamble: preamble)
        #expect(rewrite == nil)
    }

    @Test func itemsThatChangeTypedTextOrAddNothingAreSkipped() {
        let text = "SELECT * FROM ord"
        #expect(CopilotCompletionMapper.ghostText(for: item("select * from orders", from: 0, to: 17), editorText: text, caret: 17, preamble: preamble) == nil)
        #expect(CopilotCompletionMapper.ghostText(for: item("SELECT * FROM ord", from: 0, to: 17), editorText: text, caret: 17, preamble: preamble) == nil)
        #expect(CopilotCompletionMapper.ghostText(for: item("x", line: 0, from: 0, to: 1), editorText: text, caret: 17, preamble: preamble) == nil, "in the preamble")
        #expect(CopilotCompletionMapper.ghostText(for: item("SELECT", from: 0, to: 6), editorText: text, caret: 3, preamble: preamble) == nil,
                "a range ending before the caret")
    }

    @Test func noRangeInsertsAtTheCaretAndLineBreaksAreNormalized() {
        let plain = CopilotCompletionItem(insertText: "ers\r\nWHERE 1 = 1")
        #expect(CopilotCompletionMapper.ghostText(for: plain, editorText: "FROM ord", caret: 8, preamble: preamble) == "ers\nWHERE 1 = 1")
    }

    @Test func itemsParseFromAListOrAnArray() {
        let list: JSONValue = ["items": [
            ["insertText": "a", "range": ["start": ["line": 1, "character": 0], "end": ["line": 1, "character": 2]],
             "command": ["command": "github.copilot.didAcceptCompletionItem", "arguments": ["id-1"]]],
            ["insertText": ["kind": "snippet", "value": "b"]],
            ["range": nil],
        ]]
        let items = CopilotCompletionItem.items(from: list)
        #expect(items.count == 2)
        #expect(items[0].command == LSPCommand(command: "github.copilot.didAcceptCompletionItem", arguments: ["id-1"]))
        #expect(items[0].range?.end == LSPPosition(line: 1, character: 2))
        #expect(items[1].insertText == "b")
        #expect(CopilotCompletionItem.items(from: [["insertText": "c"]]).map(\.insertText) == ["c"])
        #expect(CopilotCompletionItem.items(from: .null).isEmpty)
    }
}

@Suite("Copilot settings and policy")
@MainActor
struct CopilotSettingsTests {
    @Test func enablingCopilotAddsAndActivatesIt() throws {
        var settings = AISettings()
        settings.enabled = true
        settings.upsert(AIProviderConfig(name: "Local", kind: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "llama3.1"))
        #expect(!settings.copilotMayRun)
        settings.setCopilotEnabled(true)
        #expect(settings.copilotProvider?.kind == .copilot)
        #expect(settings.activeProvider?.kind == .copilot)
        #expect(settings.copilotMayRun)
        #expect(settings.copilotIsInlineSource)
        settings.setCopilotEnabled(true)
        #expect(settings.providers.filter { $0.kind == .copilot }.count == 1)
        // Another provider for suggestions: Copilot may still run (Settings signs in), but is not the inline source.
        settings.activeProviderID = settings.providers[0].id
        #expect(settings.copilotMayRun)
        #expect(!settings.copilotIsInlineSource)
        settings.activeProviderID = settings.copilotProvider?.id
        settings.inlineSuggestions = false
        #expect(!settings.copilotIsInlineSource)
        settings.enabled = false
        #expect(!settings.copilotMayRun)
        settings.setCopilotEnabled(false)
        #expect(settings.copilotProvider == nil)
        #expect(settings.activeProvider?.name == "Local")
        #expect(!AIProviderKind.chatKinds.contains(.copilot))
        #expect(AIProviderConfig(kind: .copilot).validationMessage == nil)
    }

    @Test func telemetryIsOffByDefaultAndDecodes() throws {
        #expect(AISettings().copilotTelemetry == false)
        let old = try JSONDecoder().decode(AISettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(old.copilotTelemetry == false)
        var settings = AISettings()
        settings.copilotTelemetry = true
        settings.setCopilotEnabled(true)
        let decoded = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.copilotProvider?.kind == .copilot)
    }

    /// The source, and with it any document traffic, exists only once the connection's policy resolves to Allow.
    @Test func copilotSourceOnlyForAllow() {
        var settings = AISettings()
        settings.enabled = true
        settings.setCopilotEnabled(true)
        let service = CopilotService(configuration: .init(executable: { _ in throw CancellationError() }, environment: [:], clientVersion: "test"))
        let keys = AIKeyStore(store: MemoryKeys())
        func source(_ policy: AIPolicy, environment: ConnectionEnvironment = .development, language: QueryLanguage = .sql(.postgresql)) -> InlineSuggestionSource? {
            var connection = ConnectionConfig(kind: .postgresql, environment: environment)
            connection.aiPolicyLevel = policy
            return InlineSuggestionSources.make(settings: settings, connection: connection, language: language, keys: keys, copilot: service)
        }
        #expect(source(.allow) is CopilotInlineSuggestionSource)
        #expect(source(.ask) == nil)
        #expect(source(.never) == nil)
        #expect(source(.allow, language: .mongo) == nil)
        #expect(source(.allow, language: .redis) == nil)
        var connection = ConnectionConfig(kind: .postgresql, environment: .production)
        #expect(InlineSuggestionSources.availability(settings: settings, connection: connection, language: .sql(.postgresql), keys: keys) == .policyNever)
        connection.aiPolicyLevel = .allow
        #expect(InlineSuggestionSources.availability(settings: settings, connection: connection, language: .sql(.postgresql), keys: keys).provider?.kind == .copilot,
                "Copilot needs no API key")
        settings.enabled = false
        #expect(source(.allow) == nil)
    }
}

final class MemoryKeys: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    var accounts: [String] { lock.withLock { secrets.keys.sorted() } }
    func secret(account: String) -> String? { lock.withLock { secrets[account] } }
    func setSecret(_ secret: String, account: String) throws { lock.withLock { secrets[account] = secret } }
    func deleteSecret(account: String) { lock.withLock { secrets[account] = nil } }
}

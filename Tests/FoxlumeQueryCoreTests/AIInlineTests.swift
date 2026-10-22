import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite("AI requests")
struct AIRequestTests {
    private let prompt = AIInlinePrompt(textBefore: "SELECT * FROM ord", textAfter: "\n", dialect: "PostgreSQL", schemaText: "orders(id integer PK)")

    private func json(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func openAIChatCompletion() throws {
        let provider = AIProviderConfig(name: "Local", kind: .openAICompatible, baseURL: "http://localhost:11434/v1/", model: "llama3.1")
        let request = try AIRequestBuilder.completionRequest(provider: provider, apiKey: "sk-test", prompt: prompt)
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        let body = try json(request)
        #expect(Set(body.keys) == ["model", "messages", "max_tokens", "temperature", "stop", "stream"])
        #expect(body["model"] as? String == "llama3.1")
        #expect(body["max_tokens"] as? Int == 256)
        #expect(body["temperature"] as? Double == 0.1)
        #expect(body["stream"] as? Bool == false)
        #expect(body["stop"] as? [String] == ["\n\n", ";\n"])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[0]["content"] == AIInlinePrompt.instructions + "\n\nSQL dialect: PostgreSQL\n\nSchema (table(column type), PK = primary key, FK = foreign key):\norders(id integer PK)")
        #expect(messages[1] == ["role": "user", "content": "SELECT * FROM ord<CURSOR>\n"])
    }

    @Test func openAIWithoutKeySendsNoAuthorization() throws {
        let provider = AIProviderConfig(kind: .openAICompatible, baseURL: "http://localhost:1234/v1", model: "qwen")
        let request = try AIRequestBuilder.completionRequest(provider: provider, apiKey: "  ", prompt: prompt)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func anthropicMessages() throws {
        let provider = AIProviderConfig(name: "Claude", kind: .anthropic)
        #expect(provider.model == "claude-opus-5-5")
        let request = try AIRequestBuilder.completionRequest(provider: provider, apiKey: "sk-ant-test", prompt: prompt)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try json(request)
        // No temperature, top_p, top_k or thinking: current models reject them.
        #expect(Set(body.keys) == ["model", "max_tokens", "system", "messages", "output_config", "fallbacks"])
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["max_tokens"] as? Int == 2048)
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["output_config"] as? [String: String] == ["effort": "low"])
        let system = try #require(body["system"] as? [[String: Any]])
        #expect(system.count == 2)
        #expect(system[0]["type"] as? String == "text")
        #expect(system[0]["text"] as? String == AIInlinePrompt.instructions)
        #expect(system[0]["cache_control"] == nil)
        #expect(system[1]["text"] as? String == prompt.contextText)
        #expect(system[1]["cache_control"] as? [String: String] == ["type": "ephemeral"])
        // One user message, never an assistant prefill.
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "SELECT * FROM ord<CURSOR>\n"]])
    }

    @Test func anthropicModelsWithoutFallbacksOrEffort() throws {
        var provider = AIProviderConfig(kind: .anthropic, model: "claude-haiku-5-5")
        var request = try AIRequestBuilder.completionRequest(provider: provider, apiKey: "k", prompt: prompt)
        var body = try json(request)
        #expect(body["fallbacks"] == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(body["output_config"] as? [String: String] == ["effort": "low"])
        provider.model = "claude-haiku-4-5"
        request = try AIRequestBuilder.completionRequest(provider: provider, apiKey: "k", prompt: prompt)
        body = try json(request)
        #expect(body["output_config"] == nil)
        #expect(body["fallbacks"] == nil)
    }

    @Test func testRequestsAreTiny() throws {
        let anthropic = try AIRequestBuilder.testRequest(provider: AIProviderConfig(kind: .anthropic), apiKey: "k")
        let anthropicBody = try json(anthropic)
        #expect(anthropicBody["system"] == nil)
        #expect((anthropicBody["messages"] as? [[String: String]])?.first?["content"] == "Reply with the single word OK.")
        let openAI = try AIRequestBuilder.testRequest(provider: AIProviderConfig(kind: .openAICompatible, model: "gpt-4o-mini"), apiKey: nil)
        let openAIBody = try json(openAI)
        #expect(openAIBody["max_tokens"] as? Int == 16)
        #expect(openAIBody["stop"] == nil)
        #expect((openAIBody["messages"] as? [[String: String]])?.count == 1)
    }

    @Test func modelsRequests() throws {
        let openAI = try AIRequestBuilder.modelsRequest(provider: AIProviderConfig(kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1"), apiKey: "or-key")
        #expect(openAI.url?.absoluteString == "https://openrouter.ai/api/v1/models")
        #expect(openAI.httpMethod == "GET")
        #expect(openAI.value(forHTTPHeaderField: "Authorization") == "Bearer or-key")
        #expect(openAI.httpBody == nil)
        let anthropic = try AIRequestBuilder.modelsRequest(provider: AIProviderConfig(kind: .anthropic), apiKey: "k", afterID: "claude-x")
        #expect(anthropic.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=100&after_id=claude-x")
        #expect(anthropic.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(anthropic.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test func invalidBaseURL() {
        let provider = AIProviderConfig(kind: .openAICompatible, baseURL: "localhost:11434", model: "m")
        #expect(provider.validationMessage != nil)
        #expect(throws: AIProviderError.invalidBaseURL) {
            try AIRequestBuilder.completionRequest(provider: provider, apiKey: nil, prompt: prompt)
        }
    }
}

@Suite("AI responses")
struct AIResponseTests {
    private func data(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    @Test func anthropicTextBlocksOnly() throws {
        let body = data([
            "content": [
                ["type": "thinking", "thinking": "", "signature": "x"],
                ["type": "text", "text": "ERS WHERE "],
                ["type": "text", "text": "status = 'paid'"],
            ],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 1200],
        ])
        let completion = try AIResponseParser.completion(kind: .anthropic, data: body)
        #expect(completion.text == "ERS WHERE status = 'paid'")
        #expect(completion.stopReason == "end_turn")
        #expect(completion.cacheReadTokens == 1200)
        #expect(!completion.refused)
    }

    @Test func anthropicRefusalHasNoText() throws {
        let body = data(["content": [["type": "text", "text": "partial"]], "stop_reason": "refusal",
                         "stop_details": ["type": "refusal", "category": "cyber"]])
        let completion = try AIResponseParser.completion(kind: .anthropic, data: body)
        #expect(completion.refused)
        #expect(completion.text == nil)
    }

    @Test func anthropicMaxTokensKeepsText() throws {
        let completion = try AIResponseParser.completion(kind: .anthropic, data: data(["content": [["type": "text", "text": "id, name"]], "stop_reason": "max_tokens"]))
        #expect(completion.text == "id, name")
        #expect(completion.stopReason == "max_tokens")
    }

    @Test func openAIChoices() throws {
        let completion = try AIResponseParser.completion(kind: .openAICompatible, data: data([
            "choices": [["index": 0, "message": ["role": "assistant", "content": "FROM orders"], "finish_reason": "stop"]],
        ]))
        #expect(completion.text == "FROM orders")
        #expect(completion.stopReason == "stop")
        let refused = try AIResponseParser.completion(kind: .openAICompatible, data: data([
            "choices": [["message": ["role": "assistant", "content": NSNull(), "refusal": "I can't help"], "finish_reason": "stop"]],
        ]))
        #expect(refused.refused)
        let empty = try AIResponseParser.completion(kind: .openAICompatible, data: data(["choices": []]))
        #expect(empty.text == nil)
    }

    @Test func malformedBodies() {
        #expect(throws: AIProviderError.invalidResponse) { try AIResponseParser.completion(kind: .anthropic, data: Data("<html>".utf8)) }
        #expect(throws: AIProviderError.invalidResponse) { try AIResponseParser.completion(kind: .openAICompatible, data: Data("{}".utf8)) }
    }

    @Test func modelPages() throws {
        let page = try AIResponseParser.models(kind: .anthropic, data: data([
            "data": [["id": "claude-opus-5-5", "display_name": "Claude Opus 5.5", "type": "model"]],
            "has_more": true, "last_id": "claude-opus-5-5",
        ]))
        #expect(page.models == [AIModelInfo(id: "claude-opus-5-5", displayName: "Claude Opus 5.5")])
        #expect(page.nextAfterID == "claude-opus-5-5")
        let openAI = try AIResponseParser.models(kind: .openAICompatible, data: data(["object": "list", "data": [["id": "gpt-4o-mini"], ["id": "o3"]], "has_more": true]))
        #expect(openAI.models.map(\.id) == ["gpt-4o-mini", "o3"])
        #expect(openAI.nextAfterID == nil)
    }

    @Test func errorMapping() {
        let none: [AnyHashable: Any] = [:]
        #expect(AIProviderError.from(status: 200, headers: none, body: Data()) == nil)
        #expect(AIProviderError.from(status: 401, headers: none, body: Data()) == .keyRejected)
        #expect(AIProviderError.from(status: 403, headers: none, body: Data()) == .keyRejected)
        #expect(AIProviderError.keyRejected.localizedDescription == "API key rejected")
        #expect(AIProviderError.from(status: 429, headers: ["Retry-After": "12"], body: Data()) == .rateLimited(retryAfter: 12))
        #expect(AIProviderError.from(status: 429, headers: none, body: Data()) == .rateLimited(retryAfter: nil))
        // 2027-01-15 08:00:30 GMT is 1_800_000_030 seconds after 1970; asked 30 s before it.
        let date = "Fri, 15 Jan 2027 08:00:30 GMT"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AIProviderError.from(status: 429, headers: ["retry-after": date], body: Data(), now: now) == .rateLimited(retryAfter: 30))
        #expect(AIProviderError.from(status: 500, headers: none, body: Data()) == .unavailable(status: 500))
        #expect(AIProviderError.from(status: 529, headers: none, body: Data()) == .unavailable(status: 529))
        #expect(AIProviderError.unavailable(status: 529).isTransient)
        let body = Data(#"{"type":"error","error":{"type":"not_found_error","message":"model: nope"}}"#.utf8)
        #expect(AIProviderError.from(status: 404, headers: none, body: body) == .rejected(status: 404, message: "model: nope"))
        #expect(AIProviderError.from(URLError(.timedOut)) == .timedOut)
        #expect(AIProviderError.from(URLError(.cancelled)) == .cancelled)
        #expect(AIProviderError.from(CancellationError()) == .cancelled)
        #expect(AIProviderError.timedOut.isTransient)
        #expect(!AIProviderError.keyRejected.isTransient)
        #expect(!AIProviderError.rateLimited(retryAfter: nil).isTransient)
    }
}

@Suite("AI provider client", .serialized)
struct AIProviderClientTests {
    private static func anthropicReply(_ text: String, stop: String = "end_turn") -> AIStubURLProtocol.Reply {
        AIStubURLProtocol.json(["content": [["type": "text", "text": text]], "stop_reason": stop, "usage": ["cache_read_input_tokens": 0]])
    }

    private func source(host: String, kind: AIProviderKind = .anthropic, reply: @escaping (URLRequest) -> AIStubURLProtocol.Reply) -> ChatInlineSuggestionSource {
        let session = AIStubURLProtocol.session(host: host, handler: reply)
        let provider = AIProviderConfig(kind: kind, baseURL: "https://\(host)/v1", model: kind == .anthropic ? "claude-opus-5-5" : "gpt-4o-mini")
        return ChatInlineSuggestionSource(provider: provider, apiKey: "secret-key", session: session)
    }

    private let request = InlineSuggestionRequest(
        text: "SELECT * FROM ord\nWHERE 1 = 1", caret: 17, dialect: "PostgreSQL",
        schema: [AISchemaTable(name: "orders", columns: [.init(name: "id", type: "integer", isPrimaryKey: true)])]
    )

    @Test func successRecordsTheExactRequest() async throws {
        let host = "claude-success.test"
        defer { AIStubURLProtocol.reset(host: host) }
        let source = source(host: host) { _ in Self.anthropicReply("ers") }
        let suggestion = try await source.suggestion(for: request)
        #expect(suggestion == InlineSuggestion(text: "ers", location: 17))
        let sent = try #require(AIStubURLProtocol.requests(host: host).first)
        #expect(sent.url.absoluteString == "https://\(host)/v1/messages")
        #expect(sent.method == "POST")
        #expect(sent.header("x-api-key") == "secret-key")
        #expect(sent.header("anthropic-version") == "2023-06-01")
        #expect(sent.header("anthropic-beta") == "server-side-fallback-2026-07-01")
        let body = try #require(sent.json)
        #expect((body["messages"] as? [[String: String]]) == [["role": "user", "content": "SELECT * FROM ord<CURSOR>\nWHERE 1 = 1"]])
        let system = try #require(body["system"] as? [[String: Any]])
        #expect((system[1]["text"] as? String)?.contains("orders(id integer PK)") == true)
    }

    @Test func openAISuccessAndPostProcessing() async throws {
        let host = "openai-success.test"
        defer { AIStubURLProtocol.reset(host: host) }
        let source = source(host: host, kind: .openAICompatible) { _ in
            AIStubURLProtocol.json(["choices": [["message": ["role": "assistant", "content": "```sql\nSELECT * FROM orders\n```"], "finish_reason": "stop"]]])
        }
        let suggestion = try await source.suggestion(for: request)
        // The fence is stripped and the repeated "SELECT * FROM ord" with it.
        #expect(suggestion?.text == "ers")
        let sent = try #require(AIStubURLProtocol.requests(host: host).first)
        #expect(sent.url.absoluteString == "https://\(host)/v1/chat/completions")
        #expect(sent.header("Authorization") == "Bearer secret-key")
    }

    @Test func refusalAndEmptyAnswersGiveNoSuggestion() async throws {
        let host = "claude-refusal.test"
        defer { AIStubURLProtocol.reset(host: host) }
        var replies = [Self.anthropicReply("anything", stop: "refusal"), Self.anthropicReply(""), Self.anthropicReply("  \n ")]
        let source = source(host: host) { _ in replies.removeFirst() }
        #expect(try await source.suggestion(for: request) == nil)
        #expect(try await source.suggestion(for: request) == nil)
        #expect(try await source.suggestion(for: request) == nil)
    }

    @Test func maxTokensStillUsesTheText() async throws {
        let host = "claude-max.test"
        defer { AIStubURLProtocol.reset(host: host) }
        let source = source(host: host) { _ in Self.anthropicReply("ers o", stop: "max_tokens") }
        #expect(try await source.suggestion(for: request)?.text == "ers o")
    }

    @Test func httpErrors() async throws {
        let host = "claude-errors.test"
        defer { AIStubURLProtocol.reset(host: host) }
        var replies: [AIStubURLProtocol.Reply] = [
            AIStubURLProtocol.json(["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]], status: 401),
            AIStubURLProtocol.json(["type": "error"], status: 429, headers: ["retry-after": "7"]),
            AIStubURLProtocol.json(["type": "error"], status: 500),
            AIStubURLProtocol.json(["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]], status: 529),
            .failure(.timedOut),
            .failure(.notConnectedToInternet),
        ]
        let source = source(host: host) { _ in replies.removeFirst() }
        var errors: [AIProviderError] = []
        for _ in 0..<6 {
            do {
                _ = try await source.suggestion(for: request)
                Issue.record("expected an error")
            } catch {
                errors.append(AIProviderError.from(error))
            }
        }
        #expect(errors[0] == .keyRejected)
        #expect(errors[1] == .rateLimited(retryAfter: 7))
        #expect(errors[2] == .unavailable(status: 500))
        #expect(errors[3] == .unavailable(status: 529))
        #expect(errors[4] == .timedOut)
        if case .network = errors[5] {} else { Issue.record("offline was \(errors[5])") }
    }

    @Test func cancellingTheTaskCancelsTheRequest() async throws {
        let host = "claude-hang.test"
        defer { AIStubURLProtocol.reset(host: host) }
        let source = source(host: host) { _ in .hang }
        let request = self.request
        let task = Task { try await source.suggestion(for: request) }
        // Wait until the request reached the stub, then cancel.
        let deadline = Date().addingTimeInterval(5)
        while AIStubURLProtocol.requests(host: host).isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        task.cancel()
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("a cancelled request answered")
            return
        }
        #expect(AIProviderError.from(error) == .cancelled)
    }

    @Test func listModelsFollowsPages() async throws {
        let host = "claude-models.test"
        defer { AIStubURLProtocol.reset(host: host) }
        let session = AIStubURLProtocol.session(host: host) { request in
            if request.url?.query?.contains("after_id=b") == true {
                return AIStubURLProtocol.json(["data": [["id": "c", "display_name": "C"]], "has_more": false, "last_id": "c"])
            }
            return AIStubURLProtocol.json(["data": [["id": "a", "display_name": "A"], ["id": "b", "display_name": "B"]], "has_more": true, "last_id": "b"])
        }
        let client = AIProviderClient(provider: AIProviderConfig(kind: .anthropic, baseURL: "https://\(host)/v1"), apiKey: "k", session: session)
        let models = try await client.listModels()
        #expect(models.map(\.id) == ["a", "b", "c"])
        #expect(models.first?.displayName == "A")
        let urls = AIStubURLProtocol.requests(host: host).map(\.url.absoluteString)
        #expect(urls == ["https://\(host)/v1/models?limit=100", "https://\(host)/v1/models?limit=100&after_id=b"])
    }

    @Test func testRequestAnswer() async throws {
        let host = "openai-test.test"
        defer { AIStubURLProtocol.reset(host: host) }
        let session = AIStubURLProtocol.session(host: host) { _ in
            AIStubURLProtocol.json(["choices": [["message": ["role": "assistant", "content": "OK"], "finish_reason": "stop"]]])
        }
        let client = AIProviderClient(provider: AIProviderConfig(kind: .openAICompatible, baseURL: "http://\(host)/v1", model: "m"), apiKey: nil, session: session)
        #expect(try await client.test().text == "OK")
        #expect(AIStubURLProtocol.requests(host: host).first?.header("Authorization") == nil)
    }
}

@Suite("AI prompt and schema context")
struct AIPromptTests {
    @Test func capsTextAroundTheCaret() {
        let before = String(repeating: "a", count: 2_500)
        let after = String(repeating: "b", count: 900)
        let prompt = AIInlinePrompt(request: InlineSuggestionRequest(text: before + after, caret: 2_500, dialect: "MySQL"))
        #expect(prompt.textBefore.count == 2_000)
        #expect(prompt.textAfter.count == 500)
        #expect(prompt.userMessage == String(repeating: "a", count: 2_000) + "<CURSOR>" + String(repeating: "b", count: 500))
        #expect(prompt.contextText == "SQL dialect: MySQL")
    }

    @Test func neverSplitsASurrogatePair() {
        // "😀" is two UTF-16 units; a cut at 2,000 units from the caret would fall inside it.
        let text = "x😀" + String(repeating: "a", count: 1_999)
        let prompt = AIInlinePrompt(request: InlineSuggestionRequest(text: text, caret: (text as NSString).length, dialect: "SQLite"))
        #expect(prompt.textBefore == String(repeating: "a", count: 1_999))
        let short = AIInlinePrompt(request: InlineSuggestionRequest(text: "SELECT 1", caret: 99, dialect: "SQLite"))
        #expect(short.textBefore == "SELECT 1")
        #expect(short.textAfter == "")
    }

    @Test func schemaTablesMentionedFirstThenByName() {
        let orders = TableStructure(
            table: TableRef(schema: "public", name: "orders"),
            columns: [
                ColumnInfo(name: "id", dataType: "integer", isNullable: false, defaultValue: "nextval('x')", isPrimaryKey: true, comment: "secret comment"),
                ColumnInfo(name: "customer_id", dataType: "integer", isNullable: false),
                ColumnInfo(name: "note", dataType: "text"),
            ],
            indexes: [IndexInfo(name: "orders_pkey", columns: ["id"], isUnique: true, isPrimary: true)],
            foreignKeys: [ForeignKeyInfo(name: "fk", columns: ["customer_id"], referencedTable: TableRef(schema: "public", name: "customers"), referencedColumns: ["id"])],
            comment: "table comment"
        )
        let audit = TableStructure(table: TableRef(schema: "audit", name: "log"), columns: [ColumnInfo(name: "at", dataType: "timestamptz")])
        let refs = ["accounts", "customers", "orders", "zebra"].map { TableRef(schema: "public", name: $0) }
        let tables = AISchemaContext.tables(tables: refs, structures: [orders, audit], currentSchema: "public",
                                            editorText: "SELECT * FROM Orders o JOIN customers c ON", limit: 4)
        #expect(tables.map(\.name) == ["orders", "customers", "accounts", "zebra"])
        let text = AISchemaContext.text(for: tables)
        #expect(text == """
            orders(id integer PK, customer_id integer NOT NULL, note text) FK customer_id -> customers(id)
            customers
            accounts
            zebra
            """)
        #expect(!text.contains("secret") && !text.contains("nextval") && !text.contains("table comment"))
        let all = AISchemaContext.tables(tables: refs, structures: [orders, audit], currentSchema: "public", editorText: "", limit: 10)
        #expect(all.map(\.name) == ["accounts", "customers", "orders", "zebra", "audit.log"])
        #expect(AISchemaContext.tables(tables: refs, structures: [], currentSchema: nil, editorText: "", limit: 0).isEmpty)
    }

    @Test func mentionsAreWholeWords() {
        let positions = AISchemaContext.mentionedPositions(of: ["order", "orders"], in: "select * from orders")
        #expect(positions["orders"] == 14)
        #expect(positions["order"] == nil)
    }
}

@Suite("Inline suggestion post-processing")
struct InlineSuggestionPostProcessingTests {
    private func clean(_ raw: String, _ before: String, _ after: String = "") -> String? {
        InlineSuggestionPostProcessor.clean(raw, textBefore: before, textAfter: after)
    }

    @Test func codeFencesAndBackticks() {
        #expect(clean("```sql\nFROM orders\n```", "SELECT * ") == "FROM orders")
        #expect(clean("```\nFROM orders```", "SELECT * ") == "FROM orders")
        #expect(clean("`FROM orders`", "SELECT * ") == "FROM orders")
        #expect(clean("FROM orders<CURSOR>", "SELECT * ") == "FROM orders")
    }

    @Test func repeatedPrefixIsStripped() {
        #expect(clean("SELECT * FROM orders", "SELECT * FR") == "OM orders")
        #expect(clean("name, total", "SELECT n") == "ame, total")
        #expect(clean("WHERE id = 1", "SELECT * FROM t WHERE ") == "id = 1")
        // A match that starts inside a word is a coincidence, not a repeat.
        #expect(clean("s.id", "SELECT user") == "s.id")
    }

    @Test func spacingAndWhitespaceOnly() {
        #expect(clean("  FROM orders  \n", "SELECT * ") == "FROM orders")
        #expect(clean(" FROM orders", "SELECT *") == " FROM orders")
        #expect(clean("\nFROM orders", "SELECT *") == "\nFROM orders")
        #expect(clean("   \n\t", "SELECT ") == nil)
        #expect(clean("", "SELECT ") == nil)
        #expect(clean("SELECT ", "SELECT ") == nil)
    }

    @Test func textAlreadyAfterTheCaretIsTrimmed() {
        #expect(clean("*)", "SELECT count(", ")") == "*")
        #expect(clean("id FROM orders\nWHERE x = 1", "SELECT ", "\nWHERE x = 1") == "id FROM orders")
        #expect(clean("id", "SELECT ", " FROM t") == "id")
    }

    @Test func longAnswersAreCut() {
        let raw = (1...20).map { "line \($0)" }.joined(separator: "\n")
        #expect(clean(raw, "SELECT ")?.components(separatedBy: "\n").count == InlineSuggestionPostProcessor.maxLines)
    }
}

@Suite("AI settings and policy")
struct AIPolicyTests {
    private func connection(_ environment: ConnectionEnvironment, policy: AIPolicy? = nil) -> ConnectionConfig {
        var config = ConnectionConfig(kind: .postgresql, environment: environment)
        config.aiPolicy = policy
        return config
    }

    private var enabled: AISettings {
        var settings = AISettings()
        settings.enabled = true
        settings.upsert(AIProviderConfig(name: "Local", kind: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "llama3.1"))
        return settings
    }

    @Test func defaultsFollowTheEnvironment() {
        #expect(AIPolicy.allCases == [.allow, .ask, .never])
        #expect(connection(.production).aiPolicyLevel == .never)
        for environment in [ConnectionEnvironment.none, .local, .development, .staging] {
            #expect(connection(environment).aiPolicyLevel == .ask)
        }
        #expect(connection(.production, policy: .allow).aiPolicyLevel == .allow)
        #expect(connection(.production, policy: .ask).aiPolicyLevel == .ask)
        #expect(connection(.local, policy: .never).aiPolicyLevel == .never)
        #expect(connection(.local, policy: .allow).aiPolicyLevel == .allow)
        // Choosing the environment's default stores nothing, so a later environment change still applies.
        var config = connection(.development)
        config.aiPolicyLevel = .ask
        #expect(config.aiPolicy == nil)
        config.aiPolicyLevel = .allow
        #expect(config.aiPolicy == .allow)
        config.aiPolicyLevel = .never
        #expect(config.aiPolicy == .never)
        config.environment = .production
        config.aiPolicyLevel = .never
        #expect(config.aiPolicy == nil)
    }

    @Test func storedPoliciesDecode() throws {
        for (raw, policy) in [("allow", AIPolicy.allow), ("ask", .ask), ("never", .never)] {
            let json = #"{"id":"0F1E0000-0000-4000-8000-000000000001","name":"x","kind":"postgresql","host":"h","port":5432,"user":"u","database":"","filePath":"","sslMode":"prefer","color":"none","environment":"production","group":"","readOnly":false,"connectTimeout":10,"aiPolicy":"\#(raw)"}"#
            let config = try JSONDecoder().decode(ConnectionConfig.self, from: Data(json.utf8))
            #expect(config.aiPolicy == policy)
            #expect(config.aiPolicyLevel == policy)
        }
    }

    @Test func availability() {
        let keys: (UUID) -> Bool = { _ in false }
        let sql = QueryLanguage.sql(.postgresql)
        #expect(AIInlineAvailability.resolve(settings: AISettings(), connection: connection(.local), language: sql, hasAPIKey: keys) == .aiDisabled)
        var settings = enabled
        let local = settings.providers[0]
        #expect(AIInlineAvailability.resolve(settings: settings, connection: connection(.local, policy: .allow), language: sql, hasAPIKey: keys) == .available(local))
        // Ask: ready, but nothing may be sent before the user answers.
        let ask = AIInlineAvailability.resolve(settings: settings, connection: connection(.local), language: sql, hasAPIKey: keys)
        #expect(ask == .askFirst(local))
        #expect(ask.needsConsent)
        #expect(ask.provider == nil)
        #expect(AIInlineAvailability.resolve(settings: settings, connection: connection(.production), language: sql, hasAPIKey: keys) == .policyNever)
        #expect(AIInlineAvailability.resolve(settings: settings, connection: connection(.local, policy: .never), language: sql, hasAPIKey: keys) == .policyNever)
        // No prompt is worth showing without a usable provider.
        #expect(AIInlineAvailability.resolve(settings: AISettings(), connection: connection(.local), language: sql, hasAPIKey: keys) == .aiDisabled)
        #expect(AIInlineAvailability.resolve(settings: settings, connection: connection(.local), language: .mongo, hasAPIKey: keys) == .unsupportedLanguage)
        #expect(AIInlineAvailability.resolve(settings: settings, connection: connection(.local), language: .redis, hasAPIKey: keys) == .unsupportedLanguage)
        settings.inlineSuggestions = false
        #expect(AIInlineAvailability.resolve(settings: settings, connection: connection(.local), language: sql, hasAPIKey: keys) == .inlineDisabled)
        settings = enabled
        let claude = AIProviderConfig(name: "Claude", kind: .anthropic)
        settings.upsert(claude)
        settings.activeProviderID = claude.id
        #expect(AIInlineAvailability.resolve(settings: settings, connection: connection(.local), language: sql, hasAPIKey: keys) == .missingAPIKey)
        #expect(AIInlineAvailability.resolve(settings: settings, connection: connection(.local, policy: .allow), language: sql) { $0 == claude.id }.provider == claude)
        settings.providers = []
        #expect(AIInlineAvailability.resolve(settings: settings, connection: connection(.local), language: sql, hasAPIKey: keys) == .noProvider)
    }

    @Test func neverAndUnansweredAskMakeNoSource() {
        let store = FileCredentialStore(url: TestFiles.url("ai-policy-\(UUID().uuidString).json"))
        let keys = AIKeyStore(store: store)
        #expect(InlineSuggestionSources.make(settings: enabled, connection: connection(.production), language: .sql(.mysql), keys: keys) == nil)
        #expect(InlineSuggestionSources.make(settings: enabled, connection: connection(.local, policy: .never), language: .sql(.mysql), keys: keys) == nil)
        #expect(InlineSuggestionSources.make(settings: enabled, connection: connection(.local), language: .sql(.mysql), keys: keys) == nil, "Ask sends nothing before the answer")
        #expect(InlineSuggestionSources.make(settings: enabled, connection: connection(.local, policy: .allow), language: .sql(.mysql), keys: keys) != nil)
    }

    @Test func settingsDecodeWithDefaults() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"rowsPerPage": 200}"#.utf8))
        #expect(old.ai == AISettings())
        #expect(!old.ai.enabled)
        #expect(old.ai.debounceMilliseconds == 500)
        #expect(old.ai.maxSchemaTables == 20)
        #expect(old.ai.includeSchema)
        var settings = AppSettings()
        settings.ai = enabled
        settings.ai.debounceMilliseconds = 800
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.ai == settings.ai)
        #expect(decoded.ai.debounceInterval == 0.8)
        let text = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(!text.contains("apiKey"), "keys never go into settings.json")
    }

    @Test func connectionsSavedBeforeDecode() throws {
        let config = ConnectionConfig(kind: .postgresql, environment: .production)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object.removeValue(forKey: "aiPolicy")
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.aiPolicy == nil)
        #expect(decoded.aiPolicyLevel == .never)
    }

    @Test func removingTheActiveProviderPicksAnother() {
        var settings = enabled
        let second = AIProviderConfig(name: "Second", kind: .openAICompatible, model: "m")
        settings.upsert(second)
        let first = settings.providers[0]
        #expect(settings.activeProviderID == first.id)
        settings.removeProvider(id: first.id)
        #expect(settings.activeProvider == second)
    }

    @Test func portableKeysLiveInTheCredentialsFile() throws {
        let url = TestFiles.url("ai-keys-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = AIKeyStore(store: FileCredentialStore(url: url))
        let id = UUID()
        try keys.setAPIKey(" sk-portable \n", for: id)
        #expect(keys.apiKey(for: id) == "sk-portable")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let stored = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
        #expect(stored == ["ai." + id.uuidString: "sk-portable"])
        try keys.setAPIKey("", for: id)
        #expect(keys.apiKey(for: id) == nil)
    }
}

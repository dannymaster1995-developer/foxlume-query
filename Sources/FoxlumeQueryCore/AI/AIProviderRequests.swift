import Foundation

/// Builds the HTTP requests each provider takes. Pure, so tests can compare the exact URL, headers and JSON.
public enum AIRequestBuilder {
    public static let anthropicVersion = "2023-06-01"
    /// Server-side refusal fallbacks (`fallbacks: "default"`), on by default for the models that take them.
    public static let anthropicFallbackBeta = "server-side-fallback-2026-07-01"
    public static let openAIMaxTokens = 256
    public static let openAITemperature = 0.1
    /// Room for low-effort thinking plus a one or two line answer.
    public static let anthropicMaxTokens = 2048
    /// A blank line or the end of a statement ends a suggestion.
    public static let openAIStopSequences = ["\n\n", ";\n"]
    public static let completionTimeout: TimeInterval = 20
    public static let listTimeout: TimeInterval = 15

    public enum Purpose: Sendable {
        /// An inline suggestion.
        case inline
        /// Settings › AI › Test: a tiny request whose answer is shown.
        case test
    }

    public static func completionRequest(provider: AIProviderConfig, apiKey: String?, prompt: AIInlinePrompt) throws -> URLRequest {
        switch provider.kind {
        case .openAICompatible:
            return try openAIRequest(provider: provider, apiKey: apiKey, system: AIInlinePrompt.instructions + "\n\n" + prompt.contextText,
                                     user: prompt.userMessage, purpose: .inline)
        case .anthropic:
            let system: [[String: Any]] = [
                ["type": "text", "text": AIInlinePrompt.instructions],
                // The last stable block: instructions, dialect and schema are cached, the editor text is not.
                ["type": "text", "text": prompt.contextText, "cache_control": ["type": "ephemeral"]],
            ]
            return try anthropicRequest(provider: provider, apiKey: apiKey, system: system, user: prompt.userMessage, maxTokens: anthropicMaxTokens)
        case .copilot:
            // Copilot is asked through its language server, never over HTTP.
            throw AIProviderError.invalidBaseURL
        }
    }

    /// Settings › AI › Test.
    public static func testRequest(provider: AIProviderConfig, apiKey: String?) throws -> URLRequest {
        let question = "Reply with the single word OK."
        switch provider.kind {
        case .openAICompatible:
            return try openAIRequest(provider: provider, apiKey: apiKey, system: nil, user: question, purpose: .test)
        case .anthropic:
            return try anthropicRequest(provider: provider, apiKey: apiKey, system: nil, user: question, maxTokens: 1024)
        case .copilot:
            throw AIProviderError.invalidBaseURL
        }
    }

    /// `GET {base}/models`; Anthropic pages with `after_id`.
    public static func modelsRequest(provider: AIProviderConfig, apiKey: String?, afterID: String? = nil) throws -> URLRequest {
        guard let base = provider.normalizedBaseURL else { throw AIProviderError.invalidBaseURL }
        var components = URLComponents(url: base.appendingPathComponent("models"), resolvingAgainstBaseURL: false)
        if provider.kind == .anthropic {
            components?.queryItems = [URLQueryItem(name: "limit", value: "100")] + (afterID.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
        }
        guard let url = components?.url else { throw AIProviderError.invalidBaseURL }
        var request = URLRequest(url: url, timeoutInterval: listTimeout)
        request.httpMethod = "GET"
        applyHeaders(to: &request, provider: provider, apiKey: apiKey, beta: nil)
        return request
    }

    private static func openAIRequest(provider: AIProviderConfig, apiKey: String?, system: String?, user: String, purpose: Purpose) throws -> URLRequest {
        guard let base = provider.normalizedBaseURL else { throw AIProviderError.invalidBaseURL }
        var messages: [[String: Any]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": user])
        var body: [String: Any] = [
            "model": provider.model.trimmingCharacters(in: .whitespaces),
            "messages": messages,
            "max_tokens": purpose == .test ? 16 : openAIMaxTokens,
            "temperature": purpose == .test ? 0 : openAITemperature,
            "stream": false,
        ]
        if purpose == .inline { body["stop"] = openAIStopSequences }
        var request = URLRequest(url: base.appendingPathComponent("chat").appendingPathComponent("completions"), timeoutInterval: completionTimeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        applyHeaders(to: &request, provider: provider, apiKey: apiKey, beta: nil)
        return request
    }

    private static func anthropicRequest(provider: AIProviderConfig, apiKey: String?, system: [[String: Any]]?, user: String, maxTokens: Int) throws -> URLRequest {
        guard let base = provider.normalizedBaseURL else { throw AIProviderError.invalidBaseURL }
        let model = provider.model.trimmingCharacters(in: .whitespaces)
        // No `thinking` (it cannot be turned off on current models), no sampling parameters and no assistant prefill:
        // current models reject them. Low effort keeps the latency down.
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": user]],
        ]
        if let system { body["system"] = system }
        if AnthropicModelTraits.supportsEffort(model) { body["output_config"] = ["effort": "low"] }
        let fallbacks = AnthropicModelTraits.supportsServerFallbacks(model)
        if fallbacks { body["fallbacks"] = "default" }
        var request = URLRequest(url: base.appendingPathComponent("messages"), timeoutInterval: completionTimeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        applyHeaders(to: &request, provider: provider, apiKey: apiKey, beta: fallbacks ? anthropicFallbackBeta : nil)
        return request
    }

    private static func applyHeaders(to request: inout URLRequest, provider: AIProviderConfig, apiKey: String?, beta: String?) {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch provider.kind {
        case .openAICompatible:
            if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        case .copilot:
            break
        }
        if request.httpMethod == "POST" { request.setValue("application/json", forHTTPHeaderField: "content-type") }
        request.setValue("application/json", forHTTPHeaderField: "accept")
    }
}

/// What the Messages API accepts per model id. Ids are used exactly as the models list gives them.
public enum AnthropicModelTraits {
    /// `fallbacks: "default"` with the server-side fallback beta.
    public static func supportsServerFallbacks(_ model: String) -> Bool {
        ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(model)
    }

    /// `output_config.effort`; older models reject it.
    public static func supportsEffort(_ model: String) -> Bool {
        let older = ["claude-3", "claude-haiku-4-5", "claude-sonnet-4-5", "claude-sonnet-4-0", "claude-sonnet-4-2", "claude-opus-4-0", "claude-opus-4-1"]
        return !older.contains { model.hasPrefix($0) }
    }
}

/// A model from `GET /models`.
public struct AIModelInfo: Sendable, Hashable, Identifiable {
    public var id: String
    /// Anthropic's `display_name`; nil for OpenAI-compatible servers.
    public var displayName: String?

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }
}

/// A provider's answer to a completion request.
public struct AICompletion: Sendable, Equatable {
    /// Text blocks (Anthropic) or the first choice's message (OpenAI); nil when the model refused.
    public var text: String?
    /// `end_turn`, `max_tokens`, `refusal`, `stop`, `length`…
    public var stopReason: String?
    /// Anthropic `usage.cache_read_input_tokens`.
    public var cacheReadTokens: Int?
    public var refused: Bool { stopReason == "refusal" }

    public init(text: String?, stopReason: String? = nil, cacheReadTokens: Int? = nil) {
        self.text = text
        self.stopReason = stopReason
        self.cacheReadTokens = cacheReadTokens
    }
}

public enum AIResponseParser {
    public static func completion(kind: AIProviderKind, data: Data) throws -> AICompletion {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIProviderError.invalidResponse }
        switch kind {
        case .openAICompatible:
            guard let choices = object["choices"] as? [[String: Any]] else { throw AIProviderError.invalidResponse }
            guard let first = choices.first else { return AICompletion(text: nil) }
            let finish = first["finish_reason"] as? String
            let message = first["message"] as? [String: Any]
            if let refusal = message?["refusal"] as? String, !refusal.isEmpty {
                return AICompletion(text: nil, stopReason: "refusal")
            }
            // Some servers (older ones, legacy completions) answer with `text` on the choice.
            let text = (message?["content"] as? String) ?? (first["text"] as? String)
            return AICompletion(text: text, stopReason: finish)
        case .anthropic:
            guard let content = object["content"] as? [[String: Any]] else { throw AIProviderError.invalidResponse }
            let stop = object["stop_reason"] as? String
            let usage = object["usage"] as? [String: Any]
            let cacheRead = (usage?["cache_read_input_tokens"] as? NSNumber)?.intValue
            // stop_reason first: a refusal carries no usable content.
            if stop == "refusal" { return AICompletion(text: nil, stopReason: stop, cacheReadTokens: cacheRead) }
            // Only text blocks; thinking and fallback blocks are not part of the answer.
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            return AICompletion(text: text, stopReason: stop, cacheReadTokens: cacheRead)
        case .copilot:
            throw AIProviderError.invalidResponse
        }
    }

    /// Models from one page, and the id to continue after when the provider has more.
    public static func models(kind: AIProviderKind, data: Data) throws -> (models: [AIModelInfo], nextAfterID: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIProviderError.invalidResponse }
        let list = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]]) ?? []
        let models = list.compactMap { entry -> AIModelInfo? in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            return AIModelInfo(id: id, displayName: entry["display_name"] as? String)
        }
        guard kind == .anthropic, object["has_more"] as? Bool == true else { return (models, nil) }
        return (models, (object["last_id"] as? String) ?? models.last?.id)
    }

    /// The `error.message` of an error body, if any.
    public static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let message = object["error"] as? String { return message }
        return object["message"] as? String
    }
}

/// A provider failure, mapped from the HTTP status or the network error.
public enum AIProviderError: Error, Equatable, LocalizedError, Sendable {
    /// 401 or 403.
    case keyRejected
    /// 429: back off; `retryAfter` from the header when given.
    case rateLimited(retryAfter: TimeInterval?)
    /// 5xx and 529 (overloaded): retried silently on the next keystroke.
    case unavailable(status: Int)
    case timedOut
    case network(String)
    /// Other 4xx, such as an unknown model.
    case rejected(status: Int, message: String?)
    case invalidResponse
    case invalidBaseURL
    case cancelled
    /// The source cannot answer until the user does something, such as signing in to GitHub Copilot.
    case notReady(String)

    public var errorDescription: String? {
        switch self {
        case .keyRejected: return "API key rejected"
        case .rateLimited: return "Rate limited by the provider"
        case .unavailable(let status): return "The provider is unavailable (HTTP \(status))"
        case .timedOut: return "The provider did not answer in time"
        case .network(let message): return message
        case .rejected(let status, let message): return message.map { "HTTP \(status): \($0)" } ?? "The provider refused the request (HTTP \(status))"
        case .invalidResponse: return "The provider sent an answer that is not understood"
        case .invalidBaseURL: return "The base URL is not a valid http or https URL"
        case .cancelled: return "Cancelled"
        case .notReady(let message): return message
        }
    }

    /// Failures the editor does not report: the next keystroke simply asks again.
    public var isTransient: Bool {
        switch self {
        case .unavailable, .timedOut, .network, .cancelled: return true
        default: return false
        }
    }

    /// Nil for a 2xx status.
    public static func from(status: Int, headers: [AnyHashable: Any], body: Data, now: Date = Date()) -> AIProviderError? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .keyRejected
        case 429: return .rateLimited(retryAfter: retryAfter(headers: headers, now: now))
        case 500..<600: return .unavailable(status: status)
        default: return .rejected(status: status, message: AIResponseParser.errorMessage(body))
        }
    }

    public static func from(_ error: Error) -> AIProviderError {
        if let error = error as? AIProviderError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? JSONRPCError, error.isCancellation { return .cancelled }
        if let error = error as? CopilotInstallError { return .notReady(error.localizedDescription) }
        guard let urlError = error as? URLError else { return .network(error.localizedDescription) }
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        default: return .network(urlError.localizedDescription)
        }
    }

    /// `retry-after` in seconds or as an HTTP date.
    static func retryAfter(headers: [AnyHashable: Any], now: Date) -> TimeInterval? {
        let value = headers.first { ($0.key as? String)?.lowercased() == "retry-after" }?.value as? String
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

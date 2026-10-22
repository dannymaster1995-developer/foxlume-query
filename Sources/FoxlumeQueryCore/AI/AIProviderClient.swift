import Foundation
import os

/// Talks to one provider over URLSession. Cancelling the calling task cancels the URLSession task.
public final class AIProviderClient: Sendable {
    public let provider: AIProviderConfig
    private let apiKey: String?
    private let session: URLSession
    static let log = Logger(subsystem: "com.foxlume.query", category: "ai")

    public init(provider: AIProviderConfig, apiKey: String?, session: URLSession = .shared) {
        self.provider = provider
        self.apiKey = apiKey
        self.session = session
    }

    public func complete(_ prompt: AIInlinePrompt) async throws -> AICompletion {
        let request = try AIRequestBuilder.completionRequest(provider: provider, apiKey: apiKey, prompt: prompt)
        let completion = try AIResponseParser.completion(kind: provider.kind, data: try await send(request))
        if completion.refused {
            Self.log.debug("Inline suggestion refused by \(self.provider.model, privacy: .public)")
        }
        if let cached = completion.cacheReadTokens {
            Self.log.debug("Inline suggestion: \(cached, privacy: .public) cached input tokens read")
        }
        return completion
    }

    /// Settings › AI › Test: the model's answer to a tiny request.
    public func test() async throws -> AICompletion {
        let request = try AIRequestBuilder.testRequest(provider: provider, apiKey: apiKey)
        return try AIResponseParser.completion(kind: provider.kind, data: try await send(request))
    }

    /// Every model the provider lists, following Anthropic's pages (at most 10).
    public func listModels() async throws -> [AIModelInfo] {
        var models: [AIModelInfo] = []
        var afterID: String?
        for _ in 0..<10 {
            let request = try AIRequestBuilder.modelsRequest(provider: provider, apiKey: apiKey, afterID: afterID)
            let page = try AIResponseParser.models(kind: provider.kind, data: try await send(request))
            models += page.models
            guard let next = page.nextAfterID, next != afterID else { break }
            afterID = next
        }
        var seen = Set<String>()
        return models.filter { seen.insert($0.id).inserted }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIProviderError.from(error)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        if let error = AIProviderError.from(status: http.statusCode, headers: http.allHeaderFields, body: data) {
            Self.log.debug("AI request failed with HTTP \(http.statusCode, privacy: .public)")
            throw error
        }
        return data
    }
}

/// Cleans a model's answer into text to insert at the caret.
public enum InlineSuggestionPostProcessor {
    public static let maxLines = 8

    /// Nil when nothing useful is left.
    public static func clean(_ raw: String, textBefore: String, textAfter: String) -> String? {
        var text = stripCodeFences(raw)
        text = text.replacingOccurrences(of: AIInlinePrompt.cursorMarker, with: "")
        // Trailing whitespace never helps a suggestion; a newline at the start may (a new clause on its own line).
        while let last = text.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) { text.unicodeScalars.removeLast() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        text = stripRepeatedPrefix(text, textBefore: textBefore)
        // An answer that only repeats the last words before the caret (`SELECT |` + `SELECT`) adds nothing.
        let trimmedBefore = textBefore.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
        if trimmedBefore != textBefore, stripRepeatedPrefix(text, textBefore: trimmedBefore).isEmpty { return nil }
        if let last = textBefore.last, last == " " || last == "\t" {
            text = String(text.drop { $0 == " " || $0 == "\t" })
        }
        text = trimDuplicatedSuffix(text, textAfter: textAfter)
        let lines = text.components(separatedBy: "\n")
        if lines.count > maxLines { text = lines.prefix(maxLines).joined(separator: "\n") }
        while let last = text.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) { text.unicodeScalars.removeLast() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// The body of the first ``` fence, or the text without a pair of backticks around all of it.
    static func stripCodeFences(_ raw: String) -> String {
        if let open = raw.range(of: "```") {
            let afterOpen = raw[open.upperBound...]
            // The fence line may name a language (```sql).
            let bodyStart = afterOpen.firstIndex(of: "\n").map { afterOpen.index(after: $0) } ?? afterOpen.startIndex
            let body = raw[bodyStart...]
            let end = body.range(of: "```")?.lowerBound ?? body.endIndex
            let before = raw[..<open.lowerBound]
            // Text before the fence is an explanation unless the answer is only the fenced part.
            let fenced = String(body[..<end])
            return before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !fenced.isEmpty ? fenced : raw
        }
        if raw.count > 2, raw.hasPrefix("`"), raw.hasSuffix("`"), !raw.dropFirst().dropLast().contains("`") {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    /// Drops the start of the answer when it repeats the end of the text before the caret. The repeated part must
    /// start at a word boundary there, so `user|` + `s.id` is kept while `SELECT n|` + `name` becomes `ame`.
    static func stripRepeatedPrefix(_ text: String, textBefore: String) -> String {
        let before = Array(textBefore.utf16.suffix(400))
        let suggestion = Array(text.utf16)
        let longest = min(before.count, suggestion.count)
        guard longest > 0 else { return text }
        for length in stride(from: longest, through: 1, by: -1) {
            let start = before.count - length
            guard Array(before[start...]) == Array(suggestion[..<length]) else { continue }
            let boundary = start == 0 || !isWordCharacter(before[start - 1]) || !isWordCharacter(before[start])
            guard boundary else { continue }
            if length == suggestion.count { return "" }
            return String(utf16CodeUnits: Array(suggestion[length...]), count: suggestion.count - length)
        }
        return text
    }

    /// Drops the end of the answer when it is what already follows the caret (a closing bracket, the rest of a line).
    static func trimDuplicatedSuffix(_ text: String, textAfter: String) -> String {
        let after = textAfter.drop { $0 == " " || $0 == "\t" }
        guard !after.isEmpty, !text.isEmpty else { return text }
        let suggestion = Array(text.utf16)
        let following = Array(String(after).utf16)
        let longest = min(suggestion.count, following.count)
        for length in stride(from: longest, through: 1, by: -1) where Array(suggestion.suffix(length)) == Array(following.prefix(length)) {
            return String(utf16CodeUnits: Array(suggestion.dropLast(length)), count: suggestion.count - length)
        }
        return text
    }

    private static func isWordCharacter(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
    }
}

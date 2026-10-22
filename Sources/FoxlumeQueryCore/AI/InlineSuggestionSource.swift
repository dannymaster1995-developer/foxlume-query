import Foundation

/// Text proposed for insertion at the caret, as the editor shows it in grey.
public struct InlineSuggestion: Sendable, Equatable {
    public var text: String
    /// UTF-16 offset in the request's text where `text` goes.
    public var location: Int
    /// A source's own handle for the suggestion (a language server's item id, for example).
    public var sourceItemID: String?

    public init(text: String, location: Int, sourceItemID: String? = nil) {
        self.text = text
        self.location = location
        self.sourceItemID = sourceItemID
    }
}

/// Where inline suggestions come from. The editor's suggestion manager owns the debounce, the cancellation and the
/// grey text; a source only answers one request at a time. Cancelling the calling task must cancel the source's
/// work. The chat API source is the first; a language server (GitHub Copilot) can be another.
public protocol InlineSuggestionSource: AnyObject, Sendable {
    /// Nil when the source has nothing useful. Throws `AIProviderError` (or `CancellationError`) on failure.
    func suggestion(for request: InlineSuggestionRequest) async throws -> InlineSuggestion?
    /// The user took all of `suggestion` (`partially` after the first word of it).
    func didAccept(_ suggestion: InlineSuggestion, partially: Bool)
    /// The suggestion was shown and then dismissed, typed over or abandoned.
    func didDismiss(_ suggestion: InlineSuggestion)
}

/// Inline suggestions from a chat API (OpenAI-compatible or Anthropic): sends the capped editor text, the dialect and
/// the schema, and cleans the answer.
public final class ChatInlineSuggestionSource: InlineSuggestionSource {
    public let client: AIProviderClient

    public init(client: AIProviderClient) {
        self.client = client
    }

    public convenience init(provider: AIProviderConfig, apiKey: String?, session: URLSession = .shared) {
        self.init(client: AIProviderClient(provider: provider, apiKey: apiKey, session: session))
    }

    public func suggestion(for request: InlineSuggestionRequest) async throws -> InlineSuggestion? {
        let prompt = AIInlinePrompt(request: request)
        let completion = try await client.complete(prompt)
        guard !completion.refused, let raw = completion.text,
              let text = InlineSuggestionPostProcessor.clean(raw, textBefore: prompt.textBefore, textAfter: prompt.textAfter)
        else { return nil }
        return InlineSuggestion(text: text, location: request.caret)
    }

    public func didAccept(_ suggestion: InlineSuggestion, partially: Bool) {}
    public func didDismiss(_ suggestion: InlineSuggestion) {}
}

public enum InlineSuggestionSources {
    /// The source an editor of `connection` in `language` uses, or nil when nothing may be sent (AI off, inline
    /// suggestions off, no usable provider, a Never policy or an Ask policy not answered yet, MongoDB or Redis).
    public static func make(
        settings: AISettings,
        connection: ConnectionConfig,
        language: QueryLanguage,
        keys: AIKeyStore,
        session: URLSession = .shared
    ) -> InlineSuggestionSource? {
        guard let provider = availability(settings: settings, connection: connection, language: language, keys: keys).provider else { return nil }
        return ChatInlineSuggestionSource(provider: provider, apiKey: keys.apiKey(for: provider.id), session: session)
    }

    public static func availability(settings: AISettings, connection: ConnectionConfig, language: QueryLanguage, keys: AIKeyStore) -> AIInlineAvailability {
        AIInlineAvailability.resolve(settings: settings, connection: connection, language: language) { keys.apiKey(for: $0) != nil }
    }
}

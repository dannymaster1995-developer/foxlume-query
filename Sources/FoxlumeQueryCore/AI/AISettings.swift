import Foundation

/// The wire format a provider speaks.
public enum AIProviderKind: String, Codable, CaseIterable, Sendable {
    /// `POST {base}/chat/completions`: OpenAI, OpenRouter, Ollama, LM Studio, Gemini's compatible endpoint and others.
    case openAICompatible
    /// Anthropic's Messages API (`POST {base}/messages`).
    case anthropic

    public var title: String {
        switch self {
        case .openAICompatible: return "OpenAI-compatible"
        case .anthropic: return "Anthropic (Claude)"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        }
    }

    public var defaultModel: String {
        switch self {
        case .openAICompatible: return ""
        case .anthropic: return "claude-opus-5-5"
        }
    }

    /// Anthropic always needs a key; local OpenAI-compatible servers usually do not.
    public var requiresAPIKey: Bool { self == .anthropic }
}

/// A ready-made base URL for the provider form.
public struct AIProviderPreset: Sendable, Hashable {
    public var name: String
    public var kind: AIProviderKind
    public var baseURL: String
    /// Local servers take no key.
    public var isLocal: Bool

    public static let all: [AIProviderPreset] = [
        AIProviderPreset(name: "OpenAI", kind: .openAICompatible, baseURL: "https://api.openai.com/v1", isLocal: false),
        AIProviderPreset(name: "OpenRouter", kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1", isLocal: false),
        AIProviderPreset(name: "Ollama", kind: .openAICompatible, baseURL: "http://localhost:11434/v1", isLocal: true),
        AIProviderPreset(name: "LM Studio", kind: .openAICompatible, baseURL: "http://localhost:1234/v1", isLocal: true),
        AIProviderPreset(name: "Gemini", kind: .openAICompatible, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", isLocal: false),
        AIProviderPreset(name: "Anthropic", kind: .anthropic, baseURL: AIProviderKind.anthropic.defaultBaseURL, isLocal: false),
    ]
}

/// A provider in Settings › AI. Its API key is kept in the credential store (`AIKeyStore`), never here.
public struct AIProviderConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: AIProviderKind
    public var baseURL: String
    public var model: String

    public init(id: UUID = UUID(), name: String = "", kind: AIProviderKind = .openAICompatible, baseURL: String? = nil, model: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.model = model ?? kind.defaultModel
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? kind.title : trimmed
    }

    /// The base URL without trailing slashes, or nil when it is not an http(s) URL.
    public var normalizedBaseURL: URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            return nil
        }
        return url
    }

    /// What the form says is missing before the provider can be used.
    public var validationMessage: String? {
        if normalizedBaseURL == nil { return "Enter an http or https base URL." }
        if model.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a model." }
        return nil
    }
}

/// Settings › AI. Everything is off until the user turns AI on and adds a provider.
public struct AISettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var providers: [AIProviderConfig] = []
    /// The provider inline suggestions use; the first one when unset or removed.
    public var activeProviderID: UUID?
    public var inlineSuggestions = true
    /// The pause after the last keystroke before a suggestion is asked for.
    public var debounceMilliseconds = 500
    /// Send table and column names, types, keys and foreign keys of the current schema with each request.
    public var includeSchema = true
    public var maxSchemaTables = 20

    public static let debounceRange = 200...3000
    public static let schemaTableRange = 1...200

    public init() {}

    public var activeProvider: AIProviderConfig? {
        providers.first { $0.id == activeProviderID } ?? providers.first
    }

    public var debounceInterval: TimeInterval {
        TimeInterval(min(max(debounceMilliseconds, Self.debounceRange.lowerBound), Self.debounceRange.upperBound)) / 1000
    }

    public var schemaTableLimit: Int {
        min(max(maxSchemaTables, Self.schemaTableRange.lowerBound), Self.schemaTableRange.upperBound)
    }

    public mutating func upsert(_ provider: AIProviderConfig) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        if activeProviderID == nil || !providers.contains(where: { $0.id == activeProviderID }) { activeProviderID = provider.id }
    }

    public mutating func removeProvider(id: UUID) {
        providers.removeAll { $0.id == id }
        if activeProviderID == id { activeProviderID = providers.first?.id }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, providers, activeProviderID, inlineSuggestions, debounceMilliseconds, includeSchema, maxSchemaTables
    }

    public init(from decoder: Decoder) throws {
        let defaults = AISettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        providers = (try? container.decodeIfPresent([AIProviderConfig].self, forKey: .providers)) ?? defaults.providers
        activeProviderID = try? container.decodeIfPresent(UUID.self, forKey: .activeProviderID)
        inlineSuggestions = try container.decodeIfPresent(Bool.self, forKey: .inlineSuggestions) ?? defaults.inlineSuggestions
        debounceMilliseconds = try container.decodeIfPresent(Int.self, forKey: .debounceMilliseconds) ?? defaults.debounceMilliseconds
        includeSchema = try container.decodeIfPresent(Bool.self, forKey: .includeSchema) ?? defaults.includeSchema
        maxSchemaTables = try container.decodeIfPresent(Int.self, forKey: .maxSchemaTables) ?? defaults.maxSchemaTables
    }
}

/// Whether AI features may send anything for a connection.
public enum AIPolicy: String, Codable, CaseIterable, Sendable {
    case allow
    /// The first suggestion asks the user, who answers Allow, Not Now or Never; nothing is sent before the answer.
    case ask
    /// No request is made for the connection's windows.
    case never

    public var title: String {
        switch self {
        case .allow: return "Allow"
        case .ask: return "Ask"
        case .never: return "Never"
        }
    }

    /// Production connections send nothing unless the user allows it; every other connection asks the first time.
    public static func defaultPolicy(for environment: ConnectionEnvironment) -> AIPolicy {
        environment == .production ? .never : .ask
    }
}

extension ConnectionConfig {
    /// The connection's AI policy: the one chosen in the connection form, or the default of its environment.
    /// Setting the environment's default stores nothing, so the policy follows a later environment change.
    public var aiPolicyLevel: AIPolicy {
        get { aiPolicy ?? AIPolicy.defaultPolicy(for: environment) }
        set { aiPolicy = newValue == AIPolicy.defaultPolicy(for: environment) ? nil : newValue }
    }
}

/// Why inline suggestions are off for an editor, or the provider they use.
public enum AIInlineAvailability: Equatable, Sendable {
    case available(AIProviderConfig)
    /// Everything is ready, but the connection's policy is Ask and the user has not answered yet: nothing may be sent.
    case askFirst(AIProviderConfig)
    case aiDisabled
    case inlineDisabled
    case noProvider
    case missingAPIKey
    case policyNever
    /// MongoDB and Redis editors get no suggestions yet.
    case unsupportedLanguage

    /// The provider requests may go to now; nil while the user has not been asked.
    public var provider: AIProviderConfig? {
        if case .available(let provider) = self { return provider }
        return nil
    }

    public var needsConsent: Bool {
        if case .askFirst = self { return true }
        return false
    }

    /// Decides from Settings › AI, the connection's policy and the editor's language. `hasAPIKey` says whether the
    /// active provider has a key stored; it is only asked for providers that need one.
    public static func resolve(settings: AISettings, connection: ConnectionConfig, language: QueryLanguage, hasAPIKey: (UUID) -> Bool) -> AIInlineAvailability {
        guard settings.enabled else { return .aiDisabled }
        guard settings.inlineSuggestions else { return .inlineDisabled }
        guard case .sql = language else { return .unsupportedLanguage }
        let policy = connection.aiPolicyLevel
        guard policy != .never else { return .policyNever }
        // Only a provider that could answer is worth asking the user about.
        guard let provider = settings.activeProvider, provider.validationMessage == nil else { return .noProvider }
        if provider.kind.requiresAPIKey, !hasAPIKey(provider.id) { return .missingAPIKey }
        return policy == .ask ? .askFirst(provider) : .available(provider)
    }
}

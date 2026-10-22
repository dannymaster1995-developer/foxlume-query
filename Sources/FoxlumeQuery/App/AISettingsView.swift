import AppKit
import FoxlumeQueryCore
import SwiftUI

/// Sections of the Settings window that other windows can scroll to.
enum SettingsSection {
    static let ai = "ai"
}

/// Asks the Settings form to scroll to a section.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var target: String?
}

enum AIPrivacyNote {
    /// Shown under Settings › AI; also the wording the README's FAQ follows.
    static let text = """
        Nothing leaves your Mac until you turn on AI features and add a provider. For a suggestion, Foxlume Query \
        sends the active provider only: up to 2,000 characters of the query editor before the cursor and 500 after it, \
        the database engine's name and, when Include schema is on, the names and types of up to the set number of \
        tables and their columns with primary keys, NOT NULL and foreign keys. It never sends row values, query \
        results, connection details, host names or passwords. What the provider does with it is governed by that \
        provider's terms. API keys stay in the macOS Keychain (in portable mode, in the data folder's private \
        credentials file). Each connection has an AI setting: Allow, Ask or Never. New connections ask the first \
        time and send nothing before you answer; Production connections default to Never, and Never sends nothing. \
        MongoDB and Redis editors get no suggestions yet.
        """
}

/// Settings › AI: the switch, the providers, inline suggestion options and what is sent.
struct AISettingsSection: View {
    @Binding var settings: AppSettings
    @State private var editor: AIProviderEditorModel?

    var body: some View {
        Section {
            Toggle("Enable AI features", isOn: $settings.ai.enabled)
                .accessibilityIdentifier("aiEnabled")
            if settings.ai.providers.isEmpty {
                Text("No providers yet. Add one to use inline suggestions.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Provider for suggestions", selection: activeProvider) {
                    ForEach(settings.ai.providers) { provider in
                        Text(provider.displayName).tag(Optional(provider.id))
                    }
                }
                .accessibilityIdentifier("aiActiveProvider")
                ForEach(settings.ai.providers) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                            Text("\(provider.kind.title) · \(provider.model.isEmpty ? "no model" : provider.model)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit…") { editor = AIProviderEditorModel(provider: provider) }
                        Button("Remove") { remove(provider) }
                    }
                }
            }
            Button("Add Provider…") { editor = AIProviderEditorModel(provider: nil) }
                .accessibilityIdentifier("aiAddProvider")
            Toggle("Inline suggestions in the SQL editor", isOn: $settings.ai.inlineSuggestions)
                .accessibilityIdentifier("aiInlineSuggestions")
            Stepper("Suggest after a pause of \(settings.ai.debounceMilliseconds) ms", value: $settings.ai.debounceMilliseconds,
                    in: AISettings.debounceRange, step: 100)
            Toggle("Include schema (table and column names, types and keys)", isOn: $settings.ai.includeSchema)
                .accessibilityIdentifier("aiIncludeSchema")
            if settings.ai.includeSchema {
                Stepper("At most \(settings.ai.maxSchemaTables) tables", value: $settings.ai.maxSchemaTables, in: AISettings.schemaTableRange, step: 5)
            }
            Text("Tab accepts a suggestion, ⌥→ its next word, Esc dismisses it; Query › Suggest with AI (⌥\\) asks at once. A connection's AI setting (Allow, Ask or Never) is in its connection form.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("AI")
        } footer: {
            Text(AIPrivacyNote.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("aiPrivacyNote")
        }
        .sheet(item: $editor) { model in
            AIProviderEditorView(model: model) { save in
                if save {
                    do {
                        try model.save(into: &settings.ai)
                    } catch {
                        model.testState = .failure(error.localizedDescription)
                        return
                    }
                }
                editor = nil
            }
        }
    }

    private var activeProvider: Binding<UUID?> {
        Binding(get: { settings.ai.activeProvider?.id }, set: { settings.ai.activeProviderID = $0 })
    }

    private func remove(_ provider: AIProviderConfig) {
        settings.ai.removeProvider(id: provider.id)
        AppEnvironment.aiKeys.deleteAPIKey(for: provider.id)
    }
}

/// The add / edit form of one provider, with Fetch Models and Test.
@MainActor
final class AIProviderEditorModel: ObservableObject, Identifiable {
    enum TestState: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }

    let id = UUID()
    let isNew: Bool
    @Published var provider: AIProviderConfig
    @Published var apiKey: String
    @Published var models: [AIModelInfo] = []
    @Published var modelsMessage: String?
    @Published var isFetchingModels = false
    @Published var testState: TestState = .idle
    private let keys: AIKeyStore
    private let session: URLSession

    /// A nil `keys` uses the app's key store.
    init(provider: AIProviderConfig?, keys: AIKeyStore? = nil, session: URLSession = .shared) {
        let keys = keys ?? AppEnvironment.aiKeys
        self.isNew = provider == nil
        self.provider = provider ?? AIProviderConfig(name: "", kind: .openAICompatible)
        self.apiKey = provider.flatMap { keys.apiKey(for: $0.id) } ?? ""
        self.keys = keys
        self.session = session
    }

    var validationMessage: String? {
        if let message = provider.validationMessage { return message }
        if provider.kind.requiresAPIKey, apiKey.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the API key." }
        return nil
    }

    func changeKind(to kind: AIProviderKind) {
        guard kind != provider.kind else { return }
        let previous = provider.kind
        if provider.baseURL == previous.defaultBaseURL || provider.baseURL.isEmpty { provider.baseURL = kind.defaultBaseURL }
        if provider.model == previous.defaultModel || provider.model.isEmpty { provider.model = kind.defaultModel }
        provider.kind = kind
        models = []
        testState = .idle
    }

    func apply(_ preset: AIProviderPreset) {
        changeKind(to: preset.kind)
        provider.baseURL = preset.baseURL
        if provider.name.isEmpty || AIProviderPreset.all.contains(where: { $0.name == provider.name }) { provider.name = preset.name }
        models = []
        testState = .idle
    }

    private var client: AIProviderClient {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIProviderClient(provider: provider, apiKey: key.isEmpty ? nil : key, session: session)
    }

    func fetchModels() async {
        isFetchingModels = true
        modelsMessage = nil
        defer { isFetchingModels = false }
        do {
            let list = try await client.listModels()
            models = list
            modelsMessage = list.isEmpty ? "The provider listed no models." : "\(list.count) model\(list.count == 1 ? "" : "s")"
        } catch {
            models = []
            modelsMessage = AIProviderError.from(error).localizedDescription
        }
    }

    /// Sends a tiny request and shows what came back.
    func test() async {
        testState = .running
        let started = Date()
        do {
            let answer = try await client.test()
            let elapsed = Date().timeIntervalSince(started).durationText
            if answer.refused {
                testState = .failure("The model declined the test request.")
            } else if let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                testState = .success("\(provider.model) answered “\(text.prefix(40))” in \(elapsed).")
            } else {
                testState = .success("Connected in \(elapsed), but the model sent an empty answer.")
            }
        } catch {
            testState = .failure(AIProviderError.from(error).localizedDescription)
        }
    }

    /// Stores the provider in `settings` and its key in the key store (an empty key removes it).
    func save(into settings: inout AISettings) throws {
        provider.baseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        try keys.setAPIKey(apiKey, for: provider.id)
        settings.upsert(provider)
    }
}

struct AIProviderEditorView: View {
    @ObservedObject var model: AIProviderEditorModel
    /// True for Add or Save, false for Cancel.
    let onDone: (_ save: Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Type", selection: Binding(get: { model.provider.kind }, set: { model.changeKind(to: $0) })) {
                        ForEach(AIProviderKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("aiProviderKind")
                    if model.provider.kind == .openAICompatible {
                        Menu("Presets") {
                            ForEach(AIProviderPreset.all.filter { $0.kind == .openAICompatible }, id: \.name) { preset in
                                Button("\(preset.name)  ·  \(preset.baseURL)") { model.apply(preset) }
                            }
                        }
                        .accessibilityIdentifier("aiProviderPresets")
                    }
                    TextField("Name", text: $model.provider.name, prompt: Text(model.provider.kind.title))
                        .accessibilityIdentifier("aiProviderName")
                    TextField("Base URL", text: $model.provider.baseURL, prompt: Text(model.provider.kind.defaultBaseURL))
                        .accessibilityIdentifier("aiProviderBaseURL")
                    SecureField("API Key", text: $model.apiKey, prompt: Text(model.provider.kind.requiresAPIKey ? "Required" : "Optional for local servers"))
                        .accessibilityIdentifier("aiProviderKey")
                    HStack {
                        TextField("Model", text: $model.provider.model, prompt: Text(model.provider.kind == .anthropic ? "claude-opus-5-5" : "gpt-4o-mini, llama3.1…"))
                            .accessibilityIdentifier("aiProviderModel")
                        if !model.models.isEmpty {
                            Menu("Choose") {
                                ForEach(model.models) { info in
                                    Button(info.displayName.map { "\($0) (\(info.id))" } ?? info.id) { model.provider.model = info.id }
                                }
                            }
                            .fixedSize()
                        }
                        Button(model.isFetchingModels ? "Fetching…" : "Fetch Models") { Task { await model.fetchModels() } }
                            .disabled(model.isFetchingModels || model.provider.normalizedBaseURL == nil)
                            .accessibilityIdentifier("aiFetchModels")
                    }
                    if let message = model.modelsMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("The key is stored in the macOS Keychain (in portable mode, in the data folder's private credentials file). Test sends one short question to the provider; nothing from your databases.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.testState != .idle {
                    Section { testResult }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button {
                    Task { await model.test() }
                } label: {
                    if model.testState == .running { ProgressView().controlSize(.small) } else { Text("Test") }
                }
                .disabled(model.validationMessage != nil || model.testState == .running)
                .accessibilityIdentifier("aiTestProvider")
                if let message = model.validationMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onDone(false) }
                    .keyboardShortcut(.cancelAction)
                Button(model.isNew ? "Add" : "Save") { onDone(true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.validationMessage != nil)
                    .accessibilityIdentifier("aiSaveProvider")
            }
            .padding(14)
        }
        .frame(width: 520)
        .frame(minHeight: 380)
    }

    @ViewBuilder
    private var testResult: some View {
        switch model.testState {
        case .idle:
            EmptyView()
        case .running:
            Label("Asking the provider…", systemImage: "hourglass")
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
        }
    }
}

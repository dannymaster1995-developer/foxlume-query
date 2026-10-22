import AppKit
import FoxlumeQueryCore

/// Scripted commands for inline AI suggestions.
///
///     aisuggest                       Query › Suggest with AI in the selected query tab, then waits for the answer
///     aiwait [seconds]                waits until the query tab shows a suggestion (or the status reports a failure)
///     aistate                         logs the suggestion on screen, the status line, the Ask prompt and how many
///                                     requests were sent
///     aiprompt [seconds]              waits until the query tab shows the Ask prompt, and logs it
///     aiconsent allow|notnow|never    answers the Ask prompt as its buttons do
///     aisettings                      opens Settings scrolled to the AI section
///     aipolicy allow|never            saves the front workspace's connection with that AI policy
@MainActor
enum AIAutoTest {
    static let commands: Set<String> = ["aisuggest", "aiwait", "aistate", "aisettings", "aipolicy", "aiprompt", "aiconsent"]
}

extension AutoTestRunner {
    func performAI(_ command: String, _ argument: String) async throws {
        let query = workspace?.tabs.selectedTab?.content as? QueryTabViewController
        switch command {
        case "aisuggest":
            guard let query else { throw DatabaseError.unsupported("aisuggest needs a query tab") }
            query.focusEditor()
            query.editorForTesting.textView.suggestInline(nil)
            try await waitForSuggestion(in: query, seconds: 10)
        case "aiwait":
            guard let query else { throw DatabaseError.unsupported("aiwait needs a query tab") }
            try await waitForSuggestion(in: query, seconds: Double(argument) ?? 10)
        case "aistate":
            guard let query else { throw DatabaseError.unsupported("aistate needs a query tab") }
            let ghost = query.inlineSuggestionText.map { "\"" + $0.replacingOccurrences(of: "\n", with: "\\n") + "\"" } ?? "none"
            let status = query.inlineSuggestionStatusText.isEmpty ? "idle" : query.inlineSuggestionStatusText
            let prompt = query.aiConsentPrompt.map { "\"" + $0 + "\"" } ?? "none"
            record("  suggestion: \(ghost); status: \(status); prompt: \(prompt); requests: \(query.editorForTesting.textView.inlineSuggestions.requestCount)")
        case "aiprompt":
            guard let query else { throw DatabaseError.unsupported("aiprompt needs a query tab") }
            try await waitFor(seconds: Double(argument) ?? 10) { query.aiConsentPrompt != nil }
            record("  prompt: \(query.aiConsentPrompt ?? "")")
            try await Task.sleep(nanoseconds: 300_000_000)
        case "aiconsent":
            guard let query else { throw DatabaseError.unsupported("aiconsent needs a query tab") }
            let answers: [String: AIConsentAnswer] = ["allow": .allow, "notnow": .notNow, "never": .never]
            guard let answer = answers[argument] else { throw DatabaseError.unsupported("aiconsent allow|notnow|never") }
            query.answerAIConsent(answer)
            try await Task.sleep(nanoseconds: 300_000_000)
        case "aisettings":
            SettingsWindowController.shared.show(section: SettingsSection.ai)
            try await Task.sleep(nanoseconds: 900_000_000)
        case "aipolicy":
            guard let window = workspace, var config = AppEnvironment.connections.connection(id: window.workspace.config.id) else {
                throw DatabaseError.notConnected
            }
            guard let policy = AIPolicy(rawValue: argument) else { throw DatabaseError.unsupported("aipolicy allow|never") }
            config.aiPolicyLevel = policy
            try AppEnvironment.connections.save(config)
            try await Task.sleep(nanoseconds: 300_000_000)
        default:
            break
        }
    }

    private func waitForSuggestion(in query: QueryTabViewController, seconds: Double) async throws {
        try await waitFor(seconds: seconds) {
            if query.inlineSuggestionText != nil { return true }
            if case .failed = query.inlineSuggestionStatus { return true }
            return false
        }
        // Let the editor draw the grey text before a snapshot.
        try await Task.sleep(nanoseconds: 300_000_000)
    }
}

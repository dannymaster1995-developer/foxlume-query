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
///     aisettings [copilot]            opens Settings scrolled to the AI section (or its GitHub Copilot part)
///     aipolicy allow|never            saves the front workspace's connection with that AI policy
///
/// GitHub Copilot (debug builds run the program in FOXLUME_COPILOT_SERVER, the fqfakelsp stand-in, instead):
///
///     copilot on|off                  turns Copilot on (and AI features, with Copilot as the provider) or off
///     copilotsignin                   Sign in with GitHub, then waits for the device code
///     copilotsignout                  Sign Out
///     copilotwait <state> [seconds]   waits for running, stopped, signedin, signingin or signedout
///     copilotstate                    logs the server and sign-in state, the open documents and what would have been
///                                     opened in the browser or copied
///     copilotmessage [seconds]        waits for a server message panel and logs its text and buttons
///     copilotanswer <title>           answers the open message panel with that button
@MainActor
enum AIAutoTest {
    static let commands: Set<String> = ["aisuggest", "aiwait", "aistate", "aisettings", "aipolicy", "aiprompt", "aiconsent",
                                        "copilot", "copilotsignin", "copilotsignout", "copilotwait", "copilotstate",
                                        "copilotmessage", "copilotanswer"]
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
            SettingsWindowController.shared.show(section: argument == "copilot" ? SettingsSection.copilot : SettingsSection.ai)
            try await Task.sleep(nanoseconds: 900_000_000)
        case "copilot", "copilotsignin", "copilotsignout", "copilotwait", "copilotstate", "copilotmessage", "copilotanswer":
            try await performCopilot(command, argument)
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

    private func performCopilot(_ command: String, _ argument: String) async throws {
        let service = CopilotEnvironment.service
        switch command {
        case "copilot":
            var settings = AppEnvironment.settings
            switch argument {
            case "on":
                settings.ai.enabled = true
                settings.ai.setCopilotEnabled(true)
            case "off":
                settings.ai.setCopilotEnabled(false)
            default:
                throw DatabaseError.unsupported("copilot on|off")
            }
            AppEnvironment.settings = settings
            try await Task.sleep(nanoseconds: 300_000_000)
        case "copilotsignin":
            service.signIn()
            try await waitFor(seconds: 10) {
                switch service.authState {
                case .signingIn, .signedIn: return true
                default: return service.authError != nil
                }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        case "copilotsignout":
            await service.signOut()
            try await Task.sleep(nanoseconds: 300_000_000)
        case "copilotwait":
            let parts = argument.split(separator: " ").map(String.init)
            let seconds = parts.count > 1 ? Double(parts[1]) ?? 10 : 10
            let check: () -> Bool
            switch parts.first ?? "" {
            case "running": check = { service.serverState == .running }
            case "stopped": check = { service.serverState == .stopped }
            case "signedin": check = { service.isSignedIn }
            case "signedout": check = { service.authState == .signedOut }
            case "signingin": check = { if case .signingIn = service.authState { return true } else { return false } }
            default: throw DatabaseError.unsupported("copilotwait running|stopped|signedin|signingin|signedout [seconds]")
            }
            try await waitFor(seconds: seconds, check)
            try await Task.sleep(nanoseconds: 300_000_000)
        case "copilotstate":
            let note = service.statusNote.map { "\($0.kind.rawValue) \"\($0.message)\"" } ?? "none"
            record("  copilot server: \(service.serverState); auth: \(service.authState); note: \(note); documents: \(service.openDocumentCount)"
                   + "; opened: \(CopilotEnvironment.recordedURLs.map(\.absoluteString)); copied: \(CopilotEnvironment.recordedClipboard)"
                   + (service.authError.map { "; error: \($0)" } ?? ""))
        case "copilotmessage":
            try await waitFor(seconds: Double(argument) ?? 10) { !CopilotMessagePanel.open.isEmpty }
            if let panel = CopilotMessagePanel.open.first {
                record("  message: \"\(panel.message.text)\"; buttons: \(panel.actionTitles)")
            }
        case "copilotanswer":
            guard let panel = CopilotMessagePanel.open.first else { throw DatabaseError.unsupported("copilotanswer needs an open message") }
            panel.answer(argument.isEmpty ? nil : argument)
            try await Task.sleep(nanoseconds: 300_000_000)
        default:
            break
        }
    }
}

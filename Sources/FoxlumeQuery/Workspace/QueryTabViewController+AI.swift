import AppKit
import FoxlumeQueryCore

/// Inline AI suggestions in a query tab: SQL engines only, and only while Settings › AI and the connection's AI
/// policy allow them. With the policy Ask, the first request shows a prompt above the editor instead.
extension QueryTabViewController: InlineSuggestionHost {
    func makeInlineSuggestionGate() -> InlineSuggestionGate {
        let workspace = self.workspace
        return InlineSuggestionGate(
            cache: inlineSourceCache, consent: workspace.aiConsent, language: workspace.queryLanguage,
            connection: { workspace.config },
            savePolicy: { policy in
                guard var saved = AppEnvironment.connections.connection(id: workspace.config.id) else { return }
                saved.aiPolicyLevel = policy
                try AppEnvironment.connections.save(saved)
                // The store's notification updates the workspace; make sure it has before the next request.
                workspace.adoptSavedEnvironment()
            }
        )
    }

    /// Wires the Ask prompt to the gate; called once from loadView.
    func configureConsentBar() {
        aiGate.onPromptChange = { [weak self] showing in
            guard let self else { return }
            if showing {
                self.aiConsentBar.show(connectionName: self.aiGate.connectionName)
            } else {
                self.aiConsentBar.isHidden = true
            }
        }
        aiGate.onAllowed = { [weak self] manual in
            guard let textView = self?.editorForTesting.textView else { return }
            if manual { textView.inlineSuggestions.requestNow() } else { textView.inlineSuggestions.scheduleAfterEdit() }
        }
        aiConsentBar.onAnswer = { [weak self] answer in self?.answerAIConsent(answer) }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(aiConsentContextDidChange(_:)), name: ConnectionWorkspace.metadataDidChange, object: workspace)
        center.addObserver(self, selector: #selector(aiConsentContextDidChange(_:)), name: AISessionConsent.didChangeNotification, object: workspace.aiConsent)
        center.addObserver(self, selector: #selector(aiConsentContextDidChange(_:)), name: SettingsStore.didChangeNotification, object: nil)
    }

    func answerAIConsent(_ answer: AIConsentAnswer) {
        do {
            try aiGate.answer(answer)
        } catch {
            Alerts.showError(error, title: "Could not save the connection", in: view.window)
        }
    }

    @objc private func aiConsentContextDidChange(_ notification: Notification) {
        aiGate.refresh()
    }

    var inlineSuggestionSource: InlineSuggestionSource? {
        aiGate.source
    }

    var inlineSuggestionAwaitsConsent: Bool {
        aiGate.awaitsConsent
    }

    func inlineSuggestionRequestConsent(manual: Bool) {
        aiGate.requestConsent(manual: manual)
    }

    var inlineSuggestionDebounce: TimeInterval {
        AppEnvironment.settings.ai.debounceInterval
    }

    /// The schema comes from what the sidebar and completion already loaded; nothing is fetched for a suggestion.
    func inlineSuggestionRequest(text: String, caret: Int, manual: Bool) -> InlineSuggestionRequest {
        let settings = AppEnvironment.settings.ai
        var schema: [AISchemaTable]?
        if settings.includeSchema {
            let tables = workspace.tables.filter { $0.kind != .keyspace && $0.kind != .systemTable }.map(\.ref)
            schema = AISchemaContext.tables(
                tables: tables, structures: workspace.cachedStructures, currentSchema: workspace.currentSchema,
                editorText: text, limit: settings.schemaTableLimit
            )
        }
        return InlineSuggestionRequest(text: text, caret: caret, dialect: workspace.kind.displayName, schema: schema, manual: manual)
    }

    func inlineSuggestionStatusDidChange(_ status: InlineSuggestionStatus) {
        aiStatusView.update(status)
    }

    // MARK: Scripted checks

    var inlineSuggestionText: String? { editorForTesting.textView.inlineSuggestions.ghost?.text }
    var inlineSuggestionStatus: InlineSuggestionStatus { editorForTesting.textView.inlineSuggestions.status }
    var inlineSuggestionStatusText: String { aiStatusView.text }
    var aiConsentPrompt: String? { aiConsentBar.isHidden ? nil : aiConsentBar.text }
}

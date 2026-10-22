import AppKit
import FoxlumeQueryCore

/// Keeps the inline suggestion source of one editor and makes a new one only when what it depends on changes:
/// Settings › AI, a stored key, the connection's AI policy or the editor's language.
@MainActor
final class InlineSuggestionSourceCache {
    private struct Key: Equatable {
        var settings: AISettings
        var policy: AIPolicy
        var language: QueryLanguage
        var keysVersion: Int
    }

    var keys: AIKeyStore
    var session: URLSession
    var settings: @MainActor () -> AISettings
    private var key: Key?
    private var source: InlineSuggestionSource?
    private var cachedAvailability: AIInlineAvailability = .aiDisabled
    private var keysVersion = 0
    private var observer: NSObjectProtocol?

    /// Nil arguments use the app's key store and Settings › AI.
    init(keys: AIKeyStore? = nil, session: URLSession = .shared, settings: (@MainActor () -> AISettings)? = nil) {
        self.keys = keys ?? AppEnvironment.aiKeys
        self.session = session
        self.settings = settings ?? { AppEnvironment.settings.ai }
        observer = NotificationCenter.default.addObserver(forName: AIKeyStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keysVersion += 1 }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Nil when nothing may be sent for `connection`'s editors in `language` (including Ask before the answer).
    func source(for connection: ConnectionConfig, language: QueryLanguage) -> InlineSuggestionSource? {
        update(for: connection, language: language)
        return source
    }

    func availability(for connection: ConnectionConfig, language: QueryLanguage) -> AIInlineAvailability {
        update(for: connection, language: language)
        return cachedAvailability
    }

    private func update(for connection: ConnectionConfig, language: QueryLanguage) {
        let current = Key(settings: settings(), policy: connection.aiPolicyLevel, language: language, keysVersion: keysVersion)
        guard current != key else { return }
        key = current
        cachedAvailability = InlineSuggestionSources.availability(settings: current.settings, connection: connection, language: language, keys: keys)
        source = cachedAvailability.provider.map { ChatInlineSuggestionSource(provider: $0, apiKey: keys.apiKey(for: $0.id), session: session) }
    }
}

/// The editor toolbar's AI line: a spinner while a suggestion is asked for, and a one-line error with a way to
/// Settings › AI after a provider failure.
final class InlineSuggestionStatusView: NSStackView {
    private let spinner = NSProgressIndicator()
    private let label = UI.label("", size: 11, color: .secondaryLabelColor)
    private lazy var settingsButton: NSButton = {
        let button = NSButton(title: "AI Settings…", target: self, action: #selector(openSettings(_:)))
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.setAccessibilityIdentifier("aiStatusSettings")
        return button
    }()

    private(set) var status: InlineSuggestionStatus = .idle

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 4
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("aiStatus")
        addArrangedSubview(spinner)
        addArrangedSubview(label)
        addArrangedSubview(settingsButton)
        update(.idle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The label's text, for tests and scripted checks.
    var text: String { label.stringValue }

    func update(_ status: InlineSuggestionStatus) {
        self.status = status
        switch status {
        case .idle:
            spinner.stopAnimation(nil)
            label.stringValue = ""
            label.toolTip = nil
            settingsButton.isHidden = true
            isHidden = true
        case .requesting:
            isHidden = false
            spinner.startAnimation(nil)
            label.stringValue = "AI…"
            label.textColor = .secondaryLabelColor
            label.toolTip = "Asking the AI provider for a suggestion"
            settingsButton.isHidden = true
        case .failed(let message):
            isHidden = false
            spinner.stopAnimation(nil)
            label.stringValue = "AI: " + message
            label.textColor = .systemOrange
            label.toolTip = message
            settingsButton.isHidden = false
        }
    }

    @objc private func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(section: SettingsSection.ai)
    }
}

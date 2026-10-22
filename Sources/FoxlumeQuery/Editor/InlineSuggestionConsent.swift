import AppKit
import FoxlumeQueryCore

/// A workspace's answer of Not Now to the Ask prompt: no requests and no prompt again until the workspace is reopened.
@MainActor
final class AISessionConsent {
    static let didChangeNotification = Notification.Name("FoxlumeQuery.AISessionConsent.didChange")

    private(set) var declined = false

    func decline() {
        guard !declined else { return }
        declined = true
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

/// The user's answer to "Allow AI suggestions for …?".
enum AIConsentAnswer {
    /// Stored on the connection as Allow.
    case allow
    /// Nothing for this workspace until it is reopened; the connection keeps Ask.
    case notNow
    /// Stored on the connection as Never.
    case never
}

/// Decides, for one editor, whether suggestions may be asked for, must wait for the user's answer (Ask), or are off;
/// and keeps the Ask prompt's state. Nothing is sent while the answer is pending.
@MainActor
final class InlineSuggestionGate {
    let cache: InlineSuggestionSourceCache
    let consent: AISessionConsent
    var language: QueryLanguage
    private let connection: () -> ConnectionConfig
    private let savePolicy: (AIPolicy) throws -> Void
    /// Shows or hides the prompt.
    var onPromptChange: ((Bool) -> Void)?
    /// After Allow: whether the prompt was opened by the Suggest command, so the editor can ask at once.
    var onAllowed: ((_ manual: Bool) -> Void)?
    private(set) var isPrompting = false
    private var promptWasManual = false

    init(cache: InlineSuggestionSourceCache, consent: AISessionConsent, language: QueryLanguage,
         connection: @escaping () -> ConnectionConfig, savePolicy: @escaping (AIPolicy) throws -> Void) {
        self.cache = cache
        self.consent = consent
        self.language = language
        self.connection = connection
        self.savePolicy = savePolicy
    }

    /// Nil while the policy is Never, Ask is unanswered or Not Now was chosen, and whenever Settings › AI is off.
    var source: InlineSuggestionSource? {
        cache.source(for: connection(), language: language)
    }

    var awaitsConsent: Bool {
        !consent.declined && cache.availability(for: connection(), language: language).needsConsent
    }

    var connectionName: String { connection().displayName }

    /// Opens the prompt (once); nothing is sent.
    func requestConsent(manual: Bool) {
        guard awaitsConsent else { return }
        promptWasManual = promptWasManual || manual
        guard !isPrompting else { return }
        isPrompting = true
        onPromptChange?(true)
    }

    func answer(_ answer: AIConsentAnswer) throws {
        let manual = promptWasManual
        switch answer {
        case .allow: try savePolicy(.allow)
        case .never: try savePolicy(.never)
        case .notNow: consent.decline()
        }
        closePrompt()
        if answer == .allow { onAllowed?(manual) }
    }

    /// The policy, Settings › AI or the session's answer changed elsewhere (another tab, the connection form): a prompt
    /// that is no longer needed goes, and so does a source that may no longer send.
    func refresh() {
        // Also makes the cache drop a source that may no longer send (its Copilot document is closed then).
        _ = cache.availability(for: connection(), language: language)
        if isPrompting, !awaitsConsent { closePrompt() }
    }

    private func closePrompt() {
        promptWasManual = false
        guard isPrompting else { return }
        isPrompting = false
        onPromptChange?(false)
    }
}

/// The non-modal Ask prompt above the query editor. Its buttons never take keyboard focus, so typing goes on.
final class AIConsentBar: NSView {
    private let label = UI.label("", size: 12, color: .labelColor)
    private let detail = UI.label("Nothing is sent until you answer.", size: 11, color: .secondaryLabelColor)
    var onAnswer: ((AIConsentAnswer) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityIdentifier("aiConsentBar")
        setAccessibilityRole(.group)
        let icon = NSImageView(image: Theme.image("sparkles", "AI") ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let allow = button("Allow", #selector(allow(_:)), id: "aiConsentAllow")
        let notNow = button("Not Now", #selector(notNow(_:)), id: "aiConsentNotNow")
        let never = button("Never", #selector(never(_:)), id: "aiConsentNever")
        let info = button("What is sent?", #selector(showSettings(_:)), id: "aiConsentInfo")
        info.bezelStyle = .inline
        let row = UI.hstack([icon, label, detail, UI.flexibleSpace(), info, never, notNow, allow], spacing: 8)
        let line = UI.separator()
        addSubview(line)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubviewFilling(row, insets: NSEdgeInsets(top: 6, left: 10, bottom: 7, right: 10))
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(connectionName: String) {
        label.stringValue = "Allow AI suggestions for “\(connectionName)”?"
        isHidden = false
    }

    var text: String { label.stringValue }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    private func button(_ title: String, _ action: Selector, id: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.refusesFirstResponder = true
        button.setAccessibilityIdentifier(id)
        return button
    }

    @objc private func allow(_ sender: Any?) { onAnswer?(.allow) }
    @objc private func notNow(_ sender: Any?) { onAnswer?(.notNow) }
    @objc private func never(_ sender: Any?) { onAnswer?(.never) }

    @objc private func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(section: SettingsSection.aiForActiveProvider)
    }
}

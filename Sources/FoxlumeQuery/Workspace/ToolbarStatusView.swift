import AppKit
import FoxlumeQueryCore

/// Center toolbar pill: environment, engine and version, database, latency.
@MainActor
final class ToolbarStatusView: NSView {
    private let environmentBadge = PaddedLabel()
    private let engineLabel = UI.label("", size: 12, color: .secondaryLabelColor)
    private let betaBadge = PaddedLabel()
    private let databaseIcon = NSImageView()
    private let databaseLabel = UI.label("", size: 12, weight: .semibold)
    private let lockIcon = NSImageView()
    private let latencyLabel = UI.label("", size: 11, color: .tertiaryLabelColor)
    private let activity = NSProgressIndicator()
    /// "Reconnecting…" or "Disconnected", shown instead of the latency.
    private let stateLabel = UI.label("", size: 11, weight: .semibold)
    private lazy var reconnectButton: NSButton = {
        let button = NSButton(title: "Reconnect", target: self, action: #selector(reconnectClicked(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.setAccessibilityIdentifier("reconnect")
        return button
    }()
    var onReconnect: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        databaseIcon.image = Theme.image("cylinder", "Database", size: 11)
        databaseIcon.contentTintColor = .secondaryLabelColor
        lockIcon.image = Theme.image("lock.fill", "Read-only", size: 10)
        lockIcon.contentTintColor = .secondaryLabelColor
        lockIcon.toolTip = "Read-only connection"
        engineLabel.font = Theme.monospaced(11)
        latencyLabel.font = Theme.monospaced(10)
        activity.style = .spinning
        activity.controlSize = .small
        activity.isDisplayedWhenStopped = false
        betaBadge.text = "BETA"
        betaBadge.tint = .systemOrange
        betaBadge.toolTip = "Support for this engine is in beta"
        let stack = UI.hstack([environmentBadge, engineLabel, betaBadge, databaseIcon, databaseLabel, lockIcon, activity, latencyLabel, stateLabel, reconnectButton], spacing: 6)
        stateLabel.isHidden = true
        reconnectButton.isHidden = true
        addSubviewFilling(stack, insets: NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 10))
        setAccessibilityIdentifier("connectionStatus")
        updateLayerColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        }
    }

    func update(with workspace: ConnectionWorkspace) {
        let config = workspace.config
        let environment = config.environment == .none ? nil : config.environment
        environmentBadge.isHidden = environment == nil
        if let environment {
            environmentBadge.text = environment.displayName.uppercased()
            environmentBadge.tint = Theme.color(for: environment)
        }
        engineLabel.stringValue = "\(config.kind.displayName) \(workspace.serverVersion)"
        betaBadge.isHidden = !config.kind.isBeta
        let database = config.kind.isFileBased ? (config.filePath as NSString).lastPathComponent : (workspace.currentDatabase ?? config.database)
        databaseLabel.stringValue = workspace.currentSchema.map { workspace.kind.supportsSchemas ? "\(database) · \($0)" : database } ?? database
        let level = SafeModeGate.level(for: config)
        lockIcon.isHidden = level == .silent
        lockIcon.image = Theme.image(level.symbolName, level.title, size: 10)
        lockIcon.contentTintColor = level.strictness >= SafeModeLevel.safeMode.strictness ? .systemRed : (level == .silent ? .secondaryLabelColor : .systemOrange)
        lockIcon.toolTip = "Safe Mode: \(level.title). \(level.summary)"
        latencyLabel.stringValue = workspace.latency?.durationText ?? ""
        var busy = workspace.runningStatements > 0
        switch workspace.connectionState {
        case .connected:
            stateLabel.isHidden = true
            reconnectButton.isHidden = true
            latencyLabel.isHidden = false
            toolTip = config.subtitle
        case .reconnecting:
            busy = true
            stateLabel.stringValue = "Reconnecting…"
            stateLabel.textColor = .systemOrange
            stateLabel.isHidden = false
            reconnectButton.isHidden = true
            latencyLabel.isHidden = true
            toolTip = "Reconnecting to \(config.subtitle)"
        case .lost(let reason):
            stateLabel.stringValue = reason == "Disconnected." ? "Disconnected" : "Connection lost"
            stateLabel.textColor = .systemRed
            stateLabel.isHidden = false
            reconnectButton.isHidden = false
            latencyLabel.isHidden = true
            toolTip = reason
        }
        if busy {
            activity.startAnimation(nil)
        } else {
            activity.stopAnimation(nil)
        }
    }

    @objc private func reconnectClicked(_ sender: Any?) {
        onReconnect?()
    }
}

/// Small rounded label used for environment badges.
final class PaddedLabel: NSView {
    private let label = UI.label("", size: 10, weight: .bold)

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    var tint: NSColor = .systemGreen {
        didSet { updateColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        addSubviewFilling(label, insets: NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6))
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        label.textColor = tint
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
        }
    }
}

import AppKit
import FoxlumeQueryCore

/// The translucent band in the environment's color behind a window's titlebar and toolbar, so a Production window
/// stands out at a glance (Settings › Appearance › Tint the window toolbar). It lives in the titlebar view, under the
/// toolbar items and over the system material, so it spans the whole width (sidebar included) and moves with the
/// toolbar into full screen. It follows the window's appearance, active state and the setting by itself.
@MainActor
final class EnvironmentTintBand: NSView {
    static let didChangeActiveOverride = Notification.Name("FoxlumeQuery.EnvironmentTintBand.didChangeActiveOverride")

    /// Scripted runs keep the app in the background, so every window looks inactive; this forces one look. Nil
    /// follows the window.
    static var activeOverride: Bool? {
        didSet { NotificationCenter.default.post(name: didChangeActiveOverride, object: nil) }
    }

    var environment: ConnectionEnvironment = .none {
        didSet { if environment != oldValue { refresh() } }
    }

    /// The tint shown now; nil when the band is clear.
    private(set) var tint: EnvironmentTint?
    /// Called with the accent color (nil for none) whenever the tint changes, for the tab strip's line.
    var onAccentChange: ((NSColor?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
        setAccessibilityIdentifier("environmentTint")
        for name in [SettingsStore.didChangeNotification, Self.didChangeActiveOverride, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(inputsChanged), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Puts the band into `window`'s titlebar. Returns false when the window has no titlebar to tint.
    @discardableResult
    func install(in window: NSWindow) -> Bool {
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return false }
        removeFromSuperview()
        frame = titlebar.bounds
        // Above the titlebar's own material, below the toolbar and the window buttons.
        if let material = titlebar.subviews.last(where: { $0 is NSVisualEffectView }) {
            titlebar.addSubview(self, positioned: .above, relativeTo: material)
        } else {
            titlebar.addSubview(self, positioned: .below, relativeTo: titlebar.subviews.first)
        }
        refresh()
        return true
    }

    // Clicks, drags and double-clicks belong to the titlebar.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        if let window {
            center.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: window)
            center.removeObserver(self, name: NSWindow.didResignMainNotification, object: window)
        }
        if let newWindow {
            center.addObserver(self, selector: #selector(inputsChanged), name: NSWindow.didBecomeMainNotification, object: newWindow)
            center.addObserver(self, selector: #selector(inputsChanged), name: NSWindow.didResignMainNotification, object: newWindow)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    @objc private func inputsChanged() {
        refresh()
    }

    /// Whether the window counts as active: the main window of the active app. A sheet keeps its parent active.
    var isWindowActive: Bool {
        if let override = Self.activeOverride { return override }
        guard let window else { return false }
        return NSApp.isActive && (window.isMainWindow || window.isKeyWindow)
    }

    func refresh() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let enabled = AppEnvironment.settings.tintsToolbar(for: environment)
        let next = EnvironmentTint.tint(for: environment, enabled: enabled, dark: dark, active: isWindowActive)
        let changed = next != tint
        tint = next
        layer?.backgroundColor = next.map { Self.nsColor($0.band).cgColor }
        isHidden = next == nil
        if changed { onAccentChange?(next.map { Self.nsColor($0.accent) }) }
    }

    static func nsColor(_ color: RGBAColor) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

/// The environment badge at the trailing end of a titlebar without a toolbar, such as Server Activity's.
@MainActor
final class EnvironmentBadgeAccessory: NSTitlebarAccessoryViewController {
    private let badge = PaddedLabel()

    var environment: ConnectionEnvironment = .none {
        didSet { update() }
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 110, height: 28))
        badge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            badge.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        badge.setAccessibilityIdentifier("environmentBadge")
        view = container
        layoutAttribute = .trailing
        update()
    }

    var badgeText: String? { isHidden ? nil : badge.text }

    private func update() {
        guard isViewLoaded else { return }
        isHidden = environment == .none
        badge.text = environment.displayName.uppercased()
        badge.tint = Theme.color(for: environment)
        badge.toolTip = "\(environment.displayName) connection"
    }
}

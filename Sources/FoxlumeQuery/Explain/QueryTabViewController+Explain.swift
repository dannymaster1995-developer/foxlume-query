import AppKit
import FoxlumeQueryCore

/// Query › Explain (⌥⌘E) and Explain Analyze (⌃⌘E) for the selection or the statement at the caret.
///
/// Explain only plans the statement, so Safe Mode treats it as a read and read-only connections allow it.
/// Explain Analyze runs it: a statement that writes asks first through Safe Mode, runs inside a transaction that is
/// rolled back on PostgreSQL, and is refused on the other engines and on read-only connections.
extension QueryTabViewController {
    @objc func explainQuery(_ sender: Any?) {
        explain(.plan)
    }

    @objc func explainAnalyzeQuery(_ sender: Any?) {
        explain(.analyze)
    }

    func explain(_ mode: ExplainMode) {
        guard !isRunning else { return NSSound.beep() }
        guard let statement = currentStatement() else { return NSSound.beep() }
        let request: ExplainRequest
        do {
            request = try workspace.explainRequest(for: statement, mode: mode)
        } catch {
            return showExplainRefusal(error)
        }
        SafeModeGate.authorize(
            config: workspace.config,
            statements: [request.statement],
            writes: request.isWrite,
            action: request.isWrite ? "Explain Analyze a statement that changes data" : "\(mode.title) 1 statement",
            // Only when the level asks anyway, so a Silent connection is not stopped for a write that is rolled back.
            extraDetail: SafeModeGate.level(for: workspace.config).gates(writes: request.isWrite) ? request.safeModeDetail : nil,
            in: view.window
        ) { [weak self] confirmed in
            if confirmed { self?.runExplain(request) }
        }
    }

    func canExplain(_ mode: ExplainMode) -> Bool {
        guard !isRunning else { return false }
        let availability = workspace.explainAvailability
        return mode == .plan ? availability.plan : availability.analyze
    }

    /// A pull-down with both commands where the engine has Explain Analyze, a plain button where it has only Explain,
    /// and nothing for Redis.
    func makeExplainControl() -> NSButton {
        let availability = workspace.explainAvailability
        let control: NSButton
        if availability.analyze {
            let popup = NSPopUpButton(frame: .zero, pullsDown: true)
            popup.bezelStyle = .rounded
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popup.translatesAutoresizingMaskIntoConstraints = false
            let title = NSMenuItem(title: "Explain", action: nil, keyEquivalent: "")
            title.image = Theme.image("list.bullet.indent", "Explain")
            popup.menu?.addItem(title)
            for (itemTitle, action) in [("Explain", #selector(explainQuery(_:))), ("Explain Analyze", #selector(explainAnalyzeQuery(_:)))] {
                let item = NSMenuItem(title: itemTitle, action: action, keyEquivalent: "")
                item.target = self
                popup.menu?.addItem(item)
            }
            popup.toolTip = "Explain shows the plan (⌥⌘E); Explain Analyze runs the statement and measures it (⌃⌘E)"
            control = popup
        } else {
            control = UI.button("Explain", symbol: "list.bullet.indent", target: self, action: #selector(explainQuery(_:)))
            control.toolTip = "Show the plan of the selection or the statement at the cursor (⌥⌘E)"
        }
        control.setAccessibilityIdentifier("explainQuery")
        control.isHidden = !availability.plan
        return control
    }

    func updateExplainControl() {
        explainControl.isEnabled = !isRunning
    }
}

extension QueryTabViewController: NSMenuItemValidation {
    /// Only the Explain commands depend on the engine; everything else the tab handles stays enabled as before.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(explainQuery(_:)):
            return canExplain(.plan)
        case #selector(explainAnalyzeQuery(_:)):
            menuItem.toolTip = workspace.explainAvailability.analyzeNote
            return canExplain(.analyze)
        default:
            return true
        }
    }
}

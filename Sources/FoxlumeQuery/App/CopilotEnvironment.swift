import AppKit
import FoxlumeQueryCore

/// The app's one GitHub Copilot service: fed Settings › AI from launch on, stopped at quit. Its server messages show
/// in non-modal panels; the sign-in page opens in the browser and the device code goes to the clipboard.
@MainActor
enum CopilotEnvironment {
    static let service: CopilotService = makeService()
    private static var observer: NSObjectProtocol?

    #if DEBUG
    /// Debug builds only: `FOXLUME_COPILOT_SERVER=/path/to/fqfakelsp` runs that program instead of downloading the real
    /// language server, and the sign-in page and device code are only recorded (scripted UI checks).
    static var debugServer: URL? {
        ProcessInfo.processInfo.environment["FOXLUME_COPILOT_SERVER"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }
    #endif

    /// What a debug run with the stand-in server would have opened or copied.
    private(set) static var recordedURLs: [URL] = []
    private(set) static var recordedClipboard: [String] = []

    static let installer = CopilotInstaller()

    private static func makeService() -> CopilotService {
        var executable: @Sendable (_ progress: @escaping @Sendable (Double?) -> Void) async throws -> URL = { progress in
            try await installer.ensureInstalled(progress: progress)
        }
        var recordOnly = false
        #if DEBUG
        if let debugServer {
            executable = { _ in debugServer }
            recordOnly = true
        }
        #endif
        let configuration = CopilotService.Configuration(
            executable: executable,
            environment: ToolProcess.environment(adding: [:]),
            clientVersion: AppEnvironment.appVersion
        )
        let service = CopilotService(configuration: configuration)
        service.showMessage = { message in await CopilotMessagePanel.present(message) }
        service.openURL = { url in
            if recordOnly {
                recordedURLs.append(url)
                return true
            }
            return NSWorkspace.shared.open(url)
        }
        service.copyToClipboard = { text in
            if recordOnly {
                recordedClipboard.append(text)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        return service
    }

    /// At launch: applies Settings › AI now (a Copilot provider of suggestions starts the server and checks the
    /// sign-in) and on every change.
    static func activate() {
        service.apply(AppEnvironment.settings.ai)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: SettingsStore.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { service.apply(AppEnvironment.settings.ai) }
        }
    }

    /// At quit: the language server's process group ends with the app.
    static func shutdown() {
        service.terminateNow()
    }
}

/// A server message (`window/showMessageRequest`, such as an account or billing notice) in a small floating panel with
/// one button per action. Non-modal: the app goes on working while it is open.
final class CopilotMessagePanel: NSPanel {
    /// Panels on screen, for tests and scripted checks.
    @MainActor private(set) static var open: [CopilotMessagePanel] = []

    let message: CopilotService.Message
    private var continuation: CheckedContinuation<String?, Never>?

    @MainActor
    static func present(_ message: CopilotService.Message) async -> String? {
        await withCheckedContinuation { continuation in
            let panel = CopilotMessagePanel(message: message)
            panel.continuation = continuation
            open.append(panel)
            panel.center()
            panel.orderFrontRegardless()
        }
    }

    @MainActor
    init(message: CopilotService.Message) {
        self.message = message
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120), styleMask: [.titled, .closable, .utilityWindow],
                   backing: .buffered, defer: false)
        title = "GitHub Copilot"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        setAccessibilityIdentifier("copilotMessagePanel")
        let icon = NSImageView(image: NSImage(systemSymbolName: message.type <= 1 ? "exclamationmark.octagon" : message.type == 2 ? "exclamationmark.triangle" : "info.circle",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = message.type <= 1 ? .systemRed : message.type == 2 ? .systemOrange : .secondaryLabelColor
        let text = NSTextField(wrappingLabelWithString: message.text)
        text.isSelectable = true
        text.preferredMaxLayoutWidth = 340
        text.setAccessibilityIdentifier("copilotMessageText")
        var buttons: [NSView] = [UI.flexibleSpace()]
        let titles = message.actions.isEmpty ? ["OK"] : message.actions
        for (index, title) in titles.enumerated() {
            let button = NSButton(title: title, target: nil, action: nil)
            button.target = self
            button.action = #selector(choose(_:))
            button.tag = index
            if index == titles.count - 1 { button.keyEquivalent = "\r" }
            buttons.append(button)
        }
        let top = UI.hstack([icon, text], spacing: 10)
        top.alignment = .top
        let stack = NSStackView(views: [top, UI.hstack(buttons, spacing: 8)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        let content = NSView()
        content.addSubviewFilling(stack, insets: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
        contentView = content
        stack.arrangedSubviews.last?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// The button titles shown.
    var actionTitles: [String] { message.actions.isEmpty ? ["OK"] : message.actions }

    @MainActor @objc private func choose(_ sender: NSButton) {
        answer(message.actions.indices.contains(sender.tag) ? message.actions[sender.tag] : nil)
    }

    /// Closes the panel with `action` as the answer (nil: dismissed).
    @MainActor
    func answer(_ action: String?) {
        let continuation = self.continuation
        self.continuation = nil
        Self.open.removeAll { $0 === self }
        orderOut(nil)
        continuation?.resume(returning: action)
    }

    override func close() {
        MainActor.assumeIsolated { answer(nil) }
        super.close()
    }
}

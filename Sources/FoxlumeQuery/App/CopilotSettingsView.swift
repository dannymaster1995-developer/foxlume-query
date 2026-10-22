import AppKit
import FoxlumeQueryCore
import SwiftUI

enum CopilotPrivacyNote {
    /// Shown under Settings › AI › GitHub Copilot; also the wording the README's FAQ follows.
    static let text = """
        GitHub Copilot needs a GitHub account with a Copilot subscription (Copilot Free works). Turning it on downloads \
        GitHub's Copilot language server (\(CopilotRelease.version), MIT) from npm (once per version), checks its checksums and runs it \
        on your Mac. For a suggestion, Foxlume Query gives it the whole text of the query tab, not only the text around \
        the cursor, under a neutral placeholder file name, with comment lines at the top naming \
        the database engine and, when Include schema is on, the same table and column names, types and keys other \
        providers get; the language server sends this to GitHub, and GitHub's Copilot terms apply. Foxlume Query never \
        gives it row values, query results, connection details, host names or passwords. Usage telemetry is off unless \
        you turn it on. Your GitHub sign-in is kept by the language server, not by Foxlume Query. Each connection's AI \
        setting (Allow, Ask or Never) applies to Copilot too, and nothing is sent while AI features or Copilot are off.
        """
}

/// The Copilot section's view of `CopilotService`: refreshed whenever the service changes.
@MainActor
final class CopilotSettingsModel: ObservableObject {
    let service: CopilotService
    @Published private(set) var serverState: CopilotService.ServerState
    @Published private(set) var authState: CopilotService.AuthState
    @Published private(set) var statusNote: CopilotService.StatusNote?
    @Published private(set) var authError: String?
    private var observer: NSObjectProtocol?

    init(service: CopilotService? = nil) {
        let service = service ?? CopilotEnvironment.service
        self.service = service
        serverState = service.serverState
        authState = service.authState
        statusNote = service.statusNote
        authError = service.authError
        observer = NotificationCenter.default.addObserver(forName: CopilotService.didChangeNotification, object: service, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        serverState = service.serverState
        authState = service.authState
        statusNote = service.statusNote
        authError = service.authError
    }

    /// The language server line.
    var serverText: String {
        switch serverState {
        case .stopped: return "Not running; it starts with the next suggestion or sign-in."
        case .installing(let fraction?): return "Downloading the language server… \(Int((fraction * 100).rounded())) %"
        case .installing(nil): return "Downloading the language server…"
        case .starting: return "Starting the language server…"
        case .running: return "Language server \(CopilotRelease.version) running."
        case .failed(let message): return message
        }
    }

    var serverFailed: Bool {
        if case .failed = serverState { return true }
        return false
    }

    /// The sign-in line.
    var authText: String { Self.authText(authState) }

    static func authText(_ state: CopilotService.AuthState) -> String {
        switch state {
        case .unknown: return "Sign-in not checked yet."
        case .signedOut: return "Not signed in."
        case .signingIn(let code, let page):
            return "Enter the code \(code) at \(page) (it is on the clipboard). Waiting for GitHub…"
        case .signedIn(let user): return user.isEmpty ? "Signed in." : "Signed in as \(user)."
        case .notAuthorized(let user): return "Signed in as \(user), but this account has no GitHub Copilot access."
        case .expired: return "Your GitHub sign-in expired."
        }
    }

    enum AuthAction: Equatable {
        case signIn(String)
        case signingIn
        case signOut
    }

    var authAction: AuthAction { Self.authAction(authState) }

    static func authAction(_ state: CopilotService.AuthState) -> AuthAction {
        switch state {
        case .unknown, .signedOut: return .signIn("Sign in with GitHub")
        case .expired: return .signIn("Sign in again")
        case .signingIn: return .signingIn
        case .signedIn, .notAuthorized: return .signOut
        }
    }

    var userCode: String? {
        if case .signingIn(let code, _) = authState { return code }
        return nil
    }

    func signIn() { service.signIn() }
    func cancelSignIn() { service.cancelSignIn() }
    func signOut() { Task { await service.signOut() } }
    func retry() { Task { await service.retry() } }

    func openPageAgain() {
        guard case .signingIn(_, let page) = authState, let url = URL(string: page) else { return }
        _ = service.openURL?(url)
    }
}

/// Settings › AI › GitHub Copilot: the switch, the sign-in, the language server's state and what is sent.
struct CopilotSettingsSection: View {
    @Binding var settings: AppSettings
    @StateObject private var model = CopilotSettingsModel()

    private var enabled: Binding<Bool> {
        Binding(get: { settings.ai.copilotProvider != nil }, set: { settings.ai.setCopilotEnabled($0) })
    }

    var body: some View {
        Section {
            Toggle("Use GitHub Copilot for inline suggestions", isOn: enabled)
                .accessibilityIdentifier("copilotEnabled")
            if settings.ai.copilotProvider != nil {
                if !settings.ai.enabled {
                    Text("Turn on AI features above to use Copilot.")
                        .foregroundStyle(.secondary)
                } else if settings.ai.activeProvider?.kind != .copilot {
                    Text("Suggestions use \(settings.ai.activeProvider?.displayName ?? "another provider"). Choose GitHub Copilot as the provider for suggestions to use it.")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Account") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(model.authText)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("copilotAuth")
                        authButtons
                    }
                }
                if let error = model.authError {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
                if let note = model.statusNote, !note.message.isEmpty {
                    Label(note.message, systemImage: note.kind == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(note.kind == .error ? .red : .orange)
                        .accessibilityIdentifier("copilotStatusNote")
                }
                LabeledContent("Language server") {
                    HStack {
                        if case .installing(let fraction) = model.serverState, let fraction {
                            ProgressView(value: fraction).frame(width: 80)
                        }
                        Text(model.serverText)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("copilotServer")
                        if model.serverFailed {
                            Button("Try Again") { model.retry() }
                        }
                    }
                }
                Toggle("Send usage telemetry to GitHub", isOn: $settings.ai.copilotTelemetry)
                    .accessibilityIdentifier("copilotTelemetry")
            }
        } header: {
            Text("GitHub Copilot")
        } footer: {
            Text(CopilotPrivacyNote.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("copilotPrivacyNote")
        }
    }

    @ViewBuilder
    private var authButtons: some View {
        switch model.authAction {
        case .signIn(let title):
            Button(title) { model.signIn() }
                .disabled(!settings.ai.enabled)
                .accessibilityIdentifier("copilotSignIn")
        case .signingIn:
            HStack {
                ProgressView().controlSize(.small)
                Button("Open Page Again") { model.openPageAgain() }
                Button("Cancel") { model.cancelSignIn() }
            }
        case .signOut:
            Button("Sign Out") { model.signOut() }
                .accessibilityIdentifier("copilotSignOut")
        }
    }
}

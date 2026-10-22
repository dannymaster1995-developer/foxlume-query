import AppKit
import Testing
@testable import FoxlumeQuery
@testable import FoxlumeQueryCore

/// A Copilot service on the `fqfakelsp` stand-in (built with the tests), with its state folder in TMPDIR.
@MainActor
final class AppFakeCopilot {
    let folder: URL
    let service: CopilotService

    init(signedIn: Bool = false, configure: (inout CopilotService.Configuration) -> Void = { _ in }) throws {
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        folder = tmp.appendingPathComponent("fq-app-copilot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let products = Bundle(for: AppFakeCopilot.self).bundleURL.deletingLastPathComponent()
        var executable = products.appendingPathComponent("fqfakelsp")
        if !FileManager.default.isExecutableFile(atPath: executable.path) {
            executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/debug/fqfakelsp")
        }
        let server = executable
        var configuration = CopilotService.Configuration(executable: { _ in server }, environment: ["FQ_FAKE_LSP_DIR": folder.path], clientVersion: "test")
        configuration.signInPollInterval = 0.05
        configure(&configuration)
        service = CopilotService(configuration: configuration)
        service.openURL = { _ in true }
        service.copyToClipboard = { _ in }
        if signedIn { try "fake-copilot-user".write(to: folder.appendingPathComponent("signed-in"), atomically: true, encoding: .utf8) }
    }

    static var settings: AISettings {
        var settings = AISettings()
        settings.enabled = true
        settings.setCopilotEnabled(true)
        return settings
    }

    func received(_ method: String) -> [JSONValue] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("received.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONValue.decode(Data($0.utf8)) }.filter { $0["method"]?.string == method }
    }

    func sentDocuments() -> Bool {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("received.jsonl"), encoding: .utf8) else { return false }
        return text.contains("\"textDocument/")
    }

    func finish() async {
        await service.stop()
        try? FileManager.default.removeItem(at: folder)
    }
}

extension AppCompletionTests {
    @Suite("GitHub Copilot in the app")
    @MainActor
    struct CopilotAppTests {
        private func withFake(_ fake: AppFakeCopilot, _ body: (AppFakeCopilot) async throws -> Void) async throws {
            do {
                try await body(fake)
            } catch {
                await fake.finish()
                throw error
            }
            await fake.finish()
        }

        private func cache(_ fake: AppFakeCopilot, settings: @escaping @MainActor () -> AISettings = { AppFakeCopilot.settings }) -> InlineSuggestionSourceCache {
            InlineSuggestionSourceCache(keys: AIKeyStore(store: MemoryCredentialStore()), settings: settings, copilot: { fake.service })
        }

        @Test func settingsFollowTheSignIn() async throws {
            let fake = try AppFakeCopilot()
            try "1".write(to: fake.folder.appendingPathComponent("confirm-delay"), atomically: true, encoding: .utf8)
            try await withFake(fake) { fake in
                let model = CopilotSettingsModel(service: fake.service)
                #expect(model.authText == "Sign-in not checked yet.")
                #expect(model.authAction == .signIn("Sign in with GitHub"))
                #expect(model.serverText == "Not running; it starts with the next suggestion or sign-in.")
                fake.service.apply(AppFakeCopilot.settings)
                await settle(until: { model.authState == .signedOut }, seconds: 5)
                #expect(model.authText == "Not signed in.")
                #expect(model.serverText == "Language server \(CopilotRelease.version) running.")
                model.signIn()
                await settle(until: { model.userCode != nil }, seconds: 5)
                #expect(model.userCode == "FAKE-1234")
                #expect(model.authAction == .signingIn)
                #expect(model.authText == "Enter the code FAKE-1234 at https://github.com/login/device (it is on the clipboard). Waiting for GitHub…")
                await settle(until: { model.authState == .signedIn(user: "fake-copilot-user") }, seconds: 5)
                #expect(model.authText == "Signed in as fake-copilot-user.")
                #expect(model.authAction == .signOut)
                // Signing out goes back to Sign in.
                model.signOut()
                await settle(until: { model.authState == .signedOut }, seconds: 5)
                #expect(model.authAction == .signIn("Sign in with GitHub"))
            }
        }

        @Test func settingsShowDownloadProgressAndFailures() async throws {
            let gate = AsyncGate()
            let fake = try AppFakeCopilot { configuration in
                configuration.executable = { progress in
                    progress(0.45)
                    await gate.wait()
                    throw CopilotInstallError.checksumMismatch("package")
                }
            }
            try await withFake(fake) { fake in
                let model = CopilotSettingsModel(service: fake.service)
                fake.service.apply(AppFakeCopilot.settings)
                await settle(until: { model.serverState == .installing(0.45) })
                #expect(model.serverText == "Downloading the language server… 45 %")
                await gate.open()
                await settle(until: { model.serverFailed })
                #expect(model.serverText == CopilotInstallError.checksumMismatch("package").localizedDescription)
            }
        }

        @Test func expiredSignInAsksToSignInAgain() {
            let model = CopilotSettingsModel(service: CopilotService(configuration: .init(executable: { _ in throw CancellationError() }, environment: [:], clientVersion: "test")))
            #expect(model.authAction == .signIn("Sign in with GitHub"))
            // The states map to their lines and buttons.
            let lines: [(CopilotService.AuthState, String, CopilotSettingsModel.AuthAction)] = [
                (.expired, "Your GitHub sign-in expired.", .signIn("Sign in again")),
                (.notAuthorized(user: "someone"), "Signed in as someone, but this account has no GitHub Copilot access.", .signOut),
                (.signedIn(user: ""), "Signed in.", .signOut),
            ]
            for (state, text, action) in lines {
                #expect(CopilotSettingsModel.authText(state) == text)
                #expect(CopilotSettingsModel.authAction(state) == action)
            }
        }

        @Test func ghostTextComesFromCopilotAndTabAccepts() async throws {
            try await withFake(try AppFakeCopilot(signedIn: true)) { fake in
                fake.service.apply(AppFakeCopilot.settings)
                var connection = ConnectionConfig(kind: .postgresql, environment: .development)
                connection.aiPolicyLevel = .allow
                let host = SettingsInlineHost(cache: cache(fake), connection: connection)
                let h = EditorHarness(engine: StubCompletionEngine())
                defer { h.close() }
                h.editor.inlineSuggestionHost = host
                #expect(host.inlineSuggestionSource is CopilotInlineSuggestionSource)
                h.type("SELECT * FROM ord")
                await settle(until: { h.ghost != nil }, seconds: 5)
                #expect(h.ghost == "ers")
                #expect(h.string == "SELECT * FROM ord")
                h.text.sendKeyForTesting("tab")
                #expect(h.string == "SELECT * FROM orders")
                await settle(until: { !fake.received("workspace/executeCommand").isEmpty }, seconds: 5)
                #expect(fake.received("workspace/executeCommand").count == 1)
                let open = fake.received("textDocument/didOpen").first?["params"]?["textDocument"]?["text"]?.string
                #expect(open?.hasPrefix("-- Dialect: PostgreSQL\n-- orders\n") == true, "the preamble with the host's schema")
            }
        }

        @Test func askSendsNoDocumentAndNeverClosesIt() async throws {
            try await withFake(try AppFakeCopilot(signedIn: true)) { fake in
                fake.service.apply(AppFakeCopilot.settings)
                await settle(until: { fake.service.isSignedIn }, seconds: 5)
                let host = ConsentHost(cache: cache(fake), connection: ConnectionConfig(kind: .postgresql, environment: .development))
                let h = EditorHarness(engine: StubCompletionEngine())
                defer { h.close() }
                h.editor.inlineSuggestionHost = host
                host.attach(to: h.text)
                h.type("SELECT * FROM ord")
                await settle(until: { host.gate.isPrompting })
                await settle(300)
                #expect(host.gate.isPrompting)
                #expect(!fake.sentDocuments(), "a document reached the language server before Allow")
                // Not Now: still nothing.
                try host.gate.answer(.notNow)
                h.type("e")
                await settle(300)
                #expect(!fake.sentDocuments())
                // Allow (the policy stored on the connection) sends it.
                host.box.config.aiPolicyLevel = .allow
                h.type("r")
                await settle(until: { h.ghost != nil }, seconds: 5)
                #expect(h.ghost == "ers")
                #expect(fake.received("textDocument/didOpen").count == 1)
                #expect(fake.service.openDocumentCount == 1)
                // Never: the tab's document is closed at the server, and nothing more is sent.
                host.box.config.aiPolicyLevel = .never
                host.gate.refresh()
                await settle(until: { !fake.received("textDocument/didClose").isEmpty }, seconds: 5)
                #expect(fake.service.openDocumentCount == 0)
                let completions = fake.received("textDocument/inlineCompletion").count
                h.text.suggestInline(nil)
                await settle(300)
                #expect(fake.received("textDocument/inlineCompletion").count == completions)
            }
        }

        @Test func closingTheTabClosesItsDocument() async throws {
            try await withFake(try AppFakeCopilot(signedIn: true)) { fake in
                fake.service.apply(AppFakeCopilot.settings)
                var connection = ConnectionConfig(kind: .postgresql, environment: .development)
                connection.aiPolicyLevel = .allow
                let cache = cache(fake)
                let source = try #require(cache.source(for: connection, language: .sql(.postgresql)))
                _ = try await source.suggestion(for: InlineSuggestionRequest(text: "SELECT 1", caret: 8, dialect: "PostgreSQL"))
                #expect(fake.service.openDocumentCount == 1)
                cache.retire()
                await settle(until: { !fake.received("textDocument/didClose").isEmpty }, seconds: 5)
                #expect(fake.service.openDocumentCount == 0)
                // AI off: no source at all.
                let off = InlineSuggestionSourceCache(keys: AIKeyStore(store: MemoryCredentialStore()), settings: {
                    var settings = AppFakeCopilot.settings
                    settings.enabled = false
                    return settings
                }, copilot: { fake.service })
                #expect(off.source(for: connection, language: .sql(.postgresql)) == nil)
            }
        }

        @Test func serverMessagesShowInAPanelWithTheirButtons() async throws {
            _ = NSApplication.shared
            let message = CopilotService.Message(type: 2, text: "You have used 80% of your Copilot Free completions.", actions: ["Learn More", "Dismiss"])
            let answer = Task { await CopilotMessagePanel.present(message) }
            await settle(until: { !CopilotMessagePanel.open.isEmpty })
            let panel = try #require(CopilotMessagePanel.open.first)
            #expect(panel.isVisible)
            #expect(panel.actionTitles == ["Learn More", "Dismiss"])
            #expect(!panel.styleMask.contains(.docModalWindow))
            panel.answer("Learn More")
            #expect(await answer.value == "Learn More")
            #expect(CopilotMessagePanel.open.isEmpty)
            // Closing it answers nothing.
            let dismissed = Task { await CopilotMessagePanel.present(CopilotService.Message(type: 3, text: "Note", actions: [])) }
            await settle(until: { !CopilotMessagePanel.open.isEmpty })
            CopilotMessagePanel.open.first?.close()
            #expect(await dismissed.value == nil)
        }

        @Test func providerFormOffersChatKindsOnly() {
            #expect(AIProviderKind.chatKinds == [.openAICompatible, .anthropic])
            var settings = AISettings()
            settings.setCopilotEnabled(true)
            #expect(settings.providers.map(\.displayName) == ["GitHub Copilot"])
            #expect(CopilotPrivacyNote.text.contains("whole text of the query tab"))
            #expect(CopilotPrivacyNote.text.contains("Copilot Free works"))
            #expect(AIPrivacyNote.text.contains("GitHub Copilot gets the whole query tab instead"))
        }
    }
}

/// Holds an async caller until `open`.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

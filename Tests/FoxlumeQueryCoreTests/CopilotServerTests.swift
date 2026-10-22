import CryptoKit
import Foundation
import Testing
@testable import FoxlumeQueryCore

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A tarball shaped like the npm platform package, with a small script standing in for the binary.
private struct FakeTarball {
    let data: Data
    let binary: Data

    init(binaryText: String = "#!/bin/sh\necho fake copilot\n") throws {
        let folder = TestFiles.url("fq-copilot-tarball-\(UUID().uuidString)")
        let package = folder.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        binary = Data(binaryText.utf8)
        try binary.write(to: package.appendingPathComponent("copilot-language-server"))
        try Data(#"{"name":"@github/copilot-language-server-darwin-arm64"}"#.utf8).write(to: package.appendingPathComponent("package.json"))
        let archive = folder.appendingPathComponent("package.tgz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", folder.path, "package"]
        try tar.run()
        tar.waitUntilExit()
        data = try Data(contentsOf: archive)
    }

    var digests: [String: CopilotRelease.Digests] {
        ["darwin-arm64": CopilotRelease.Digests(tarball: sha256(data), binary: sha256(binary))]
    }
}

@Suite("Copilot language server install", .serialized)
struct CopilotInstallerTests {
    private let host = "registry.npmjs.org"

    private func installer(_ tarball: FakeTarball, reply: AIStubURLProtocol.Reply? = nil,
                           digests: [String: CopilotRelease.Digests]? = nil, version: String = "9.9.9") -> (CopilotInstaller, URL) {
        let root = TestFiles.url("fq-copilot-install-\(UUID().uuidString)")
        let session = AIStubURLProtocol.session(host: host) { _ in
            reply ?? .http(status: 200, headers: ["content-length": "\(tarball.data.count)"], body: tarball.data)
        }
        return (CopilotInstaller(root: root, version: version, platform: "darwin-arm64", digests: digests ?? tarball.digests, session: session), root)
    }

    @Test func pinnedReleaseIsComplete() {
        #expect(CopilotRelease.version.split(separator: ".").count == 3)
        for platform in ["darwin-arm64", "darwin-x64"] {
            let digests = CopilotRelease.digests[platform]
            #expect(digests != nil, "no digests for \(platform)")
            for hash in [digests?.tarball ?? "", digests?.binary ?? ""] {
                #expect(hash.count == 64 && hash.allSatisfy(\.isHexDigit), "\(platform): \(hash)")
            }
        }
        #expect(CopilotRelease.digests[CopilotRelease.currentPlatform] != nil)
        #expect(CopilotRelease.tarballURL(platform: "darwin-x64", version: "1.2.3").absoluteString
                == "https://registry.npmjs.org/@github/copilot-language-server-darwin-x64/-/copilot-language-server-darwin-x64-1.2.3.tgz")
        #expect(CopilotRelease.tarballURL(platform: "darwin-arm64").absoluteString.hasSuffix("copilot-language-server-darwin-arm64-\(CopilotRelease.version).tgz"))
    }

    @Test func installsOnlyTheCheckedBinary() async throws {
        defer { AIStubURLProtocol.reset(host: host) }
        let tarball = try FakeTarball()
        let (installer, root) = installer(tarball)
        defer { try? FileManager.default.removeItem(at: root) }
        let fractions = Recorder()
        #expect(await installer.isInstalled() == false)
        let url = try await installer.ensureInstalled { fraction in fractions.add(fraction.map { String(format: "%.2f", $0) } ?? "nil") }
        #expect(url == root.appendingPathComponent("9.9.9/copilot-language-server"))
        #expect(try Data(contentsOf: url) == tarball.binary)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(try String(contentsOf: root.appendingPathComponent("9.9.9/version.txt"), encoding: .utf8) == "9.9.9\n")
        // Only the binary and version.txt: no package.json, no tarball, no staging folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("9.9.9").path).sorted() == ["copilot-language-server", "version.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["9.9.9"])
        #expect(fractions.items.last == "1.00")
        let requests = AIStubURLProtocol.requests(host: host)
        #expect(requests.map(\.url.absoluteString) == [CopilotRelease.tarballURL(platform: "darwin-arm64", version: "9.9.9").absoluteString])
        // Installed: no second download.
        #expect(await installer.isInstalled())
        _ = try await installer.ensureInstalled()
        #expect(AIStubURLProtocol.requests(host: host).count == 1)
    }

    @Test func wrongTarballHashInstallsNothing() async throws {
        defer { AIStubURLProtocol.reset(host: host) }
        let tarball = try FakeTarball()
        var digests = tarball.digests
        digests["darwin-arm64"]?.tarball = String(repeating: "0", count: 64)
        let (installer, root) = installer(tarball, digests: digests)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: CopilotInstallError.checksumMismatch("package")) { try await installer.ensureInstalled() }
        #expect(!FileManager.default.fileExists(atPath: installer.executableURL.path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.path)) == [])
    }

    @Test func wrongBinaryHashInstallsNothing() async throws {
        defer { AIStubURLProtocol.reset(host: host) }
        let tarball = try FakeTarball()
        var digests = tarball.digests
        digests["darwin-arm64"]?.binary = String(repeating: "a", count: 64)
        let (installer, root) = installer(tarball, digests: digests)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: CopilotInstallError.checksumMismatch("copilot-language-server")) { try await installer.ensureInstalled() }
        #expect(!FileManager.default.fileExists(atPath: installer.executableURL.path))
        let message = CopilotInstallError.checksumMismatch("copilot-language-server").localizedDescription
        #expect(message.contains("expected checksum"))
    }

    @Test func changedBinaryOrVersionIsInstalledAgain() async throws {
        defer { AIStubURLProtocol.reset(host: host) }
        let tarball = try FakeTarball()
        let (installer, root) = installer(tarball)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await installer.ensureInstalled()
        // Someone changed the binary on disk.
        try Data("#!/bin/sh\necho changed\n".utf8).write(to: url)
        #expect(await installer.isInstalled() == false)
        _ = try await installer.ensureInstalled()
        #expect(try Data(contentsOf: url) == tarball.binary)
        #expect(AIStubURLProtocol.requests(host: host).count == 2)
        // A version.txt for another version.
        try "1.0.0\n".write(to: root.appendingPathComponent("9.9.9/version.txt"), atomically: true, encoding: .utf8)
        #expect(await installer.isInstalled() == false)
        _ = try await installer.ensureInstalled()
        #expect(AIStubURLProtocol.requests(host: host).count == 3)
        // A newer pinned version replaces the old folder.
        let (newer, _) = (CopilotInstaller(root: root, version: "10.0.0", platform: "darwin-arm64", digests: tarball.digests,
                                            session: AIStubURLProtocol.session(host: host) { _ in .http(status: 200, body: tarball.data) }), root)
        _ = try await newer.ensureInstalled()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["10.0.0"])
    }

    @Test func downloadFailuresSayWhy() async throws {
        defer { AIStubURLProtocol.reset(host: host) }
        let tarball = try FakeTarball()
        let (notFound, root) = installer(tarball, reply: .http(status: 404, body: Data("Not Found".utf8)))
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: CopilotInstallError.downloadFailed("the server answered HTTP 404")) { try await notFound.ensureInstalled() }
        let (offline, root2) = installer(tarball, reply: .failure(.notConnectedToInternet))
        defer { try? FileManager.default.removeItem(at: root2) }
        do {
            _ = try await offline.ensureInstalled()
            Issue.record("installed without a network")
        } catch let error as CopilotInstallError {
            guard case .downloadFailed = error else { Issue.record("unexpected \(error)"); return }
            #expect(error.localizedDescription.hasPrefix("Could not download the GitHub Copilot language server"))
        }
        let (unknown, root3) = installer(tarball, digests: [:])
        defer { try? FileManager.default.removeItem(at: root3) }
        await #expect(throws: CopilotInstallError.unsupportedPlatform("darwin-arm64")) { try await unknown.ensureInstalled() }
    }
}

/// The fake language server (`fqfakelsp`, built with the tests) and its state folder.
@MainActor
final class FakeCopilot {
    let folder: URL
    let service: CopilotService
    var clipboard: [String] = []
    var openedURLs: [URL] = []
    var messages: [CopilotService.Message] = []
    var messageAnswer: String? = "Learn More"

    static var executable: URL {
        // The test bundle sits next to the products in the build folder.
        let products = Bundle(for: FakeCopilot.self).bundleURL.deletingLastPathComponent()
        let candidate = products.appendingPathComponent("fqfakelsp")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/fqfakelsp")
    }

    init(signedIn: Bool = false, configure: (inout CopilotService.Configuration) -> Void = { _ in }) throws {
        folder = TestFiles.url("fq-fake-copilot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = Self.executable
        var configuration = CopilotService.Configuration(
            executable: { _ in executable },
            environment: ["FQ_FAKE_LSP_DIR": folder.path, "PATH": "/usr/bin:/bin"],
            clientVersion: "0.1.0-test"
        )
        configuration.restartDelays = [0.2]
        configuration.signInPollInterval = 0.05
        configuration.requestTimeout = 5
        configure(&configuration)
        service = CopilotService(configuration: configuration)
        if signedIn { set("signed-in", "fake-copilot-user") }
        service.copyToClipboard = { [weak self] text in self?.clipboard.append(text) }
        service.openURL = { [weak self] url in
            self?.openedURLs.append(url)
            return true
        }
        service.showMessage = { [weak self] message in
            self?.messages.append(message)
            return self?.messageAnswer
        }
    }

    func set(_ name: String, _ text: String) {
        try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    static var copilotSettings: AISettings {
        var settings = AISettings()
        settings.enabled = true
        settings.setCopilotEnabled(true)
        return settings
    }

    /// Every message the fake server received, in order.
    var received: [JSONValue] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("received.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONValue.decode(Data($0.utf8)) }
    }

    func receivedMethods() -> [String] { received.compactMap { $0["method"]?.string } }

    func received(_ method: String) -> [JSONValue] { received.filter { $0["method"]?.string == method } }

    func finish() async {
        await service.stop()
        try? FileManager.default.removeItem(at: folder)
    }
}

@Suite("Copilot with a fake language server", .serialized)
@MainActor
struct CopilotFakeServerTests {
    /// Runs `body` and always stops the fake server and removes its folder before the test ends.
    private func withFake(_ fake: FakeCopilot, _ body: (FakeCopilot) async throws -> Void) async throws {
        do {
            try await body(fake)
        } catch {
            await fake.finish()
            throw error
        }
        await fake.finish()
    }

    private let request = InlineSuggestionRequest(
        text: "SELECT *\nFROM ord", caret: 17, dialect: "PostgreSQL",
        schema: [AISchemaTable(name: "orders", columns: [.init(name: "id", type: "integer", isPrimaryKey: true)])]
    )

    @Test func startsWithTheClientsNameTelemetryOffAndChecksTheSignIn() async throws {
        try await withFake(try FakeCopilot()) { fake in
            fake.service.apply(FakeCopilot.copilotSettings)
            try await waitFor { fake.service.authState == .signedOut }
            #expect(fake.service.serverState == .running)
            let methods = fake.receivedMethods()
            #expect(Array(methods.prefix(4)) == ["initialize", "initialized", "workspace/didChangeConfiguration", "checkStatus"])
            let initialize = fake.received("initialize").first?["params"]
            #expect(initialize?["clientInfo"] == ["name": "Foxlume Query", "version": "0.1.0-test"])
            #expect(initialize?["initializationOptions"]?["editorInfo"] == ["name": "Foxlume Query", "version": "0.1.0-test"])
            #expect(initialize?["initializationOptions"]?["editorPluginInfo"]?["name"] == "foxlume-query-copilot")
            #expect(initialize?["capabilities"]?["general"]?["positionEncodings"] == ["utf-16"])
            #expect(fake.received("workspace/didChangeConfiguration").first?["params"] == ["settings": ["telemetry": ["telemetryLevel": "off"]]])
            // workspace/configuration from the server is answered with the same settings.
            try await waitFor { fake.received.contains { $0["id"] == "fake-1" && $0["result"] != nil } }
            #expect(fake.received.first { $0["id"] == "fake-1" }?["result"] == [["telemetryLevel": "off"]])
            // Turning telemetry on tells the server.
            var settings = FakeCopilot.copilotSettings
            settings.copilotTelemetry = true
            fake.service.apply(settings)
            try await waitFor { fake.received("workspace/didChangeConfiguration").count == 2 }
            #expect(fake.received("workspace/didChangeConfiguration").last?["params"] == ["settings": ["telemetry": ["telemetryLevel": "all"]]])
            // Nothing about documents was sent: no tab asked for a suggestion.
            #expect(!fake.receivedMethods().contains { $0.hasPrefix("textDocument/") })
        }
    }

    @Test func signInShowsTheCodeThenPolls() async throws {
        try await withFake(try FakeCopilot()) { fake in
            fake.set("pending-confirms", "2")
            fake.service.apply(FakeCopilot.copilotSettings)
            fake.service.signIn()
            try await waitFor { fake.service.authState == .signingIn(userCode: "FAKE-1234", verificationURL: "https://github.com/login/device") }
            #expect(fake.clipboard == ["FAKE-1234"])
            #expect(fake.openedURLs == [URL(string: "https://github.com/login/device")!])
            await fake.service.waitForSignIn()
            #expect(fake.service.authState == .signedIn(user: "fake-copilot-user"))
            #expect(fake.received("signInConfirm").count == 3, "two NotSignedIn answers, then OK")
            #expect(fake.service.authError == nil)
            // Sign out.
            await fake.service.signOut()
            #expect(fake.service.authState == .signedOut)
            #expect(fake.received("signOut").count == 1)
        }
    }

    @Test func signInGivesUpAfterTheTimeout() async throws {
        try await withFake(try FakeCopilot { $0.signInTimeout = 0.5 }) { fake in
            fake.set("pending-confirms", "1000")
            fake.service.apply(FakeCopilot.copilotSettings)
            fake.service.signIn()
            await fake.service.waitForSignIn()
            #expect(fake.service.authState == .signedOut)
            #expect(fake.service.authError == "Sign-in timed out. Try again.")
        }
    }

    @Test func suggestionsSyncTheDocumentWithThePreamble() async throws {
        try await withFake(try FakeCopilot(signedIn: true)) { fake in
            fake.service.apply(FakeCopilot.copilotSettings)
            let source = CopilotInlineSuggestionSource(service: fake.service)
            let first = try await source.suggestion(for: request)
            #expect(first?.text == "ers")
            #expect(first?.location == 17)
            #expect(fake.service.authState == .signedIn(user: "fake-copilot-user"))
            let preamble = CopilotPreamble(dialect: "PostgreSQL", schema: request.schema)
            let open = fake.received("textDocument/didOpen").first?["params"]?["textDocument"]
            #expect(open?["text"]?.string == "-- Dialect: PostgreSQL\n-- orders(id integer PK)\nSELECT *\nFROM ord")
            #expect(open?["languageId"] == "sql")
            let uri = open?["uri"]?.string ?? ""
            #expect(uri == fake.service.documentFolder.absoluteString + "query-1.sql")
            #expect(uri.hasPrefix("file:///foxlume-query/"))
            let completion = fake.received("textDocument/inlineCompletion").first?["params"]
            #expect(completion?["position"] == ["line": JSONValue(1 + preamble.lineCount), "character": 8])
            #expect(completion?["context"]?["triggerKind"] == 2)
            #expect(completion?["formattingOptions"] == ["tabSize": 4, "insertSpaces": true])
            #expect(completion?["textDocument"]?["version"] == 0)
            #expect(fake.receivedMethods().contains("textDocument/didFocus"))

            // Typed on: an incremental change, and the server's copy matches exactly.
            var next = request
            next.text = "SELECT *\nFROM orders o\nWHERE o."
            next.caret = (next.text as NSString).length
            next.manual = true
            fake.set("suggestion", "id = 1")
            let second = try await source.suggestion(for: next)
            #expect(second?.text == "id = 1")
            let change = fake.received("textDocument/didChange").last?["params"]
            #expect(change?["textDocument"]?["version"] == 1)
            #expect(change?["contentChanges"]?.array?.first?["range"] != nil, "incremental")
            #expect(fake.received("textDocument/inlineCompletion").last?["params"]?["context"]?["triggerKind"] == 1)
            let endpoint = try await fake.service.start()
            let documents = try await endpoint.request("fake/documents")
            #expect(documents[uri]?.string == preamble.document(for: next.text))

            // Accepting runs the item's command.
            if let second { source.didAccept(second, partially: false) }
            try await waitFor { !fake.received("workspace/executeCommand").isEmpty }
            #expect(fake.received("workspace/executeCommand").first?["params"]
                    == ["command": "github.copilot.didAcceptCompletionItem", "arguments": ["fake-item-2"]])

            // A retired document is closed and never sent again.
            source.retireDocument()
            try await waitFor { !fake.received("textDocument/didClose").isEmpty }
            let completions = fake.received("textDocument/inlineCompletion").count
            #expect(try await source.suggestion(for: next) == nil)
            #expect(fake.received("textDocument/inlineCompletion").count == completions)
            #expect(fake.service.openDocumentCount == 0)
        }
    }

    /// Nothing the client sends carries the Mac's account name or a local path: no root, no workspace folders, neutral
    /// document names.
    @Test func noUserNameOrLocalPathIsSent() async throws {
        try await withFake(try FakeCopilot(signedIn: true)) { fake in
            fake.service.apply(FakeCopilot.copilotSettings)
            let source = CopilotInlineSuggestionSource(service: fake.service)
            let suggestion = try await source.suggestion(for: request)
            if let suggestion { source.didAccept(suggestion, partially: false) }
            try await waitFor { !fake.received("workspace/executeCommand").isEmpty }
            source.retireDocument()
            try await waitFor { !fake.received("textDocument/didClose").isEmpty }
            let sent = try String(contentsOf: fake.folder.appendingPathComponent("received.jsonl"), encoding: .utf8)
            for method in ["initialize", "textDocument/didOpen", "textDocument/inlineCompletion", "workspace/executeCommand"] {
                #expect(sent.contains("\"\(method)\""), "\(method) was not sent")
            }
            #expect(!sent.contains(NSHomeDirectory()))
            #expect(!sent.contains(NSUserName()))
            #expect(!sent.contains("/Users/"))
            #expect(!sent.contains(FileManager.default.currentDirectoryPath))
            let initialize = fake.received("initialize").first?["params"]
            #expect(initialize?["rootUri"] == nil && initialize?["rootPath"] == nil)
            #expect(initialize?["workspaceFolders"] == JSONValue.null)
        }
    }

    @Test func notSignedInSendsNoDocument() async throws {
        try await withFake(try FakeCopilot()) { fake in
            fake.service.apply(FakeCopilot.copilotSettings)
            let source = CopilotInlineSuggestionSource(service: fake.service)
            await #expect(throws: AIProviderError.notReady("Sign in to GitHub Copilot in Settings › AI")) { try await source.suggestion(for: request) }
            #expect(!fake.receivedMethods().contains { $0.hasPrefix("textDocument/") })
        }
    }

    @Test func cancellingASuggestionCancelsAtTheServer() async throws {
        try await withFake(try FakeCopilot(signedIn: true)) { fake in
            fake.set("slow-completion", "5")
            fake.service.apply(FakeCopilot.copilotSettings)
            let source = CopilotInlineSuggestionSource(service: fake.service)
            let task = Task { try await source.suggestion(for: request) }
            try await waitFor { !fake.received("textDocument/inlineCompletion").isEmpty }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            try await waitFor { !fake.received("$/cancelRequest").isEmpty }
            let id = fake.received("textDocument/inlineCompletion").first?["id"]
            #expect(fake.received("$/cancelRequest").first?["params"]?["id"] == id)
        }
    }

    @Test func showMessageRequestIsAnsweredWithTheChosenAction() async throws {
        try await withFake(try FakeCopilot()) { fake in
            fake.set("show-message", "Your Copilot Free quota is used up.")
            fake.service.apply(FakeCopilot.copilotSettings)
            try await waitFor { !fake.messages.isEmpty }
            #expect(fake.messages.first == CopilotService.Message(type: 2, text: "Your Copilot Free quota is used up.", actions: ["Learn More", "Dismiss"]))
            try await waitFor { fake.received.contains { $0["id"] == "fake-2" } }
            #expect(fake.received.first { $0["id"] == "fake-2" }?["result"] == ["title": "Learn More"])
        }
    }

    @Test func crashRestartsWithANewGeneration() async throws {
        try await withFake(try FakeCopilot(signedIn: true)) { fake in
            fake.service.apply(FakeCopilot.copilotSettings)
            let source = CopilotInlineSuggestionSource(service: fake.service)
            #expect(try await source.suggestion(for: request)?.text == "ers")
            let generation = fake.service.generation
            fake.set("crash-on-completion", "")
            var next = request
            next.text += "e"
            next.caret += 1
            await #expect(throws: LSPError.self) { try await source.suggestion(for: next) }
            try await waitFor { fake.service.generation > generation && fake.service.serverState == .running }
            #expect(fake.service.restartCount >= 1)
            // The new process gets the document again from scratch.
            let opens = fake.received("textDocument/didOpen").count
            #expect(try await source.suggestion(for: next)?.text == "ers")
            #expect(fake.received("textDocument/didOpen").count == opens + 1)
            #expect(fake.received("initialize").count == 2)
        }
    }

    @Test func anExpiredSignInAsksToSignInAgain() async throws {
        try await withFake(try FakeCopilot(signedIn: true)) { fake in
            fake.service.apply(FakeCopilot.copilotSettings)
            let source = CopilotInlineSuggestionSource(service: fake.service)
            _ = try await source.suggestion(for: request)
            fake.set("expire-on-completion", "")
            var next = request
            next.manual = true
            _ = try await source.suggestion(for: next)
            try await waitFor { fake.service.authState == .expired }
            #expect(fake.service.statusNote == .init(kind: .error, message: "You are not signed into GitHub."))
            await #expect(throws: AIProviderError.notReady("GitHub sign-in expired: sign in again in Settings › AI")) { try await source.suggestion(for: next) }
            // Signed out elsewhere while the app still thinks it is signed in: the server's "Not authenticated" (code
            // 1000, as the real 1.557.0 answers) becomes the same message, not a silent failure.
            fake.set("signed-in", "fake-copilot-user")
            await fake.service.refreshStatus()
            #expect(fake.service.isSignedIn)
            try FileManager.default.removeItem(at: fake.folder.appendingPathComponent("signed-in"))
            next.text += " "
            next.caret += 1
            await #expect(throws: AIProviderError.notReady("GitHub sign-in expired: sign in again in Settings › AI")) { try await source.suggestion(for: next) }
        }
    }

    @Test func turningAIOffStopsTheServerAndIdleStopsIt() async throws {
        try await withFake(try FakeCopilot(signedIn: true) { $0.idleStop = 0.5 }) { fake in
            fake.service.apply(FakeCopilot.copilotSettings)
            try await waitFor { fake.service.serverState == .running }
            // Idle: stops on its own.
            try await waitFor { fake.service.serverState == .stopped }
            try await waitFor { fake.receivedMethods().contains("shutdown") && fake.receivedMethods().contains("exit") }
            // A suggestion starts it again.
            let source = CopilotInlineSuggestionSource(service: fake.service)
            #expect(try await source.suggestion(for: request)?.text == "ers")
            // Copilot no longer the inline source: its documents are closed.
            var other = FakeCopilot.copilotSettings
            other.upsert(AIProviderConfig(name: "Local", kind: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "x"))
            other.activeProviderID = other.providers.first { $0.kind != .copilot }?.id
            fake.service.apply(other)
            try await waitFor { !fake.received("textDocument/didClose").isEmpty }
            #expect(try await source.suggestion(for: request) == nil)
            // AI off: the server stops and nothing starts it.
            var off = FakeCopilot.copilotSettings
            off.enabled = false
            fake.service.apply(off)
            try await waitFor { fake.service.serverState == .stopped }
            await #expect(throws: LSPError.notRunning) { try await fake.service.start() }
        }
    }

    @Test func installFailureIsReportedWithoutRestarts() async throws {
        let attempts = Recorder()
        let failing = try FakeCopilot { configuration in
            configuration.executable = { _ in
                attempts.add("download")
                throw CopilotInstallError.downloadFailed("the server answered HTTP 404")
            }
        }
        try await withFake(failing) { fake in
            fake.service.apply(FakeCopilot.copilotSettings)
            try await waitFor { if case .failed = fake.service.serverState { return true } else { return false } }
            #expect(fake.service.serverState == .failed("Could not download the GitHub Copilot language server: the server answered HTTP 404"))
            try await Task.sleep(nanoseconds: 400_000_000)
            #expect(fake.service.restartCount == 0)
            let source = CopilotInlineSuggestionSource(service: fake.service)
            do {
                _ = try await source.suggestion(for: request)
                Issue.record("answered without a server")
            } catch {
                #expect(AIProviderError.from(error) == .notReady("Could not download the GitHub Copilot language server: the server answered HTTP 404"))
            }
            // Suggestions do not download again; Try Again does.
            #expect(attempts.items.count == 1)
            await fake.service.retry()
            #expect(attempts.items.count == 2)
        }
    }
}

import Foundation
import os

/// GitHub Copilot through its language server: installs and runs the server while Settings › AI allows it, signs in
/// with GitHub's device flow, keeps the query documents in sync and asks for inline completions. The GitHub token is
/// kept by the language server, never by the app.
///
/// The server runs only while AI is on and Copilot is a provider. It starts on its own when Copilot becomes the
/// provider of inline suggestions (and checks the sign-in then), stops after `idleStop` without use, restarts with a
/// growing delay after a crash, and stops when AI or Copilot is turned off. Every launch bumps `generation`, and
/// callbacks from an older process are ignored.
@MainActor
public final class CopilotService {
    static let log = Logger(subsystem: "com.foxlume.query", category: "copilot")
    public static let didChangeNotification = Notification.Name("FoxlumeQuery.CopilotService.didChange")

    public enum ServerState: Equatable, Sendable {
        case stopped
        /// Downloading the language server: the fraction done, nil while unknown.
        case installing(Double?)
        case starting
        case running
        case failed(String)
    }

    public enum AuthState: Equatable, Sendable {
        /// Not asked yet (the server has not run).
        case unknown
        case signedOut
        /// Waiting for the user to enter `userCode` at `verificationURL`.
        case signingIn(userCode: String, verificationURL: String)
        case signedIn(user: String)
        /// Signed in to GitHub, but the account has no Copilot access.
        case notAuthorized(user: String)
        /// Was signed in during this session and is not any more.
        case expired
    }

    /// The last `didChangeStatus` that was not plain Normal.
    public struct StatusNote: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case normal = "Normal"
            case warning = "Warning"
            case error = "Error"
            case inactive = "Inactive"
        }

        public var kind: Kind
        public var message: String
    }

    /// A `window/showMessageRequest` (or `window/showMessage`, which has no actions).
    public struct Message: Equatable, Sendable {
        /// 1 error, 2 warning, 3 info, 4 log.
        public var type: Int
        public var text: String
        public var actions: [String]
    }

    public struct Configuration: Sendable {
        /// The language server to start; may download it, reporting the fraction done.
        public var executable: @Sendable (_ progress: @escaping @Sendable (Double?) -> Void) async throws -> URL
        public var environment: [String: String]
        public var clientVersion: String
        public var requestTimeout: TimeInterval = 30
        public var completionTimeout: TimeInterval = 15
        public var idleStop: TimeInterval = 15 * 60
        public var restartDelays: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60]
        public var signInPollInterval: TimeInterval = 2
        public var signInTimeout: TimeInterval = 120

        public init(executable: @escaping @Sendable (_ progress: @escaping @Sendable (Double?) -> Void) async throws -> URL,
                    environment: [String: String], clientVersion: String) {
            self.executable = executable
            self.environment = environment
            self.clientVersion = clientVersion
        }
    }

    public let configuration: Configuration
    public private(set) var settings = AISettings()
    public private(set) var serverState: ServerState = .stopped { didSet { changed(serverState != oldValue) } }
    public private(set) var authState: AuthState = .unknown { didSet { changed(authState != oldValue) } }
    public private(set) var statusNote: StatusNote? { didSet { changed(statusNote != oldValue) } }
    /// Why the last sign-in or sign-out failed.
    public private(set) var authError: String? { didSet { changed(authError != oldValue) } }
    /// Bumped by every start and stop.
    public private(set) var generation = 0

    /// Shows a server message with its actions and returns the chosen one (nil when dismissed).
    public var showMessage: (@MainActor (Message) async -> String?)?
    /// Opens the sign-in page; false when it could not be opened.
    public var openURL: (@MainActor (URL) -> Bool)?
    public var copyToClipboard: (@MainActor (String) -> Void)?

    private var server: LSPServerProcess?
    private var startTask: Task<LSPEndpoint, Error>?
    private var restartTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private var restartAttempt = 0
    /// Why the last install failed; suggestions do not download again until `retry` (or a sign-in) asks.
    private var installFailure: String?
    private var documents: CopilotDocuments
    /// Documents closed for good (tab closed, the connection's policy no longer Allow): never opened again.
    private var retired = Set<UUID>()
    /// Commands of suggestions on screen, run when the user accepts one.
    private var pendingCommands: [String: LSPCommand] = [:]
    private var pendingOrder: [String] = []

    /// Where the query documents' names point: `file:///foxlume-query/<random id>/`, new at every launch. No such
    /// folder exists, and the names carry no user, connection, host, database or local path.
    public let documentFolder: URL

    public init(configuration: Configuration) {
        self.configuration = configuration
        documentFolder = Self.neutralDocumentFolder()
        documents = CopilotDocuments(folder: documentFolder)
    }

    public nonisolated static func neutralDocumentFolder(id: UUID = UUID()) -> URL {
        URL(string: "file:///foxlume-query/\(id.uuidString.lowercased())/")!
    }

    private func changed(_ really: Bool) {
        if really { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
    }

    /// The documents the server has open now, for tests and scripted checks.
    public var openDocumentCount: Int { documents.open.count }

    // MARK: Settings

    /// Applies Settings › AI: stops the server when AI or Copilot is off, starts it when Copilot becomes the provider
    /// of inline suggestions, closes every document when it stops being that, and passes the telemetry choice on.
    public func apply(_ newSettings: AISettings) {
        let old = settings
        settings = newSettings
        guard newSettings.copilotMayRun else {
            if server != nil || startTask != nil || restartTask != nil || serverState != .stopped {
                Task { await stop() }
            }
            authState = .unknown
            statusNote = nil
            return
        }
        if old.copilotTelemetry != newSettings.copilotTelemetry, serverState == .running, let endpoint = server?.endpoint {
            endpoint.notify("workspace/didChangeConfiguration", params: ["settings": configurationSettings])
        }
        if !newSettings.copilotIsInlineSource {
            closeAllDocuments()
        } else if !old.copilotIsInlineSource, server == nil, startTask == nil {
            Task { try? await start() }
        }
    }

    var configurationSettings: JSONValue {
        ["telemetry": ["telemetryLevel": .string(settings.copilotTelemetry ? "all" : "off")]]
    }

    // MARK: Lifecycle

    /// The running server's endpoint, starting (and installing) it first when needed. Concurrent callers share one start.
    @discardableResult
    public func start() async throws -> LSPEndpoint {
        if let server, serverState == .running { return server.endpoint }
        if let startTask { return try await startTask.value }
        guard settings.copilotMayRun else { throw LSPError.notRunning }
        restartTask?.cancel()
        restartTask = nil
        generation += 1
        let generation = self.generation
        let task = Task { try await launch(generation: generation) }
        startTask = task
        defer { if startTask == task { startTask = nil } }
        return try await task.value
    }

    private func launch(generation: Int) async throws -> LSPEndpoint {
        serverState = .installing(nil)
        let executable: URL
        do {
            executable = try await configuration.executable { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.generation == generation, case .installing = self.serverState else { return }
                    self.serverState = .installing(fraction)
                }
            }
        } catch {
            if self.generation == generation {
                serverState = .failed(error.localizedDescription)
                if !(error is CancellationError) { installFailure = error.localizedDescription }
            }
            throw error
        }
        guard self.generation == generation else { throw CancellationError() }
        installFailure = nil
        serverState = .starting
        let process = LSPServerProcess(executable: executable, environment: configuration.environment, requestTimeout: configuration.requestTimeout)
        let endpoint = process.endpoint
        endpoint.setHandlers(
            request: { [weak self] method, params in
                guard let self else { return .failure(JSONRPCError(code: JSONRPCError.methodNotFound, message: method)) }
                return await self.answer(method, params)
            },
            notification: { [weak self] method, params in
                Task { @MainActor in self?.handleNotification(method, params, generation: generation) }
            }
        )
        process.onExit = { [weak self] code, requested in
            Task { @MainActor in self?.serverDidExit(generation: generation, code: code, requested: requested) }
        }
        do {
            try process.start()
            server = process
            let result = try await endpoint.request("initialize", params: initializeParams)
            guard self.generation == generation else { throw CancellationError() }
            documents.syncKind = Self.syncKind(result["capabilities"]?["textDocumentSync"])
            endpoint.notify("initialized", params: [:])
            endpoint.notify("workspace/didChangeConfiguration", params: ["settings": configurationSettings])
            documents.serverDidRestart()
            serverState = .running
            noteActivity()
            await refreshStatus()
            return endpoint
        } catch {
            if self.generation == generation {
                server = nil
                serverState = .failed(error.localizedDescription)
                scheduleRestart()
            }
            process.terminate()
            throw error
        }
    }

    /// Settings › Try Again: starts the server, downloading it again after a failed install.
    public func retry() async {
        installFailure = nil
        _ = try? await start()
    }

    /// Stops the server: `shutdown` and `exit`, then the process group goes.
    public func stop() async {
        generation += 1
        restartTask?.cancel()
        restartTask = nil
        idleTask?.cancel()
        idleTask = nil
        signInTask?.cancel()
        signInTask = nil
        startTask = nil
        let process = server
        server = nil
        documents.serverDidRestart()
        clearCommands()
        serverState = .stopped
        if case .signingIn = authState { authState = .signedOut }
        // Not cancelled with the caller (the idle timer stops the server from its own task).
        await Task { await process?.stop() }.value
    }

    /// App quit: ends the server's process group at once.
    public func terminateNow() {
        generation += 1
        restartTask?.cancel()
        idleTask?.cancel()
        signInTask?.cancel()
        server?.terminate()
        server = nil
        serverState = .stopped
    }

    private func serverDidExit(generation: Int, code: Int32, requested: Bool) {
        guard generation == self.generation, !requested else { return }
        Self.log.error("Copilot language server exited with code \(code)")
        server = nil
        documents.serverDidRestart()
        clearCommands()
        if case .signingIn = authState { authState = .signedOut }
        serverState = .failed("The Copilot language server stopped unexpectedly (code \(code)).")
        scheduleRestart()
    }

    /// After a crash or a failed start: try again after 1, 2, 4… up to 60 seconds, while Copilot provides suggestions.
    private func scheduleRestart() {
        guard settings.copilotIsInlineSource, restartTask == nil else { return }
        let delays = configuration.restartDelays
        let delay = delays.isEmpty ? 1 : delays[min(restartAttempt, delays.count - 1)]
        restartAttempt += 1
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.restartTask = nil
            _ = try? await self.start()
        }
    }

    /// Restarts counted since the last answer that worked, for tests.
    public var restartCount: Int { restartAttempt }

    private func noteActivity() {
        idleTask?.cancel()
        let interval = configuration.idleStop
        let generation = self.generation
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == generation, self.serverState == .running else { return }
            if case .signingIn = self.authState { return }
            Self.log.info("Copilot language server idle, stopping")
            self.idleTask = nil
            await self.stop()
        }
    }

    private var initializeParams: JSONValue {
        let version = JSONValue.string(configuration.clientVersion)
        return [
            "processId": JSONValue(Int(ProcessInfo.processInfo.processIdentifier)),
            "clientInfo": ["name": "Foxlume Query", "version": version],
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "workspace": ["configuration": true],
                "window": ["showDocument": ["support": true], "showMessage": ["messageActionItem": ["additionalPropertiesSupport": false]]],
                "textDocument": ["synchronization": ["dynamicRegistration": false], "inlineCompletion": ["dynamicRegistration": false]],
            ],
            "initializationOptions": [
                "editorInfo": ["name": "Foxlume Query", "version": version],
                "editorPluginInfo": ["name": "foxlume-query-copilot", "version": version],
            ],
            "workspaceFolders": nil,
        ]
    }

    static func syncKind(_ value: JSONValue?) -> CopilotDocuments.SyncKind {
        let kind = value?.int ?? value?["change"]?.int
        return kind == 1 ? .full : .incremental
    }

    // MARK: Sign-in

    /// The sign-in status from the server (`checkStatus`).
    public func refreshStatus() async {
        guard serverState == .running, let endpoint = server?.endpoint else { return }
        do {
            let result = try await endpoint.request("checkStatus", params: ["options": ["localChecksOnly": false]])
            applyStatus(result)
        } catch {
            Self.log.debug("checkStatus failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyStatus(_ result: JSONValue) {
        let user = result["user"]?.string ?? ""
        switch result["status"]?.string {
        case "OK", "MaybeOk", "AlreadySignedIn":
            authState = .signedIn(user: user)
        case "NotAuthorized":
            authState = .notAuthorized(user: user)
        default:
            if case .signingIn = authState { return }
            switch authState {
            case .signedIn, .notAuthorized, .expired: authState = .expired
            default: authState = .signedOut
            }
        }
    }

    /// GitHub's device flow: shows the code (copied to the clipboard), opens the page, then waits up to two minutes.
    public func signIn() {
        signInTask?.cancel()
        authError = nil
        signInTask = Task { [weak self] in await self?.runSignIn() }
    }

    public func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        if case .signingIn = authState { authState = .signedOut }
    }

    /// Waits for the sign-in started by `signIn`, for tests.
    public func waitForSignIn() async {
        await signInTask?.value
    }

    private func runSignIn() async {
        do {
            let endpoint = try await start()
            noteActivity()
            let initiate = try await endpoint.request("signInInitiate", params: [:])
            if let user = Self.signedInUser(initiate) {
                authState = .signedIn(user: user)
                return
            }
            guard let code = initiate["userCode"]?.string, let page = initiate["verificationUri"]?.string else {
                throw AIProviderError.invalidResponse
            }
            authState = .signingIn(userCode: code, verificationURL: page)
            copyToClipboard?(code)
            if let url = URL(string: page), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                _ = openURL?(url)
            }
            let deadline = Date().addingTimeInterval(configuration.signInTimeout)
            while true {
                try Task.checkCancellation()
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                do {
                    // Newer servers answer once the user has finished; older ones answer at once and are asked again.
                    let result = try await endpoint.request("signInConfirm", params: ["userCode": .string(code)], timeout: remaining)
                    if let user = Self.signedInUser(result) {
                        authState = .signedIn(user: user)
                        noteActivity()
                        return
                    }
                } catch let error as JSONRPCError {
                    // "No pending sign in" and failed flows: the status says whether it worked after all.
                    authState = .signedOut
                    await refreshStatus()
                    if case .signedIn = authState { return }
                    authError = "Sign-in did not complete: \(error.message)"
                    return
                } catch LSPError.timedOut {
                    break
                }
                try await Task.sleep(nanoseconds: UInt64(configuration.signInPollInterval * 1_000_000_000))
            }
            authState = .signedOut
            authError = "Sign-in timed out. Try again."
        } catch is CancellationError {
            if case .signingIn = authState { authState = .signedOut }
        } catch {
            if case .signedIn = authState { return }
            authState = .signedOut
            authError = error.localizedDescription
        }
    }

    static func signedInUser(_ result: JSONValue) -> String? {
        switch result["status"]?.string {
        case "OK", "AlreadySignedIn", "MaybeOk": return result["user"]?.string ?? ""
        default: return nil
        }
    }

    public func signOut() async {
        cancelSignIn()
        authError = nil
        do {
            let endpoint = try await start()
            closeAllDocuments()
            _ = try await endpoint.request("signOut", params: [:])
            authState = .signedOut
        } catch {
            authError = "Could not sign out: \(error.localizedDescription)"
        }
    }

    // MARK: Documents and completions

    /// An inline completion for the query document `key` (one per query tab). Sends the document only while Copilot
    /// provides suggestions, the user is signed in and the document has not been retired.
    public func suggestion(for request: InlineSuggestionRequest, document key: UUID) async throws -> InlineSuggestion? {
        guard settings.copilotIsInlineSource, !retired.contains(key) else { return nil }
        // A failed download is not tried again on every pause in typing.
        if let installFailure, server == nil { throw AIProviderError.notReady(installFailure) }
        noteActivity()
        let endpoint = try await start()
        switch authState {
        case .signedIn: break
        case .notAuthorized: throw AIProviderError.notReady("This GitHub account has no Copilot access")
        case .expired: throw AIProviderError.notReady("GitHub sign-in expired: sign in again in Settings › AI")
        default: throw AIProviderError.notReady("Sign in to GitHub Copilot in Settings › AI")
        }
        // Settings or the connection's policy may have changed while the server started.
        try Task.checkCancellation()
        guard settings.copilotIsInlineSource, !retired.contains(key) else { return nil }
        let preamble = CopilotPreamble(dialect: request.dialect, schema: request.schema)
        for message in documents.sync(key, text: preamble.document(for: request.text)) {
            endpoint.notify(message.method, params: message.params)
        }
        guard let document = documents.open[key] else { return nil }
        let params: JSONValue = [
            "textDocument": ["uri": .string(document.uri), "version": JSONValue(document.version)],
            "position": preamble.documentPosition(ofEditorOffset: request.caret, in: request.text).json,
            "context": ["triggerKind": JSONValue(request.manual ? 1 : 2)],
            "formattingOptions": ["tabSize": JSONValue(request.tabSize), "insertSpaces": .bool(request.insertSpaces)],
        ]
        let generation = self.generation
        let result: JSONValue
        do {
            result = try await endpoint.request("textDocument/inlineCompletion", params: params, timeout: configuration.completionTimeout)
        } catch let error as JSONRPCError where error.code == Self.notAuthenticated {
            // The sign-in went away since it was last checked.
            await refreshStatus()
            throw AIProviderError.notReady(authState == .expired ? "GitHub sign-in expired: sign in again in Settings › AI"
                                                                  : "Sign in to GitHub Copilot in Settings › AI")
        }
        guard generation == self.generation else { return nil }
        restartAttempt = 0
        for item in CopilotCompletionItem.items(from: result) {
            guard let ghost = CopilotCompletionMapper.ghostText(for: item, editorText: request.text, caret: request.caret, preamble: preamble) else { continue }
            let id = UUID().uuidString
            if let command = item.command { remember(command, id: id) }
            return InlineSuggestion(text: ghost, location: request.caret, sourceItemID: id)
        }
        return nil
    }

    /// The server's error code for a request made without a valid sign-in ("Not authenticated: NotSignedIn").
    static let notAuthenticated = 1000

    /// The user accepted the suggestion: its command goes to the server (Copilot counts accepted suggestions).
    public func accept(itemID: String) async {
        guard let command = pendingCommands.removeValue(forKey: itemID) else { return }
        pendingOrder.removeAll { $0 == itemID }
        guard serverState == .running, let endpoint = server?.endpoint else { return }
        noteActivity()
        _ = try? await endpoint.request("workspace/executeCommand", params: command.executeParams)
    }

    public func dismiss(itemID: String) {
        pendingCommands[itemID] = nil
        pendingOrder.removeAll { $0 == itemID }
    }

    private func remember(_ command: LSPCommand, id: String) {
        pendingCommands[id] = command
        pendingOrder.append(id)
        while pendingOrder.count > 20 { pendingCommands[pendingOrder.removeFirst()] = nil }
    }

    private func clearCommands() {
        pendingCommands = [:]
        pendingOrder = []
    }

    /// Closes the document of `key` at the server and never opens it again.
    public func retireDocument(_ key: UUID) {
        retired.insert(key)
        send(documents.close(key))
    }

    public func closeAllDocuments() {
        send(documents.closeAll())
    }

    private func send(_ messages: [LSPNotification]) {
        guard !messages.isEmpty, serverState == .running, let endpoint = server?.endpoint else { return }
        for message in messages { endpoint.notify(message.method, params: message.params) }
    }

    // MARK: Messages from the server

    private func answer(_ method: String, _ params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        switch method {
        case "window/showMessageRequest":
            let message = Message(type: params?["type"]?.int ?? 3, text: params?["message"]?.string ?? "",
                                  actions: params?["actions"]?.array?.compactMap { $0["title"]?.string } ?? [])
            Self.log.info("Copilot message: \(message.text, privacy: .public)")
            let chosen = await showMessage?(message)
            return .success(chosen.map { ["title": .string($0)] } ?? .null)
        case "workspace/configuration":
            let items = params?["items"]?.array ?? []
            return .success(.array(items.map { configurationValue(section: $0["section"]?.string) }))
        case "window/showDocument":
            guard let text = params?["uri"]?.string, let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { return .success(["success": false]) }
            return .success(["success": .bool(openURL?(url) ?? false)])
        case "client/registerCapability", "client/unregisterCapability", "window/workDoneProgress/create", "workspace/workspaceFolders":
            return .success(.null)
        default:
            return .failure(JSONRPCError(code: JSONRPCError.methodNotFound, message: "Unhandled method \(method)"))
        }
    }

    func configurationValue(section: String?) -> JSONValue {
        guard let section, !section.isEmpty else { return configurationSettings }
        var value: JSONValue = configurationSettings
        for part in section.split(separator: ".") {
            value = value[String(part)] ?? .null
        }
        return value
    }

    private func handleNotification(_ method: String, _ params: JSONValue?, generation: Int) {
        guard generation == self.generation else { return }
        switch method {
        case "window/logMessage":
            Self.log.debug("server: \(params?["message"]?.string ?? "", privacy: .public)")
        case "window/showMessage":
            let message = Message(type: params?["type"]?.int ?? 3, text: params?["message"]?.string ?? "", actions: [])
            Self.log.info("Copilot message: \(message.text, privacy: .public)")
            if message.type <= 2, let showMessage { Task { _ = await showMessage(message) } }
        case "didChangeStatus":
            let kind = StatusNote.Kind(rawValue: params?["kind"]?.string ?? "Normal") ?? .normal
            let message = params?["message"]?.string ?? ""
            statusNote = kind == .normal && message.isEmpty ? nil : StatusNote(kind: kind, message: message)
            // An error is usually a sign-in that is gone; Normal after a sign-in elsewhere: ask the server.
            if kind == .error || (kind == .normal && !isSignedIn) {
                if case .signingIn = authState { return }
                Task { await refreshStatus() }
            }
        default:
            break
        }
    }

    public var isSignedIn: Bool {
        if case .signedIn = authState { return true }
        return false
    }
}

/// Inline suggestions from GitHub Copilot for one query tab: the tab's document is `documentKey`. Made only when the
/// connection's AI policy resolves to Allow; when that changes, or the tab closes, the document is retired.
public final class CopilotInlineSuggestionSource: InlineSuggestionSource {
    public let service: CopilotService
    public let documentKey = UUID()

    public init(service: CopilotService) {
        self.service = service
    }

    deinit {
        let service = self.service
        let key = documentKey
        Task { @MainActor in service.retireDocument(key) }
    }

    public func suggestion(for request: InlineSuggestionRequest) async throws -> InlineSuggestion? {
        try await service.suggestion(for: request, document: documentKey)
    }

    public func didAccept(_ suggestion: InlineSuggestion, partially: Bool) {
        guard !partially, let id = suggestion.sourceItemID else { return }
        let service = self.service
        Task { @MainActor in await service.accept(itemID: id) }
    }

    public func didDismiss(_ suggestion: InlineSuggestion) {
        guard let id = suggestion.sourceItemID else { return }
        let service = self.service
        Task { @MainActor in service.dismiss(itemID: id) }
    }

    /// Closes the tab's document at the server now and never opens it again.
    @MainActor
    public func retireDocument() {
        service.retireDocument(documentKey)
    }
}

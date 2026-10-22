import AppKit
import FoxlumeQueryCore

/// What the editor's suggestion line shows.
enum InlineSuggestionStatus: Equatable {
    case idle
    /// A request is on its way.
    case requesting
    /// The last request failed in a way the user should know about (key rejected, rate limited, bad model…).
    case failed(String)
}

/// Supplies the suggestion source and the request details; asked per request, so a settings change applies at once.
@MainActor
protocol InlineSuggestionHost: AnyObject {
    /// Nil turns suggestions off for the editor (AI off, no provider, a Never policy, MongoDB or Redis): nothing is sent.
    var inlineSuggestionSource: InlineSuggestionSource? { get }
    /// The pause after typing before a request.
    var inlineSuggestionDebounce: TimeInterval { get }
    /// Adds the dialect and, when Settings › AI includes it, the schema.
    func inlineSuggestionRequest(text: String, caret: Int, manual: Bool) -> InlineSuggestionRequest
    func inlineSuggestionStatusDidChange(_ status: InlineSuggestionStatus)
    /// The connection's AI policy is Ask and the user has not answered: a request shows the prompt instead.
    var inlineSuggestionAwaitsConsent: Bool { get }
    /// Shows the Ask prompt without taking focus; nothing is sent until the user answers.
    func inlineSuggestionRequestConsent(manual: Bool)
}

extension InlineSuggestionHost {
    var inlineSuggestionAwaitsConsent: Bool { false }
    func inlineSuggestionRequestConsent(manual: Bool) {}
}

/// Owns one editor's inline suggestion: the pause after typing, the request in flight (cancelled by every keystroke
/// and caret move; stale answers are dropped by a generation counter) and the grey text shown after the caret.
@MainActor
final class InlineSuggestionManager {
    /// The suggestion on screen: `text` is what is still to come after `location`.
    struct Ghost: Equatable {
        var location: Int
        var text: String
        var suggestion: InlineSuggestion
    }

    weak var host: InlineSuggestionHost?
    /// Redraws the editor and reads its state.
    private unowned let textView: SQLTextView
    private(set) var ghost: Ghost? {
        didSet { if ghost != oldValue { textView.inlineSuggestionDidChange() } }
    }
    private(set) var status: InlineSuggestionStatus = .idle {
        didSet { if status != oldValue { host?.inlineSuggestionStatusDidChange(status) } }
    }
    /// The source of the ghost on screen, told when it is accepted or dismissed.
    private var ghostSource: InlineSuggestionSource?
    private var task: Task<Void, Never>?
    /// Bumped by every cancel; an answer from an older generation is dropped.
    private(set) var generation = 0
    /// After a 429 nothing is asked until then.
    private(set) var pausedUntil: Date?
    /// Requests handed to a source, for tests and scripted checks.
    private(set) var requestCount = 0

    /// A pause after a 429 without `retry-after`, and the bounds for one with it.
    static let defaultRateLimitPause: TimeInterval = 30
    static let rateLimitPauseRange: ClosedRange<TimeInterval> = 5...300

    init(textView: SQLTextView) {
        self.textView = textView
    }

    var isWaiting: Bool { task != nil }

    /// After an edit by the user: waits for the pause, then asks when the caret is at a sensible spot.
    func scheduleAfterEdit() {
        cancelPending()
        guard let host, host.inlineSuggestionSource != nil || host.inlineSuggestionAwaitsConsent else { return }
        let delay = host.inlineSuggestionDebounce
        let generation = self.generation
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            await self.run(manual: false, generation: generation)
        }
    }

    /// The Suggest command: asks now, wherever the caret is.
    func requestNow() {
        dismiss()
        let generation = self.generation
        task = Task { @MainActor [weak self] in
            guard let self, self.generation == generation else { return }
            await self.run(manual: true, generation: generation)
        }
    }

    /// Cancels the wait or the request in flight; the ghost on screen stays.
    func cancelPending() {
        generation += 1
        task?.cancel()
        task = nil
        if status == .requesting { status = .idle }
    }

    /// Hides the ghost and cancels everything pending.
    func dismiss() {
        cancelPending()
        guard let ghost else { return }
        let source = ghostSource
        self.ghost = nil
        ghostSource = nil
        source?.didDismiss(ghost.suggestion)
    }

    /// Typing `typed` at the caret continues the ghost: the rest stays on screen.
    func continues(with typed: String, selection: NSRange) -> Bool {
        guard let ghost, !typed.isEmpty, selection == NSRange(location: ghost.location, length: 0) else { return false }
        return ghost.text.hasPrefix(typed)
    }

    /// `piece` was inserted at the ghost's location (typed or accepted): the ghost moves past it. True when it is used up.
    @discardableResult
    func advance(by piece: String, accepted: Bool) -> Bool {
        guard var ghost, ghost.text.hasPrefix(piece) else { return false }
        ghost.location += (piece as NSString).length
        ghost.text = String(ghost.text.dropFirst(piece.count))
        if ghost.text.isEmpty {
            let source = ghostSource
            self.ghost = nil
            ghostSource = nil
            source?.didAccept(ghost.suggestion, partially: false)
            return true
        }
        self.ghost = ghost
        if accepted { ghostSource?.didAccept(ghost.suggestion, partially: true) }
        return false
    }

    /// The caret moved without an edit: a ghost not at the caret any more goes, and so does a request.
    func caretDidMove(to selection: NSRange) {
        if let ghost, selection != NSRange(location: ghost.location, length: 0) {
            dismiss()
        } else {
            cancelPending()
        }
    }

    /// The next word of the ghost, with the whitespace before it; or one punctuation character.
    static func nextWord(of text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex, text[index].isWhitespace {
            result.append(text[index])
            index = text.index(after: index)
        }
        guard index < text.endIndex else { return result }
        func isWord(_ character: Character) -> Bool { character.isLetter || character.isNumber || character == "_" }
        if isWord(text[index]) {
            while index < text.endIndex, isWord(text[index]) {
                result.append(text[index])
                index = text.index(after: index)
            }
        } else {
            result.append(text[index])
        }
        return result
    }

    private func run(manual: Bool, generation: Int) async {
        defer { if self.generation == generation { task = nil } }
        guard let host else { return }
        guard let source = host.inlineSuggestionSource else {
            // Ask: where a request would go out, the user is asked instead, and nothing is sent.
            if host.inlineSuggestionAwaitsConsent, textView.canRequestInlineSuggestion(manual: manual) {
                host.inlineSuggestionRequestConsent(manual: manual)
            }
            return
        }
        if let pausedUntil, pausedUntil > Date() { return }
        pausedUntil = nil
        guard textView.canRequestInlineSuggestion(manual: manual) else { return }
        let text = textView.string
        let caret = textView.selectedRange().location
        let request = host.inlineSuggestionRequest(text: text, caret: caret, manual: manual)
        requestCount += 1
        status = .requesting
        do {
            let answer = try await source.suggestion(for: request)
            guard self.generation == generation, !Task.isCancelled else { return }
            status = .idle
            // The user kept typing or moved: the answer is for another text.
            guard let answer, !answer.text.isEmpty, textView.string == text,
                  textView.selectedRange() == NSRange(location: caret, length: 0), answer.location == caret,
                  textView.canRequestInlineSuggestion(manual: true)
            else { return }
            ghostSource = source
            ghost = Ghost(location: caret, text: answer.text, suggestion: answer)
        } catch {
            guard self.generation == generation else { return }
            report(AIProviderError.from(error))
        }
    }

    private func report(_ error: AIProviderError) {
        switch error {
        case .rateLimited(let retryAfter):
            let pause = min(max(retryAfter ?? Self.defaultRateLimitPause, Self.rateLimitPauseRange.lowerBound), Self.rateLimitPauseRange.upperBound)
            pausedUntil = Date().addingTimeInterval(pause)
            status = .failed("Rate limited: suggestions paused for \(Int(pause.rounded())) s")
        case _ where error.isTransient:
            // 5xx, 529, timeouts and network errors: the next keystroke asks again.
            status = .idle
        default:
            status = .failed(error.localizedDescription)
        }
    }
}

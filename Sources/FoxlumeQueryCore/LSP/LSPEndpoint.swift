import Foundation

public enum LSPError: Error, Equatable, LocalizedError {
    /// No answer within the request's timeout; the request was cancelled at the server.
    case timedOut(method: String)
    /// The connection closed (the server exited or the stream broke) before the answer came.
    case connectionClosed(String)
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .timedOut(let method): return "The language server did not answer \(method) in time"
        case .connectionClosed(let reason): return reason
        case .notRunning: return "The language server is not running"
        }
    }
}

/// JSON-RPC over one byte stream: numbered requests with timeouts and cancellation, notifications both ways, and
/// requests from the server answered by `onRequest`. Bytes come in through `receive` (from any thread) and go out
/// through the `write` closure given at creation. Thread-safe.
public final class LSPEndpoint: @unchecked Sendable {
    public typealias RequestHandler = @Sendable (_ method: String, _ params: JSONValue?) async -> Result<JSONValue, JSONRPCError>
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: JSONValue?) -> Void

    private let lock = NSLock()
    private let write: @Sendable (Data) -> Bool
    private var decoder = LSPFrameDecoder()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var closedReason: String?
    private var handlers: (request: RequestHandler?, notification: NotificationHandler?) = (nil, nil)

    /// Applies to requests sent without their own timeout.
    public let defaultTimeout: TimeInterval

    /// `write` sends framed bytes and returns false when the stream is gone.
    public init(defaultTimeout: TimeInterval = 30, write: @escaping @Sendable (Data) -> Bool) {
        self.defaultTimeout = defaultTimeout
        self.write = write
    }

    /// Answers the server's requests (`window/showMessageRequest`, `workspace/configuration`…). Without a handler,
    /// or for a method it does not know, the server gets MethodNotFound.
    public func setHandlers(request: RequestHandler?, notification: NotificationHandler?) {
        lock.withLock { handlers = (request, notification) }
    }

    public var isClosed: Bool { lock.withLock { closedReason != nil } }

    /// Sends a request and waits for its result. Cancelling the calling task, or the timeout, sends `$/cancelRequest`
    /// and throws `CancellationError` or `LSPError.timedOut`; an error answer throws its `JSONRPCError`.
    public func request(_ method: String, params: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> JSONValue {
        let id: Int = lock.withLock {
            defer { nextID += 1 }
            return nextID
        }
        let timeout = timeout ?? defaultTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                let closed: String? = lock.withLock {
                    if let closedReason { return closedReason }
                    pending[id] = continuation
                    return nil
                }
                if let closed {
                    continuation.resume(throwing: LSPError.connectionClosed(closed))
                    return
                }
                // Cancelled before the request was registered: the handler below found nothing to cancel.
                if Task.isCancelled {
                    if let waiting = take(id) { waiting.resume(throwing: CancellationError()) }
                    return
                }
                guard write(JSONRPCMessage.request(id: .number(id), method: method, params: params).framed) else {
                    if let waiting = take(id) { waiting.resume(throwing: LSPError.connectionClosed("The language server stopped reading")) }
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, let waiting = self.take(id) else { return }
                    self.sendCancel(id)
                    waiting.resume(throwing: LSPError.timedOut(method: method))
                }
            }
        } onCancel: {
            if let waiting = take(id) {
                sendCancel(id)
                waiting.resume(throwing: CancellationError())
            }
        }
    }

    /// Sends a notification; false when the stream is closed.
    @discardableResult
    public func notify(_ method: String, params: JSONValue? = nil) -> Bool {
        guard !isClosed else { return false }
        return write(JSONRPCMessage.notification(method: method, params: params).framed)
    }

    /// Feeds bytes read from the server. A stream that cannot be decoded closes the endpoint.
    public func receive(_ data: Data) {
        let bodies: [Data]
        do {
            bodies = try lock.withLock { try decoder.append(data) }
        } catch {
            close(reason: "The language server sent a broken message: \(error.localizedDescription)")
            return
        }
        for body in bodies {
            guard let message = try? JSONRPCMessage(body: body) else { continue }
            dispatch(message)
        }
    }

    /// Fails every waiting request; later requests fail at once.
    public func close(reason: String) {
        let waiting: [CheckedContinuation<JSONValue, Error>] = lock.withLock {
            guard closedReason == nil else { return [] }
            closedReason = reason
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        waiting.forEach { $0.resume(throwing: LSPError.connectionClosed(reason)) }
    }

    /// Requests still waiting for an answer, for tests.
    public var pendingCount: Int { lock.withLock { pending.count } }

    private func take(_ id: Int) -> CheckedContinuation<JSONValue, Error>? {
        lock.withLock { pending.removeValue(forKey: id) }
    }

    private func sendCancel(_ id: Int) {
        notify("$/cancelRequest", params: ["id": JSONValue(id)])
    }

    private func dispatch(_ message: JSONRPCMessage) {
        switch message {
        case .response(let id, let result):
            guard case .number(let number)? = id, let waiting = take(number) else { return }
            switch result {
            case .success(let value): waiting.resume(returning: value)
            case .failure(let error): waiting.resume(throwing: error)
            }
        case .notification(let method, let params):
            let handler = lock.withLock { handlers.notification }
            handler?(method, params)
        case .request(let id, let method, let params):
            let handler = lock.withLock { handlers.request }
            Task { [weak self] in
                let result = await handler?(method, params)
                    ?? .failure(JSONRPCError(code: JSONRPCError.methodNotFound, message: "Unhandled method \(method)"))
                guard let self, !self.isClosed else { return }
                _ = self.write(JSONRPCMessage.response(id: id, result: result).framed)
            }
        }
    }
}

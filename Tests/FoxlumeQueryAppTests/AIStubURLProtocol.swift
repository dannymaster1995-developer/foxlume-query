import Foundation

/// A copy of the core tests' stub, as test targets cannot share files. Answers URLSession requests from canned
/// responses and records exactly what was sent. Handlers are registered per host, so suites that run in parallel
/// never see each other's requests.
final class AIStubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case http(status: Int, headers: [String: String] = [:], body: Data)
        case failure(URLError.Code)
        /// Never answers; the request ends only when it is cancelled.
        case hang
    }

    struct Recorded {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: Data?

        var json: [String: Any]? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }

        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: (URLRequest) -> Reply] = [:]
    nonisolated(unsafe) private static var recorded: [String: [Recorded]] = [:]

    /// A session whose requests to `host` get `handler`'s replies.
    static func session(host: String, handler: @escaping (URLRequest) -> Reply) -> URLSession {
        lock.lock()
        handlers[host] = handler
        recorded[host] = []
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func requests(host: String) -> [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded[host] ?? []
    }

    static func reset(host: String) {
        lock.lock()
        handlers[host] = nil
        recorded[host] = nil
        lock.unlock()
    }

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Reply {
        .http(status: status, headers: headers.merging(["content-type": "application/json"]) { a, _ in a },
              body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        lock.lock()
        defer { lock.unlock() }
        return handlers[host] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let entry = Recorded(url: url, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        Self.lock.lock()
        Self.recorded[host, default: []].append(entry)
        let handler = Self.handlers[host]
        Self.lock.unlock()
        switch handler?(request) ?? .failure(.cannotFindHost) {
        case .http(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}

    /// URLSession moves a request's body into a stream before the protocol sees it.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

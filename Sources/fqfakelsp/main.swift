// A stand-in for the GitHub Copilot language server, for tests and scripted UI checks only. It speaks LSP over
// stdio and never touches the network: initialize, the sign-in methods, checkStatus, document sync,
// textDocument/inlineCompletion with a canned answer, workspace/executeCommand, and a few requests of its own to
// the client. Its behaviour is set by files in the folder named by FQ_FAKE_LSP_DIR (nothing is recorded without it):
//
//   received.jsonl        every message received, one JSON object per line (written by the server)
//   signed-in             present when signed in; holds the user name
//   pending-confirms      a number: signInConfirm answers NotSignedIn that many times first
//   confirm-delay         seconds signInConfirm waits before it answers
//   suggestion            the text a completion adds after the caret (default "ers")
//   slow-completion       seconds a completion waits before it answers ($/cancelRequest ends it early)
//   crash-on-completion   the next completion makes the server exit with code 3 (the file is removed first)
//   expire-on-completion  the next completion signs out and reports an Error status (the file is removed first)
//   show-message          after initialized, sends window/showMessageRequest with this text
//
// The custom request `fake/documents` returns the open documents as the server has them ({uri: text}).
import Foundation

let folder = ProcessInfo.processInfo.environment["FQ_FAKE_LSP_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
let queue = DispatchQueue(label: "fqfakelsp")
let outputLock = NSLock()
var documents: [String: (version: Int, text: String)] = [:]
var cancelled = Set<Int>()
var serverRequestNumber = 0
var completionNumber = 0

func file(_ name: String) -> URL? { folder?.appendingPathComponent(name) }

func read(_ name: String) -> String? {
    guard let url = file(name) else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
}

func exists(_ name: String) -> Bool {
    file(name).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
}

func remove(_ name: String) {
    if let url = file(name) { try? FileManager.default.removeItem(at: url) }
}

func write(_ name: String, _ text: String) {
    if let url = file(name) { try? text.write(to: url, atomically: true, encoding: .utf8) }
}

func record(_ body: Data) {
    guard let url = file("received.jsonl") else { return }
    var line = body
    line.append(0x0A)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line)
        try? handle.close()
    } else {
        try? line.write(to: url)
    }
}

func send(_ object: [String: Any]) {
    var message = object
    message["jsonrpc"] = "2.0"
    guard let body = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { return }
    var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
    data.append(body)
    outputLock.lock()
    FileHandle.standardOutput.write(data)
    outputLock.unlock()
}

func reply(_ id: Any, result: Any) { send(["id": id, "result": result]) }
func fail(_ id: Any, code: Int, message: String) { send(["id": id, "error": ["code": code, "message": message]]) }
func notify(_ method: String, _ params: [String: Any]) { send(["method": method, "params": params]) }

func request(_ method: String, _ params: [String: Any]) {
    serverRequestNumber += 1
    send(["id": "fake-\(serverRequestNumber)", "method": method, "params": params])
}

var signedInUser: String? {
    read("signed-in")?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The UTF-16 offset of an LSP position.
func offset(_ position: [String: Any], in text: String) -> Int {
    let units = Array(text.utf16)
    let line = position["line"] as? Int ?? 0
    let character = position["character"] as? Int ?? 0
    var current = 0
    var index = 0
    while current < line, index < units.count {
        if units[index] == 10 { current += 1 }
        index += 1
    }
    return min(index + character, units.count)
}

func applyChange(_ change: [String: Any], to text: String) -> String {
    let newText = change["text"] as? String ?? ""
    guard let range = change["range"] as? [String: Any],
          let start = range["start"] as? [String: Any], let end = range["end"] as? [String: Any] else { return newText }
    var units = Array(text.utf16)
    let from = offset(start, in: text)
    let to = offset(end, in: text)
    units.replaceSubrange(from..<max(from, to), with: Array(newText.utf16))
    return String(decoding: units, as: UTF16.self)
}

func completion(id: Any, params: [String: Any]) {
    if exists("crash-on-completion") {
        remove("crash-on-completion")
        exit(3)
    }
    if exists("expire-on-completion") {
        remove("expire-on-completion")
        remove("signed-in")
        notify("didChangeStatus", ["kind": "Error", "message": "You are not signed into GitHub.", "busy": false])
        reply(id, result: ["items": []])
        return
    }
    guard signedInUser != nil else {
        // As the real server answers without a sign-in.
        fail(id, code: 1000, message: "Not authenticated: NotSignedIn")
        return
    }
    let textDocument = params["textDocument"] as? [String: Any] ?? [:]
    let uri = textDocument["uri"] as? String ?? ""
    guard let document = documents[uri] else {
        fail(id, code: -32602, message: "Unknown document \(uri)")
        return
    }
    if let version = textDocument["version"] as? Int, version != document.version {
        fail(id, code: -32801, message: "Version \(version) is not the document's \(document.version)")
        return
    }
    let position = params["position"] as? [String: Any] ?? [:]
    let line = position["line"] as? Int ?? 0
    let character = position["character"] as? Int ?? 0
    let lines = document.text.components(separatedBy: "\n")
    let lineText = line < lines.count ? lines[line] : ""
    let prefix = String(decoding: Array(lineText.utf16).prefix(character), as: UTF16.self)
    completionNumber += 1
    let item: [String: Any] = [
        "insertText": prefix + (read("suggestion") ?? "ers"),
        "range": ["start": ["line": line, "character": 0], "end": ["line": line, "character": character]],
        "command": ["title": "Accept", "command": "github.copilot.didAcceptCompletionItem", "arguments": ["fake-item-\(completionNumber)"]],
    ]
    let answer = { reply(id, result: ["items": [item]]) }
    if let delay = read("slow-completion").flatMap({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), let number = id as? Int {
        queue.asyncAfter(deadline: .now() + delay) {
            if !cancelled.contains(number) { answer() }
        }
    } else {
        answer()
    }
}

func handle(_ message: [String: Any]) {
    let method = message["method"] as? String
    let params = message["params"] as? [String: Any] ?? [:]
    guard let method else { return }
    guard let id = message["id"] else {
        switch method {
        case "initialized":
            notify("window/logMessage", ["type": 4, "message": "fake server ready"])
            notify("didChangeStatus", ["kind": "Normal", "message": "", "busy": false])
            request("workspace/configuration", ["items": [["section": "telemetry"]]])
            if let text = read("show-message") {
                request("window/showMessageRequest", ["type": 2, "message": text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                      "actions": [["title": "Learn More"], ["title": "Dismiss"]]])
            }
        case "textDocument/didOpen":
            let item = params["textDocument"] as? [String: Any] ?? [:]
            if let uri = item["uri"] as? String {
                documents[uri] = (item["version"] as? Int ?? 0, item["text"] as? String ?? "")
            }
        case "textDocument/didChange":
            let item = params["textDocument"] as? [String: Any] ?? [:]
            if let uri = item["uri"] as? String, var document = documents[uri] {
                for change in params["contentChanges"] as? [[String: Any]] ?? [] {
                    document.text = applyChange(change, to: document.text)
                }
                document.version = item["version"] as? Int ?? document.version + 1
                documents[uri] = document
            }
        case "textDocument/didClose":
            if let uri = (params["textDocument"] as? [String: Any])?["uri"] as? String { documents[uri] = nil }
        case "$/cancelRequest":
            if let number = params["id"] as? Int {
                cancelled.insert(number)
                fail(number, code: -32800, message: "Request cancelled")
            }
        case "exit":
            exit(0)
        default:
            break
        }
        return
    }
    switch method {
    case "initialize":
        reply(id, result: ["capabilities": ["textDocumentSync": 2, "inlineCompletionProvider": [:] as [String: Any]],
                           "serverInfo": ["name": "fqfakelsp", "version": "0.0.1"]])
    case "shutdown":
        reply(id, result: NSNull())
    case "checkStatus":
        if let user = signedInUser {
            reply(id, result: ["status": "OK", "user": user])
        } else {
            reply(id, result: ["status": "NotSignedIn"])
        }
    case "signInInitiate", "signIn":
        if let user = signedInUser {
            reply(id, result: ["status": "AlreadySignedIn", "user": user])
        } else {
            reply(id, result: ["status": "PromptUserDeviceFlow", "userCode": "FAKE-1234",
                               "verificationUri": "https://github.com/login/device", "expiresIn": 900, "interval": 5])
        }
    case "signInConfirm":
        let answer = {
            let pending = Int(read("pending-confirms")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            if pending > 0 {
                write("pending-confirms", "\(pending - 1)")
                reply(id, result: ["status": "NotSignedIn"])
            } else {
                write("signed-in", "fake-copilot-user")
                reply(id, result: ["status": "OK", "user": "fake-copilot-user"])
            }
        }
        if let delay = read("confirm-delay").flatMap({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            queue.asyncAfter(deadline: .now() + delay, execute: answer)
        } else {
            answer()
        }
    case "signOut":
        remove("signed-in")
        reply(id, result: ["status": "NotSignedIn"])
    case "textDocument/inlineCompletion":
        completion(id: id, params: params)
    case "workspace/executeCommand":
        reply(id, result: NSNull())
    case "fake/documents":
        reply(id, result: documents.mapValues { $0.text })
    default:
        fail(id, code: -32601, message: "Unhandled method \(method)")
    }
}

// Reads Content-Length framed messages from stdin until it closes.
var buffer = Data()
let separator = Data("\r\n\r\n".utf8)
var chunk = [UInt8](repeating: 0, count: 65_536)
while true {
    let count = read(0, &chunk, chunk.count)
    if count < 0, errno == EINTR { continue }
    guard count > 0 else { break }
    buffer.append(contentsOf: chunk[0..<count])
    while let headerEnd = buffer.range(of: separator) {
        let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        guard let line = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
              let length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        else { exit(2) }
        let start = headerEnd.upperBound
        guard buffer.distance(from: start, to: buffer.endIndex) >= length else { break }
        let body = Data(buffer[start..<buffer.index(start, offsetBy: length)])
        buffer = Data(buffer[buffer.index(start, offsetBy: length)...])
        queue.sync {
            record(body)
            if let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] { handle(message) }
        }
    }
}
exit(0)

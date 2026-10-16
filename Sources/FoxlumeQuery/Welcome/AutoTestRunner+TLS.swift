import AppKit
import FoxlumeQueryCore

/// Scripted commands for the SSL/TLS part of the connection form. They act on the form opened with `form`.
///
///     tlsset <field> <value>    sets a form field: name, kind, host, port, user, password, database, mode
///                               (disable|prefer|require|verifyCA|verifyFull), ca, cert, key, p12, secret,
///                               safemode (a SafeModeLevel raw value), querytimeout (seconds, empty for no limit),
///                               startup (Run on connect; `\n` starts a new line); an empty value clears a path
///     tlsscroll [result|advanced] scrolls the form to the SSL/TLS section (or to the Test Connection result, or
///                               to the Advanced section)
///     formsize <width>x<height> resizes the form window
///     tlsstate                  logs the mode, the paths, the file checks and the validation message
///     tlstest                   presses Test Connection and logs the result when it arrives
///     tlssave [connect]         presses Save (or Connect)
@MainActor
enum TLSAutoTest {
    static let commands: Set<String> = ["tlsset", "tlsscroll", "formsize", "tlsstate", "tlstest", "tlssave"]
}

extension AutoTestRunner {
    func performTLS(_ command: String, _ argument: String) async throws {
        guard let form = ConnectionFormController.presented else {
            throw DatabaseError.unsupported("\(command) needs an open connection form (use `form` first)")
        }
        let model = form.formModel
        switch command {
        case "tlsset":
            let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard let field = parts.first else { throw DatabaseError.unsupported("tlsset <field> <value>") }
            try Self.set(field, parts.count > 1 ? parts[1] : "", on: model)
            try await Task.sleep(nanoseconds: 300_000_000)
        case "tlsscroll":
            model.scrollTarget = ["result", "advanced"].contains(argument) ? argument : "tls"
            try await Task.sleep(nanoseconds: 500_000_000)
        case "formsize":
            let size = argument.split(separator: "x").compactMap { Double($0) }
            guard size.count == 2 else { throw DatabaseError.unsupported("formsize <width>x<height>") }
            let window = form.formWindow
            var frame = window.frame
            frame.origin.y += frame.height - size[1]
            frame.size = NSSize(width: size[0], height: size[1])
            window.setFrame(frame, display: true)
            try await Task.sleep(nanoseconds: 400_000_000)
        case "tlsstate":
            let files = model.config.certificates
            record("  mode: \(model.config.sslMode.rawValue) (\(model.config.sslMode.displayName)); format: \(model.usesPKCS12 ? "PKCS#12" : "PEM")")
            record("  ca: \(files.caCertificatePath.isEmpty ? "-" : files.caCertificatePath)")
            record("  cert: \(files.clientCertificatePath.isEmpty ? "-" : files.clientCertificatePath); key: \(files.clientKeyPath.isEmpty ? "-" : files.clientKeyPath); p12: \(files.pkcs12Path.isEmpty ? "-" : files.pkcs12Path)")
            record("  secret: \(model.tlsSecret.isEmpty ? "empty" : "set")")
            let check = model.tlsCheck
            record("  ca check: \(Self.describe(check.ca))")
            record("  client check: \(Self.describe(check.client))")
            record("  validation: \(model.validationMessage ?? "ok")")
            record("  query timeout: \(model.config.queryTimeout.map { "\($0) s" } ?? "none"); run on connect: \(model.config.startupCommands.map { "\($0.split(whereSeparator: \.isNewline).count) line(s)" } ?? "none")")
        case "tlstest":
            model.test()
            try await waitFor(seconds: 30) { model.testState != .testing }
            switch model.testState {
            case .success(let message): record("  test: success: \(message)")
            case .failure(let message): record("  test: failure: \(message)")
            default: record("  test: \(model.testState)")
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        case "tlssave":
            model.onSave?(model.config, model.password, model.sshSecret, model.tlsSecret, argument == "connect")
            try await Task.sleep(nanoseconds: 500_000_000)
        default:
            throw DatabaseError.unsupported("Unknown command \(command)")
        }
    }

    private static func describe(_ line: TLSFileCheck.Line?) -> String {
        switch line {
        case .ok(let text): return "ok: \(text)"
        case .problem(let text): return "problem: \(text)"
        case nil: return "-"
        }
    }

    private static func set(_ field: String, _ value: String, on model: ConnectionFormModel) throws {
        switch field {
        case "name": model.config.name = value
        case "kind":
            guard let kind = DatabaseKind(rawValue: value) else { throw DatabaseError.unsupported("Unknown kind \(value)") }
            model.changeKind(to: kind)
        case "host": model.config.host = value
        case "port": model.config.port = Int(value) ?? model.config.port
        case "user": model.config.user = value
        case "password": model.password = value
        case "database": model.config.database = value
        case "mode":
            guard let mode = SSLMode(rawValue: value) else { throw DatabaseError.unsupported("Unknown SSL mode \(value)") }
            model.config.sslMode = mode
        case "ca": model.config.certificates.caCertificatePath = value
        case "cert":
            model.setUsesPKCS12(false)
            model.config.certificates.clientCertificatePath = value
        case "key":
            model.setUsesPKCS12(false)
            model.config.certificates.clientKeyPath = value
        case "p12":
            model.setUsesPKCS12(true)
            model.config.certificates.pkcs12Path = value
        case "secret": model.tlsSecret = value
        case "safemode":
            guard let level = SafeModeLevel(rawValue: value) else { throw DatabaseError.unsupported("Unknown Safe Mode \(value)") }
            model.config.safeModeLevel = level
        case "querytimeout": model.config.queryTimeout = Int(value).flatMap { $0 > 0 ? $0 : nil }
        case "startup":
            let text = value.replacingOccurrences(of: "\\n", with: "\n")
            model.config.startupCommands = text.isEmpty ? nil : text
        default: throw DatabaseError.unsupported("Unknown tlsset field \(field)")
        }
    }
}

import AppKit
import FoxlumeQueryCore
import SwiftUI

/// What the form shows under the certificate fields: each file read the way a connection would read it.
struct TLSFileCheck: Equatable {
    enum Line: Equatable {
        case ok(String)
        case problem(String)
    }

    var ca: Line?
    var client: Line?
}

extension ConnectionFormModel {
    /// Blocks Save and Test only for settings that can never work; file problems show next to the fields instead,
    /// so a connection whose certificates sit on an unmounted volume can still be saved.
    var tlsValidationMessage: String? {
        guard config.sslMode.wantsTLS, !config.kind.isFileBased else { return nil }
        let files = config.certificates
        if !usesPKCS12, files.clientCertificatePath.trimmingCharacters(in: .whitespaces).isEmpty,
           !files.clientKeyPath.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Choose the client certificate that goes with the key."
        }
        return nil
    }

    /// Reads the certificate files of the form, cached until a path, the passphrase or the mode changes.
    var tlsCheck: TLSFileCheck {
        let files = config.certificates
        let mode = config.sslMode
        let key = [mode.rawValue, files.caCertificatePath, files.clientCertificatePath, files.clientKeyPath, files.pkcs12Path, tlsSecret, "\(usesPKCS12)"]
            .joined(separator: "\u{1f}")
        if let cached = tlsCheckCache, cached.key == key { return cached.result }
        var check = TLSFileCheck()
        let caPath = files.caCertificatePath.trimmingCharacters(in: .whitespaces)
        if mode.verifiesCertificate, !caPath.isEmpty {
            do {
                check.ca = .ok(try TLSCredentials.describeCertificates(atPath: caPath))
            } catch {
                check.ca = .problem(error.localizedDescription)
            }
        }
        do {
            if let summary = try TLSCredentials.describeClientIdentity(files, secret: tlsSecret.isEmpty ? nil : tlsSecret) {
                check.client = .ok(summary)
            }
        } catch {
            check.client = .problem(error.localizedDescription)
        }
        tlsCheckCache = (key, check)
        return check
    }

    /// The PEM fields and the PKCS#12 field are alternatives; switching clears the other kind.
    func setUsesPKCS12(_ value: Bool) {
        guard value != usesPKCS12 else { return }
        usesPKCS12 = value
        var files = config.certificates
        if value {
            files.clientCertificatePath = ""
            files.clientKeyPath = ""
        } else {
            files.pkcs12Path = ""
        }
        config.certificates = files
    }

    func chooseTLSFile(_ field: WritableKeyPath<TLSCertificateFiles, String>, message: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = message
        let current = config.certificates[keyPath: field]
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.certificates[keyPath: field] = url.path
    }
}

/// The SSL/TLS part of the connection form: mode, CA certificate, client certificate (PEM files or PKCS#12) and
/// the passphrase, with each file checked as it is chosen.
struct ConnectionTLSSection: View {
    @ObservedObject var model: ConnectionFormModel

    private var mode: SSLMode { model.config.sslMode }

    private func path(_ field: WritableKeyPath<TLSCertificateFiles, String>) -> Binding<String> {
        Binding(get: { model.config.certificates[keyPath: field] }, set: { model.config.certificates[keyPath: field] = $0 })
    }

    var body: some View {
        let check = model.tlsCheck
        Section {
            Picker("SSL Mode", selection: $model.config.sslMode) {
                ForEach(SSLMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityIdentifier("sslMode")
            if mode.wantsTLS {
                if mode.verifiesCertificate {
                    fileRow("CA Certificate", field: \.caCertificatePath, prompt: "System trust store", identifier: "tlsCACertificate", message: "Choose the CA certificate (PEM) that signed the server certificate")
                    statusLine(check.ca)
                }
                Picker("Client Certificate", selection: Binding(get: { model.usesPKCS12 }, set: { model.setUsesPKCS12($0) })) {
                    Text("PEM Files").tag(false)
                    Text("PKCS#12").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("tlsClientFormat")
                if model.usesPKCS12 {
                    fileRow("PKCS#12 File", field: \.pkcs12Path, prompt: "Optional, .p12 or .pfx", identifier: "tlsPKCS12", message: "Choose a PKCS#12 file with the client certificate and key")
                    if !model.config.certificates.pkcs12Path.isEmpty {
                        SecureField("Password", text: $model.tlsSecret, prompt: Text("Password of the PKCS#12 file"))
                            .accessibilityIdentifier("tlsSecret")
                    }
                } else {
                    fileRow("Certificate", field: \.clientCertificatePath, prompt: "Optional, PEM", identifier: "tlsClientCertificate", message: "Choose the client certificate (PEM)")
                    fileRow("Private Key", field: \.clientKeyPath, prompt: "Optional, PEM", identifier: "tlsClientKey", message: "Choose the client certificate's private key (PEM)")
                    if !model.config.certificates.clientKeyPath.isEmpty || !model.config.certificates.clientCertificatePath.isEmpty {
                        SecureField("Key Passphrase", text: $model.tlsSecret, prompt: Text("Leave empty if the key is not encrypted"))
                            .accessibilityIdentifier("tlsSecret")
                    }
                }
                statusLine(check.client)
            }
        } header: {
            Text("SSL/TLS")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.summary)
                if mode.wantsTLS {
                    if mode.verifiesCertificate {
                        Text("Leave the CA certificate empty to use the certificate authorities trusted by macOS.")
                    }
                    Text("A client certificate is needed only when the server requires one (mutual TLS). The passphrase is kept with the password, not in the connection file.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func fileRow(_ title: String, field: WritableKeyPath<TLSCertificateFiles, String>, prompt: String, identifier: String, message: String) -> some View {
        HStack {
            TextField(title, text: path(field), prompt: Text(prompt))
                .truncationMode(.head)
                .help(model.config.certificates[keyPath: field])
                .accessibilityIdentifier(identifier)
            Button("Choose…") { model.chooseTLSFile(field, message: message) }
        }
    }

    @ViewBuilder
    private func statusLine(_ line: TLSFileCheck.Line?) -> some View {
        switch line {
        case .ok(let text):
            Label(text, systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .problem(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case nil:
            EmptyView()
        }
    }
}

/// Scrolls the form to a section id when `target` is set, then clears it.
struct FormScroller: ViewModifier {
    @Binding var target: String?

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onChange(of: target) { value in
                guard let value else { return }
                // The test result is the last section: show it at the bottom, with what precedes it above.
                proxy.scrollTo(value, anchor: value == "result" ? .bottom : .top)
                target = nil
            }
        }
    }
}

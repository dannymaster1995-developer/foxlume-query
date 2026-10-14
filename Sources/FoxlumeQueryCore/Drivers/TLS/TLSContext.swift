import Foundation
import Security

/// What `SocketTransport.startTLS` needs: the name to send and check, how to verify, and an optional client identity.
public struct TLSClientOptions: @unchecked Sendable {
    /// Host name for SNI and for the Verify Identity check.
    public var serverName: String
    public var verification: TLSVerification
    public var identity: TLSClientIdentity?

    public init(serverName: String, verification: TLSVerification, identity: TLSClientIdentity? = nil) {
        self.serverName = serverName
        self.verification = verification
        self.identity = identity
    }
}

/// The certificates of one connection, read once per connect from the files in its settings.
///
/// Like TablePro and libpq, the CA file only counts in the verify modes (Required encrypts without checking anything),
/// and the client certificate is offered in every TLS mode.
public struct TLSContext: @unchecked Sendable {
    public var mode: SSLMode
    public var anchors: [SecCertificate]?
    public var anchorsPath: String?
    public var identity: TLSClientIdentity?
    /// Overrides the host for SNI and name checks (the real server behind an SSH tunnel).
    public var serverName: String?

    public init(mode: SSLMode, anchors: [SecCertificate]? = nil, anchorsPath: String? = nil, identity: TLSClientIdentity? = nil, serverName: String? = nil) {
        self.mode = mode
        self.anchors = anchors
        self.anchorsPath = anchorsPath
        self.identity = identity
        self.serverName = serverName
    }

    /// Reads the files of `parameters`. File problems are thrown as `.connection` errors with a clear message.
    public static func load(_ parameters: ConnectionParameters) throws -> TLSContext {
        try load(mode: parameters.config.sslMode, files: parameters.config.tlsFiles, secret: parameters.tlsSecret, serverName: parameters.tlsServerName)
    }

    public static func load(mode: SSLMode, files: TLSCertificateFiles?, secret: String?, serverName: String? = nil) throws -> TLSContext {
        var context = TLSContext(mode: mode, serverName: serverName)
        guard mode.wantsTLS, let files = files?.trimmed else { return context }
        do {
            if mode.verifiesCertificate, !files.caCertificatePath.isEmpty {
                context.anchors = try TLSCredentials.certificates(atPath: files.caCertificatePath)
                context.anchorsPath = files.caCertificatePath
            }
            if !files.pkcs12Path.isEmpty {
                context.identity = try TLSCredentials.identity(pkcs12Path: files.pkcs12Path, password: secret)
            } else if !files.clientCertificatePath.isEmpty {
                context.identity = try TLSCredentials.identity(certificatePath: files.clientCertificatePath, keyPath: files.clientKeyPath, passphrase: secret)
            } else if !files.clientKeyPath.isEmpty {
                throw DatabaseError.connection("A client key is set without a client certificate. Choose the certificate that goes with the key.")
            }
        } catch let error as TLSFileError {
            throw DatabaseError.connection(error.localizedDescription)
        }
        return context
    }

    /// Options for one TLS session with `host`, in this context's mode or another one (Mongo and Redis may relax it).
    public func options(host: String, mode: SSLMode? = nil) -> TLSClientOptions {
        let mode = mode ?? self.mode
        let level: TLSVerification.Level = mode.verifiesHostname ? .chainAndHostname : (mode.verifiesCertificate ? .chain : .none)
        let verification = TLSVerification(level: level, anchors: level == .none ? nil : anchors, anchorsPath: anchorsPath)
        return TLSClientOptions(serverName: serverName ?? host, verification: verification, identity: identity)
    }
}

extension TLSCertificateFiles {
    /// Paths with surrounding spaces removed, or nil when nothing is set.
    var trimmed: TLSCertificateFiles? {
        let files = TLSCertificateFiles(
            caCertificatePath: caCertificatePath.trimmingCharacters(in: .whitespacesAndNewlines),
            clientCertificatePath: clientCertificatePath.trimmingCharacters(in: .whitespacesAndNewlines),
            clientKeyPath: clientKeyPath.trimmingCharacters(in: .whitespacesAndNewlines),
            pkcs12Path: pkcs12Path.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return files.isEmpty ? nil : files
    }
}

extension SocketTransport {
    /// Rewrites a failure of the first exchange after `startTLS` so it says what went wrong with TLS.
    /// `endpoint` nil gives "TLS handshake failed: …"; errors that are not about TLS come back unchanged.
    func tlsHandshakeError(_ error: Error, endpoint: String?) -> Error {
        guard isTLS, case DatabaseError.connection(let reason)? = error as? DatabaseError else { return error }
        let head = endpoint.map { "TLS handshake with \($0) failed" } ?? "TLS handshake failed"
        if let failure = tlsFailure {
            return DatabaseError.connection("\(head): \(failure.message)")
        }
        // After a completed handshake, a dropped connection is not a TLS problem.
        guard tlsProtocolVersion == nil else { return error }
        let detail = reason.hasPrefix("TLS error: ") ? String(reason.dropFirst(11)) : reason
        return DatabaseError.connection("\(head). \(detail)")
    }
}

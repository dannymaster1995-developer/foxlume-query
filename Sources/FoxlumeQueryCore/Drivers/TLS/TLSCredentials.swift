import Foundation
import Security

/// A client certificate with its private key, kept in memory only, plus any intermediate certificates to send.
public struct TLSClientIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public let certificate: SecCertificate
    /// Certificates sent after the leaf (intermediates), never the leaf itself.
    public let chain: [SecCertificate]

    /// Common name of the client certificate, for messages.
    public var subjectSummary: String {
        (SecCertificateCopySubjectSummary(certificate) as String?) ?? "client certificate"
    }
}

/// Reads certificate and key files for TLS. Nothing is imported into a keychain: certificates come from
/// `SecCertificateCreateWithData`, keys from `SecKeyCreateWithData`, identities from `SecIdentityCreate`.
public enum TLSCredentials {
    /// Every certificate in a PEM file (a CA bundle may hold several), or a single DER certificate.
    public static func certificates(atPath path: String) throws -> [SecCertificate] {
        let data = try read(path)
        return try certificates(in: data, path: path)
    }

    static func certificates(in data: Data, path: String) throws -> [SecCertificate] {
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1), text.contains("-----BEGIN") {
            let blocks = PEMBlock.all(in: text).filter { $0.label == "CERTIFICATE" || $0.label == "TRUSTED CERTIFICATE" || $0.label == "X509 CERTIFICATE" }
            guard !blocks.isEmpty else { throw TLSFileError.noCertificate(path: path) }
            return try blocks.map { block in
                guard let certificate = SecCertificateCreateWithData(nil, Data(block.der) as CFData) else {
                    throw TLSFileError.badCertificate(path: path)
                }
                return certificate
            }
        }
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw TLSFileError.noCertificate(path: path)
        }
        return [certificate]
    }

    /// A client identity from a PEM certificate (optionally followed by intermediates) and a PEM private key.
    /// An empty `keyPath` looks for the key in the certificate file (a combined PEM, as MongoDB uses).
    public static func identity(certificatePath: String, keyPath: String, passphrase: String?) throws -> TLSClientIdentity {
        let certificateData = try read(certificatePath)
        let certificates = try certificates(in: certificateData, path: certificatePath)
        let resolvedKeyPath = keyPath.isEmpty ? certificatePath : keyPath
        let keyData = keyPath.isEmpty ? certificateData : try read(keyPath)
        guard let keyText = String(data: keyData, encoding: .utf8) ?? String(data: keyData, encoding: .isoLatin1) else {
            throw TLSFileError.noPrivateKey(path: resolvedKeyPath)
        }
        let key = try PrivateKeyDecoder.key(from: PEMBlock.all(in: keyText), passphrase: passphrase, path: resolvedKeyPath)
        // The leaf is the certificate whose public key matches the private key, wherever it sits in the file.
        let publicKey = SecKeyCopyPublicKey(key).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? }
        let leafIndex = certificates.firstIndex { certificate in
            guard let publicKey, let certificateKey = SecCertificateCopyKey(certificate) else { return false }
            return (SecKeyCopyExternalRepresentation(certificateKey, nil) as Data?) == publicKey
        }
        guard let leafIndex, let identity = SecIdentityCreate(nil, certificates[leafIndex], key) else {
            throw TLSFileError.keyDoesNotMatch(certificate: certificatePath, key: resolvedKeyPath)
        }
        var others = certificates
        let leaf = others.remove(at: leafIndex)
        // Intermediates go with the certificate; a root in the file is left out, the server has its own copy.
        return TLSClientIdentity(identity: identity, certificate: leaf, chain: others.filter { !isSelfSigned($0) })
    }

    /// A client identity from a PKCS#12 (.p12/.pfx) file, imported in memory only. Needs macOS 15, the first release
    /// where `SecPKCS12Import` can skip the keychain.
    public static func identity(pkcs12Path path: String, password: String?) throws -> TLSClientIdentity {
        let data = try read(path)
        guard #available(macOS 15.0, *) else {
            throw TLSFileError.pkcs12(path: path, reason: "PKCS#12 files need macOS 15 or later. Convert it to PEM files with: openssl pkcs12 -in file.p12 -out client.pem -nodes")
        }
        let options: [CFString: Any] = [
            kSecImportExportPassphrase: password ?? "",
            kSecImportToMemoryOnly: true,
        ]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            break
        case errSecAuthFailed, errSecPkcs12VerifyFailure:
            throw TLSFileError.pkcs12(path: path, reason: (password ?? "").isEmpty ? "the file is protected by a password. Enter it as the passphrase." : "wrong password.")
        case errSecDecode:
            throw TLSFileError.pkcs12(path: path, reason: "the file is not a valid PKCS#12 archive.")
        default:
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw TLSFileError.pkcs12(path: path, reason: message)
        }
        guard let entries = items as? [[CFString: Any]],
              let entry = entries.first(where: { $0[kSecImportItemIdentity] != nil }),
              let value = entry[kSecImportItemIdentity] as CFTypeRef?, CFGetTypeID(value) == SecIdentityGetTypeID()
        else {
            throw TLSFileError.pkcs12(path: path, reason: "it contains no certificate with its private key.")
        }
        let identity = unsafeDowncast(value, to: SecIdentity.self)
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw TLSFileError.pkcs12(path: path, reason: "it contains no client certificate.")
        }
        let leafData = SecCertificateCopyData(certificate) as Data
        let others = (entry[kSecImportItemCertChain] as? [SecCertificate] ?? []).filter {
            SecCertificateCopyData($0) as Data != leafData
        }
        // Self-signed certificates in the archive are roots; servers have their own copy.
        let chain = others.filter { !isSelfSigned($0) }
        return TLSClientIdentity(identity: identity, certificate: certificate, chain: chain)
    }

    static func isSelfSigned(_ certificate: SecCertificate) -> Bool {
        guard let subject = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data?,
              let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate) as Data?
        else { return false }
        return subject == issuer
    }

    private static func read(_ path: String) throws -> Data {
        let expanded = (path as NSString).expandingTildeInPath
        do {
            return try Data(contentsOf: URL(fileURLWithPath: expanded))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw TLSFileError.unreadable(path: path, reason: "the file does not exist (\(expanded)).")
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw TLSFileError.unreadable(path: path, reason: "permission denied.")
        } catch {
            throw TLSFileError.unreadable(path: path, reason: error.localizedDescription)
        }
    }
}

// MARK: - Form checks

extension TLSCredentials {
    /// One line about a CA file for the connection form, for example "Foxlume Test CA, valid until 2036-10-12".
    /// Throws `TLSFileError` when the file cannot be used.
    public static func describeCertificates(atPath path: String) throws -> String {
        let certificates = try certificates(atPath: path)
        let names = certificates.map { (SecCertificateCopySubjectSummary($0) as String?) ?? "certificate" }
        if certificates.count == 1 {
            return names[0] + validitySuffix(certificates[0])
        }
        let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
        return "\(certificates.count) certificates: \(shown)"
    }

    /// One line about the client certificate as a connection would load it, for example
    /// "certuser, issued by Foxlume Test CA, valid until 2036-10-12". Throws `TLSFileError`.
    public static func describeClientIdentity(_ files: TLSCertificateFiles, secret: String?) throws -> String? {
        guard let files = files.trimmed, files.hasClientCertificate || !files.clientKeyPath.isEmpty else { return nil }
        let identity: TLSClientIdentity
        if !files.pkcs12Path.isEmpty {
            identity = try TLSCredentials.identity(pkcs12Path: files.pkcs12Path, password: secret)
        } else if !files.clientCertificatePath.isEmpty {
            identity = try TLSCredentials.identity(certificatePath: files.clientCertificatePath, keyPath: files.clientKeyPath, passphrase: secret)
        } else {
            return nil
        }
        var text = identity.subjectSummary
        if let issuer = issuerName(identity.certificate), issuer != text { text += ", issued by \(issuer)" }
        return text + validitySuffix(identity.certificate)
    }

    private static func issuerName(_ certificate: SecCertificate) -> String? {
        guard let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1IssuerName] as CFArray, nil) as? [CFString: Any],
              let issuer = values[kSecOIDX509V1IssuerName] as? [CFString: Any],
              let parts = issuer[kSecPropertyKeyValue] as? [[CFString: Any]]
        else { return nil }
        let commonName = parts.first { ($0[kSecPropertyKeyLabel] as? String) == (kSecOIDCommonName as String) }
        return commonName?[kSecPropertyKeyValue] as? String
    }

    private static func validitySuffix(_ certificate: SecCertificate) -> String {
        guard let validity = CertificateNames.validity(certificate) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        if validity.notAfter < Date() { return ", expired on \(formatter.string(from: validity.notAfter))" }
        if validity.notBefore > Date() { return ", not valid before \(formatter.string(from: validity.notBefore))" }
        return ", valid until \(formatter.string(from: validity.notAfter))"
    }
}

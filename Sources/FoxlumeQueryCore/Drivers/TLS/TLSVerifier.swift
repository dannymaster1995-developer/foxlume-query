import Darwin
import Foundation
import Security

/// A TLS problem, classified so the message can say what is wrong and what to change.
public struct TLSFailure: Error, Equatable, LocalizedError, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The chain does not lead to a trusted CA (the CA file, or the system roots without one).
        case unknownCA
        case hostnameMismatch
        case expired
        case notYetValid
        /// The chain is valid but unusable for another reason (bad signature, wrong key usage …).
        case untrusted
        /// The server refused the client certificate that was sent.
        case clientCertificateRejected
        /// The server wants a client certificate and none is configured.
        case clientCertificateRequired
        /// Any other handshake failure (protocol versions, ciphers, a non-TLS peer).
        case handshake
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// How the server certificate is checked, following libpq: the chain in Verify CA, chain and host name in
/// Verify Identity (verify-full), nothing in the other modes.
public struct TLSVerification: @unchecked Sendable {
    public enum Level: Sendable {
        case none
        case chain
        case chainAndHostname
    }

    public var level: Level
    /// The only trusted roots when set (libpq's `sslrootcert`); nil trusts the system roots.
    public var anchors: [SecCertificate]?
    /// Where the anchors came from, for messages.
    public var anchorsPath: String?

    public init(level: Level, anchors: [SecCertificate]? = nil, anchorsPath: String? = nil) {
        self.level = level
        self.anchors = anchors
        self.anchorsPath = anchorsPath
    }

    /// Checks the server's chain. `verifyDate` lets tests evaluate at another time.
    public func evaluate(_ trust: SecTrust, host: String, verifyDate: Date? = nil) -> TLSFailure? {
        guard level != .none else { return nil }
        // The basic X.509 policy checks signatures, validity and CA constraints like OpenSSL does. Apple's TLS
        // server policy would add rules (825-day lifetime, mandatory serverAuth EKU) that reject certificates
        // libpq and the MySQL clients accept from private CAs; the host name is checked below instead.
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        if let anchors {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        SecTrustSetNetworkFetchAllowed(trust, false)
        if let verifyDate { SecTrustSetVerifyDate(trust, verifyDate as CFDate) }

        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        guard let leaf = chain.first else {
            return TLSFailure(.untrusted, "The server sent no certificate.")
        }
        var error: CFError?
        if !SecTrustEvaluateWithError(trust, &error) {
            return classify(error, leaf: leaf, chain: chain, verifyDate: verifyDate)
        }
        if level == .chainAndHostname, !CertificateNames(leaf).matches(host: host) {
            let names = CertificateNames(leaf).displayNames
            let listed = names.isEmpty ? "no host name" : names.map { "\"\($0)\"" }.joined(separator: ", ")
            return TLSFailure(.hostnameMismatch, """
                Host name mismatch: the server certificate is for \(listed), not "\(host)". \
                Connect with a host name the certificate lists, or use SSL mode "\(SSLMode.verifyCA.displayName)" \
                to check the CA without the host name.
                """)
        }
        return nil
    }

    private func classify(_ error: CFError?, leaf: SecCertificate, chain: [SecCertificate], verifyDate: Date?) -> TLSFailure {
        let code = error.map { CFErrorGetCode($0) } ?? 0
        let detail = error.map { CFErrorCopyDescription($0) as String } ?? "unknown reason"
        let subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? "server"
        let now = verifyDate ?? Date()
        var status = OSStatus(truncatingIfNeeded: code)
        // Security reports both ends of the validity period as "expired"; the dates tell them apart.
        if status == errSecCertificateExpired || status == errSecCertificateNotValidYet {
            let early = ([leaf] + chain).contains { CertificateNames.validity($0).map { $0.notBefore > now } ?? false }
            status = early ? errSecCertificateNotValidYet : errSecCertificateExpired
        }
        switch status {
        case errSecCertificateExpired:
            let expired = chain.first { CertificateNames.validity($0).map { $0.notAfter < now } ?? false } ?? leaf
            let date = CertificateNames.validity(expired).map { " on \(Self.format($0.notAfter))" } ?? ""
            let which = expired == leaf ? "The server certificate \"\(subject)\"" : "The certificate \"\((SecCertificateCopySubjectSummary(expired) as String?) ?? "CA")\" in the server's chain"
            return TLSFailure(.expired, "\(which) expired\(date). Ask the server administrator to renew it.")
        case errSecCertificateNotValidYet:
            let date = CertificateNames.validity(leaf).map { " until \(Self.format($0.notBefore))" } ?? ""
            return TLSFailure(.notYetValid, "The server certificate \"\(subject)\" is not valid yet\(date). Check the clock on this Mac and on the server.")
        case errSecNotTrusted, errSecCreateChainFailed:
            let source: String
            if let anchorsPath {
                source = "the CA certificate \(TLSFileError.name(anchorsPath))"
            } else {
                source = "a certificate authority trusted by macOS"
            }
            return TLSFailure(.unknownCA, """
                The server certificate "\(subject)" could not be verified: it is not signed by \(source) (unknown CA). \
                Choose the CA certificate that issued the server's certificate, or use SSL mode \
                "\(SSLMode.require.displayName)" to encrypt without verifying.
                """)
        default:
            return TLSFailure(.untrusted, "The server certificate \"\(subject)\" could not be verified: \(detail)")
        }
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: date)
    }
}

/// Host names in a certificate: subject alternative names (DNS and IP), and the common name when there are none.
struct CertificateNames {
    var dnsNames: [String] = []
    var ipAddresses: [[UInt8]] = []
    var commonName: String?

    init(_ certificate: SecCertificate) {
        let der = [UInt8](SecCertificateCopyData(certificate) as Data)
        if let names = try? Self.subjectAltNames(der) {
            dnsNames = names.dns
            ipAddresses = names.ip
        }
        var name: CFString?
        if SecCertificateCopyCommonName(certificate, &name) == errSecSuccess {
            commonName = name as String?
        }
    }

    init(dnsNames: [String], ipAddresses: [[UInt8]] = [], commonName: String? = nil) {
        self.dnsNames = dnsNames
        self.ipAddresses = ipAddresses
        self.commonName = commonName
    }

    var displayNames: [String] {
        var names = dnsNames + ipAddresses.compactMap(Self.ipText)
        if names.isEmpty, let commonName { names.append(commonName) }
        return names
    }

    /// RFC 6125 matching as libpq does it: SANs win over the CN; `*` only as the whole leftmost label;
    /// IP literals match IP SANs (or a name spelled the same way).
    func matches(host rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if let address = Self.ipBytes(host) {
            if ipAddresses.contains(address) { return true }
            let names = dnsNames.isEmpty && ipAddresses.isEmpty ? [commonName].compactMap { $0 } : dnsNames
            return names.contains { $0.lowercased() == host }
        }
        let names = dnsNames.isEmpty && ipAddresses.isEmpty ? [commonName].compactMap { $0 } : dnsNames
        return names.contains { Self.match(pattern: $0, host: host) }
    }

    static func match(pattern rawPattern: String, host: String) -> Bool {
        var pattern = rawPattern.lowercased()
        if pattern.hasSuffix(".") { pattern.removeLast() }
        guard pattern.hasPrefix("*.") else { return pattern == host }
        let suffix = pattern.dropFirst(1) // ".example.com"
        guard suffix.split(separator: ".").count >= 2, host.hasSuffix(suffix) else { return false }
        let label = host.dropLast(suffix.count)
        return !label.isEmpty && !label.contains(".")
    }

    static func ipBytes(_ text: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    static func ipText(_ bytes: [UInt8]) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = bytes.count == 4 ? AF_INET : (bytes.count == 16 ? AF_INET6 : -1)
        guard family != -1 else { return nil }
        let ok = bytes.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &buffer, socklen_t(buffer.count)) } != nil
        return ok ? String(cString: buffer) : nil
    }

    // MARK: - Certificate DER

    private static let subjectAltNameOID = "2.5.29.17"

    /// TBSCertificate fields: [0] version?, serial, signature, issuer, validity, subject, spki, [1]?, [2]?, [3] extensions.
    private static func tbsFields(_ der: [UInt8]) throws -> [DERNode] {
        let certificate = try DER.parse(der).children()
        guard let tbs = certificate.first else { throw DERError("empty certificate") }
        return try tbs.children()
    }

    static func subjectAltNames(_ der: [UInt8]) throws -> (dns: [String], ip: [[UInt8]]) {
        let fields = try tbsFields(der)
        guard let extensionsWrapper = fields.first(where: { $0.tag == 0xa3 }) else { return ([], []) }
        var dns: [String] = []
        var ip: [[UInt8]] = []
        for item in try extensionsWrapper.child(0).children() {
            let parts = try item.children()
            guard parts.first?.objectIdentifier == subjectAltNameOID, let value = parts.last, value.tag == DERNode.octetString else { continue }
            for name in try DER.parse(value.content).children() {
                switch name.tag {
                case 0x82: dns.append(String(decoding: name.content, as: UTF8.self))
                case 0x87: ip.append(name.content)
                default: break
                }
            }
        }
        return (dns, ip)
    }

    /// notBefore / notAfter from the certificate (SecCertificate exposes them only on macOS 15).
    static func validity(_ certificate: SecCertificate) -> (notBefore: Date, notAfter: Date)? {
        guard let fields = try? tbsFields([UInt8](SecCertificateCopyData(certificate) as Data)) else { return nil }
        let offset = fields.first?.tag == 0xa0 ? 1 : 0
        guard fields.count > offset + 3, let times = try? fields[offset + 3].children(), times.count == 2,
              let start = time(times[0]), let end = time(times[1])
        else { return nil }
        return (start, end)
    }

    private static func time(_ node: DERNode) -> Date? {
        let text = String(decoding: node.content, as: UTF8.self)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        switch node.tag {
        case 0x17: formatter.dateFormat = "yyMMddHHmmss'Z'"
        case 0x18: formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        default: return nil
        }
        return formatter.date(from: text)
    }
}

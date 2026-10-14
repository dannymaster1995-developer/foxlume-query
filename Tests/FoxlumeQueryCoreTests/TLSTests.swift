import Foundation
import Security
import Testing
@testable import FoxlumeQueryCore

/// Certificates made at test time by `scripts/tls-test-certs.sh` (with /usr/bin/openssl) in the test temp folder.
enum TLSFixtures {
    static let directory: URL? = {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/tls-test-certs.sh")
        let output = TestFiles.url("fq-tls-fixtures")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["FOXLUME_TLS_DIR"] = output.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        return process.terminationStatus == 0 ? output : nil
    }()

    static var isAvailable: Bool { directory != nil }

    static func path(_ name: String) -> String {
        directory!.appendingPathComponent(name).path
    }

    static func certificate(_ name: String) throws -> SecCertificate {
        try #require(try TLSCredentials.certificates(atPath: path(name)).first)
    }

    /// A trust object for the server certificate as a TLS handshake would present it.
    static func serverTrust() throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates([try certificate("server.crt")] as CFArray, SecPolicyCreateBasicX509(), &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }
}

private func fileError(_ body: () throws -> Void) -> TLSFileError? {
    do {
        try body()
    } catch let error as TLSFileError {
        return error
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    return nil
}

// MARK: - DER and PEM

@Suite struct DERAndPEMTests {
    @Test func decodesObjectIdentifiersAndIntegers() throws {
        // SEQUENCE { OID 1.2.840.113549.1.1.1, INTEGER 2048 }
        let bytes: [UInt8] = [0x30, 0x0f, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x02, 0x02, 0x08, 0x00]
        let children = try DER.parse(bytes).children()
        #expect(children[0].objectIdentifier == "1.2.840.113549.1.1.1")
        #expect(children[1].intValue == 2048)
    }

    @Test func rejectsTruncatedAndTrailingData() {
        #expect(throws: DERError.self) { try DER.parse([0x30, 0x05, 0x02, 0x01]) }
        #expect(throws: DERError.self) { try DER.parse([0x02, 0x01, 0x05, 0x00]) }
    }

    @Test func readsBlocksHeadersAndSkipsText() {
        let text = """
            Bag Attributes
                friendlyName: test
            -----BEGIN CERTIFICATE-----
            AQID
            -----END CERTIFICATE-----
            -----BEGIN RSA PRIVATE KEY-----
            Proc-Type: 4,ENCRYPTED
            DEK-Info: AES-256-CBC,00112233445566778899AABBCCDDEEFF

            BAUG
            -----END RSA PRIVATE KEY-----
            """
        let blocks = PEMBlock.all(in: text)
        #expect(blocks.map(\.label) == ["CERTIFICATE", "RSA PRIVATE KEY"])
        #expect(blocks[0].der == [1, 2, 3])
        #expect(blocks[1].headers["Proc-Type"] == "4,ENCRYPTED")
        #expect(blocks[1].headers["DEK-Info"] == "AES-256-CBC,00112233445566778899AABBCCDDEEFF")
        #expect(blocks[1].der == [4, 5, 6])
    }
}

// MARK: - Certificates, keys and identities

@Suite(.enabled(if: TLSFixtures.isAvailable, "needs /usr/bin/openssl"))
struct TLSCredentialTests {
    @Test func loadsCABundleAndSingleCertificates() throws {
        let bundle = TestFiles.url("fq-tls-bundle-\(UUID().uuidString).pem")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let text = try String(contentsOfFile: TLSFixtures.path("ca.crt"), encoding: .utf8)
            + "\n# comment between certificates\n"
            + (try String(contentsOfFile: TLSFixtures.path("other-ca.crt"), encoding: .utf8))
        try text.write(to: bundle, atomically: true, encoding: .utf8)
        #expect(try TLSCredentials.certificates(atPath: bundle.path).count == 2)
        #expect(try TLSCredentials.describeCertificates(atPath: bundle.path).hasPrefix("2 certificates: Foxlume Test CA, Foxlume Other CA"))
        #expect(try TLSCredentials.describeCertificates(atPath: TLSFixtures.path("ca.crt")).hasPrefix("Foxlume Test CA, valid until "))
    }

    @Test func loadsDERCertificates() throws {
        let der = TestFiles.url("fq-tls-\(UUID().uuidString).der")
        defer { try? FileManager.default.removeItem(at: der) }
        try (SecCertificateCopyData(try TLSFixtures.certificate("ca.crt")) as Data).write(to: der)
        #expect(try TLSCredentials.certificates(atPath: der.path).count == 1)
    }

    @Test func reportsUnreadableAndWrongFiles() throws {
        guard case .unreadable(_, let reason)? = fileError({ _ = try TLSCredentials.certificates(atPath: "/nonexistent/ca.pem") }) else {
            Issue.record("Expected an unreadable file error")
            return
        }
        #expect(reason.contains("does not exist"))
        #expect(fileError { _ = try TLSCredentials.certificates(atPath: TLSFixtures.path("client.key")) } == .noCertificate(path: TLSFixtures.path("client.key")))
        let message = TLSFileError.unreadable(path: "/x/ca.pem", reason: "permission denied.").localizedDescription
        #expect(message == "Cannot read “ca.pem”: permission denied.")
    }

    @Test(arguments: ["client.key", "client-rsa.key"])
    func buildsIdentityFromPEMFiles(key: String) throws {
        let identity = try TLSCredentials.identity(certificatePath: TLSFixtures.path("client.crt"), keyPath: TLSFixtures.path(key), passphrase: nil)
        #expect(identity.subjectSummary == "certuser")
        #expect(identity.chain.isEmpty)
        var privateKey: SecKey?
        #expect(SecIdentityCopyPrivateKey(identity.identity, &privateKey) == errSecSuccess)
        // The key really signs: what TLS client authentication needs.
        let signature = SecKeyCreateSignature(try #require(privateKey), .rsaSignatureMessagePSSSHA256, Data("hello".utf8) as CFData, nil)
        #expect(signature != nil)
    }

    /// A P-256 key whose scalar starts with a zero byte, written by LibreSSL with that byte dropped (31 bytes).
    @Test func readsAShortECScalar() throws {
        let pem = """
            -----BEGIN EC PRIVATE KEY-----
            MHYCAQEEHyC0xu2CqkgbcucMgz8wKqLqZQWye4b9Y6DwpiICgTagCgYIKoZIzj0D
            AQehRANCAAQkf5N5SgOEqIKYfbxjpirjUxKjiTiOjJQOahOLNn+NagmJFaUqjsTq
            BLwIxtjfq22q3IQ2AmwMj3+wTNhucR4q
            -----END EC PRIVATE KEY-----
            """
        let key = try PrivateKeyDecoder.key(from: PEMBlock.all(in: pem), passphrase: nil, path: "short.key")
        let attributes = SecKeyCopyAttributes(key) as? [CFString: Any]
        #expect(attributes?[kSecAttrKeySizeInBits] as? Int == 256)
        // The public key recomputed from the padded scalar is the one stored in the file.
        let stored = Data(base64Encoded: "BCR/k3lKA4Sogph9vGOmKuNTEqOJOI6MlA5qE4s2f41qCYkVpSqOxOoEvAjG2N+rbarchDYCbAyPf7BM2G5xHio=")
        #expect(SecKeyCopyExternalRepresentation(try #require(SecKeyCopyPublicKey(key)), nil) as Data? == stored)
    }

    @Test func buildsIdentityFromAnECKey() throws {
        let identity = try TLSCredentials.identity(certificatePath: TLSFixtures.path("client-ec.crt"), keyPath: TLSFixtures.path("client-ec.key"), passphrase: nil)
        var privateKey: SecKey?
        #expect(SecIdentityCopyPrivateKey(identity.identity, &privateKey) == errSecSuccess)
        let signature = SecKeyCreateSignature(try #require(privateKey), .ecdsaSignatureMessageX962SHA256, Data("hello".utf8) as CFData, nil)
        #expect(signature != nil)
    }

    @Test(arguments: ["client-pkcs8-enc.key", "client-legacy-enc.key"])
    func decryptsEncryptedKeys(key: String) throws {
        let path = TLSFixtures.path(key)
        let certificate = TLSFixtures.path("client.crt")
        #expect(try TLSCredentials.identity(certificatePath: certificate, keyPath: path, passphrase: "secret").subjectSummary == "certuser")
        #expect(fileError { _ = try TLSCredentials.identity(certificatePath: certificate, keyPath: path, passphrase: "wrong") } == .wrongPassphrase(path: path))
        #expect(fileError { _ = try TLSCredentials.identity(certificatePath: certificate, keyPath: path, passphrase: nil) } == .passphraseRequired(path: path))
        #expect(TLSFileError.wrongPassphrase(path: path).localizedDescription == "Wrong passphrase for the client key “\(key)”.")
    }

    @Test func readsTheKeyFromACombinedFileAndSkipsTheRoot() throws {
        let combined = TestFiles.url("fq-tls-combined-\(UUID().uuidString).pem")
        defer { try? FileManager.default.removeItem(at: combined) }
        let text = try ["client-chain.crt", "client.key"].map { try String(contentsOfFile: TLSFixtures.path($0), encoding: .utf8) }.joined(separator: "\n")
        try text.write(to: combined, atomically: true, encoding: .utf8)
        let identity = try TLSCredentials.identity(certificatePath: combined.path, keyPath: "", passphrase: nil)
        #expect(identity.subjectSummary == "certuser")
        #expect(identity.chain.isEmpty)
    }

    @Test func rejectsAKeyOfAnotherCertificate() {
        let certificate = TLSFixtures.path("client.crt")
        let key = TLSFixtures.path("client-ec.key")
        #expect(fileError { _ = try TLSCredentials.identity(certificatePath: certificate, keyPath: key, passphrase: nil) } == .keyDoesNotMatch(certificate: certificate, key: key))
    }

    @Test func rejectsFilesWithoutAKey() {
        let path = TLSFixtures.path("ca.crt")
        #expect(fileError { _ = try TLSCredentials.identity(certificatePath: TLSFixtures.path("client.crt"), keyPath: path, passphrase: nil) } == .noPrivateKey(path: path))
    }

    @Test func importsPKCS12InMemory() throws {
        guard #available(macOS 15.0, *) else { return }
        let path = TLSFixtures.path("client.p12")
        let identity = try TLSCredentials.identity(pkcs12Path: path, password: "secret")
        #expect(identity.subjectSummary == "certuser")
        #expect(identity.chain.isEmpty, "the CA root in the archive is not sent")
        guard case .pkcs12(_, let reason)? = fileError({ _ = try TLSCredentials.identity(pkcs12Path: path, password: "wrong") }) else {
            Issue.record("Expected a PKCS#12 error")
            return
        }
        #expect(reason == "wrong password.")
        // Nothing reached a keychain: an in-memory import leaves no identity to find.
        let query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecMatchSubjectContains: "certuser", kSecMatchLimit: kSecMatchLimitAll]
        var found: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &found) == errSecItemNotFound)
    }

    @Test func describesTheClientIdentityForTheForm() throws {
        let files = TLSCertificateFiles(clientCertificatePath: TLSFixtures.path("client.crt"), clientKeyPath: TLSFixtures.path("client-pkcs8-enc.key"))
        let summary = try #require(try TLSCredentials.describeClientIdentity(files, secret: "secret"))
        #expect(summary.hasPrefix("certuser, issued by Foxlume Test CA, valid until "))
        #expect(try TLSCredentials.describeClientIdentity(TLSCertificateFiles(), secret: nil) == nil)
    }
}

// MARK: - Server certificate verification

@Suite(.enabled(if: TLSFixtures.isAvailable, "needs /usr/bin/openssl"))
struct TLSVerificationTests {
    private func verification(_ level: TLSVerification.Level, ca: String? = "ca.crt") throws -> TLSVerification {
        let anchors = try ca.map { [try TLSFixtures.certificate($0)] }
        return TLSVerification(level: level, anchors: anchors, anchorsPath: ca.map(TLSFixtures.path))
    }

    @Test func verifyCAAcceptsTheChainWhateverTheHost() throws {
        #expect(try verification(.chain).evaluate(TLSFixtures.serverTrust(), host: "127.0.0.1") == nil)
    }

    @Test func verifyIdentityChecksTheHostName() throws {
        #expect(try verification(.chainAndHostname).evaluate(TLSFixtures.serverTrust(), host: "localhost") == nil)
        #expect(try verification(.chainAndHostname).evaluate(TLSFixtures.serverTrust(), host: "LOCALHOST.") == nil)
        let failure = try #require(try verification(.chainAndHostname).evaluate(TLSFixtures.serverTrust(), host: "127.0.0.1"))
        #expect(failure.kind == .hostnameMismatch)
        #expect(failure.message.hasPrefix("Host name mismatch: the server certificate is for \"localhost\", not \"127.0.0.1\"."))
    }

    @Test func anotherCAIsAnUnknownCA() throws {
        let failure = try #require(try verification(.chain, ca: "other-ca.crt").evaluate(TLSFixtures.serverTrust(), host: "localhost"))
        #expect(failure.kind == .unknownCA)
        #expect(failure.message.contains("not signed by the CA certificate “other-ca.crt” (unknown CA)"))
    }

    @Test func systemTrustDoesNotKnowThePrivateCA() throws {
        let failure = try #require(try verification(.chain, ca: nil).evaluate(TLSFixtures.serverTrust(), host: "localhost"))
        #expect(failure.kind == .unknownCA)
        #expect(failure.message.contains("a certificate authority trusted by macOS"))
    }

    @Test func expiredAndNotYetValidCertificates() throws {
        let future = Date(timeIntervalSinceNow: 20 * 365 * 86_400)
        let expired = try #require(try verification(.chain).evaluate(TLSFixtures.serverTrust(), host: "localhost", verifyDate: future))
        #expect(expired.kind == .expired)
        #expect(expired.message.contains("expired on "))
        let past = Date(timeIntervalSinceNow: -365 * 86_400)
        let early = try #require(try verification(.chain).evaluate(TLSFixtures.serverTrust(), host: "localhost", verifyDate: past))
        #expect(early.kind == .notYetValid)
    }

    @Test func noVerificationAcceptsAnything() throws {
        #expect(try verification(.none, ca: "other-ca.crt").evaluate(TLSFixtures.serverTrust(), host: "elsewhere") == nil)
    }

    @Test func contextUsesTheCAOnlyInVerifyModes() throws {
        let files = TLSCertificateFiles(caCertificatePath: "/nonexistent/ca.pem")
        // Required ignores the CA (as TablePro and libpq's require without a root file), so a missing file is fine.
        let required = try TLSContext.load(mode: .require, files: files, secret: nil)
        #expect(required.anchors == nil)
        #expect(required.options(host: "h").verification.level == .none)
        guard case .connection(let message)? = captured({ try TLSContext.load(mode: .verifyCA, files: files, secret: nil) }) else {
            Issue.record("Expected a connection error")
            return
        }
        #expect(message.hasPrefix("Cannot read “ca.pem”"))
        let verifying = try TLSContext.load(mode: .verifyFull, files: TLSCertificateFiles(caCertificatePath: TLSFixtures.path("ca.crt")), secret: nil, serverName: "localhost")
        let options = verifying.options(host: "127.0.0.1")
        #expect(options.serverName == "localhost")
        #expect(options.verification.level == .chainAndHostname)
        #expect(verifying.options(host: "x", mode: .verifyCA).verification.level == .chain)
    }

    @Test func aKeyWithoutCertificateIsRefused() {
        let files = TLSCertificateFiles(clientKeyPath: TLSFixtures.path("client.key"))
        guard case .connection(let message)? = captured({ try TLSContext.load(mode: .require, files: files, secret: nil) }) else {
            Issue.record("Expected a connection error")
            return
        }
        #expect(message.contains("without a client certificate"))
    }

    private func captured(_ body: () throws -> TLSContext) -> DatabaseError? {
        do {
            _ = try body()
        } catch let error as DatabaseError {
            return error
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        return nil
    }
}

// MARK: - Host name matching

@Suite struct CertificateNameTests {
    @Test func wildcardsMatchOneLeftmostLabel() {
        let names = CertificateNames(dnsNames: ["*.db.example.com", "db.example.com"])
        #expect(names.matches(host: "eu.db.example.com"))
        #expect(names.matches(host: "db.example.com"))
        #expect(!names.matches(host: "a.b.db.example.com"))
        #expect(!names.matches(host: "example.com"))
        #expect(!CertificateNames(dnsNames: ["*.com"]).matches(host: "example.com"))
    }

    @Test func ipAddressesMatchIPEntries() {
        let names = CertificateNames(dnsNames: ["localhost"], ipAddresses: [[127, 0, 0, 1], CertificateNames.ipBytes("::1")!])
        #expect(names.matches(host: "127.0.0.1"))
        #expect(names.matches(host: "[::1]"))
        #expect(!names.matches(host: "10.0.0.1"))
        #expect(names.displayNames == ["localhost", "127.0.0.1", "::1"])
    }

    @Test func commonNameCountsOnlyWithoutSubjectAltNames() {
        #expect(CertificateNames(dnsNames: [], commonName: "db.local").matches(host: "db.local"))
        #expect(!CertificateNames(dnsNames: ["other.local"], commonName: "db.local").matches(host: "db.local"))
    }

    @Test(.enabled(if: TLSFixtures.isAvailable)) func readsSubjectAltNamesFromACertificate() throws {
        let names = CertificateNames(try TLSFixtures.certificate("server.crt"))
        #expect(names.dnsNames == ["localhost"])
        #expect(names.ipAddresses.isEmpty)
        #expect(names.commonName == "localhost")
    }
}

// MARK: - Settings

@Suite struct TLSSettingsTests {
    @Test func modesFollowLibpq() {
        #expect(SSLMode.allCases.map(\.libpqName) == ["disable", "prefer", "require", "verify-ca", "verify-full"])
        #expect(SSLMode.allCases.map(\.displayName) == ["Disabled", "Preferred", "Required", "Verify CA", "Verify Identity"])
        #expect(SSLMode.verifyCA.verifiesCertificate && !SSLMode.verifyCA.verifiesHostname && SSLMode.verifyCA.requiresTLS)
        #expect(SSLMode.verifyFull.verifiesHostname)
        #expect(!SSLMode.require.verifiesCertificate)
    }

    @Test func oldConnectionsDecodeAndFilesRoundTrip() throws {
        var config = ConnectionConfig(kind: .postgresql, host: "db", sslMode: .verifyCA)
        let old = try JSONEncoder().encode(config)
        #expect(!String(decoding: old, as: UTF8.self).contains("tlsFiles"))
        #expect(try JSONDecoder().decode(ConnectionConfig.self, from: old).tlsFiles == nil)

        config.certificates = TLSCertificateFiles(caCertificatePath: "/ca.pem", clientKeyPath: "/k.pem")
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: try JSONEncoder().encode(config))
        #expect(decoded.sslMode == .verifyCA)
        #expect(decoded.certificates == TLSCertificateFiles(caCertificatePath: "/ca.pem", clientKeyPath: "/k.pem"))
        // A partial object (another app version) still decodes.
        let partial = try JSONDecoder().decode(TLSCertificateFiles.self, from: Data(#"{"caCertificatePath":"/x"}"#.utf8))
        #expect(partial.caCertificatePath == "/x" && partial.pkcs12Path.isEmpty)

        config.certificates = TLSCertificateFiles()
        #expect(config.tlsFiles == nil)
    }

    @Test func passphrasesStayOutOfTheConfigFile() throws {
        let url = TestFiles.url("fq-tls-credentials-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileCredentialStore(url: url)
        let id = UUID()
        try store.setTLSSecret("key pass", for: id)
        #expect(store.tlsSecret(for: id) == "key pass")
        #expect(store.password(for: id) == nil)
        store.deleteTLSSecret(for: id)
        #expect(store.tlsSecret(for: id) == nil)
    }
}

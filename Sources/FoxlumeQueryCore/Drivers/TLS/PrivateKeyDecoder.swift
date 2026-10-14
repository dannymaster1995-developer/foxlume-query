import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Why a certificate or key file could not be used. The messages name the file and say what to do.
public enum TLSFileError: Error, Equatable, LocalizedError {
    case unreadable(path: String, reason: String)
    case noCertificate(path: String)
    case badCertificate(path: String)
    case noPrivateKey(path: String)
    case passphraseRequired(path: String)
    case wrongPassphrase(path: String)
    case unsupportedKey(path: String, reason: String)
    case malformedKey(path: String, reason: String)
    case keyDoesNotMatch(certificate: String, key: String)
    case pkcs12(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(path, reason):
            return "Cannot read \(Self.name(path)): \(reason)"
        case let .noCertificate(path):
            return "\(Self.name(path)) contains no certificate. Expected a PEM file (-----BEGIN CERTIFICATE-----) or a DER certificate."
        case let .badCertificate(path):
            return "\(Self.name(path)) contains a certificate that could not be parsed."
        case let .noPrivateKey(path):
            return "\(Self.name(path)) contains no private key. Expected a PEM key (-----BEGIN PRIVATE KEY-----)."
        case let .passphraseRequired(path):
            return "The client key \(Self.name(path)) is encrypted. Enter its passphrase."
        case let .wrongPassphrase(path):
            return "Wrong passphrase for the client key \(Self.name(path))."
        case let .unsupportedKey(path, reason):
            return "The client key \(Self.name(path)) is not supported: \(reason)"
        case let .malformedKey(path, reason):
            return "The client key \(Self.name(path)) could not be parsed: \(reason)"
        case let .keyDoesNotMatch(certificate, key):
            return "The client key \(Self.name(key)) does not belong to the client certificate \(Self.name(certificate))."
        case let .pkcs12(path, reason):
            return "Cannot use the PKCS#12 file \(Self.name(path)): \(reason)"
        }
    }

    static func name(_ path: String) -> String { "“\((path as NSString).lastPathComponent)”" }
}

/// Turns a PEM private key into an in-memory `SecKey`, decrypting it when needed. Nothing is written to a keychain.
///
/// Encodings: PKCS#8 (`PRIVATE KEY`), encrypted PKCS#8 (`ENCRYPTED PRIVATE KEY`, PBES2 with PBKDF2), PKCS#1
/// (`RSA PRIVATE KEY`) and SEC1 (`EC PRIVATE KEY`), the last two optionally with OpenSSL's legacy PEM encryption
/// (`Proc-Type: 4,ENCRYPTED` and `DEK-Info`). Key types: RSA and EC on P-256, P-384 and P-521.
enum PrivateKeyDecoder {
    static func key(from blocks: [PEMBlock], passphrase: String?, path: String) throws -> SecKey {
        let keyLabels: Set = ["PRIVATE KEY", "ENCRYPTED PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY"]
        guard let block = blocks.first(where: { keyLabels.contains($0.label) }) else {
            if blocks.contains(where: { $0.label == "OPENSSH PRIVATE KEY" }) {
                throw TLSFileError.unsupportedKey(path: path, reason: "OpenSSH keys cannot be used for TLS. Use a PEM key, for example the one your server administrator issued with the certificate.")
            }
            throw TLSFileError.noPrivateKey(path: path)
        }
        return try key(from: block, passphrase: passphrase, path: path)
    }

    static func key(from block: PEMBlock, passphrase: String?, path: String) throws -> SecKey {
        switch block.label {
        case "PRIVATE KEY":
            return try pkcs8Key(block.der, path: path, decrypted: false)
        case "ENCRYPTED PRIVATE KEY":
            guard let passphrase, !passphrase.isEmpty else { throw TLSFileError.passphraseRequired(path: path) }
            let plain = try decryptPKCS8(block.der, passphrase: passphrase, path: path)
            return try pkcs8Key(plain, path: path, decrypted: true)
        case "RSA PRIVATE KEY":
            let (der, decrypted) = try legacyDecrypt(block, passphrase: passphrase, path: path)
            return try rsaKey(pkcs1: der, path: path, decrypted: decrypted)
        case "EC PRIVATE KEY":
            let (der, decrypted) = try legacyDecrypt(block, passphrase: passphrase, path: path)
            return try ecKey(sec1: der, curveOID: nil, path: path, decrypted: decrypted)
        default:
            throw TLSFileError.noPrivateKey(path: path)
        }
    }

    // MARK: - Key structures

    private static let rsaEncryption = "1.2.840.113549.1.1.1"
    private static let ecPublicKey = "1.2.840.10045.2.1"
    private static let curves: [String: Int] = [
        "1.2.840.10045.3.1.7": 256, // prime256v1
        "1.3.132.0.34": 384, // secp384r1
        "1.3.132.0.35": 521, // secp521r1
    ]
    private static let unsupportedAlgorithms = [
        "1.3.101.112": "Ed25519 keys are not supported by macOS TLS. Use an RSA or ECDSA (P-256/P-384/P-521) key.",
        "1.3.101.113": "Ed448 keys are not supported by macOS TLS. Use an RSA or ECDSA (P-256/P-384/P-521) key.",
        "1.2.840.10040.4.1": "DSA keys are not supported. Use an RSA or ECDSA key.",
    ]

    /// PrivateKeyInfo: SEQUENCE { version, AlgorithmIdentifier, OCTET STRING privateKey, … }.
    /// `decrypted` marks DER that came out of a decryption: garbage there means a wrong passphrase.
    private static func pkcs8Key(_ der: [UInt8], path: String, decrypted: Bool) throws -> SecKey {
        let fields: [DERNode]
        let algorithm: [DERNode]
        do {
            fields = try DER.parse(der).children()
            guard fields.count >= 3, fields[2].tag == DERNode.octetString else { throw DERError("not a PKCS#8 key") }
            algorithm = try fields[1].children()
        } catch {
            if decrypted { throw TLSFileError.wrongPassphrase(path: path) }
            throw TLSFileError.malformedKey(path: path, reason: "\(error)")
        }
        let oid = algorithm.first?.objectIdentifier ?? ""
        switch oid {
        case rsaEncryption:
            return try rsaKey(pkcs1: fields[2].content, path: path, decrypted: decrypted)
        case ecPublicKey:
            let curve = algorithm.count > 1 ? algorithm[1].objectIdentifier : nil
            return try ecKey(sec1: fields[2].content, curveOID: curve, path: path, decrypted: decrypted)
        default:
            throw TLSFileError.unsupportedKey(path: path, reason: unsupportedAlgorithms[oid] ?? "unknown key algorithm \(oid).")
        }
    }

    private static func rsaKey(pkcs1 der: [UInt8], path: String, decrypted: Bool) throws -> SecKey {
        // Check the structure first: SecKeyCreateWithData accepts some garbage and fails later, during the handshake.
        do {
            let fields = try DER.parse(der).children()
            guard fields.count >= 9, fields.allSatisfy({ $0.tag == DERNode.integer }) else { throw DERError("not an RSA key") }
        } catch {
            if decrypted { throw TLSFileError.wrongPassphrase(path: path) }
            throw TLSFileError.malformedKey(path: path, reason: "\(error)")
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, &error) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "the RSA key was rejected"
            throw TLSFileError.malformedKey(path: path, reason: reason)
        }
        return key
    }

    /// ECPrivateKey: SEQUENCE { version 1, OCTET STRING privateKey, [0] parameters OPTIONAL, [1] publicKey OPTIONAL }.
    /// The public point is recomputed with CryptoKit, so keys without the optional [1] work too.
    private static func ecKey(sec1 der: [UInt8], curveOID: String?, path: String, decrypted: Bool) throws -> SecKey {
        let scalar: [UInt8]
        var curve = curveOID
        do {
            let fields = try DER.parse(der).children()
            guard fields.count >= 2, fields[0].intValue == 1, fields[1].tag == DERNode.octetString else {
                throw DERError("not an EC key")
            }
            scalar = fields[1].content
            if curve == nil, let parameters = fields.first(where: { $0.tag == 0xa0 }) {
                curve = try parameters.child(0).objectIdentifier
            }
        } catch {
            if decrypted { throw TLSFileError.wrongPassphrase(path: path) }
            throw TLSFileError.malformedKey(path: path, reason: "\(error)")
        }
        let bits = curve.flatMap { curves[$0] } ?? [32: 256, 48: 384, 66: 521][scalar.count]
        // Some encoders (LibreSSL among them) drop leading zero bytes of the scalar; CryptoKit wants the full width.
        let width = ((bits ?? 0) + 7) / 8
        let padded = scalar.count < width ? [UInt8](repeating: 0, count: width - scalar.count) + scalar : scalar
        let x963: Data
        do {
            switch bits {
            case 256: x963 = try P256.Signing.PrivateKey(rawRepresentation: padded).x963Representation
            case 384: x963 = try P384.Signing.PrivateKey(rawRepresentation: padded).x963Representation
            case 521: x963 = try P521.Signing.PrivateKey(rawRepresentation: padded).x963Representation
            default:
                throw TLSFileError.unsupportedKey(path: path, reason: "only the EC curves P-256, P-384 and P-521 are supported.")
            }
        } catch let error as TLSFileError {
            throw error
        } catch {
            if decrypted { throw TLSFileError.wrongPassphrase(path: path) }
            throw TLSFileError.malformedKey(path: path, reason: "invalid EC private key")
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(x963 as CFData, attributes as CFDictionary, &error) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "the EC key was rejected"
            throw TLSFileError.malformedKey(path: path, reason: reason)
        }
        return key
    }

    // MARK: - Encrypted PKCS#8 (PBES2)

    private static let pbes2 = "1.2.840.113549.1.5.13"
    private static let pbkdf2 = "1.2.840.113549.1.5.12"
    private static let prfs: [String: CCPseudoRandomAlgorithm] = [
        "1.2.840.113549.2.7": CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
        "1.2.840.113549.2.8": CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA224),
        "1.2.840.113549.2.9": CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
        "1.2.840.113549.2.10": CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384),
        "1.2.840.113549.2.11": CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
    ]

    struct Cipher {
        let algorithm: CCAlgorithm
        let keySize: Int
        let blockSize: Int
    }

    private static let pbes2Ciphers: [String: Cipher] = [
        "2.16.840.1.101.3.4.1.2": Cipher(algorithm: CCAlgorithm(kCCAlgorithmAES), keySize: 16, blockSize: 16),
        "2.16.840.1.101.3.4.1.22": Cipher(algorithm: CCAlgorithm(kCCAlgorithmAES), keySize: 24, blockSize: 16),
        "2.16.840.1.101.3.4.1.42": Cipher(algorithm: CCAlgorithm(kCCAlgorithmAES), keySize: 32, blockSize: 16),
        "1.2.840.113549.3.7": Cipher(algorithm: CCAlgorithm(kCCAlgorithm3DES), keySize: 24, blockSize: 8),
    ]

    /// EncryptedPrivateKeyInfo: SEQUENCE { AlgorithmIdentifier { pbes2, PBES2-params }, OCTET STRING encryptedData }.
    private static func decryptPKCS8(_ der: [UInt8], passphrase: String, path: String) throws -> [UInt8] {
        do {
            let top = try DER.parse(der).children()
            guard top.count == 2, top[1].tag == DERNode.octetString else { throw DERError("not an encrypted PKCS#8 key") }
            let algorithm = try top[0].children()
            guard algorithm.first?.objectIdentifier == pbes2, algorithm.count == 2 else {
                throw TLSFileError.unsupportedKey(path: path, reason: "only PBES2 encryption is supported (the default of OpenSSL 1.1 and later). Convert it with: openssl pkcs8 -topk8 -v2 aes-256-cbc")
            }
            let parameters = try algorithm[1].children()
            guard parameters.count == 2 else { throw DERError("bad PBES2 parameters") }
            let kdf = try parameters[0].children()
            guard kdf.first?.objectIdentifier == pbkdf2, kdf.count == 2 else {
                throw TLSFileError.unsupportedKey(path: path, reason: "only PBKDF2 key derivation is supported.")
            }
            let kdfParameters = try kdf[1].children()
            guard kdfParameters.count >= 2, kdfParameters[0].tag == DERNode.octetString, let iterations = kdfParameters[1].intValue else {
                throw DERError("bad PBKDF2 parameters")
            }
            let salt = kdfParameters[0].content
            var prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
            if let prfNode = kdfParameters.dropFirst(2).first(where: { $0.tag == DERNode.sequence }) {
                let prfOID = try prfNode.child(0).objectIdentifier ?? ""
                guard let known = prfs[prfOID] else {
                    throw TLSFileError.unsupportedKey(path: path, reason: "unknown PBKDF2 hash \(prfOID).")
                }
                prf = known
            }
            let scheme = try parameters[1].children()
            let schemeOID = scheme.first?.objectIdentifier ?? ""
            guard let cipher = pbes2Ciphers[schemeOID], scheme.count == 2, scheme[1].tag == DERNode.octetString else {
                throw TLSFileError.unsupportedKey(path: path, reason: "unknown key encryption \(schemeOID). Supported: AES-128/192/256-CBC and 3DES-CBC.")
            }
            let key = try pbkdf2Key(passphrase: passphrase, salt: salt, iterations: iterations, prf: prf, length: cipher.keySize)
            return try decryptCBC(top[1].content, key: key, iv: scheme[1].content, cipher: cipher, path: path)
        } catch let error as TLSFileError {
            throw error
        } catch {
            throw TLSFileError.malformedKey(path: path, reason: "\(error)")
        }
    }

    private static func pbkdf2Key(passphrase: String, salt: [UInt8], iterations: Int, prf: CCPseudoRandomAlgorithm, length: Int) throws -> [UInt8] {
        let password = Array(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBufferPointer { passwordBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) }, password.count,
                salt, salt.count, prf, UInt32(iterations), &derived, length
            )
        }
        guard status == kCCSuccess else { throw DERError("PBKDF2 failed (\(status))") }
        return derived
    }

    /// CBC with PKCS#7 padding. A padding error is the usual sign of a wrong passphrase.
    private static func decryptCBC(_ data: [UInt8], key: [UInt8], iv: [UInt8], cipher: Cipher, path: String) throws -> [UInt8] {
        guard iv.count == cipher.blockSize, data.count % cipher.blockSize == 0 else {
            throw TLSFileError.malformedKey(path: path, reason: "the encrypted key has a bad length")
        }
        var output = [UInt8](repeating: 0, count: data.count + cipher.blockSize)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), cipher.algorithm, CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv, data, data.count, &output, output.count, &moved
        )
        guard status == kCCSuccess else { throw TLSFileError.wrongPassphrase(path: path) }
        return Array(output[0..<moved])
    }

    // MARK: - Legacy OpenSSL PEM encryption

    private static let legacyCiphers: [String: Cipher] = [
        "AES-128-CBC": Cipher(algorithm: CCAlgorithm(kCCAlgorithmAES), keySize: 16, blockSize: 16),
        "AES-192-CBC": Cipher(algorithm: CCAlgorithm(kCCAlgorithmAES), keySize: 24, blockSize: 16),
        "AES-256-CBC": Cipher(algorithm: CCAlgorithm(kCCAlgorithmAES), keySize: 32, blockSize: 16),
        "DES-EDE3-CBC": Cipher(algorithm: CCAlgorithm(kCCAlgorithm3DES), keySize: 24, blockSize: 8),
        "DES-CBC": Cipher(algorithm: CCAlgorithm(kCCAlgorithmDES), keySize: 8, blockSize: 8),
    ]

    /// `Proc-Type: 4,ENCRYPTED` + `DEK-Info: AES-256-CBC,<hex IV>`; the key comes from OpenSSL's EVP_BytesToKey
    /// (MD5, one iteration, the first 8 IV bytes as salt). Returns the DER and whether it was decrypted.
    private static func legacyDecrypt(_ block: PEMBlock, passphrase: String?, path: String) throws -> ([UInt8], Bool) {
        guard let procType = block.headers["Proc-Type"], procType.uppercased().contains("ENCRYPTED") else {
            return (block.der, false)
        }
        guard let passphrase, !passphrase.isEmpty else { throw TLSFileError.passphraseRequired(path: path) }
        let info = (block.headers["DEK-Info"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard info.count == 2, let cipher = legacyCiphers[info[0].uppercased()], let iv = hexBytes(info[1]), iv.count == cipher.blockSize else {
            throw TLSFileError.unsupportedKey(path: path, reason: "unknown PEM encryption \"\(block.headers["DEK-Info"] ?? "")\". Supported: AES-128/192/256-CBC, DES-EDE3-CBC.")
        }
        let password = Array(passphrase.utf8)
        let salt = Array(iv.prefix(8))
        var key: [UInt8] = []
        var previous: [UInt8] = []
        while key.count < cipher.keySize {
            previous = Array(Insecure.MD5.hash(data: previous + password + salt))
            key += previous
        }
        let plain = try decryptCBC(block.der, key: Array(key.prefix(cipher.keySize)), iv: iv, cipher: cipher, path: path)
        return (plain, true)
    }

    private static func hexBytes(_ text: String) -> [UInt8]? {
        guard text.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

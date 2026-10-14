import CryptoKit
import Foundation
import Security

/// Password scrambles and RSA password encryption for the MySQL authentication plugins.
enum MySQLAuth {
    static let nativePassword = "mysql_native_password"
    static let cachingSHA2Password = "caching_sha2_password"
    static let clearPassword = "mysql_clear_password"

    static let supportedPlugins: Set<String> = [nativePassword, cachingSHA2Password, clearPassword]

    /// caching_sha2_password AuthMoreData status bytes and the public key request.
    static let fastAuthSuccess: UInt8 = 0x03
    static let performFullAuthentication: UInt8 = 0x04
    static let requestPublicKey: UInt8 = 0x02

    /// mysql_native_password: SHA1(password) XOR SHA1(scramble + SHA1(SHA1(password))).
    static func nativePasswordScramble(password: String, scramble: [UInt8]) -> [UInt8] {
        guard !password.isEmpty else { return [] }
        let stage1 = Array(Insecure.SHA1.hash(data: Array(password.utf8)))
        let stage2 = Array(Insecure.SHA1.hash(data: stage1))
        let mix = Array(Insecure.SHA1.hash(data: scramble + stage2))
        return xor(stage1, mix)
    }

    /// caching_sha2_password: SHA256(password) XOR SHA256(SHA256(SHA256(password)) + scramble).
    static func cachingSHA2Scramble(password: String, scramble: [UInt8]) -> [UInt8] {
        guard !password.isEmpty else { return [] }
        let stage1 = Array(SHA256.hash(data: Array(password.utf8)))
        let stage2 = Array(SHA256.hash(data: stage1))
        let mix = Array(SHA256.hash(data: stage2 + scramble))
        return xor(stage1, mix)
    }

    /// The password and its NUL terminator, sent as is. Only ever used over TLS.
    static func cleartext(_ password: String) -> [UInt8] {
        Array(password.utf8) + [0]
    }

    /// RSA-OAEP(SHA1) of (password + NUL) XOR the scramble repeated, for caching_sha2_password full
    /// authentication without TLS. `publicKeyPEM` is the key the server sent.
    static func encryptPassword(_ password: String, scramble: [UInt8], publicKeyPEM: [UInt8]) throws -> [UInt8] {
        guard !scramble.isEmpty else { throw DatabaseError.protocolViolation("Missing authentication scramble") }
        let plain = cleartext(password)
        var obfuscated = [UInt8](repeating: 0, count: plain.count)
        for index in plain.indices {
            obfuscated[index] = plain[index] ^ scramble[index % scramble.count]
        }
        let key = try publicKey(fromPEM: publicKeyPEM)
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(obfuscated) as CFData, &error) else {
            let reason = error.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? "unknown error"
            throw DatabaseError.authentication("Cannot encrypt the password with the server's public key: \(reason)")
        }
        return [UInt8](encrypted as Data)
    }

    static func publicKey(fromPEM pem: [UInt8]) throws -> SecKey {
        let der = try derFromPEM(pem)
        // Security wants a PKCS#1 RSAPublicKey; the server sends a SubjectPublicKeyInfo around one.
        var candidates: [[UInt8]] = []
        if let pkcs1 = pkcs1PublicKey(fromSubjectPublicKeyInfo: der) { candidates.append(pkcs1) }
        candidates.append(der)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var lastError = "unrecognized key format"
        for candidate in candidates {
            var error: Unmanaged<CFError>?
            if let key = SecKeyCreateWithData(Data(candidate) as CFData, attributes as CFDictionary, &error) {
                return key
            }
            if let error { lastError = (error.takeRetainedValue() as Error).localizedDescription }
        }
        throw DatabaseError.authentication("The server sent an unusable RSA public key: \(lastError)")
    }

    /// Base64 body of a PEM block, decoded.
    static func derFromPEM(_ pem: [UInt8]) throws -> [UInt8] {
        let text = String(decoding: pem, as: UTF8.self)
        let body = text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        guard !body.isEmpty, let data = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else {
            throw DatabaseError.authentication("The server sent an unreadable RSA public key.")
        }
        return [UInt8](data)
    }

    /// Extract the RSAPublicKey from SubjectPublicKeyInfo:
    /// SEQUENCE { SEQUENCE { OID, params }, BIT STRING { 0x00, RSAPublicKey } }.
    /// Returns nil when `der` is not an SPKI, for example when it is already PKCS#1.
    static func pkcs1PublicKey(fromSubjectPublicKeyInfo der: [UInt8]) -> [UInt8]? {
        var outer = DERReader(der[...])
        guard let spki = outer.next(), spki.tag == 0x30 else { return nil }
        var inner = DERReader(spki.content)
        guard let algorithm = inner.next(), algorithm.tag == 0x30,
              let bitString = inner.next(), bitString.tag == 0x03,
              bitString.content.first == 0x00
        else { return nil }
        let key = bitString.content.dropFirst()
        guard key.first == 0x30 else { return nil }
        return Array(key)
    }

    private static func xor(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        zip(lhs, rhs).map { $0 ^ $1 }
    }
}

/// Minimal DER walker: enough to unwrap a SubjectPublicKeyInfo.
private struct DERReader {
    struct Element {
        var tag: UInt8
        var content: ArraySlice<UInt8>
    }

    private var bytes: ArraySlice<UInt8>

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
    }

    mutating func next() -> Element? {
        var index = bytes.startIndex
        guard index < bytes.endIndex else { return nil }
        let tag = bytes[index]
        index += 1
        guard index < bytes.endIndex else { return nil }
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, index + count <= bytes.endIndex else { return nil }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
        }
        guard length >= 0, index + length <= bytes.endIndex else { return nil }
        let content = bytes[index..<(index + length)]
        bytes = bytes[(index + length)...]
        return Element(tag: tag, content: content)
    }
}

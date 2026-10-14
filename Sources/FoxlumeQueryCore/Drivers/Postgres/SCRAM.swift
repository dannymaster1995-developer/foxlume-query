import CommonCrypto
import CryptoKit
import Foundation

/// SCRAM-SHA-256 client (RFC 5802, RFC 7677) without channel binding, as PostgreSQL uses it.
public struct SCRAMSHA256Client {
    public static let mechanism = "SCRAM-SHA-256"
    public static let channelBindingMechanism = "SCRAM-SHA-256-PLUS"
    /// `n,,`: the client does not support channel binding and sends no authorization identity.
    private static let gs2Header = "n,,"

    public let clientFirstMessageBare: String
    private let clientNonce: String
    private let password: [UInt8]
    private var expectedServerSignature: [UInt8]?

    /// PostgreSQL ignores the SCRAM user name in favor of the startup user, so libpq sends an empty one.
    public init(username: String = "", password: String, clientNonce: String = SCRAMSHA256Client.makeNonce()) {
        self.clientNonce = clientNonce
        self.password = Array(Self.saslPrep(password).utf8)
        clientFirstMessageBare = "n=\(Self.escapeName(username)),r=\(clientNonce)"
    }

    public var clientFirstMessage: String { Self.gs2Header + clientFirstMessageBare }

    /// Consume server-first-message and produce client-final-message with the proof.
    public mutating func clientFinalMessage(serverFirstMessage: String) throws -> String {
        let attributes = Self.attributes(serverFirstMessage)
        if attributes["m"] != nil {
            throw DatabaseError.authentication("SCRAM: the server requires an unsupported extension.")
        }
        guard let nonce = attributes["r"], nonce.hasPrefix(clientNonce), nonce.count > clientNonce.count else {
            throw DatabaseError.authentication("SCRAM: the server nonce does not extend the client nonce.")
        }
        guard let saltText = attributes["s"], let salt = Data(base64Encoded: saltText), !salt.isEmpty else {
            throw DatabaseError.authentication("SCRAM: the server sent an invalid salt.")
        }
        guard let iterationText = attributes["i"], let iterations = UInt32(iterationText), iterations > 0 else {
            throw DatabaseError.authentication("SCRAM: the server sent an invalid iteration count.")
        }

        let channelBinding = Data(Self.gs2Header.utf8).base64EncodedString()
        let finalWithoutProof = "c=\(channelBinding),r=\(nonce)"
        let authMessage = Array("\(clientFirstMessageBare),\(serverFirstMessage),\(finalWithoutProof)".utf8)

        let saltedPassword = try Self.pbkdf2SHA256(password: password, salt: [UInt8](salt), iterations: iterations)
        let clientKey = Self.hmac(key: saltedPassword, Array("Client Key".utf8))
        let storedKey = Array(SHA256.hash(data: clientKey))
        let clientSignature = Self.hmac(key: storedKey, authMessage)
        let proof = zip(clientKey, clientSignature).map { $0 ^ $1 }
        let serverKey = Self.hmac(key: saltedPassword, Array("Server Key".utf8))
        expectedServerSignature = Self.hmac(key: serverKey, authMessage)

        return "\(finalWithoutProof),p=\(Data(proof).base64EncodedString())"
    }

    /// Check server-final-message. Proves the server knows the password verifier, not just that it accepted us.
    public func verifyServerFinal(_ message: String) throws {
        let attributes = Self.attributes(message)
        if let error = attributes["e"] {
            throw DatabaseError.authentication("SCRAM: the server rejected the authentication (\(error)).")
        }
        guard let expected = expectedServerSignature else {
            throw DatabaseError.authentication("SCRAM: the server finished before the client proof was sent.")
        }
        guard let verifier = attributes["v"], let signature = Data(base64Encoded: verifier),
              Self.constantTimeEqual([UInt8](signature), expected)
        else {
            throw DatabaseError.authentication("SCRAM: the server signature is invalid. The server may not be who it claims to be.")
        }
    }

    public static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<18).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
    }

    // MARK: - Helpers

    /// Split `a=1,b=2` at the first `=` of each part; base64 values may contain more.
    private static func attributes(_ message: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in message.split(separator: ",", omittingEmptySubsequences: true) {
            guard let equals = part.firstIndex(of: "="), part.distance(from: part.startIndex, to: equals) == 1 else { continue }
            result[String(part[..<equals])] = String(part[part.index(after: equals)...])
        }
        return result
    }

    private static func escapeName(_ name: String) -> String {
        name.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
    }

    private static func hmac(key: [UInt8], _ message: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    private static func pbkdf2SHA256(password: [UInt8], salt: [UInt8], iterations: UInt32) throws -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let derivedCount = derived.count
        let status = password.withUnsafeBufferPointer { passwordBuffer in
            salt.withUnsafeBufferPointer { saltBuffer in
                derived.withUnsafeMutableBufferPointer { output in
                    passwordBuffer.withMemoryRebound(to: CChar.self) { passwordChars in
                        CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2),
                            passwordChars.baseAddress, passwordChars.count,
                            saltBuffer.baseAddress, saltBuffer.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                            iterations,
                            output.baseAddress, derivedCount
                        )
                    }
                }
            }
        }
        guard status == Int32(kCCSuccess) else {
            throw DatabaseError.authentication("SCRAM: key derivation failed (\(status)).")
        }
        return derived
    }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }

    // MARK: - SASLprep

    /// SASLprep (RFC 4013) as PostgreSQL applies it: when the password is not valid for SASLprep,
    /// both the server and libpq fall back to the raw bytes, so this does the same.
    /// Unicode 3.2 unassigned code points and the bidi rules are not checked.
    static func saslPrep(_ password: String) -> String {
        guard password.unicodeScalars.contains(where: { !$0.isASCII }) else { return password }
        var mapped = String.UnicodeScalarView()
        for scalar in password.unicodeScalars {
            if nonASCIISpaces.contains(where: { $0.contains(scalar.value) }) {
                mapped.append(" ")
            } else if !mappedToNothing.contains(where: { $0.contains(scalar.value) }) {
                mapped.append(scalar)
            }
        }
        let normalized = String(mapped).precomposedStringWithCompatibilityMapping
        guard !normalized.isEmpty else { return password }
        for scalar in normalized.unicodeScalars where isProhibited(scalar.value) {
            return password
        }
        return normalized
    }

    private static let nonASCIISpaces: [ClosedRange<UInt32>] = [
        0x00A0...0x00A0, 0x1680...0x1680, 0x2000...0x200B, 0x202F...0x202F, 0x205F...0x205F, 0x3000...0x3000,
    ]

    private static let mappedToNothing: [ClosedRange<UInt32>] = [
        0x00AD...0x00AD, 0x034F...0x034F, 0x1806...0x1806, 0x180B...0x180D, 0x200C...0x200D,
        0x2060...0x2060, 0xFE00...0xFE0F, 0xFEFF...0xFEFF,
    ]

    private static let prohibited: [ClosedRange<UInt32>] = [
        0x0000...0x001F, 0x007F...0x009F, 0x0340...0x0341, 0x06DD...0x06DD, 0x070F...0x070F,
        0x180E...0x180E, 0x200C...0x200F, 0x2028...0x202E, 0x2060...0x2063, 0x206A...0x206F,
        0x2FF0...0x2FFB, 0xD800...0xDFFF, 0xE000...0xF8FF, 0xFDD0...0xFDEF, 0xFEFF...0xFEFF,
        0xFFF9...0xFFFF, 0x1D173...0x1D17A, 0xE0001...0xE0001, 0xE0020...0xE007F,
        0xF0000...0xFFFFD, 0x100000...0x10FFFD,
    ]

    private static func isProhibited(_ value: UInt32) -> Bool {
        if value & 0xFFFE == 0xFFFE { return true }
        return prohibited.contains { $0.contains(value) }
    }
}

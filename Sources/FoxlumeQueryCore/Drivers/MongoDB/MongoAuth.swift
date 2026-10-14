import CommonCrypto
import CryptoKit
import Foundation

public enum MongoAuthMechanism: String, Sendable, CaseIterable {
    case scramSHA1 = "SCRAM-SHA-1"
    case scramSHA256 = "SCRAM-SHA-256"
    case plain = "PLAIN"
    case x509 = "MONGODB-X509"
    case aws = "MONGODB-AWS"
    case gssapi = "GSSAPI"

    /// Accepts the spellings people type, such as `scram-sha-256` or `X.509`.
    public init?(userText: String) {
        let normalized = userText.uppercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "")
        switch normalized {
        case "SCRAM-SHA-1", "SCRAMSHA1", "SCRAM-SHA1": self = .scramSHA1
        case "SCRAM-SHA-256", "SCRAMSHA256", "SCRAM-SHA256": self = .scramSHA256
        case "PLAIN", "LDAP": self = .plain
        case "MONGODB-X509", "X509", "X.509": self = .x509
        case "MONGODB-AWS", "AWS", "AWSIAM", "AWS-IAM": self = .aws
        case "GSSAPI", "KERBEROS": self = .gssapi
        default: return nil
        }
    }

    /// Mechanisms whose users live in `$external` regardless of the database.
    var usesExternalSource: Bool { self == .plain || self == .x509 || self == .aws || self == .gssapi }
}

/// Who to authenticate as and where the user is defined.
struct MongoCredential: Sendable {
    var user: String
    var password: String
    var source: String
    var mechanism: MongoAuthMechanism?
}

/// A SCRAM client (RFC 5802, RFC 7677) as MongoDB uses it, without channel binding.
///
/// SCRAM-SHA-1 hashes the hex MD5 of `user:mongo:password` instead of the password itself;
/// SCRAM-SHA-256 applies SASLprep to the password.
public struct MongoSCRAMClient {
    public enum Hash: Sendable {
        case sha1
        case sha256
    }

    private static let gs2Header = "n,,"
    /// The MongoDB auth specification requires refusing fewer iterations than this.
    static let minimumIterations: UInt32 = 4096

    public let hash: Hash
    public let clientFirstMessageBare: String
    private let clientNonce: String
    private let password: [UInt8]
    private var expectedServerSignature: [UInt8]?

    /// `preparedPassword` is what goes into the key derivation: already digested or SASLprep'd.
    public init(hash: Hash, username: String, preparedPassword: String, clientNonce: String = SCRAMSHA256Client.makeNonce()) {
        self.hash = hash
        self.clientNonce = clientNonce
        password = Array(preparedPassword.utf8)
        clientFirstMessageBare = "n=\(Self.escapeName(username)),r=\(clientNonce)"
    }

    public static func mongo(mechanism: MongoAuthMechanism, username: String, password: String, clientNonce: String = SCRAMSHA256Client.makeNonce()) -> MongoSCRAMClient {
        switch mechanism {
        case .scramSHA1:
            return MongoSCRAMClient(hash: .sha1, username: username, preparedPassword: mongoPasswordDigest(username: username, password: password), clientNonce: clientNonce)
        default:
            return MongoSCRAMClient(hash: .sha256, username: username, preparedPassword: SCRAMSHA256Client.saslPrep(password), clientNonce: clientNonce)
        }
    }

    /// The legacy MongoDB password digest: hex MD5 of `user:mongo:password`.
    public static func mongoPasswordDigest(username: String, password: String) -> String {
        Data(Insecure.MD5.hash(data: Data("\(username):mongo:\(password)".utf8))).hexString
    }

    public var clientFirstMessage: String { Self.gs2Header + clientFirstMessageBare }

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
        guard let iterationText = attributes["i"], let iterations = UInt32(iterationText), iterations >= Self.minimumIterations else {
            throw DatabaseError.authentication("SCRAM: the server sent an invalid or too small iteration count.")
        }

        let channelBinding = Data(Self.gs2Header.utf8).base64EncodedString()
        let finalWithoutProof = "c=\(channelBinding),r=\(nonce)"
        let authMessage = Array("\(clientFirstMessageBare),\(serverFirstMessage),\(finalWithoutProof)".utf8)

        let saltedPassword = try pbkdf2(salt: [UInt8](salt), iterations: iterations)
        let clientKey = hmac(key: saltedPassword, Array("Client Key".utf8))
        let storedKey = digest(clientKey)
        let clientSignature = hmac(key: storedKey, authMessage)
        let proof = zip(clientKey, clientSignature).map { $0 ^ $1 }
        let serverKey = hmac(key: saltedPassword, Array("Server Key".utf8))
        expectedServerSignature = hmac(key: serverKey, authMessage)
        return "\(finalWithoutProof),p=\(Data(proof).base64EncodedString())"
    }

    /// Proves the server knows the password verifier, not just that it accepted the client.
    public func verifyServerFinal(_ message: String) throws {
        let attributes = Self.attributes(message)
        if let error = attributes["e"] {
            throw DatabaseError.authentication("SCRAM: the server rejected the authentication (\(error)).")
        }
        guard let expected = expectedServerSignature else {
            throw DatabaseError.authentication("SCRAM: the server finished before the client proof was sent.")
        }
        guard let verifier = attributes["v"], let signature = Data(base64Encoded: verifier), Self.constantTimeEqual([UInt8](signature), expected) else {
            throw DatabaseError.authentication("SCRAM: the server signature is invalid. The server may not be who it claims to be.")
        }
    }

    // MARK: Helpers

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

    private func hmac(key: [UInt8], _ message: [UInt8]) -> [UInt8] {
        switch hash {
        case .sha1: return Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        case .sha256: return Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        }
    }

    private func digest(_ data: [UInt8]) -> [UInt8] {
        switch hash {
        case .sha1: return Array(Insecure.SHA1.hash(data: data))
        case .sha256: return Array(SHA256.hash(data: data))
        }
    }

    private func pbkdf2(salt: [UInt8], iterations: UInt32) throws -> [UInt8] {
        let length = hash == .sha1 ? Int(CC_SHA1_DIGEST_LENGTH) : Int(CC_SHA256_DIGEST_LENGTH)
        let algorithm = CCPseudoRandomAlgorithm(hash == .sha1 ? kCCPRFHmacAlgSHA1 : kCCPRFHmacAlgSHA256)
        var derived = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBufferPointer { passwordBuffer in
            salt.withUnsafeBufferPointer { saltBuffer in
                derived.withUnsafeMutableBufferPointer { output in
                    passwordBuffer.withMemoryRebound(to: CChar.self) { passwordChars in
                        CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2),
                            passwordChars.baseAddress, passwordChars.count,
                            saltBuffer.baseAddress, saltBuffer.count,
                            algorithm, iterations,
                            output.baseAddress, length
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
}

/// Runs the SASL conversation (`saslStart` / `saslContinue`) on a freshly opened link.
enum MongoAuthenticator {
    /// SCRAM-SHA-256 when the server lists it for this user, otherwise SCRAM-SHA-1, as the driver spec says.
    static func negotiate(_ supported: [String]?) -> MongoAuthMechanism {
        guard let supported, supported.contains(MongoAuthMechanism.scramSHA256.rawValue) else { return .scramSHA1 }
        return .scramSHA256
    }

    static func authenticate(_ link: MongoLink, credential: MongoCredential) throws {
        let mechanism = credential.mechanism ?? negotiate(link.hello.saslSupportedMechs)
        do {
            switch mechanism {
            case .scramSHA1, .scramSHA256:
                try scram(link, credential: credential, mechanism: mechanism)
            case .plain:
                try plain(link, credential: credential)
            case .x509, .aws, .gssapi:
                throw DatabaseError.unsupported("The \(mechanism.rawValue) authentication mechanism is not supported. Use SCRAM-SHA-256, SCRAM-SHA-1 or PLAIN.")
            }
        } catch let error as MongoServerError {
            throw DatabaseError.authentication("Authentication failed for user \"\(credential.user)\" on database \"\(credential.source)\" (\(mechanism.rawValue)): \(error.message)")
        }
    }

    private static func payload(_ text: String) -> BSONValue {
        .binary(subtype: 0, data: Data(text.utf8))
    }

    private static func payloadText(_ reply: BSONDocument) -> String {
        if case .binary(_, let data)? = reply["payload"] { return String(decoding: data, as: UTF8.self) }
        return reply["payload"]?.stringValue ?? ""
    }

    private static func scram(_ link: MongoLink, credential: MongoCredential, mechanism: MongoAuthMechanism) throws {
        var client = MongoSCRAMClient.mongo(mechanism: mechanism, username: credential.user, password: credential.password)
        let start = try link.command([
            "saslStart": .int32(1),
            "mechanism": .string(mechanism.rawValue),
            "payload": payload(client.clientFirstMessage),
            "autoAuthorize": .int32(1),
            "options": .document(["skipEmptyExchange": .bool(true)]),
        ], database: credential.source)
        guard let conversation = start["conversationId"] else {
            throw DatabaseError.protocolViolation("saslStart reply without a conversation id")
        }
        let final = try client.clientFinalMessage(serverFirstMessage: payloadText(start))
        var reply = try link.command([
            "saslContinue": .int32(1),
            "conversationId": conversation,
            "payload": payload(final),
        ], database: credential.source)
        try client.verifyServerFinal(payloadText(reply))
        // Servers that ignore skipEmptyExchange expect one more empty round.
        var rounds = 0
        while reply["done"]?.boolValue != true {
            rounds += 1
            guard rounds < 3 else { throw DatabaseError.protocolViolation("The SASL conversation did not finish") }
            reply = try link.command([
                "saslContinue": .int32(1),
                "conversationId": conversation,
                "payload": .binary(subtype: 0, data: Data()),
            ], database: credential.source)
        }
    }

    private static func plain(_ link: MongoLink, credential: MongoCredential) throws {
        let message = "\0\(credential.user)\0\(credential.password)"
        let reply = try link.command([
            "saslStart": .int32(1),
            "mechanism": .string("PLAIN"),
            "payload": payload(message),
            "autoAuthorize": .int32(1),
        ], database: credential.source)
        guard reply["done"]?.boolValue == true else {
            throw DatabaseError.protocolViolation("PLAIN authentication did not finish in one step")
        }
    }
}

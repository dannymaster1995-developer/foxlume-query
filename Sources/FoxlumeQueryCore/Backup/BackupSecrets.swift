import Foundation
import Security

/// A private folder (0700) for the files a tool reads its password and client key from, each 0600. Removed by
/// `remove()`, and by `deinit` as a fallback, so nothing is left behind when a run ends in any way.
public final class BackupSecretDirectory: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var removed = false

    /// Creates a new folder inside `parent`, by default the temporary folder (TMPDIR).
    public init(parent: URL? = nil) throws {
        let base = parent ?? Self.defaultParent
        url = base.appendingPathComponent("foxlume-backup-\(UUID().uuidString.prefix(12))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // createDirectory applies the umask; set the mode explicitly.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    deinit { remove() }

    /// TMPDIR when set (the per-user temporary folder for apps; the project's own for tests), else the system's.
    static var defaultParent: URL {
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty {
            return URL(fileURLWithPath: tmp, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// Writes each file readable and writable by the user only. The file is created with mode 0600 before any byte
    /// is written, so the secret is never readable by others, not even for a moment.
    public func write(_ files: [BackupSecretFile]) throws {
        for file in files {
            try Self.writePrivately(Data(file.contents.utf8), to: file.path)
        }
    }

    static func writePrivately(_ data: Data, to path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw BackupError.unsupported("Could not write a temporary file for the backup tool (\(String(cString: strerror(errno)))).")
        }
        defer { close(descriptor) }
        fchmod(descriptor, 0o600)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else {
                    throw BackupError.unsupported("Could not write a temporary file for the backup tool (\(String(cString: strerror(errno)))).")
                }
                offset += written
            }
        }
    }

    /// Deletes the folder and everything in it. Safe to call more than once.
    public func remove() {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else { return }
        removed = true
        try? FileManager.default.removeItem(at: url)
    }
}

/// Turns a connection's TLS settings into files the command-line tools can read.
///
/// The CA file is passed as it is. A client certificate is always written out again as a PEM certificate chain and an
/// unencrypted PEM key in the secret folder: the tools cannot take the key passphrase or the PKCS#12 password
/// without a prompt or a command-line argument, libpq refuses key files that others can read, and a key kept in the
/// certificate file (as MongoDB uses) needs to be on its own. The key is read with the app's own decoder, so the
/// tools accept exactly what a connection accepts.
public enum BackupTLSFiles {
    public struct Resolved: Hashable, Sendable {
        public var caPath: String?
        public var certificatePath: String?
        public var keyPath: String?
    }

    public static func resolve(mode: SSLMode, files: TLSCertificateFiles?, secret: String?, in directory: BackupSecretDirectory) throws -> Resolved {
        guard mode.wantsTLS, let files else { return Resolved() }
        let ca = files.caCertificatePath.isEmpty ? nil : (files.caCertificatePath as NSString).expandingTildeInPath
        let identity: TLSClientIdentity
        if !files.pkcs12Path.isEmpty {
            identity = try TLSCredentials.identity(pkcs12Path: (files.pkcs12Path as NSString).expandingTildeInPath, password: secret)
        } else if !files.clientCertificatePath.isEmpty {
            identity = try TLSCredentials.identity(
                certificatePath: (files.clientCertificatePath as NSString).expandingTildeInPath,
                keyPath: (files.clientKeyPath as NSString).expandingTildeInPath,
                passphrase: secret
            )
        } else {
            return Resolved(caPath: ca)
        }
        let certificatePath = directory.url.appendingPathComponent("client-cert.pem").path
        let keyPath = directory.url.appendingPathComponent("client-key.pem").path
        try BackupSecretDirectory.writePrivately(Data(certificatePEM(identity).utf8), to: certificatePath)
        try BackupSecretDirectory.writePrivately(Data(try privateKeyPEM(identity).utf8), to: keyPath)
        return Resolved(caPath: ca, certificatePath: certificatePath, keyPath: keyPath)
    }

    /// The client certificate followed by its intermediates.
    static func certificatePEM(_ identity: TLSClientIdentity) -> String {
        ([identity.certificate] + identity.chain).map { pem("CERTIFICATE", SecCertificateCopyData($0) as Data) }.joined()
    }

    /// The private key as PKCS#1 (`RSA PRIVATE KEY`) or SEC1 (`EC PRIVATE KEY`), unencrypted.
    static func privateKeyPEM(_ identity: TLSClientIdentity) throws -> String {
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity.identity, &key) == errSecSuccess, let key else {
            throw BackupError.unsupported("The client certificate's private key cannot be read.")
        }
        var error: Unmanaged<CFError>?
        guard let external = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "it cannot be exported"
            throw BackupError.unsupported("The client certificate's private key cannot be handed to the backup tool: \(reason).")
        }
        let attributes = SecKeyCopyAttributes(key) as? [CFString: Any] ?? [:]
        let type = attributes[kSecAttrKeyType] as? String
        if type == (kSecAttrKeyTypeRSA as String) {
            return pem("RSA PRIVATE KEY", external)
        }
        if type == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            return pem("EC PRIVATE KEY", try sec1(x963: [UInt8](external)))
        }
        throw BackupError.unsupported("The client certificate's key type is not supported by the backup tools.")
    }

    /// ECPrivateKey (RFC 5915) from Security's X9.63 form `04 || X || Y || K`.
    static func sec1(x963 bytes: [UInt8]) throws -> Data {
        let curves: [Int: [UInt8]] = [
            32: [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07], // prime256v1
            48: [0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22], // secp384r1
            66: [0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x23], // secp521r1
        ]
        guard bytes.first == 0x04, (bytes.count - 1) % 3 == 0, let oid = curves[(bytes.count - 1) / 3] else {
            throw BackupError.unsupported("The client certificate's EC key uses an unsupported curve.")
        }
        let size = (bytes.count - 1) / 3
        let publicPoint = Array(bytes[0..<(1 + 2 * size)])
        let scalar = Array(bytes[(1 + 2 * size)...])
        let body = derElement(0x02, [0x01])
            + derElement(0x04, scalar)
            + derElement(0xA0, oid)
            + derElement(0xA1, derElement(0x03, [0x00] + publicPoint))
        return Data(derElement(0x30, body))
    }

    static func derElement(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var length: [UInt8]
        if content.count < 0x80 {
            length = [UInt8(content.count)]
        } else {
            var value = content.count
            var bytes: [UInt8] = []
            while value > 0 {
                bytes.insert(UInt8(value & 0xFF), at: 0)
                value >>= 8
            }
            length = [0x80 | UInt8(bytes.count)] + bytes
        }
        return [tag] + length + content
    }

    static func pem(_ label: String, _ der: Data) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----\n"
    }
}

import Foundation
import Security

public protocol CredentialStore: Sendable {
    func secret(account: String) -> String?
    func setSecret(_ secret: String, account: String) throws
    func deleteSecret(account: String)
}

public extension CredentialStore {
    func password(for connectionID: UUID) -> String? { secret(account: connectionID.uuidString) }
    func setPassword(_ password: String, for connectionID: UUID) throws { try setSecret(password, account: connectionID.uuidString) }
    func deletePassword(for connectionID: UUID) { deleteSecret(account: connectionID.uuidString) }

    /// SSH password or key passphrase for a connection's tunnel.
    func sshSecret(for connectionID: UUID) -> String? { secret(account: connectionID.uuidString + ".ssh") }
    func setSSHSecret(_ secret: String, for connectionID: UUID) throws { try setSecret(secret, account: connectionID.uuidString + ".ssh") }
    func deleteSSHSecret(for connectionID: UUID) { deleteSecret(account: connectionID.uuidString + ".ssh") }
}

public enum CredentialStores {
    /// Keychain normally; a private file inside the data folder in portable mode.
    public static func makeDefault() -> CredentialStore {
        AppPaths.isPortable ? FileCredentialStore(url: AppPaths.portableCredentialsFile) : KeychainCredentialStore()
    }
}

public struct KeychainError: Error, LocalizedError {
    public var status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Keychain error: \(message)"
    }
}

public struct KeychainCredentialStore: CredentialStore {
    private let service = "com.foxlume.query.connection"
    /// Where passwords were kept while the app was called EasyQuery; read once and copied over.
    private let legacyService = "com.easyquery.app.connection"

    public init() {}

    private func query(for account: String, service: String? = nil) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? self.service,
            kSecAttrAccount as String: account,
        ]
    }

    public func secret(account: String) -> String? {
        if let current = read(account: account, service: service) { return current }
        guard let legacy = read(account: account, service: legacyService) else { return nil }
        try? setSecret(legacy, account: account)
        return legacy
    }

    private func read(account: String, service: String) -> String? {
        var request = query(for: account, service: service)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(for: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(for: account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Foxlume Query connection"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func deleteSecret(account: String) {
        SecItemDelete(query(for: account) as CFDictionary)
        SecItemDelete(query(for: account, service: legacyService) as CFDictionary)
    }
}

/// Portable-mode store: a JSON map in a file readable only by the current user.
public final class FileCredentialStore: CredentialStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    private func load() -> [String: String] {
        JSONFile.read([String: String].self, from: url) ?? [:]
    }

    public func secret(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return load()[account]
    }

    public func setSecret(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var map = load()
        map[account] = secret
        try JSONFile.write(map, to: url, permissions: 0o600)
    }

    public func deleteSecret(account: String) {
        lock.lock()
        defer { lock.unlock() }
        var map = load()
        map.removeValue(forKey: account)
        try? JSONFile.write(map, to: url, permissions: 0o600)
    }
}

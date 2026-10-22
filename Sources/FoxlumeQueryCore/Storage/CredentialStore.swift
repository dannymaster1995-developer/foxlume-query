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

    /// Passphrase of a connection's TLS client key, or its PKCS#12 password.
    func tlsSecret(for connectionID: UUID) -> String? { secret(account: connectionID.uuidString + ".tls") }
    func setTLSSecret(_ secret: String, for connectionID: UUID) throws { try setSecret(secret, account: connectionID.uuidString + ".tls") }
    func deleteTLSSecret(for connectionID: UUID) { deleteSecret(account: connectionID.uuidString + ".tls") }
}

public enum CredentialStores {
    /// Keychain normally; a private file inside the data folder in portable mode.
    public static func makeDefault() -> CredentialStore {
        AppPaths.isPortable ? FileCredentialStore(url: AppPaths.portableCredentialsFile) : KeychainCredentialStore()
    }

    /// AI provider keys: their own Keychain service normally; the portable credentials file (under `ai.` accounts)
    /// in portable mode.
    public static func makeAIDefault(portable: Bool = AppPaths.isPortable) -> CredentialStore {
        portable
            ? FileCredentialStore(url: AppPaths.portableCredentialsFile)
            : KeychainCredentialStore(service: KeychainCredentialStore.aiService, label: "Foxlume Query AI provider")
    }
}

/// API keys of AI providers, keyed by provider id.
public struct AIKeyStore: Sendable {
    /// Posted after a key is stored or removed, so cached suggestion sources pick the new key up.
    public static let didChangeNotification = Notification.Name("FoxlumeQuery.AIKeyStore.didChange")
    public let store: CredentialStore

    public init(store: CredentialStore) {
        self.store = store
    }

    static func account(_ providerID: UUID) -> String { "ai." + providerID.uuidString }

    public func apiKey(for providerID: UUID) -> String? {
        guard let key = store.secret(account: Self.account(providerID)), !key.isEmpty else { return nil }
        return key
    }

    /// An empty key removes the stored one.
    public func setAPIKey(_ key: String, for providerID: UUID) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            store.deleteSecret(account: Self.account(providerID))
        } else {
            try store.setSecret(trimmed, account: Self.account(providerID))
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    public func deleteAPIKey(for providerID: UUID) {
        store.deleteSecret(account: Self.account(providerID))
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
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
    public static let connectionService = "com.foxlume.query.connection"
    /// AI provider API keys.
    public static let aiService = "com.foxlume.query.ai"

    public let service: String
    /// Where passwords were kept while the app was called EasyQuery; read once and copied over.
    private let legacyService: String?
    private let label: String

    public init() {
        self.init(service: Self.connectionService, legacyService: "com.easyquery.app.connection", label: "Foxlume Query connection")
    }

    /// A store on its own Keychain service, such as the AI keys or a test service.
    public init(service: String, legacyService: String? = nil, label: String) {
        self.service = service
        self.legacyService = legacyService
        self.label = label
    }

    private func query(for account: String, service: String? = nil) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? self.service,
            kSecAttrAccount as String: account,
        ]
    }

    public func secret(account: String) -> String? {
        if let current = read(account: account, service: service) { return current }
        guard let legacyService, let legacy = read(account: account, service: legacyService) else { return nil }
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
            item[kSecAttrLabel as String] = label
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func deleteSecret(account: String) {
        SecItemDelete(query(for: account) as CFDictionary)
        if let legacyService { SecItemDelete(query(for: account, service: legacyService) as CFDictionary) }
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

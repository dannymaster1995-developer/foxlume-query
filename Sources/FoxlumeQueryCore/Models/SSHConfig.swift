import Foundation

public enum SSHAuthMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The running ssh-agent and the user's default keys, without prompting.
    case agent
    /// One private key file, optionally protected by a passphrase.
    case keyFile
    case password

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .agent: return "SSH Agent / Default Keys"
        case .keyFile: return "Private Key File"
        case .password: return "Password"
        }
    }
}

/// An SSH jump host that forwards a local port to the database server.
public struct SSHConfig: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var host: String
    public var port: Int
    public var user: String
    public var authMethod: SSHAuthMethod
    public var keyPath: String

    public init(isEnabled: Bool = false, host: String = "", port: Int = 22, user: String = "", authMethod: SSHAuthMethod = .agent, keyPath: String = "") {
        self.isEnabled = isEnabled
        self.host = host
        self.port = port
        self.user = user
        self.authMethod = authMethod
        self.keyPath = keyPath
    }

    /// Whether a secret (password or key passphrase) can be used with this method.
    public var usesSecret: Bool { authMethod != .agent }
}

import Foundation

public enum SSLMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Never use TLS.
    case disable
    /// Use TLS when the server offers it, without verifying the certificate.
    case prefer
    /// Require TLS, without verifying the certificate.
    case require
    /// Require TLS and verify the certificate chain and host name.
    case verifyFull

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disable: return "Disabled"
        case .prefer: return "Preferred"
        case .require: return "Required"
        case .verifyFull: return "Verify Full"
        }
    }

    public var wantsTLS: Bool { self != .disable }
    public var requiresTLS: Bool { self == .require || self == .verifyFull }
    public var verifiesCertificate: Bool { self == .verifyFull }
}

public enum ConnectionColor: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, red, orange, yellow, green, blue, purple, gray
    public var id: String { rawValue }
}

public enum ConnectionEnvironment: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, local, development, staging, production
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .local: return "Local"
        case .development: return "Development"
        case .staging: return "Staging"
        case .production: return "Production"
        }
    }
}

/// A saved connection. The password is never stored here; it lives in the credential store keyed by `id`.
public struct ConnectionConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: DatabaseKind
    public var host: String
    public var port: Int
    public var user: String
    public var database: String
    /// File path for SQLite connections.
    public var filePath: String
    public var sslMode: SSLMode
    public var color: ConnectionColor
    public var environment: ConnectionEnvironment
    public var group: String
    public var readOnly: Bool
    /// See `safeModeLevel`. Optional so connections saved before Safe Mode existed still decode.
    public var safeMode: SafeModeLevel?
    public var connectTimeout: Int
    public var lastUsedAt: Date?
    /// Optional SSH tunnel. Nil for connections saved before tunnels existed.
    public var ssh: SSHConfig?
    /// Engine-specific settings, keyed by `ConnectionOption`. Optional so older saved connections still decode.
    public var options: [String: String]?

    public func option(_ key: ConnectionOption) -> String? {
        guard let value = options?[key.rawValue], !value.isEmpty else { return nil }
        return value
    }

    public mutating func setOption(_ key: ConnectionOption, _ value: String?) {
        var map = options ?? [:]
        if let value, !value.isEmpty {
            map[key.rawValue] = value
        } else {
            map.removeValue(forKey: key.rawValue)
        }
        options = map.isEmpty ? nil : map
    }

    public var usesSSH: Bool { !kind.isFileBased && (ssh?.isEnabled ?? false) }

    public init(
        id: UUID = UUID(),
        name: String = "",
        kind: DatabaseKind = .postgresql,
        host: String = "127.0.0.1",
        port: Int? = nil,
        user: String? = nil,
        database: String = "",
        filePath: String = "",
        sslMode: SSLMode = .prefer,
        color: ConnectionColor = .none,
        environment: ConnectionEnvironment = .none,
        group: String = "",
        readOnly: Bool = false,
        connectTimeout: Int = 10,
        lastUsedAt: Date? = nil,
        ssh: SSHConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port ?? kind.defaultPort
        self.user = user ?? kind.defaultUser
        self.database = database
        self.filePath = filePath
        self.sslMode = sslMode
        self.color = color
        self.environment = environment
        self.group = group
        self.readOnly = readOnly
        self.connectTimeout = connectTimeout
        self.lastUsedAt = lastUsedAt
        self.ssh = ssh
    }

    public var displayName: String {
        if !name.isEmpty { return name }
        if kind.isFileBased { return (filePath as NSString).lastPathComponent }
        let target = database.isEmpty ? (user.isEmpty ? host : "\(user)@\(host)") : "\(database)@\(host)"
        return kind == .redis ? "\(host) db\(database.isEmpty ? "0" : database)" : target
    }

    public var subtitle: String {
        if kind.isFileBased { return filePath }
        if kind == .mongodb, let uri = option(.mongoConnectionString) {
            return uri.replacingOccurrences(of: #"//[^@/]*@"#, with: "//", options: .regularExpression)
        }
        let db = database.isEmpty ? "" : (kind == .redis ? "/db\(database)" : "/\(database)")
        let via = usesSSH ? " via SSH \(ssh?.host ?? "")" : ""
        let userPart = user.isEmpty ? "" : "\(user)@"
        return "\(userPart)\(host):\(port)\(db)\(via)"
    }
}

/// Keys for `ConnectionConfig.options`.
public enum ConnectionOption: String, Sendable, CaseIterable {
    // MongoDB
    case mongoAuthSource
    case mongoAuthMechanism
    case mongoReplicaSet
    case mongoReadPreference
    case mongoWriteConcern
    /// "true" to resolve the host through `mongodb+srv` DNS records.
    case mongoSRV
    /// A full `mongodb://` or `mongodb+srv://` URI; when set it overrides host, port, user and database.
    case mongoConnectionString
    // Redis
    /// "standalone", "sentinel" or "cluster".
    case redisMode
    /// Comma-separated `host:port` list of sentinels or cluster seed nodes.
    case redisNodes
    case redisSentinelMaster
    case redisSentinelUser
    case redisKeySeparator
}

/// Everything a driver needs to open a session: the saved config plus the secret resolved at connect time.
public struct ConnectionParameters: Sendable {
    public var config: ConnectionConfig
    public var password: String
    /// SSH password or key passphrase, when the tunnel needs one.
    public var sshSecret: String?

    public init(config: ConnectionConfig, password: String, sshSecret: String? = nil) {
        self.config = config
        self.password = password
        self.sshSecret = sshSecret
    }
}

extension ConnectionConfig {
    /// Removes a password written into a MongoDB URI (the connection string option, or a URI typed into the host field)
    /// and returns it, so it can be kept in the credential store instead of `connections.json`. The user name stays.
    public mutating func removeEmbeddedPassword() -> String? {
        guard kind == .mongodb else { return nil }
        var found: String?
        if let uri = option(.mongoConnectionString) {
            let (redacted, password) = Self.strippingPassword(fromURI: uri)
            if let password {
                setOption(.mongoConnectionString, redacted)
                found = password
            }
        }
        if host.contains("://") {
            let (redacted, password) = Self.strippingPassword(fromURI: host)
            if let password {
                host = redacted
                found = found ?? password
            }
        }
        return found
    }

    /// `scheme://user:secret@hosts/…` → (`scheme://user@hosts/…`, `secret`); URIs without a password come back unchanged.
    public static func strippingPassword(fromURI uri: String) -> (uri: String, password: String?) {
        guard let schemeEnd = uri.range(of: "://") else { return (uri, nil) }
        let rest = uri[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" } ?? rest.endIndex
        guard let at = rest[..<authorityEnd].lastIndex(of: "@") else { return (uri, nil) }
        let userInfo = rest[..<at]
        guard let colon = userInfo.firstIndex(of: ":") else { return (uri, nil) }
        let encoded = String(userInfo[userInfo.index(after: colon)...])
        let user = userInfo[..<colon]
        let redacted = String(uri[..<schemeEnd.upperBound]) + user + String(rest[at...])
        return (redacted, encoded.removingPercentEncoding ?? encoded)
    }
}

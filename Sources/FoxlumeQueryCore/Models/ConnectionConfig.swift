import Foundation

public enum SSLMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Never use TLS.
    case disable
    /// Use TLS when the server offers it, without verifying the certificate.
    case prefer
    /// Require TLS, without verifying the certificate.
    case require
    /// Require TLS and verify the certificate chain (libpq `verify-ca`), not the host name.
    case verifyCA
    /// Require TLS and verify the certificate chain and host name (libpq `verify-full`, MySQL `VERIFY_IDENTITY`).
    case verifyFull

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disable: return "Disabled"
        case .prefer: return "Preferred"
        case .require: return "Required"
        case .verifyCA: return "Verify CA"
        case .verifyFull: return "Verify Identity"
        }
    }

    /// One line for the connection form.
    public var summary: String {
        switch self {
        case .disable: return "No encryption."
        case .prefer: return "Encrypt when the server supports it, without verifying its certificate."
        case .require: return "Always encrypt, without verifying the server certificate."
        case .verifyCA: return "Always encrypt and verify that a trusted CA signed the server certificate (verify-ca)."
        case .verifyFull: return "Always encrypt, verify the CA and that the certificate matches the host name (verify-full)."
        }
    }

    /// The libpq `sslmode` spelling.
    public var libpqName: String {
        switch self {
        case .disable: return "disable"
        case .prefer: return "prefer"
        case .require: return "require"
        case .verifyCA: return "verify-ca"
        case .verifyFull: return "verify-full"
        }
    }

    public var wantsTLS: Bool { self != .disable }
    public var requiresTLS: Bool { self == .require || self == .verifyCA || self == .verifyFull }
    public var verifiesCertificate: Bool { self == .verifyCA || self == .verifyFull }
    public var verifiesHostname: Bool { self == .verifyFull }
}

/// Certificate files for TLS. Only paths are saved; the key passphrase or PKCS#12 password is kept in the
/// credential store (`CredentialStore.tlsSecret`).
public struct TLSCertificateFiles: Codable, Hashable, Sendable {
    /// PEM file with the CA certificates to trust (a bundle may hold several). Used by Verify CA and Verify Identity;
    /// empty means the system trust store.
    public var caCertificatePath: String
    /// PEM client certificate, optionally followed by intermediates. May also hold the key.
    public var clientCertificatePath: String
    /// PEM private key of the client certificate, possibly encrypted.
    public var clientKeyPath: String
    /// PKCS#12 (.p12/.pfx) with the client certificate and key; replaces the two fields above when set.
    public var pkcs12Path: String

    public init(caCertificatePath: String = "", clientCertificatePath: String = "", clientKeyPath: String = "", pkcs12Path: String = "") {
        self.caCertificatePath = caCertificatePath
        self.clientCertificatePath = clientCertificatePath
        self.clientKeyPath = clientKeyPath
        self.pkcs12Path = pkcs12Path
    }

    public var isEmpty: Bool {
        caCertificatePath.isEmpty && clientCertificatePath.isEmpty && clientKeyPath.isEmpty && pkcs12Path.isEmpty
    }

    /// True when a client certificate is configured (PEM or PKCS#12).
    public var hasClientCertificate: Bool { !clientCertificatePath.isEmpty || !pkcs12Path.isEmpty }

    /// True when a passphrase could apply: an encrypted key (possibly inside the certificate file) or a PKCS#12 file.
    public var needsSecret: Bool { !clientCertificatePath.isEmpty || !clientKeyPath.isEmpty || !pkcs12Path.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case caCertificatePath, clientCertificatePath, clientKeyPath, pkcs12Path
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        caCertificatePath = try container.decodeIfPresent(String.self, forKey: .caCertificatePath) ?? ""
        clientCertificatePath = try container.decodeIfPresent(String.self, forKey: .clientCertificatePath) ?? ""
        clientKeyPath = try container.decodeIfPresent(String.self, forKey: .clientKeyPath) ?? ""
        pkcs12Path = try container.decodeIfPresent(String.self, forKey: .pkcs12Path) ?? ""
    }
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
    /// CA and client certificate files. Nil when none are set (and for connections saved before they existed).
    public var tlsFiles: TLSCertificateFiles?
    /// Seconds a statement from a query tab or a table page may run before it is stopped; nil or 0 means no limit.
    /// SQL engines only. Optional so connections saved before it existed still decode.
    public var queryTimeout: Int?
    /// SQL run on every new session of a SQL connection ("Run on connect"), such as `SET search_path TO app, public;`.
    /// Nil when empty, and for connections saved before it existed.
    public var startupCommands: String?
    /// Whether AI features may send anything for this connection; nil follows the environment (see `aiPolicyLevel`).
    /// Optional so connections saved before it existed still decode.
    public var aiPolicy: AIPolicy?

    /// `queryTimeout` when it limits anything: a positive number of seconds on a SQL engine.
    public var effectiveQueryTimeout: Int? {
        guard kind.isSQL, let queryTimeout, queryTimeout > 0 else { return nil }
        return queryTimeout
    }

    /// Non-optional view of `tlsFiles`; setting empty paths stores nil.
    public var certificates: TLSCertificateFiles {
        get { tlsFiles ?? TLSCertificateFiles() }
        set { tlsFiles = newValue.isEmpty ? nil : newValue }
    }

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
    /// Passphrase of the TLS client key, or the PKCS#12 password.
    public var tlsSecret: String?
    /// Host name for TLS (SNI and Verify Identity) when it differs from `config.host`, as behind an SSH tunnel.
    public var tlsServerName: String?

    public init(config: ConnectionConfig, password: String, sshSecret: String? = nil, tlsSecret: String? = nil) {
        self.config = config
        self.password = password
        self.sshSecret = sshSecret
        self.tlsSecret = tlsSecret
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

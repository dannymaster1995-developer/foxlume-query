import Foundation

/// Parses database URLs such as `postgresql://user:pass@host:5432/db?sslmode=require` into a connection.
public enum ConnectionURL {
    public struct Parsed: Sendable {
        public var config: ConnectionConfig
        public var password: String
    }

    /// URL schemes Foxlume Query registers with macOS.
    public static let schemes: [String: DatabaseKind] = [
        "postgresql": .postgresql, "postgres": .postgresql, "pg": .postgresql,
        "mysql": .mysql, "mariadb": .mariadb,
        "sqlite": .sqlite, "sqlite3": .sqlite,
        "duckdb": .duckdb,
        "mongodb": .mongodb, "mongodb+srv": .mongodb,
        "redis": .redis, "rediss": .redis,
    ]

    public static func parse(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: "://") else { return nil }
        let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
        guard let kind = schemes[scheme] else { return nil }

        if kind.isFileBased {
            // sqlite:///absolute/path or sqlite://~/path
            var path = String(trimmed[schemeEnd.upperBound...])
            if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
            path = path.removingPercentEncoding ?? path
            guard !path.isEmpty else { return nil }
            let expanded = (path as NSString).expandingTildeInPath
            let config = ConnectionConfig(name: (expanded as NSString).lastPathComponent, kind: kind, filePath: expanded)
            return Parsed(config: config, password: "")
        }

        if kind == .mongodb {
            // Multi-host lists (`h1:1,h2:2`) are not valid for URLComponents, so split by hand.
            var rest = String(trimmed[schemeEnd.upperBound...])
            var user = ""
            var password = ""
            let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" } ?? rest.endIndex
            if let at = rest[..<authorityEnd].lastIndex(of: "@") {
                let userInfo = rest[..<at]
                let parts = userInfo.split(separator: ":", maxSplits: 1).map(String.init)
                user = parts.first?.removingPercentEncoding ?? ""
                password = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
                rest = String(rest[rest.index(after: at)...])
            }
            let hostsEnd = rest.firstIndex { $0 == "/" || $0 == "?" } ?? rest.endIndex
            let hosts = String(rest[..<hostsEnd])
            var database = ""
            if hostsEnd < rest.endIndex, rest[hostsEnd] == "/" {
                let afterSlash = rest[rest.index(after: hostsEnd)...]
                database = String(afterSlash.prefix { $0 != "?" }).removingPercentEncoding ?? ""
            }
            let first = hosts.split(separator: ",").first.map(String.init) ?? ""
            let hostParts = first.split(separator: ":").map(String.init)
            guard let host = hostParts.first, !host.isEmpty else { return nil }
            var config = ConnectionConfig(kind: .mongodb, host: host, port: hostParts.count > 1 ? Int(hostParts[1]) : nil, user: user, database: database)
            // The password goes to the credential store with `Parsed.password`, never into the saved URI.
            config.setOption(.mongoConnectionString, ConnectionConfig.strippingPassword(fromURI: trimmed).uri)
            if scheme == "mongodb+srv" {
                config.setOption(.mongoSRV, "true")
                config.sslMode = .require
            }
            config.name = host
            return Parsed(config: config, password: password)
        }

        guard let components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty else { return nil }
        var config = ConnectionConfig(kind: kind, host: host, port: components.port, user: components.percentEncodedUser?.removingPercentEncoding)
        let path = String(components.path.dropFirst()).removingPercentEncoding ?? ""
        let query = Dictionary((components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { _, last in last })

        switch kind {
        case .redis:
            if components.percentEncodedUser == nil { config.user = "" }
            config.database = Int(path).map(String.init) ?? (query["db"].flatMap { Int($0) }.map(String.init) ?? "")
            config.sslMode = scheme == "rediss" ? .require : .disable
        default:
            config.database = path
            switch (query["sslmode"] ?? query["ssl-mode"] ?? query["ssl"] ?? "").lowercased() {
            case "disable", "disabled", "false", "0": config.sslMode = .disable
            case "require", "required", "true", "1": config.sslMode = .require
            case "verify-full", "verify_identity", "verify-ca", "verify_ca": config.sslMode = .verifyFull
            default: break
            }
        }
        config.name = config.database.isEmpty || kind == .redis ? host : "\(config.database)@\(host)"
        return Parsed(config: config, password: components.percentEncodedPassword?.removingPercentEncoding ?? "")
    }
}

import Foundation

/// Finds the current master of a Sentinel-managed group.
enum RedisSentinel {
    static let defaultPort = 26379
    static let defaultMaster = "mymaster"

    /// Asks each sentinel in turn for `SENTINEL get-master-addr-by-name <master>` and returns the first answer.
    ///
    /// Sentinels authenticate with `sentinelUser` and the connection password when a sentinel user is set.
    /// Without one, the sentinel is tried without credentials first and with the password when it insists.
    static func resolveMaster(
        sentinels: [RedisEndpoint],
        masterName: String,
        sentinelUser: String?,
        template: RedisNodeLink.Options
    ) throws -> RedisEndpoint {
        guard !sentinels.isEmpty else {
            throw DatabaseError.connection("Sentinel mode needs at least one sentinel node (host:port).")
        }
        var failures: [String] = []
        for sentinel in sentinels {
            do {
                let link = try open(sentinel, sentinelUser: sentinelUser, template: template)
                defer { link.close() }
                let info = try link.serverInfo()
                if !info.mode.isEmpty, info.mode != "sentinel" {
                    failures.append("\(sentinel) is not a Sentinel (redis_mode is \(info.mode))")
                    continue
                }
                let reply = try link.call(["SENTINEL", "get-master-addr-by-name", masterName])
                switch reply {
                case .error(let message):
                    failures.append("\(sentinel): \(message)")
                case .null:
                    failures.append("\(sentinel) does not monitor a master named \"\(masterName)\"")
                default:
                    guard let parts = reply.elements, parts.count >= 2,
                          let host = parts[0].string, let port = parts[1].integer
                    else {
                        failures.append("\(sentinel) sent an unexpected answer")
                        continue
                    }
                    return RedisEndpoint(host: host, port: Int(port))
                }
            } catch let error as DatabaseError {
                failures.append("\(sentinel): \(error.errorDescription ?? "\(error)")")
            }
        }
        throw DatabaseError.connection("No sentinel could name the master \"\(masterName)\". " + failures.joined(separator: "; "))
    }

    private static func open(_ sentinel: RedisEndpoint, sentinelUser: String?, template: RedisNodeLink.Options) throws -> RedisNodeLink {
        var options = template
        options.endpoint = sentinel
        if let sentinelUser, !sentinelUser.isEmpty {
            options.user = sentinelUser
            return try RedisNodeLink.open(options)
        }
        options.user = ""
        let password = options.password
        options.password = ""
        do {
            return try RedisNodeLink.open(options)
        } catch DatabaseError.authentication(_) where !password.isEmpty {
            // The sentinel has its own requirepass; try the connection password.
            options.password = password
            return try RedisNodeLink.open(options)
        }
    }
}

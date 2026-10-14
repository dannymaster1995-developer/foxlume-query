import dnssd
import Foundation

public struct MongoHost: Hashable, Sendable, CustomStringConvertible {
    public var host: String
    public var port: Int

    public init(host: String, port: Int = 27017) {
        self.host = host
        self.port = port
    }

    /// `host`, `host:port` or `[v6]:port`.
    public init?(parsing text: String, defaultPort: Int = 27017) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.isEmpty {
                port = defaultPort
            } else {
                guard rest.hasPrefix(":"), let value = Int(rest.dropFirst()), (1...65535).contains(value) else { return nil }
                port = value
            }
            return
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            host = trimmed
            port = defaultPort
        case 2:
            guard let value = Int(parts[1]), (1...65535).contains(value) else { return nil }
            host = String(parts[0])
            port = value
        default:
            host = trimmed
            port = defaultPort
        }
        guard !host.isEmpty else { return nil }
    }

    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

/// A parsed `mongodb://` or `mongodb+srv://` URI.
public struct MongoConnectionString: Sendable {
    public var isSRV: Bool
    public var hosts: [MongoHost]
    public var user: String?
    public var password: String?
    public var database: String?
    /// Option names lowercased, values percent-decoded.
    public var options: [String: String]

    public init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rest: Substring
        if trimmed.lowercased().hasPrefix("mongodb+srv://") {
            isSRV = true
            rest = trimmed.dropFirst("mongodb+srv://".count)
        } else if trimmed.lowercased().hasPrefix("mongodb://") {
            isSRV = false
            rest = trimmed.dropFirst("mongodb://".count)
        } else {
            throw DatabaseError.connection("The connection string must start with mongodb:// or mongodb+srv://")
        }
        // Options start at the first "?"; credentials end at the last "@" before that, so a stray "/" in a password still parses.
        let queryStart = rest.firstIndex(of: "?")
        let beforeQuery = rest[..<(queryStart ?? rest.endIndex)]
        var hostAndPath = beforeQuery
        if let at = beforeQuery.lastIndex(of: "@") {
            let userInfo = beforeQuery[..<at]
            hostAndPath = beforeQuery[beforeQuery.index(after: at)...]
            if let colon = userInfo.firstIndex(of: ":") {
                user = try Self.decode(String(userInfo[..<colon]), what: "user name")
                password = try Self.decode(String(userInfo[userInfo.index(after: colon)...]), what: "password")
            } else {
                user = try Self.decode(String(userInfo), what: "user name")
            }
            if user?.isEmpty == true { user = nil }
        }
        let slash = hostAndPath.firstIndex(of: "/")
        let hostList = hostAndPath[..<(slash ?? hostAndPath.endIndex)]
        if let slash {
            let path = try Self.decode(String(hostAndPath[hostAndPath.index(after: slash)...]), what: "database name")
            database = path.isEmpty ? nil : path
        }
        hosts = []
        for item in hostList.split(separator: ",") {
            let decoded = try Self.decode(String(item), what: "host")
            guard let host = MongoHost(parsing: decoded) else {
                throw DatabaseError.connection("Invalid host \"\(decoded)\" in the connection string")
            }
            hosts.append(host)
        }
        guard !hosts.isEmpty else { throw DatabaseError.connection("The connection string names no host") }
        if isSRV {
            guard hosts.count == 1, !hostList.contains(":") else {
                throw DatabaseError.connection("A mongodb+srv:// connection string takes exactly one host name and no port")
            }
        }
        options = [:]
        if let queryStart {
            for pair in rest[rest.index(after: queryStart)...].split(whereSeparator: { $0 == "&" || $0 == ";" }) {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = try Self.decode(String(parts[0]), what: "option").lowercased()
                let value = parts.count > 1 ? try Self.decode(String(parts[1]), what: "option value") : ""
                guard !key.isEmpty else { continue }
                options[key] = value
            }
        }
    }

    private static func decode(_ text: String, what: String) throws -> String {
        guard let decoded = text.replacingOccurrences(of: "+", with: "%2B").removingPercentEncoding else {
            throw DatabaseError.connection("The connection string has an invalid percent escape in the \(what)")
        }
        return decoded
    }

    public func option(_ name: String) -> String? {
        guard let value = options[name.lowercased()], !value.isEmpty else { return nil }
        return value
    }

    func flag(_ name: String) -> Bool? {
        guard let value = option(name)?.lowercased() else { return nil }
        switch value {
        case "true", "1", "yes", "y", "t": return true
        case "false", "0", "no", "n", "f": return false
        default: return nil
        }
    }

    public var authSource: String? { option("authSource") }
    public var authMechanism: String? { option("authMechanism") }
    public var replicaSet: String? { option("replicaSet") }
    public var readPreference: String? { option("readPreference") }
    public var writeConcern: String? { option("w") }
    /// `tls` and its older alias `ssl`.
    public var tls: Bool? { flag("tls") ?? flag("ssl") }
    public var tlsInsecure: Bool {
        flag("tlsInsecure") == true || flag("tlsAllowInvalidCertificates") == true || flag("sslAllowInvalidCertificates") == true
    }
    public var directConnection: Bool? { flag("directConnection") }
}

// MARK: - DNS

/// SRV and TXT lookups through dnssd, which ships with the system and needs no extra library.
enum MongoDNS {
    struct SRVRecord {
        var priority: UInt16
        var weight: UInt16
        var port: UInt16
        var target: String
    }

    /// Hosts from `_mongodb._tcp.<name>` and options from the TXT record of `<name>`.
    static func resolveSRV(_ name: String, timeout: TimeInterval) throws -> (hosts: [MongoHost], options: [String: String]) {
        let domainParts = name.lowercased().split(separator: ".")
        guard domainParts.count >= 2 else {
            throw DatabaseError.connection("\"\(name)\" is not a valid mongodb+srv host name; it needs at least two labels.")
        }
        let records = try query("_mongodb._tcp.\(name)", type: UInt16(kDNSServiceType_SRV), timeout: timeout)
        guard !records.isEmpty else { throw DatabaseError.connection("No SRV records found for _mongodb._tcp.\(name)") }
        // Every target must sit under the parent domain of the SRV name, so DNS cannot redirect elsewhere.
        let parent = domainParts.count > 2 ? Array(domainParts.dropFirst()) : domainParts
        var hosts: [MongoHost] = []
        for raw in records {
            guard let record = parseSRV(raw) else { continue }
            let target = record.target.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let targetParts = target.split(separator: ".")
            guard targetParts.count > parent.count, Array(targetParts.suffix(parent.count)) == parent else {
                throw DatabaseError.connection("The SRV record target \(target) is not under the domain \(parent.joined(separator: "."))")
            }
            hosts.append(MongoHost(host: target, port: Int(record.port)))
        }
        guard !hosts.isEmpty else { throw DatabaseError.connection("The SRV records for \(name) could not be read") }
        var options: [String: String] = [:]
        let texts = (try? query(name, type: UInt16(kDNSServiceType_TXT), timeout: timeout)) ?? []
        guard texts.count <= 1 else { throw DatabaseError.connection("\(name) has more than one TXT record") }
        for raw in texts {
            for string in parseTXT(raw) {
                for pair in string.split(separator: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let key = String(parts[0]).lowercased()
                    // Only these options may come from DNS.
                    guard ["authsource", "replicaset", "loadbalanced"].contains(key) else {
                        throw DatabaseError.connection("The TXT record for \(name) sets \(parts[0]), which is not allowed")
                    }
                    options[key] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                }
            }
        }
        return (hosts.sorted { $0.description < $1.description }, options)
    }

    private final class QueryBox {
        let type: UInt16
        var records: [[UInt8]] = []
        var error: DNSServiceErrorType = DNSServiceErrorType(kDNSServiceErr_NoError)
        var finished = false

        init(type: UInt16) {
            self.type = type
        }
    }

    static func query(_ name: String, type: UInt16, timeout: TimeInterval) throws -> [[UInt8]] {
        let box = QueryBox(type: type)
        let context = Unmanaged.passUnretained(box).toOpaque()
        var reference: DNSServiceRef?
        let callback: DNSServiceQueryRecordReply = { _, flags, _, errorCode, _, recordType, _, length, data, _, context in
            guard let context else { return }
            let box = Unmanaged<QueryBox>.fromOpaque(context).takeUnretainedValue()
            if errorCode != DNSServiceErrorType(kDNSServiceErr_NoError) {
                box.error = errorCode
                box.finished = true
                return
            }
            // Intermediate answers such as CNAMEs arrive too; only records of the asked type end the wait.
            guard recordType == box.type else { return }
            if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let data, length > 0 {
                let bytes = data.assumingMemoryBound(to: UInt8.self)
                box.records.append(Array(UnsafeBufferPointer(start: bytes, count: Int(length))))
            }
            if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { box.finished = true }
        }
        let status = DNSServiceQueryRecord(&reference, DNSServiceFlags(kDNSServiceFlagsTimeout | kDNSServiceFlagsReturnIntermediates), 0, name, type, UInt16(kDNSServiceClass_IN), callback, context)
        guard status == DNSServiceErrorType(kDNSServiceErr_NoError), let reference else {
            throw DatabaseError.connection("DNS lookup of \(name) failed (\(status))")
        }
        defer { DNSServiceRefDeallocate(reference) }
        let socket = DNSServiceRefSockFD(reference)
        let deadline = Date().addingTimeInterval(max(1, timeout))
        while !box.finished {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw DatabaseError.connection("DNS lookup of \(name) timed out") }
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(remaining * 1000))
            if ready < 0 { throw DatabaseError.connection("DNS lookup of \(name) failed: \(String(cString: strerror(errno)))") }
            if ready == 0 { continue }
            let processed = DNSServiceProcessResult(reference)
            guard processed == DNSServiceErrorType(kDNSServiceErr_NoError) else {
                throw DatabaseError.connection("DNS lookup of \(name) failed (\(processed))")
            }
        }
        if box.error == DNSServiceErrorType(kDNSServiceErr_NoSuchRecord) || box.error == DNSServiceErrorType(kDNSServiceErr_NoSuchName) {
            return []
        }
        guard box.error == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            throw DatabaseError.connection("DNS lookup of \(name) failed (\(box.error))")
        }
        return box.records
    }

    /// RDATA of an SRV record: priority, weight, port, then the target as DNS labels.
    static func parseSRV(_ data: [UInt8]) -> SRVRecord? {
        guard data.count >= 7 else { return nil }
        let priority = UInt16(data[0]) << 8 | UInt16(data[1])
        let weight = UInt16(data[2]) << 8 | UInt16(data[3])
        let port = UInt16(data[4]) << 8 | UInt16(data[5])
        var labels: [String] = []
        var index = 6
        while index < data.count {
            let length = Int(data[index])
            index += 1
            if length == 0 { break }
            guard length < 64, index + length <= data.count else { return nil }
            labels.append(String(decoding: data[index..<(index + length)], as: UTF8.self))
            index += length
        }
        guard !labels.isEmpty else { return nil }
        return SRVRecord(priority: priority, weight: weight, port: port, target: labels.joined(separator: "."))
    }

    /// RDATA of a TXT record: length-prefixed strings, which are joined as the spec requires.
    static func parseTXT(_ data: [UInt8]) -> [String] {
        var parts: [String] = []
        var index = 0
        while index < data.count {
            let length = Int(data[index])
            index += 1
            guard index + length <= data.count else { break }
            parts.append(String(decoding: data[index..<(index + length)], as: UTF8.self))
            index += length
        }
        return [parts.joined()]
    }
}

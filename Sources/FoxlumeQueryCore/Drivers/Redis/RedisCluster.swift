import Foundation

/// Hash slots as Redis Cluster computes them: CRC16 (XMODEM) of the key, or of its hash tag, modulo 16384.
enum RedisKeySlot {
    static let count = 16384

    static func slot(for key: Data) -> Int {
        Int(crc16(hashTag(key)) % UInt16(count))
    }

    static func slot(for key: String) -> Int {
        slot(for: Data(key.utf8))
    }

    /// The part of the key that is hashed: the text between the first `{` and the next `}`, when that is not empty.
    static func hashTag(_ key: Data) -> Data {
        let bytes = [UInt8](key)
        guard let open = bytes.firstIndex(of: UInt8(ascii: "{")),
              let close = bytes[(open + 1)...].firstIndex(of: UInt8(ascii: "}")),
              close > open + 1
        else { return key }
        return Data(bytes[(open + 1)..<close])
    }

    static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}

/// `-MOVED 3999 127.0.0.1:6381` and `-ASK 3999 127.0.0.1:6381`.
struct RedisRedirect: Equatable {
    enum Kind { case moved, ask }
    var kind: Kind
    var slot: Int
    var endpoint: RedisEndpoint

    init?(_ message: String) {
        let parts = message.split(separator: " ")
        guard parts.count >= 3, let slot = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "MOVED": kind = .moved
        case "ASK": kind = .ask
        default: return nil
        }
        guard let endpoint = RedisEndpoint(parsing: String(parts[2]), defaultPort: 6379) else { return nil }
        self.slot = slot
        self.endpoint = endpoint
    }
}

/// Which master serves each hash slot.
struct RedisClusterTopology: Equatable {
    /// Masters in a stable order (by their lowest slot), so composite SCAN cursors stay valid.
    var masters: [RedisEndpoint]
    /// Index into `masters` for each of the 16384 slots; -1 when no node serves it.
    var slotOwners: [Int]

    init(ranges: [(ClosedRange<Int>, RedisEndpoint)]) {
        var owners = [Int](repeating: -1, count: RedisKeySlot.count)
        let ordered = ranges.sorted { $0.0.lowerBound < $1.0.lowerBound }
        var masters: [RedisEndpoint] = []
        for (range, endpoint) in ordered {
            var index = masters.firstIndex(of: endpoint) ?? -1
            if index < 0 {
                masters.append(endpoint)
                index = masters.count - 1
            }
            for slot in range where slot >= 0 && slot < RedisKeySlot.count {
                owners[slot] = index
            }
        }
        self.masters = masters
        slotOwners = owners
    }

    func owner(of slot: Int) -> RedisEndpoint? {
        guard slot >= 0, slot < slotOwners.count, slotOwners[slot] >= 0 else { return nil }
        return masters[slotOwners[slot]]
    }

    mutating func assign(slot: Int, to endpoint: RedisEndpoint) {
        guard slot >= 0, slot < slotOwners.count else { return }
        if let index = masters.firstIndex(of: endpoint) {
            slotOwners[slot] = index
        } else {
            masters.append(endpoint)
            slotOwners[slot] = masters.count - 1
        }
    }

    /// `CLUSTER SLOTS`: `[[start, end, [ip, port, id, …], replica…], …]`. An empty ip means the node that answered.
    static func fromSlots(_ reply: RESPValue, answeredBy seed: RedisEndpoint) -> RedisClusterTopology? {
        guard let entries = reply.elements, !entries.isEmpty else { return nil }
        var ranges: [(ClosedRange<Int>, RedisEndpoint)] = []
        for entry in entries {
            guard let parts = entry.elements, parts.count >= 3,
                  let start = parts[0].integer, let end = parts[1].integer, start <= end,
                  let node = parts[2].elements, node.count >= 2,
                  let port = node[1].integer
            else { continue }
            let host = node[0].string ?? ""
            let endpoint = RedisEndpoint(host: host.isEmpty || host == "?" ? seed.host : host, port: Int(port))
            ranges.append((Int(start)...Int(end), endpoint))
        }
        return ranges.isEmpty ? nil : RedisClusterTopology(ranges: ranges)
    }

    /// `CLUSTER SHARDS` (Redis 7+): shards with `slots` as flat start/end pairs and `nodes` as maps.
    static func fromShards(_ reply: RESPValue, answeredBy seed: RedisEndpoint) -> RedisClusterTopology? {
        guard let shards = reply.elements, !shards.isEmpty else { return nil }
        var ranges: [(ClosedRange<Int>, RedisEndpoint)] = []
        for shard in shards {
            let fields = shard.dictionary
            guard let bounds = fields["slots"]?.elements?.compactMap(\.integer), bounds.count >= 2,
                  let nodes = fields["nodes"]?.elements
            else { continue }
            let master = nodes.map(\.dictionary).first { node in
                node["role"]?.string == "master" && node["health"]?.string != "failed"
            }
            guard let master, let port = (master["port"] ?? master["tls-port"])?.integer else { continue }
            let host = master["ip"]?.string ?? master["endpoint"]?.string ?? ""
            let endpoint = RedisEndpoint(host: host.isEmpty || host == "?" ? seed.host : host, port: Int(port))
            for pair in stride(from: 0, to: bounds.count - 1, by: 2) where bounds[pair] <= bounds[pair + 1] {
                ranges.append((Int(bounds[pair])...Int(bounds[pair + 1]), endpoint))
            }
        }
        return ranges.isEmpty ? nil : RedisClusterTopology(ranges: ranges)
    }

    static func == (lhs: RedisClusterTopology, rhs: RedisClusterTopology) -> Bool {
        lhs.masters == rhs.masters && lhs.slotOwners == rhs.slotOwners
    }
}

/// Composite cursor for a SCAN that walks every master in turn: `host:port-cursor`, or `0` when done.
enum RedisClusterCursor {
    enum Position: Equatable {
        case finished
        case node(index: Int, cursor: String)
    }

    static func decode(_ raw: String, masters: [RedisEndpoint]) -> Position {
        guard !masters.isEmpty else { return .finished }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "0" else { return .node(index: 0, cursor: "0") }
        // Host names can contain hyphens; the node cursor never does, so split at the last one.
        guard let separator = trimmed.lastIndex(of: "-"),
              let index = masters.firstIndex(where: { $0.description == trimmed[..<separator] })
        else { return .node(index: 0, cursor: "0") }
        let cursor = String(trimmed[trimmed.index(after: separator)...])
        return .node(index: index, cursor: cursor.isEmpty ? "0" : cursor)
    }

    /// The cursor to hand back after node `index` answered `nodeCursor`.
    static func advance(index: Int, nodeCursor: String, masters: [RedisEndpoint]) -> String {
        if nodeCursor != "0" { return "\(masters[index].description)-\(nodeCursor)" }
        guard index + 1 < masters.count else { return "0" }
        return "\(masters[index + 1].description)-0"
    }
}

/// Connections to the masters of one cluster, opened lazily, plus the slot map.
final class RedisClusterRouter {
    private let template: RedisNodeLink.Options
    private(set) var topology: RedisClusterTopology
    private var links: [RedisEndpoint: RedisNodeLink] = [:]
    /// The node used for keyless commands.
    private(set) var primary: RedisEndpoint

    /// Opens the first reachable seed, checks it runs in cluster mode and loads the slot map.
    init(seeds: [RedisEndpoint], template: RedisNodeLink.Options, verify: (RedisNodeLink) throws -> Void) throws {
        var failures: [String] = []
        var opened: RedisNodeLink?
        var resolvedTemplate = template
        for seed in seeds {
            var options = template
            options.endpoint = seed
            let link: RedisNodeLink
            do {
                link = try RedisNodeLink.open(options)
            } catch let error as DatabaseError where RedisNodeLink.isTransportFailure(error) {
                // An unreachable seed is normal; try the next one.
                failures.append("\(seed): \(error.errorDescription ?? "\(error)")")
                continue
            }
            do {
                try verify(link)
            } catch {
                link.close()
                throw error
            }
            opened = link
            // Every node of a cluster speaks the same transport; skip the TLS probe on the others.
            resolvedTemplate.sslMode = Self.resolvedSSL(template.sslMode, isTLS: link.isTLS)
            break
        }
        guard let seed = opened else {
            throw DatabaseError.connection("Could not reach any cluster seed node. " + failures.joined(separator: "; "))
        }
        self.template = resolvedTemplate
        topology = RedisClusterTopology(ranges: [])
        primary = seed.endpoint
        links[seed.endpoint] = seed
        try refresh(using: seed)
        if let first = topology.masters.first, topology.masters.contains(seed.endpoint) == false {
            primary = first
        }
    }

    static func resolvedSSL(_ mode: SSLMode, isTLS: Bool) -> SSLMode {
        guard isTLS else { return .disable }
        return mode.verifiesCertificate ? .verifyFull : .require
    }

    var masters: [RedisEndpoint] { topology.masters }

    /// Reloads the slot map with `CLUSTER SLOTS`, or `CLUSTER SHARDS` where SLOTS is gone.
    func refresh(using given: RedisNodeLink? = nil) throws {
        let link = try given ?? self.link(for: primary)
        let replies = try link.pipeline([RedisNodeLink.data(["CLUSTER", "SLOTS"])])
        if let parsed = RedisClusterTopology.fromSlots(replies[0], answeredBy: link.endpoint) {
            topology = parsed
            return
        }
        let shards = try link.call(["CLUSTER", "SHARDS"])
        if let parsed = RedisClusterTopology.fromShards(shards, answeredBy: link.endpoint) {
            topology = parsed
            return
        }
        if let message = replies[0].errorMessage ?? shards.errorMessage {
            throw DatabaseError.server(message: "Cannot read the cluster slot map: \(message)", code: "CLUSTER")
        }
        throw DatabaseError.connection("The cluster reported no slots. Is it fully set up (cluster_state:ok)?")
    }

    func endpoint(forSlot slot: Int) -> RedisEndpoint {
        topology.owner(of: slot) ?? primary
    }

    func endpoint(forKey key: Data?) -> RedisEndpoint {
        guard let key else { return primary }
        return endpoint(forSlot: RedisKeySlot.slot(for: key))
    }

    /// The open link to `endpoint`, connecting when needed and replacing a broken one.
    func link(for endpoint: RedisEndpoint) throws -> RedisNodeLink {
        if let existing = links[endpoint], !existing.isBroken, existing.transport.isOpen {
            return existing
        }
        var options = template
        options.endpoint = endpoint
        let link = try RedisNodeLink.open(options)
        links[endpoint] = link
        return link
    }

    func noteMoved(slot: Int, to endpoint: RedisEndpoint) {
        topology.assign(slot: slot, to: endpoint)
    }

    var openLinks: [RedisNodeLink] { Array(links.values) }

    var isUsable: Bool {
        links.values.contains { !$0.isBroken && $0.transport.isOpen }
    }

    func closeAll() {
        for link in links.values { link.close() }
        links.removeAll()
    }
}

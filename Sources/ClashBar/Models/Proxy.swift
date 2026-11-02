import Foundation

enum ProxyDelayHistory {
    static let limit = 4
}

/// Immutable view of the latency state for one render pass.
///
/// Resolving a node's samples used to walk `proxyGroups` with `first(where:)` on every call, so a
/// list of ~1000 nodes in a ~40 group config paid O(nodes × groups) string comparisons per pass
/// (and per sort comparison). Building the index once per pass keeps lookups to a couple of
/// dictionary hits.
struct ProxyDelayLookup {
    private let samplesByNode: [String: [Int]]
    private let nestedSelection: [String: String]

    init(samplesByNode: [String: [Int]], groups: [ProxyGroup]) {
        self.samplesByNode = samplesByNode
        var nestedSelection: [String: String] = [:]
        nestedSelection.reserveCapacity(groups.count)
        for group in groups {
            guard !group.all.isEmpty, let now = group.now?.trimmedNonEmpty else { continue }
            nestedSelection[group.name] = now
        }
        self.nestedSelection = nestedSelection
    }

    /// Walks the node → nested group chain, mirroring the previous `proxySelectionChain` walk:
    /// the deepest nested selection is preferred, then it falls back to the starting node.
    func samples(for node: String) -> [Int] {
        var chain: [String] = []
        var current = node
        var seen: Set<String> = []
        while seen.insert(current).inserted {
            chain.append(current)
            guard let next = self.nestedSelection[current] else { break }
            current = next
        }
        for name in chain.reversed() {
            if let samples = self.samplesByNode[name], !samples.isEmpty {
                return samples
            }
        }
        return []
    }

    func samples(for node: String, fallbackToGroup group: String) -> [Int] {
        let nodeSamples = self.samples(for: node)
        guard nodeSamples.isEmpty else { return nodeSamples }
        return self.samples(for: group)
    }

    func value(for node: String) -> Int? {
        self.samples(for: node).last
    }

    func value(for node: String, fallbackToGroup group: String) -> Int? {
        self.samples(for: node, fallbackToGroup: group).last
    }
}

struct ProxyGroupsResponse: Decodable, Equatable {
    let proxies: [String: ProxyGroup]
}

struct ProxyGroup: Decodable, Equatable {
    let name: String
    let type: String?
    let now: String?
    let all: [String]
    let testUrl: String?
    let timeout: Int?
    let icon: String?
    let hidden: Bool?
    let delayHistory: [Int]

    init(
        name: String,
        type: String? = nil,
        now: String? = nil,
        all: [String],
        testUrl: String? = nil,
        timeout: Int? = nil,
        icon: String? = nil,
        hidden: Bool? = nil,
        delayHistory: [Int] = [])
    {
        self.name = name
        self.type = type
        self.now = now
        self.all = all
        self.testUrl = testUrl.trimmedNonEmpty
        self.timeout = timeout.positiveOrNil
        self.icon = icon.trimmedNonEmpty
        self.hidden = hidden
        self.delayHistory = delayHistory
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case now
        case all
        case testUrl
        case timeout
        case icon
        case hidden
        case history
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.now = try container.decodeIfPresent(String.self, forKey: .now)
        self.all = try container.decodeIfPresent([String].self, forKey: .all) ?? []
        self.testUrl = try container.decodeIfPresent(String.self, forKey: .testUrl).trimmedNonEmpty
        self.timeout = container.decodeFlexibleInt(forKey: .timeout).positiveOrNil
        self.icon = try container.decodeIfPresent(String.self, forKey: .icon).trimmedNonEmpty
        self.hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
        self.delayHistory = container.decodeDelayHistory(forKey: .history)
    }
}

struct ConfigSnapshot: Codable, Equatable {
    struct TunConfig: Codable, Equatable {
        let enable: Bool?
        let stack: String?

        private enum CodingKeys: String, CodingKey {
            case enable
            case stack
        }

        init(enable: Bool?, stack: String?) {
            self.enable = enable
            self.stack = stack
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.enable = container.decodeFlexibleBool(forKey: .enable)
            self.stack = container.decodeFlexibleString(forKey: .stack)
        }
    }

    let allowLan: Bool?
    let mode: String?
    let logLevel: String?
    let ipv6: Bool?
    let tcpConcurrent: Bool?
    let port: Int?
    let socksPort: Int?
    let redirPort: Int?
    let tproxyPort: Int?
    let mixedPort: Int?
    let tun: TunConfig?
    let externalController: String?
    let externalUIURL: String?
    let externalUIName: String?

    var tunEnabled: Bool? {
        self.tun?.enable
    }

    private enum CodingKeys: String, CodingKey {
        case allowLan = "allow-lan"
        case mode
        case logLevel = "log-level"
        case ipv6
        case tcpConcurrent = "tcp-concurrent"
        case port
        case socksPort = "socks-port"
        case redirPort = "redir-port"
        case tproxyPort = "tproxy-port"
        case mixedPort = "mixed-port"
        case tun
        case externalController = "external-controller"
        case externalUIURL = "external-ui-url"
        case externalUIName = "external-ui-name"
    }
}

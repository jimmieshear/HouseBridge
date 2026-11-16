import Foundation
import Network

public struct DiscoveredAirPlayDevice: Sendable {
    public var name: String
    public var model: String
    public var host: String?
    public var osVersion: String?
    public var isAppleTV: Bool { model.hasPrefix("AppleTV") }
    public var description: String { AppleTVDiscovery.describe(model: model) }
}

/// Lists AirPlay receivers (Apple TV, HomePod, smart TVs, Macs) on the local network. Apple TVs advertise their hardware
/// identifier in the `_airplay._tcp` TXT record (`model=AppleTV11,1`); mDNS does not cross subnets, so this only sees
/// the LAN/VLAN this Mac is on.
public enum AppleTVDiscovery {
    public static let generations: [String: String] = [
        "AppleTV2,1": "Apple TV 2nd generation (2010)",
        "AppleTV3,1": "Apple TV 3rd generation (2012)",
        "AppleTV3,2": "Apple TV 3rd generation (2013)",
        "AppleTV5,3": "Apple TV HD (4th generation, 2015)",
        "AppleTV6,2": "Apple TV 4K 1st generation (2017)",
        "AppleTV11,1": "Apple TV 4K 2nd generation (2021)",
        "AppleTV14,1": "Apple TV 4K 3rd generation (2022)",
    ]

    public static func describe(model: String) -> String {
        if let known = generations[model] { return known }
        if model.hasPrefix("AppleTV") { return "Apple TV (unrecognized model, newer than this list?)" }
        if model.hasPrefix("AudioAccessory") { return "HomePod / HomePod mini" }
        if model.hasPrefix("Mac") { return "Mac" }
        return model.isEmpty ? "unknown" : "other AirPlay device"
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: DiscoveredAirPlayDevice] = [:]
        private var endpoints: [String: NWEndpoint] = [:]
        func add(_ key: String, _ item: DiscoveredAirPlayDevice, _ endpoint: NWEndpoint) {
            lock.withLock { items[key] = item; endpoints[key] = endpoint }
        }
        func setHost(_ key: String, _ host: String) { lock.withLock { items[key]?.host = host } }
        var snapshot: [(String, NWEndpoint)] { lock.withLock { endpoints.map { ($0.key, $0.value) } } }
        var devices: [DiscoveredAirPlayDevice] { lock.withLock { items.values.sorted { $0.name < $1.name } } }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func first() -> Bool { lock.withLock { defer { used = true }; return !used } }
    }

    public static func find(browseFor seconds: Double = 5) async -> [DiscoveredAirPlayDevice] {
        let queue = DispatchQueue(label: "housebridge.airplay-discovery")
        let collector = Collector()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                var txt: [String: String] = [:]
                if case let .bonjour(record) = result.metadata { txt = record.dictionary }
                collector.add(name, DiscoveredAirPlayDevice(name: name, model: txt["model"] ?? "",
                                                            host: nil, osVersion: txt["osvers"] ?? txt["srcvers"]), result.endpoint)
            }
        }
        browser.start(queue: queue)
        try? await Task.sleep(for: .seconds(seconds))
        browser.cancel()

        await withTaskGroup(of: Void.self) { group in
            for (key, endpoint) in collector.snapshot {
                group.addTask { await resolve(key, endpoint, collector, queue) }
            }
        }
        return collector.devices
    }

    /// Connects to the service (IPv4) just to learn its address.
    private static func resolve(_ key: String, _ endpoint: NWEndpoint, _ collector: Collector, _ queue: DispatchQueue) async {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = Once()
            let finish: @Sendable () -> Void = {
                guard once.first() else { return }
                connection.cancel()
                done.resume()
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
                        var text = "\(host)"
                        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                        collector.setHost(key, text)
                    }
                    finish()
                case .failed, .cancelled: finish()
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { finish() }
        }
    }
}

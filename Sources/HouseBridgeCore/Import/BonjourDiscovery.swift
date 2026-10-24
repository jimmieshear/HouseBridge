import Foundation
import Network

public struct DiscoveredBridge: Sendable {
    public var name: String
    public var id: String
    public var paired: Bool
    public var host: String?
    public var port: UInt16?
}

/// Finds HomeKit bridges (Homebridge among them) advertised on the local network. The advertisement only says that a
/// bridge exists and where; what it exposes cannot be read without being paired to it.
public enum BonjourDiscovery {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        /// True only for the first caller.
        func first() -> Bool { lock.withLock { defer { used = true }; return !used } }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: DiscoveredBridge] = [:]
        private var endpoints: [String: NWEndpoint] = [:]
        func add(_ key: String, _ item: DiscoveredBridge, _ endpoint: NWEndpoint) {
            lock.withLock { items[key] = item; endpoints[key] = endpoint }
        }
        func update(_ key: String, host: String, port: UInt16) {
            lock.withLock { items[key]?.host = host; items[key]?.port = port }
        }
        var snapshot: [(String, DiscoveredBridge, NWEndpoint)] {
            lock.withLock { items.map { ($0.key, $0.value, endpoints[$0.key]!) } }
        }
        var bridges: [DiscoveredBridge] { lock.withLock { items.values.sorted { $0.name < $1.name } } }
    }

    public static func findBridges(browseFor seconds: Double = 4) async -> [DiscoveredBridge] {
        let queue = DispatchQueue(label: "housebridge.discovery")
        let collector = Collector()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_hap._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                var txt: [String: String] = [:]
                if case let .bonjour(record) = result.metadata { txt = record.dictionary }
                collector.add(name, DiscoveredBridge(name: name, id: txt["id"] ?? "", paired: txt["sf"] == "0"), result.endpoint)
            }
        }
        browser.start(queue: queue)
        try? await Task.sleep(for: .seconds(seconds))
        browser.cancel()

        // Resolve each service to an address by connecting to it (IPv4 only, so the result is usable in a URL).
        await withTaskGroup(of: Void.self) { group in
            for (key, _, endpoint) in collector.snapshot {
                group.addTask { await resolve(key, endpoint, collector, queue) }
            }
        }
        return collector.bridges
    }

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
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        var text = "\(host)"
                        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                        collector.update(key, host: text, port: port.rawValue)
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

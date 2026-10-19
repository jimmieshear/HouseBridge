import Foundation

public struct HueCredentials: Codable, Sendable {
    public var host: String
    public var appKey: String
}

public enum HueError: Error, CustomStringConvertible {
    case notPaired
    case linkButtonNotPressed
    case notFound(kind: String, name: String, available: [String])
    case http(HTTPFailure)

    public var description: String {
        switch self {
        case .notPaired: return "Hue bridge is not paired. Run: housebridgectl pair-hue"
        case .linkButtonNotPressed: return "Press the round link button on the Hue bridge, then try again."
        case .notFound(let kind, let name, let available):
            return "No Hue \(kind) named “\(name)”. Available: \(available.sorted().joined(separator: ", "))"
        case .http(let f): return "Hue bridge error: \(f)"
        }
    }
}

public struct HueInventory: Sendable {
    public struct Item: Sendable {
        public let id: String
        public let name: String
        public let groupedLightId: String?
        /// What it can do / what's in it, as short human-readable facts.
        public var details: [String] = []
        public var product: String = ""
    }
    public struct SceneItem: Sendable { public let id: String; public let name: String; public let groupName: String? }
    public var lights: [Item] = []
    public var rooms: [Item] = []
    public var zones: [Item] = []
    public var scenes: [SceneItem] = []
}

/// Talks to a Hue bridge over the local CLIP v2 API.
public final class HueClient: @unchecked Sendable {
    public let credentials: HueCredentials
    private let session: URLSession
    private let lock = NSLock()
    private var cache: HueInventory?

    public init(credentials: HueCredentials, hosts: KnownHosts) {
        self.credentials = credentials
        session = URLSession(configuration: .ephemeral, delegate: PinningDelegate(hosts: hosts), delegateQueue: nil)
    }

    // MARK: Pairing

    /// Requires the bridge's link button to have been pressed within the last 30 seconds.
    public static func pair(host: String, hosts: KnownHosts, appName: String = "housebridge") async throws -> HueCredentials {
        let session = URLSession(configuration: .ephemeral, delegate: PinningDelegate(hosts: hosts), delegateQueue: nil)
        var request = URLRequest(url: URL(string: "https://\(host)/api")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "devicetype": "\(appName)#\(Host.current().localizedName ?? "mac")",
            "generateclientkey": true,
        ])
        let (data, _) = try await session.data(for: request)
        guard let array = try parseJSON(data) as? [JSON], let first = array.first else {
            throw HueError.http(HTTPFailure(status: 0, body: String(decoding: data, as: UTF8.self)))
        }
        if let error = first["error"] as? JSON {
            if (error["type"] as? Int) == 101 { throw HueError.linkButtonNotPressed }
            throw HueError.http(HTTPFailure(status: 0, body: "\(error)"))
        }
        guard let success = first["success"] as? JSON, let key = success["username"] as? String else {
            throw HueError.http(HTTPFailure(status: 0, body: String(decoding: data, as: UTF8.self)))
        }
        return HueCredentials(host: host, appKey: key)
    }

    public static func load(from url: URL) -> HueCredentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HueCredentials.self, from: data)
    }

    public static func save(_ credentials: HueCredentials, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(credentials).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Requests

    func request(_ method: String, _ path: String, body: JSON? = nil) async throws -> [JSON] {
        var request = URLRequest(url: URL(string: "https://\(credentials.host)/clip/v2\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue(credentials.appKey, forHTTPHeaderField: "hue-application-key")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw HueError.http(HTTPFailure(status: status, body: String(decoding: data, as: UTF8.self)))
        }
        let object = try parseJSON(data) as? JSON
        return object?["data"] as? [JSON] ?? []
    }

    // MARK: Inventory

    public func inventory(refresh: Bool = false) async throws -> HueInventory {
        let cached = lock.withLock { cache }
        if let cached, !refresh { return cached }

        func named(_ items: [JSON]) -> [String: String] {
            var out: [String: String] = [:]
            for i in items { if let id = i["id"] as? String, let n = (i["metadata"] as? JSON)?["name"] as? String { out[id] = n } }
            return out
        }
        func groupedLight(_ item: JSON) -> String? {
            (item["services"] as? [JSON])?.first { ($0["rtype"] as? String) == "grouped_light" }?["rid"] as? String
        }

        async let lightsRaw = request("GET", "/resource/light")
        async let roomsRaw = request("GET", "/resource/room")
        async let zonesRaw = request("GET", "/resource/zone")
        async let scenesRaw = request("GET", "/resource/scene")
        async let devicesRaw = request("GET", "/resource/device")
        let (lights, rooms, zones, scenes, devices) = try await (lightsRaw, roomsRaw, zonesRaw, scenesRaw, devicesRaw)

        // device id → product name; light id → owning device id (rooms contain devices, zones contain lights)
        var products: [String: String] = [:]
        for d in devices {
            if let id = d["id"] as? String, let pd = d["product_data"] as? JSON {
                products[id] = [pd["manufacturer_name"] as? String, pd["product_name"] as? String].compactMap { $0 }.joined(separator: " ")
            }
        }
        var lightNameById: [String: String] = [:], lightNameByOwner: [String: String] = [:]
        for l in lights {
            guard let id = l["id"] as? String, let n = (l["metadata"] as? JSON)?["name"] as? String else { continue }
            lightNameById[id] = n
            if let owner = (l["owner"] as? JSON)?["rid"] as? String { lightNameByOwner[owner] = n }
        }
        func capabilities(_ l: JSON) -> [String] {
            var c = ["on / off"]
            if l["dimming"] != nil { c.append("brightness 0–100%") }
            if let schema = (l["color_temperature"] as? JSON)?["mirek_schema"] as? JSON,
               let lo = schema["mirek_minimum"] as? Int, let hi = schema["mirek_maximum"] as? Int, lo > 0, hi > 0 {
                c.append("color temperature \(1_000_000 / hi)–\(1_000_000 / lo) K")
            } else if l["color_temperature"] != nil { c.append("color temperature") }
            if l["color"] != nil { c.append("full color") }
            if l["gradient"] != nil { c.append("gradient") }
            return c
        }
        func members(_ g: JSON) -> [String] {
            ((g["children"] as? [JSON]) ?? []).compactMap { child in
                guard let rid = child["rid"] as? String else { return nil }
                return lightNameById[rid] ?? lightNameByOwner[rid]
            }.sorted()
        }

        var inv = HueInventory()
        inv.lights = lights.compactMap { l in
            guard let id = l["id"] as? String, let n = (l["metadata"] as? JSON)?["name"] as? String else { return nil }
            var item = HueInventory.Item(id: id, name: n, groupedLightId: nil)
            item.details = capabilities(l)
            item.product = ((l["owner"] as? JSON)?["rid"] as? String).flatMap { products[$0] } ?? ""
            return item
        }
        inv.rooms = rooms.compactMap { r in
            guard let id = r["id"] as? String, let n = (r["metadata"] as? JSON)?["name"] as? String else { return nil }
            var item = HueInventory.Item(id: id, name: n, groupedLightId: groupedLight(r))
            item.details = ["lights: " + (members(r).joined(separator: ", ").isEmpty ? "none" : members(r).joined(separator: ", "))]
            return item
        }
        inv.zones = zones.compactMap { z in
            guard let id = z["id"] as? String, let n = (z["metadata"] as? JSON)?["name"] as? String else { return nil }
            var item = HueInventory.Item(id: id, name: n, groupedLightId: groupedLight(z))
            item.details = ["lights: " + (members(z).joined(separator: ", ").isEmpty ? "none" : members(z).joined(separator: ", "))]
            return item
        }
        let groupNames = named(rooms).merging(named(zones)) { a, _ in a }
        inv.scenes = scenes.compactMap { s in
            guard let id = s["id"] as? String, let n = (s["metadata"] as? JSON)?["name"] as? String else { return nil }
            let group = (s["group"] as? JSON)?["rid"] as? String
            return .init(id: id, name: n, groupName: group.flatMap { groupNames[$0] })
        }
        lock.withLock { cache = inv }
        return inv
    }
}

import Foundation

/// Executes rule actions against a Hue bridge.
public final class HueActions: ActionExecutor, @unchecked Sendable {
    private let client: HueClient
    private let cycleLock = NSLock()
    private var lastCycled: [String: String] = [:]   // group → scene we last recalled (fallback when the bridge reports none active)

    public init(client: HueClient) { self.client = client }

    public func execute(_ action: Action) async throws {
        switch action {
        case .light(let target, let state):
            for (type, id) in try await resolve(target) {
                try await put(type, id, HueActions.body(for: state))
            }
        case .toggle(let target):
            for (type, id) in try await resolve(target) {
                let current = try await client.request("GET", "/resource/\(type)/\(id)").first
                let isOn = ((current?["on"] as? JSON)?["on"] as? Bool) ?? false
                try await put(type, id, ["on": ["on": !isOn]])
            }
        case .scene(let name, let room, let zone, let brightness):
            let inv = try await client.inventory()
            let group = room ?? zone
            let candidates = inv.scenes.filter { $0.name.lowercased() == name.lowercased() }
            let match = group == nil ? candidates.first
                : candidates.first { $0.groupName?.lowercased() == group!.lowercased() }
            guard let scene = match else {
                let available = inv.scenes.map { "\($0.groupName ?? "?"): \($0.name)" }
                throw HueError.notFound(kind: "scene", name: group.map { "\($0): \(name)" } ?? name, available: available)
            }
            var recall: JSON = ["action": "active"]
            if let brightness { recall["dimming"] = ["brightness": brightness] }
            try await put("scene", scene.id, ["recall": recall])
        case .cycleScenes(let room, let zone, let wanted, let step):
            try await cycle(group: room ?? zone!, kind: room != nil ? "room" : "zone", wanted: wanted, step: step)
        case .dim(let target, let delta, _, _):
            let body: JSON = ["dimming_delta": [
                "action": delta >= 0 ? "up" : "down",
                "brightness_delta": abs(delta),
            ]]
            for (type, id) in try await resolve(target) { try await put(type, id, body) }
        case .wait, .log:
            break
        }
    }

    /// Picks the scene to move to. `current` nil (nothing active) starts at the first scene going forward, the last going back.
    static func nextScene(in names: [String], current: String?, step: Int) -> String? {
        guard !names.isEmpty else { return nil }
        guard let current, let i = names.firstIndex(where: { $0.lowercased() == current.lowercased() }) else {
            return step >= 0 ? names.first : names.last
        }
        return names[((i + step) % names.count + names.count) % names.count]
    }

    private func cycle(group: String, kind: String, wanted: [String], step: Int) async throws {
        let inv = try await client.inventory(refresh: true)
        let inGroup = inv.scenes.filter { $0.groupName?.lowercased() == group.lowercased() }
        guard !inGroup.isEmpty else {
            throw HueError.notFound(kind: "\(kind) with scenes", name: group, available: Set(inv.scenes.compactMap(\.groupName)).sorted())
        }
        // Order: the configured list if given, otherwise alphabetical.
        let names: [String]
        if wanted.isEmpty {
            names = inGroup.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        } else {
            for w in wanted where !inGroup.contains(where: { $0.name.lowercased() == w.lowercased() }) {
                throw HueError.notFound(kind: "scene in \(group)", name: w, available: inGroup.map(\.name))
            }
            names = wanted
        }
        // Which of those is active right now? Ask the bridge so cycling stays in step with other controls.
        let live = try await client.request("GET", "/resource/scene")
        let inOrder = Set(names.map { $0.lowercased() })
        let groupIds = Set(inGroup.map(\.id))
        var activeId: String?
        for item in live {
            let state = (item["status"] as? JSON)?["active"] as? String ?? "inactive"
            let id = item["id"] as? String ?? ""
            let name = ((item["metadata"] as? JSON)?["name"] as? String ?? "").lowercased()
            if state != "inactive", groupIds.contains(id), inOrder.contains(name) { activeId = id; break }
        }
        let current = inGroup.first { $0.id == activeId }?.name ?? cycleLock.withLock { lastCycled[group.lowercased()] }
        guard let target = HueActions.nextScene(in: names, current: current, step: step),
              let scene = inGroup.first(where: { $0.name.lowercased() == target.lowercased() }) else { return }
        cycleLock.withLock { lastCycled[group.lowercased()] = scene.name }
        try await put("scene", scene.id, ["recall": ["action": "active"]])
    }

    private func put(_ type: String, _ id: String, _ body: JSON) async throws {
        _ = try await client.request("PUT", "/resource/\(type)/\(id)", body: body)
    }

    /// Resolves names to (resource type, id) pairs. Rooms and zones are driven through their grouped_light.
    func resolve(_ target: HueTarget) async throws -> [(String, String)] {
        var inv = try await client.inventory()
        func find(_ names: [String], in items: @escaping (HueInventory) -> [HueInventory.Item], kind: String,
                  type: String, useGroup: Bool) async throws -> [(String, String)] {
            var out: [(String, String)] = []
            for name in names {
                var match = items(inv).first { $0.name.lowercased() == name.lowercased() }
                if match == nil {
                    inv = try await client.inventory(refresh: true) // maybe renamed/added since last fetch
                    match = items(inv).first { $0.name.lowercased() == name.lowercased() }
                }
                guard let item = match else {
                    throw HueError.notFound(kind: kind, name: name, available: items(inv).map(\.name))
                }
                if useGroup {
                    guard let gid = item.groupedLightId else {
                        throw HueError.notFound(kind: "group light for \(kind)", name: name, available: [])
                    }
                    out.append(("grouped_light", gid))
                } else {
                    out.append((type, item.id))
                }
            }
            return out
        }
        var result: [(String, String)] = []
        result += try await find(target.lights, in: { $0.lights }, kind: "light", type: "light", useGroup: false)
        result += try await find(target.rooms, in: { $0.rooms }, kind: "room", type: "grouped_light", useGroup: true)
        result += try await find(target.zones, in: { $0.zones }, kind: "zone", type: "grouped_light", useGroup: true)
        return result
    }

    static func body(for state: LightState) -> JSON {
        var body: JSON = [:]
        var on = state.on
        if let b = state.brightness {
            if b <= 0 { on = false } else {
                body["dimming"] = ["brightness": min(100, max(1, b))]
                if on == nil { on = true }
            }
        }
        if let on { body["on"] = ["on": on] }
        if let k = state.colorTempKelvin {
            body["color_temperature"] = ["mirek": min(500, max(153, 1_000_000 / max(k, 1)))]
            if body["on"] == nil && on == nil { body["on"] = ["on": true] }
        }
        if let hex = state.colorHex, let xy = ColorMath.xy(fromHex: hex) {
            body["color"] = ["xy": ["x": xy.x, "y": xy.y]]
            if body["on"] == nil { body["on"] = ["on": true] }
        }
        if let t = state.transitionMs { body["dynamics"] = ["duration": t] }
        return body
    }
}

/// Logs what would happen without touching any lights.
public final class DryRunExecutor: ActionExecutor, @unchecked Sendable {
    private let log: @Sendable (LogEntry) -> Void
    public init(log: @escaping @Sendable (LogEntry) -> Void) { self.log = log }

    public func execute(_ action: Action) async throws {
        log(LogEntry(category: "dry-run", message: "would run \(action)"))
    }
}

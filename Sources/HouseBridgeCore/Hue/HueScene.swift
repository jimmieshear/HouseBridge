import Foundation

/// Builds Hue scenes from a room/zone, a white temperature and a brightness (`housebridgectl create-scene`).
public enum HueScene {
    public static let minMirek = 153, maxMirek = 500   // what Hue accepts (about 6500 K to 2000 K)

    public static func mirek(kelvin: Int) -> Int? {
        guard kelvin > 0 else { return nil }
        let m = Int((1_000_000 / Double(kelvin)).rounded())
        return (minMirek...maxMirek).contains(m) ? m : nil
    }

    /// One action per light. Lights without white temperature (plain dimmable ones) get on + brightness only.
    static func actions(lights: [HueInventory.Item], mirek: Int, brightness: Double) -> [JSON] {
        lights.map { l in
            var action: JSON = ["on": ["on": true], "dimming": ["brightness": brightness]]
            if l.supportsTemperature { action["color_temperature"] = ["mirek": mirek] }
            return ["target": ["rid": l.id, "rtype": "light"], "action": action]
        }
    }

    static func createBody(name: String, group: HueInventory.Item, isZone: Bool, actions: [JSON]) -> JSON {
        ["type": "scene", "metadata": ["name": name],
         "group": ["rid": group.id, "rtype": isZone ? "zone" : "room"], "actions": actions]
    }
}

extension HueClient {
    /// Creates the scene, or with `replace` rewrites the same-named scene of that room/zone. Returns the scene id.
    @discardableResult
    public func createScene(name: String, group: String, kelvin: Int, brightness: Double, replace: Bool) async throws -> (id: String, lights: Int, updated: Bool) {
        guard let mirek = HueScene.mirek(kelvin: kelvin) else {
            throw HueError.invalid("\(kelvin) K is outside what Hue can show (\(1_000_000 / HueScene.maxMirek)–\(1_000_000 / HueScene.minMirek) K).")
        }
        guard (1...100).contains(brightness) else { throw HueError.invalid("Brightness must be between 1 and 100.") }
        let inv = try await inventory(refresh: true)
        let all = inv.rooms.map { ($0, false) } + inv.zones.map { ($0, true) }
        guard let (target, isZone) = all.first(where: { $0.0.name.caseInsensitiveCompare(group) == .orderedSame }) else {
            throw HueError.notFound(kind: "room or zone", name: group, available: all.map { $0.0.name })
        }
        let byId = Dictionary(inv.lights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let lights = target.lightIds.compactMap { byId[$0] }
        guard !lights.isEmpty else { throw HueError.invalid("“\(target.name)” has no lights.") }
        let actions = HueScene.actions(lights: lights, mirek: mirek, brightness: brightness)

        let existing = inv.scenes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.groupName == target.name }
        if let existing {
            guard replace else { throw HueError.invalid("“\(target.name)” already has a scene named “\(name)”. Use --replace to overwrite it.") }
            _ = try await request("PUT", "/resource/scene/\(existing.id)", body: ["actions": actions])
            return (existing.id, lights.count, true)
        }
        let created = try await request("POST", "/resource/scene", body: HueScene.createBody(name: name, group: target, isZone: isZone, actions: actions))
        return (created.first?["rid"] as? String ?? "?", lights.count, false)
    }
}

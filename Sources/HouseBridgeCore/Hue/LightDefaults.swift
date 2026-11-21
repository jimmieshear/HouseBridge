import Foundation

/// `light_defaults:` — the color temperature Hue lights should have whenever they are on, with per-light, per-zone and
/// per-room overrides (most specific wins: light, then zone, then room, then the default).
public struct LightDefaults: Sendable {
    public struct Override: Sendable {
        public enum Target: Sendable { case light(String), room(String), zone(String) }
        public var target: Target
        /// nil with `ignore`.
        public var kelvin: Int?
        /// Never touch these lights.
        public var ignore: Bool
        /// Also put these lights back to white when they are showing a color (normally a light showing a color is left alone).
        public var resetColor: Bool = false
    }
    public var kelvin: Int
    /// How often the bridge is read.
    public var checkSeconds: Double = 30
    /// How far (in kelvin) a light may drift before it is corrected.
    public var toleranceKelvin: Int = 100
    public var overrides: [Override] = []

    static let range = 2000...6500   // what Hue color-temperature lights can do (mirek 153–500)

    static func parse(_ r: Reader) throws -> LightDefaults {
        try r.rejectUnknown(["kelvin", "check_seconds", "tolerance_kelvin", "overrides"])
        func kelvin(_ reader: Reader, required: Bool) throws -> Int? {
            guard let k = try reader.int("kelvin") else {
                if required { throw ConfigError(path: reader.path + ".kelvin", message: "is required") }
                return nil
            }
            guard range.contains(k) else { throw ConfigError(path: reader.path + ".kelvin", message: "must be between 2000 and 6500") }
            return k
        }
        var out = LightDefaults(kelvin: try kelvin(r, required: true)!)
        if let s = try r.double("check_seconds") {
            guard s >= 10 else { throw ConfigError(path: r.path + ".check_seconds", message: "must be at least 10") }
            out.checkSeconds = s
        }
        if let t = try r.int("tolerance_kelvin") {
            guard (0...1000).contains(t) else { throw ConfigError(path: r.path + ".tolerance_kelvin", message: "must be between 0 and 1000") }
            out.toleranceKelvin = t
        }
        if let value = r.map["overrides"] {
            guard case .array(let items) = value else { throw ConfigError(path: r.path + ".overrides", message: "must be a list") }
            for (i, item) in items.enumerated() {
                let path = "\(r.path).overrides[\(i)]"
                guard case .map(let m) = item else { throw ConfigError(path: path, message: "must be a map") }
                let o = Reader(map: m, path: path)
                try o.rejectUnknown(["light", "room", "zone", "kelvin", "ignore", "reset_color"])
                let targets: [Override.Target] = [try o.string("light").map { .light($0) }, try o.string("room").map { .room($0) },
                                                  try o.string("zone").map { .zone($0) }].compactMap { $0 }
                guard targets.count == 1 else { throw ConfigError(path: path, message: "needs exactly one of light:, room: or zone:") }
                let ignore = try o.bool("ignore") ?? false
                let k = try kelvin(o, required: false)
                guard ignore != (k != nil) else { throw ConfigError(path: path, message: "needs either kelvin: or ignore: true") }
                let resetColor = try o.bool("reset_color") ?? false
                guard !(ignore && resetColor) else { throw ConfigError(path: path + ".reset_color", message: "makes no sense together with ignore: true") }
                out.overrides.append(Override(target: targets[0], kelvin: k, ignore: ignore, resetColor: resetColor))
            }
        }
        return out
    }
}

/// A light as the bridge reports it right now.
public struct HueLightState: Sendable {
    public var id: String
    public var name: String
    public var on: Bool
    /// nil when the light is showing a color (xy) rather than a white temperature.
    public var mirek: Int?
    public var minMirek: Int
    public var maxMirek: Int
    /// 0–100, when the bridge reports one.
    public var brightness: Double? = nil
}

public struct TemperatureCorrection: Sendable {
    public var lightID: String
    public var name: String
    public var fromKelvin: Int
    public var toKelvin: Int
    public var toMirek: Int
    public var brightness: Double? = nil
    public var room: String? = nil
    /// The light was showing a color, not a white (`fromKelvin` is 0).
    public var fromColor = false
}

enum LightTemperature {
    static func kelvin(mirek: Int) -> Int { Int((1_000_000 / Double(max(mirek, 1))).rounded()) }

    /// The most specific override that applies to a light: its own, then a zone's, then a room's.
    static func override(for light: HueInventory.Item, inventory: HueInventory, defaults: LightDefaults) -> LightDefaults.Override? {
        func matches(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }
        let zones = Set(inventory.zones.filter { $0.lightIds.contains(light.id) }.map { $0.name.lowercased() })
        let rooms = Set(inventory.rooms.filter { $0.lightIds.contains(light.id) }.map { $0.name.lowercased() })
        for rank in 0..<3 {   // light, then zone, then room
            for o in defaults.overrides {
                let hit: Bool
                switch (rank, o.target) {
                case (0, .light(let n)): hit = matches(n, light.name)
                case (1, .zone(let n)): hit = zones.contains(n.lowercased())
                case (2, .room(let n)): hit = rooms.contains(n.lowercased())
                default: hit = false
                }
                if hit { return o }
            }
        }
        return nil
    }

    /// The kelvin a light should have, or nil when it is to be left alone.
    static func wanted(_ light: HueInventory.Item, inventory: HueInventory, defaults: LightDefaults) -> Int? {
        guard let o = override(for: light, inventory: inventory, defaults: defaults) else { return defaults.kelvin }
        return o.ignore ? nil : o.kelvin
    }

    /// Lights that are on, in white (not a color), outside any active scene, and further from their wanted temperature than
    /// the tolerance. `activeGroups` are the ids of rooms and zones that have a Hue scene recalled.
    static func plan(states: [HueLightState], inventory: HueInventory, activeGroups: Set<String>,
                     defaults: LightDefaults) -> [TemperatureCorrection] {
        let sceneLights = Set((inventory.rooms + inventory.zones).filter { activeGroups.contains($0.id) }.flatMap(\.lightIds))
        let byID = Dictionary(inventory.lights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [TemperatureCorrection] = []
        for state in states where state.on {
            guard !sceneLights.contains(state.id), let light = byID[state.id],
                  let wanted = wanted(light, inventory: inventory, defaults: defaults) else { continue }
            let target = min(state.maxMirek, max(state.minMirek, Int((1_000_000 / Double(wanted)).rounded())))
            let room = inventory.rooms.first { $0.lightIds.contains(state.id) }?.name
            guard let current = state.mirek else {
                // Showing a color rather than a white: left alone, unless its override says to reset it.
                if override(for: light, inventory: inventory, defaults: defaults)?.resetColor == true {
                    out.append(TemperatureCorrection(lightID: state.id, name: state.name, fromKelvin: 0, toKelvin: kelvin(mirek: target),
                                                     toMirek: target, brightness: state.brightness, room: room, fromColor: true))
                }
                continue
            }
            let from = kelvin(mirek: current), to = kelvin(mirek: target)
            if abs(from - to) > defaults.toleranceKelvin {
                out.append(TemperatureCorrection(lightID: state.id, name: state.name, fromKelvin: from, toKelvin: to, toMirek: target,
                                                 brightness: state.brightness, room: room))
            }
        }
        return out
    }
}

/// Reads the lights every `checkSeconds` (one small request, plus the scenes) and puts any that are on at the wrong white
/// temperature back to the default. Lights showing a color, or in a room with a scene recalled, are left alone.
public final class LightTemperatureVerifier: @unchecked Sendable {
    private let client: HueClient
    private let defaults: LightDefaults
    private let log: @Sendable (LogEntry) -> Void
    private var lastSent: [String: Date] = [:]
    private var failing = false
    private var warnedUnknown = false

    public init(client: HueClient, defaults: LightDefaults, log: @escaping @Sendable (LogEntry) -> Void) {
        self.client = client
        self.defaults = defaults
        self.log = log
    }

    public func run() async {
        try? await Task.sleep(for: .seconds(10))   // let the Hue connection check and the first rules go first
        while !Task.isCancelled {
            var pause = defaults.checkSeconds
            do {
                let corrections = try await checkOnce()
                if failing { failing = false; log(LogEntry(category: "hue", message: "light temperature check is working again")) }
                if !corrections.isEmpty { log(LogEntry(category: "hue", message: "set \(corrections.count) light(s) to their default temperature")) }
            } catch {
                if !failing { log(LogEntry(level: .warning, category: "hue", message: "light temperature check failed: \(describeError(error)); will keep trying")) }
                failing = true
                if case HueError.http(let failure) = error, failure.isRateLimited { pause = max(pause * 4, 120) }   // the bridge is busy: ease off
            }
            try? await Task.sleep(for: .seconds(pause))
        }
    }

    /// One pass; returns what it changed.
    @discardableResult
    public func checkOnce() async throws -> [TemperatureCorrection] {
        var inventory = try await client.inventory()
        async let statesRaw = client.lightStates()
        async let groupsRaw = client.activeSceneGroups()
        let (states, groups) = try await (statesRaw, groupsRaw)
        if states.contains(where: { s in !inventory.lights.contains { $0.id == s.id } }) {
            inventory = try await client.inventory(refresh: true)   // a light was added since the last read
        }
        warnAboutUnknownNames(inventory)

        let now = Date()
        let corrections = LightTemperature.plan(states: states, inventory: inventory, activeGroups: groups, defaults: defaults)
            .filter { now.timeIntervalSince(lastSent[$0.lightID] ?? .distantPast) > defaults.checkSeconds * 2 }   // don't nag a light that ignores us
        for c in corrections {
            lastSent[c.lightID] = now
            try await client.setColorTemperature(lightID: c.lightID, mirek: c.toMirek)
            // Where and how bright it was says what moved it: a whole room at one odd value and one brightness points at
            // something recalling a setting (a Home.app or Hue routine), not at drift.
            let context = [c.room, c.brightness.map { "\(Int($0.rounded()))%" }].compactMap { $0 }.joined(separator: ", ")
            log(LogEntry(category: "hue", message: "light ‘\(c.name)’\(context.isEmpty ? "" : " (\(context))"): \(c.fromColor ? "was showing a color" : "\(c.fromKelvin) K") → \(c.toKelvin) K (default; no Hue scene active there)"))
        }
        return corrections
    }

    private func warnAboutUnknownNames(_ inventory: HueInventory) {
        guard !warnedUnknown else { return }
        warnedUnknown = true
        for o in defaults.overrides {
            let (kind, name, known): (String, String, [String])
            switch o.target {
            case .light(let n): (kind, name, known) = ("light", n, inventory.lights.map(\.name))
            case .room(let n): (kind, name, known) = ("room", n, inventory.rooms.map(\.name))
            case .zone(let n): (kind, name, known) = ("zone", n, inventory.zones.map(\.name))
            }
            if !known.contains(where: { $0.lowercased() == name.lowercased() }) {
                log(LogEntry(level: .warning, category: "hue", message: "light_defaults override for \(kind) ‘\(name)’ matches nothing. Available: \(known.sorted().joined(separator: ", "))"))
            }
        }
    }
}

import Foundation

// MARK: - Model

/// Devices an automation hold covers. Names are compared, case-insensitively, with the names used in rule actions.
public struct PauseTargets: Sendable, Equatable {
    public var lutron: [String] = []
    public var lights: [String] = []
    public var rooms: [String] = []
    public var zones: [String] = []
    public var isEmpty: Bool { lutron.isEmpty && lights.isEmpty && rooms.isEmpty && zones.isEmpty }

    /// One key per named device, e.g. "light:porch", so "the latest rule per device" can be worked out.
    var keys: [String] {
        lutron.map { "lutron:" + $0.lowercased() } + lights.map { "light:" + $0.lowercased() }
            + rooms.map { "room:" + $0.lowercased() } + zones.map { "zone:" + $0.lowercased() }
    }

    func covers(_ other: PauseTargets) -> Bool {
        func hit(_ mine: [String], _ theirs: [String]) -> Bool {
            let m = Set(mine.map { $0.lowercased() })
            return theirs.contains { m.contains($0.lowercased()) }
        }
        return hit(lutron, other.lutron) || hit(lights, other.lights) || hit(rooms, other.rooms) || hit(zones, other.zones)
    }
}

/// "Someone is home": while any trigger has fired within `duration`, automatic rules that act on `pauses` are skipped.
/// Every new trigger restarts the clock, so the hold lasts until `duration` after the last one.
public struct PresenceHold: Sendable {
    public var name: String
    public var triggers: [TriggerSpec]
    public var duration: TimeInterval
    public var pauses: PauseTargets
}

extension Action {
    /// What this action controls, for matching against `PauseTargets`.
    var targets: PauseTargets {
        func from(_ t: HueTarget) -> PauseTargets { PauseTargets(lights: t.lights, rooms: t.rooms, zones: t.zones) }
        switch self {
        case .light(let t, _), .toggle(let t), .dim(let t, _, _, _): return from(t)
        case .scene(_, let room, let zone, _), .cycleScenes(let room, let zone, _, _):
            return PauseTargets(rooms: room.map { [$0] } ?? [], zones: zone.map { [$0] } ?? [])
        case .lutron(let device, _, _): return PauseTargets(lutron: [device])
        case .wait, .log: return PauseTargets()
        }
    }
}

extension Rule {
    /// Holds only pause automation. A Pico press is a person at the switch, so it always works, as does a rule marked `ignore_presence`.
    func isPaused(by hold: PresenceHold) -> Bool {
        guard trigger.source != .pico, !ignorePresence else { return false }
        return actions.contains { hold.pauses.covers($0.targets) }
    }
}

// MARK: - Persistence

/// Remembers when each hold ends, so a config reload or app restart does not end it early.
public final class HoldStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public func load() -> [String: Date] {
        lock.withLock {
            guard let data = try? Data(contentsOf: url),
                  let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Double] else { return [:] }
            return raw.mapValues { Date(timeIntervalSince1970: $0) }
        }
    }

    public func save(_ holds: [String: Date]) {
        lock.withLock {
            let raw = holds.mapValues { $0.timeIntervalSince1970 }
            guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

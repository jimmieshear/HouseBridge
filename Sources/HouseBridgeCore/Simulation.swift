import Foundation

// MARK: - Model

/// "Looks lived in": on random nights, turns lights on for a while at random times inside a window.
/// Sessions are planned a night at a time and run like any automatic rule, so a presence hold that covers
/// the lights pauses them.
public struct Simulation: Sendable {
    public var name: String
    public var enabled = true
    public var between: TimeWindow
    /// Chance (0...1) that a night is active, for nights starting on a weekend day and on other days.
    public var weekdayChance: Double
    public var weekendChance: Double
    /// `Calendar` weekday numbers whose evenings count as weekend nights.
    public var weekendDays: Set<Int>
    public var sessions: ClosedRange<Int>
    public var minutes: ClosedRange<Double>
    /// One is picked per session. Each is a `light` action; `on` and `off_after_seconds` are filled in.
    public var choices: [(target: HueTarget, state: LightState)]

    func chance(forNightStarting day: Date, calendar: Calendar) -> Double {
        weekendDays.contains(calendar.component(.weekday, from: day)) ? weekendChance : weekdayChance
    }
}

public struct SimulatedSession: Sendable, Equatable {
    public var start: Date
    public var seconds: TimeInterval
    public var choice: Int
    public var end: Date { start.addingTimeInterval(seconds) }
}

// MARK: - Planning

/// Small deterministic generator, so one night's plan is the same after a restart or config reload.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// FNV-1a (Swift's `Hasher` is randomly seeded per process).
    static func seed(_ text: String) -> UInt64 {
        text.utf8.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    }
}

extension Simulation {
    /// The window that starts on the local day of `day` (it may end after midnight).
    func window(startingOn day: Date, location: GeoLocation?, calendar: Calendar) -> (start: Date, end: Date)? {
        guard let s = between.start.fireDate(onDayOf: day, location: location, calendar: calendar),
              var e = between.end.fireDate(onDayOf: day, location: location, calendar: calendar) else { return nil }
        if e <= s { guard let next = calendar.date(byAdding: .day, value: 1, to: e) else { return nil }; e = next }
        return (s, e)
    }

    /// The sessions for the night whose window starts on `day`; empty when the dice say the night is quiet.
    func plan(nightStarting day: Date, location: GeoLocation?, calendar: Calendar = .current) -> [SimulatedSession] {
        guard !choices.isEmpty, let (start, end) = window(startingOn: day, location: location, calendar: calendar) else { return [] }
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        var rng = SeededGenerator(seed: SeededGenerator.seed("\(name)|\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"))
        guard Double.random(in: 0..<1, using: &rng) < chance(forNightStarting: day, calendar: calendar) else { return [] }

        let span = end.timeIntervalSince(start)
        var out: [SimulatedSession] = []
        for _ in 0..<Int.random(in: sessions, using: &rng) {
            let seconds = min(Double.random(in: minutes, using: &rng) * 60, span)
            let choice = Int.random(in: 0..<choices.count, using: &rng)
            // A few tries to avoid overlapping an earlier session on the same lights, which would just extend it.
            for _ in 0..<5 {
                let begin = start.addingTimeInterval(Double.random(in: 0...(span - seconds), using: &rng))
                let candidate = SimulatedSession(start: begin, seconds: seconds, choice: choice)
                if out.contains(where: { $0.choice == choice && $0.start < candidate.end && candidate.start < $0.end }) { continue }
                out.append(candidate)
                break
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Sessions still relevant at `date` (not yet over), tonight first, looking up to a week ahead.
    public func upcoming(after date: Date, location: GeoLocation?, calendar: Calendar = .current, days: Int = 8) -> [SimulatedSession] {
        let today = calendar.startOfDay(for: date)
        var out: [SimulatedSession] = []
        for offset in -1..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            out += plan(nightStarting: day, location: location, calendar: calendar).filter { $0.end > date }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// The `light` action for one session, `remaining` seconds long.
    func action(for session: SimulatedSession, remaining: TimeInterval) -> Action {
        let (target, base) = choices[session.choice]
        var state = base
        state.on = true
        state.offAfterSeconds = max(1, remaining.rounded())
        return .light(target, state)
    }
}

// MARK: - Parsing

extension ConfigLoader {
    static func parseSimulation(_ r: Reader) throws -> Simulation {
        try r.rejectUnknown(["name", "enabled", "between", "nights", "weekend_days", "sessions", "minutes", "lights"])
        guard case .array(let parts)? = r.map["between"], parts.count == 2,
              let s = parts[0].stringValue.flatMap(parseTimePoint), let e = parts[1].stringValue.flatMap(parseTimePoint) else {
            throw ConfigError(path: r.path + ".between", message: "is required: two times such as [\"19:00\", \"23:30\"] or [sunset, \"23:30\"]")
        }

        var weekday = 40.0, weekend = 70.0
        if let n = try r.reader("nights") {
            try n.rejectUnknown(["weekday", "weekend"])
            weekday = try n.double("weekday") ?? weekday
            weekend = try n.double("weekend") ?? weekend
            for (key, v) in [("weekday", weekday), ("weekend", weekend)] where !(0...100).contains(v) {
                throw ConfigError(path: n.path + "." + key, message: "is a percentage of nights, 0–100")
            }
        }

        var weekendDays: Set<Int> = [6, 7, 1]   // Fri, Sat, Sun
        if r.map["weekend_days"] != nil {
            weekendDays = []
            for name in try r.stringList("weekend_days") {
                guard let i = Schedule.dayNames.firstIndex(of: name.lowercased()) else {
                    throw ConfigError(path: r.path + ".weekend_days", message: "'\(name)' is not one of \(Schedule.dayNames.joined(separator: ", "))")
                }
                weekendDays.insert(i + 1)
            }
        }

        func range<T: Comparable>(_ key: String, _ fallback: ClosedRange<T>, _ value: (YAMLValue) -> T?) throws -> ClosedRange<T> {
            guard let raw = r.map[key] else { return fallback }
            // A single number means exactly that many.
            if let one = value(raw) { return one...one }
            guard case .array(let items) = raw, items.count == 2, let lo = value(items[0]), let hi = value(items[1]), lo <= hi else {
                throw ConfigError(path: r.path + "." + key, message: "expected a number or a [min, max] pair")
            }
            return lo...hi
        }
        let sessions = try range("sessions", 1...3) { $0.intValue }
        let minutes = try range("minutes", 15.0...90.0) { $0.doubleValue }
        guard sessions.lowerBound >= 0 else { throw ConfigError(path: r.path + ".sessions", message: "can't be negative") }
        guard minutes.lowerBound > 0 else { throw ConfigError(path: r.path + ".minutes", message: "must be greater than 0") }

        guard case .array(let rawLights)? = r.map["lights"], !rawLights.isEmpty else {
            throw ConfigError(path: r.path + ".lights", message: "needs a non-empty list, e.g. - { room: Bedroom 1 }")
        }
        var choices: [(HueTarget, LightState)] = []
        for (i, raw) in rawLights.enumerated() {
            guard case .map(let m) = raw else { throw ConfigError(path: "\(r.path).lights[\(i)]", message: "must be a map") }
            var withAction = m
            withAction["action"] = .string("light")
            withAction["on"] = .bool(true)
            for key in ["on", "off_after_seconds"] where m[key] != nil {
                throw ConfigError(path: "\(r.path).lights[\(i)].\(key)", message: "is set by the simulation")
            }
            guard case .light(let target, let state) = try parseAction(Reader(map: withAction, path: "\(r.path).lights[\(i)]")) else { continue }
            choices.append((target, state))
        }

        return Simulation(name: try r.requireString("name"), enabled: try r.bool("enabled") ?? true,
                          between: TimeWindow(start: s, end: e), weekdayChance: weekday / 100, weekendChance: weekend / 100,
                          weekendDays: weekendDays, sessions: sessions, minutes: minutes, choices: choices)
    }
}

import Foundation

// MARK: - Model

public struct Config: Sendable {
    public var lutron: LutronConfig?
    public var hue: HueConfig?
    public var unifi: UnifiConfig?
    public var homekit: HomeKitConfig?
    /// Where the house is; needed for `sunrise`/`sunset` schedules.
    public var location: GeoLocation?
    public var presence: [PresenceHold] = []
    public var timing = Timing()
    public var rules: [Rule] = []
    public init() {}
}

public struct LutronConfig: Sendable {
    public var host: String
    public var port: Int = 8081
    public var caPath: String
    public var certPath: String
    public var keyPath: String

    /// Human-readable list of configured PEM files that don't exist (empty when all are present).
    public func missingFiles() -> [String] {
        [("ca", caPath), ("cert", certPath), ("key", keyPath)]
            .filter { !FileManager.default.isReadableFile(atPath: $0.1) }
            .map { "\($0.0): \($0.1)" }
    }
}

public struct HueConfig: Sendable {
    public var host: String
}

public struct UnifiConfig: Sendable {
    public var host: String
    public var username: String
    public var password: String?
    public var passwordEnv: String?
    /// Seconds after a sensor stops before a `clear` event is emitted.
    public var clearAfterSeconds: Double = 30

    /// Order: `password:` in the file, then the environment variable named by `password_env:`, then the macOS Keychain
    /// (stored with `housebridgectl set-unifi-password`).
    public func resolvedPassword() -> String? {
        if let password, !password.isEmpty { return password }
        if let name = passwordEnv, let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
        return Keychain.readPassword(host: host, username: username)
    }
}

public struct Timing: Sendable {
    public var doubleTapMs: Int = 300
    public var holdMs: Int = 500
}

public struct Rule: Sendable {
    public var name: String
    public var enabled = true
    public var trigger: TriggerSpec
    public var between: TimeWindow?
    public var cooldownSeconds: Double = 0
    /// When a presence hold covering this rule's devices ends, also run its actions (for "should always be true" rules).
    public var onResume = false
    /// Keeps running while a presence hold is active, even for devices the hold pauses.
    public var ignorePresence = false
    public var actions: [Action]
}

public struct TriggerSpec: Sendable {
    public var source: Source
    /// nil or "*" matches any device.
    public var device: String?
    /// Button / sensor input; nil or "*" matches any.
    public var input: String?
    public var kind: String
    /// Set for `clock` triggers; the scheduler fires these.
    public var schedule: Schedule?

    public func matches(_ event: TriggerEvent, ignoringKind: Bool = false) -> Bool {
        guard event.source == source else { return false }
        if !ignoringKind && event.kind != kind { return false }
        if let device, device != "*" {
            let wanted = device.lowercased()
            let names = ([event.device] + event.deviceAliases).map { $0.lowercased() }
            if !names.contains(wanted) { return false }
        }
        if let input, input != "*" {
            let wanted = input.lowercased()
            let names = ([event.input] + event.inputAliases).map { $0.lowercased() }
            if !names.contains(wanted) { return false }
        }
        return true
    }
}

public struct TimeWindow: Sendable {
    public var start: Schedule
    public var end: Schedule

    public init(start: Schedule, end: Schedule) { self.start = start; self.end = end }
    public init(startMinutes: Int, endMinutes: Int) {
        self.init(start: Schedule(anchor: .clock(minutes: startMinutes)), end: Schedule(anchor: .clock(minutes: endMinutes)))
    }

    public var usesSun: Bool { start.usesSun || end.usesSun }

    /// Windows may wrap midnight (e.g. 18:00 → 06:00) and may end at sunrise/sunset (compared using today's times).
    public func contains(_ date: Date, location: GeoLocation? = nil, calendar: Calendar = .current) -> Bool {
        guard let s = start.fireDate(onDayOf: date, location: location, calendar: calendar),
              let e = end.fireDate(onDayOf: date, location: location, calendar: calendar) else { return false }
        // Compare as times of day so a wrapping window is recognised whichever instants they land on.
        func minutes(_ d: Date) -> Int { let c = calendar.dateComponents([.hour, .minute], from: d); return (c.hour ?? 0) * 60 + (c.minute ?? 0) }
        let (sm, em, now) = (minutes(s), minutes(e), minutes(date))
        if sm <= em { return now >= sm && now < em }
        return now >= sm || now < em
    }
}

public struct HueTarget: Sendable {
    public var lights: [String] = []
    public var rooms: [String] = []
    public var zones: [String] = []
    public var isEmpty: Bool { lights.isEmpty && rooms.isEmpty && zones.isEmpty }
}

public struct LightState: Sendable {
    public var on: Bool?
    public var brightness: Double?
    public var colorTempKelvin: Int?
    public var colorHex: String?
    public var transitionMs: Int?
    /// With `on: true`, the engine turns the same target off this long after the last such action.
    public var offAfterSeconds: Double?
}

public enum Action: Sendable {
    case light(HueTarget, LightState)
    case toggle(HueTarget)
    case scene(name: String, room: String?, zone: String?, brightness: Double?)
    /// Steps through a room's/zone's scenes. `scenes` fixes the order; empty means every scene in the group, sorted by name.
    case cycleScenes(room: String?, zone: String?, scenes: [String], step: Int)
    case dim(HueTarget, delta: Double, repeatWhileHeld: Bool, intervalMs: Int)
    /// Switches a Lutron switch/dimmer. `offAfterSeconds` (with `on: true`) schedules an off; a new `lutron` action for the same device restarts it.
    case lutron(device: String, on: Bool, offAfterSeconds: Double?)
    case wait(ms: Int)
    case log(String)
}

// MARK: - Errors

public struct ConfigError: Error, CustomStringConvertible {
    public let path: String
    public let message: String
    public var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

// MARK: - Loading

public enum ConfigLoader {
    public static func load(from url: URL) throws -> Config {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text, baseDirectory: url.deletingLastPathComponent())
    }

    /// `baseDirectory` is what relative file paths in the config are resolved against (normally the config file's folder).
    public static func parse(_ text: String, baseDirectory: URL? = nil) throws -> Config {
        let root = try YAML.parse(text)
        guard case .map(let top) = root else { throw ConfigError(path: "", message: "top level must be a map") }
        let r = Reader(map: top, path: "")
        try r.rejectUnknown(["lutron", "hue", "unifi", "homekit", "location", "presence", "timing", "rules"])

        var config = Config()
        if let l = try r.reader("lutron") {
            try l.rejectUnknown(["host", "port", "certs_dir", "ca", "cert", "key"])
            let found = try l.string("certs_dir").map { try discoverPEMs(in: resolve($0, base: baseDirectory), path: l.path + ".certs_dir") }
            func file(_ key: String, _ discovered: String?) throws -> String {
                if let explicit = try l.string(key) { return resolve(explicit, base: baseDirectory) }
                if let discovered { return discovered }
                throw ConfigError(path: l.path + "." + key,
                                  message: "is required (set '\(key):' to the PEM file, or set 'certs_dir:' to a folder containing the CA, cert and key files)")
            }
            config.lutron = LutronConfig(host: try l.requireString("host"),
                                         port: try l.int("port") ?? 8081,
                                         caPath: try file("ca", found?.ca),
                                         certPath: try file("cert", found?.cert),
                                         keyPath: try file("key", found?.key))
        }
        if let h = try r.reader("hue") {
            try h.rejectUnknown(["host"])
            config.hue = HueConfig(host: try h.requireString("host"))
        }
        if let u = try r.reader("unifi") {
            try u.rejectUnknown(["host", "username", "password", "password_env", "clear_after_seconds"])
            var cfg = UnifiConfig(host: try u.requireString("host"), username: try u.requireString("username"))
            cfg.password = try u.string("password")
            cfg.passwordEnv = try u.string("password_env")
            cfg.clearAfterSeconds = try u.double("clear_after_seconds") ?? 30
            config.unifi = cfg
        }
        if let h = try r.reader("homekit") {
            try h.rejectUnknown(["name", "port", "setup_code", "smart_detections"])
            var cfg = HomeKitConfig()
            if let name = try h.string("name") {
                guard !name.isEmpty, name.count <= 64 else { throw ConfigError(path: h.path + ".name", message: "must be 1-64 characters") }
                cfg.name = name
            }
            if let port = try h.int("port") {
                guard (1024...65535).contains(port) else { throw ConfigError(path: h.path + ".port", message: "must be between 1024 and 65535") }
                cfg.port = port
            }
            if let code = try h.string("setup_code") {
                guard HAPStore.isValidSetupCode(code) else {
                    throw ConfigError(path: h.path + ".setup_code", message: "must look like 031-45-154 (8 digits; HomeKit rejects easy ones such as 123-45-678 or 111-11-111)")
                }
                cfg.setupCode = code
            }
            cfg.smartDetections = try h.bool("smart_detections") ?? false
            config.homekit = cfg
        }
        if let l = try r.reader("location") {
            try l.rejectUnknown(["latitude", "longitude"])
            guard let lat = try l.double("latitude") else { throw ConfigError(path: l.path + ".latitude", message: "is required") }
            guard let lon = try l.double("longitude") else { throw ConfigError(path: l.path + ".longitude", message: "is required") }
            guard (-90...90).contains(lat) else { throw ConfigError(path: l.path + ".latitude", message: "must be between -90 and 90") }
            guard (-180...180).contains(lon) else { throw ConfigError(path: l.path + ".longitude", message: "must be between -180 and 180 (west of Greenwich is negative)") }
            config.location = GeoLocation(latitude: lat, longitude: lon)
        }
        if let p = top["presence"] {
            guard case .array(let items) = p else { throw ConfigError(path: "presence", message: "must be a list") }
            for (i, item) in items.enumerated() {
                guard case .map(let m) = item else { throw ConfigError(path: "presence[\(i)]", message: "must be a map") }
                config.presence.append(try parseHold(Reader(map: m, path: "presence[\(i)]")))
            }
        }
        if let t = try r.reader("timing") {
            try t.rejectUnknown(["double_tap_ms", "hold_ms"])
            config.timing.doubleTapMs = try t.int("double_tap_ms") ?? config.timing.doubleTapMs
            config.timing.holdMs = try t.int("hold_ms") ?? config.timing.holdMs
        }
        if let rules = top["rules"] {
            guard case .array(let items) = rules else { throw ConfigError(path: "rules", message: "must be a list") }
            for (i, item) in items.enumerated() {
                guard case .map(let m) = item else { throw ConfigError(path: "rules[\(i)]", message: "must be a map") }
                config.rules.append(try parseRule(Reader(map: m, path: "rules[\(i)]")))
            }
        }
        try validate(config)
        return config
    }


    /// `~` is expanded; relative paths are taken relative to the config file's folder.
    static func resolve(_ path: String, base: URL?) -> String {
        let expanded = Paths.expand(path)
        if expanded.hasPrefix("/") { return expanded }
        return (base ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .appendingPathComponent(expanded).standardizedFileURL.path
    }

    /// Picks the CA, client certificate and private key out of a folder by file name, e.g. Home Assistant's
    /// `lutron_caseta-<id>-ca.pem` / `-cert.pem` / `-key.pem`, or `ca.crt` / `client.crt` / `client.key`.
    static func discoverPEMs(in directory: String, path: String) throws -> (ca: String?, cert: String?, key: String?) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            // Folder not there yet: keep the config loadable and let missingFiles() report exactly what's absent.
            return ((directory as NSString).appendingPathComponent("ca.pem"),
                    (directory as NSString).appendingPathComponent("cert.pem"),
                    (directory as NSString).appendingPathComponent("key.pem"))
        }
        var ca: String?, cert: String?, key: String?
        for name in names.sorted() {
            let url = URL(fileURLWithPath: name)
            let ext = url.pathExtension.lowercased()
            guard ["pem", "crt", "cer", "key"].contains(ext) else { continue }
            let last = url.deletingPathExtension().lastPathComponent.lowercased()
                .split(whereSeparator: { "-_.".contains($0) }).last.map(String.init) ?? ""
            let full = (directory as NSString).appendingPathComponent(name)
            if ext == "key" || last == "key" { key = key ?? full }
            else if last == "ca" || last == "root" { ca = ca ?? full }
            else if ["cert", "certificate", "client", "crt"].contains(last) { cert = cert ?? full }
        }
        if ca == nil && cert == nil && key == nil {
            throw ConfigError(path: path, message: "no PEM files recognised in \(directory) (expected names ending in -ca, -cert and -key)")
        }
        return (ca, cert, key)
    }

    private static func validate(_ config: Config) throws {
        if config.homekit != nil && config.unifi == nil {
            throw ConfigError(path: "homekit", message: "publishes UniFi Protect devices to Home.app, so it needs a 'unifi:' section")
        }
        var seen = Set<String>()
        for hold in config.presence {
            guard seen.insert(hold.name.lowercased()).inserted else { throw ConfigError(path: "presence", message: "two holds are named '\(hold.name)'") }
            for t in hold.triggers {
                switch t.source {
                case .pico, .lutronSwitch:
                    if config.lutron == nil { throw ConfigError(path: "presence", message: "hold '\(hold.name)' uses Lutron but there is no 'lutron:' section") }
                case .unifi:
                    if config.unifi == nil { throw ConfigError(path: "presence", message: "hold '\(hold.name)' uses UniFi but there is no 'unifi:' section") }
                case .clock: break
                }
            }
        }
        for rule in config.rules {
            if rule.between?.usesSun == true && config.location == nil {
                throw ConfigError(path: "rules", message: "rule '\(rule.name)' uses sunrise/sunset in 'between' but there is no 'location:' section (latitude and longitude)")
            }
            switch rule.trigger.source {
            case .pico, .lutronSwitch:
                if config.lutron == nil { throw ConfigError(path: "rules", message: "rule '\(rule.name)' uses Lutron but there is no 'lutron:' section") }
            case .unifi:
                if config.unifi == nil { throw ConfigError(path: "rules", message: "rule '\(rule.name)' uses UniFi but there is no 'unifi:' section") }
            case .clock:
                if rule.trigger.schedule?.usesSun == true && config.location == nil {
                    throw ConfigError(path: "rules", message: "rule '\(rule.name)' uses sunrise/sunset but there is no 'location:' section (latitude and longitude)")
                }
            }
            let usesHue = rule.actions.contains {
                switch $0 { case .wait, .log, .lutron: false; default: true }
            }
            let usesLutronOutput = rule.actions.contains { if case .lutron = $0 { true } else { false } }
            if usesLutronOutput && config.lutron == nil {
                throw ConfigError(path: "rules", message: "rule '\(rule.name)' controls a Lutron switch but there is no 'lutron:' section")
            }
            if usesHue && config.hue == nil {
                throw ConfigError(path: "rules", message: "rule '\(rule.name)' controls Hue but there is no 'hue:' section")
            }
        }
    }

    private static let picoGestures: Set<String> = ["press", "release", "tap", "double_tap", "hold", "hold_release"]
    private static let unifiStates: Set<String> = ["start", "end", "clear", "open", "closed"]

    private static func parseHold(_ r: Reader) throws -> PresenceHold {
        try r.rejectUnknown(["name", "when", "hold_hours", "hold_minutes", "pauses"])
        var triggers: [TriggerSpec] = []
        guard case .array(let rawWhen)? = r.map["when"], !rawWhen.isEmpty else {
            throw ConfigError(path: r.path + ".when", message: "needs a non-empty list of triggers, e.g. - { unifi: Front Door Motion, event: motion, state: start }")
        }
        for (i, raw) in rawWhen.enumerated() {
            guard case .map(let m) = raw else { throw ConfigError(path: "\(r.path).when[\(i)]", message: "must be a map") }
            let t = try parseTrigger(Reader(map: m, path: "\(r.path).when[\(i)]"))
            if t.source == .clock { throw ConfigError(path: "\(r.path).when[\(i)]", message: "a presence hold is set by a sensor or switch, not by the clock") }
            triggers.append(t)
        }
        let hours = try r.double("hold_hours"), minutes = try r.double("hold_minutes")
        if hours != nil && minutes != nil { throw ConfigError(path: r.path, message: "use either 'hold_hours' or 'hold_minutes', not both") }
        let seconds = hours.map { $0 * 3600 } ?? minutes.map { $0 * 60 } ?? 24 * 3600
        guard seconds > 0 else { throw ConfigError(path: r.path + ".hold_hours", message: "must be greater than 0") }
        guard case .array(let rawPauses)? = r.map["pauses"], !rawPauses.isEmpty else {
            throw ConfigError(path: r.path + ".pauses", message: "needs a non-empty list of devices, e.g. - { lutron: Garage Wall Lights }")
        }
        var pauses = PauseTargets()
        for (i, raw) in rawPauses.enumerated() {
            guard case .map(let m) = raw else { throw ConfigError(path: "\(r.path).pauses[\(i)]", message: "must be a map") }
            let p = Reader(map: m, path: "\(r.path).pauses[\(i)]")
            try p.rejectUnknown(["lutron", "light", "room", "zone"])
            let before = pauses
            pauses.lutron += try p.stringList("lutron")
            pauses.lights += try p.stringList("light")
            pauses.rooms += try p.stringList("room")
            pauses.zones += try p.stringList("zone")
            if pauses == before { throw ConfigError(path: p.path, message: "needs 'lutron:', 'light:', 'room:' or 'zone:'") }
        }
        return PresenceHold(name: try r.requireString("name"), triggers: triggers, duration: seconds, pauses: pauses)
    }

    /// One `when:` map: pico / switch / unifi / at.
    private static func parseTrigger(_ w: Reader) throws -> TriggerSpec {
        let trigger: TriggerSpec
        if let device = try w.string("pico") {
            try w.rejectUnknown(["pico", "button", "gesture"])
            let gesture = try w.string("gesture") ?? "tap"
            guard picoGestures.contains(gesture) else {
                throw ConfigError(path: w.path + ".gesture", message: "'\(gesture)' is not one of \(picoGestures.sorted().joined(separator: ", "))")
            }
            trigger = TriggerSpec(source: .pico, device: device, input: try w.string("button"), kind: gesture)
        } else if let device = try w.string("switch") {
            try w.rejectUnknown(["switch", "state"])
            let state = try w.string("state") ?? "on"
            guard state == "on" || state == "off" else {
                throw ConfigError(path: w.path + ".state", message: "must be 'on' or 'off'")
            }
            trigger = TriggerSpec(source: .lutronSwitch, device: device, input: "power", kind: state)
        } else if let device = try w.string("unifi") {
            try w.rejectUnknown(["unifi", "event", "state"])
            let state = try w.string("state") ?? "start"
            guard unifiStates.contains(state) else {
                throw ConfigError(path: w.path + ".state", message: "'\(state)' is not one of \(unifiStates.sorted().joined(separator: ", "))")
            }
            trigger = TriggerSpec(source: .unifi, device: device, input: try w.string("event") ?? "motion", kind: state)
        } else if let at = try w.string("at") {
            try w.rejectUnknown(["at", "offset_minutes", "days"])
            let anchor: Schedule.Anchor
            switch at.lowercased() {
            case "sunrise": anchor = .sunrise
            case "sunset": anchor = .sunset
            default:
                guard let minutes = parseClock(at) else {
                    throw ConfigError(path: w.path + ".at", message: "expected a 24-hour time like \"18:30\", or sunrise / sunset")
                }
                anchor = .clock(minutes: minutes)
            }
            let offset = try w.int("offset_minutes") ?? 0
            if offset != 0, case .clock = anchor {
                throw ConfigError(path: w.path + ".offset_minutes", message: "only applies to sunrise / sunset; put the time in 'at:' instead")
            }
            guard abs(offset) <= 720 else { throw ConfigError(path: w.path + ".offset_minutes", message: "must be within ±720 (12 hours)") }
            var days = Set<Int>()
            for name in try w.stringList("days") {
                switch name.lowercased() {
                case "weekdays": days.formUnion(2...6)
                case "weekends": days.formUnion([1, 7])
                case "daily", "everyday": break
                case let n:
                    guard let i = Schedule.dayNames.firstIndex(of: String(n.prefix(3))), n.count >= 3 else {
                        throw ConfigError(path: w.path + ".days", message: "'\(name)' is not a day (use mon, tue, wed, thu, fri, sat, sun, weekdays or weekends)")
                    }
                    days.insert(i + 1)
                }
            }
            let schedule = Schedule(anchor: anchor, offsetMinutes: offset, days: days)
            trigger = TriggerSpec(source: .clock, device: nil, input: schedule.key, kind: "fire", schedule: schedule)
        } else {
            throw ConfigError(path: w.path, message: "needs one of 'pico:', 'switch:', 'unifi:' (naming the device, \"*\" for any) or 'at:' (a time, sunrise or sunset)")
        }
        return trigger
    }

    private static func parseRule(_ r: Reader) throws -> Rule {
        try r.rejectUnknown(["name", "enabled", "when", "between", "cooldown_seconds", "on_resume", "ignore_presence", "then"])
        guard let w = try r.reader("when") else { throw ConfigError(path: r.path, message: "missing 'when'") }

        let trigger = try parseTrigger(w)

        var window: TimeWindow?
        if let b = r.map["between"] {
            guard case .array(let parts) = b, parts.count == 2,
                  let s = parts[0].stringValue.flatMap(parseTimePoint), let e = parts[1].stringValue.flatMap(parseTimePoint) else {
                throw ConfigError(path: r.path + ".between", message: "expected two times such as [\"18:00\", \"06:00\"] or [\"23:00\", sunrise] (also sunset, sunset-30, sunrise+15)")
            }
            window = TimeWindow(start: s, end: e)
        }

        guard case .array(let rawActions)? = r.map["then"], !rawActions.isEmpty else {
            throw ConfigError(path: r.path + ".then", message: "needs a non-empty list of actions")
        }
        var actions: [Action] = []
        for (i, raw) in rawActions.enumerated() {
            guard case .map(let m) = raw else { throw ConfigError(path: "\(r.path).then[\(i)]", message: "must be a map") }
            actions.append(try parseAction(Reader(map: m, path: "\(r.path).then[\(i)]")))
        }

        let name = try r.string("name") ?? "rule"
        let rule = Rule(name: name, enabled: try r.bool("enabled") ?? true, trigger: trigger, between: window,
                        cooldownSeconds: try r.double("cooldown_seconds") ?? 0,
                        onResume: try r.bool("on_resume") ?? false,
                        ignorePresence: try r.bool("ignore_presence") ?? false, actions: actions)
        if rule.trigger.source == .pico, rule.actions.contains(where: {
            if case .dim(_, _, true, _) = $0 { return true } else { return false }
        }), !["hold", "press"].contains(rule.trigger.kind) {
            throw ConfigError(path: r.path, message: "'repeat_while_held' only makes sense with gesture 'hold' or 'press'")
        }
        return rule
    }

    private static func parseTarget(_ r: Reader) throws -> HueTarget {
        HueTarget(lights: try r.stringList("light"), rooms: try r.stringList("room"), zones: try r.stringList("zone"))
    }

    private static func parseAction(_ r: Reader) throws -> Action {
        let kind = try r.requireString("action")
        switch kind {
        case "light":
            try r.rejectUnknown(["action", "light", "room", "zone", "on", "brightness", "color_temp_kelvin", "color", "transition_ms", "off_after_seconds"])
            let target = try parseTarget(r)
            guard !target.isEmpty else { throw ConfigError(path: r.path, message: "needs 'light:', 'room:' or 'zone:'") }
            var state = LightState()
            state.on = try r.bool("on")
            state.brightness = try r.double("brightness")
            state.colorTempKelvin = try r.int("color_temp_kelvin")
            state.colorHex = try r.string("color")
            state.transitionMs = try r.int("transition_ms")
            state.offAfterSeconds = try r.double("off_after_seconds")
            if let off = state.offAfterSeconds {
                guard off > 0 else { throw ConfigError(path: r.path + ".off_after_seconds", message: "must be greater than 0") }
                guard state.on == true else { throw ConfigError(path: r.path + ".off_after_seconds", message: "only makes sense with 'on: true'") }
            }
            if let b = state.brightness, !(0...100).contains(b) {
                throw ConfigError(path: r.path + ".brightness", message: "must be 0–100")
            }
            if let hex = state.colorHex, ColorMath.xy(fromHex: hex) == nil {
                throw ConfigError(path: r.path + ".color", message: "expected a hex color like \"#FFAA00\"")
            }
            return .light(target, state)
        case "toggle":
            try r.rejectUnknown(["action", "light", "room", "zone"])
            let target = try parseTarget(r)
            guard !target.isEmpty else { throw ConfigError(path: r.path, message: "needs 'light:', 'room:' or 'zone:'") }
            return .toggle(target)
        case "scene":
            try r.rejectUnknown(["action", "name", "room", "zone", "brightness"])
            return .scene(name: try r.requireString("name"), room: try r.string("room"),
                          zone: try r.string("zone"), brightness: try r.double("brightness"))
        case "cycle_scenes":
            try r.rejectUnknown(["action", "room", "zone", "scenes", "direction"])
            let room = try r.string("room"), zone = try r.string("zone")
            guard (room == nil) != (zone == nil) else {
                throw ConfigError(path: r.path, message: "needs exactly one of 'room:' or 'zone:'")
            }
            let direction = try r.string("direction") ?? "next"
            guard direction == "next" || direction == "previous" else {
                throw ConfigError(path: r.path + ".direction", message: "must be 'next' or 'previous'")
            }
            return .cycleScenes(room: room, zone: zone, scenes: try r.stringList("scenes"), step: direction == "next" ? 1 : -1)
        case "dim":
            try r.rejectUnknown(["action", "light", "room", "zone", "direction", "step", "repeat_while_held", "interval_ms"])
            let target = try parseTarget(r)
            guard !target.isEmpty else { throw ConfigError(path: r.path, message: "needs 'light:', 'room:' or 'zone:'") }
            let direction = try r.string("direction") ?? "up"
            guard direction == "up" || direction == "down" else {
                throw ConfigError(path: r.path + ".direction", message: "must be 'up' or 'down'")
            }
            let step = try r.double("step") ?? 10
            return .dim(target, delta: direction == "up" ? step : -step,
                        repeatWhileHeld: try r.bool("repeat_while_held") ?? false,
                        intervalMs: try r.int("interval_ms") ?? 400)
        case "lutron":
            try r.rejectUnknown(["action", "switch", "on", "off_after_seconds"])
            let off = try r.double("off_after_seconds")
            let on = try r.bool("on") ?? true
            if let off {
                guard off > 0 else { throw ConfigError(path: r.path + ".off_after_seconds", message: "must be greater than 0") }
                guard on else { throw ConfigError(path: r.path + ".off_after_seconds", message: "only makes sense with 'on: true'") }
            }
            return .lutron(device: try r.requireString("switch"), on: on, offAfterSeconds: off)
        case "wait":
            try r.rejectUnknown(["action", "ms", "seconds"])
            if let s = try r.double("seconds") { return .wait(ms: Int(s * 1000)) }
            return .wait(ms: try r.int("ms") ?? 1000)
        case "log":
            try r.rejectUnknown(["action", "message"])
            return .log(try r.requireString("message"))
        default:
            throw ConfigError(path: r.path + ".action", message: "unknown action '\(kind)' (expected light, toggle, scene, cycle_scenes, dim, lutron, wait, log)")
        }
    }

    /// "18:30", "sunrise", "sunset", or either with a minute offset: "sunset-30", "sunrise+15".
    static func parseTimePoint(_ text: String) -> Schedule? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let m = parseClock(t) { return Schedule(anchor: .clock(minutes: m)) }
        for (name, anchor) in [("sunrise", Schedule.Anchor.sunrise), ("sunset", .sunset)] where t.hasPrefix(name) {
            let rest = t.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return Schedule(anchor: anchor) }
            if rest.hasPrefix("+") || rest.hasPrefix("-"), let n = Int(rest.replacingOccurrences(of: " ", with: "")), abs(n) <= 720 {
                return Schedule(anchor: anchor, offsetMinutes: n)
            }
        }
        return nil
    }

    static func parseClock(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
}

// MARK: - Reader

/// Typed access to a YAML map with helpful error paths and typo detection.
struct Reader {
    let map: [String: YAMLValue]
    let path: String

    private func at(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

    func reader(_ key: String) throws -> Reader? {
        guard let v = map[key] else { return nil }
        if case .null = v { return nil }
        guard case .map(let m) = v else { throw ConfigError(path: at(key), message: "must be a map") }
        return Reader(map: m, path: at(key))
    }

    func string(_ key: String) throws -> String? {
        guard let v = map[key] else { return nil }
        if case .null = v { return nil }
        guard let s = v.stringValue else { throw ConfigError(path: at(key), message: "must be text") }
        return s
    }

    func requireString(_ key: String) throws -> String {
        guard let s = try string(key) else { throw ConfigError(path: at(key), message: "is required") }
        return s
    }

    func int(_ key: String) throws -> Int? {
        guard let v = map[key] else { return nil }
        guard let i = v.intValue else { throw ConfigError(path: at(key), message: "must be a whole number") }
        return i
    }

    func double(_ key: String) throws -> Double? {
        guard let v = map[key] else { return nil }
        guard let d = v.doubleValue else { throw ConfigError(path: at(key), message: "must be a number") }
        return d
    }

    func bool(_ key: String) throws -> Bool? {
        guard let v = map[key] else { return nil }
        guard let b = v.boolValue else { throw ConfigError(path: at(key), message: "must be true or false") }
        return b
    }

    /// Accepts a single string or a list of strings.
    func stringList(_ key: String) throws -> [String] {
        guard let v = map[key] else { return [] }
        if let s = v.stringValue { return [s] }
        guard case .array(let items) = v else { throw ConfigError(path: at(key), message: "must be text or a list of text") }
        return try items.map {
            guard let s = $0.stringValue else { throw ConfigError(path: at(key), message: "list items must be text") }
            return s
        }
    }

    func rejectUnknown(_ known: Set<String>) throws {
        for key in map.keys.sorted() where !known.contains(key) {
            let hint = known.min(by: { editDistance($0, key) < editDistance($1, key) })
                .flatMap { editDistance($0, key) <= 3 ? " (did you mean '\($0)'?)" : nil } ?? ""
            throw ConfigError(path: path, message: "unknown key '\(key)'\(hint)")
        }
    }
}

private func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    for i in 1...a.count {
        var current = [i] + Array(repeating: 0, count: b.count)
        for j in 1...b.count {
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        previous = current
    }
    return previous[b.count]
}

// MARK: - Color

enum ColorMath {
    /// sRGB hex → CIE xy using the standard Hue conversion (no gamut clamping).
    static func xy(fromHex hex: String) -> (x: Double, y: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        func linear(_ c: Double) -> Double { c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92 }
        let r = linear(Double((value >> 16) & 0xFF) / 255)
        let g = linear(Double((value >> 8) & 0xFF) / 255)
        let b = linear(Double(value & 0xFF) / 255)
        let X = r * 0.664511 + g * 0.154324 + b * 0.162028
        let Y = r * 0.283881 + g * 0.668433 + b * 0.047685
        let Z = r * 0.000088 + g * 0.072310 + b * 0.986039
        let sum = X + Y + Z
        guard sum > 0 else { return (0.3127, 0.3290) }
        return (X / sum, Y / sum)
    }
}

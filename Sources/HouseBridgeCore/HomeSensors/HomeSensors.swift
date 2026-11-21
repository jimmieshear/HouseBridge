import Foundation

// MARK: - Readings

/// One value reported by the HouseBridgeHomeKit helper for one HomeKit accessory.
///
/// `kind` is smoke | co | temperature | humidity | air_quality | pm25 | voc | co2. Smoke and co are 0/1 (1 = detected),
/// temperature is °C, humidity is %, air_quality is HomeKit's 0 (unknown) … 5 (poor), the others are µg/m³ / ppb / ppm.
public struct SensorReading: Sendable, Equatable, Identifiable {
    public var accessory: String   // the helper's stable id for the accessory (HomeKit uuid)
    public var home: String
    public var name: String
    public var room: String
    public var kind: String
    public var value: Double
    public var reachable: Bool
    public var date: Date

    public var id: String { "\(accessory)|\(kind)" }

    public init(accessory: String, home: String, name: String, room: String, kind: String, value: Double,
                reachable: Bool = true, date: Date = Date()) {
        self.accessory = accessory; self.home = home; self.name = name; self.room = room
        self.kind = kind; self.value = value; self.reachable = reachable; self.date = date
    }

    /// Read straight from UniFi Protect (accessory id `unifi:<id>`) rather than through the HomeKit helper.
    public var isProtect: Bool { accessory.hasPrefix("unifi:") }

    /// Smoke and CO are alarms; the rest are measurements.
    public var isAlarm: Bool { SensorReading.alarmKinds.contains(kind) }
    public var isAlarming: Bool { isAlarm && value >= 1 }
    static let alarmKinds: Set<String> = ["smoke", "co"]
}

/// How a room temperature is shown in the window: red when hot, blue when cold, green in between.
public enum TemperatureBand: Sendable, Equatable {
    case cold, comfortable, hot

    public static let coldBelowFahrenheit = 68.0
    public static let hotAboveFahrenheit = 80.0

    public init(fahrenheit: Double) {
        self = fahrenheit > TemperatureBand.hotAboveFahrenheit ? .hot : fahrenheit < TemperatureBand.coldBelowFahrenheit ? .cold : .comfortable
    }
    public init(celsius: Double) { self.init(fahrenheit: celsius * 9 / 5 + 32) }
}

/// What `SensorStore.ingest` made of one line from the helper.
public struct SensorIngest: Sendable {
    public var events: [TriggerEvent] = []
    /// True when the set of readings changed (new, different value or reachability), so the window should refresh.
    public var changed = false
    public var hello = false
}

// MARK: - Store

/// Latest reading per accessory and kind, and the alarm events that follow from changes. Pure (no sockets), so the
/// tests feed it lines directly. Thread-safe.
public final class SensorStore: @unchecked Sendable {
    private let config: HomeSensorsConfig
    private let lock = NSLock()
    private var latest: [String: SensorReading] = [:]
    /// The alarm state last seen per `SensorReading.id`; an event is only made when it changes.
    private var alarming: [String: Bool] = [:]

    public init(config: HomeSensorsConfig) { self.config = config }

    public var readings: [SensorReading] {
        lock.withLock { latest.values.sorted { ($0.name.lowercased(), $0.kind) < ($1.name.lowercased(), $1.kind) } }
    }

    /// Parses one JSON line (see `Tools/HouseBridgeHomeKit`) from the HomeKit helper and updates the store.
    public func ingest(line: String, now: Date = Date()) -> SensorIngest {
        var result = SensorIngest()
        guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["t"] as? String else { return result }
        if type == "hello" { result.hello = true; return result }
        guard type == "reading",
              let accessory = obj["id"] as? String, let name = obj["name"] as? String,
              let kind = obj["kind"] as? String, let value = (obj["value"] as? NSNumber)?.doubleValue,
              config.includes(name) else { return result }
        let ts = (obj["ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? now
        return apply(SensorReading(accessory: accessory, home: obj["home"] as? String ?? "", name: name,
                                   room: obj["room"] as? String ?? "", kind: kind, value: value,
                                   reachable: obj["reachable"] as? Bool ?? true, date: ts))
    }

    /// A reading taken straight from UniFi Protect (temperature °C, humidity %, ...), kept only for the names listed
    /// under `home_sensors: unifi:`.
    public func ingest(protect reading: SensorReading) -> SensorIngest {
        guard config.includesUnifi(reading.name) else { return SensorIngest() }
        return apply(reading)
    }

    private func apply(_ reading: SensorReading) -> SensorIngest {
        var result = SensorIngest()
        lock.withLock {
            let previous = latest[reading.id]
            latest[reading.id] = reading
            // A new value, or a re-read of the same one a while later, so the window's "updated" time keeps moving.
            result.changed = previous == nil || previous?.value != reading.value || previous?.reachable != reading.reachable
                || reading.date.timeIntervalSince(previous?.date ?? .distantPast) > 60
            guard reading.isAlarm else { return }
            // An unreachable alarm keeps its last state (a sensor that drops off Wi-Fi has not stopped smelling smoke).
            guard reading.reachable else { return }
            let was = alarming[reading.id] ?? false
            let isOn = reading.isAlarming
            alarming[reading.id] = isOn
            guard isOn != was else { return }
            let input = reading.kind
            result.events.append(TriggerEvent(source: .homekit, device: reading.name, input: input,
                                              inputAliases: input == "co" ? ["carbon_monoxide"] : [],
                                              kind: isOn ? "detected" : "clear",
                                              detail: [reading.room, reading.home].filter { !$0.isEmpty }.joined(separator: ", "),
                                              deviceID: reading.accessory))
        }
        return result
    }
}

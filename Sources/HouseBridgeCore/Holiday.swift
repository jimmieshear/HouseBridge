import Foundation

// MARK: - Model

/// One step of a holiday theme, run against every color-capable Hue light.
public enum HolidayStep: Sendable {
    /// Turn the lights on, each in the next palette color (lights sorted by name, so the same light gets the same color every night).
    case start(colors: [String], brightness: Double?)
    /// Back to normal: reset to white at `kelvin`, and switch off unless someone is home.
    case end(kelvin: Int, turnOff: Bool)
}

/// A holiday theme: on the days from `from` to `to`, during `between`, color-capable lights wear the holiday colors.
/// Skipped while any presence hold is active.
public struct Holiday: Sendable {
    public struct MonthDay: Sendable, Equatable {
        public var month: Int, day: Int
        var ordinal: Int { month * 100 + day }
    }
    public var name: String
    public var enabled = true
    public var from: MonthDay
    public var to: MonthDay
    public var colors: [String]
    public var brightness: Double?
    public var between: TimeWindow
    public var normalKelvin: Int

    /// Windows run on whole calendar days; a range such as Dec 28 – Jan 2 wraps the year.
    func covers(_ day: Date, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.month, .day], from: day)
        let md = (c.month ?? 0) * 100 + (c.day ?? 0)
        return from.ordinal <= to.ordinal ? (from.ordinal...to.ordinal).contains(md) : (md >= from.ordinal || md <= to.ordinal)
    }

    /// The evening window that starts on `day`, if that day is part of the holiday.
    func window(startingOn day: Date, location: GeoLocation?, calendar: Calendar) -> (start: Date, end: Date)? {
        guard covers(day, calendar: calendar),
              let s = between.start.fireDate(onDayOf: day, location: location, calendar: calendar),
              var e = between.end.fireDate(onDayOf: day, location: location, calendar: calendar) else { return nil }
        if e <= s { guard let next = calendar.date(byAdding: .day, value: 1, to: e) else { return nil }; e = next }
        return (s, e)
    }

    /// Windows that are active or still ahead at `date`, soonest first.
    public func upcoming(after date: Date, location: GeoLocation?, calendar: Calendar = .current, days: Int = 400) -> [(start: Date, end: Date)] {
        let today = calendar.startOfDay(for: date)
        var out: [(Date, Date)] = []
        for offset in -1..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let w = window(startingOn: day, location: location, calendar: calendar), w.end > date else { continue }
            out.append(w)
        }
        return out
    }
}

// MARK: - Parsing

extension ConfigLoader {
    static func parseMonthDay(_ text: String?) -> Holiday.MonthDay? {
        guard let parts = text?.split(separator: "-"), parts.count == 2, let m = Int(parts[0]), let d = Int(parts[1]),
              (1...12).contains(m) else { return nil }
        let days = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...days[m - 1]).contains(d) ? .init(month: m, day: d) : nil
    }

    static func parseHoliday(_ r: Reader) throws -> Holiday {
        try r.rejectUnknown(["name", "enabled", "from", "to", "colors", "brightness", "between", "normal_color_temp_kelvin"])
        let name = try r.requireString("name")
        guard let from = parseMonthDay(try r.string("from")) else {
            throw ConfigError(path: r.path + ".from", message: "is required, as month-day: \"07-03\"")
        }
        let to = parseMonthDay(try r.string("to")) ?? from
        let colors = try r.stringList("colors")
        guard !colors.isEmpty else { throw ConfigError(path: r.path + ".colors", message: "needs at least one color, e.g. [\"#FF0000\", \"#FFFFFF\", \"#0000FF\"]") }
        for hex in colors where ColorMath.xy(fromHex: hex) == nil {
            throw ConfigError(path: r.path + ".colors", message: "'\(hex)' is not a hex color like \"#FFAA00\"")
        }
        let brightness = try r.double("brightness") ?? 80
        guard (1...100).contains(brightness) else { throw ConfigError(path: r.path + ".brightness", message: "must be 1–100") }
        let kelvin = try r.int("normal_color_temp_kelvin") ?? 2700
        guard (2000...6500).contains(kelvin) else { throw ConfigError(path: r.path + ".normal_color_temp_kelvin", message: "must be 2000–6500") }

        var window = TimeWindow(start: Schedule(anchor: .sunset, offsetMinutes: -30), end: Schedule(anchor: .clock(minutes: 23 * 60)))
        if let b = r.map["between"] {
            guard case .array(let parts) = b, parts.count == 2,
                  let s = parts[0].stringValue.flatMap(parseTimePoint), let e = parts[1].stringValue.flatMap(parseTimePoint) else {
                throw ConfigError(path: r.path + ".between", message: "expected two times such as [sunset-30, \"23:00\"]")
            }
            window = TimeWindow(start: s, end: e)
        }
        return Holiday(name: name, enabled: try r.bool("enabled") ?? true, from: from, to: to, colors: colors,
                       brightness: brightness, between: window, normalKelvin: kelvin)
    }
}

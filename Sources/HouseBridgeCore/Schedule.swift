import Foundation

// MARK: - Location and sun

public struct GeoLocation: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double   // degrees east of Greenwich
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
}

/// Sunrise and sunset from the NOAA solar-position equations (accurate to about a minute away from the poles).
public enum Sun {
    public enum Event: String, Sendable { case sunrise, sunset }

    /// The moment of `event` on the calendar day `year-month-day` at `location`, or nil when the sun does not
    /// rise or set that day (polar day/night). The day is the *local* date, so callers pass components taken
    /// in their own time zone.
    public static func time(_ event: Event, year: Int, month: Int, day: Int, at location: GeoLocation) -> Date? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let midnight = utc.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let jd0 = midnight.timeIntervalSince1970 / 86400 + 2440587.5   // Julian day at 0h UT
        // Two passes: solar position at the guessed event time, then again at the result.
        var minutes = 720 - 4 * location.longitude
        for _ in 0..<2 {
            guard let m = eventMinutes(event, julianDay: jd0 + minutes / 1440, location: location) else { return nil }
            minutes = m
        }
        return midnight.addingTimeInterval(minutes * 60)
    }

    private static func eventMinutes(_ event: Event, julianDay jd: Double, location: GeoLocation) -> Double? {
        func rad(_ d: Double) -> Double { d * .pi / 180 }
        func deg(_ r: Double) -> Double { r * 180 / .pi }
        let t = (jd - 2451545) / 36525
        let l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(rad(m)) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(rad(2 * m)) * (0.019993 - 0.000101 * t) + sin(rad(3 * m)) * 0.000289
        let omega = 125.04 - 1934.136 * t
        let lambda = l0 + c - 0.00569 - 0.00478 * sin(rad(omega))
        let eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let eps = eps0 + 0.00256 * cos(rad(omega))
        let declination = asin(sin(rad(eps)) * sin(rad(lambda)))
        let y = pow(tan(rad(eps) / 2), 2)
        let equationOfTime = 4 * deg(y * sin(2 * rad(l0)) - 2 * e * sin(rad(m))
                                     + 4 * e * y * sin(rad(m)) * cos(2 * rad(l0))
                                     - 0.5 * y * y * sin(4 * rad(l0)) - 1.25 * e * e * sin(2 * rad(m)))
        let lat = rad(location.latitude)
        let cosHA = cos(rad(90.833)) / (cos(lat) * cos(declination)) - tan(lat) * tan(declination)
        guard (-1...1).contains(cosHA) else { return nil }
        let hourAngle = deg(acos(cosHA))
        let sign: Double = event == .sunrise ? 1 : -1
        return 720 - 4 * (location.longitude + sign * hourAngle) - equationOfTime
    }
}

// MARK: - Schedule

/// A time of day (fixed, or relative to sunrise/sunset) on some or all days of the week.
public struct Schedule: Sendable, Equatable {
    public enum Anchor: Sendable, Equatable {
        case clock(minutes: Int)   // minutes after local midnight
        case sunrise
        case sunset
    }

    public var anchor: Anchor
    public var offsetMinutes: Int = 0
    /// `Calendar` weekday numbers (1 = Sunday … 7 = Saturday); empty means every day.
    public var days: Set<Int> = []

    public init(anchor: Anchor, offsetMinutes: Int = 0, days: Set<Int> = []) {
        self.anchor = anchor
        self.offsetMinutes = offsetMinutes
        self.days = days
    }

    public var usesSun: Bool { if case .clock = anchor { false } else { true } }

    static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// Stable identity; the scheduler's events carry it as their `input` so rules can match them.
    public var key: String {
        var s: String
        switch anchor {
        case .clock(let m): s = String(format: "%02d:%02d", m / 60, m % 60)
        case .sunrise: s = "sunrise"
        case .sunset: s = "sunset"
        }
        if offsetMinutes != 0 { s += String(format: "%+d", offsetMinutes) }
        if !days.isEmpty { s += "|" + days.sorted().map { Schedule.dayNames[$0 - 1] }.joined(separator: ",") }
        return s
    }

    /// The fire time on the local calendar day containing `day`, ignoring the weekday filter.
    func fireDate(onDayOf day: Date, location: GeoLocation?, calendar: Calendar) -> Date? {
        let base: Date?
        switch anchor {
        case .clock(let m):
            base = calendar.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day, matchingPolicy: .nextTime)
        case .sunrise, .sunset:
            guard let location else { return nil }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = c.year, let mo = c.month, let d = c.day else { return nil }
            base = Sun.time(anchor == .sunrise ? .sunrise : .sunset, year: y, month: mo, day: d, at: location)
        }
        return base?.addingTimeInterval(Double(offsetMinutes) * 60)
    }

    /// The first fire time strictly after `date`, looking at most a week ahead (nil if the sun never rises/sets then).
    public func next(after date: Date, location: GeoLocation?, calendar: Calendar = .current) -> Date? {
        let start = calendar.startOfDay(for: date)
        var best: Date?
        for offset in -1...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            if !days.isEmpty, !days.contains(calendar.component(.weekday, from: day)) { continue }
            if let d = fireDate(onDayOf: day, location: location, calendar: calendar), d > date, best.map({ d < $0 }) ?? true {
                best = d
            }
        }
        return best
    }

    /// The most recent fire time at or before `date` (looking back at most 8 days), honouring the weekday filter.
    public func previous(onOrBefore date: Date, location: GeoLocation?, calendar: Calendar = .current) -> Date? {
        let start = calendar.startOfDay(for: date)
        var best: Date?
        for offset in -8...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            if !days.isEmpty, !days.contains(calendar.component(.weekday, from: day)) { continue }
            if let d = fireDate(onDayOf: day, location: location, calendar: calendar), d <= date, best.map({ d > $0 }) ?? true {
                best = d
            }
        }
        return best
    }

    public var summary: String {
        var s: String
        switch anchor {
        case .clock(let m): s = String(format: "at %02d:%02d", m / 60, m % 60)
        case .sunrise: s = "sunrise"
        case .sunset: s = "sunset"
        }
        if offsetMinutes != 0 { s += offsetMinutes < 0 ? " − \(-offsetMinutes) min" : " + \(offsetMinutes) min" }
        if !days.isEmpty { s += " on " + days.sorted().map { Schedule.dayNames[$0 - 1] }.joined(separator: ", ") }
        return s
    }
}

// MARK: - Scheduler

/// Emits a `clock` TriggerEvent when each schedule's time passes.
///
/// It polls the wall clock rather than sleeping until the target, so it stays right across Mac sleep, DST changes
/// and clock adjustments. A time that passed while the Mac slept is skipped if it is more than `grace` old, so
/// waking at midnight does not turn the sunset lights on.
public final class ClockScheduler: @unchecked Sendable {
    private let schedules: [Schedule]
    private let location: GeoLocation?
    private let calendar: Calendar
    private let grace: TimeInterval
    private let tick: Duration
    private let emit: @Sendable (TriggerEvent) -> Void
    private let log: @Sendable (LogEntry) -> Void

    public init(schedules: [Schedule], location: GeoLocation?, calendar: Calendar = .current,
                grace: TimeInterval = 300, tick: Duration = .seconds(10),
                emit: @escaping @Sendable (TriggerEvent) -> Void, log: @escaping @Sendable (LogEntry) -> Void) {
        var seen = Set<String>()
        self.schedules = schedules.filter { seen.insert($0.key).inserted }
        self.location = location
        self.calendar = calendar
        self.grace = grace
        self.tick = tick
        self.emit = emit
        self.log = log
    }

    public func run() async {
        guard !schedules.isEmpty else { return }
        log(LogEntry(category: "clock", message: "schedules: " + schedules.map { "\($0.summary) → \(describeNext($0))" }.joined(separator: "; ")))
        var last = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: tick)
            let now = Date()
            poll(from: last, to: now)
            last = now
        }
    }

    /// Fires every schedule whose next time after `from` is at or before `now`. Visible for tests.
    func poll(from: Date, to now: Date) {
        for s in schedules {
            guard let due = s.next(after: from, location: location, calendar: calendar), due <= now else { continue }
            if now.timeIntervalSince(due) > grace {
                log(LogEntry(level: .warning, category: "clock", message: "missed \(s.summary) (due \(Self.format(due))); skipped"))
                continue
            }
            emit(TriggerEvent(source: .clock, device: "clock", input: s.key, kind: "fire", detail: s.summary))
        }
    }

    func describeNext(_ s: Schedule) -> String {
        s.next(after: Date(), location: location, calendar: calendar).map(Self.format) ?? "never"
    }

    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE HH:mm"
        return f.string(from: date)
    }
}

import XCTest
@testable import HouseBridgeCore

final class ScheduleTests: XCTestCase {
    private func minutesDiff(_ a: Date, _ iso: String) -> Double {
        abs(a.timeIntervalSince(ISO8601DateFormatter().date(from: iso)!)) / 60
    }

    func testSunTimesMatchPublishedValues() {
        // London, summer solstice: sunrise 04:43 BST, sunset 21:21 BST (UTC+1).
        let london = GeoLocation(latitude: 51.5074, longitude: -0.1278)
        XCTAssertLessThan(minutesDiff(Sun.time(.sunrise, year: 2026, month: 6, day: 21, at: london)!, "2026-06-21T03:43:00Z"), 3)
        XCTAssertLessThan(minutesDiff(Sun.time(.sunset, year: 2026, month: 6, day: 21, at: london)!, "2026-06-21T20:21:00Z"), 3)
        // The rest are checked against an independent altitude-bisection calculation (Meeus low-precision solar
        // coordinates). San Francisco, 25 Oct: sunrise 07:29 PDT, sunset 18:19 PDT; sunset falls on the next UTC day.
        let sf = GeoLocation(latitude: 37.7749, longitude: -122.4194)
        XCTAssertLessThan(minutesDiff(Sun.time(.sunrise, year: 2026, month: 10, day: 25, at: sf)!, "2026-10-25T14:29:00Z"), 2)
        XCTAssertLessThan(minutesDiff(Sun.time(.sunset, year: 2026, month: 10, day: 25, at: sf)!, "2026-10-26T01:19:00Z"), 2)
        // Sydney (east of UTC): sunrise 06 Dec 05:37 AEDT = 18:37Z the day before.
        let sydney = GeoLocation(latitude: -33.8688, longitude: 151.2093)
        XCTAssertLessThan(minutesDiff(Sun.time(.sunrise, year: 2026, month: 12, day: 6, at: sydney)!, "2026-12-05T18:37:00Z"), 2)
    }

    func testPolarNightHasNoSunrise() {
        XCTAssertNil(Sun.time(.sunrise, year: 2026, month: 12, day: 21, at: GeoLocation(latitude: 78.2, longitude: 15.6)))
    }

    private var pacific: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!; return c
    }
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testClockNextFireAndDays() {
        let cal = pacific
        // 2026-10-25 is a Sunday. 18:30 PDT = 01:30Z next day.
        let daily = Schedule(anchor: .clock(minutes: 18 * 60 + 30))
        XCTAssertEqual(daily.next(after: date("2026-10-25T20:00:00Z"), location: nil, calendar: cal), date("2026-10-26T01:30:00Z"))
        // Mondays only: from Sunday evening the next is Monday 18:30 PDT.
        let monday = Schedule(anchor: .clock(minutes: 18 * 60 + 30), days: [2])
        XCTAssertEqual(monday.next(after: date("2026-10-25T20:00:00Z"), location: nil, calendar: cal), date("2026-10-27T01:30:00Z"))
    }

    func testClockAcrossDaylightSavingEnd() {
        // DST ends Sun 2026-11-01 at 02:00 PDT. 18:00 local is UTC-7 on Oct 31 and UTC-8 on Nov 1.
        let s = Schedule(anchor: .clock(minutes: 18 * 60))
        XCTAssertEqual(s.next(after: date("2026-10-31T20:00:00Z"), location: nil, calendar: pacific), date("2026-11-01T01:00:00Z"))
        XCTAssertEqual(s.next(after: date("2026-11-01T02:00:00Z"), location: nil, calendar: pacific), date("2026-11-02T02:00:00Z"))
    }

    func testSunsetOffsetAndMissingLocation() {
        let sf = GeoLocation(latitude: 37.7749, longitude: -122.4194)
        let plain = Schedule(anchor: .sunset).next(after: date("2026-10-25T20:00:00Z"), location: sf, calendar: pacific)!
        let early = Schedule(anchor: .sunset, offsetMinutes: -30).next(after: date("2026-10-25T20:00:00Z"), location: sf, calendar: pacific)!
        XCTAssertEqual(plain.timeIntervalSince(early), 1800, accuracy: 1)
        XCTAssertNil(Schedule(anchor: .sunset).next(after: Date(), location: nil))
    }

    func testSchedulerFiresOnceAndSkipsStaleTimes() {
        let cal = pacific
        let events = Locked<[TriggerEvent]>([]), logs = Locked<[LogEntry]>([])
        let s = Schedule(anchor: .clock(minutes: 18 * 60 + 30))
        let sched = ClockScheduler(schedules: [s, s], location: nil, calendar: cal, emit: { e in events.mutate { $0.append(e) } }, log: { l in logs.mutate { $0.append(l) } })
        let due = date("2026-10-26T01:30:00Z")
        sched.poll(from: due.addingTimeInterval(-20), to: due.addingTimeInterval(-10))
        XCTAssertTrue(events.value.isEmpty)
        sched.poll(from: due.addingTimeInterval(-5), to: due.addingTimeInterval(5))
        XCTAssertEqual(events.value.map(\.input), ["18:30"], "duplicate schedules collapse to one")
        XCTAssertEqual(events.value.first?.source, .clock)
        sched.poll(from: due.addingTimeInterval(5), to: due.addingTimeInterval(15))
        XCTAssertEqual(events.value.count, 1)
        // Woke from sleep hours later: skipped and logged.
        sched.poll(from: due.addingTimeInterval(-5), to: due.addingTimeInterval(3 * 3600))
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(logs.value.last?.level, .warning)
    }

    func testBetweenAcceptsSunriseAndWrapsOvernight() throws {
        let sf = GeoLocation(latitude: 37.7749, longitude: -122.4194)
        let cal = pacific
        let w = TimeWindow(start: ConfigLoader.parseTimePoint("23:00")!, end: ConfigLoader.parseTimePoint("sunrise")!)
        // 2026-10-25: sunrise 07:28 PDT. 23:30 PDT = 06:30Z next day; 03:00 PDT = 10:00Z; 07:00 = 14:00Z; 08:00 = 15:00Z; 14:00 = 21:00Z.
        XCTAssertTrue(w.contains(date("2026-10-26T06:30:00Z"), location: sf, calendar: cal))
        XCTAssertTrue(w.contains(date("2026-10-25T10:00:00Z"), location: sf, calendar: cal))
        XCTAssertTrue(w.contains(date("2026-10-25T14:00:00Z"), location: sf, calendar: cal))
        XCTAssertFalse(w.contains(date("2026-10-25T15:00:00Z"), location: sf, calendar: cal))
        XCTAssertFalse(w.contains(date("2026-10-25T21:00:00Z"), location: sf, calendar: cal))
        XCTAssertFalse(w.contains(date("2026-10-25T10:00:00Z"), location: nil, calendar: cal), "no location: sun windows never match")
        XCTAssertEqual(ConfigLoader.parseTimePoint("sunset-30"), Schedule(anchor: .sunset, offsetMinutes: -30))
        XCTAssertNil(ConfigLoader.parseTimePoint("noon"))
        XCTAssertThrowsError(try ConfigLoader.parse("""
        hue: { host: 1.1.1.1 }
        rules:
          - name: x
            when: { at: "23:00" }
            between: ["23:00", sunrise]
            then: [{ action: log, message: hi }]
        """), "sunrise in 'between' needs a location")
    }

    func testConfigParsesClockRules() throws {
        let cfg = try ConfigLoader.parse("""
        location: { latitude: 37.77, longitude: -122.42 }
        hue: { host: 1.1.1.1 }
        rules:
          - name: a
            when: { at: sunset, offset_minutes: -30 }
            then: [{ action: log, message: hi }]
          - name: b
            when: { at: "23:30", days: [fri, sat] }
            then: [{ action: log, message: hi }]
          - name: c
            when: { at: "6:05", days: weekdays }
            then: [{ action: log, message: hi }]
        """)
        XCTAssertEqual(cfg.rules[0].trigger.schedule, Schedule(anchor: .sunset, offsetMinutes: -30))
        XCTAssertEqual(cfg.rules[1].trigger.schedule, Schedule(anchor: .clock(minutes: 23 * 60 + 30), days: [6, 7]))
        XCTAssertEqual(cfg.rules[2].trigger.schedule?.days, [2, 3, 4, 5, 6])
        let fired = TriggerEvent(source: .clock, device: "clock", input: cfg.rules[1].trigger.input!, kind: "fire")
        XCTAssertTrue(cfg.rules[1].trigger.matches(fired))
        XCTAssertFalse(cfg.rules[0].trigger.matches(fired))
    }

    func testConfigRejectsBadClockRules() {
        func parse(_ when: String, location: Bool = true) throws {
            _ = try ConfigLoader.parse((location ? "location: { latitude: 1, longitude: 2 }\n" : "") + "rules:\n  - name: x\n    when: \(when)\n    then: [{ action: log, message: hi }]\n")
        }
        XCTAssertThrowsError(try parse("{ at: sunset }", location: false))
        XCTAssertThrowsError(try parse("{ at: \"25:00\" }"))
        XCTAssertThrowsError(try parse("{ at: \"18:00\", offset_minutes: 5 }"))
        XCTAssertThrowsError(try parse("{ at: sunrise, days: [funday] }"))
        XCTAssertThrowsError(try ConfigLoader.parse("location: { latitude: 91, longitude: 0 }"))
        XCTAssertNoThrow(try parse("{ at: \"18:00\" }", location: false))
    }
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

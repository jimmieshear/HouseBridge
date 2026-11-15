import XCTest
@testable import HouseBridgeCore

final class HolidayTests: XCTestCase {
    private let yaml = """
    hue: { host: 2.2.2.2 }
    unifi: { host: 3.3.3.3, username: u, password: p }
    location: { latitude: 44.0582, longitude: -121.3153 }
    presence:
      - name: Someone is home
        when: [{ unifi: Door, event: motion, state: start }]
        pauses: [{ light: X }]
    holidays:
      - name: Independence Day
        from: "07-03"
        to: "07-04"
        colors: ["#FF0000", "#FFFFFF", "#0000FF"]
      - name: New Year
        from: "12-30"
        to: "01-01"
        colors: ["#FFD700"]
        between: ["18:00", "23:00"]
    """
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone.current; return c }
    private func date(_ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2027, month: m, day: d, hour: h, minute: min))!
    }

    func testParsing() throws {
        let cfg = try ConfigLoader.parse(yaml)
        XCTAssertEqual(cfg.holidays.count, 2)
        XCTAssertEqual(cfg.holidays[0].colors.count, 3); XCTAssertEqual(cfg.holidays[0].brightness, 80)
        XCTAssertEqual(cfg.holidays[0].between.start.offsetMinutes, -30)
        XCTAssertEqual(cfg.holidays[1].from, .init(month: 12, day: 30))
    }

    func testRejectsBadConfig() {
        func parse(_ body: String, hue: Bool = true, location: Bool = true) throws {
            _ = try ConfigLoader.parse((hue ? "hue: { host: 2.2.2.2 }\n" : "") + (location ? "location: { latitude: 44, longitude: -121 }\n" : "") + "holidays:\n" + body)
        }
        let ok = "  - { name: x, from: \"07-04\", colors: [\"#FF0000\"] }"
        XCTAssertNoThrow(try parse(ok))
        XCTAssertThrowsError(try parse(ok, hue: false))
        XCTAssertThrowsError(try parse(ok, location: false), "default window uses sunset")
        XCTAssertThrowsError(try parse("  - { name: x, from: \"13-04\", colors: [\"#FF0000\"] }"))
        XCTAssertThrowsError(try parse("  - { name: x, from: \"02-30\", colors: [\"#FF0000\"] }"))
        XCTAssertThrowsError(try parse("  - { name: x, from: \"07-04\", colors: [] }"))
        XCTAssertThrowsError(try parse("  - { name: x, from: \"07-04\", colors: [red] }"))
        XCTAssertThrowsError(try parse("  - { name: x, from: \"07-04\", colors: [\"#FF0000\"], brightness: 0 }"))
    }

    func testDatesIncludingYearWrap() throws {
        let h = try ConfigLoader.parse(yaml).holidays
        XCTAssertTrue(h[0].covers(date(7, 3), calendar: cal)); XCTAssertTrue(h[0].covers(date(7, 4), calendar: cal))
        XCTAssertFalse(h[0].covers(date(7, 2), calendar: cal)); XCTAssertFalse(h[0].covers(date(7, 5), calendar: cal))
        for (m, d) in [(12, 30), (12, 31), (1, 1)] { XCTAssertTrue(h[1].covers(date(m, d), calendar: cal)) }
        XCTAssertFalse(h[1].covers(date(1, 2), calendar: cal)); XCTAssertFalse(h[1].covers(date(12, 29), calendar: cal))
    }

    func testWindowIsSunsetMinus30To11pm() throws {
        let cfg = try ConfigLoader.parse(yaml)
        let w = cfg.holidays[0].window(startingOn: date(7, 4), location: cfg.location, calendar: cal)!
        let sunset = Sun.time(.sunset, year: 2027, month: 7, day: 4, at: cfg.location!)!
        XCTAssertEqual(w.start.timeIntervalSince(sunset), -1800, accuracy: 1)
        XCTAssertEqual(cal.dateComponents([.hour, .minute], from: w.end).hour, 23)
    }

    func testStepsAreDueOnceAtTheRightTimes() async throws {
        let cfg = try ConfigLoader.parse(yaml)
        let engine = RuleEngine(config: cfg, executor: RecordingExecutor(), now: { Date() }, log: { _ in })
        let w = cfg.holidays[0].window(startingOn: date(7, 4), location: cfg.location, calendar: cal)!

        let before = await engine.dueHolidaySteps(at: w.start.addingTimeInterval(-60), done: [])
        XCTAssertTrue(before.isEmpty)
        let during = await engine.dueHolidaySteps(at: w.start.addingTimeInterval(60), done: [])
        XCTAssertEqual(during.count, 1)
        if case .start(let colors, _) = during[0].step { XCTAssertEqual(colors.count, 3) } else { XCTFail() }
        let again = await engine.dueHolidaySteps(at: w.start.addingTimeInterval(120), done: [during[0].key])
        XCTAssertTrue(again.isEmpty, "not repeated")
        let end = await engine.dueHolidaySteps(at: w.end.addingTimeInterval(30), done: [during[0].key])
        guard case .end(let kelvin, let off)? = end.first?.step else { return XCTFail("no end step") }
        XCTAssertEqual(kelvin, 2700); XCTAssertTrue(off)
        let late = await engine.dueHolidaySteps(at: w.end.addingTimeInterval(2 * 3600), done: [])
        XCTAssertTrue(late.isEmpty, "too late to catch up")
    }

    func testStartWaitsWhileSomeoneIsHomeAndEndDoesNotSwitchOff() async throws {
        let cfg = try ConfigLoader.parse(yaml)
        let exec = RecordingExecutor()
        let w = cfg.holidays[0].window(startingOn: date(7, 4), location: cfg.location, calendar: cal)!
        let engine = RuleEngine(config: cfg, executor: exec, now: { w.end.addingTimeInterval(30) }, log: { _ in })
        await engine.start()
        await engine.handle(TriggerEvent(source: .unifi, device: "Door", input: "motion", kind: "start"))
        let end = await engine.dueHolidaySteps(at: w.end.addingTimeInterval(30), done: [])
        guard case .end(_, let off)? = end.first?.step else { return XCTFail("no end step") }
        XCTAssertFalse(off, "someone is home: only the color is reset")
        await engine.stop()
    }
}

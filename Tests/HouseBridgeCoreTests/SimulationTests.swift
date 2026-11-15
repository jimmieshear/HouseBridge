import XCTest
@testable import HouseBridgeCore

final class SimulationTests: XCTestCase {
    private let yaml = """
    hue: { host: 2.2.2.2 }
    unifi: { host: 3.3.3.3, username: u, password: p }
    presence:
      - name: Someone is home
        hold_hours: 24
        when: [{ unifi: Front Door Motion, event: motion, state: start }]
        pauses: [{ room: Bedroom 1 }, { room: Bedroom 2 }]
    simulate:
      - name: Kids rooms
        between: ["19:00", "23:30"]
        nights: { weekday: 30, weekend: 80 }
        sessions: [1, 3]
        minutes: [20, 60]
        lights:
          - { room: Bedroom 1, brightness: 40 }
          - { room: Bedroom 2 }
    """
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: cal.date(from: DateComponents(year: 2026, month: 3, day: 2))!)! }   // Monday

    func testParsing() throws {
        let sim = try ConfigLoader.parse(yaml).simulations[0]
        XCTAssertEqual(sim.weekdayChance, 0.3); XCTAssertEqual(sim.weekendChance, 0.8)
        XCTAssertEqual(sim.weekendDays, [6, 7, 1])
        XCTAssertEqual(sim.sessions, 1...3); XCTAssertEqual(sim.minutes, 20...60)
        XCTAssertEqual(sim.choices.count, 2); XCTAssertEqual(sim.choices[0].state.brightness, 40)
    }

    func testRejectsBadConfig() {
        func parse(_ body: String, hue: Bool = true) throws {
            _ = try ConfigLoader.parse((hue ? "hue: { host: 2.2.2.2 }\n" : "") + "simulate:\n" + body)
        }
        let ok = "  - { name: x, between: [\"19:00\", \"23:00\"], lights: [{ room: A }] }"
        XCTAssertNoThrow(try parse(ok))
        XCTAssertThrowsError(try parse(ok, hue: false), "needs hue")
        XCTAssertThrowsError(try parse("  - { name: x, lights: [{ room: A }] }"), "needs between")
        XCTAssertThrowsError(try parse("  - { name: x, between: [sunset, \"23:00\"], lights: [{ room: A }] }"), "sun needs location")
        XCTAssertThrowsError(try parse("  - { name: x, between: [\"19:00\", \"23:00\"], lights: [] }"))
        XCTAssertThrowsError(try parse("  - { name: x, between: [\"19:00\", \"23:00\"], lights: [{ room: A, off_after_seconds: 5 }] }"))
        XCTAssertThrowsError(try parse("  - { name: x, between: [\"19:00\", \"23:00\"], nights: { weekend: 150 }, lights: [{ room: A }] }"))
        XCTAssertThrowsError(try parse("  - { name: x, between: [\"19:00\", \"23:00\"], minutes: [60, 20], lights: [{ room: A }] }"))
    }

    func testPlanIsDeterministicAndInsideWindow() throws {
        let sim = try ConfigLoader.parse(yaml).simulations[0]
        var active = 0
        for offset in 0..<200 {
            let a = sim.plan(nightStarting: day(offset), location: nil, calendar: cal)
            XCTAssertEqual(a, sim.plan(nightStarting: day(offset), location: nil, calendar: cal))
            guard !a.isEmpty else { continue }
            active += 1
            let (start, end) = sim.window(startingOn: day(offset), location: nil, calendar: cal)!
            XCTAssertTrue((1...3).contains(a.count))
            for s in a {
                XCTAssertGreaterThanOrEqual(s.start, start); XCTAssertLessThanOrEqual(s.end, end)
                XCTAssertTrue((20 * 60...60 * 60).contains(s.seconds))
            }
        }
        XCTAssertTrue((40...110).contains(active), "~ (4×30% + 3×80%)/7 ≈ 51% of 200 nights, got \(active)")
    }

    func testWeekendNightsAreBusier() throws {
        let sim = try ConfigLoader.parse(yaml).simulations[0]
        var weekend = 0, weekday = 0
        for offset in 0..<700 where !sim.plan(nightStarting: day(offset), location: nil, calendar: cal).isEmpty {
            if sim.weekendDays.contains(cal.component(.weekday, from: day(offset))) { weekend += 1 } else { weekday += 1 }
        }
        // 300 weekend nights × 80% = 240; 400 weekday nights × 30% = 120
        XCTAssertGreaterThan(Double(weekend) / 300, Double(weekday) / 400 + 0.3)
    }

    func testWindowWrappingMidnight() throws {
        var sim = try ConfigLoader.parse(yaml).simulations[0]
        sim.between = TimeWindow(startMinutes: 22 * 60, endMinutes: 2 * 60)
        let (s, e) = sim.window(startingOn: day(0), location: nil, calendar: cal)!
        XCTAssertEqual(e.timeIntervalSince(s), 4 * 3600)
    }

    func testSessionTurnsLightsOnWithAutoOffAndIsPausedByPresence() async throws {
        let cfg = try ConfigLoader.parse(yaml)
        let sim = cfg.simulations[0]
        let session = SimulatedSession(start: Date(timeIntervalSince1970: 1_800_000_000), seconds: 1800, choice: 0)
        let fixed = session.start.addingTimeInterval(60)

        let exec = RecordingExecutor()
        let engine = RuleEngine(config: cfg, executor: exec, now: { fixed }, log: { _ in })
        await engine.start()
        await engine.fireSimulated(sim, session)
        try await Task.sleep(for: .milliseconds(50))
        guard case .light(let target, let state)? = exec.actions.first else { return XCTFail("no action") }
        XCTAssertEqual(target.rooms, ["Bedroom 1"]); XCTAssertEqual(state.on, true)
        XCTAssertEqual(state.brightness, 40); XCTAssertEqual(state.offAfterSeconds, 1740, "remaining time, not the full session")

        // Someone is home: the session is skipped.
        await engine.handle(TriggerEvent(source: .unifi, device: "Front Door Motion", input: "motion", kind: "start"))
        await engine.fireSimulated(sim, SimulatedSession(start: session.start, seconds: 1800, choice: 1))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(exec.actions.count, 1)
        await engine.stop()
    }
}

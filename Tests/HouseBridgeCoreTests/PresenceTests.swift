import XCTest
@testable import HouseBridgeCore

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var date: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

private final class Names: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [[String]] = []
    func add(_ n: [String]) { lock.withLock { all.append(n) } }
    var value: [[String]] { lock.withLock { all } }
}

final class PresenceTests: XCTestCase {
    private let yaml = """
    lutron: { host: 1.1.1.1, ca: /x, cert: /x, key: /x }
    hue: { host: 2.2.2.2 }
    unifi: { host: 3.3.3.3, username: u, password: p }
    presence:
      - name: Someone is home
        hold_hours: 24
        when:
          - { unifi: Front Door Motion, event: motion, state: start }
          - { unifi: UP Sense GarageDoor, event: contact, state: open }
        pauses:
          - lutron: Garage Wall Lights
          - light: Porch
    rules:
      - name: garage motion
        when: { unifi: Cam, event: motion, state: start }
        then: [{ action: lutron, switch: garage wall lights, on: true, off_after_seconds: 300 }]
      - name: porch at sunset
        when: { at: "18:00" }
        then: [{ action: light, light: Porch, on: true }]
      - name: porch pico
        when: { pico: P, button: on, gesture: tap }
        then: [{ action: light, light: Porch, on: true }]
      - name: porch always
        ignore_presence: true
        when: { unifi: Cam, event: motion, state: start }
        then: [{ action: light, light: Porch, on: false }]
      - name: kitchen motion
        when: { unifi: Cam, event: motion, state: start }
        then: [{ action: light, light: Kitchen, on: true }]
    """

    private func motion(_ device: String = "Front Door Motion", input: String = "motion", kind: String = "start") -> TriggerEvent {
        TriggerEvent(source: .unifi, device: device, input: input, kind: kind)
    }

    private func lutronCount(_ e: RecordingExecutor) -> Int { e.actions.filter { if case .lutron = $0 { true } else { false } }.count }

    func testParsesHold() throws {
        let h = try ConfigLoader.parse(yaml).presence[0]
        XCTAssertEqual(h.duration, 24 * 3600)
        XCTAssertEqual(h.triggers.count, 2)
        XCTAssertEqual(h.pauses.lutron, ["Garage Wall Lights"])
        XCTAssertEqual(h.pauses.lights, ["Porch"])
    }

    func testRejectsBadHolds() {
        func parse(_ body: String) throws { _ = try ConfigLoader.parse("unifi: { host: 3.3.3.3, username: u, password: p }\npresence:\n\(body)") }
        XCTAssertThrowsError(try parse("  - { name: x, pauses: [{ lutron: A }] }"), "no triggers")
        XCTAssertThrowsError(try parse("  - { name: x, when: [{ unifi: S, event: motion }] }"), "no pauses")
        XCTAssertThrowsError(try parse("  - { name: x, when: [{ at: sunset }], pauses: [{ lutron: A }] }"), "clock trigger")
        XCTAssertThrowsError(try parse("  - { name: x, hold_hours: 0, when: [{ unifi: S }], pauses: [{ lutron: A }] }"))
        XCTAssertThrowsError(try parse("  - { name: x, hold_hours: 1, hold_minutes: 5, when: [{ unifi: S }], pauses: [{ lutron: A }] }"))
        XCTAssertThrowsError(try parse("  - { name: x, when: [{ unifi: S }], pauses: [{ colour: A }] }"))
        XCTAssertNoThrow(try parse("  - { name: x, when: [{ unifi: S }], pauses: [{ lutron: A }] }"))
    }

    func testHoldPausesCoveredAutomationOnlyAndExpires() async throws {
        let clock = Clock(), exec = RecordingExecutor(), cancelled = Names()
        let cfg = try ConfigLoader.parse(yaml)
        let engine = RuleEngine(config: cfg, executor: exec, cancelLutronTimers: { cancelled.add($0) }, now: { clock.date }, log: { _ in })
        await engine.start()

        // Before anyone is home the garage rule works.
        await engine.handle(motion("Cam"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(lutronCount(exec), 1)

        // Someone arrives: pending garage off-timers are cancelled, and covered rules are skipped.
        await engine.handle(motion())
        XCTAssertEqual(cancelled.value, [["Garage Wall Lights"]])
        await engine.handle(motion("Cam"))
        await engine.handle(TriggerEvent(source: .clock, device: "clock", input: "18:00", kind: "fire"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(lutronCount(exec), 1, "garage motion rule is paused")
        let lights = exec.actions.compactMap { a -> String? in if case .light(let t, _) = a { return t.lights.first } else { return nil } }
        XCTAssertEqual(lights, ["Porch", "Kitchen", "Porch", "Kitchen"], "kitchen is not covered and the ignore_presence rule still runs; the paused Porch clock rule did not")

        // A person pressing a Pico always works, even for a covered light.
        await engine.handle(TriggerEvent(source: .pico, device: "P", input: "on", kind: "tap"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(exec.actions.compactMap { a -> String? in if case .light(let t, _) = a { return t.lights.first } else { return nil } }.last, "Porch")

        // Another trigger 23h later renews it: still paused 2h after that (25h in total), and not re-announced.
        clock.advance(23 * 3600)
        await engine.handle(TriggerEvent(source: .unifi, device: "UP Sense GarageDoor", input: "contact", kind: "open"))
        clock.advance(2 * 3600)
        await engine.handle(motion("Cam"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(lutronCount(exec), 1)
        XCTAssertEqual(cancelled.value.count, 1)

        // 22h more is past the renewed 24h: automation resumes.
        clock.advance(22 * 3600)
        await engine.handle(motion("Cam"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(lutronCount(exec), 2)
        await engine.stop()
    }

    func testHoldSurvivesRestartAndExpiredOnesAreDropped() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("holds-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = Clock(), cfg = try ConfigLoader.parse(yaml)
        let first = RuleEngine(config: cfg, executor: RecordingExecutor(), holdStore: HoldStore(url: url), now: { clock.date }, log: { _ in })
        await first.start()
        await first.handle(motion())
        await first.stop()

        // A reload creates a new engine; the hold must still apply.
        clock.advance(3600)
        let exec = RecordingExecutor()
        let second = RuleEngine(config: cfg, executor: exec, holdStore: HoldStore(url: url), now: { clock.date }, log: { _ in })
        await second.start()
        await second.handle(motion("Cam"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(lutronCount(exec), 0)
        await second.stop()

        // After it expires, a restart starts clean and rewrites the file.
        clock.advance(24 * 3600)
        let third = RuleEngine(config: cfg, executor: exec, holdStore: HoldStore(url: url), now: { clock.date }, log: { _ in })
        await third.start()
        await third.handle(motion("Cam"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(lutronCount(exec), 1)
        XCTAssertTrue(HoldStore(url: url).load().isEmpty)
        await third.stop()
    }

    // MARK: Restoring state after a hold

    private func hhmm(_ date: Date, plusHours h: Int) -> String {
        let hour = ((Calendar.current.component(.hour, from: date) + h) % 24 + 24) % 24
        return String(format: "%02d:00", hour)
    }

    private func restoreConfig(_ clock: Clock, onAt: Int, offAt: Int) throws -> Config {
        try ConfigLoader.parse("""
        lutron: { host: 1.1.1.1, ca: /x, cert: /x, key: /x }
        hue: { host: 2.2.2.2 }
        presence:
          - name: Someone is home
            hold_hours: 24
            when: [{ switch: Door, state: on }]
            pauses: [{ light: Porch }, { lutron: Porch Switch }]
        rules:
          - name: porch on
            when: { at: "\(hhmm(clock.date, plusHours: onAt))" }
            then: [{ action: light, light: Porch, on: true }]
          - name: porch off
            when: { at: "\(hhmm(clock.date, plusHours: offAt))" }
            then: [{ action: light, light: Porch, on: false }]
          - name: other room on
            when: { at: "\(hhmm(clock.date, plusHours: -1))" }
            then: [{ action: light, light: Kitchen, on: true }]
          - name: switch stays on
            on_resume: true
            when: { switch: Porch Switch, state: off }
            then: [{ action: lutron, switch: Porch Switch, on: true }]
        """)
    }

    private func lightCalls(_ e: RecordingExecutor) -> [String] {
        e.actions.compactMap { a -> String? in
            if case .light(let t, let s) = a { return "\(t.lights[0])=\(s.on == true ? "on" : "off")" }
            if case .lutron(let d, let on, _) = a { return "\(d)=\(on ? "on" : "off")" }
            return nil
        }
    }

    func testHoldEndRestoresLatestScheduledStateOnly() async throws {
        for (onAt, offAt, expected) in [(-3, -1, "Porch=off"), (-3, 2, "Porch=on")] {
            let clock = Clock(), exec = RecordingExecutor()
            let engine = RuleEngine(config: try restoreConfig(clock, onAt: onAt, offAt: offAt), executor: exec, now: { clock.date }, log: { _ in })
            await engine.start()
            await engine.handle(TriggerEvent(source: .lutronSwitch, device: "Door", input: "power", kind: "on"))
            clock.advance(24 * 3600 + 60)
            await engine.resumed("Someone is home")
            try await Task.sleep(for: .milliseconds(80))
            // The most recent scheduled state for Porch, the Kitchen untouched (never held), and the keep-on rule replayed.
            XCTAssertEqual(lightCalls(exec), [expected, "Porch Switch=on"], "on at \(onAt)h, off at \(offAt)h")
            await engine.stop()
        }
    }

    func testRenewedHoldDoesNotRestoreEarlyAndOtherHoldBlocksRestore() async throws {
        let clock = Clock(), exec = RecordingExecutor()
        let engine = RuleEngine(config: try restoreConfig(clock, onAt: -3, offAt: -1), executor: exec, now: { clock.date }, log: { _ in })
        await engine.start()
        await engine.handle(TriggerEvent(source: .lutronSwitch, device: "Door", input: "power", kind: "on"))
        clock.advance(3600)
        await engine.resumed("Someone is home")   // timer fired too early (deadline not reached): nothing happens
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(exec.actions.isEmpty)
        await engine.stop()
    }
}

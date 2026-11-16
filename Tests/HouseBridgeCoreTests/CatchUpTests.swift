import XCTest
@testable import HouseBridgeCore

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var date: Date { lock.withLock { t } }
}

/// Fails the first `failures` plug calls, like an unreachable plug.
private final class FlakyExecutor: ActionExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var failuresLeft: Int
    private var _calls: [String] = []
    init(failures: Int) { failuresLeft = failures }
    var calls: [String] { lock.withLock { _calls } }
    func execute(_ action: Action) async throws {
        try lock.withLock {
            guard case .plug(let d, let on, _) = action else { return }
            _calls.append("\(d)=\(on ? "on" : "off")")
            if failuresLeft > 0 { failuresLeft -= 1; throw KasaError.timeout("test") }
        }
    }
}

final class CatchUpTests: XCTestCase {
    private func hhmm(_ d: Date, plusHours h: Int) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d.addingTimeInterval(Double(h) * 3600))
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    private func config(_ clock: Clock, onAt: Int, offAt: Int, extra: String = "") throws -> Config {
        try ConfigLoader.parse("""
        lutron: { host: 1.1.1.1, ca: /x, cert: /x, key: /x }
        hue: { host: 2.2.2.2 }
        kasa:
          plugs: [{ name: Outdoor, host: 4.4.4.4 }, { name: Timed, host: 4.4.4.5 }]
        \(extra)
        rules:
          - name: plug on
            when: { at: "\(hhmm(clock.date, plusHours: onAt))" }
            then: [{ action: plug, device: Outdoor, on: true }]
          - name: plug off
            when: { at: "\(hhmm(clock.date, plusHours: offAt))" }
            then: [{ action: plug, device: Outdoor, on: false }]
          - name: timed
            when: { at: "\(hhmm(clock.date, plusHours: -1))" }
            then: [{ action: plug, device: Timed, on: true, off_after_seconds: 600 }]
        """)
    }

    func testStartupAppliesLatestDueStateOnly() async throws {
        for (onAt, offAt, expected) in [(-3, -1, "Outdoor=off"), (-3, 2, "Outdoor=on")] {
            let clock = Clock(), exec = FlakyExecutor(failures: 0)
            let engine = RuleEngine(config: try config(clock, onAt: onAt, offAt: offAt), executor: exec, now: { clock.date }, log: { _ in })
            await engine.start()
            await engine.catchUp(reason: "test")
            // The timed rule is never replayed (it would switch on for 10 minutes hours late).
            XCTAssertEqual(exec.calls, [expected])
            await engine.stop()
        }
    }

    func testFailureIsRetriedWithoutReplayingStaleActions() async throws {
        let clock = Clock(), exec = FlakyExecutor(failures: 1)
        let engine = RuleEngine(config: try config(clock, onAt: -3, offAt: -1), executor: exec, now: { clock.date },
                                retryDelays: [0.05, 0.05], log: { _ in })
        await engine.start()
        await engine.catchUp(reason: "test")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(exec.calls, ["Outdoor=off", "Outdoor=off"])   // failed once, then succeeded, then stopped
        await engine.stop()
    }

    func testGivesUpAfterRetriesAndStopStopsRetrying() async throws {
        let clock = Clock(), exec = FlakyExecutor(failures: 100)
        let engine = RuleEngine(config: try config(clock, onAt: -3, offAt: -1), executor: exec, now: { clock.date },
                                retryDelays: [0.05, 0.05], log: { _ in })
        await engine.start()
        await engine.catchUp(reason: "test")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(exec.calls.count, 3)   // initial + two retries
        await engine.stop()
    }

    func testActivePresenceHoldBlocksCatchUp() async throws {
        let clock = Clock(), exec = FlakyExecutor(failures: 0)
        let extra = """
        presence:
          - name: Someone is home
            hold_hours: 24
            when: [{ switch: Door, state: on }]
            pauses: [{ plug: Outdoor }]
        """
        let engine = RuleEngine(config: try config(clock, onAt: -3, offAt: -1, extra: extra), executor: exec, now: { clock.date }, log: { _ in })
        await engine.start()
        await engine.handle(TriggerEvent(source: .lutronSwitch, device: "Door", input: "power", kind: "on"))
        await engine.catchUp(reason: "test")
        XCTAssertTrue(exec.calls.isEmpty)
        await engine.stop()
    }

    func testStartupCatchUpRunsOnStartWhenEnabled() async throws {
        let clock = Clock(), exec = FlakyExecutor(failures: 0)
        let engine = RuleEngine(config: try config(clock, onAt: -3, offAt: -1), executor: exec, now: { clock.date },
                                catchUpOnStart: 0, log: { _ in })
        await engine.start()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(exec.calls, ["Outdoor=off"])
        await engine.stop()
    }
}

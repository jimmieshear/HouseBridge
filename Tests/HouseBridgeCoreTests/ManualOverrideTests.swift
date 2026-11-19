import XCTest
@testable import HouseBridgeCore

private final class Recorder: ActionExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var failuresLeft: Int
    private var _calls: [String] = []
    init(failures: Int = 0) { failuresLeft = failures }
    var calls: [String] { lock.withLock { _calls } }
    func execute(_ action: Action) async throws {
        try lock.withLock {
            guard case .plug(let d, let on, _) = action else { return }
            _calls.append("\(d)=\(on ? "on" : "off")")
            if failuresLeft > 0 { failuresLeft -= 1; throw KasaError.timeout("test") }
        }
    }
}

final class ManualOverrideTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func hhmm(plusHours h: Int) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: fixedNow.addingTimeInterval(Double(h) * 3600))
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    /// "off" was last due an hour ago, so on its own a catch-up would switch Outdoor off.
    private func config() throws -> Config {
        try ConfigLoader.parse("""
        kasa:
          plugs: [{ name: Outdoor, host: 4.4.4.4 }]
        rules:
          - name: plug on
            when: { at: "\(hhmm(plusHours: -3))" }
            then: [{ action: plug, device: Outdoor, on: true }]
          - name: plug off
            when: { at: "\(hhmm(plusHours: -1))" }
            then: [{ action: plug, device: Outdoor, on: false }]
        """)
    }

    private func tempStore() -> HoldStore {
        HoldStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("overrides-\(UUID().uuidString).json"))
    }

    func testRunNowStandsAgainstAnOlderScheduleTime() async throws {
        let exec = Recorder()
        let engine = RuleEngine(config: try config(), executor: exec, overrideStore: tempStore(), now: { self.fixedNow }, log: { _ in })
        await engine.start()
        await engine.runNow("plug on")
        try await Task.sleep(for: .milliseconds(100))
        await engine.catchUp(reason: "wake")
        XCTAssertEqual(exec.calls, ["Outdoor=on"])   // the wake catch-up did not put it back to off
        await engine.stop()
    }

    func testOverrideSurvivesARestart() async throws {
        let store = tempStore(), exec = Recorder()
        let first = RuleEngine(config: try config(), executor: exec, overrideStore: store, now: { self.fixedNow }, log: { _ in })
        await first.start()
        await first.runNow("plug on")
        try await Task.sleep(for: .milliseconds(100))
        await first.stop()

        let second = RuleEngine(config: try config(), executor: exec, overrideStore: store, now: { self.fixedNow }, log: { _ in })
        await second.start()
        await second.catchUp(reason: "startup")
        XCTAssertEqual(exec.calls, ["Outdoor=on"])
        await second.stop()
    }

    func testWithoutAnOverrideCatchUpStillAppliesTheSchedule() async throws {
        let exec = Recorder()
        let engine = RuleEngine(config: try config(), executor: exec, overrideStore: tempStore(), now: { self.fixedNow }, log: { _ in })
        await engine.start()
        await engine.catchUp(reason: "startup")
        XCTAssertEqual(exec.calls, ["Outdoor=off"])
        await engine.stop()
    }

    func testFailedRunNowWithdrawsItsOverride() async throws {
        let exec = Recorder(failures: 1)
        let engine = RuleEngine(config: try config(), executor: exec, overrideStore: tempStore(), now: { self.fixedNow }, log: { _ in })
        await engine.start()
        await engine.runNow("plug on")
        try await Task.sleep(for: .milliseconds(150))
        await engine.catchUp(reason: "test")
        XCTAssertEqual(exec.calls, ["Outdoor=on", "Outdoor=off"])   // the manual change did not happen, so the schedule still applies
        await engine.stop()
    }

    func testUnknownRuleIsIgnored() async throws {
        let exec = Recorder()
        let engine = RuleEngine(config: try config(), executor: exec, overrideStore: tempStore(), now: { self.fixedNow }, log: { _ in })
        await engine.start()
        await engine.runNow("nope")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(exec.calls.isEmpty)
        await engine.stop()
    }
}

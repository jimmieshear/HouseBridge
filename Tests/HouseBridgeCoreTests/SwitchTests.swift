import XCTest
@testable import HouseBridgeCore

private final class Flips: @unchecked Sendable {
    private let lock = NSLock()
    private var _list: [String] = []
    var list: [String] { lock.withLock { _list } }
    func add(_ name: String, _ on: Bool) { lock.withLock { _list.append("\(name)=\(on)") } }
}

final class SwitchTests: XCTestCase {
    private func yaml(timeout: String = "0.2") -> String {
        """
        unifi: { host: 3.3.3.3, username: u, password: p }
        homekit: { name: HB }
        hue: { host: 2.2.2.2 }
        rules:
          - name: Night
            homekit_switch: Night Lite
            when: { unifi: Door, event: motion, state: start }
            then:
              - { action: light, light: [A, B], on: true, brightness: 13, off_after_seconds: \(timeout) }
        """
    }

    func testParsingAndValidation() throws {
        let cfg = try ConfigLoader.parse(yaml())
        XCTAssertEqual(cfg.homekitSwitches, ["Night Lite"])
        // needs a timer so the switch can turn itself off
        XCTAssertThrowsError(try ConfigLoader.parse(yaml().replacingOccurrences(of: ", off_after_seconds: 0.2", with: "")))
        // needs the homekit section
        XCTAssertThrowsError(try ConfigLoader.parse(yaml().replacingOccurrences(of: "homekit: { name: HB }\n", with: "")))
    }

    func testSwitchFollowsAutomationAndTimeout() async throws {
        let flips = Flips(), exec = RecordingExecutor()
        let engine = RuleEngine(config: try ConfigLoader.parse(yaml()), executor: exec, onSwitch: { flips.add($0, $1) }, log: { _ in })
        await engine.start()
        await engine.handle(TriggerEvent(source: .unifi, device: "Door", input: "motion", kind: "start"))
        XCTAssertEqual(flips.list, ["Night Lite=true"])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(flips.list, ["Night Lite=true", "Night Lite=false"])
        XCTAssertEqual(exec.actions.count, 2, "on, then the engine's auto-off")
    }

    func testTurningOnFromHomeAppRunsRuleAndStillTimesOut() async throws {
        let flips = Flips(), exec = RecordingExecutor()
        let engine = RuleEngine(config: try ConfigLoader.parse(yaml()), executor: exec, onSwitch: { flips.add($0, $1) }, log: { _ in })
        await engine.start()
        await engine.setSwitch("night lite", on: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(exec.actions.count, 1)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(exec.actions.count, 2, "auto-off ran")
        XCTAssertEqual(flips.list.last, "Night Lite=false")
    }

    func testTurningOffFromHomeAppCancelsTimerAndSwitchesLightsOff() async throws {
        let flips = Flips(), exec = RecordingExecutor()
        let engine = RuleEngine(config: try ConfigLoader.parse(yaml(timeout: "0.3")), executor: exec, onSwitch: { flips.add($0, $1) }, log: { _ in })
        await engine.start()
        await engine.setSwitch("Night Lite", on: true)
        await engine.setSwitch("Night Lite", on: false)
        try await Task.sleep(for: .milliseconds(600))
        let states = exec.actions.compactMap { a -> Bool? in if case .light(_, let s) = a { return s.on } else { return nil } }
        XCTAssertEqual(states, [true, false], "one off from the switch; the cancelled timer did not add a second")
        XCTAssertEqual(flips.list.last, "Night Lite=false")
    }

    func testLayoutPublishesWritableSwitch() {
        let built = HAPLayout.build(bridgeName: "HB", bridgeID: "id", devices: [], smartDetections: false, switches: [(name: "Night Lite", aid: 5)])
        let key = built.switches["night lite"]
        XCTAssertNotNil(key)
        let accessory = built.accessories.first { $0.aid == 5 }
        let on = accessory?.services.flatMap(\.characteristics).first { $0.iid == key?.iid }
        XCTAssertEqual(on?.type, "25")
        XCTAssertEqual(on?.perms, ["pr", "pw", "ev"])
    }
}

import XCTest
@testable import HouseBridgeCore

private final class Clock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 1_800_000_000) }

final class HomeButtonTests: XCTestCase {
    private let yaml = """
    hue: { host: 2.2.2.2 }
    unifi: { host: 3.3.3.3, username: u, password: p }
    homekit: { name: HB }
    presence:
      - name: Someone is home
        hold_hours: 24
        when: [{ unifi: Front Door Motion, event: motion, state: start }]
        pauses: [{ room: Bedroom }]
    buttons:
      - name: Default Lights
        then:
          - { action: scene, name: SanJose-Default, room: Bedroom, brightness: 100 }
          - { action: light, room: Stairs, on: true, brightness: 100 }
    rules:
      - name: porch
        homekit_switch: Porch timer
        when: { at: "18:00" }
        then: [{ action: light, room: Porch, on: true, off_after_seconds: 60 }]
    """

    func testButtonsAreParsedAndPublishedAsSwitches() throws {
        let c = try ConfigLoader.parse(yaml)
        XCTAssertEqual(c.homekitButtons, ["Default Lights"])
        XCTAssertEqual(c.homekitSwitches, ["Porch timer", "Default Lights"])
        let rule = try XCTUnwrap(c.rules.first { $0.homekitButton != nil })
        XCTAssertEqual(rule.actions.count, 2)
        XCTAssertEqual(rule.name, "button: Default Lights")
        // No real event can start it.
        XCTAssertFalse(rule.trigger.matches(TriggerEvent(source: .homekit, device: "Owl", input: "smoke", kind: "detected")))
        XCTAssertFalse(rule.trigger.matches(TriggerEvent(source: .homekit, device: "(Home.app button)", input: "smoke", kind: "detected")))
    }

    func testRejectsBadButtons() {
        let unifi = "unifi: { host: 3.3.3.3, username: u, password: p }\n"
        let base = "hue: { host: 2.2.2.2 }\n" + unifi + "homekit: { name: HB }\n"
        func parse(_ extra: String, prefix: String = base) throws { _ = try ConfigLoader.parse(prefix + extra) }
        let ok = "buttons:\n  - name: A\n    then: [{ action: light, room: R, on: true }]\n"
        XCTAssertNoThrow(try parse(ok))
        XCTAssertThrowsError(try parse(ok, prefix: "hue: { host: 2.2.2.2 }\n" + unifi), "needs homekit:")
        XCTAssertThrowsError(try parse("buttons:\n  - name: A\n    then: []\n"), "no actions")
        XCTAssertThrowsError(try parse("buttons:\n  - then: [{ action: light, room: R, on: true }]\n"), "no name")
        XCTAssertThrowsError(try parse("buttons:\n  - { name: A, then: [{ action: light, room: R, on: true }], when: x }\n"), "unknown key")
        XCTAssertThrowsError(try parse(ok + "  - name: a\n    then: [{ action: light, room: R, on: true }]\n"), "duplicate (case-insensitive)")
        XCTAssertThrowsError(try parse(ok, prefix: unifi + "homekit: { name: HB }\n"), "controls Hue but there is no hue: section")
        XCTAssertThrowsError(try parse("buttons:\n  - name: P\n    then: [{ action: light, room: R, on: true }]\nrules:\n  - { name: r, homekit_switch: p, when: { at: \"18:00\" }, then: [{ action: light, room: R, on: true, off_after_seconds: 5 }] }\n"),
                             "clashes with a rule's switch")
    }

    /// Pressing it runs everything at once, even while a presence hold covers those lights.
    func testPressingRunsTheActionsEvenDuringAPresenceHold() async throws {
        let clock = Clock(), exec = RecordingExecutor()
        let engine = RuleEngine(config: try ConfigLoader.parse(yaml), executor: exec, now: { clock.date }, log: { _ in })
        await engine.start()
        await engine.handle(TriggerEvent(source: .unifi, device: "Front Door Motion", input: "motion", kind: "start"))   // starts the hold on Bedroom
        await engine.pressButton("default lights")   // case-insensitive
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(exec.actions.count, 2)
        XCTAssertTrue(exec.actions.contains { if case .scene(let name, let room, _, let brightness) = $0 { name == "SanJose-Default" && room == "Bedroom" && brightness == 100 } else { false } })
        await engine.pressButton("no such button")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(exec.actions.count, 2, "an unknown name does nothing")
        await engine.stop()
    }
}

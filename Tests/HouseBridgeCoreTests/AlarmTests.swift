import XCTest
@testable import HouseBridgeCore

final class AlarmTests: XCTestCase {
    private func yaml(keep: String = "0.3") -> String {
        """
        lutron: { host: 1.1.1.1, ca: /x, cert: /x, key: /x }
        hue: { host: 2.2.2.2 }
        unifi: { host: 3.3.3.3, username: u, password: p }
        presence:
          - name: Someone is home
            when: [{ unifi: Door, event: motion, state: start }]
            pauses: [{ light: X }]
        alarms:
          - name: Intruder
            when:
              - { unifi: Front Camera, event: person }
              - { unifi: Front PTZ, event: person }
            keep_seconds: \(keep)
            max_minutes: 10
            lights: { except_rooms: [Guest Bedroom 2, Master Bedroom], lutron: [Garage Wall Lights, Spot] }
            accent: { lights: [Porch], color: "#FF0000" }
            sound: { start: Dog Barking, stop: Stop Dog Barking }
        """
    }
    private func person(_ camera: String = "Front Camera", _ kind: String = "start") -> TriggerEvent {
        TriggerEvent(source: .unifi, device: camera, input: "person", kind: kind)
    }
    /// Short labels of the alarm steps the executor saw.
    private func steps(_ e: RecordingExecutor) -> [String] {
        e.actions.compactMap { a -> String? in
            guard case .alarm(let s) = a else { return nil }
            switch s { case .start: return "start"; case .end: return "end"; case .soundStart: return "sound"; case .soundStop: return "stop"
            case .lutron(let d, let on): return "\(d.prefix(1).lowercased())\(on ? "+" : "-")" }
        }
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(80)) }

    func testParsing() throws {
        let a = try ConfigLoader.parse(yaml()).alarms[0]
        XCTAssertEqual(a.triggers.count, 2); XCTAssertEqual(a.exceptRooms, ["Guest Bedroom 2", "Master Bedroom"])
        XCTAssertEqual(a.lutronSwitches, ["Garage Wall Lights", "Spot"]); XCTAssertEqual(a.accentLights, ["Porch"]); XCTAssertEqual(a.soundStart, "Dog Barking"); XCTAssertEqual(a.maxSeconds, 600)
        XCTAssertEqual(try ConfigLoader.parse(yaml(keep: "30")).alarms[0].keepSeconds, 30)
    }

    func testRejectsBadConfig() {
        func parse(_ body: String, unifi: Bool = true, hue: Bool = true) throws {
            _ = try ConfigLoader.parse((hue ? "hue: { host: 2.2.2.2 }\n" : "") + (unifi ? "unifi: { host: 3.3.3.3, username: u, password: p }\n" : "") + "alarms:\n" + body)
        }
        let ok = "  - { name: a, when: [{ unifi: Cam, event: person }] }"
        XCTAssertNoThrow(try parse(ok))
        XCTAssertThrowsError(try parse(ok, unifi: false)); XCTAssertThrowsError(try parse(ok, hue: false))
        XCTAssertThrowsError(try parse("  - { name: a, when: [] }"))
        XCTAssertThrowsError(try parse("  - { name: a, when: [{ unifi: Cam }] }"), "needs an event")
        XCTAssertThrowsError(try parse("  - { name: a, when: [{ pico: P }] }"))
        XCTAssertThrowsError(try parse("  - { name: a, when: [{ unifi: Cam, event: person }], keep_seconds: 0 }"))
        XCTAssertThrowsError(try parse("  - { name: a, when: [{ unifi: Cam, event: person }], accent: { color: red } }"))
        XCTAssertThrowsError(try parse("  - { name: a, when: [{ unifi: Cam, event: person }], sound: { stop: x } }"), "stop alone")
    }

    func testStartsOnPersonThenEndsAfterQuietPeriod() async throws {
        let exec = RecordingExecutor()
        let engine = RuleEngine(config: try ConfigLoader.parse(yaml()), executor: exec, log: { _ in })
        await engine.start()
        await engine.handle(person())
        try await settle()
        XCTAssertEqual(steps(exec), ["start", "g+", "s+", "sound"])

        // A detection that has ended: the countdown runs from the `end`, and a second camera restarts it without restarting the alarm.
        await engine.handle(person("Front PTZ"))
        await engine.handle(person("Front Camera", "end"))
        await engine.handle(person("Front PTZ", "end"))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(steps(exec), ["start", "g+", "s+", "sound"], "not over yet")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(steps(exec), ["start", "g+", "s+", "sound", "stop", "g-", "s-", "end"])
        await engine.stop()
    }

    func testLingeringPersonKeepsAlarmGoing() async throws {
        let exec = RecordingExecutor()
        let engine = RuleEngine(config: try ConfigLoader.parse(yaml()), executor: exec, log: { _ in })
        await engine.start()
        await engine.handle(person())          // start, no end yet: still in view
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(steps(exec), ["start", "g+", "s+", "sound"], "stays on while the person is in view, well past keep_seconds")
        await engine.handle(person("Front Camera", "end"))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(steps(exec).suffix(4), ["stop", "g-", "s-", "end"])
        await engine.stop()
    }

    func testNotStartedWhileSomeoneIsHomeButNotStoppedByAHold() async throws {
        let exec = RecordingExecutor()
        let engine = RuleEngine(config: try ConfigLoader.parse(yaml()), executor: exec, log: { _ in })
        await engine.start()
        await engine.handle(TriggerEvent(source: .unifi, device: "Door", input: "motion", kind: "start"))
        await engine.handle(person())
        try await settle()
        XCTAssertTrue(steps(exec).isEmpty, "someone is home")
        await engine.stop()

        // A hold that starts after the alarm began (the intruder reaching the door) does not cancel it.
        let exec2 = RecordingExecutor()
        let engine2 = RuleEngine(config: try ConfigLoader.parse(yaml()), executor: exec2, log: { _ in })
        await engine2.start()
        await engine2.handle(person())
        await engine2.handle(TriggerEvent(source: .unifi, device: "Door", input: "motion", kind: "start"))
        await engine2.handle(person("Front PTZ"))
        try await settle()
        XCTAssertEqual(steps(exec2), ["start", "g+", "s+", "sound"], "still running, not restarted")
        await engine2.stop()
    }

    func testStoppingTheEngineEndsARunningAlarm() async throws {
        let exec = RecordingExecutor()
        let engine = RuleEngine(config: try ConfigLoader.parse(yaml(keep: "30")), executor: exec, log: { _ in })
        await engine.start()
        await engine.handle(person())
        try await settle()
        await engine.stop()
        try await settle()
        XCTAssertEqual(steps(exec), ["start", "g+", "s+", "sound", "stop", "g-", "s-", "end"], "a reload must not leave the dogs barking")
    }

    func testOtherDetectionsAndCamerasAreIgnored() async throws {
        let exec = RecordingExecutor()
        let engine = RuleEngine(config: try ConfigLoader.parse(yaml()), executor: exec, log: { _ in })
        await engine.start()
        await engine.handle(TriggerEvent(source: .unifi, device: "Front Camera", input: "vehicle", kind: "start"))
        await engine.handle(person("Garage Camera"))
        try await settle()
        XCTAssertTrue(steps(exec).isEmpty)
        await engine.stop()
    }
}

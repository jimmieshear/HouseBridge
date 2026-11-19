import XCTest
@testable import HouseBridgeCore

private final class Calls: ActionExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    func execute(_ action: Action) async throws {
        lock.withLock { if case .plug(let d, let on, _) = action { _calls.append("\(d)=\(on ? "on" : "off")") } }
    }
}

final class SkipTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func hhmm(plusHours h: Int) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: fixedNow.addingTimeInterval(Double(h) * 3600))
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    /// "off" was due an hour ago; "on" is due in an hour.
    private func config() throws -> Config {
        try ConfigLoader.parse("""
        kasa:
          plugs: [{ name: Outdoor, host: 4.4.4.4 }]
        rules:
          - name: plug on
            when: { at: "\(hhmm(plusHours: 1))" }
            then: [{ action: plug, device: Outdoor, on: true }]
          - name: plug off
            when: { at: "\(hhmm(plusHours: -1))" }
            then: [{ action: plug, device: Outdoor, on: false }]
        """)
    }

    private func store() -> HoldStore {
        HoldStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("skip-\(UUID().uuidString).json"))
    }

    private func clockEvent(_ config: Config, rule: String, at date: Date) -> TriggerEvent {
        let schedule = config.rules.first { $0.name == rule }!.trigger.schedule!
        return TriggerEvent(source: .clock, device: "clock", input: schedule.key, kind: "fire", detail: schedule.summary, date: date)
    }

    private func nextOn(_ config: Config) -> Date {
        config.rules.first { $0.name == "plug on" }!.trigger.schedule!.next(after: fixedNow, location: nil)!
    }

    func testSkippedOccurrenceDoesNotFireButTheNextOneDoes() async throws {
        let config = try config(), due = nextOn(config), exec = Calls()
        let engine = RuleEngine(config: config, executor: exec, skipStore: store(), now: { self.fixedNow }, log: { _ in })
        await engine.start()
        await engine.skip("plug on", at: due)
        await engine.handle(clockEvent(config, rule: "plug on", at: due))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(exec.calls.isEmpty)

        // The skip was for that one time only: the same rule a day later runs.
        let tomorrow = due.addingTimeInterval(86400)
        await engine.handle(clockEvent(config, rule: "plug on", at: tomorrow))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(exec.calls, ["Outdoor=on"])
        await engine.stop()
    }

    func testWithoutSkipTheRuleFires() async throws {
        let config = try config(), exec = Calls()
        let engine = RuleEngine(config: config, executor: exec, skipStore: store(), now: { self.fixedNow }, log: { _ in })
        await engine.start()
        await engine.handle(clockEvent(config, rule: "plug on", at: nextOn(config)))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(exec.calls, ["Outdoor=on"])
        await engine.stop()
    }

    func testCatchUpDoesNotApplyTheSkippedChangeLateOrAnOlderOne() async throws {
        let config = try config(), due = nextOn(config), exec = Calls()
        let engine = RuleEngine(config: config, executor: exec, overrideStore: store(), skipStore: store(), now: { self.fixedNow }, log: { _ in })
        await engine.start()
        await engine.skip("plug on", at: due)
        await engine.catchUp(reason: "wake")
        XCTAssertTrue(exec.calls.isEmpty)   // the device stays as it is until after the skipped time
        await engine.stop()
    }

    func testUndoRestoresTheOccurrence() async throws {
        let config = try config(), due = nextOn(config), exec = Calls()
        let engine = RuleEngine(config: config, executor: exec, overrideStore: store(), skipStore: store(), now: { self.fixedNow }, log: { _ in })
        await engine.start()
        await engine.skip("plug on", at: due)
        await engine.unskip("plug on", at: due)
        await engine.handle(clockEvent(config, rule: "plug on", at: due))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(exec.calls, ["Outdoor=on"])
        await engine.catchUp(reason: "wake")   // and catch-up is back to normal: the past "off" applies
        XCTAssertEqual(exec.calls, ["Outdoor=on", "Outdoor=off"])
        await engine.stop()
    }

    func testSkipSurvivesARestart() async throws {
        let config = try config(), due = nextOn(config), exec = Calls(), skips = store()
        let first = RuleEngine(config: config, executor: exec, skipStore: skips, now: { self.fixedNow }, log: { _ in })
        await first.start()
        await first.skip("plug on", at: due)
        await first.stop()

        let second = RuleEngine(config: config, executor: exec, skipStore: skips, now: { self.fixedNow }, log: { _ in })
        await second.start()
        await second.handle(clockEvent(config, rule: "plug on", at: due))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(exec.calls.isEmpty)
        await second.stop()
    }

    func testUpcomingMarksSkippedOccurrences() throws {
        let config = try config(), due = nextOn(config)
        let events = Upcoming.events(config: config, skips: [Upcoming.skipKey("plug on", due)], now: fixedNow)
        XCTAssertEqual(events.filter(\.skipped).map(\.title), ["plug on"])
        XCTAssertEqual(events.filter(\.skipped).first?.date, due)
        XCTAssertFalse(events.filter { $0.title == "plug off" }.contains(where: \.skipped))
    }
}

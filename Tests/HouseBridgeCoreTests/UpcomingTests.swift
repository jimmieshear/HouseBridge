import XCTest
@testable import HouseBridgeCore

final class UpcomingTests: XCTestCase {
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.date(from: s)!
    }

    func testNoAutomationGivesNoEvents() throws {
        let config = try ConfigLoader.parse("hue: { host: 1.1.1.1 }\nrules: []\n")
        XCTAssertTrue(Upcoming.events(config: config, now: date("2026-11-18 12:00")).isEmpty)
    }

    func testDailyRuleAppearsOncePerDayInsideTheWindowSoonestFirst() throws {
        let config = try ConfigLoader.parse("""
        hue: { host: 1.1.1.1 }
        rules:
          - name: Evening
            when: { at: "18:30" }
            then: [{ action: light, room: Den, on: true }]
          - name: Late
            when: { at: "23:00" }
            then: [{ action: light, room: Den, on: false }]
          - name: Off rule
            enabled: false
            when: { at: "19:00" }
            then: [{ action: light, room: Den, on: false }]
        """)
        let events = Upcoming.events(config: config, now: date("2026-11-18 12:00"), ruleHours: 48)
        XCTAssertEqual(events.map(\.title), ["Evening", "Late", "Evening", "Late"])   // disabled rule left out
        XCTAssertEqual(events.first?.date, date("2026-11-18 18:30"))
        XCTAssertEqual(events.last?.date, date("2026-11-19 23:00"))
    }

    func testPresenceHoldEndAppearsOnlyWhileActive() throws {
        let config = try ConfigLoader.parse("""
        hue: { host: 1.1.1.1 }
        unifi: { host: 3.3.3.3, username: u, password: p }
        presence:
          - name: Home
            hold_hours: 2
            when:
              - { unifi: Cam, event: motion, state: start }
            pauses:
              - room: Den
        rules: []
        """)
        let now = date("2026-11-18 12:00")
        XCTAssertEqual(Upcoming.events(config: config, holds: ["Home": now.addingTimeInterval(600)], now: now).count, 1)
        XCTAssertTrue(Upcoming.events(config: config, holds: ["Home": now.addingTimeInterval(-600)], now: now).isEmpty)
    }
}

import XCTest
@testable import HouseBridgeCore

final class LightDefaultsTests: XCTestCase {
    private let yaml = """
    hue: { host: 1.1.1.1 }
    light_defaults:
      kelvin: 3000
      overrides:
        - { room: Bedroom, kelvin: 2400 }
        - { zone: Porch Zone, kelvin: 2700 }
        - { light: Lamp, kelvin: 2200 }
        - { light: Stairs1, ignore: true }
    """

    private func inventory() -> HueInventory {
        func light(_ id: String) -> HueInventory.Item { HueInventory.Item(id: id, name: id, groupedLightId: nil) }
        var inv = HueInventory()
        inv.lights = ["Hall1", "Hall2", "Lamp", "Stairs1", "Porch"].map(light)
        var hall = HueInventory.Item(id: "room-hall", name: "Hallway", groupedLightId: "g1"); hall.lightIds = ["Hall1", "Hall2"]
        var bed = HueInventory.Item(id: "room-bed", name: "Bedroom", groupedLightId: "g2"); bed.lightIds = ["Lamp", "Stairs1"]
        var zone = HueInventory.Item(id: "zone-porch", name: "Porch Zone", groupedLightId: "g3"); zone.lightIds = ["Porch"]
        inv.rooms = [hall, bed]
        inv.zones = [zone]
        return inv
    }

    private func state(_ id: String, on: Bool = true, kelvin: Int?, min: Int = 153, max: Int = 500) -> HueLightState {
        HueLightState(id: id, name: id, on: on, mirek: kelvin.map { Int((1_000_000 / Double($0)).rounded()) }, minMirek: min, maxMirek: max)
    }

    func testConfigParsingAndValidation() throws {
        let c = try ConfigLoader.parse(yaml)
        XCTAssertEqual(c.lightDefaults?.kelvin, 3000)
        XCTAssertEqual(c.lightDefaults?.overrides.count, 4)
        XCTAssertEqual(c.lightDefaults?.checkSeconds, 30)
        XCTAssertThrowsError(try ConfigLoader.parse("light_defaults: { kelvin: 3000 }"), "needs hue:")
        XCTAssertThrowsError(try ConfigLoader.parse("hue: { host: 1.1.1.1 }\nlight_defaults: { kelvin: 9000 }"))
        XCTAssertThrowsError(try ConfigLoader.parse("hue: { host: 1.1.1.1 }\nlight_defaults:\n  kelvin: 3000\n  overrides:\n    - { room: A, light: B, kelvin: 2500 }"))
        XCTAssertThrowsError(try ConfigLoader.parse("hue: { host: 1.1.1.1 }\nlight_defaults:\n  kelvin: 3000\n  overrides:\n    - { room: A }"))
    }

    func testPrecedenceLightThenZoneThenRoomThenDefault() throws {
        let d = try XCTUnwrap(ConfigLoader.parse(yaml).lightDefaults), inv = inventory()
        func wanted(_ id: String) -> Int? { LightTemperature.wanted(inv.lights.first { $0.id == id }!, inventory: inv, defaults: d) }
        XCTAssertEqual(wanted("Hall1"), 3000)   // default
        XCTAssertEqual(wanted("Lamp"), 2200)    // light beats its room (Bedroom 2400)
        XCTAssertNil(wanted("Stairs1"))         // ignored
        XCTAssertEqual(wanted("Porch"), 2700)   // zone
    }

    func testPlanCorrectsOnlyWhiteLightsThatAreOnAndOffTarget() throws {
        let d = try XCTUnwrap(ConfigLoader.parse(yaml).lightDefaults), inv = inventory()
        let states = [state("Hall1", kelvin: 5000),                 // wrong, on -> fix
                      state("Hall2", kelvin: 3050),                 // within tolerance
                      state("Lamp", on: false, kelvin: 5000),       // off
                      state("Porch", kelvin: nil),                  // showing a color
                      state("Stairs1", kelvin: 6000)]               // ignored
        let plan = LightTemperature.plan(states: states, inventory: inv, activeGroups: [], defaults: d)
        XCTAssertEqual(plan.map(\.lightID), ["Hall1"])
        XCTAssertEqual(plan.first?.toKelvin, 3003)   // mirek 333 reads back as 3003 K
        XCTAssertEqual(plan.first?.toMirek, 333)
    }

    func testActiveSceneInRoomOrZoneIsLeftAlone() throws {
        let d = try XCTUnwrap(ConfigLoader.parse(yaml).lightDefaults), inv = inventory()
        let states = [state("Hall1", kelvin: 5000), state("Porch", kelvin: 5000)]
        XCTAssertEqual(LightTemperature.plan(states: states, inventory: inv, activeGroups: ["room-hall"], defaults: d).map(\.lightID), ["Porch"])
        XCTAssertEqual(LightTemperature.plan(states: states, inventory: inv, activeGroups: ["zone-porch"], defaults: d).map(\.lightID), ["Hall1"])
    }

    func testTargetIsClampedToWhatTheLightCanDo() throws {
        let d = try XCTUnwrap(ConfigLoader.parse(yaml).lightDefaults), inv = inventory()
        // A light limited to 2200 K–4000 K (mirek 250–454) asked for 3000 K is fine; one limited to mirek 153–300 can't reach 3000 K (333).
        let plan = LightTemperature.plan(states: [state("Hall1", kelvin: 6500, min: 153, max: 300)], inventory: inv, activeGroups: [], defaults: d)
        XCTAssertEqual(plan.first?.toMirek, 300)
    }
}

final class RequestGateTests: XCTestCase {
    private actor Counter {
        var now = 0, peak = 0
        func enter() { now += 1; peak = max(peak, now) }
        func leave() { now -= 1 }
    }

    func testNeverRunsMoreThanLimitAtOnce() async throws {
        let gate = RequestGate(limit: 2), counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await gate.run {
                        await counter.enter()
                        try await Task.sleep(for: .milliseconds(20))
                        await counter.leave()
                    }
                }
            }
        }
        let peak = await counter.peak
        XCTAssertEqual(peak, 2)
    }

    func testHTMLErrorPageIsSummarisedByItsTitle() {
        let failure = HTTPFailure(status: 429, body: "<html>\r\n<head><title>429 Too Many Requests</title></head>\r\n<body>…</body></html>")
        XCTAssertEqual(failure.description, "HTTP 429: 429 Too Many Requests")
        XCTAssertTrue(failure.isRateLimited)
    }
}

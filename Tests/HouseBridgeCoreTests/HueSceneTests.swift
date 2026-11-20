import XCTest
@testable import HouseBridgeCore

final class HueSceneTests: XCTestCase {
    func testMirek() {
        XCTAssertEqual(HueScene.mirek(kelvin: 3003), 333)
        XCTAssertEqual(HueScene.mirek(kelvin: 2000), 500)
        XCTAssertNil(HueScene.mirek(kelvin: 1500))
        XCTAssertNil(HueScene.mirek(kelvin: 9000))
        XCTAssertNil(HueScene.mirek(kelvin: 0))
    }

    func testActionsSkipTemperatureForDimmableOnly() throws {
        var white = HueInventory.Item(id: "a", name: "A", groupedLightId: nil); white.supportsTemperature = true
        let plain = HueInventory.Item(id: "b", name: "B", groupedLightId: nil)
        let actions = HueScene.actions(lights: [white, plain], mirek: 333, brightness: 80)
        let first = try XCTUnwrap(actions[0]["action"] as? JSON), second = try XCTUnwrap(actions[1]["action"] as? JSON)
        XCTAssertEqual(((first["color_temperature"] as? JSON)?["mirek"]) as? Int, 333)
        XCTAssertNil(second["color_temperature"])
        XCTAssertEqual((second["dimming"] as? JSON)?["brightness"] as? Double, 80)
    }

    func testCreateBodyUsesGroupType() {
        let room = HueInventory.Item(id: "r1", name: "Den", groupedLightId: nil)
        let body = HueScene.createBody(name: "Warm", group: room, isZone: true, actions: [])
        XCTAssertEqual((body["group"] as? JSON)?["rtype"] as? String, "zone")
        XCTAssertEqual((body["metadata"] as? JSON)?["name"] as? String, "Warm")
    }
}

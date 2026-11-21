import XCTest
@testable import HouseBridgeCore

final class HueScheduleTests: XCTestCase {
    private func scene(_ id: String, _ name: String, group: String, mireks: [Int], active: String = "inactive") -> JSON {
        ["id": id, "metadata": ["name": name], "group": ["rid": group, "rtype": "room"], "status": ["active": active],
         "actions": mireks.map { ["target": ["rid": "l", "rtype": "light"], "action": ["color_temperature": ["mirek": $0]]] }]
    }

    func testSmartScenesCountAsActiveScenes() {
        let scenes = [scene("a", "Default", group: "room-bed", mireks: [333], active: "static"),
                      scene("b", "Relax", group: "room-hall", mireks: [447])]   // inactive
        let smart: [JSON] = [["state": "active", "group": ["rid": "room-family", "rtype": "room"]],
                             ["state": "inactive", "group": ["rid": "room-kitchen", "rtype": "room"]]]
        XCTAssertEqual(HueClient.activeGroups(scenes: scenes, smartScenes: smart), ["room-bed", "room-family"])
        XCTAssertEqual(HueClient.activeGroups(scenes: scenes, smartScenes: []), ["room-bed"])
    }

    /// A room moved by a smart scene (Natural light) is left alone instead of being forced to the default.
    func testPlanLeavesASmartSceneRoomAlone() throws {
        let yaml = "hue: { host: 1.1.1.1 }\nlight_defaults: { kelvin: 3000 }"
        let d = try XCTUnwrap(ConfigLoader.parse(yaml).lightDefaults)
        var inv = HueInventory()
        inv.lights = [HueInventory.Item(id: "L1", name: "L1", groupedLightId: nil)]
        var room = HueInventory.Item(id: "room-family", name: "Family room", groupedLightId: "g"); room.lightIds = ["L1"]
        inv.rooms = [room]
        let state = HueLightState(id: "L1", name: "L1", on: true, mirek: 377, minMirek: 153, maxMirek: 500, brightness: 30)
        XCTAssertEqual(LightTemperature.plan(states: [state], inventory: inv, activeGroups: [], defaults: d).count, 1)
        let active = HueClient.activeGroups(scenes: [], smartScenes: [["state": "active", "group": ["rid": "room-family", "rtype": "room"]]])
        XCTAssertTrue(LightTemperature.plan(states: [state], inventory: inv, activeGroups: active, defaults: d).isEmpty)
        // The correction says where and how bright the light was.
        let c = LightTemperature.plan(states: [state], inventory: inv, activeGroups: [], defaults: d)[0]
        XCTAssertEqual(c.room, "Family room")
        XCTAssertEqual(c.brightness, 30)
        XCTAssertEqual(c.fromKelvin, 2653)
    }

    func testReportFlagsScenesThatDifferFromTheTarget() {
        let scenes = [scene("a", "SanJose-Default", group: "r1", mireks: [333, 333]),
                      scene("b", "Evening", group: "r1", mireks: [377, 333]),
                      scene("c", "Dusk", group: "r2", mireks: [377], active: "static")]
        let text = HueSchedule.report(scenes: scenes, smartScenes: [], routines: [], groupNames: ["r1": "Bedroom", "r2": "Family room"],
                                      target: (3000, 100))
        XCTAssertTrue(text.contains("target: 3000 K (Hue stores it as mirek 333, shown as 3003 K)"), text)
        XCTAssertTrue(text.contains("Bedroom / SanJose-Default: 3003 K   ok"), text)
        XCTAssertTrue(text.contains("Bedroom / Evening: 2653–3003 K   DIFFERENT (1 of 2 lights)"), text)
        XCTAssertTrue(text.contains("Family room / Dusk: 2653 K   DIFFERENT (1 of 1 lights)   [ACTIVE: static]"), text)
        // A filter keeps only matching scenes (by name or room).
        let filtered = HueSchedule.report(scenes: scenes, smartScenes: [], routines: [], groupNames: ["r1": "Bedroom", "r2": "Family room"],
                                          target: (3000, 100), filter: "default")
        XCTAssertTrue(filtered.contains("SanJose-Default"))
        XCTAssertFalse(filtered.contains("Evening"))
    }

    func testReportShowsSmartSceneSlotsAndRoutineTimes() {
        let scenes = [scene("day", "Daytime", group: "r1", mireks: [250]), scene("eve", "Evening", group: "r1", mireks: [377])]
        let smart: [JSON] = [["metadata": ["name": "Natural light"], "group": ["rid": "r1", "rtype": "room"], "state": "active",
                              "week_timeslots": [["recurrence": ["monday", "tuesday"],
                                                  "timeslots": [["start_time": ["kind": "time", "time": ["hour": 7, "minute": 0]], "target": ["rid": "day", "rtype": "scene"]],
                                                                ["start_time": ["kind": "time", "time": ["hour": 20, "minute": 0]], "target": ["rid": "eve", "rtype": "scene"]]]]]]]
        let routines: [JSON] = [["metadata": ["name": "Go to sleep"], "enabled": true, "status": "running",
                                 "configuration": ["when": ["time_point": ["time": ["hour": 22, "minute": 30]]], "where": [["group": ["rid": "r1", "rtype": "room"]]],
                                                   "what": [["recall": ["rid": "eve", "rtype": "scene"]]]]],
                                ["metadata": ["name": "Odd one"], "enabled": false, "configuration": ["something": ["else": 1]]]]
        let text = HueSchedule.report(scenes: scenes, smartScenes: smart, routines: routines, groupNames: ["r1": "Bedroom"], target: nil)
        XCTAssertTrue(text.contains("Bedroom / Natural light: active"), text)
        XCTAssertTrue(text.contains("07:00  Daytime: 4000 K  (mon,tue)"), text)
        XCTAssertTrue(text.contains("20:00  Evening: 2653 K  (mon,tue)"), text)
        XCTAssertTrue(text.contains("“Go to sleep”  enabled  running  at 22:30  scenes: Bedroom / Evening"), text)
        XCTAssertTrue(text.contains("“Odd one”  DISABLED"), text)
        XCTAssertTrue(text.contains("configuration: {\"something\":{\"else\":1}}"), "an unrecognised shape is shown as it is")
    }
}

final class HueScheduleErrorTests: XCTestCase {
    func testAFailedReadIsNotReportedAsNone() {
        let text = HueSchedule.report(scenes: [], smartScenes: [], routines: [], groupNames: [:], target: nil,
                                      smartScenesError: "HTTP 404", routinesError: "HTTP 403: forbidden")
        XCTAssertTrue(text.contains("COULD NOT READ: HTTP 404"), text)
        XCTAssertTrue(text.contains("COULD NOT READ: HTTP 403: forbidden"), text)
        let none = HueSchedule.report(scenes: [], smartScenes: [], routines: [], groupNames: [:], target: nil)
        XCTAssertFalse(none.contains("COULD NOT READ"))
        XCTAssertEqual(none.components(separatedBy: "(none)").count - 1, 3, "scenes, smart scenes and routines")
    }
}

import XCTest
@testable import HouseBridgeCore

private final class Clock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

final class HomeSensorTests: XCTestCase {
    private func line(_ kind: String, _ value: Double, name: String = "Owl upstairs Master", reachable: Bool = true,
                      id: String = "B6D05288") -> String {
        #"{"t":"reading","id":"\#(id)","home":"San Jose","name":"\#(name)","room":"Bedroom","kind":"\#(kind)","value":\#(value),"reachable":\#(reachable),"ts":1800000000}"#
    }

    private func store(_ devices: [String] = ["Owl upstairs Master"]) -> SensorStore { SensorStore(config: HomeSensorsConfig(devices: devices)) }

    // MARK: Store

    func testReadingsAreStoredAndOnlyChangesAreReported() {
        let s = store()
        XCTAssertTrue(s.ingest(line: line("temperature", 23.87)).changed)
        XCTAssertFalse(s.ingest(line: line("temperature", 23.87)).changed, "the helper re-sends everything every few minutes")
        XCTAssertTrue(s.ingest(line: line("temperature", 24.1)).changed)
        XCTAssertTrue(s.ingest(line: line("humidity", 55.9)).changed)
        XCTAssertEqual(s.readings.map(\.kind), ["humidity", "temperature"])
        XCTAssertEqual(s.readings.first { $0.kind == "temperature" }?.value, 24.1)
        XCTAssertEqual(s.readings.first?.room, "Bedroom")
    }

    func testSmokeAndCOMakeEventsOnlyOnChange() throws {
        let s = store()
        // The helper reports "clear" first: that is not news.
        XCTAssertTrue(s.ingest(line: line("smoke", 0)).events.isEmpty)
        let on = try XCTUnwrap(s.ingest(line: line("smoke", 1)).events.first)
        XCTAssertEqual(on.source, .homekit)
        XCTAssertEqual(on.device, "Owl upstairs Master")
        XCTAssertEqual(on.input, "smoke")
        XCTAssertEqual(on.kind, "detected")
        XCTAssertEqual(on.detail, "Bedroom, San Jose")
        XCTAssertTrue(s.ingest(line: line("smoke", 1)).events.isEmpty, "a repeat is not a new alarm")
        XCTAssertEqual(s.ingest(line: line("smoke", 0)).events.first?.kind, "clear")
        let co = try XCTUnwrap(s.ingest(line: line("co", 1)).events.first)
        XCTAssertEqual(co.input, "co")
        XCTAssertTrue(co.inputAliases.contains("carbon_monoxide"))
    }

    func testAlarmAlreadyOnWhenHouseBridgeStartsIsReported() {
        XCTAssertEqual(store().ingest(line: line("smoke", 1)).events.first?.kind, "detected")
    }

    func testUnreachableSensorKeepsItsAlarmState() {
        let s = store()
        XCTAssertEqual(s.ingest(line: line("smoke", 1)).events.count, 1)
        // Dropping off Wi-Fi reads as 0 in some stacks; that must not end the alarm.
        let offline = s.ingest(line: line("smoke", 0, reachable: false))
        XCTAssertTrue(offline.events.isEmpty)
        XCTAssertTrue(offline.changed)
        XCTAssertEqual(s.ingest(line: line("smoke", 0)).events.first?.kind, "clear")
    }

    func testOnlyConfiguredDevicesAndBadLinesAreIgnored() {
        let s = store(["owl upstairs master"])   // case-insensitive
        XCTAssertTrue(s.ingest(line: line("smoke", 1, name: "Some Other Detector")).events.isEmpty)
        XCTAssertTrue(s.readings.isEmpty)
        XCTAssertFalse(s.ingest(line: "not json").changed)
        XCTAssertFalse(s.ingest(line: #"{"t":"reading","id":"x"}"#).changed)
        XCTAssertTrue(s.ingest(line: line("temperature", 20)).changed, "the configured device is accepted (names are case-insensitive)")
        XCTAssertEqual(s.readings.count, 1)
        XCTAssertTrue(s.ingest(line: #"{"t":"hello","helper":"h","version":1}"#).hello)
        XCTAssertEqual(store(["*"]).ingest(line: line("smoke", 1, name: "Anything")).events.count, 1)
    }

    // MARK: Config

    private let yaml = """
    lutron: { host: 1.1.1.1, ca: /x, cert: /x, key: /x }
    hue: { host: 2.2.2.2 }
    unifi: { host: 3.3.3.3, username: u, password: p }
    home_sensors:
      devices: [Owl upstairs Master]
    presence:
      - name: Someone is home
        hold_hours: 24
        when: [{ unifi: Front Door Motion, event: motion, state: start }]
        pauses: [{ light: Porch }]
    rules:
      - name: smoke lights
        when: { homekit: Owl upstairs Master, event: smoke, state: detected }
        then: [{ action: light, light: Porch, on: true }]
      - name: porch motion
        when: { unifi: Cam, event: motion, state: start }
        then: [{ action: light, light: Porch, on: true }]
    """

    func testParsesSensorsAndTrigger() throws {
        let cfg = try ConfigLoader.parse(yaml)
        XCTAssertEqual(cfg.homeSensors?.devices, ["Owl upstairs Master"])
        let t = cfg.rules[0].trigger
        XCTAssertEqual(t.source, .homekit)
        XCTAssertEqual(t.device, "Owl upstairs Master")
        XCTAssertEqual(t.input, "smoke")
        XCTAssertEqual(t.kind, "detected")
        // The state defaults to detected and the event to smoke.
        let d = try ConfigLoader.parse("home_sensors: { devices: [A] }\nhue: { host: 1.1.1.1 }\nrules:\n  - { name: x, when: { homekit: A }, then: [{ action: light, light: L, on: true }] }")
        XCTAssertEqual(d.rules[0].trigger.input, "smoke")
        XCTAssertEqual(d.rules[0].trigger.kind, "detected")
    }

    func testRejectsBadSensorConfig() {
        let hue = "hue: { host: 1.1.1.1 }\n"
        func rule(_ when: String, sensors: Bool = true) throws {
            _ = try ConfigLoader.parse(hue + (sensors ? "home_sensors: { devices: [A] }\n" : "") + "rules:\n  - { name: x, when: \(when), then: [{ action: light, light: L, on: true }] }")
        }
        XCTAssertNoThrow(try rule("{ homekit: A, event: co, state: clear }"))
        XCTAssertThrowsError(try rule("{ homekit: A, event: smoke, state: open }"), "bad state")
        XCTAssertThrowsError(try rule("{ homekit: A, event: motion }"), "bad event")
        XCTAssertThrowsError(try rule("{ homekit: A, color: red }"), "unknown key")
        XCTAssertThrowsError(try rule("{ homekit: A }", sensors: false), "needs home_sensors")
        XCTAssertThrowsError(try ConfigLoader.parse("home_sensors: { devices: [] }"), "empty devices")
        XCTAssertThrowsError(try ConfigLoader.parse("home_sensors: { device: [A] }"), "unknown key")
    }

    // MARK: Behaviour

    /// Someone being home is when a smoke alarm matters most, so presence holds never pause it.
    func testPresenceHoldDoesNotPauseSmokeRule() async throws {
        let clock = Clock(), exec = RecordingExecutor()
        let engine = RuleEngine(config: try ConfigLoader.parse(yaml), executor: exec, now: { clock.date }, log: { _ in })
        await engine.start()
        await engine.handle(TriggerEvent(source: .unifi, device: "Front Door Motion", input: "motion", kind: "start"))   // starts the hold
        await engine.handle(TriggerEvent(source: .unifi, device: "Cam", input: "motion", kind: "start"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(exec.actions.count, 0, "the porch motion rule is paused")
        await engine.handle(TriggerEvent(source: .homekit, device: "Owl upstairs Master", input: "smoke", kind: "detected"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(exec.actions.count, 1, "the smoke rule still ran")
        await engine.stop()
    }

    // MARK: Socket

    func testServerDeliversLinesAndCountsClients() async throws {
        let path = "/tmp/hb-sensors-\(UInt32.random(in: 0...UInt32.max)).sock"
        final class Box: @unchecked Sendable { var lines: [String] = []; var counts: [Int] = []; let lock = NSLock() }
        let box = Box()
        let server = HomeSensorServer(path: path, onLine: { l in box.lock.withLock { box.lines.append(l) } },
                                      onClients: { n in box.lock.withLock { box.counts.append(n) } })
        do { try server.start() } catch { throw XCTSkip("the sandbox does not allow Unix sockets here: \(error)") }
        defer { server.stop() }
        XCTAssertEqual((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int, 0o600)

        // A second server on the same path must notice the first and refuse.
        let second = HomeSensorServer(path: path, onLine: { _ in }, onClients: { _ in })
        XCTAssertThrowsError(try second.start()) { XCTAssertEqual("\($0)", "another HouseBridge is already listening for the HomeKit helper") }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(rc, 0)
        // Two lines in one packet, and one split across two writes.
        let payload = Array("{\"t\":\"hello\"}\n{\"t\":\"a\"}\n{\"t\":".utf8)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        try await Task.sleep(for: .milliseconds(100))
        let rest = Array("\"b\"}\n".utf8)
        _ = rest.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        try await Task.sleep(for: .milliseconds(100))
        close(fd)
        try await Task.sleep(for: .milliseconds(100))
        box.lock.withLock {
            XCTAssertEqual(box.lines, ["{\"t\":\"hello\"}", "{\"t\":\"a\"}", "{\"t\":\"b\"}"])
            XCTAssertEqual(box.counts, [1, 0])
        }
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "stop removes the socket")
    }
}

final class HelperLauncherTests: XCTestCase {
    func testFindsTheHelperInsideTheAppBundleFromEitherExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hb-bundle-\(UUID().uuidString)/HouseBridge.app/Contents")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let menu = root.appendingPathComponent("MacOS/HouseBridge"), ctl = root.appendingPathComponent("MacOS/housebridgectl")

        XCTAssertNil(HomeKitHelperLauncher.helperURL(environment: [:], executable: menu), "no helper bundled yet")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Helpers/HouseBridgeHomeKit.app"), withIntermediateDirectories: true)
        let expected = root.appendingPathComponent("Helpers/HouseBridgeHomeKit.app").resolvingSymlinksInPath().path
        XCTAssertEqual(HomeKitHelperLauncher.helperURL(environment: [:], executable: menu)?.resolvingSymlinksInPath().path, expected)
        XCTAssertEqual(HomeKitHelperLauncher.helperURL(environment: [:], executable: ctl)?.resolvingSymlinksInPath().path, expected)

        // An explicit path wins, and a wrong one finds nothing rather than falling back to something unexpected.
        XCTAssertNil(HomeKitHelperLauncher.helperURL(environment: ["HOUSEBRIDGE_HOMEKIT_HELPER": "/nonexistent/x.app"], executable: menu))
        XCTAssertEqual(HomeKitHelperLauncher.helperURL(environment: ["HOUSEBRIDGE_HOMEKIT_HELPER": root.path], executable: nil)?.path, root.path)
    }
}

final class TemperatureBandTests: XCTestCase {
    func testRedAbove80BlueBelow68GreenBetween() {
        XCTAssertEqual(TemperatureBand(fahrenheit: 80.1), .hot)
        XCTAssertEqual(TemperatureBand(fahrenheit: 80.0), .comfortable, "80 itself is not over 80")
        XCTAssertEqual(TemperatureBand(fahrenheit: 74.6), .comfortable)
        XCTAssertEqual(TemperatureBand(fahrenheit: 68.0), .comfortable, "68 itself is not below 68")
        XCTAssertEqual(TemperatureBand(fahrenheit: 67.9), .cold)
        XCTAssertEqual(TemperatureBand(celsius: 23.87), .comfortable)   // the Owl, 75.0°F
        XCTAssertEqual(TemperatureBand(celsius: 12.6), .cold)           // the USL Environmental, 54.7°F
        XCTAssertEqual(TemperatureBand(celsius: 27.0), .hot)            // 80.6°F
    }
}

// MARK: - UniFi Protect, read directly

final class ProtectSensorTests: XCTestCase {
    func testStatsParsing() {
        // The shape Protect uses: value + status per measurement.
        let full: [String: Any] = ["temperature": ["value": 12.6, "status": "neutral"], "humidity": ["value": 36, "status": "neutral"],
                                   "light": ["value": NSNull(), "status": "unknown"]]
        XCTAssertEqual(ProtectStats.measurements(full), ["temperature": 12.6, "humidity": 36])
        // A live update carries only what changed, and may give a bare number.
        XCTAssertEqual(ProtectStats.measurements(["temperature": ["value": 12.8]]), ["temperature": 12.8])
        XCTAssertEqual(ProtectStats.measurements(["humidity": 41.5]), ["humidity": 41.5])
        // Not numbers: ignored (a Bool is an NSNumber too, and must not become 1).
        XCTAssertEqual(ProtectStats.measurements(["temperature": ["value": true], "humidity": "wet"]), [:])
        XCTAssertEqual(ProtectStats.measurements(nil), [:])
        XCTAssertEqual(ProtectStats.measurements(["wifi": ["signalQuality": 100]]), [:])
    }

    func testLiveUpdateBecomesReadings() {
        let interpreter = ProtectInterpreter()
        interpreter.devices["abc"] = .init(id: "abc", name: "USL Environmental", kind: "sensor")
        interpreter.devices["cam"] = .init(id: "cam", name: "G5 Flex", kind: "camera")
        func update(_ model: String, _ id: String, _ data: [String: Any]) -> ProtectUpdate {
            ProtectUpdate(action: ["action": "update", "modelKey": model, "id": id], data: data)
        }
        let readings = interpreter.readings(update("sensor", "abc", ["stats": ["temperature": ["value": 13.1], "humidity": ["value": 40]]]))
        XCTAssertEqual(readings.map(\.kind), ["humidity", "temperature"])
        XCTAssertEqual(readings.first { $0.kind == "temperature" }?.value, 13.1)
        XCTAssertEqual(readings.first?.accessory, "unifi:abc")
        XCTAssertEqual(readings.first?.name, "USL Environmental")
        XCTAssertTrue(readings.allSatisfy(\.isProtect))
        XCTAssertTrue(interpreter.readings(update("sensor", "abc", ["isMotionDetected": true])).isEmpty, "no stats, no readings")
        XCTAssertTrue(interpreter.readings(update("camera", "cam", ["stats": ["temperature": ["value": 50]]])).isEmpty, "cameras are not sensors")
        XCTAssertTrue(interpreter.readings(update("sensor", "unknown", ["stats": ["temperature": ["value": 1]]])).isEmpty)
    }

    func testStoreKeepsOnlyListedProtectSensorsAndHomeKitOnlyListedAccessories() {
        let s = SensorStore(config: HomeSensorsConfig(devices: ["Owl upstairs Master"], unifi: ["usl environmental"]))
        func protect(_ name: String, _ kind: String = "temperature", _ v: Double = 12.6, at date: Date = Date()) -> SensorReading {
            SensorReading(accessory: "unifi:\(name)", home: "UniFi Protect", name: name, room: "", kind: kind, value: v, date: date)
        }
        XCTAssertTrue(s.ingest(protect: protect("USL Environmental")).changed)
        XCTAssertFalse(s.ingest(protect: protect("UP Sense GarageDoor")).changed, "not listed")
        XCTAssertEqual(s.readings.count, 1)
        // A HomeKit line for the Protect sensor's name is not accepted (it would be the Homebridge duplicate).
        let line = #"{"t":"reading","id":"x","home":"Bend House","name":"USL Environmental","room":"","kind":"temperature","value":1,"reachable":true}"#
        XCTAssertFalse(s.ingest(line: line).changed)
        XCTAssertEqual(s.readings.count, 1)
    }

    func testSteadyValueStillRefreshesTheWindowEveryFewMinutes() {
        let s = SensorStore(config: HomeSensorsConfig(unifi: ["*"]))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func r(_ date: Date, _ v: Double = 12.6) -> SensorReading {
            SensorReading(accessory: "unifi:a", home: "UniFi Protect", name: "S", room: "", kind: "temperature", value: v, date: date)
        }
        XCTAssertTrue(s.ingest(protect: r(t0)).changed)
        XCTAssertFalse(s.ingest(protect: r(t0.addingTimeInterval(20))).changed, "same value seconds later: nothing to redraw")
        XCTAssertTrue(s.ingest(protect: r(t0.addingTimeInterval(300))).changed, "same value 5 minutes later: the 'updated' time moved")
        XCTAssertEqual(s.readings.first?.date, t0.addingTimeInterval(300))
        XCTAssertTrue(s.ingest(protect: r(t0.addingTimeInterval(310), 13.0)).changed)
    }

    func testConfig() throws {
        let unifi = "unifi: { host: 1.1.1.1, username: u, password: p }\n"
        let c = try ConfigLoader.parse(unifi + "home_sensors:\n  unifi: [USL Environmental]\n")
        XCTAssertEqual(c.homeSensors?.unifi, ["USL Environmental"])
        XCTAssertEqual(c.homeSensors?.devices, [])
        XCTAssertEqual(c.homeSensors?.needsHelper, false, "Protect-only needs no HomeKit helper")
        let both = try ConfigLoader.parse(unifi + "home_sensors:\n  devices: [Owl]\n  unifi: [USL Environmental]\n")
        XCTAssertEqual(both.homeSensors?.needsHelper, true)
        XCTAssertThrowsError(try ConfigLoader.parse(unifi + "home_sensors: {}\n"), "needs something to watch")
        XCTAssertThrowsError(try ConfigLoader.parse("home_sensors:\n  unifi: [A]\n"), "Protect sensors need the unifi: section")
        XCTAssertNoThrow(try ConfigLoader.parse("home_sensors:\n  devices: [Owl]\n"), "HomeKit-only needs no unifi: section")
    }

    func testHomeKitLayoutGetsTemperatureAndHumidityServices() throws {
        let sensor = HAPDevice(id: "dev1", name: "USL Environmental", model: "USL Environmental", kind: "sensor",
                               provides: ["contact", "motion", "temperature", "humidity"])
        let built = HAPLayout.build(bridgeName: "HB", bridgeID: "id", devices: [(sensor, 2)], smartDetections: true)
        let accessory = try XCTUnwrap(built.accessories.first { $0.aid == 2 })
        let types = accessory.services.map(\.type)
        XCTAssertTrue(types.contains(HAPLayout.temperatureSensor))
        XCTAssertTrue(types.contains(HAPLayout.humiditySensor))
        XCTAssertEqual(built.routes["dev1|temperature"]?.kind, .temperature)
        XCTAssertEqual(built.routes["dev1|humidity"]?.kind, .humidity)
        // With smart_detections on, "temperature" must not turn into a motion sensor of its own.
        XCTAssertNil(built.routes["dev1|Temperature"])
        XCTAssertEqual(accessory.services.filter { $0.type == HAPLayout.motionSensor }.count, 1)
        // A float characteristic in Celsius that notifies.
        let t = try XCTUnwrap(accessory.services.first { $0.type == HAPLayout.temperatureSensor }?.characteristics.first { $0.type == "11" })
        XCTAssertEqual(t.format, "float")
        XCTAssertEqual(t.extra["unit"] as? String, "celsius")
        XCTAssertTrue(t.notifies)
        XCTAssertEqual(HAPValue.double(12.6).json as? Double, 12.6)
        // A sensor without readings (a door contact) gets neither.
        let door = HAPDevice(id: "dev2", name: "Door", model: "UP Sense", kind: "sensor", provides: ["contact"])
        let plain = HAPLayout.build(bridgeName: "HB", bridgeID: "id", devices: [(door, 2)], smartDetections: false)
        XCTAssertFalse(plain.accessories.flatMap(\.services).contains { $0.type == HAPLayout.temperatureSensor })
    }
}

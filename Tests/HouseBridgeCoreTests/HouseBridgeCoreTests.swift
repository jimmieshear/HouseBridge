import XCTest
@testable import HouseBridgeCore

final class YAMLTests: XCTestCase {
    func testScalarsMapsAndSequences() throws {
        let v = try YAML.parse("""
        a: 1
        b: "two: 2"   # comment
        c: [x, 'y z', 3.5]
        d:
          - name: first
            on: true
          - name: second
        e: { k: v, n: ~ }
        """)
        let m = try XCTUnwrap(v.mapValue)
        XCTAssertEqual(m["a"], .int(1))
        XCTAssertEqual(m["b"], .string("two: 2"))
        XCTAssertEqual(m["c"], .array([.string("x"), .string("y z"), .double(3.5)]))
        XCTAssertEqual(m["d"]?.arrayValue?.count, 2)
        XCTAssertEqual(m["d"]?.arrayValue?[0].mapValue?["on"], .bool(true))
        XCTAssertEqual(m["e"], .map(["k": .string("v"), "n": .null]))
    }

    func testSequenceAtSameIndentAsKey() throws {
        let v = try YAML.parse("rules:\n- a\n- b\nnext: 1\n")
        XCTAssertEqual(v.mapValue?["rules"], .array([.string("a"), .string("b")]))
        XCTAssertEqual(v.mapValue?["next"], .int(1))
    }

    func testIPAddressAndClockStayStrings() throws {
        let v = try YAML.parse("host: 192.168.1.50\nt: 18:00\n")
        XCTAssertEqual(v.mapValue?["host"], .string("192.168.1.50"))
        XCTAssertEqual(v.mapValue?["t"], .string("18:00"))
    }

    func testErrorsCarryLineNumbers() {
        XCTAssertThrowsError(try YAML.parse("a: 1\n\tb: 2\n")) { XCTAssertEqual(($0 as? YAMLError)?.line, 2) }
        XCTAssertThrowsError(try YAML.parse("a: 1\na: 2\n"))
    }
}

final class ConfigTests: XCTestCase {
    func testExampleConfigParses() throws {
        let c = try ConfigLoader.parse(exampleConfig)
        XCTAssertEqual(c.rules.count, 6)
        XCTAssertEqual(c.lutron?.port, 8081)
        XCTAssertEqual(c.rules[4].trigger.source, .unifi)
        XCTAssertEqual(c.rules[4].trigger.input, "person")
        XCTAssertNotNil(c.rules[4].between)
    }

    func testTypoIsReportedWithSuggestion() {
        let text = """
        hue: { host: 1.2.3.4 }
        rules:
          - name: x
            when: { pico: P, buton: on }
            then: [ { action: log, message: hi } ]
        """
        XCTAssertThrowsError(try ConfigLoader.parse(text)) {
            XCTAssertTrue("\($0)".contains("did you mean 'button'"), "\($0)")
        }
    }

    func testRuleNeedingMissingSectionIsRejected() {
        let text = """
        rules:
          - name: x
            when: { unifi: Cam }
            then: [ { action: log, message: hi } ]
        """
        XCTAssertThrowsError(try ConfigLoader.parse(text))
    }

    func testTimeWindowWrapsMidnight() {
        let w = TimeWindow(startMinutes: 18 * 60, endMinutes: 6 * 60)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .gmt
        func at(_ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h))! }
        XCTAssertTrue(w.contains(at(23), calendar: cal))
        XCTAssertTrue(w.contains(at(3), calendar: cal))
        XCTAssertFalse(w.contains(at(12), calendar: cal))
    }

    func testMatchingUsesAliasesAndWildcards() {
        let e = TriggerEvent(source: .pico, device: "Family Room Pico", deviceAliases: ["Pico"], input: "on",
                             inputAliases: ["0", "button_0"], kind: "tap")
        func spec(_ d: String?, _ i: String?) -> TriggerSpec { TriggerSpec(source: .pico, device: d, input: i, kind: "tap") }
        XCTAssertTrue(spec("family room pico", "ON").matches(e))
        XCTAssertTrue(spec("Pico", "0").matches(e))
        XCTAssertTrue(spec("*", nil).matches(e))
        XCTAssertFalse(spec("Other", "on").matches(e))
        XCTAssertFalse(spec("Pico", "off").matches(e))
    }
}

final class HueBodyTests: XCTestCase {
    func testBrightnessImpliesOnAndKelvinConvertsToMirek() {
        let body = HueActions.body(for: LightState(on: nil, brightness: 80, colorTempKelvin: 3200, colorHex: nil, transitionMs: 400))
        XCTAssertEqual((body["on"] as? [String: Bool])?["on"], true)
        XCTAssertEqual((body["dimming"] as? [String: Double])?["brightness"], 80)
        XCTAssertEqual((body["color_temperature"] as? [String: Int])?["mirek"], 312)
        XCTAssertEqual((body["dynamics"] as? [String: Int])?["duration"], 400)
    }

    func testZeroBrightnessTurnsOff() {
        let body = HueActions.body(for: LightState(on: nil, brightness: 0))
        XCTAssertEqual((body["on"] as? [String: Bool])?["on"], false)
        XCTAssertNil(body["dimming"])
    }

    func testHexColorToXY() throws {
        let xy = try XCTUnwrap(ColorMath.xy(fromHex: "#FF0000"))
        XCTAssertEqual(xy.x, 0.70, accuracy: 0.02)
        XCTAssertEqual(xy.y, 0.30, accuracy: 0.02)
        XCTAssertNil(ColorMath.xy(fromHex: "red"))
    }
}

final class ProtectTests: XCTestCase {
    private func frame(_ json: Data, deflated: Bool) -> Data {
        var d = Data([1, 1, deflated ? 1 : 0, 0])
        let n = UInt32(json.count)
        d.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
        d.append(json)
        return d
    }

    func testDecodesCompressedFrameProducedByRealZlib() throws {
        // zlib.compress() output from Python for the JSON below.
        let z = Data(base64Encoded: "eJyrViqpLEhVslJQys0vyczPU9JRUEpOzE0tSgSJAVmGIJHiksSiEqCAIYidnF8E0mBqAOLkAiVcUktSk0tCgOYUA8WjlQpSi4qBJsXWAgAr0Bzy")!
        let action = Data(#"{"action":"add","modelKey":"event","id":"ev1"}"#.utf8)
        let packet = frame(action, deflated: false) + frame(z, deflated: true)
        let update = try ProtectPacket.decode(packet)
        XCTAssertEqual(update.action["id"] as? String, "ev1")
        XCTAssertEqual(update.data["camera"] as? String, "cam1")
        XCTAssertEqual(update.data["smartDetectTypes"] as? [String], ["person"])
    }

    func testInterpretsMotionAndSmartDetectLifecycle() throws {
        let interp = ProtectInterpreter()
        interp.devices["cam1"] = .init(id: "cam1", name: "Front Camera", kind: "camera")
        let add = ProtectUpdate(action: ["action": "add", "modelKey": "event", "id": "ev1"],
                                data: ["type": "smartDetectZone", "camera": "cam1", "smartDetectTypes": ["person"]])
        let started = interp.interpret(add)
        XCTAssertEqual(started.map(\.input), ["person"])
        XCTAssertEqual(started.map(\.kind), ["start"])
        XCTAssertEqual(started.first?.device, "Front Camera")
        XCTAssertEqual(started.first?.deviceID, "cam1", "HomeKit routes events by Protect device id")

        // Same event gains a second type, then ends: only the new type starts, then every started type ends.
        let more = interp.interpret(ProtectUpdate(action: ["action": "update", "modelKey": "event", "id": "ev1"],
                                                  data: ["smartDetectTypes": ["person", "vehicle"]]))
        XCTAssertEqual(more.map(\.input), ["vehicle"])
        let ended = interp.interpret(ProtectUpdate(action: ["action": "update", "modelKey": "event", "id": "ev1"],
                                                   data: ["end": 12345]))
        XCTAssertEqual(Set(ended.map(\.input)), ["person", "vehicle"])
        XCTAssertTrue(ended.allSatisfy { $0.kind == "end" })
        // Late updates after the end are ignored.
        XCTAssertTrue(interp.interpret(ProtectUpdate(action: ["action": "update", "modelKey": "event", "id": "ev1"],
                                                     data: ["score": 90])).isEmpty)
    }

    func testSensorContactAndLeak() {
        let interp = ProtectInterpreter()
        interp.devices["s1"] = .init(id: "s1", name: "Back Door", kind: "sensor")
        let open = interp.interpret(ProtectUpdate(action: ["action": "update", "modelKey": "sensor", "id": "s1"], data: ["isOpened": true]))
        XCTAssertEqual(open.first?.input, "contact")
        XCTAssertEqual(open.first?.kind, "open")
        let leak = interp.interpret(ProtectUpdate(action: ["action": "update", "modelKey": "sensor", "id": "s1"], data: ["leakDetectedAt": 1700000000000]))
        XCTAssertEqual(leak.first?.input, "leak")
        XCTAssertEqual(leak.first?.kind, "start")
    }
}

final class LutronActionConfigTests: XCTestCase {
    func testParsesLutronAction() throws {
        let cfg = try ConfigLoader.parse("""
        lutron: { host: 1.1.1.1, ca: /x, cert: /x, key: /x }
        unifi: { host: 3.3.3.3, username: u, password: p }
        rules:
          - name: r
            when: { unifi: Cam, event: motion, state: start }
            then:
              - { action: lutron, switch: Garage Wall, on: true, off_after_seconds: 300 }
        """)
        guard case .lutron(let device, let on, let off)? = cfg.rules.first?.actions.first else { return XCTFail("not a lutron action") }
        XCTAssertEqual(device, "Garage Wall")
        XCTAssertTrue(on)
        XCTAssertEqual(off, 300)
    }

    func testOffAfterRequiresOn() {
        XCTAssertThrowsError(try ConfigLoader.parse("""
        lutron: { host: 1.1.1.1, ca: /x, cert: /x, key: /x }
        unifi: { host: 3.3.3.3, username: u, password: p }
        rules:
          - name: r
            when: { unifi: Cam, event: motion, state: start }
            then:
              - { action: lutron, switch: Garage Wall, on: false, off_after_seconds: 300 }
        """))
    }
}

final class RecordingExecutor: ActionExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var _actions: [Action] = []
    var actions: [Action] { lock.withLock { _actions } }
    func execute(_ action: Action) async throws { lock.withLock { _actions.append(action) } }
}

final class EngineTests: XCTestCase {
    private func config(_ rules: String, extra: String = "") throws -> Config {
        try ConfigLoader.parse("""
        lutron: { host: 1.1.1.1, ca: /x, cert: /x, key: /x }
        hue: { host: 2.2.2.2 }
        unifi: { host: 3.3.3.3, username: u, password: p, clear_after_seconds: 0.2 }
        timing: { double_tap_ms: 120, hold_ms: 150 }
        \(extra)
        rules:
        \(rules)
        """)
    }

    private func press(_ kind: String, button: String = "on") -> TriggerEvent {
        TriggerEvent(source: .pico, device: "Pico", input: button, kind: kind)
    }

    private func makeEngine(_ cfg: Config, _ exec: RecordingExecutor) async -> RuleEngine {
        let engine = RuleEngine(config: cfg, executor: exec, log: { _ in })
        await engine.start()
        return engine
    }

    func testTapFiresImmediatelyWithoutDoubleTapRule() async throws {
        let exec = RecordingExecutor()
        let cfg = try config("""
          - name: tap
            when: { pico: Pico, button: on, gesture: tap }
            then: [ { action: light, light: A, on: true } ]
        """)
        let engine = await makeEngine(cfg, exec)
        engine.submit(press("press")); engine.submit(press("release"))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(exec.actions.count, 1)
        await engine.stop()
    }

    func testDoubleTapSuppressesSingleTap() async throws {
        let exec = RecordingExecutor()
        let cfg = try config("""
          - name: tap
            when: { pico: Pico, button: on, gesture: tap }
            then: [ { action: light, light: Single, on: true } ]
          - name: double
            when: { pico: Pico, button: on, gesture: double_tap }
            then: [ { action: light, light: Double, on: true } ]
        """)
        let engine = await makeEngine(cfg, exec)
        engine.submit(press("press")); engine.submit(press("release"))
        try await Task.sleep(for: .milliseconds(40))
        engine.submit(press("press")); engine.submit(press("release"))
        try await Task.sleep(for: .milliseconds(250))
        let names = exec.actions.compactMap { a -> String? in if case .light(let t, _) = a { return t.lights.first } else { return nil } }
        XCTAssertEqual(names, ["Double"])

        engine.submit(press("press")); engine.submit(press("release"))
        try await Task.sleep(for: .milliseconds(250))
        let after = exec.actions.compactMap { a -> String? in if case .light(let t, _) = a { return t.lights.first } else { return nil } }
        XCTAssertEqual(after, ["Double", "Single"])
        await engine.stop()
    }

    func testHoldRepeatsDimUntilRelease() async throws {
        let exec = RecordingExecutor()
        let cfg = try config("""
          - name: raise
            when: { pico: Pico, button: raise, gesture: hold }
            then: [ { action: dim, room: R, direction: up, step: 5, repeat_while_held: true, interval_ms: 40 } ]
        """)
        let engine = await makeEngine(cfg, exec)
        engine.submit(press("press", button: "raise"))
        try await Task.sleep(for: .milliseconds(300))   // hold at 150ms, then ~3 repeats
        engine.submit(press("release", button: "raise"))
        try await Task.sleep(for: .milliseconds(60))
        let count = exec.actions.count
        XCTAssertGreaterThanOrEqual(count, 2)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(exec.actions.count, count, "dimming should stop after release")
        await engine.stop()
    }

    func testUnifiClearIsSynthesizedAndCancelledByNewMotion() async throws {
        let exec = RecordingExecutor()
        let cfg = try config("""
          - name: off
            when: { unifi: Cam, event: person, state: clear }
            then: [ { action: light, room: Porch, on: false } ]
        """)
        let engine = await makeEngine(cfg, exec)
        func ev(_ kind: String) -> TriggerEvent { TriggerEvent(source: .unifi, device: "Cam", input: "person", kind: kind) }
        engine.submit(ev("start")); engine.submit(ev("end"))
        try await Task.sleep(for: .milliseconds(100))
        engine.submit(ev("start"))                         // activity resumes before clear_after_seconds
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(exec.actions.count, 0)
        engine.submit(ev("end"))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(exec.actions.count, 1)
        await engine.stop()
    }

    func testCooldownSuppressesRepeatTriggers() async throws {
        let exec = RecordingExecutor()
        let cfg = try config("""
          - name: motion
            cooldown_seconds: 5
            when: { unifi: Cam, event: motion }
            then: [ { action: light, light: L, on: true } ]
        """)
        let engine = await makeEngine(cfg, exec)
        let e = TriggerEvent(source: .unifi, device: "Cam", input: "motion", kind: "start")
        engine.submit(e); engine.submit(e)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(exec.actions.count, 1)
        await engine.stop()
    }
}

final class LutronPathTests: XCTestCase {
    private func makeDir(_ files: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files { try Data("x".utf8).write(to: dir.appendingPathComponent(f)) }
        return dir
    }

    func testCertsDirRecognisesHomeAssistantNames() throws {
        let dir = try makeDir(["lutron_caseta-abc-ca.pem", "lutron_caseta-abc-cert.pem", "lutron_caseta-abc-key.pem", "notes.txt"])
        let c = try ConfigLoader.parse("lutron: { host: 1.2.3.4, certs_dir: \(dir.path) }")
        XCTAssertEqual(URL(fileURLWithPath: c.lutron!.caPath).lastPathComponent, "lutron_caseta-abc-ca.pem")
        XCTAssertEqual(URL(fileURLWithPath: c.lutron!.certPath).lastPathComponent, "lutron_caseta-abc-cert.pem")
        XCTAssertEqual(URL(fileURLWithPath: c.lutron!.keyPath).lastPathComponent, "lutron_caseta-abc-key.pem")
        XCTAssertTrue(c.lutron!.missingFiles().isEmpty)
    }

    func testExplicitPathOverridesAndRelativePathsUseConfigFolder() throws {
        let dir = try makeDir(["a-ca.pem", "a-cert.pem", "a-key.pem", "mine.key"])
        let c = try ConfigLoader.parse("lutron: { host: h, certs_dir: ., key: mine.key }", baseDirectory: dir)
        XCTAssertEqual(URL(fileURLWithPath: c.lutron!.keyPath).lastPathComponent, "mine.key")
        XCTAssertEqual(URL(fileURLWithPath: c.lutron!.caPath).lastPathComponent, "a-ca.pem")
    }

    func testMissingFilesAreReportedNotFatal() throws {
        let c = try ConfigLoader.parse("lutron: { host: h, ca: /nope/ca.pem, cert: /nope/c.pem, key: /nope/k.pem }")
        XCTAssertEqual(c.lutron!.missingFiles().count, 3)
        let d = try ConfigLoader.parse("lutron: { host: h, certs_dir: /no/such/folder }")
        XCTAssertEqual(d.lutron!.missingFiles().count, 3)
    }

    func testNoCertSettingsIsAnError() {
        XCTAssertThrowsError(try ConfigLoader.parse("lutron: { host: h }")) {
            XCTAssertTrue("\($0)".contains("certs_dir"), "\($0)")
        }
    }
}

final class PasswordResolutionTests: XCTestCase {
    func testFileThenEnvThenKeychainOrder() throws {
        var cfg = UnifiConfig(host: "hb-test-host-\(UUID().uuidString)", username: "u")
        cfg.password = "from-file"
        XCTAssertEqual(cfg.resolvedPassword(), "from-file")
        cfg.password = nil
        cfg.passwordEnv = "HB_TEST_MISSING_ENV_VAR"
        XCTAssertNil(cfg.resolvedPassword())   // nothing in file/env/keychain
        cfg.passwordEnv = "PATH"
        XCTAssertEqual(cfg.resolvedPassword(), ProcessInfo.processInfo.environment["PATH"])
    }
}

final class KeychainRoundTripTests: XCTestCase {
    func testSaveReadReplaceDelete() throws {
        let service = "housebridge.test.\(UUID().uuidString)"
        let host = "10.0.0.1", user = "tester"
        defer { _ = try? Keychain.deletePassword(host: host, username: user, service: service) }
        do { try Keychain.savePassword("one", host: host, username: user, service: service) }
        catch { throw XCTSkip("Keychain not writable in this environment: \(error)") }
        XCTAssertEqual(Keychain.readPassword(host: host, username: user, service: service), "one")
        try Keychain.savePassword("two", host: host, username: user, service: service)
        XCTAssertEqual(Keychain.readPassword(host: host, username: user, service: service), "two")
        XCTAssertTrue(try Keychain.deletePassword(host: host, username: user, service: service))
        XCTAssertNil(Keychain.readPassword(host: host, username: user, service: service))
    }
}

final class LoggingTests: XCTestCase {
    func testFileLogWritesAndRotates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hb-log-\(UUID().uuidString)")
        let log = FileLog(directory: dir, maxBytes: 300, keep: 2)
        for i in 0..<30 { log.write(category: "t", message: "line \(i) " + String(repeating: "x", count: 20)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("housebridge.log").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("housebridge.log.1").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("housebridge.log.3").path))
        XCTAssertTrue(log.tail(lines: 3).contains("line 29"))
    }

    func testSanitizeHidesSecrets() {
        let text = "unifi:\n  username: bob\n  password: hunter2\n  password_env: X\nhue: { appKey: abc }\n"
        let clean = Diagnostics.sanitize(text)
        XCTAssertFalse(clean.contains("hunter2"))
        XCTAssertFalse(clean.contains("abc"))
        XCTAssertTrue(clean.contains("username: bob"))
    }

    func testDescribeErrorIncludesDomainAndURL() {
        let e = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://10.0.0.5/api"])
        let d = describeError(e)
        XCTAssertTrue(d.contains("NSURLErrorDomain"), d)
        XCTAssertTrue(d.contains("https://10.0.0.5/api"), d)
    }

    func testTimeoutFires() async {
        do {
            _ = try await withTimeout(0.1) { try await Task.sleep(for: .seconds(5)); return 1 }
            XCTFail("should have timed out")
        } catch { XCTAssertTrue(error is TimeoutError) }
    }
}

final class CycleScenesTests: XCTestCase {
    func testNextSceneWrapsBothWays() {
        let names = ["Read", "Relax", "Energize"]
        XCTAssertEqual(HueActions.nextScene(in: names, current: "Read", step: 1), "Relax")
        XCTAssertEqual(HueActions.nextScene(in: names, current: "energize", step: 1), "Read")
        XCTAssertEqual(HueActions.nextScene(in: names, current: "Read", step: -1), "Energize")
        XCTAssertEqual(HueActions.nextScene(in: names, current: nil, step: 1), "Read")
        XCTAssertEqual(HueActions.nextScene(in: names, current: nil, step: -1), "Energize")
        XCTAssertEqual(HueActions.nextScene(in: names, current: "Unknown", step: 1), "Read")
        XCTAssertNil(HueActions.nextScene(in: [], current: nil, step: 1))
    }

    func testConfigParsesCycleScenes() throws {
        let c = try ConfigLoader.parse("""
        hue: { host: h }
        lutron: { host: h, ca: /a, cert: /b, key: /c }
        rules:
          - name: next
            when: { pico: P, button: raise }
            then: [ { action: cycle_scenes, room: Den, scenes: [A, B], direction: next } ]
          - name: prev
            when: { pico: P, button: lower }
            then: [ { action: cycle_scenes, zone: Upstairs, direction: previous } ]
        """)
        guard case .cycleScenes(let room, _, let scenes, let step) = c.rules[0].actions[0] else { return XCTFail() }
        XCTAssertEqual(room, "Den"); XCTAssertEqual(scenes, ["A", "B"]); XCTAssertEqual(step, 1)
        guard case .cycleScenes(_, let zone, _, let back) = c.rules[1].actions[0] else { return XCTFail() }
        XCTAssertEqual(zone, "Upstairs"); XCTAssertEqual(back, -1)
        XCTAssertThrowsError(try ConfigLoader.parse("""
        hue: { host: h }
        lutron: { host: h, ca: /a, cert: /b, key: /c }
        rules:
          - name: bad
            when: { pico: P }
            then: [ { action: cycle_scenes, scenes: [A] } ]
        """))
    }

    func testFavoriteResetBody() {
        let body = HueActions.body(for: LightState(on: true, brightness: 100, colorTempKelvin: 3655))
        XCTAssertEqual((body["color_temperature"] as? [String: Int])?["mirek"], 273)
        XCTAssertEqual((body["dimming"] as? [String: Double])?["brightness"], 100)
    }
}

final class CatalogTests: XCTestCase {
    func testPicoAndSwitchEntries() {
        var inv = LutronInventory()
        inv.devices = [
            LutronDevice(href: "/device/5", name: "Pico", fullName: "Den Pico", type: "Pico3ButtonRaiseLower", model: "PJ2-3BRL", zoneHref: nil),
            LutronDevice(href: "/device/6", name: "Dimmer", fullName: "Den Dimmer", type: "WallDimmer", model: "DVRF", zoneHref: "/zone/1"),
        ]
        inv.buttons = [LutronButton(href: "/button/1", number: 0, deviceHref: "/device/5"),
                       LutronButton(href: "/button/2", number: 3, deviceHref: "/device/5")]
        let entries = Catalog.lutronEntries(inv)
        XCTAssertEqual(entries.count, 2)
        let pico = entries.first { $0.kind == "Remote" }!
        XCTAssertTrue(pico.provides.contains { $0.contains("“on”") && $0.contains("double_tap") })
        XCTAssertTrue(pico.provides.contains { $0.contains("“raise”") })
        XCTAssertTrue(pico.snippet.contains("pico: \"Den Pico\""))
        XCTAssertEqual(entries.first { $0.kind == "Wired dimmer" }?.name, "Den Dimmer")
    }

    func testSnippetsAreValidConfigWhenPlaceholdersFilled() throws {
        var hue = HueInventory()
        var light = HueInventory.Item(id: "l1", name: "Lamp \"A\"", groupedLightId: nil)
        light.details = ["on / off", "brightness 0–100%", "color temperature 2000–6535 K"]
        hue.lights = [light]
        hue.rooms = [HueInventory.Item(id: "r1", name: "Den", groupedLightId: "g1")]
        hue.scenes = [HueInventory.SceneItem(id: "s1", name: "Read", groupName: "Den")]
        let hueEntries = Catalog.hueEntries(hue)
        XCTAssertEqual(Set(hueEntries.map(\.kind)), ["Light", "Room", "Scene"])

        let unifi = Catalog.unifiEntries(ProtectInventory(items: [
            .init(id: "c1", name: "Front Door", model: "G6 Pro", kind: "camera", provides: ["motion", "person"], details: [])]))
        XCTAssertTrue(unifi[0].provides.contains { $0.hasPrefix("person") })

        // Every generated snippet must parse as a rule once placeholders are filled in.
        let all = hueEntries + unifi + Catalog.lutronEntries({
            var i = LutronInventory()
            i.devices = [LutronDevice(href: "/device/5", name: "Pico", fullName: "Den Pico", type: "Pico", model: "", zoneHref: nil)]
            i.buttons = [LutronButton(href: "/button/1", number: 0, deviceHref: "/device/5")]
            return i
        }())
        for e in all {
            let filled = e.snippet.replacingOccurrences(of: "<hue room>", with: "Den").replacingOccurrences(of: "<remote>", with: "Den Pico")
                .replacingOccurrences(of: "<scene>", with: "Read").replacingOccurrences(of: "<room>", with: "Den")
                .replacingOccurrences(of: "<hue zone>", with: "Upstairs").replacingOccurrences(of: "<camera>", with: "Front Door")
            let indented = filled.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n")
            let text = """
            lutron: { host: h, ca: /a, cert: /b, key: /c }
            hue: { host: h }
            unifi: { host: h, username: u }
            rules:
            \(indented)
            """
            XCTAssertNoThrow(try ConfigLoader.parse(text), "snippet for \(e.name) did not parse:\n\(e.snippet)")
        }
    }
}

final class ExampleRuleTests: XCTestCase {
    private func parse(_ snippet: String) throws -> Config {
        let filled = snippet.replacingOccurrences(of: "<hue room>", with: "Den").replacingOccurrences(of: "<scene>", with: "Read")
        let indented = filled.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n")
        return try ConfigLoader.parse("lutron: { host: h, ca: /a, cert: /b, key: /c }\nhue: { host: h }\nrules:\n" + indented)
    }

    func testFiveButtonPicoExampleCyclesScenesAndResets() throws {
        let snippet = Catalog.picoSnippet(shortName: "Den Pico", fullName: "Den Pico", buttons: ["on", "favorite", "off", "raise", "lower"])
        let c = try parse(snippet)
        func actions(_ button: String, _ gesture: String) -> [Action] {
            c.rules.filter { $0.trigger.input == button && $0.trigger.kind == gesture }.flatMap(\.actions)
        }
        guard case .cycleScenes(_, _, _, let next)? = actions("raise", "tap").first else { return XCTFail("raise/tap should cycle") }
        guard case .cycleScenes(_, _, _, let prev)? = actions("lower", "tap").first else { return XCTFail("lower/tap should cycle") }
        XCTAssertEqual(next, 1); XCTAssertEqual(prev, -1)
        guard case .light(_, let state)? = actions("favorite", "tap").first else { return XCTFail("favorite should reset") }
        XCTAssertEqual(state.colorTempKelvin, 3655); XCTAssertEqual(state.brightness, 100)
        XCTAssertFalse(actions("raise", "hold").isEmpty)    // hold-to-dim coexists with tap-to-cycle
        XCTAssertFalse(actions("on", "double_tap").isEmpty)
    }

    func testTwoButtonPicoOmitsSceneCyclingAndStillParses() throws {
        let snippet = Catalog.picoSnippet(shortName: "Hall Pico", fullName: "Hall Pico", buttons: ["on", "off"])
        XCTAssertFalse(snippet.contains("cycle_scenes"))
        XCTAssertEqual(try parse(snippet).rules.first?.trigger.input, "on")
    }

    func testRoomExampleUsesRealSceneNames() throws {
        var inv = HueInventory()
        inv.rooms = [HueInventory.Item(id: "r", name: "Den", groupedLightId: "g")]
        inv.scenes = ["Read", "Relax", "Energize"].map { HueInventory.SceneItem(id: $0, name: $0, groupName: "Den") }
        let room = Catalog.hueEntries(inv).first { $0.kind == "Room" }!
        XCTAssertTrue(room.snippet.contains("scenes: [\"Energize\", \"Read\", \"Relax\"]"), room.snippet)
        let remoteFilled = room.snippet.replacingOccurrences(of: "<remote>", with: "Den Pico")
        XCTAssertNoThrow(try parse(remoteFilled))
    }
}

final class RoomGuessTests: XCTestCase {
    func testNameMatcher() {
        let rooms = ["Master Bedroom", "Guest Bedroom", "Family Room", "Front Porch", "Front Hall", "Kitchen"]
        XCTAssertEqual(NameMatcher.bestMatch(for: "Master Bedroom", in: rooms), "Master Bedroom")
        XCTAssertEqual(NameMatcher.bestMatch(for: "Master Bedroom Pico", in: rooms), "Master Bedroom")
        XCTAssertEqual(NameMatcher.bestMatch(for: "family room", in: rooms), "Family Room")
        XCTAssertEqual(NameMatcher.bestMatch(for: "Kitchen Dimmer", in: rooms), "Kitchen")
        XCTAssertNil(NameMatcher.bestMatch(for: "Front Camera", in: rooms))   // Porch vs Hall: ambiguous, so no guess
        XCTAssertNil(NameMatcher.bestMatch(for: "Garage", in: rooms))
    }

    func testPicoExampleGetsRealRoomAndSceneFilledIn() throws {
        var hue = HueInventory()
        hue.rooms = ["Master Bedroom", "Family Room"].map { HueInventory.Item(id: $0, name: $0, groupedLightId: "g") }
        hue.scenes = [HueInventory.SceneItem(id: "1", name: "Relax", groupName: "Master Bedroom"),
                      HueInventory.SceneItem(id: "2", name: "Bright", groupName: "Master Bedroom")]
        var lutron = LutronInventory()
        lutron.devices = [LutronDevice(href: "/device/9", name: "Pico", fullName: "Master Bedroom Pico", type: "Pico3ButtonRaiseLower",
                                       model: "", zoneHref: nil, area: "Master Bedroom")]
        lutron.buttons = [0, 1, 2, 3, 4].map { LutronButton(href: "/button/\($0)", number: $0, deviceHref: "/device/9") }
        let filled = Catalog.fillGuesses(Catalog.lutronEntries(lutron), hue: hue, picos: lutron.picos)
        let snippet = try XCTUnwrap(filled.first).snippet
        XCTAssertFalse(snippet.contains("<hue room>"), snippet)
        XCTAssertTrue(snippet.contains("room: \"Master Bedroom\""))
        XCTAssertTrue(snippet.contains("name: \"Bright\""))         // first scene A–Z
        XCTAssertTrue(snippet.hasPrefix("# Hue room “Master Bedroom” was guessed"), snippet)
        let indented = snippet.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n")
        XCTAssertNoThrow(try ConfigLoader.parse("lutron: { host: h, ca: /a, cert: /b, key: /c }\nhue: { host: h }\nrules:\n" + indented))
    }

    func testRoomEntryGuessesTheRemoteAndNoGuessListsOptions() {
        var hue = HueInventory()
        hue.rooms = [HueInventory.Item(id: "r", name: "Family Room", groupedLightId: "g")]
        hue.scenes = ["A", "B"].map { HueInventory.SceneItem(id: $0, name: $0, groupName: "Family Room") }
        let picos = [LutronDevice(href: "/device/1", name: "Pico", fullName: "Family Room Pico", type: "Pico", model: "", zoneHref: nil, area: "Family Room")]
        let room = Catalog.fillGuesses(Catalog.hueEntries(hue), hue: hue, picos: picos).first { $0.kind == "Room" }!
        XCTAssertTrue(room.snippet.contains("pico: \"Family Room Pico\""), room.snippet)

        let lonely = Catalog.fillGuesses(Catalog.hueEntries(hue), hue: hue, picos: []).first { $0.kind == "Room" }!
        XCTAssertTrue(lonely.snippet.contains("<remote>"))
    }
}

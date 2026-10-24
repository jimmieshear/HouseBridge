import XCTest
@testable import HouseBridgeCore

final class HomebridgeImportTests: XCTestCase {
    let sample = """
    {
      "bridge": { "name": "Homebridge 1A2B", "username": "0E:12:34:56:78:9A", "pin": "031-45-154", "port": 51826 },
      "accessories": [ { "accessory": "HttpSwitch", "name": "Fan" } ],
      "platforms": [
        { "platform": "config", "name": "Config", "port": 8581 },
        { "platform": "UniFi Protect",
          "controllers": [
            { "address": "https://192.168.1.1/", "username": "homebridge", "password": "s3cret \\"quoted\\"", "name": "Main" },
            { "address": "10.0.0.2", "username": "other", "password": "x" }
          ],
          "options": ["Disable.Video", "Enable.Motion.Sensor"] }
      ]
    }
    """

    func testParsesControllerBridgeAndFlagsTheRest() throws {
        let imported = try HomebridgeImport.parse(Data(sample.utf8))
        XCTAssertEqual(imported.bridgeName, "Homebridge 1A2B")
        XCTAssertEqual(imported.controllers.count, 2)
        XCTAssertEqual(imported.primary, .init(host: "192.168.1.1", username: "homebridge", password: "s3cret \"quoted\"", name: "Main"))
        XCTAssertEqual(imported.pluginOptions, ["Disable.Video", "Enable.Motion.Sensor"])
        XCTAssertEqual(imported.unmigrated, ["accessory “HttpSwitch”"], "the Config UI X platform is not worth reporting")
        let report = imported.report(source: "test", accessories: ["a", "b"])
        XCTAssertTrue(report.contains("2 accessories"))
        XCTAssertTrue(report.contains("not written to the YAML"))
        XCTAssertFalse(report.contains("s3cret"))
    }

    func testGeneratedYAMLLoadsAndNeverContainsThePassword() throws {
        let yaml = try HomebridgeImport.parse(Data(sample.utf8)).yaml(source: "test")
        XCTAssertFalse(yaml.contains("s3cret"))
        let config = try ConfigLoader.parse(yaml)
        XCTAssertEqual(config.unifi?.host, "192.168.1.1")
        XCTAssertEqual(config.unifi?.username, "homebridge")
        XCTAssertEqual(config.homekit?.name, "HouseBridge")
        XCTAssertTrue(config.rules.isEmpty)
        XCTAssertTrue(yaml.contains("10.0.0.2"), "skipped controllers are mentioned")
    }

    func testHomeKitNameAvoidsClashingWithTheOldBridge() throws {
        var imported = try HomebridgeImport.parse(Data(sample.utf8))
        imported.bridgeName = "housebridge"
        XCTAssertEqual(try ConfigLoader.parse(imported.yaml(source: "t")).homekit?.name, "HouseBridge Protect")
    }

    func testHostsAreNormalised() {
        XCTAssertEqual(HomebridgeImport.normalizeHost("https://192.168.1.1/proxy"), "192.168.1.1")
        XCTAssertEqual(HomebridgeImport.normalizeHost(" udm.local "), "udm.local")
    }

    func testConfigWithoutProtectIsRejectedAndListsWhatItHas() {
        let other = #"{"platforms":[{"platform":"Hue"}],"accessories":[{"accessory":"Thing"}]}"#
        XCTAssertThrowsError(try HomebridgeImport.parse(Data(other.utf8))) { error in
            XCTAssertTrue("\(error)".contains("Hue") && "\(error)".contains("Thing"), "\(error)")
        }
        XCTAssertThrowsError(try HomebridgeImport.parse(Data("[1,2]".utf8)))
    }

    func testControllerNeedsAddressAndUsername() {
        let incomplete = #"{"platforms":[{"platform":"UniFi Protect","controllers":[{"address":"1.2.3.4"}]}]}"#
        XCTAssertThrowsError(try HomebridgeImport.parse(Data(incomplete.utf8)))
    }

    func testSSOUsernameIsFlagged() throws {
        let sso = #"{"platforms":[{"platform":"UniFi Protect","controllers":[{"address":"1.2.3.4","username":"me@example.com","password":"p"}]}]}"#
        XCTAssertTrue(try HomebridgeImport.parse(Data(sso.utf8)).report(source: "t").contains("SSO"))
    }
}

final class ConfigAppendTests: XCTestCase {
    var dir: URL!
    var url: URL { dir.appendingPathComponent("config.yaml") }
    let imported: HomebridgeImport = {
        var i = HomebridgeImport()
        i.bridgeName = "Homebridge Bend House"
        i.controllers = [.init(host: "10.42.1.1", username: "r2d2", password: "pw", name: nil)]
        return i
    }()
    let existing = """
    # my config, with comments that must survive
    lutron:
      host: 192.168.1.20
      certs_dir: ~/.config/housebridge/lutron
    hue:
      host: 192.168.1.21
    timing: { double_tap_ms: 250 }
    rules:
      - name: Family room - on
        when: { pico: Family Room Pico, button: on, gesture: tap }
        then:
          - action: light
            room: Family Room
            on: true
    """

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("append-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testCreatesWhenMissing() throws {
        let outcome = try ConfigAppend.apply(imported, source: "test", to: url)
        XCTAssertEqual(outcome.action, .created)
        let config = try ConfigLoader.load(from: url)
        XCTAssertEqual(config.unifi?.host, "10.42.1.1")
        XCTAssertEqual(config.homekit?.name, "HouseBridge")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as? Int, 0o600)
    }

    func testAppendsWithoutChangingAnythingThatWasThere() throws {
        try existing.write(to: url, atomically: true, encoding: .utf8)   // note: no trailing newline
        let outcome = try ConfigAppend.apply(imported, source: "http://vm:8581", to: url)
        XCTAssertEqual(outcome.action, .appended)
        XCTAssertEqual(outcome.added, ["unifi", "homekit"])

        let merged = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(merged.hasPrefix(existing), "the original text is a byte-for-byte prefix")
        XCTAssertTrue(merged.contains("# Imported from Homebridge (http://vm:8581)"))
        let config = try ConfigLoader.load(from: url)
        XCTAssertEqual(config.unifi?.username, "r2d2")
        XCTAssertEqual(config.rules.count, 1)
        XCTAssertEqual(config.hue?.host, "192.168.1.21")
        XCTAssertEqual(config.timing.doubleTapMs, 250)

        let backup = try XCTUnwrap(outcome.backup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), existing)
    }

    func testRunningTwiceIsANoOp() throws {
        try existing.write(to: url, atomically: true, encoding: .utf8)
        _ = try ConfigAppend.apply(imported, source: "t", to: url)
        let once = try String(contentsOf: url, encoding: .utf8)
        let again = try ConfigAppend.apply(imported, source: "t", to: url)
        XCTAssertEqual(again.action, .nothingToDo)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), once)
    }

    func testExistingSectionsAreLeftAloneAndOnlyTheMissingOneIsAdded() throws {
        let withUnifi = existing + "\nunifi:\n  host: 10.9.9.9\n  username: someoneelse\n"
        try withUnifi.write(to: url, atomically: true, encoding: .utf8)
        let outcome = try ConfigAppend.apply(imported, source: "t", to: url)
        XCTAssertEqual(outcome.added, ["homekit"])
        XCTAssertEqual(outcome.skipped, ["unifi"])
        let config = try ConfigLoader.load(from: url)
        XCTAssertEqual(config.unifi?.host, "10.9.9.9", "existing unifi section is never replaced")
        XCTAssertNotNil(config.homekit)
    }

    func testInvalidExistingConfigIsRefusedAndUntouched() throws {
        let broken = "lutron:\n  host: 1.2.3.4\n\tbad: tab\n"
        try broken.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigAppend.apply(imported, source: "t", to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), broken)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["config.yaml"], "no stray backup")
    }

    func testExistingConfigThatDoesNotLoadIsRefusedEvenIfAppendingWouldFixIt() throws {
        try "homekit:\n  name: Mine\n".write(to: url, atomically: true, encoding: .utf8)
        // homekit without unifi does not load, so the existing file is refused rather than guessed at
        XCTAssertThrowsError(try ConfigAppend.apply(imported, source: "t", to: url))
    }
}

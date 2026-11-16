import XCTest
@testable import HouseBridgeCore

final class LutronPairingTests: XCTestCase {
    func testButtonPressDetection() {
        let pressed: [String: Any] = ["Header": ["ContentType": "status;plurality=single"],
                                      "Body": ["Status": ["Permissions": ["PhysicalAccess"]]]]
        let waiting: [String: Any] = ["Header": ["ContentType": "status;plurality=single"],
                                      "Body": ["Status": ["Permissions": ["Public"]]]]
        XCTAssertTrue(LutronPairing.isButtonPress(pressed))
        XCTAssertFalse(LutronPairing.isButtonPress(waiting))
        XCTAssertFalse(LutronPairing.isButtonPress([:]))
    }

    func testRequestAndResult() throws {
        let req = LutronPairing.certificateRequest(csr: "CSR")
        XCTAssertEqual(((req["Header"] as? [String: Any])?["ClientTag"]) as? String, "get-cert")
        XCTAssertEqual((((req["Body"] as? [String: Any])?["Parameters"]) as? [String: Any])?["CSR"] as? String, "CSR")
        let reply: [String: Any] = ["Body": ["SigningResult": ["Certificate": "C", "RootCertificate": "R"]]]
        let r = try LutronPairing.signingResult(reply)
        XCTAssertEqual(r.cert, "C"); XCTAssertEqual(r.root, "R")
        XCTAssertThrowsError(try LutronPairing.signingResult(["Header": ["StatusCode": "403 Forbidden"]]))
    }

    func testEmbeddedIdentityLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (n, t) in [("ca.pem", LutronPairingAssets.ca), ("cert.pem", LutronPairingAssets.cert), ("key.pem", LutronPairingAssets.key)] {
            try t.write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8)
        }
        XCTAssertNoThrow(try LeapIdentity.load(certPath: dir.appendingPathComponent("cert.pem").path,
                                               keyPath: dir.appendingPathComponent("key.pem").path,
                                               caPath: dir.appendingPathComponent("ca.pem").path))
    }

    func testSaveWritesPrivateKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lutron-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try LutronPairing.save(LutronCredentials(ca: "A", cert: "B", key: "C", leapVersion: nil), to: dir)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("key.pem").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}

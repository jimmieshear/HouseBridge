import XCTest
@testable import HouseBridgeCore

final class HAPCameraTests: XCTestCase {
    var directory: URL!
    var server: HAPServer!
    var built: HAPLayout.Built!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hapcam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        server = HAPServer(store: HAPStore(url: directory.appendingPathComponent("homekit.json"), setupCode: HAPProtocolTests.code))
        built = HAPLayout.build(bridgeName: "Test Bridge", bridgeID: "id", devices: [
            (HAPDevice(id: "cam1", name: "Front Camera", model: "G4", kind: "camera", provides: ["motion"]), 2),
            (HAPDevice(id: "door1", name: "Door", model: "Sensor", kind: "sensor", provides: ["contact"]), 3),
        ], smartDetections: false, cameras: true)
        server.setAccessories(built.accessories)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func pairedController() -> TestController {
        let c = TestController(server: server)
        XCTAssertTrue(c.pair(code: HAPProtocolTests.code)); XCTAssertTrue(c.verify())
        return c
    }

    private func characteristic(_ type: String) throws -> HAPCharacteristic {
        try XCTUnwrap(built.accessories[1].services.flatMap(\.characteristics).first { $0.type == type })
    }

    func testOnlyCamerasGetCameraServicesAndOnlyWhenEnabled() throws {
        XCTAssertEqual(built.accessories[1].services.map(\.type), ["3E", "85", "110", "112"])
        XCTAssertEqual(built.accessories[2].services.map(\.type), ["3E", "80"], "sensors are untouched")
        XCTAssertEqual(built.cameras, [2: "cam1"])
        let off = HAPLayout.build(bridgeName: "B", bridgeID: "id", devices: [(HAPDevice(id: "cam1", name: "C", model: "", kind: "camera", provides: ["motion"]), 2)],
                                  smartDetections: false)
        XCTAssertEqual(off.accessories[1].services.map(\.type), ["3E", "85"], "off by default")
        XCTAssertTrue(off.cameras.isEmpty)
    }

    func testCameraTLVsDecode() throws {
        let video = try XCTUnwrap(TLV8.dictionary(HAPCamera.supportedVideoConfiguration(width: 1920, height: 1080, fps: 24)))
        let codec = try XCTUnwrap(TLV8.dictionary(try XCTUnwrap(video[1])))
        XCTAssertEqual(codec[1], Data([0]), "H.264")
        let attributes = try XCTUnwrap(TLV8.dictionary(try XCTUnwrap(codec[3])))
        XCTAssertEqual(attributes[1], Data([0x80, 0x07]), "1920 little-endian"); XCTAssertEqual(attributes[2], Data([0x38, 0x04])); XCTAssertEqual(attributes[3], Data([24]))
        XCTAssertEqual(TLV8.dictionary(HAPCamera.supportedRTPConfiguration())?[2], Data([0]), "AES_CM_128_HMAC_SHA1_80")
        XCTAssertEqual(TLV8.dictionary(HAPCamera.streamingStatus())?[1], Data([0]))
        let audio = try XCTUnwrap(TLV8.dictionary(HAPCamera.supportedAudioConfiguration()))
        XCTAssertEqual(TLV8.dictionary(try XCTUnwrap(audio[1]))?[1], Data([3]), "Opus")
    }

    func testRefusalEchoesTheSessionId() {
        let session = Data((0..<16).map(UInt8.init))
        let request = HAPCamera.tlv([(1, session), (3, Data([1, 2, 3]))])
        let answer = HAPCamera.refuseSetup(request).flatMap(TLV8.dictionary)
        XCTAssertEqual(answer?[1], session); XCTAssertEqual(answer?[2], Data([2]), "status: error")
        XCTAssertNil(HAPCamera.refuseSetup(HAPCamera.tlv([(1, Data([1]))])), "session id must be 16 bytes")
        XCTAssertNil(HAPCamera.refuseSetup(Data([1])), "garbage")
    }

    func testDatabaseCarriesTLVCharacteristicsAsBase64() throws {
        let c = pairedController()
        let root = try XCTUnwrap(c.json(c.request("GET", "/accessories"))["accessories"] as? [[String: Any]])
        let services = try XCTUnwrap(root[1]["services"] as? [[String: Any]])
        let management = try XCTUnwrap(services.first { $0["type"] as? String == "110" })
        let video = try XCTUnwrap((management["characteristics"] as? [[String: Any]])?.first { $0["type"] as? String == "114" })
        XCTAssertEqual(video["format"] as? String, "tlv8")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(video["value"] as? String)), HAPCamera.supportedVideoConfiguration())
    }

    func testSetupEndpointsWriteIsHandedOverAndTheAnswerIsReadBack() throws {
        let c = pairedController()
        let setup = try characteristic("118")
        let key = HAPCharKey(aid: 2, iid: setup.iid)
        var written: HAPValue?
        server.onWrite = { k, v in
            guard k == key else { return }
            written = v
            self.server.setValue(key, .data(HAPCamera.refuseSetup(try! XCTUnwrap({ if case .data(let d) = v { d } else { nil } }())) ?? Data()))
        }
        let session = Data(repeating: 7, count: 16)
        let body = try JSONSerialization.data(withJSONObject: ["characteristics": [["aid": 2, "iid": setup.iid, "value": HAPCamera.tlv([(1, session)]).base64EncodedString()]]])
        XCTAssertEqual(c.request("PUT", "/characteristics", body: body, type: "application/hap+json").status, 204)
        XCTAssertEqual(written, .data(HAPCamera.tlv([(1, session)])))
        let read = c.json(c.request("GET", "/characteristics?id=2.\(setup.iid)"))
        let value = try XCTUnwrap(((read["characteristics"] as? [[String: Any]])?.first?["value"]) as? String)
        XCTAssertEqual(TLV8.dictionary(try XCTUnwrap(Data(base64Encoded: value)))?[2], Data([2]))

        // read-only TLV characteristics refuse writes
        let video = try characteristic("114")
        let bad = try JSONSerialization.data(withJSONObject: ["characteristics": [["aid": 2, "iid": video.iid, "value": "AA=="]]])
        XCTAssertEqual(c.request("PUT", "/characteristics", body: bad).status, 207)
    }

    func testWritesCarryTheWritersIdentityAndAddressAndCloseIsReported() throws {
        let c = pairedController()
        c.connection.localAddress = "10.0.0.2"
        let setup = try characteristic("118"), selected = try characteristic("117")
        var seen: [(String, ObjectIdentifier?, String?)] = []
        server.onWrite = { key, _ in
            let name = key.iid == setup.iid ? "setup" : key.iid == selected.iid ? "selected" : "?"
            seen.append((name, self.server.activeWriter?.id, self.server.activeWriter?.localAddress))
        }
        for iid in [setup.iid, selected.iid] {
            let body = try JSONSerialization.data(withJSONObject: ["characteristics": [["aid": 2, "iid": iid, "value": "AQID"]]])
            XCTAssertEqual(c.request("PUT", "/characteristics", body: body).status, 204)
        }
        XCTAssertEqual(seen.map(\.0), ["setup", "selected"])
        XCTAssertTrue(seen.allSatisfy { $0.1 == ObjectIdentifier(c.connection) && $0.2 == "10.0.0.2" })
        XCTAssertNil(server.activeWriter, "only valid while the write is handled")

        var closed: [ObjectIdentifier] = []
        server.onConnectionClosed = { closed.append($0) }
        c.connection.connectionDidClose()
        XCTAssertEqual(closed, [ObjectIdentifier(c.connection)])
    }

    func testLayoutRoutesTheStreamingCharacteristics() throws {
        let selected = try characteristic("117"), setup = try characteristic("118"), status = try characteristic("120")
        XCTAssertEqual(built.selectedStreams, [HAPCharKey(aid: 2, iid: selected.iid): 2])
        XCTAssertEqual(built.setupEndpoints, [HAPCharKey(aid: 2, iid: setup.iid): 2])
        XCTAssertEqual(built.streamingStatus[2], HAPCharKey(aid: 2, iid: status.iid))
    }

    func testSnapshotIsServedAsynchronouslyAndHoldsLaterRequestsBack() throws {
        let c = pairedController()
        var pending: ((Data?) -> Void)?
        var asked: (Int, Int, Int)?
        server.snapshot = { aid, w, h, done in asked = (aid, w, h); pending = done }

        let body = try JSONSerialization.data(withJSONObject: ["resource-type": "image", "image-width": 640, "image-height": 360, "aid": 2])
        let first = c.request("POST", "/resource", body: body, type: "application/hap+json")
        XCTAssertEqual(first.status, 0, "no answer yet")
        XCTAssertEqual(asked?.0, 2); XCTAssertEqual(asked?.1, 640); XCTAssertEqual(asked?.2, 360)

        // A request that arrives meanwhile waits for the image to go out first.
        XCTAssertEqual(c.request("GET", "/characteristics?id=1.3").status, 0)

        let jpeg = Data((0..<3000).map { UInt8($0 % 251) })   // bigger than one encrypted frame
        pending?(jpeg)
        var out = c.takeResponse()
        XCTAssertEqual(out.status, 200)
        XCTAssertFalse(out.body.isEmpty)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: out.body), "the held-back request was answered after the image")

        // The image itself, on a fresh exchange
        asked = nil
        _ = c.request("POST", "/resource", body: body)
        pending?(jpeg)
        out = c.takeResponse()
        XCTAssertEqual(out.status, 200); XCTAssertEqual(out.body, jpeg)
    }

    func testSnapshotFailureAndBadRequests() throws {
        let c = pairedController()
        server.snapshot = { _, _, _, done in done(nil) }
        let ok = try JSONSerialization.data(withJSONObject: ["resource-type": "image", "image-width": 640, "image-height": 360, "aid": 2])
        XCTAssertEqual(c.request("POST", "/resource", body: ok).status, 500)
        for bad in [["resource-type": "image", "image-width": 0, "image-height": 360, "aid": 2],
                    ["resource-type": "image", "image-width": 99999, "image-height": 360, "aid": 2],
                    ["resource-type": "video", "image-width": 640, "image-height": 360, "aid": 2],
                    ["resource-type": "image", "image-width": 640, "image-height": 360]] as [[String: Any]] {
            XCTAssertEqual(c.request("POST", "/resource", body: try JSONSerialization.data(withJSONObject: bad)).status, 400)
        }
        // unpaired connections get nothing
        let stranger = TestController(server: server)
        XCTAssertEqual(stranger.request("POST", "/resource", body: ok).status, 470)
    }

    func testConfigFlag() throws {
        XCTAssertFalse(try ConfigLoader.parse("unifi: { host: 3.3.3.3, username: u, password: p }\nhomekit: { name: HB }").homekit!.cameras)
        XCTAssertTrue(try ConfigLoader.parse("unifi: { host: 3.3.3.3, username: u, password: p }\nhomekit: { name: HB, cameras: true }").homekit!.cameras)
    }
}

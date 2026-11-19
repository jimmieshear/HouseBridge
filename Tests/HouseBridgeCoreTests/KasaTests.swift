import XCTest
@testable import HouseBridgeCore

final class KasaTests: XCTestCase {
    func testXORKnownVector() {
        // Widely published first bytes of the encrypted {"system":{"get_sysinfo":{}}} request.
        let enc = KasaXOR.encrypt(KasaCommand.iotInfo)
        XCTAssertEqual(Array(enc.prefix(4)), [0xd0, 0xf2, 0x81, 0xf8])
        XCTAssertEqual(KasaXOR.decrypt(enc), KasaCommand.iotInfo)
        XCTAssertEqual(Array(KasaXOR.frame(Data("{}".utf8)).prefix(4)), [0, 0, 0, 2])
    }

    func testKlapSessionRoundTrip() throws {
        let auth = KlapCrypto.authHash(username: "a@b.c", password: "pw")
        let local = Data(repeating: 1, count: 16), remote = Data(repeating: 2, count: 16)
        var client = KlapSession(local: local, remote: remote, authHash: auth)
        let server = KlapSession(local: local, remote: remote, authHash: auth)
        let (seq, payload) = try client.encrypt(KasaCommand.smartInfo)
        XCTAssertEqual(try server.decrypt(payload, seq: seq), KasaCommand.smartInfo)
        let (seq2, _) = try client.encrypt(Data("x".utf8))
        XCTAssertEqual(seq2, seq &+ 1)
    }

    func testKlapV1HashVectorAndProofs() {
        // md5(md5(user) + md5(password)), checked against Python hashlib.
        let v1 = KlapCrypto.authHashV1(username: "a@b.c", password: "pw")
        XCTAssertEqual(v1.map { String(format: "%02x", $0) }.joined(), "375e949ab68ef9492f765c4c1e4c7fb6")
        let v2 = KlapCrypto.authHash(username: "a@b.c", password: "pw")
        let local = Data(repeating: 1, count: 16), remote = Data(repeating: 2, count: 16)
        // v1 proofs omit one seed; v2 proofs use both.
        XCTAssertEqual(KlapCrypto.serverProof(local: local, remote: remote, auth: v1), KlapCrypto.sha256(local + v1))
        XCTAssertEqual(KlapCrypto.clientProof(local: local, remote: remote, auth: v1), KlapCrypto.sha256(remote + v1))
        XCTAssertEqual(KlapCrypto.serverProof(local: local, remote: remote, auth: v2), KlapCrypto.sha256(local + remote + v2))
        XCTAssertEqual(KlapCrypto.clientProof(local: local, remote: remote, auth: v2), KlapCrypto.sha256(remote + local + v2))
        XCTAssertEqual(KlapCrypto.authHashes(username: "a@b.c", password: "pw"), [v2, v1])
    }

    func testReplyParsing() {
        let iot = Data(#"{"system":{"get_sysinfo":{"alias":"Patio","model":"KP125(US)","relay_state":1}}}"#.utf8)
        XCTAssertEqual(KasaCommand.parseIOTInfo(iot)?.isOn, true)
        XCTAssertEqual(KasaCommand.parseIOTInfo(iot)?.name, "Patio")
        let smart = Data(#"{"error_code":0,"result":{"device_on":false,"model":"KP125M","nickname":"UGF0aW8="}}"#.utf8)
        XCTAssertEqual(KasaCommand.parseSmartInfo(smart)?.name, "Patio")
        XCTAssertEqual(KasaCommand.parseSmartInfo(smart)?.isOn, false)
        XCTAssertNil(KasaCommand.parseSmartInfo(iot))
        XCTAssertTrue(KasaCommand.iotSetSucceeded(Data(#"{"system":{"set_relay_state":{"err_code":0}}}"#.utf8)))
        XCTAssertFalse(KasaCommand.smartSetSucceeded(Data(#"{"error_code":-1012}"#.utf8)))
    }

    func testConfigAndValidation() throws {
        let base = """
        kasa:
          username: me@example.com
          plugs:
            - { name: Patio Plug, host: 192.168.1.70 }
        rules:
          - name: patio
            when: { at: "18:00" }
            then:
              - { action: plug, device: patio plug, on: true, off_after_seconds: 600 }
        """
        let c = try ConfigLoader.parse(base)
        XCTAssertEqual(c.kasa?.plugs.first?.host, "192.168.1.70")
        guard case .plug(let d, true, 600)? = c.rules.first?.actions.first else { return XCTFail("expected plug action") }
        XCTAssertEqual(d, "patio plug")
        XCTAssertEqual(c.rules.first?.actions.first?.targets.plugs, ["patio plug"])

        XCTAssertThrowsError(try ConfigLoader.parse(base.replacingOccurrences(of: "device: patio plug", with: "device: Garage")))
        let noKasa = "rules:\n  - name: x\n    when: { at: \"18:00\" }\n    then:\n      - { action: plug, device: P }\n"
        XCTAssertThrowsError(try ConfigLoader.parse(noKasa))
    }

    func testPlugAsHomeKitOutlet() throws {
        let yaml = """
        unifi: { host: 3.3.3.3, username: u, password: p }
        homekit: { name: HB }
        kasa:
          plugs:
            - { name: Outdoor, host: 10.0.0.5, homekit: true }
            - { name: Hidden, host: 10.0.0.6 }
        """
        let c = try ConfigLoader.parse(yaml)
        XCTAssertEqual(c.homekitOutlets, ["Outdoor"])

        // Needs a homekit: section.
        XCTAssertThrowsError(try ConfigLoader.parse("kasa:\n  plugs:\n    - { name: Outdoor, host: 10.0.0.5, homekit: true }\n"))

        let built = HAPLayout.build(bridgeName: "HB", bridgeID: "id", devices: [], smartDetections: false, outlets: [(name: "Outdoor", aid: 7)])
        let key = built.outlets["outdoor"]
        XCTAssertNotNil(key)
        let accessory = built.accessories.first { $0.aid == 7 }
        XCTAssertEqual(accessory?.services.last?.type, "47")   // Outlet
        let on = accessory?.services.flatMap(\.characteristics).first { $0.iid == key?.iid }
        XCTAssertEqual(on?.type, "25")
        XCTAssertEqual(on?.perms, ["pr", "pw", "ev"])
    }
}

private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [ConnectionStatus] = []
    var items: [ConnectionStatus] { lock.withLock { _items } }
    func add(_ s: ConnectionStatus) { lock.withLock { _items.append(s) } }
}

final class KasaMonitorTests: XCTestCase {
    func testUnreachablePlugTurnsStatusRedOnceAndKeepsWatching() async throws {
        let config = try XCTUnwrap(ConfigLoader.parse("kasa:\n  plugs:\n    - { name: Gone, host: 127.0.0.1 }\n").kasa)
        let statuses = StatusLog()
        let bridge = KasaBridge(config: config, log: { _ in }, status: { statuses.add($0) })
        let task = Task { await bridge.monitor() }
        defer { task.cancel() }
        for _ in 0..<80 where !statuses.items.contains(.disconnected("can't reach Gone")) { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(statuses.items, [.connecting, .disconnected("can't reach Gone")])   // reported once, not on every pass
    }
}

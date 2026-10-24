import XCTest
import CryptoKit
@testable import HouseBridgeCore

/// Plays the iOS side of HomeKit pairing and sessions against `HAPServer`, in memory.
final class TestController {
    let server: HAPServer
    let connection: HAPConnection
    var wire = Data()
    var closed = false
    let identifier = UUID().uuidString
    let signing = Curve25519.Signing.PrivateKey()
    var readKey: SymmetricKey?    // accessory -> controller
    var writeKey: SymmetricKey?   // controller -> accessory
    var readCounter: UInt64 = 0
    var writeCounter: UInt64 = 0
    var events: [[String: Any]] = []

    init(server: HAPServer) {
        self.server = server
        connection = server.newConnection()
        connection.send = { [unowned self] data, close in wire.append(data); if close { closed = true } }
        connection.close = { [unowned self] in closed = true }
    }

    // MARK: Plain HTTP

    func request(_ method: String, _ path: String, body: Data = Data(), type: String? = nil) -> (status: Int, body: Data) {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: test\r\nContent-Length: \(body.count)\r\n"
        if let type { head += "Content-Type: \(type)\r\n" }
        let bytes = Data((head + "\r\n").utf8) + body
        wire = Data()
        if let writeKey {
            for start in stride(from: 0, to: bytes.count, by: 1024) {
                let chunk = Data(bytes[start..<min(start + 1024, bytes.count)])
                let aad = Data([UInt8(chunk.count & 0xFF), UInt8(chunk.count >> 8)])
                let sealed = try! HAPCrypto.seal(chunk, key: writeKey, nonce: HAPCrypto.counterNonce(writeCounter), aad: aad)
                writeCounter += 1
                connection.receive(aad + sealed)
            }
        } else {
            connection.receive(bytes)
        }
        return takeResponse()
    }

    /// Reads whatever the server wrote: HTTP responses and EVENT messages, decrypting if a session exists.
    func takeResponse() -> (status: Int, body: Data) {
        var data = wire
        wire = Data()
        if let readKey {
            var out = Data()
            while data.count >= 2 {
                let length = Int(data[data.startIndex]) | Int(data[data.startIndex + 1]) << 8
                let aad = Data(data.prefix(2))
                let body = Data(data[(data.startIndex + 2)..<(data.startIndex + 2 + length + 16)])
                out += try! HAPCrypto.open(body, key: readKey, nonce: HAPCrypto.counterNonce(readCounter), aad: aad)
                readCounter += 1
                data = Data(data.dropFirst(2 + length + 16))
            }
            data = out
        }
        var result: (Int, Data) = (0, Data())
        while !data.isEmpty {
            let end = data.range(of: Data("\r\n\r\n".utf8))!
            let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
            let first = head.components(separatedBy: "\r\n")[0]
            let length = Int(head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length") }!
                .split(separator: ":")[1].trimmingCharacters(in: .whitespaces))!
            let body = Data(data[end.upperBound..<data.index(end.upperBound, offsetBy: length)])
            data = Data(data[data.index(end.upperBound, offsetBy: length)...])
            if first.hasPrefix("EVENT/1.0") {
                let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
                events += json["characteristics"] as! [[String: Any]]
            } else {
                result = (Int(first.split(separator: " ")[1])!, body)
            }
        }
        return result
    }

    func tlvPost(_ path: String, _ items: [(TLV8.Tag, Data)]) -> [UInt8: Data] {
        let r = request("POST", path, body: TLV8.encode(items), type: "application/pairing+tlv8")
        XCTAssertEqual(r.status, 200)
        return TLV8.dictionary(r.body) ?? [:]
    }

    // MARK: Pairing

    @discardableResult
    func pair(code: String) -> Bool {
        let m2 = tlvPost("/pair-setup", [(.state, Data([1])), (.method, Data([0]))])
        guard let B = m2[TLV8.Tag.publicKey.rawValue], let salt = m2[TLV8.Tag.salt.rawValue] else { return false }
        let client = SRP.Client(password: code)
        let (K, proof) = client.session(salt: salt, serverPublic: B)
        let m4 = tlvPost("/pair-setup", [(.state, Data([3])), (.publicKey, client.publicKey), (.proof, proof)])
        guard m4[TLV8.Tag.error.rawValue] == nil, m4[TLV8.Tag.proof.rawValue] != nil else { return false }

        let key = HAPCrypto.hkdf(K, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let x = HAPCrypto.keyData(HAPCrypto.hkdf(K, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info"))
        let id = Data(identifier.utf8), ltpk = signing.publicKey.rawRepresentation
        let signature = try! signing.signature(for: x + id + ltpk)
        let sealed = try! HAPCrypto.seal(TLV8.encode([(.identifier, id), (.publicKey, ltpk), (.signature, Data(signature))]),
                                         key: key, nonce: HAPCrypto.labelNonce("PS-Msg05"))
        let m6 = tlvPost("/pair-setup", [(.state, Data([5])), (.encryptedData, sealed)])
        guard let encrypted = m6[TLV8.Tag.encryptedData.rawValue],
              let opened = try? HAPCrypto.open(encrypted, key: key, nonce: HAPCrypto.labelNonce("PS-Msg06")),
              let inner = TLV8.dictionary(opened) else { return false }
        let accessoryX = HAPCrypto.keyData(HAPCrypto.hkdf(K, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info"))
        let accessoryKey = try! Curve25519.Signing.PublicKey(rawRepresentation: inner[TLV8.Tag.publicKey.rawValue]!)
        XCTAssertEqual(String(decoding: inner[TLV8.Tag.identifier.rawValue]!, as: UTF8.self), server.store.state.deviceID)
        return accessoryKey.isValidSignature(inner[TLV8.Tag.signature.rawValue]!,
                                             for: accessoryX + inner[TLV8.Tag.identifier.rawValue]! + inner[TLV8.Tag.publicKey.rawValue]!)
    }

    @discardableResult
    func verify() -> Bool {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let mine = ephemeral.publicKey.rawRepresentation
        let m2 = tlvPost("/pair-verify", [(.state, Data([1])), (.publicKey, mine)])
        guard let theirs = m2[TLV8.Tag.publicKey.rawValue], let encrypted = m2[TLV8.Tag.encryptedData.rawValue] else { return false }
        let shared = try! ephemeral.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: theirs)).withUnsafeBytes { Data($0) }
        let key = HAPCrypto.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        guard let opened = try? HAPCrypto.open(encrypted, key: key, nonce: HAPCrypto.labelNonce("PV-Msg02")),
              let inner = TLV8.dictionary(opened) else { return false }
        let accessoryKey = server.store.signingKey.publicKey
        XCTAssertTrue(accessoryKey.isValidSignature(inner[TLV8.Tag.signature.rawValue]!,
                                                    for: theirs + inner[TLV8.Tag.identifier.rawValue]! + mine))
        let id = Data(identifier.utf8)
        let signature = try! signing.signature(for: mine + id + theirs)
        let sealed = try! HAPCrypto.seal(TLV8.encode([(.identifier, id), (.signature, Data(signature))]),
                                         key: key, nonce: HAPCrypto.labelNonce("PV-Msg03"))
        let m4 = tlvPost("/pair-verify", [(.state, Data([3])), (.encryptedData, sealed)])
        guard m4[TLV8.Tag.error.rawValue] == nil else { return false }
        readKey = HAPCrypto.hkdf(shared, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
        writeKey = HAPCrypto.hkdf(shared, salt: "Control-Salt", info: "Control-Write-Encryption-Key")
        return true
    }

    func json(_ r: (status: Int, body: Data)) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
    }
}

final class HAPProtocolTests: XCTestCase {
    static let code = "031-45-154"
    var directory: URL!
    var server: HAPServer!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        server = HAPServer(store: HAPStore(url: directory.appendingPathComponent("homekit.json"), setupCode: Self.code))
        let devices = [
            (device: HAPDevice(id: "cam1", name: "Front Camera", model: "G4 Doorbell", kind: "camera", provides: ["motion", "person", "ring"]), aid: 2),
            (device: HAPDevice(id: "door1", name: "Garage Door", model: "UP Sensor", kind: "sensor", provides: ["contact", "motion", "tamper"]), aid: 3),
        ]
        let built = HAPLayout.build(bridgeName: "Test Bridge", bridgeID: server.store.state.deviceID, devices: devices, smartDetections: true)
        server.setAccessories(built.accessories)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testPairVerifyAndEncryptedSession() throws {
        let c = TestController(server: server)
        XCTAssertEqual(c.request("GET", "/accessories").status, 470, "unpaired connections must not read the database")
        XCTAssertTrue(c.pair(code: Self.code))
        XCTAssertEqual(server.store.state.pairings.map(\.id), [c.identifier])
        XCTAssertTrue(c.verify())

        // Accessory database
        let accessories = try XCTUnwrap(c.json(c.request("GET", "/accessories"))["accessories"] as? [[String: Any]])
        XCTAssertEqual(accessories.map { $0["aid"] as? Int }, [1, 2, 3])
        let camera = try XCTUnwrap(accessories[1]["services"] as? [[String: Any]])
        XCTAssertEqual(camera.map { $0["type"] as? String }, ["3E", "85", "89", "85"])   // info, motion, doorbell, person

        // Find the camera's motion characteristic and read it
        let motionKey = try XCTUnwrap(server.accessories[1].services[1].characteristics.last).iid
        let read = c.json(c.request("GET", "/characteristics?id=2.\(motionKey)"))
        XCTAssertEqual((read["characteristics"] as? [[String: Any]])?.first?["value"] as? Bool, false)

        // Subscribe, then a state change arrives as an EVENT over the encrypted session
        let subscribe = try JSONSerialization.data(withJSONObject: ["characteristics": [["aid": 2, "iid": motionKey, "ev": true]]])
        XCTAssertEqual(c.request("PUT", "/characteristics", body: subscribe, type: "application/hap+json").status, 204)
        server.setValue(HAPCharKey(aid: 2, iid: motionKey), .bool(true))
        _ = c.takeResponse()
        XCTAssertEqual(c.events.count, 1)
        XCTAssertEqual(c.events.first?["value"] as? Bool, true)
        server.setValue(HAPCharKey(aid: 2, iid: motionKey), .bool(true))   // unchanged: no event
        _ = c.takeResponse()
        XCTAssertEqual(c.events.count, 1)

        // Writes to read-only characteristics and unknown ones are reported per item
        let bad = try JSONSerialization.data(withJSONObject: ["characteristics": [["aid": 2, "iid": motionKey, "value": true], ["aid": 9, "iid": 1, "value": 1]]])
        let r = c.request("PUT", "/characteristics", body: bad, type: "application/hap+json")
        XCTAssertEqual(r.status, 207)
        XCTAssertEqual((c.json(r)["characteristics"] as? [[String: Any]])?.compactMap { $0["status"] as? Int }, [-70404, -70409])

        // A large response is split into several encrypted frames and still reassembles
        XCTAssertGreaterThan(server.accessoriesJSON().count, 1024)
    }

    func testStatelessSwitchEventIsDeliveredWithoutChangingValue() throws {
        let c = TestController(server: server)
        XCTAssertTrue(c.pair(code: Self.code)); XCTAssertTrue(c.verify())
        let button = try XCTUnwrap(server.accessories[1].services[2].characteristics.last).iid
        let sub = try JSONSerialization.data(withJSONObject: ["characteristics": [["aid": 2, "iid": button, "ev": true]]])
        XCTAssertEqual(c.request("PUT", "/characteristics", body: sub).status, 204)
        server.fireEvent(HAPCharKey(aid: 2, iid: button), value: .int(0))
        _ = c.takeResponse()
        XCTAssertEqual(c.events.first?["value"] as? Int, 0)
        XCTAssertEqual(server.value(HAPCharKey(aid: 2, iid: button)), .null)
    }

    func testWrongSetupCodeIsRejected() {
        let c = TestController(server: server)
        XCTAssertFalse(c.pair(code: "031-45-155"))
        XCTAssertTrue(server.store.state.pairings.isEmpty)
        XCTAssertEqual(server.failedAttemptsForTests, 1)
    }

    func testPairSetupUnavailableOnceMessagesArePaired() {
        let first = TestController(server: server)
        XCTAssertTrue(first.pair(code: Self.code))
        let second = TestController(server: server)
        let r = second.request("POST", "/pair-setup", body: TLV8.encode([(.state, Data([1])), (.method, Data([0]))]))
        XCTAssertEqual(TLV8.dictionary(r.body)?[TLV8.Tag.error.rawValue], Data([6]))
    }

    func testUnknownControllerCannotVerify() {
        let c = TestController(server: server)
        XCTAssertFalse(c.verify())
    }

    func testListAndRemovePairingsOverSession() {
        let c = TestController(server: server)
        XCTAssertTrue(c.pair(code: Self.code)); XCTAssertTrue(c.verify())
        let listed = TLV8.decode(c.request("POST", "/pairings", body: TLV8.encode([(.state, Data([1])), (.method, Data([5]))])).body)
        XCTAssertEqual(listed?.first { $0.tag == TLV8.Tag.identifier.rawValue }?.value, Data(c.identifier.utf8))

        let removed = c.request("POST", "/pairings", body: TLV8.encode([(.state, Data([1])), (.method, Data([4])), (.identifier, Data(c.identifier.utf8))]))
        XCTAssertEqual(removed.status, 200)
        XCTAssertFalse(server.store.isPaired)
        XCTAssertTrue(c.closed, "removed controller's connection is dropped")
    }

    func testPairingsSurviveRestart() {
        let c = TestController(server: server)
        XCTAssertTrue(c.pair(code: Self.code))
        let reloaded = HAPStore(url: directory.appendingPathComponent("homekit.json"))
        XCTAssertEqual(reloaded.state.pairings.count, 1)
        XCTAssertEqual(reloaded.state.deviceID, server.store.state.deviceID)
        XCTAssertEqual(reloaded.signingKey.publicKey.rawRepresentation, server.store.signingKey.publicKey.rawRepresentation)
    }

    func testSetupCodeRulesAndURI() {
        XCTAssertTrue(HAPStore.isValidSetupCode("031-45-154"))
        XCTAssertFalse(HAPStore.isValidSetupCode("123-45-678"))
        XCTAssertFalse(HAPStore.isValidSetupCode("111-11-111"))
        XCTAssertFalse(HAPStore.isValidSetupCode("12345678"))
        XCTAssertTrue(HAPStore.isValidSetupCode(HAPStore.generateSetupCode()))
        let uri = server.store.setupURI
        XCTAssertTrue(uri.hasPrefix("X-HM://") && uri.count == 7 + 9 + 4, uri)
        // payload = category 2 << 31 | IP flag 2 << 27 | code 03145154
        XCTAssertEqual(UInt64(uri.dropFirst(7).prefix(9), radix: 36), (2 << 31) | (2 << 27) | 3145154)
    }

    func testLayoutIsStableAndFingerprintTracksShape() {
        let a = server.accessories
        XCTAssertEqual(HAPLayout.fingerprint(a), HAPLayout.fingerprint(a))
        let device = HAPDevice(id: "x", name: "X", model: "", kind: "sensor", provides: ["leak"])
        let more = HAPLayout.build(bridgeName: "Test Bridge", bridgeID: "id", devices: [(device, 2)], smartDetections: false)
        XCTAssertNotEqual(HAPLayout.fingerprint(a), HAPLayout.fingerprint(more.accessories))
        XCTAssertEqual(more.routes["x|leak"]?.kind, .leak)
    }
}

extension HAPServer {
    var failedAttemptsForTests: Int { failedSetupAttempts }
}

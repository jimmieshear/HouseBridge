import Foundation
import CryptoKit

/// The HomeKit Accessory Protocol server, minus the sockets: feed bytes into a `HAPConnection`, write out what it
/// hands back. Not thread-safe; the owner serializes every call (HAPListener uses one dispatch queue).
final class HAPServer {
    let store: HAPStore
    var log: (String) -> Void = { _ in }
    /// Called when pairings change, so the Bonjour record (`sf`) can be refreshed.
    var onPairingsChanged: () -> Void = {}

    private(set) var accessories: [HAPAccessory] = []
    private var characteristics: [HAPCharKey: HAPCharacteristic] = [:]
    private var values: [HAPCharKey: HAPValue] = [:]
    private var connections: [ObjectIdentifier: HAPConnection] = [:]

    /// The connection currently in the middle of Pair Setup (only one at a time is allowed).
    fileprivate weak var setupOwner: HAPConnection?
    var failedSetupAttempts = 0
    static let maxPairings = 16

    init(store: HAPStore) { self.store = store }

    var connectionCount: Int { connections.count }

    /// Replaces the accessory database. Values of characteristics that still exist are kept.
    func setAccessories(_ list: [HAPAccessory]) {
        accessories = list
        var newValues: [HAPCharKey: HAPValue] = [:]
        characteristics = [:]
        for accessory in list {
            for service in accessory.services {
                for c in service.characteristics {
                    let key = HAPCharKey(aid: accessory.aid, iid: c.iid)
                    characteristics[key] = c
                    newValues[key] = values[key] ?? c.initial
                }
            }
        }
        values = newValues
    }

    func newConnection() -> HAPConnection {
        let connection = HAPConnection(server: self)
        connections[ObjectIdentifier(connection)] = connection
        return connection
    }

    func connectionClosed(_ connection: HAPConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        if setupOwner === connection { setupOwner = nil }
    }

    func closeConnections(controller id: String?) {
        for connection in connections.values where id == nil || connection.controllerID == id { connection.close() }
    }

    func characteristic(_ key: HAPCharKey) -> HAPCharacteristic? { characteristics[key] }
    func value(_ key: HAPCharKey) -> HAPValue? { values[key] }

    func accessoriesJSON() -> Data {
        let list = accessories.map { $0.json(values: { self.values[$0] }) }
        return (try? JSONSerialization.data(withJSONObject: ["accessories": list])) ?? Data("{}".utf8)
    }

    /// Stores a new value and tells subscribed controllers if it changed.
    func setValue(_ key: HAPCharKey, _ value: HAPValue) {
        guard characteristics[key] != nil, values[key] != value else { return }
        values[key] = value
        notify(key, value)
    }

    /// Delivers a momentary event (a doorbell press) without changing the stored value.
    func fireEvent(_ key: HAPCharKey, value: HAPValue) {
        guard characteristics[key] != nil else { return }
        notify(key, value)
    }

    private func notify(_ key: HAPCharKey, _ value: HAPValue) {
        let body = try? JSONSerialization.data(withJSONObject: [
            "characteristics": [["aid": key.aid, "iid": key.iid, "value": value.json]],
        ])
        guard let body else { return }
        for connection in connections.values where connection.isSubscribed(to: key) { connection.sendEvent(body) }
    }

    // MARK: Pairings

    fileprivate func addPairing(_ pairing: HAPPairing) {
        store.mutate { state in
            state.pairings.removeAll { $0.id == pairing.id }
            state.pairings.append(pairing)
        }
        onPairingsChanged()
    }

    fileprivate func removePairing(id: String) {
        store.mutate { state in
            state.pairings.removeAll { $0.id == id }
            // Without an admin nobody could manage the rest, so the bridge returns to the unpaired state.
            if !state.pairings.contains(where: \.admin) { state.pairings = [] }
        }
        onPairingsChanged()
    }

    /// Forgets every controller and drops all connections (housebridgectl homekit-reset uses the file directly).
    func removeAllPairings() {
        store.mutate { $0.pairings = [] }
        onPairingsChanged()
        closeConnections(controller: nil)
    }
}

/// An established-session cipher state: one key and message counter per direction.
final class HAPSession {
    let readKey: SymmetricKey      // controller -> accessory
    let writeKey: SymmetricKey     // accessory -> controller
    var readCounter: UInt64 = 0
    var writeCounter: UInt64 = 0
    init(readKey: SymmetricKey, writeKey: SymmetricKey) { self.readKey = readKey; self.writeKey = writeKey }
}

struct HAPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
}

struct HAPResponse {
    var status: Int
    var contentType: String?
    var body = Data()
    /// Switches the connection to encrypted frames once this response has been written.
    var upgrade: HAPSession?
    var closeAfterSend = false
    var afterSend: (() -> Void)?

    static func json(_ object: Any, status: Int = 200) -> HAPResponse {
        HAPResponse(status: status, contentType: "application/hap+json",
                    body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    static func tlv(_ items: [(TLV8.Tag, Data)]) -> HAPResponse {
        HAPResponse(status: 200, contentType: "application/pairing+tlv8", body: TLV8.encode(items))
    }

    static func status(_ code: Int) -> HAPResponse { HAPResponse(status: code) }
}

/// HAP status codes carried in JSON bodies.
enum HAPStatus {
    static let ok = 0
    static let notAllowedInCurrentState = -70405 // read from a write-only characteristic
    static let writeToReadOnly = -70404
    static let notificationNotSupported = -70406
    static let resourceDoesNotExist = -70409
    static let insufficientAuthorization = -70411
    static let invalidValue = -70410
    static let notAllowed = -70401
}

final class HAPConnection {
    private unowned let server: HAPServer
    /// Set by the transport: write bytes to the socket (and optionally close afterwards) / close it.
    var send: (Data, _ thenClose: Bool) -> Void = { _, _ in }
    var close: () -> Void = {}

    private(set) var controllerID: String?
    private var isAdmin = false
    private var subscriptions: Set<HAPCharKey> = []
    private var session: HAPSession?
    private var inbound = Data()
    private var plain = Data()
    private var closed = false

    // Pair Setup / Verify state
    private var srp: SRP.Server?
    private var srpAuthenticated = false
    private var verifyState: (shared: Data, accessoryPublic: Data, controllerPublic: Data, key: SymmetricKey)?

    init(server: HAPServer) { self.server = server }

    var isSecure: Bool { session != nil }

    func isSubscribed(to key: HAPCharKey) -> Bool { session != nil && subscriptions.contains(key) }

    func connectionDidClose() {
        closed = true
        server.connectionClosed(self)
    }

    // MARK: Input

    func receive(_ data: Data) {
        guard !closed else { return }
        inbound.append(data)
        pump()
    }

    private func pump() {
        while !closed {
            if session != nil, !decryptAvailable() { return }
            guard let request = nextRequest() else { return }
            respond(to: request)
        }
    }

    /// Moves every complete encrypted frame from `inbound` into `plain`. False means the stream is corrupt.
    private func decryptAvailable() -> Bool {
        guard let session else { return true }
        while inbound.count >= 2 {
            let length = Int(inbound[inbound.startIndex]) | Int(inbound[inbound.startIndex + 1]) << 8
            guard length <= 1024 else { fail("oversized frame"); return false }
            guard inbound.count >= 2 + length + 16 else { return true }
            let aad = Data(inbound.prefix(2))
            let body = Data(inbound[(inbound.startIndex + 2)..<(inbound.startIndex + 2 + length + 16)])
            guard let opened = try? HAPCrypto.open(body, key: session.readKey,
                                                   nonce: HAPCrypto.counterNonce(session.readCounter), aad: aad) else {
                fail("frame failed authentication"); return false
            }
            session.readCounter += 1
            plain.append(opened)
            inbound = Data(inbound.dropFirst(2 + length + 16))
        }
        return true
    }

    private func fail(_ reason: String) {
        server.log("closing connection: \(reason)")
        closed = true
        close()
    }

    private func nextRequest() -> HAPRequest? {
        let secure = session != nil
        var buffer = secure ? plain : inbound
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 65536 { fail("request header too large") }
            return nil
        }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(end.upperBound, offsetBy: length)
        let body = Data(buffer[end.upperBound..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])
        if secure { plain = buffer } else { inbound = buffer }

        guard requestLine.count >= 2 else { fail("malformed request line"); return nil }
        let components = URLComponents(string: String(requestLine[1]))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HAPRequest(method: String(requestLine[0]), path: components?.path ?? String(requestLine[1]),
                          query: query, headers: headers, body: body)
    }

    // MARK: Output

    private static let reasons = [200: "OK", 204: "No Content", 207: "Multi-Status", 400: "Bad Request", 404: "Not Found",
                                  422: "Unprocessable Entity", 470: "Connection Authorization Required",
                                  500: "Internal Server Error"]

    private func write(_ bytes: Data, thenClose: Bool = false) {
        guard let session else { send(bytes, thenClose); return }
        var offset = bytes.startIndex
        var frames = Data()
        while offset < bytes.endIndex {
            let end = bytes.index(offset, offsetBy: 1024, limitedBy: bytes.endIndex) ?? bytes.endIndex
            let chunk = Data(bytes[offset..<end])
            let aad = Data([UInt8(chunk.count & 0xFF), UInt8(chunk.count >> 8)])
            guard let sealed = try? HAPCrypto.seal(chunk, key: session.writeKey,
                                                   nonce: HAPCrypto.counterNonce(session.writeCounter), aad: aad) else {
                fail("encryption failed"); return
            }
            session.writeCounter += 1
            frames.append(aad)
            frames.append(sealed)
            offset = end
        }
        send(frames, thenClose)
    }

    private func respond(to request: HAPRequest) {
        let response = route(request)
        var head = "HTTP/1.1 \(response.status) \(Self.reasons[response.status] ?? "OK")\r\n"
        if let type = response.contentType { head += "Content-Type: \(type)\r\n" }
        head += "Content-Length: \(response.body.count)\r\nConnection: keep-alive\r\n\r\n"
        write(Data(head.utf8) + response.body, thenClose: response.closeAfterSend)
        if let upgrade = response.upgrade { session = upgrade }
        response.afterSend?()
    }

    func sendEvent(_ body: Data) {
        let head = "EVENT/1.0 200 OK\r\nContent-Type: application/hap+json\r\nContent-Length: \(body.count)\r\n\r\n"
        write(Data(head.utf8) + body)
    }

    // MARK: Routing

    private func route(_ request: HAPRequest) -> HAPResponse {
        switch (request.method, request.path) {
        case ("POST", "/pair-setup"): return pairSetup(request.body)
        case ("POST", "/pair-verify"): return pairVerify(request.body)
        case ("POST", "/identify"):
            if server.store.isPaired { return .json(["status": HAPStatus.notAllowed], status: 400) }
            server.log("identify requested")
            return .status(204)
        default: break
        }
        guard session != nil else { return .json(["status": HAPStatus.insufficientAuthorization], status: 470) }
        switch (request.method, request.path) {
        case ("GET", "/accessories"):
            return HAPResponse(status: 200, contentType: "application/hap+json", body: server.accessoriesJSON())
        case ("GET", "/characteristics"): return readCharacteristics(request.query)
        case ("PUT", "/characteristics"): return writeCharacteristics(request.body)
        case ("POST", "/pairings"): return pairings(request.body)
        default: return .status(404)
        }
    }

    // MARK: Characteristics

    private func parseKey(_ text: Substring) -> HAPCharKey? {
        let parts = text.split(separator: ".")
        guard parts.count == 2, let aid = Int(parts[0]), let iid = Int(parts[1]) else { return nil }
        return HAPCharKey(aid: aid, iid: iid)
    }

    private func readCharacteristics(_ query: [String: String]) -> HAPResponse {
        guard let ids = query["id"] else { return .json(["status": HAPStatus.invalidValue], status: 400) }
        var entries: [[String: Any]] = []
        var failed = false
        for text in ids.split(separator: ",") {
            guard let key = parseKey(text) else { return .json(["status": HAPStatus.invalidValue], status: 400) }
            var entry: [String: Any] = ["aid": key.aid, "iid": key.iid]
            if let c = server.characteristic(key) {
                if c.readable, let value = server.value(key) { entry["value"] = value.json; entry["status"] = HAPStatus.ok }
                else { entry["status"] = HAPStatus.notAllowedInCurrentState; failed = true }
            } else {
                entry["status"] = HAPStatus.resourceDoesNotExist
                failed = true
            }
            entries.append(entry)
        }
        if !failed { entries = entries.map { $0.filter { $0.key != "status" } } }
        return .json(["characteristics": entries], status: failed ? 207 : 200)
    }

    private func writeCharacteristics(_ body: Data) -> HAPResponse {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let items = root["characteristics"] as? [[String: Any]] else {
            return .json(["status": HAPStatus.invalidValue], status: 400)
        }
        var results: [[String: Any]] = []
        var failed = false
        for item in items {
            guard let aid = item["aid"] as? Int, let iid = item["iid"] as? Int else {
                return .json(["status": HAPStatus.invalidValue], status: 400)
            }
            let key = HAPCharKey(aid: aid, iid: iid)
            var status = HAPStatus.ok
            if let c = server.characteristic(key) {
                if let subscribe = item["ev"] as? Bool {
                    if c.notifies { if subscribe { subscriptions.insert(key) } else { subscriptions.remove(key) } }
                    else { status = HAPStatus.notificationNotSupported }
                }
                if status == HAPStatus.ok, item["value"] != nil {
                    if c.type == "14", c.writable { server.log("identify requested by \(controllerID ?? "?")") }
                    else if !c.writable { status = HAPStatus.writeToReadOnly }
                }
            } else {
                status = HAPStatus.resourceDoesNotExist
            }
            if status != HAPStatus.ok { failed = true }
            results.append(["aid": aid, "iid": iid, "status": status])
        }
        return failed ? .json(["characteristics": results], status: 207) : .status(204)
    }

    // MARK: Pair Setup

    private func tlvError(_ state: UInt8, _ code: TLV8.ErrorCode) -> HAPResponse {
        .tlv([(.state, Data([state])), (.error, Data([code.rawValue]))])
    }

    private func pairSetup(_ body: Data) -> HAPResponse {
        guard let tlv = TLV8.dictionary(body), let state = tlv[TLV8.Tag.state.rawValue]?.first else { return .status(400) }
        switch state {
        case 1:
            if server.store.isPaired { return tlvError(2, .unavailable) }
            if let owner = server.setupOwner, owner !== self { return tlvError(2, .busy) }
            if server.failedSetupAttempts >= 100 { return tlvError(2, .maxTries) }
            server.log("pair setup started")
            let srp = SRP.Server(password: server.store.state.setupCode)
            self.srp = srp
            srpAuthenticated = false
            server.setupOwner = self
            return .tlv([(.state, Data([2])), (.publicKey, srp.publicKey), (.salt, srp.salt)])
        case 3:
            guard let srp, let A = tlv[TLV8.Tag.publicKey.rawValue], let proof = tlv[TLV8.Tag.proof.rawValue] else {
                return tlvError(4, .unknown)
            }
            guard srp.setClientPublic(A), let serverProof = srp.verify(clientProof: proof) else {
                server.failedSetupAttempts += 1
                self.srp = nil
                server.setupOwner = nil
                server.log("pair setup failed: wrong setup code")
                return tlvError(4, .authentication)
            }
            srpAuthenticated = true
            return .tlv([(.state, Data([4])), (.proof, serverProof)])
        case 5:
            guard srpAuthenticated, let srp, let K = srp.sessionKey, let encrypted = tlv[TLV8.Tag.encryptedData.rawValue] else {
                return tlvError(6, .unknown)
            }
            let sessionKey = HAPCrypto.hkdf(K, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
            guard let plainTLV = try? HAPCrypto.open(encrypted, key: sessionKey, nonce: HAPCrypto.labelNonce("PS-Msg05")),
                  let inner = TLV8.dictionary(plainTLV),
                  let identifier = inner[TLV8.Tag.identifier.rawValue], let publicKey = inner[TLV8.Tag.publicKey.rawValue],
                  let signature = inner[TLV8.Tag.signature.rawValue],
                  let controllerKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
                return tlvError(6, .authentication)
            }
            let controllerX = HAPCrypto.keyData(HAPCrypto.hkdf(K, salt: "Pair-Setup-Controller-Sign-Salt",
                                                                info: "Pair-Setup-Controller-Sign-Info"))
            guard controllerKey.isValidSignature(signature, for: controllerX + identifier + publicKey) else {
                server.log("pair setup failed: bad controller signature")
                return tlvError(6, .authentication)
            }
            let controllerName = String(decoding: identifier, as: UTF8.self)
            server.addPairing(HAPPairing(id: controllerName, publicKey: publicKey, admin: true))

            let accessoryX = HAPCrypto.keyData(HAPCrypto.hkdf(K, salt: "Pair-Setup-Accessory-Sign-Salt",
                                                               info: "Pair-Setup-Accessory-Sign-Info"))
            let accessoryID = Data(server.store.state.deviceID.utf8)
            let accessoryKey = server.store.signingKey
            let accessoryPublic = accessoryKey.publicKey.rawRepresentation
            guard let accessorySignature = try? accessoryKey.signature(for: accessoryX + accessoryID + accessoryPublic),
                  let sealed = try? HAPCrypto.seal(TLV8.encode([(.identifier, accessoryID), (.publicKey, accessoryPublic),
                                                                (.signature, Data(accessorySignature))]),
                                                   key: sessionKey, nonce: HAPCrypto.labelNonce("PS-Msg06")) else {
                return tlvError(6, .unknown)
            }
            self.srp = nil
            srpAuthenticated = false
            server.setupOwner = nil
            server.failedSetupAttempts = 0
            server.log("paired with \(controllerName)")
            return .tlv([(.state, Data([6])), (.encryptedData, sealed)])
        default:
            return .status(400)
        }
    }

    // MARK: Pair Verify

    private func pairVerify(_ body: Data) -> HAPResponse {
        guard let tlv = TLV8.dictionary(body), let state = tlv[TLV8.Tag.state.rawValue]?.first else { return .status(400) }
        switch state {
        case 1:
            guard let controllerPublic = tlv[TLV8.Tag.publicKey.rawValue],
                  let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: controllerPublic) else {
                return tlvError(2, .unknown)
            }
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            guard let secret = try? ephemeral.sharedSecretFromKeyAgreement(with: peer) else { return tlvError(2, .unknown) }
            let shared = secret.withUnsafeBytes { Data($0) }
            let accessoryPublic = ephemeral.publicKey.rawRepresentation
            let accessoryID = Data(server.store.state.deviceID.utf8)
            let key = HAPCrypto.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
            guard let signature = try? server.store.signingKey.signature(for: accessoryPublic + accessoryID + controllerPublic),
                  let sealed = try? HAPCrypto.seal(TLV8.encode([(.identifier, accessoryID), (.signature, Data(signature))]),
                                                   key: key, nonce: HAPCrypto.labelNonce("PV-Msg02")) else {
                return tlvError(2, .unknown)
            }
            verifyState = (shared, accessoryPublic, controllerPublic, key)
            return .tlv([(.state, Data([2])), (.publicKey, accessoryPublic), (.encryptedData, sealed)])
        case 3:
            guard let v = verifyState, let encrypted = tlv[TLV8.Tag.encryptedData.rawValue],
                  let plainTLV = try? HAPCrypto.open(encrypted, key: v.key, nonce: HAPCrypto.labelNonce("PV-Msg03")),
                  let inner = TLV8.dictionary(plainTLV),
                  let identifier = inner[TLV8.Tag.identifier.rawValue], let signature = inner[TLV8.Tag.signature.rawValue] else {
                return tlvError(4, .authentication)
            }
            let name = String(decoding: identifier, as: UTF8.self)
            guard let pairing = server.store.pairing(id: name),
                  let controllerKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pairing.publicKey),
                  controllerKey.isValidSignature(signature, for: v.controllerPublic + identifier + v.accessoryPublic) else {
                server.log("pair verify failed for \(name) (not paired, or key mismatch)")
                verifyState = nil
                return tlvError(4, .authentication)
            }
            // "Read" and "Write" are named from the controller's side.
            let toController = HAPCrypto.hkdf(v.shared, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
            let fromController = HAPCrypto.hkdf(v.shared, salt: "Control-Salt", info: "Control-Write-Encryption-Key")
            controllerID = name
            isAdmin = pairing.admin
            verifyState = nil
            server.log("\(name) connected")
            var response = HAPResponse.tlv([(.state, Data([4]))])
            response.upgrade = HAPSession(readKey: fromController, writeKey: toController)
            return response
        default:
            return .status(400)
        }
    }

    // MARK: Pairings management

    private func pairings(_ body: Data) -> HAPResponse {
        guard let tlv = TLV8.dictionary(body), let method = tlv[TLV8.Tag.method.rawValue]?.first else { return .status(400) }
        guard isAdmin else { return tlvError(2, .authentication) }
        let identifier = tlv[TLV8.Tag.identifier.rawValue].map { String(decoding: $0, as: UTF8.self) }
        switch method {
        case 3:   // add
            guard let identifier, let publicKey = tlv[TLV8.Tag.publicKey.rawValue],
                  let permissions = tlv[TLV8.Tag.permissions.rawValue]?.first else { return tlvError(2, .unknown) }
            if let existing = server.store.pairing(id: identifier) {
                guard existing.publicKey == publicKey else { return tlvError(2, .unknown) }
            } else if server.store.state.pairings.count >= HAPServer.maxPairings {
                return tlvError(2, .maxPeers)
            }
            server.addPairing(HAPPairing(id: identifier, publicKey: publicKey, admin: permissions == 1))
            server.log("added controller \(identifier)")
            return .tlv([(.state, Data([2]))])
        case 4:   // remove
            guard let identifier else { return tlvError(2, .unknown) }
            server.removePairing(id: identifier)
            server.log("removed controller \(identifier)")
            var response = HAPResponse.tlv([(.state, Data([2]))])
            let server = server
            // The removed controller must lose its session; if that was everyone, every session ends.
            response.afterSend = { server.closeConnections(controller: server.store.isPaired ? identifier : nil) }
            return response
        case 5:   // list
            var items: [(TLV8.Tag, Data)] = [(.state, Data([2]))]
            for (i, p) in server.store.state.pairings.enumerated() {
                if i > 0 { items.append((.separator, Data())) }
                items += [(.identifier, Data(p.id.utf8)), (.publicKey, p.publicKey), (.permissions, Data([p.admin ? 1 : 0]))]
            }
            return .tlv(items)
        default:
            return .status(400)
        }
    }
}

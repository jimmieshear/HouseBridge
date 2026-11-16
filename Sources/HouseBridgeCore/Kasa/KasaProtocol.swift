import Foundation
import CryptoKit
import CommonCrypto
import Network

// TP-Link Kasa local protocols. Older firmware speaks "XOR autokey" over TCP 9999 with no authentication.
// Newer firmware (and most Matter-era plugs, e.g. KP125M) speaks KLAP over HTTP port 80, authenticated with the
// TP-Link/Kasa cloud account's e-mail and password (the plug itself is still controlled locally).

enum KasaError: Error, CustomStringConvertible {
    case timeout(String)
    case auth(String)
    case protocolError(String)
    case unknownPlug(String, available: [String])

    var description: String {
        switch self {
        case .timeout(let s): return "timed out talking to the plug (\(s))"
        case .auth(let s): return "Kasa authentication failed: \(s)"
        case .protocolError(let s): return "unexpected reply from the plug: \(s)"
        case .unknownPlug(let name, let available):
            return "no plug named '\(name)' under 'kasa:'" + (available.isEmpty ? "" : " (configured: \(available.joined(separator: ", ")))")
        }
    }
}

// MARK: - Legacy XOR protocol (TCP 9999)

enum KasaXOR {
    /// Autokey XOR starting at 171; each output byte becomes the next key.
    static func encrypt(_ data: Data) -> Data {
        var key: UInt8 = 171
        return Data(data.map { byte in key ^= byte; return key })
    }

    static func decrypt(_ data: Data) -> Data {
        var key: UInt8 = 171
        return Data(data.map { byte in let plain = key ^ byte; key = byte; return plain })
    }

    /// 4-byte big-endian length, then the encrypted JSON.
    static func frame(_ json: Data) -> Data {
        var out = Data(withUnsafeBytes(of: UInt32(json.count).bigEndian) { Array($0) })
        out.append(encrypt(json))
        return out
    }

    static func exchange(host: String, request: Data, timeout: TimeInterval = 4) async throws -> Data {
        guard let port = NWEndpoint.Port(rawValue: 9999) else { throw KasaError.protocolError("bad port") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "housebridge.kasa.xor")
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let once = Once()
            @Sendable func finish(_ result: Result<Data, Error>) {
                guard once.first() else { return }
                conn.cancel()
                cont.resume(with: result)
            }
            @Sendable func read(_ count: Int, _ then: @escaping @Sendable (Data) -> Void) {
                conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    if let error { return finish(.failure(error)) }
                    guard let data, data.count == count else { return finish(.failure(KasaError.protocolError("connection closed early"))) }
                    then(data)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: frame(request), completion: .contentProcessed { error in
                        if let error { return finish(.failure(error)) }
                        read(4) { header in
                            let length = header.reduce(0) { $0 << 8 | Int($1) }
                            guard length > 0, length < 64 * 1024 else { return finish(.failure(KasaError.protocolError("bad length \(length)"))) }
                            read(length) { body in finish(.success(decrypt(body))) }
                        }
                    })
                case .failed(let error), .waiting(let error): finish(.failure(error))
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(KasaError.timeout("tcp 9999"))) }
        }
    }
}

// MARK: - KLAP (HTTP port 80)

enum KlapCrypto {
    static func sha1(_ d: Data) -> Data { Data(Insecure.SHA1.hash(data: d)) }
    static func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }

    static func md5(_ d: Data) -> Data { Data(Insecure.MD5.hash(data: d)) }

    /// KLAP v2 credential hash (32 bytes).
    static func authHash(username: String, password: String) -> Data {
        sha256(sha1(Data(username.utf8)) + sha1(Data(password.utf8)))
    }

    /// KLAP v1 credential hash (16 bytes). Many Kasa plugs still use v1; `KlapTransport` tells the two apart by length.
    static func authHashV1(username: String, password: String) -> Data {
        md5(md5(Data(username.utf8)) + md5(Data(password.utf8)))
    }

    /// Both variants for one account, since a plug does not say which it speaks until handshake1.
    static func authHashes(username: String, password: String) -> [Data] {
        [authHash(username: username, password: password), authHashV1(username: username, password: password)]
    }

    /// What a factory-fresh or "no account" plug accepts.
    static let fallbackHashes: [Data] =
        authHashes(username: "kasa@tp-link.net", password: "kasaSetup") + authHashes(username: "", password: "")

    /// What a plug sends back in handshake1 to prove it knows `auth`, and what handshake2 must answer. v1 (16-byte hash) omits a seed.
    static func serverProof(local: Data, remote: Data, auth: Data) -> Data {
        auth.count == 16 ? sha256(local + auth) : sha256(local + remote + auth)
    }
    static func clientProof(local: Data, remote: Data, auth: Data) -> Data {
        auth.count == 16 ? sha256(remote + auth) : sha256(remote + local + auth)
    }

    static func aes(_ op: Int, key: Data, iv: Data, _ input: Data) -> Data? {
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(op), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                                inPtr.baseAddress, input.count, outPtr.baseAddress, outPtr.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(written)
    }
}

/// Keys and counters derived from a completed KLAP handshake.
struct KlapSession {
    private let key: Data
    private let baseIV: Data
    private let signature: Data
    private(set) var seq: Int32

    init(local: Data, remote: Data, authHash: Data) {
        let tail = local + remote + authHash
        key = KlapCrypto.sha256(Data("lsk".utf8) + tail).prefix(16)
        let iv = KlapCrypto.sha256(Data("iv".utf8) + tail)
        baseIV = iv.prefix(12)
        seq = iv.suffix(4).reduce(Int32(0)) { $0 << 8 | Int32($1) }   // signed big-endian
        signature = KlapCrypto.sha256(Data("ldk".utf8) + tail).prefix(28)
    }

    private static func bytes(_ seq: Int32) -> Data { Data(withUnsafeBytes(of: seq.bigEndian) { Array($0) }) }

    mutating func encrypt(_ plain: Data) throws -> (seq: Int32, payload: Data) {
        seq = seq &+ 1
        guard let cipher = KlapCrypto.aes(kCCEncrypt, key: key, iv: baseIV + Self.bytes(seq), plain) else {
            throw KasaError.protocolError("encryption failed")
        }
        let sig = KlapCrypto.sha256(signature + Self.bytes(seq) + cipher)
        return (seq, sig + cipher)
    }

    func decrypt(_ payload: Data, seq: Int32) throws -> Data {
        guard payload.count > 32, let plain = KlapCrypto.aes(kCCDecrypt, key: key, iv: baseIV + Self.bytes(seq), payload.dropFirst(32)) else {
            throw KasaError.protocolError("could not decrypt reply")
        }
        return plain
    }
}

/// One HTTP KLAP session to a plug; re-handshakes when the plug drops it.
actor KlapTransport {
    private let host: String
    private let candidates: [Data]
    private var session: KlapSession?
    private var cookie: String?
    private let http: URLSession

    init(host: String, credentials: [Data]) {
        self.host = host
        self.candidates = credentials
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 5
        http = URLSession(configuration: cfg)
    }

    func send(_ json: Data) async throws -> Data {
        if session == nil { try await handshake() }
        do { return try await exchange(json) }
        catch {
            session = nil
            try await handshake()
            return try await exchange(json)
        }
    }

    private func post(_ path: String, _ body: Data) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: "http://\(host)\(path)") else { throw KasaError.protocolError("bad host '\(host)'") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        if let cookie { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await http.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw KasaError.protocolError("not an HTTP reply") }
        return (data, http)
    }

    private func handshake() async throws {
        let local = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        cookie = nil
        let (reply, response) = try await post("/app/handshake1", local)
        guard response.statusCode == 200, reply.count == 48 else {
            throw KasaError.protocolError("handshake1 returned HTTP \(response.statusCode), \(reply.count) bytes (is this a KLAP plug?)")
        }
        if let set = response.value(forHTTPHeaderField: "Set-Cookie"),
           let part = set.split(separator: ";").first(where: { $0.contains("TP_SESSIONID") }) {
            cookie = String(part).trimmingCharacters(in: .whitespaces)
        }
        let remote = reply.prefix(16), serverHash = reply.suffix(32)
        guard let auth = candidates.first(where: { KlapCrypto.serverProof(local: local, remote: Data(remote), auth: $0) == serverHash }) else {
            throw KasaError.auth("the plug rejected the account (tried KLAP v1 and v2). Check the e-mail and password, then set 'kasa.username' to your Kasa/TP-Link account e-mail and store its password with: housebridgectl set-kasa-password")
        }
        let (_, ack) = try await post("/app/handshake2", KlapCrypto.clientProof(local: local, remote: Data(remote), auth: auth))
        guard ack.statusCode == 200 else { throw KasaError.protocolError("handshake2 returned HTTP \(ack.statusCode)") }
        session = KlapSession(local: local, remote: Data(remote), authHash: auth)
    }

    private func exchange(_ json: Data) async throws -> Data {
        guard var s = session else { throw KasaError.protocolError("no session") }
        let (seq, payload) = try s.encrypt(json)
        session = s
        let (reply, response) = try await post("/app/request?seq=\(seq)", payload)
        guard response.statusCode == 200 else { throw KasaError.protocolError("request returned HTTP \(response.statusCode)") }
        return try s.decrypt(reply, seq: seq)
    }
}

// MARK: - Commands

/// The JSON each dialect uses. IOT is the original Kasa schema; SMART is the newer Tapo-style schema some Kasa plugs use over KLAP.
enum KasaCommand {
    static func json(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    static let iotInfo = json(["system": ["get_sysinfo": [String: Any]()]])
    static func iotSet(_ on: Bool) -> Data { json(["system": ["set_relay_state": ["state": on ? 1 : 0]]]) }
    static let smartInfo = json(["method": "get_device_info"])
    static func smartSet(_ on: Bool) -> Data { json(["method": "set_device_info", "params": ["device_on": on]]) }

    struct Info: Sendable {
        var model = "", name = "", isOn = false
    }

    static func parseIOTInfo(_ data: Data) -> Info? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sys = (root["system"] as? [String: Any])?["get_sysinfo"] as? [String: Any],
              sys["relay_state"] != nil else { return nil }
        return Info(model: sys["model"] as? String ?? "", name: sys["alias"] as? String ?? "",
                    isOn: (sys["relay_state"] as? Int ?? 0) != 0)
    }

    static func parseSmartInfo(_ data: Data) -> Info? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["error_code"] as? Int) == 0, let r = root["result"] as? [String: Any], r["device_on"] != nil else { return nil }
        // The nickname is base64-encoded.
        let nick = (r["nickname"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return Info(model: r["model"] as? String ?? "", name: nick, isOn: r["device_on"] as? Bool ?? false)
    }

    /// True when the reply to a set command reports success.
    static func iotSetSucceeded(_ data: Data) -> Bool {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let reply = (root?["system"] as? [String: Any])?["set_relay_state"] as? [String: Any]
        return (reply?["err_code"] as? Int) == 0
    }

    static func smartSetSucceeded(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error_code"] as? Int == 0
    }
}

/// One plug. Works out on first use which of the three transports/dialects it speaks and remembers it.
actor KasaDevice {
    enum Mode: String { case xor = "legacy (TCP 9999)", klapIOT = "KLAP", klapSmart = "KLAP (smart)" }

    let host: String
    private let credentials: [Data]
    private var mode: Mode?
    private var klap: KlapTransport?

    init(host: String, credentials: [Data]) { self.host = host; self.credentials = credentials }

    var detectedMode: Mode? { mode }

    func info() async throws -> (KasaCommand.Info, Mode) {
        do { return try await probe() } catch { mode = nil; throw error }
    }

    func setPower(_ on: Bool) async throws {
        if mode == nil { _ = try await probe() }
        do {
            switch mode! {
            case .xor:
                let reply = try await KasaXOR.exchange(host: host, request: KasaCommand.iotSet(on))
                guard KasaCommand.iotSetSucceeded(reply) else { throw KasaError.protocolError(String(decoding: reply, as: UTF8.self)) }
            case .klapIOT:
                let reply = try await transport().send(KasaCommand.iotSet(on))
                guard KasaCommand.iotSetSucceeded(reply) else { throw KasaError.protocolError(String(decoding: reply, as: UTF8.self)) }
            case .klapSmart:
                let reply = try await transport().send(KasaCommand.smartSet(on))
                guard KasaCommand.smartSetSucceeded(reply) else { throw KasaError.protocolError(String(decoding: reply, as: UTF8.self)) }
            }
        } catch {
            mode = nil   // re-detect next time (firmware update, new address, lost session)
            throw error
        }
    }

    private func transport() -> KlapTransport {
        if let klap { return klap }
        let t = KlapTransport(host: host, credentials: credentials)
        klap = t
        return t
    }

    private func probe() async throws -> (KasaCommand.Info, Mode) {
        if let info = await Self.tryLegacy(host) { mode = .xor; return (info, .xor) }
        let t = transport()
        // Auth/network errors from the first KLAP request are the useful ones; surface them.
        let smart = try await t.send(KasaCommand.smartInfo)
        if let info = KasaCommand.parseSmartInfo(smart) { mode = .klapSmart; return (info, .klapSmart) }
        let iot = try await t.send(KasaCommand.iotInfo)
        if let info = KasaCommand.parseIOTInfo(iot) { mode = .klapIOT; return (info, .klapIOT) }
        throw KasaError.protocolError("\(host) answered but is not a recognised Kasa plug")
    }

    private static func tryLegacy(_ host: String) async -> KasaCommand.Info? {
        guard let reply = try? await KasaXOR.exchange(host: host, request: KasaCommand.iotInfo, timeout: 3) else { return nil }
        return KasaCommand.parseIOTInfo(reply)
    }
}

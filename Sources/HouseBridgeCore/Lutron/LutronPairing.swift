import Foundation

public struct LutronCredentials: Sendable {
    public let ca: String
    public let cert: String
    public let key: String
    public let leapVersion: String?
}

public enum LutronPairingError: Error, CustomStringConvertible {
    case openssl(String)
    case timeout(String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .openssl(let s): return "could not generate a key/CSR with /usr/bin/openssl: \(s)"
        case .timeout(let s): return "timed out waiting for \(s)"
        case .badResponse(let s): return "unexpected reply from the bridge: \(s)"
        }
    }
}

/// Lutron "LAP" pairing: connect to the bridge's pairing port (8083) with Lutron's shared app identity, wait for the
/// physical button press, submit a CSR and receive a signed client certificate. Port and message shapes follow
/// pylutron-caseta's pairing.py. **Not verified against a real bridge**; the message builders/parsers are unit-tested.
public enum LutronPairing {
    static let pairingPort = 8083
    static let leapPort = 8081
    static let certTag = "get-cert"

    // MARK: Messages

    /// True for the status message the bridge sends once its pairing button has been pressed.
    static func isButtonPress(_ message: [String: Any]) -> Bool {
        let type = (message["Header"] as? [String: Any])?["ContentType"] as? String ?? ""
        let body = message["Body"] as? [String: Any]
        let permissions = (body?["Status"] as? [String: Any])?["Permissions"] as? [String] ?? []
        return type.hasPrefix("status;") && permissions.contains("PhysicalAccess")
    }

    static func certificateRequest(csr: String) -> [String: Any] {
        ["Header": ["RequestType": "Execute", "Url": "/pair", "ClientTag": certTag],
         "Body": ["CommandType": "CSR",
                  "Parameters": ["CSR": csr, "DisplayName": "housebridge", "DeviceUID": "000000000000", "Role": "Admin"]]]
    }

    /// Returns (client certificate, root certificate) from the bridge's reply to `certificateRequest`.
    static func signingResult(_ message: [String: Any]) throws -> (cert: String, root: String) {
        let body = message["Body"] as? [String: Any]
        guard let result = body?["SigningResult"] as? [String: Any],
              let cert = result["Certificate"] as? String, let root = result["RootCertificate"] as? String else {
            let status = ((message["Header"] as? [String: Any])?["StatusCode"] as? String) ?? "no SigningResult"
            throw LutronPairingError.badResponse(status)
        }
        return (cert, root)
    }

    // MARK: Pairing

    /// `onReady` is called once the bridge is connected and waiting for its button.
    public static func pair(host: String, buttonTimeout: TimeInterval = 180, onReady: @Sendable () -> Void) async throws -> LutronCredentials {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("housebridge-pair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, _ text: String) throws -> String {
            let url = dir.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }

        let (keyPEM, csrPEM) = try generateKeyAndCSR(in: dir)
        let lapCA = try write("lap-ca.pem", LutronPairingAssets.ca)
        let lapCert = try write("lap-cert.pem", LutronPairingAssets.cert)
        let lapKey = try write("lap-key.pem", LutronPairingAssets.key)
        let (lapIdentity, lapAnchor) = try LeapIdentity.load(certPath: lapCert, keyPath: lapKey, caPath: lapCA)

        let (signed, root): (String, String) = try await {
            let conn = LeapConnection(host: host, port: pairingPort, identity: lapIdentity, ca: lapAnchor)
            let inbox = Inbox()
            conn.onMessage = { inbox.push($0) }
            try await conn.start()
            defer { conn.close() }
            onReady()
            _ = try await inbox.next(timeout: buttonTimeout, what: "the button press") { isButtonPress($0) }
            conn.send(certificateRequest(csr: csrPEM))
            let reply = try await inbox.next(timeout: 15, what: "the signed certificate") {
                ($0["Header"] as? [String: Any])?["ClientTag"] as? String == certTag
            }
            let r = try signingResult(reply)
            return (r.cert, r.root)
        }()

        // Prove the new identity works on the normal LEAP port before telling the user it is done.
        let certPath = try write("cert.pem", signed), caPath = try write("ca.pem", root), keyPath = try write("key.pem", keyPEM)
        let (identity, anchor) = try LeapIdentity.load(certPath: certPath, keyPath: keyPath, caPath: caPath)
        let conn = LeapConnection(host: host, port: leapPort, identity: identity, ca: anchor)
        try await conn.start()
        defer { conn.close() }
        let ping = try await conn.request("ReadRequest", "/server/1/status/ping")
        let version = ((ping["Body"] as? [String: Any])?["PingResponse"] as? [String: Any])?["LEAPVersion"]
        return LutronCredentials(ca: root, cert: signed, key: keyPEM, leapVersion: version.map { "\($0)" })
    }

    /// Writes ca.pem, cert.pem and key.pem (key 0600) into `directory`.
    public static func save(_ creds: LutronCredentials, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, text, mode) in [("ca.pem", creds.ca, 0o644), ("cert.pem", creds.cert, 0o644), ("key.pem", creds.key, 0o600)] {
            let url = directory.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
    }

    /// /usr/bin/openssl, as in `LeapIdentity`: no crypto dependency, and Security.framework cannot make a CSR.
    private static func generateKeyAndCSR(in dir: URL) throws -> (key: String, csr: String) {
        let keyURL = dir.appendingPathComponent("new.key"), csrURL = dir.appendingPathComponent("new.csr")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256", "-subj", "/CN=housebridge",
                             "-keyout", keyURL.path, "-out", csrURL.path]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        do { try process.run() } catch { throw LutronPairingError.openssl("\(error)") }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LutronPairingError.openssl(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (try String(contentsOf: keyURL, encoding: .utf8), try String(contentsOf: csrURL, encoding: .utf8))
    }
}

/// Messages from the bridge, consumed in order, with a timeout.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [[String: Any]] = []

    func push(_ message: [String: Any]) {
        lock.withLock { queue.append(message) }
    }

    private func take(_ match: ([String: Any]) -> Bool) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let i = queue.firstIndex(where: match) else { return nil }
        return queue.remove(at: i)
    }

    func next(timeout: TimeInterval, what: String, _ match: @escaping ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let m = take(match) { return m }
            // Poll: simple and safe against a message arriving between the check and the wait.
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LutronPairingError.timeout(what)
    }
}

import Foundation
import Network
import Security

enum LeapError: Error, CustomStringConvertible {
    case identity(String)
    case closed
    case timeout(String)
    case badResponse(String)

    var description: String {
        switch self {
        case .identity(let s): return "Lutron certificate problem: \(s)"
        case .closed: return "connection closed"
        case .timeout(let s): return "timed out waiting for \(s)"
        case .badResponse(let s): return "unexpected response: \(s)"
        }
    }
}

/// Loads the client identity (certificate + private key PEM files) produced by Lutron pairing.
enum LeapIdentity {
    static func load(certPath: String, keyPath: String, caPath: String) throws -> (SecIdentity, SecCertificate) {
        let p12 = FileManager.default.temporaryDirectory.appendingPathComponent("housebridge-\(UUID().uuidString).p12")
        defer { try? FileManager.default.removeItem(at: p12) }
        let passphrase = UUID().uuidString

        // /usr/bin/openssl (LibreSSL) writes a PKCS#12 that Security.framework can import; Homebrew's OpenSSL 3 does not by default.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["pkcs12", "-export", "-inkey", keyPath, "-in", certPath, "-out", p12.path, "-passout", "pass:\(passphrase)"]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        do { try process.run() } catch { throw LeapError.identity("could not run /usr/bin/openssl: \(error)") }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw LeapError.identity("could not read \(certPath) / \(keyPath): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let data = try Data(contentsOf: p12)
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: passphrase,
                                                     kSecImportToMemoryOnly as String: true] as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            throw LeapError.identity("could not import client identity (status \(status))")
        }
        let identity = identityRef as! SecIdentity

        let caText = try String(contentsOfFile: caPath, encoding: .utf8)
        guard let caCert = pemCertificates(caText).compactMap({ SecCertificateCreateWithData(nil, $0 as CFData) }).first else {
            throw LeapError.identity("no certificate found in \(caPath)")
        }
        return (identity, caCert)
    }

    static func pemCertificates(_ text: String) -> [Data] {
        var out: [Data] = []
        var current: String?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("-----BEGIN CERTIFICATE") { current = "" }
            else if line.hasPrefix("-----END CERTIFICATE") {
                if let c = current, let d = Data(base64Encoded: c) { out.append(d) }
                current = nil
            } else if current != nil { current! += line.trimmingCharacters(in: .whitespaces) }
        }
        return out
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// True exactly once.
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// One TLS connection to a Lutron bridge speaking LEAP (CRLF-delimited JSON).
final class LeapConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "housebridge.leap")
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<JSON, Error>] = [:]
    private var closedFlag = false
    private var onClosed: [CheckedContinuation<Void, Never>] = []

    /// Called on the connection's queue for messages that aren't responses to a pending request.
    var onMessage: ((JSON) -> Void)?

    init(host: String, port: Int, identity: SecIdentity, ca: SecCertificate) {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        if let id = sec_identity_create(identity) { sec_protocol_options_set_local_identity(sec, id) }
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let t = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetAnchorCertificates(t, [ca] as CFArray)
            SecTrustSetAnchorCertificatesOnly(t, true)
            SecTrustSetPolicies(t, SecPolicyCreateBasicX509()) // the bridge's name is not in its certificate
            complete(SecTrustEvaluateWithError(t, nil))
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10   // fail fast when the address is wrong
        let params = NWParameters(tls: tls, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: params)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if once.first() { cont.resume() }
                    self.receive()
                case .failed(let error):
                    if once.first() { cont.resume(throwing: error) }
                    self.finish(error)
                case .waiting(let error):
                    if once.first() { cont.resume(throwing: error); self.connection.cancel() }
                case .cancelled:
                    if once.first() { cont.resume(throwing: LeapError.closed) }
                    self.finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func close() { connection.cancel() }

    /// Suspends until the connection ends.
    func waitUntilClosed() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.closedFlag { cont.resume() } else { self.onClosed.append(cont) }
            }
        }
    }

    private func finish(_ error: Error?) {
        queue.async {
            guard !self.closedFlag else { return }
            self.closedFlag = true
            for (_, cont) in self.pending { cont.resume(throwing: error ?? LeapError.closed) }
            self.pending = [:]
            self.onClosed.forEach { $0.resume() }
            self.onClosed = []
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if error != nil || isComplete {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private func drain() {
        while let range = buffer.range(of: Data("\r\n".utf8)) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard !line.isEmpty, let message = (try? JSONSerialization.jsonObject(with: line)) as? JSON else { continue }
            let tag = (message["Header"] as? JSON)?["ClientTag"] as? String
            if let tag, let cont = pending.removeValue(forKey: tag) {
                cont.resume(returning: message)
            } else {
                onMessage?(message)
            }
        }
    }

    func request(_ type: String, _ url: String, body: JSON? = nil, timeout: TimeInterval = 10) async throws -> JSON {
        let tag = UUID().uuidString
        var message: JSON = ["CommuniqueType": type, "Header": ["Url": url, "ClientTag": tag]]
        if let body { message["Body"] = body }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(contentsOf: Array("\r\n".utf8))

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSON, Error>) in
            queue.async {
                if self.closedFlag { cont.resume(throwing: LeapError.closed); return }
                self.pending[tag] = cont
                self.connection.send(content: data, completion: .contentProcessed { error in
                    if let error { self.queue.async { self.pending.removeValue(forKey: tag)?.resume(throwing: error) } }
                })
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.pending.removeValue(forKey: tag)?.resume(throwing: LeapError.timeout("\(type) \(url)"))
                }
            }
        }
    }
}

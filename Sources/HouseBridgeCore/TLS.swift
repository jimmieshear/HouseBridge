import Foundation
import CryptoKit
import Security

/// Trust-on-first-use certificate pinning for local devices (Hue bridge, UniFi console) that
/// present self-signed certificates. First connection records the fingerprint; later mismatches are refused.
public final class KnownHosts: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var map: [String: String]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            map = decoded
        } else {
            map = [:]
        }
    }

    public enum Verdict { case trusted, newlyTrusted, mismatch }

    func verify(host: String, fingerprint: String) -> Verdict {
        lock.lock(); defer { lock.unlock() }
        if let known = map[host] { return known == fingerprint ? .trusted : .mismatch }
        map[host] = fingerprint
        if let data = try? JSONEncoder().encode(map) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return .newlyTrusted
    }

    public func forget(host: String) {
        lock.lock(); defer { lock.unlock() }
        map.removeValue(forKey: host)
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: url, options: .atomic) }
    }
}

final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let hosts: KnownHosts
    private let onNewHost: (@Sendable (String) -> Void)?

    init(hosts: KnownHosts, onNewHost: (@Sendable (String) -> Void)? = nil) {
        self.hosts = hosts
        self.onNewHost = onNewHost
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        let host = challenge.protectionSpace.host
        switch hosts.verify(host: host, fingerprint: fingerprint) {
        case .trusted:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .newlyTrusted:
            onNewHost?(host)
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .mismatch:
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

typealias JSON = [String: Any]

func parseJSON(_ data: Data) throws -> Any {
    try JSONSerialization.jsonObject(with: data)
}

public struct HTTPFailure: Error, CustomStringConvertible {
    public let status: Int
    public let body: String
    public var description: String { "HTTP \(status): \(body.prefix(200))" }
}

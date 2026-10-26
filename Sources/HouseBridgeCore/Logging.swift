import Foundation
import Network

/// Turns an Error into something diagnosable: type, domain/code, failing URL and underlying causes.
public func describeError(_ error: Error) -> String {
    if let friendly = posixSummary(error) { return friendly }
    var parts: [String] = ["\(error)"]
    let ns = error as NSError
    if "\(error)" != ns.localizedDescription { parts.append(ns.localizedDescription) }
    parts.append("[\(type(of: error)) \(ns.domain) \(ns.code)]")
    if let url = ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String { parts.append("url=\(url)") }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { parts.append("caused by: " + describeError(underlying)) }
    return parts.joined(separator: " ")
}

/// One-line text for the connection errors Network.framework reports as POSIX codes, which otherwise print as
/// "POSIXErrorCode(rawValue: 61): Connection refused The operation couldn't be completed. (Network.NWE…".
func posixSummary(_ error: Error) -> String? {
    guard case .posix(let code)? = error as? NWError else { return nil }
    switch code {
    case .ECONNREFUSED: return "connection refused (the device is up but not accepting connections; it may be busy, restarting, or at its connection limit)"
    case .ETIMEDOUT: return "connection timed out (no reply; the device is offline, rebooting or the address is wrong)"
    case .EHOSTUNREACH: return "no route to host"
    case .ENETUNREACH: return "network unreachable"
    default: return nil
    }
}

/// Append-only log file with simple size-based rotation (housebridge.log, .1, .2). Safe from any thread.
public final class FileLog: @unchecked Sendable {
    public let url: URL
    private let maxBytes: Int
    private let keep: Int
    private let lock = NSLock()
    private let stamp: DateFormatter

    public init(directory: URL, name: String = "housebridge.log", maxBytes: Int = 1_000_000, keep: Int = 3) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent(name)
        self.maxBytes = maxBytes
        self.keep = keep
        stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
    }

    public func write(_ entry: LogEntry) {
        write(level: entry.level, category: entry.category, message: entry.message, date: entry.date)
    }

    public func write(level: LogLevel = .info, category: String, message: String, date: Date = Date()) {
        let line = "\(stamp.string(from: date)) [\(level.rawValue)] [\(category)] \(message.replacingOccurrences(of: "\n", with: "\n    "))\n"
        lock.lock(); defer { lock.unlock() }
        rotateIfNeeded()
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    private func rotateIfNeeded() {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        guard size >= maxBytes else { return }
        let fm = FileManager.default
        for i in stride(from: keep - 1, through: 1, by: -1) {
            let from = url.appendingPathExtension("\(i)"), to = url.appendingPathExtension("\(i + 1)")
            try? fm.removeItem(at: to)
            if fm.fileExists(atPath: from.path) { try? fm.moveItem(at: from, to: to) }
        }
        let first = url.appendingPathExtension("1")
        try? fm.removeItem(at: first)
        try? fm.moveItem(at: url, to: first)
    }

    public func tail(lines: Int = 80) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "(no log yet)" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}

/// If an error looks like macOS blocking access to the local network (typical for an app that was never
/// granted "Local Network" permission), returns advice; otherwise nil.
public func localNetworkHint(for error: Error, host: String) -> String? {
    if ["192.168.1.50", "192.168.1.60"].contains(host) {
        return "\(host) is the placeholder address from the example config. Set the real IP address of this device in config.yaml."
    }
    let isPrivate = host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.")
        || (host.hasPrefix("172.") && (Int(host.split(separator: ".").dropFirst().first ?? "") ?? 0).clamped(16...31))
        || host.hasSuffix(".local")
    guard isPrivate else { return nil }
    if case .posix(.ECONNREFUSED)? = error as? NWError { return nil }   // the host replied, so it is not a permission block
    let ns = error as NSError
    var codes: [(String, Int)] = [(ns.domain, ns.code)]
    if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError { codes.append((u.domain, u.code)) }
    let suspicious = codes.contains { d, c in
        (d == NSURLErrorDomain && (c == NSURLErrorNotConnectedToInternet || c == NSURLErrorCannotConnectToHost || c == NSURLErrorTimedOut))
            || (d == NSPOSIXErrorDomain && [60, 61, 64, 65, 13, 1].contains(c))
    } || "\(error)".contains("POSIXErrorCode(rawValue: 60)") || "\(error)".contains("POSIXErrorCode(rawValue: 65)")
    guard suspicious else { return nil }
    return "Could not reach \(host). If the same address works from Terminal, macOS is probably blocking this app: open System Settings → Privacy & Security → Local Network and switch HouseBridge on (relaunch it afterwards). Otherwise check the IP address and that the device is on this network."
}

private extension Int {
    func clamped(_ r: ClosedRange<Int>) -> Bool { r.contains(self) }
}

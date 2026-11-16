import Foundation

/// Controls the configured Kasa plugs and keeps their `off_after_seconds` timers.
public final class KasaBridge: @unchecked Sendable {
    private let config: KasaConfig
    private let log: @Sendable (LogEntry) -> Void
    private let status: @Sendable (ConnectionStatus) -> Void
    private let devices: [String: KasaDevice]       // lowercased plug name → device
    private let lock = NSLock()
    private var offTimers: [String: Task<Void, Never>] = [:]
    /// Told (plug name, new state) whenever a plug is switched through this bridge, so Home.app can follow.
    public var onChange: (@Sendable (String, Bool) -> Void)?

    public init(config: KasaConfig, log: @escaping @Sendable (LogEntry) -> Void,
                status: @escaping @Sendable (ConnectionStatus) -> Void = { _ in }) {
        self.config = config
        self.log = log
        self.status = status
        let hashes = config.credentialHashes()
        devices = Dictionary(config.plugs.map { ($0.name.lowercased(), KasaDevice(host: $0.host, credentials: hashes)) },
                             uniquingKeysWith: { a, _ in a })
    }

    /// Reads every plug once so the status shows whether they can be reached (and the log says which protocol each speaks).
    public func connect() async {
        status(.connecting)
        var reachable = 0
        var problems: [String] = []
        for plug in config.plugs {
            do {
                let (info, mode) = try await devices[plug.name.lowercased()]!.info()
                reachable += 1
                log(LogEntry(category: "kasa", message: "‘\(plug.name)’ at \(plug.host): \(info.model) \(info.isOn ? "on" : "off") via \(mode.rawValue)"))
            } catch {
                problems.append(plug.name)
                log(LogEntry(level: .error, category: "kasa", message: "‘\(plug.name)’ at \(plug.host): \(describeError(error))\(config.accountNote(for: error))"))
            }
        }
        if problems.isEmpty { status(.connected("\(reachable) plug\(reachable == 1 ? "" : "s")")) }
        else if reachable == 0, config.password == nil, config.resolvedPassword() == nil, config.username != nil {
            status(.needsSetup("no password: run housebridgectl set-kasa-password"))
        } else { status(.disconnected("can't reach " + problems.joined(separator: ", "))) }
    }

    /// Turns a plug on or off. With `offAfter` (and `on`), schedules an off that any later call for the same plug replaces.
    public func setPlug(_ name: String, on: Bool, offAfter: TimeInterval? = nil) async throws {
        let key = name.lowercased()
        guard let device = devices[key] else {
            throw KasaError.unknownPlug(name, available: config.plugs.map(\.name))
        }
        lock.withLock { _ = offTimers.removeValue(forKey: key)?.cancel() }
        try await device.setPower(on)
        onChange?(name, on)
        guard on, let offAfter else { return }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(offAfter))
            guard !Task.isCancelled, let self else { return }
            self.lock.withLock { _ = self.offTimers.removeValue(forKey: key) }
            do { try await device.setPower(false); self.onChange?(name, false) }
            catch { self.log(LogEntry(level: .error, category: "kasa", message: "turning ‘\(name)’ off failed: \(describeError(error))")) }
        }
        lock.withLock { offTimers[key] = timer }
    }

    /// The plug's current state, nil when it can't be read.
    public func isOn(_ name: String) async -> Bool? {
        guard let device = devices[name.lowercased()] else { return nil }
        return try? await device.info().0.isOn
    }

    /// Cancels pending `off_after_seconds` timers (names as in rules), leaving the plugs as they are.
    public func cancelOffTimers(for names: [String]) {
        lock.withLock { for n in names { offTimers.removeValue(forKey: n.lowercased())?.cancel() } }
    }

    public func stop() {
        lock.withLock { offTimers.values.forEach { $0.cancel() }; offTimers = [:] }
    }

    /// One line per plug, for `housebridgectl list kasa`.
    public static func describe(config: KasaConfig) async -> [String] {
        let hashes = config.credentialHashes()
        var lines: [String] = []
        for plug in config.plugs {
            let device = KasaDevice(host: plug.host, credentials: hashes)
            do {
                let (info, mode) = try await device.info()
                lines.append("  “\(plug.name)”  \(plug.host)  [\(info.model)] \(info.isOn ? "on" : "off"), protocol: \(mode.rawValue)")
            } catch {
                lines.append("  “\(plug.name)”  \(plug.host)  unreachable: \(describeError(error))\(config.accountNote(for: error))")
            }
        }
        return lines
    }
}

import Foundation

public struct ProtectInventory: Sendable {
    /// One of a camera's video streams (Protect calls them high, medium and low).
    public struct Channel: Sendable, Equatable {
        public var width: Int, height: Int, fps: Int, bitrate: Int
        public var rtspAlias: String?
        public var rtspEnabled: Bool
    }
    public struct Item: Sendable {
        public let id: String
        public let name: String
        public let model: String
        public let kind: String
        /// Event inputs this device can raise (e.g. motion, person, contact).
        public var provides: [String] = []
        public var details: [String] = []
        /// Current state at the time of the bootstrap: contact (true = open), motion, leak (true = detected).
        public var state: [String: Bool] = [:]
        /// Cameras only.
        public var channels: [Channel] = []
        /// Sensors only: the readings in `stats` at the time of the bootstrap (temperature °C, humidity %, light lux).
        public var measurements: [String: Double] = [:]
    }
    public var items: [Item] = []
}

/// Logs in to a UniFi OS console, reads the Protect bootstrap, and follows the live update socket.
public final class ProtectClient: @unchecked Sendable {
    private let config: UnifiConfig
    private let hosts: KnownHosts
    private let emit: @Sendable (TriggerEvent) -> Void
    private let onInventory: @Sendable (ProtectInventory) -> Void
    private let onReadings: @Sendable ([SensorReading]) -> Void
    private let status: @Sendable (ConnectionStatus) -> Void
    private let log: @Sendable (LogEntry) -> Void

    public init(config: UnifiConfig, hosts: KnownHosts,
                emit: @escaping @Sendable (TriggerEvent) -> Void = { _ in },
                onInventory: @escaping @Sendable (ProtectInventory) -> Void = { _ in },
                onReadings: @escaping @Sendable ([SensorReading]) -> Void = { _ in },
                status: @escaping @Sendable (ConnectionStatus) -> Void = { _ in },
                log: @escaping @Sendable (LogEntry) -> Void = { _ in }) {
        self.config = config
        self.hosts = hosts
        self.emit = emit
        self.onInventory = onInventory
        self.onReadings = onReadings
        self.status = status
        self.log = log
    }

    private func makeSession() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: PinningDelegate(hosts: hosts, onNewHost: { [log] host in
            log(LogEntry(category: "unifi", message: "trusting new certificate for \(host) (first connection)"))
        }), delegateQueue: nil)
    }

    private struct Bootstrap {
        var lastUpdateId: String
        var items: [ProtectInventory.Item]
    }

    private func login(_ session: URLSession) async throws {
        guard let password = config.resolvedPassword() else {
            throw HTTPFailure(status: 0, body: "no UniFi password: set unifi.password or export the variable named in unifi.password_env")
        }
        var request = URLRequest(url: URL(string: "https://\(config.host)/api/auth/login")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": config.username, "password": password, "rememberMe": false,
        ])
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw HTTPFailure(status: code, body: String(decoding: data, as: UTF8.self)) }
    }

    private func bootstrap(_ session: URLSession) async throws -> Bootstrap {
        var request = URLRequest(url: URL(string: "https://\(config.host)/proxy/protect/api/bootstrap")!)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw HTTPFailure(status: code, body: String(decoding: data, as: UTF8.self)) }
        guard let root = try parseJSON(data) as? JSON else { throw HTTPFailure(status: code, body: "bootstrap was not an object") }
        var items: [ProtectInventory.Item] = []
        for (key, kind) in [("cameras", "camera"), ("sensors", "sensor")] {
            for d in (root[key] as? [JSON]) ?? [] {
                guard let id = d["id"] as? String else { continue }
                let name = d["name"] as? String ?? d["marketName"] as? String ?? id
                var item = ProtectInventory.Item(id: id, name: name, model: d["marketName"] as? String ?? d["type"] as? String ?? "", kind: kind)
                if kind == "camera" {
                    let flags = d["featureFlags"] as? JSON
                    let smart = (flags?["smartDetectTypes"] as? [String]) ?? []
                    item.provides = ["motion"] + smart
                    if (item.model + (d["type"] as? String ?? "")).localizedCaseInsensitiveContains("doorbell") { item.provides.append("ring") }
                    if flags?["hasSpeaker"] as? Bool == true { item.details.append("has speaker") }
                    if (flags?["smartDetectAudioTypes"] as? [String])?.isEmpty == false { item.details.append("audio detection: " + (flags?["smartDetectAudioTypes"] as? [String] ?? []).joined(separator: ", ")) }
                    if let state = d["state"] as? String { item.details.append("state: \(state)") }
                    if let moving = d["isMotionDetected"] as? Bool { item.state["motion"] = moving }
                    item.channels = ((d["channels"] as? [JSON]) ?? []).map { c in
                        ProtectInventory.Channel(width: c["width"] as? Int ?? 0, height: c["height"] as? Int ?? 0, fps: c["fps"] as? Int ?? 0,
                                                 bitrate: c["bitrate"] as? Int ?? 0, rtspAlias: c["rtspAlias"] as? String,
                                                 rtspEnabled: (c["isRtspEnabled"] as? Bool ?? false) && (c["rtspAlias"] as? String)?.isEmpty == false)
                    }
                } else {
                    let mount = d["mountType"] as? String ?? "unknown"
                    item.details.append("mount: \(mount)")
                    switch mount {
                    case "door", "window", "garage": item.provides = ["contact", "motion"]
                    case "leak": item.provides = ["leak"]
                    default: item.provides = ["contact", "motion", "leak"]
                    }
                    item.provides += ["tamper", "alarm"]
                    item.measurements = ProtectStats.measurements(d["stats"])
                    item.state["contact"] = d["isOpened"] as? Bool ?? false
                    item.state["motion"] = d["isMotionDetected"] as? Bool ?? false
                    item.state["leak"] = (d["leakDetectedAt"] != nil && !(d["leakDetectedAt"] is NSNull)) || (d["externalLeakDetectedAt"] != nil && !(d["externalLeakDetectedAt"] is NSNull))
                }
                items.append(item)
            }
        }
        let lastUpdateId = root["lastUpdateId"] as? String ?? ""
        return Bootstrap(lastUpdateId: lastUpdateId, items: items)
    }

    public func discover() async throws -> ProtectInventory {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        return ProtectInventory(items: try await authenticatedBootstrap(session).items)
    }

    /// Reuses the saved login session when there is one; logs in only if it's missing or expired.
    private func authenticatedBootstrap(_ session: URLSession) async throws -> Bootstrap {
        let consoleURL = URL(string: "https://\(config.host)")!
        var found: Bootstrap?
        if let cookies = cachedCookies() {
            session.configuration.httpCookieStorage?.setCookies(cookies, for: consoleURL, mainDocumentURL: nil)
            found = try? await bootstrap(session)   // expired session → fall through to a fresh login
            if found == nil { log(LogEntry(category: "unifi", message: "saved session expired; logging in again")) }
        }
        if found == nil {
            try await login(session)
            found = try await bootstrap(session)
        }
        cache(session.configuration.httpCookieStorage?.cookies(for: consoleURL))
        return found!
    }

    // MARK: Snapshots

    /// A JPEG from `cameraID`, at most `width` x `height`. Reuses the saved login session; logs in again only when the
    /// console says it expired (or there is none), because UniFi locks out clients that log in too often.
    public func snapshot(cameraID: String, width: Int, height: Int) async throws -> Data {
        guard !cameraID.isEmpty, cameraID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw HTTPFailure(status: 0, body: "bad camera id")
        }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let consoleURL = URL(string: "https://\(config.host)")!
        func fetch() async throws -> (Data, Int) {
            var parts = URLComponents(string: "https://\(config.host)/proxy/protect/api/cameras/\(cameraID)/snapshot")!
            parts.queryItems = [URLQueryItem(name: "w", value: String(width)), URLQueryItem(name: "h", value: String(height)),
                                URLQueryItem(name: "ts", value: String(Int(Date().timeIntervalSince1970 * 1000)))]
            var request = URLRequest(url: parts.url!)
            request.timeoutInterval = 10
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var (data, code) = (Data(), 401)
        if let cookies = cachedCookies() {
            session.configuration.httpCookieStorage?.setCookies(cookies, for: consoleURL, mainDocumentURL: nil)
            (data, code) = try await fetch()
        }
        if code == 401 || code == 403 {
            try await login(session)
            cache(session.configuration.httpCookieStorage?.cookies(for: consoleURL))
            (data, code) = try await fetch()
        }
        guard code == 200, !data.isEmpty else { throw HTTPFailure(status: code, body: "snapshot request failed") }
        return data
    }

    // MARK: Run loop

    /// Cookies from the last successful login, kept for the life of the process so a reconnect (or a config
    /// reload) reuses the session instead of logging in again. UniFi locks out clients that log in too often.
    private static let cookieLock = NSLock()
    private static var cookieCache: [String: [HTTPCookie]] = [:]

    private func cachedCookies() -> [HTTPCookie]? { ProtectClient.cookieLock.withLock { ProtectClient.cookieCache[config.host] } }
    private func cache(_ cookies: [HTTPCookie]?) {
        ProtectClient.cookieLock.withLock { ProtectClient.cookieCache[config.host] = cookies }
    }

    public func run() async {
        var backoff: Double = 2
        while !Task.isCancelled {
            status(.connecting)
            var upSince: Date?
            var wait = backoff
            do {
                try await session(onConnected: { upSince = Date() })
                if Task.isCancelled { return }
                log(LogEntry(level: .warning, category: "unifi", message: "update socket closed by the console; reconnecting"))
                status(.disconnected("socket closed"))
            } catch {
                if Task.isCancelled { return }
                let hint = localNetworkHint(for: error, host: config.host)
                var message = describeError(error) + (hint.map { "\n" + $0 } ?? "")
                var shown = hint != nil ? "can't reach \(config.host) — check Local Network permission (see log)" : "\(error)"
                if let failure = error as? HTTPFailure {
                    switch failure.status {
                    case 429:
                        wait = 600
                        shown = "login rate-limited by UniFi; retrying in 10 min"
                        message += "\nUniFi is rate limiting logins (too many recent attempts). Not retrying for 10 minutes; avoid running diagnose/list meanwhile."
                    case 401, 403:
                        wait = max(backoff, 300)
                        cache(nil)
                        shown = "login rejected — check username/password"
                        message += "\nUniFi rejected the credentials. Retrying only every 5 minutes to avoid a lockout."
                    default: break
                    }
                }
                log(LogEntry(level: .warning, category: "unifi", message: message))
                status(.disconnected(shown))
            }
            // Only forget past failures once a connection has actually stayed up for a while.
            if let up = upSince, Date().timeIntervalSince(up) > 60 { backoff = 2; wait = max(wait, 2) }
            else { backoff = min(backoff * 2, 300) }
            try? await Task.sleep(for: .seconds(max(wait, backoff)))
        }
    }

    private func emitReadings(_ items: [ProtectInventory.Item], now: Date = Date()) {
        let readings = items.filter { $0.kind == "sensor" }.flatMap { item in
            item.measurements.sorted { $0.key < $1.key }.map {
                SensorReading(accessory: "unifi:\(item.id)", home: "UniFi Protect", name: item.name, room: "", kind: $0.key, value: $0.value, date: now)
            }
        }
        if !readings.isEmpty { onReadings(readings) }
    }

    private func session(onConnected: () -> Void) async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let boot = try await authenticatedBootstrap(session)

        let interpreter = ProtectInterpreter()
        for item in boot.items { interpreter.devices[item.id] = .init(id: item.id, name: item.name, kind: item.kind) }
        onInventory(ProtectInventory(items: boot.items))
        emitReadings(boot.items)
        // Protect only pushes a sensor's stats when they change, so re-read the bootstrap now and then; that also keeps
        // the window's "updated" time honest for a steady temperature.
        let refresher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if Task.isCancelled { return }
                if let fresh = try? await self?.authenticatedBootstrap(session) { self?.emitReadings(fresh.items) }
            }
        }
        defer { refresher.cancel() }

        var components = URLComponents()
        components.scheme = "wss"
        components.host = config.host
        components.path = "/proxy/protect/ws/updates"
        components.queryItems = [URLQueryItem(name: "lastUpdateId", value: boot.lastUpdateId)]
        var request = URLRequest(url: components.url!)
        if let cookies = session.configuration.httpCookieStorage?.cookies(for: URL(string: "https://\(config.host)")!) {
            request.setValue(HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], forHTTPHeaderField: "Cookie")
        }
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        onConnected()
        let cameras = boot.items.filter { $0.kind == "camera" }.count
        let sensors = boot.items.filter { $0.kind == "sensor" }.count
        status(.connected("\(cameras) cameras, \(sensors) sensors"))
        log(LogEntry(category: "unifi", message: "connected: \(cameras) cameras, \(sensors) sensors"))

        defer { log(LogEntry(category: "unifi", message: "update socket ended (cancelled: \(Task.isCancelled), close code: \(socket.closeCode.rawValue))")) }
        while !Task.isCancelled {
            let message = try await socket.receive()
            guard case .data(let data) = message else { continue }
            do {
                let update = try ProtectPacket.decode(data)
                interpreter.interpret(update).forEach(emit)
                let readings = interpreter.readings(update)
                if !readings.isEmpty { onReadings(readings) }
            } catch {
                log(LogEntry(level: .warning, category: "unifi", message: "could not decode update: \(describeError(error))"))
            }
        }
    }
}

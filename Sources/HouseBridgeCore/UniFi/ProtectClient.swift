import Foundation

public struct ProtectInventory: Sendable {
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
    }
    public var items: [Item] = []
}

/// Logs in to a UniFi OS console, reads the Protect bootstrap, and follows the live update socket.
public final class ProtectClient: @unchecked Sendable {
    private let config: UnifiConfig
    private let hosts: KnownHosts
    private let emit: @Sendable (TriggerEvent) -> Void
    private let onInventory: @Sendable (ProtectInventory) -> Void
    private let status: @Sendable (ConnectionStatus) -> Void
    private let log: @Sendable (LogEntry) -> Void

    public init(config: UnifiConfig, hosts: KnownHosts,
                emit: @escaping @Sendable (TriggerEvent) -> Void = { _ in },
                onInventory: @escaping @Sendable (ProtectInventory) -> Void = { _ in },
                status: @escaping @Sendable (ConnectionStatus) -> Void = { _ in },
                log: @escaping @Sendable (LogEntry) -> Void = { _ in }) {
        self.config = config
        self.hosts = hosts
        self.emit = emit
        self.onInventory = onInventory
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
                } else {
                    let mount = d["mountType"] as? String ?? "unknown"
                    item.details.append("mount: \(mount)")
                    switch mount {
                    case "door", "window", "garage": item.provides = ["contact", "motion"]
                    case "leak": item.provides = ["leak"]
                    default: item.provides = ["contact", "motion", "leak"]
                    }
                    item.provides += ["tamper", "alarm"]
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

    private func session(onConnected: () -> Void) async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let boot = try await authenticatedBootstrap(session)

        let interpreter = ProtectInterpreter()
        for item in boot.items { interpreter.devices[item.id] = .init(id: item.id, name: item.name, kind: item.kind) }
        onInventory(ProtectInventory(items: boot.items))

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
            } catch {
                log(LogEntry(level: .warning, category: "unifi", message: "could not decode update: \(describeError(error))"))
            }
        }
    }
}

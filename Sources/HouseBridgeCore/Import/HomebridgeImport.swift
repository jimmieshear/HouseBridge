import Foundation

/// What can be carried over from a Homebridge installation: the UniFi Protect controller and the bridge's name.
/// Everything else (other plugins, Home.app automations, room and accessory names) lives elsewhere and is reported
/// as not migrated.
public struct HomebridgeImport: Sendable {
    public struct Controller: Sendable, Equatable {
        public var host: String
        public var username: String
        public var password: String?
        public var name: String?
    }

    public var bridgeName: String?
    public var controllers: [Controller] = []
    /// Platforms and accessories in the Homebridge config that HouseBridge has no equivalent for.
    public var unmigrated: [String] = []
    /// The Protect plugin's feature-option strings, which have no HouseBridge counterpart.
    public var pluginOptions: [String] = []

    public enum ImportError: Error, CustomStringConvertible {
        case notAConfig
        case noProtectPlugin(found: [String])

        public var description: String {
            switch self {
            case .notAConfig: return "that is not a Homebridge config.json (expected a JSON object)"
            case .noProtectPlugin(let found):
                return "no UniFi Protect controller found in the Homebridge config" +
                    (found.isEmpty ? "" : " (it contains: \(found.joined(separator: ", ")))")
            }
        }
    }

    public init() {}

    public static func parse(_ data: Data) throws -> HomebridgeImport {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ImportError.notAConfig }
        var result = HomebridgeImport()
        result.bridgeName = (root["bridge"] as? [String: Any])?["name"] as? String

        var found: [String] = []
        for entry in (root["platforms"] as? [[String: Any]]) ?? [] {
            let name = entry["platform"] as? String ?? "(unnamed platform)"
            let lowered = name.lowercased()
            if lowered == "config" { continue }   // Homebridge's own web UI (Config UI X), nothing to migrate
            guard lowered.contains("unifi"), lowered.contains("protect") else {
                found.append(name)
                result.unmigrated.append("platform “\(name)”")
                continue
            }
            found.append(name)
            for c in (entry["controllers"] as? [[String: Any]]) ?? [] {
                guard let address = (c["address"] as? String) ?? (c["host"] as? String), !address.isEmpty,
                      let username = c["username"] as? String, !username.isEmpty else { continue }
                result.controllers.append(Controller(host: normalizeHost(address), username: username,
                                                     password: (c["password"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                                     name: c["name"] as? String))
            }
            result.pluginOptions += (entry["options"] as? [String]) ?? []
        }
        for entry in (root["accessories"] as? [[String: Any]]) ?? [] {
            let name = entry["accessory"] as? String ?? "(unnamed accessory)"
            found.append(name)
            result.unmigrated.append("accessory “\(name)”")
        }
        guard !result.controllers.isEmpty else { throw ImportError.noProtectPlugin(found: found) }
        return result
    }

    /// Accepts `https://192.168.1.1/`, `192.168.1.1:443` and `192.168.1.1`; HouseBridge wants the bare host.
    static func normalizeHost(_ address: String) -> String {
        var host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        return host
    }

    public var primary: Controller { controllers[0] }

    private func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// The `unifi:` section. The password is never written.
    public func unifiSection() -> String {
        let q = Catalog.q
        var out = """
        unifi:
          host: \(q(primary.host))
          username: \(q(primary.username))
          # The password is not written here. Store it in the macOS Keychain with:  housebridgectl set-unifi-password

        """
        if controllers.count > 1 {
            out += "  # Homebridge had \(controllers.count) controllers; HouseBridge supports one. Not imported: "
            out += controllers.dropFirst().map { q($0.host) }.joined(separator: ", ") + "\n"
        }
        return out
    }

    /// The `homekit:` section; its name differs from the Homebridge bridge's so the two are not confused in Home.app.
    public func homekitSection() -> String {
        var name = "HouseBridge"
        if bridgeName?.lowercased() == name.lowercased() { name = "HouseBridge Protect" }
        return """
        # Publishes the Protect cameras and sensors to Apple Home (motion, contact, leak, doorbell; no video).
        # Pair it with:  housebridgectl homekit
        homekit:
          name: \(Catalog.q(name))
          # smart_detections: true        # also a motion sensor each for person, vehicle, animal, ...

        """
    }

    /// Text to add to an existing config: just the requested sections (`unifi`, `homekit`), under a comment saying where they came from.
    public func appendix(sections: [String], source: String, date: Date = Date()) -> String {
        var out = "# Imported from Homebridge (\(source)) on \(stamp(date))\n"
        if sections.contains("unifi") { out += unifiSection() + "\n" }
        if sections.contains("homekit") { out += homekitSection() }
        return out
    }

    /// A complete new config: both sections plus a commented rule example.
    public func yaml(source: String, date: Date = Date()) -> String {
        """
        # HouseBridge configuration generated from Homebridge (\(source)) on \(stamp(date)).
        # Check it with:  housebridgectl validate
        # Lutron, Hue and rules are not part of Homebridge's Protect setup; add them below if you want them.

        \(unifiSection())
        \(homekitSection())
        # rules:
        #   - name: Front porch on when a person is seen
        #     when: { unifi: Front Camera, event: person, state: start }
        #     then:
        #       - action: light
        #         room: Front Porch
        #         on: true

        """
    }

    /// What was and was not carried over, for the person running the tool.
    public func report(source: String, accessories: [String] = []) -> String {
        var lines = ["Imported from \(source):"]
        lines.append("  • UniFi Protect controller \(primary.host), user “\(primary.username)”" +
                     (primary.password == nil ? " (no password in the Homebridge config)" : " (password found, not written to the YAML)"))
        if primary.username.contains("@") {
            lines.append("    ! “\(primary.username)” looks like an Ubiquiti SSO login. HouseBridge needs a *local* UniFi OS account, the same as the plugin did.")
        }
        if controllers.count > 1 { lines.append("  • \(controllers.count - 1) more controller(s) found but HouseBridge supports one; skipped") }
        if let bridgeName { lines.append("  • Homebridge bridge name “\(bridgeName)” (HouseBridge is a new bridge with its own name and pairing)") }
        if !accessories.isEmpty { lines.append("  • Homebridge currently exposes \(accessories.count) accessories to HomeKit") }
        lines.append("")
        lines.append("Not carried over:")
        lines.append("  • Home.app automations, rooms and renamed accessories (they live in Apple Home; HouseBridge's accessories are new, so redo them)")
        lines.append("  • Camera video and everything else the plugin exposed beyond motion, contact, leak and doorbell")
        for item in unmigrated { lines.append("  • \(item): HouseBridge has no equivalent, so this stays on Homebridge") }
        if !pluginOptions.isEmpty {
            lines.append("  • \(pluginOptions.count) plugin feature option(s): " + pluginOptions.prefix(8).joined(separator: ", ") + (pluginOptions.count > 8 ? ", …" : ""))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Config UI X API

/// Talks to Homebridge's web UI (homebridge-config-ui-x) to download `config.json` from the machine running it.
public final class HomebridgeUIClient: @unchecked Sendable {
    private let base: URL
    private let session: URLSession
    private var token: String?

    public init(baseURL: URL, hosts: KnownHosts) {
        base = baseURL
        session = URLSession(configuration: .ephemeral, delegate: PinningDelegate(hosts: hosts), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    private func send(_ method: String, _ path: String, json: Any? = nil, timeout: TimeInterval = 15) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// nil if this does not look like the Homebridge UI; otherwise whether it asks for a login.
    public func requiresLogin(timeout: TimeInterval = 4) async -> Bool? {
        guard let (status, data) = try? await send("GET", "api/auth/settings", timeout: timeout), status == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let formAuth = object["formAuth"] as? Bool else { return nil }
        return formAuth
    }

    public struct OTPRequired: Error {}

    /// Logs in (or takes the no-auth path when the UI has login turned off).
    public func authenticate(username: String?, password: String?, otp: String? = nil) async throws {
        let formAuth = await requiresLogin() ?? true
        var body: [String: Any] = [:]
        let path: String
        if formAuth {
            guard let username, let password else { throw HTTPFailure(status: 401, body: "the Homebridge UI needs a username and password") }
            body = ["username": username, "password": password]
            if let otp { body["otp"] = otp }
            path = "api/auth/login"
        } else {
            path = "api/auth/noauth"
        }
        let (status, data) = try await send("POST", path, json: body)
        if status == 412 { throw OTPRequired() }
        guard (200..<300).contains(status), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = object["access_token"] as? String else {
            throw HTTPFailure(status: status, body: String(decoding: data, as: UTF8.self))
        }
        token = access
    }

    /// The raw config.json.
    public func fetchConfig() async throws -> Data {
        let (status, data) = try await send("GET", "api/config-editor")
        guard status == 200 else { throw HTTPFailure(status: status, body: String(decoding: data, as: UTF8.self)) }
        return data
    }

    /// Names of the accessories Homebridge exposes right now. Informational only, so failures give an empty list.
    public func fetchAccessoryNames() async -> [String] {
        guard let (status, data) = try? await send("GET", "api/accessories"), status == 200,
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { $0["serviceName"] as? String }
    }
}

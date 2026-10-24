import Foundation
import Network

/// Builds a self-contained report (versions, sanitized config, certificate checks, live connectivity probes,
/// recent log lines) that is safe to paste into a chat or bug report: passwords and keys are never included.
public enum Diagnostics {
    public static func report(paths: Paths, configURL: URL, log: FileLog) async -> String {
        var out: [String] = []
        func section(_ title: String) { out.append("\n=== \(title) ===") }

        log.write(category: "diagnostics", message: "report requested")
        out.append("HouseBridge diagnostics — \(ISO8601DateFormatter().string(from: Date()))")
        section("Environment")
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        out.append("macOS \(os); executable \(CommandLine.arguments.first ?? "?")")
        out.append("home folder: \(paths.home.path)")
        out.append("log file: \(log.url.path)")

        out.append("NOTE: these tests run as whatever launched them. From Terminal they use Terminal's Local Network permission;")
        out.append("      from the menu bar app's Copy Diagnostics they use HouseBridge's. A pass in Terminal plus a fail in the app = permission.")

        section("Config file")
        out.append(configURL.path)
        var config: Config?
        if let text = try? String(contentsOf: configURL, encoding: .utf8) {
            out.append(sanitize(text))
            do { config = try ConfigLoader.load(from: configURL); out.append("→ parses OK (\(config!.rules.count) rules)") }
            catch { out.append("→ DOES NOT LOAD: \(error)") }
        } else {
            out.append("→ file not found or unreadable")
        }

        let hosts = KnownHosts(url: FileManager.default.temporaryDirectory.appendingPathComponent("hb-diag-\(UUID().uuidString).json"))

        if let l = config?.lutron {
            section("Lutron (\(l.host):\(l.port))")
            for (label, path) in [("ca", l.caPath), ("cert", l.certPath), ("key", l.keyPath)] {
                out.append("\(label): \(path) — \(fileSummary(path))")
            }
            out.append("TCP reachability: \(await tcpProbe(host: l.host, port: l.port))")
            if l.missingFiles().isEmpty {
                do {
                    _ = try LeapIdentity.load(certPath: l.certPath, keyPath: l.keyPath, caPath: l.caPath)
                    out.append("certificate + key load: OK")
                } catch { out.append("certificate + key load: FAILED — \(describeError(error))") }
                do {
                    let traceBox = TraceBox()
                    let inv = try await withTimeout(15) { try await LutronBridge.discover(config: l, trace: { traceBox.add($0) }) }
                    traceBox.lines.forEach { out.append("  [discovery] \($0)") }
                    out.append("LEAP session: OK — \(inv.devices.count) devices, \(inv.picos.count) with buttons, \(inv.switches.count) switches/dimmers")
                    for d in inv.picos {
                        let b = inv.buttons.filter { $0.deviceHref == d.href }.map { String($0.number) }.sorted().joined(separator: ",")
                        out.append("  remote “\(d.fullName)” [\(d.type)] buttons \(b)")
                    }
                    for d in inv.switches { out.append("  switch “\(d.fullName)” [\(d.type)]") }
                    if inv.picos.isEmpty, let raw = try? await withTimeout(20, { try await LutronBridge.rawDump(config: l, limit: 3500) }) {
                        out.append("No remotes found — raw bridge replies follow:\n" + raw)
                    }
                } catch { out.append("LEAP session: FAILED — \(describeError(error))") }
            }
        }

        if let h = config?.hue {
            section("Hue (\(h.host))")
            out.append("TCP reachability (443): \(await tcpProbe(host: h.host, port: 443))")
            out.append("pairing file: \(paths.hueFile.path) — " + (HueClient.load(from: paths.hueFile).map { $0.host == h.host ? "present for this host" : "present but for \($0.host)" } ?? "not paired"))
            do {
                let info = try await withTimeout(10) { try await hueBridgeInfo(host: h.host, hosts: hosts) }
                out.append("bridge responds (unauthenticated /api/config): \(info)")
            } catch { out.append("bridge request: FAILED — \(describeError(error))") }
            if let creds = HueClient.load(from: paths.hueFile), creds.host == h.host {
                do {
                    let inv = try await withTimeout(15) { try await HueClient(credentials: creds, hosts: KnownHosts(url: paths.knownHostsFile)).inventory(refresh: true) }
                    out.append("authenticated API: OK — \(inv.lights.count) lights, \(inv.rooms.count) rooms, \(inv.zones.count) zones, \(inv.scenes.count) scenes")
                } catch { out.append("authenticated API: FAILED — \(describeError(error))") }
            }
        }

        if let u = config?.unifi {
            section("UniFi (\(u.host))")
            out.append("TCP reachability (443): \(await tcpProbe(host: u.host, port: 443))")
            out.append("password source: \(passwordSource(u))")
            if u.resolvedPassword() != nil {
                do {
                    let inv = try await withTimeout(20) { try await ProtectClient(config: u, hosts: hosts).discover() }
                    out.append("login + bootstrap: OK — \(inv.items.filter { $0.kind == "camera" }.count) cameras, \(inv.items.filter { $0.kind == "sensor" }.count) sensors")
                    for i in inv.items { out.append("  \(i.kind) “\(i.name)” [\(i.model)]") }
                } catch { out.append("login + bootstrap: FAILED — \(describeError(error))") }
            }
        }

        if let hk = config?.homekit {
            section("HomeKit bridge (\(hk.name))")
            if let info = HomeKitBridge.pairingInfo(paths: paths) {
                out.append("device id: \(info.deviceID); accessories published: \(info.accessoryCount)")
                out.append(info.isPaired ? "paired controllers: \(info.controllers.count)" : "not paired yet (setup code is in `housebridgectl homekit`)")
            } else {
                out.append("no saved identity yet (created on first run)")
            }
        }

        section("Recent log (last 80 lines)")
        out.append(log.tail(lines: 80))
        return out.joined(separator: "\n")
    }

    static func passwordSource(_ u: UnifiConfig) -> String {
        if let p = u.password, !p.isEmpty { return "password: in config file" }
        if let name = u.passwordEnv, let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return "environment variable \(name)" }
        if Keychain.readPassword(host: u.host, username: u.username) != nil { return "macOS Keychain" }
        return "NONE FOUND (run: housebridgectl set-unifi-password)"
    }

    /// Masks anything that looks like a secret in the config text.
    static func sanitize(_ text: String) -> String {
        // Works for block style (`password: x`) and inline maps (`{ password: x, host: y }`).
        text.replacingOccurrences(of: #"(?<![A-Za-z_])(password|appKey|app_key|token|setup_code):[ \t]*[^,}\n]+"#,
                                  with: "$1: ********", options: .regularExpression)
    }

    static func fileSummary(_ path: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return "MISSING" }
        guard fm.isReadableFile(atPath: path) else { return "exists but NOT READABLE" }
        let attrs = try? fm.attributesOfItem(atPath: path)
        let size = attrs?[.size] as? Int ?? 0
        let perms = (attrs?[.posixPermissions] as? Int).map { String($0, radix: 8) } ?? "?"
        let first = (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n").first.map(String.init) ?? "(empty or not text)"
        return "\(size) bytes, mode \(perms), first line: \(first)"
    }

    static func tcpProbe(host: String, port: Int) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let once = Once()
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
            let queue = DispatchQueue(label: "hb.probe")
            let finish: @Sendable (String) -> Void = { s in if once.first() { conn.cancel(); cont.resume(returning: s) } }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish("open")
                case .failed(let e): finish("FAILED — \(e)")
                case .waiting(let e): finish("UNREACHABLE — \(e)")
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 4) { finish("TIMED OUT after 4s") }
        }
    }

    static func hueBridgeInfo(host: String, hosts: KnownHosts) async throws -> String {
        let session = URLSession(configuration: .ephemeral, delegate: PinningDelegate(hosts: hosts), delegateQueue: nil)
        let (data, response) = try await session.data(from: URL(string: "https://\(host)/api/config")!)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? parseJSON(data)) as? JSON
        let name = obj?["name"] as? String ?? "?", model = obj?["modelid"] as? String ?? "?", sw = obj?["swversion"] as? String ?? "?"
        return "HTTP \(code), name=\(name), model=\(model), software=\(sw)"
    }
}

struct TimeoutError: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "timed out after \(Int(seconds))s" }
}

func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask { try await Task.sleep(for: .seconds(seconds)); throw TimeoutError(seconds: seconds) }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

final class TraceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func add(_ s: String) { lock.withLock { _lines.append(s) } }
}

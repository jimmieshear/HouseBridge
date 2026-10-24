import Foundation

public struct LutronDevice: Sendable {
    public let href: String
    public let name: String
    public let fullName: String
    public let type: String
    public let model: String
    public let zoneHref: String?
    /// The room/area Lutron files the device under (everything before the device's own name), e.g. "Master Bedroom".
    public var area: String = ""
}

public struct LutronButton: Sendable {
    public let href: String
    public let number: Int
    public let deviceHref: String
}

public struct LutronInventory: Sendable {
    public var devices: [LutronDevice] = []
    public var buttons: [LutronButton] = []

    public var picos: [LutronDevice] {
        let withButtons = Set(buttons.map(\.deviceHref))
        return devices.filter { withButtons.contains($0.href) }
    }
    public var switches: [LutronDevice] { devices.filter { $0.zoneHref != nil } }

    public static func buttonName(number: Int) -> String {
        ["on", "favorite", "off", "raise", "lower"].indices.contains(number)
            ? ["on", "favorite", "off", "raise", "lower"][number] : "button_\(number)"
    }
}

public enum LutronError: Error, CustomStringConvertible {
    case notConnected
    case unknownSwitch(String, available: [String])
    case rejected(String)

    public var description: String {
        switch self {
        case .notConnected: return "Lutron bridge is not connected"
        case .unknownSwitch(let n, let a): return "no Lutron switch named ‘\(n)’ (known: \(a.joined(separator: ", ")))"
        case .rejected(let c): return "Lutron bridge rejected the command (\(c))"
        }
    }
}

/// Connects to a Caseta Smart Bridge, discovers Picos and wired switches, and turns their activity into TriggerEvents.
public final class LutronBridge: @unchecked Sendable {
    private let config: LutronConfig
    private let emit: @Sendable (TriggerEvent) -> Void
    private let status: @Sendable (ConnectionStatus) -> Void
    private let log: @Sendable (LogEntry) -> Void

    // Touched only from the connection queue / session setup, before events start flowing.
    private var buttonsByHref: [String: (LutronDevice, LutronButton)] = [:]
    private var devicesByZone: [String: LutronDevice] = [:]
    private var zoneState: [String: Bool] = [:]

    // Output side: written by the session, read by rule actions from any thread.
    private let outLock = NSLock()
    private var liveConnection: LeapConnection?
    private var switchDevices: [LutronDevice] = []
    private var offTimers: [String: Task<Void, Never>] = [:]

    public init(config: LutronConfig,
                emit: @escaping @Sendable (TriggerEvent) -> Void,
                status: @escaping @Sendable (ConnectionStatus) -> Void,
                log: @escaping @Sendable (LogEntry) -> Void) {
        self.config = config
        self.emit = emit
        self.status = status
        self.log = log
    }

    // MARK: Discovery (used by `housebridgectl list lutron`)

    public static func discover(config: LutronConfig, trace: (@Sendable (String) -> Void)? = nil) async throws -> LutronInventory {
        let (identity, ca) = try LeapIdentity.load(certPath: config.certPath, keyPath: config.keyPath, caPath: config.caPath)
        let conn = LeapConnection(host: config.host, port: config.port, identity: identity, ca: ca)
        try await conn.start()
        defer { conn.close() }
        return try await loadInventory(conn, trace: trace)
    }

    /// Raw LEAP responses for the endpoints discovery relies on (truncated); used to see what the bridge really returns.
    public static func rawDump(config: LutronConfig, limit: Int = 6000) async throws -> String {
        let (identity, ca) = try LeapIdentity.load(certPath: config.certPath, keyPath: config.keyPath, caPath: config.caPath)
        let conn = LeapConnection(host: config.host, port: config.port, identity: identity, ca: ca)
        try await conn.start()
        defer { conn.close() }
        var out = ""
        for url in ["/device", "/buttongroup/expanded", "/button", "/buttongroup"] {
            out += "--- ReadRequest \(url)\n"
            do {
                let r = try await conn.request("ReadRequest", url)
                let data = (try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                let text = String(decoding: data, as: UTF8.self)
                out += text.count > limit ? String(text.prefix(limit)) + "\n… (\(text.count - limit) more characters)\n" : text + "\n"
            } catch { out += "FAILED: \(describeError(error))\n" }
        }
        return out
    }

    private static func status(of response: JSON) -> String {
        (response["Header"] as? JSON)?["StatusCode"] as? String ?? "no status"
    }

    static func loadInventory(_ conn: LeapConnection, trace: (@Sendable (String) -> Void)? = nil) async throws -> LutronInventory {
        var inv = LutronInventory()
        var groupToDevice: [String: String] = [:]
        let devices = try await conn.request("ReadRequest", "/device")
        let deviceList = ((devices["Body"] as? JSON)?["Devices"] as? [JSON]) ?? []
        trace?("/device → \(status(of: devices)), \(deviceList.count) entries")
        for d in deviceList {
            guard let href = d["href"] as? String, let name = d["Name"] as? String else { continue }
            let type = d["DeviceType"] as? String ?? ""
            for g in (d["ButtonGroups"] as? [JSON]) ?? [] { if let gh = g["href"] as? String { groupToDevice[gh] = href } }
            if type == "SmartBridge" || type == "SmartBridgePro" { continue }
            let fqn = (d["FullyQualifiedName"] as? [String])?.joined(separator: " ") ?? name
            let zone = ((d["LocalZones"] as? [JSON])?.first)?["href"] as? String
            let parts = (d["FullyQualifiedName"] as? [String]) ?? []
            inv.devices.append(LutronDevice(href: href, name: name, fullName: fqn, type: type,
                                            model: d["ModelNumber"] as? String ?? "", zoneHref: zone,
                                            area: parts.dropLast().joined(separator: " ")))
        }
        let types = Dictionary(grouping: inv.devices, by: \.type).mapValues(\.count).sorted { $0.key < $1.key }
        trace?("device types: " + types.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
        trace?("devices with button groups: \(groupToDevice.values.count)")

        func add(_ href: String?, _ number: Int?, parent: String?) {
            guard let href, let number, let parent else { return }
            let device = parent.hasPrefix("/device") ? parent : (groupToDevice[parent] ?? "")
            guard !device.isEmpty, !inv.buttons.contains(where: { $0.href == href }) else { return }
            inv.buttons.append(LutronButton(href: href, number: number, deviceHref: device))
        }

        // 1) Expanded button groups: groups carry their parent device and their buttons.
        if let r = try? await conn.request("ReadRequest", "/buttongroup/expanded") {
            let groups = ((r["Body"] as? JSON)?["ButtonGroupsExpanded"] as? [JSON]) ?? []
            trace?("/buttongroup/expanded → \(status(of: r)), \(groups.count) groups")
            for g in groups {
                let parent = (g["Parent"] as? JSON)?["href"] as? String
                for b in (g["Buttons"] as? [JSON]) ?? [] { add(b["href"] as? String, b["ButtonNumber"] as? Int, parent: parent) }
            }
        }
        // 2) Flat button list.
        if inv.buttons.isEmpty, let r = try? await conn.request("ReadRequest", "/button") {
            let list = ((r["Body"] as? JSON)?["Buttons"] as? [JSON]) ?? []
            trace?("/button → \(status(of: r)), \(list.count) buttons")
            for b in list { add(b["href"] as? String, b["ButtonNumber"] as? Int, parent: (b["Parent"] as? JSON)?["href"] as? String) }
        }
        // 3) Walk each device's button groups and read their buttons one by one.
        if inv.buttons.isEmpty {
            for (group, device) in groupToDevice.sorted(by: { $0.key < $1.key }) {
                guard let r = try? await conn.request("ReadRequest", group),
                      let buttons = ((r["Body"] as? JSON)?["ButtonGroup"] as? JSON)?["Buttons"] as? [JSON] else { continue }
                for b in buttons {
                    guard let bh = b["href"] as? String, let br = try? await conn.request("ReadRequest", bh),
                          let detail = (br["Body"] as? JSON)?["Button"] as? JSON else { continue }
                    add(bh, detail["ButtonNumber"] as? Int, parent: device)
                }
            }
            trace?("per-group walk found \(inv.buttons.count) buttons")
        }
        trace?("result: \(inv.picos.count) devices with buttons, \(inv.buttons.count) buttons, \(inv.switches.count) switches/dimmers")
        return inv
    }

    // MARK: Run loop

    public func run() async {
        var backoff: Double = 2
        while !Task.isCancelled {
            status(.connecting)
            var upSince: Date?
            do {
                try await session(onConnected: { upSince = Date() })
                if Task.isCancelled { return }
                status(.disconnected("connection closed"))
            } catch {
                if Task.isCancelled { return }
                let hint = localNetworkHint(for: error, host: config.host)
                log(LogEntry(level: .warning, category: "lutron", message: describeError(error) + (hint.map { "\n" + $0 } ?? "")))
                status(.disconnected(hint != nil ? "can't reach \(config.host) — check Local Network permission (see log)" : "\(error)"))
            }
            if let up = upSince, Date().timeIntervalSince(up) > 60 { backoff = 2 } else { backoff = min(backoff * 2, 60) }
            try? await Task.sleep(for: .seconds(backoff))
        }
    }

    private func session(onConnected: () -> Void) async throws {
        let (identity, ca) = try LeapIdentity.load(certPath: config.certPath, keyPath: config.keyPath, caPath: config.caPath)
        let conn = LeapConnection(host: config.host, port: config.port, identity: identity, ca: ca)
        conn.onMessage = { [weak self] in self?.handle($0) }
        try await conn.start()
        defer { conn.close() }

        let inv = try await LutronBridge.loadInventory(conn, trace: { [log] in log(LogEntry(category: "lutron", message: "discovery: \($0)")) })
        buttonsByHref = [:]
        devicesByZone = [:]
        zoneState = [:]
        let devicesByHref = Dictionary(inv.devices.map { ($0.href, $0) }, uniquingKeysWith: { a, _ in a })
        for b in inv.buttons {
            if let device = devicesByHref[b.deviceHref] { buttonsByHref[b.href] = (device, b) }
        }
        for d in inv.switches { if let z = d.zoneHref { devicesByZone[z] = d } }
        outLock.withLock { liveConnection = conn; switchDevices = inv.switches }
        defer { outLock.withLock { if liveConnection === conn { liveConnection = nil } } }

        for href in buttonsByHref.keys {
            _ = try await conn.request("SubscribeRequest", "\(href)/status/event")
        }
        let zones = try await conn.request("SubscribeRequest", "/zone/status")
        for item in ((zones["Body"] as? JSON)?["ZoneStatuses"] as? [JSON]) ?? [] { prime(item) }

        onConnected()
        status(.connected("\(inv.picos.count) Pico/keypad, \(inv.switches.count) switch/dimmer"))
        log(LogEntry(category: "lutron", message: "connected: \(inv.picos.count) remotes, \(inv.switches.count) wired switches/dimmers"))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await conn.waitUntilClosed(); throw LeapError.closed }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(60))
                    _ = try await conn.request("ReadRequest", "/server/1/status/ping")
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: Output

    /// Turns a switch/dimmer on or off. `device` matches the full name, name, href or model, case-insensitively.
    /// With `offAfter`, schedules an off that any later call for the same device replaces.
    public func setSwitch(_ device: String, on: Bool, offAfter: TimeInterval? = nil) async throws {
        let wanted = device.lowercased()
        let (conn, candidates) = outLock.withLock { (liveConnection, switchDevices) }
        guard let conn else { throw LutronError.notConnected }
        let matches = candidates.filter { [$0.fullName, $0.name, $0.href, $0.model].contains { $0.lowercased() == wanted } }
        guard let target = matches.first, let zone = target.zoneHref else {
            throw LutronError.unknownSwitch(device, available: candidates.map(\.fullName).sorted())
        }
        outLock.withLock { offTimers.removeValue(forKey: zone)?.cancel() }
        try await LutronBridge.goToLevel(conn, zone: zone, level: on ? 100 : 0)
        guard on, let offAfter else { return }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(offAfter))
            guard !Task.isCancelled, let self else { return }
            self.outLock.withLock { _ = self.offTimers.removeValue(forKey: zone) }
            do { try await self.setSwitch(device, on: false) }
            catch { self.log(LogEntry(level: .error, category: "lutron", message: "turning \(target.fullName) off failed: \(describeError(error))")) }
        }
        outLock.withLock { offTimers[zone] = timer }
    }

    static func goToLevel(_ conn: LeapConnection, zone: String, level: Int) async throws {
        let body: JSON = ["Command": ["CommandType": "GoToLevel", "Parameter": [["Type": "Level", "Value": level]]]]
        let response = try await conn.request("CreateRequest", "\(zone)/commandprocessor", body: body)
        let code = status(of: response)
        guard code.hasPrefix("2") else { throw LutronError.rejected(code) }
    }

    // MARK: Message handling

    private func handle(_ message: JSON) {
        guard let body = message["Body"] as? JSON else { return }
        if let status = body["ButtonStatus"] as? JSON {
            handleButton(status)
        } else if let zone = body["ZoneStatus"] as? JSON {
            handleZone(zone)
        } else if let zones = body["ZoneStatuses"] as? [JSON] {
            zones.forEach(handleZone)
        }
    }

    private func handleButton(_ status: JSON) {
        guard let href = (status["Button"] as? JSON)?["href"] as? String,
              let (device, button) = buttonsByHref[href],
              let type = (status["ButtonEvent"] as? JSON)?["EventType"] as? String else { return }
        let kind: String
        switch type {
        case "Press": kind = "press"
        case "Release": kind = "release"
        default: return // LongHold / MultiTap: HouseBridge derives its own gestures from press/release timing.
        }
        let name = LutronInventory.buttonName(number: button.number)
        emit(TriggerEvent(source: .pico, device: device.fullName,
                          deviceAliases: [device.name, device.href, device.model],
                          input: name, inputAliases: ["button_\(button.number)", String(button.number)], kind: kind))
    }

    private func zoneIsOn(_ zone: JSON) -> Bool? {
        if let s = zone["SwitchedLevel"] as? String { return s == "On" }
        if let level = zone["Level"] as? Int { return level > 0 }
        return nil
    }

    private func prime(_ zone: JSON) {
        guard let href = (zone["Zone"] as? JSON)?["href"] as? String, let on = zoneIsOn(zone) else { return }
        zoneState[href] = on
    }

    private func handleZone(_ zone: JSON) {
        guard let href = (zone["Zone"] as? JSON)?["href"] as? String, let on = zoneIsOn(zone),
              let device = devicesByZone[href] else { return }
        defer { zoneState[href] = on }
        guard zoneState[href] != on else { return } // level-only changes on a dimmer
        let level = zone["Level"] as? Int
        emit(TriggerEvent(source: .lutronSwitch, device: device.fullName,
                          deviceAliases: [device.name, device.href, device.model],
                          input: "power", kind: on ? "on" : "off", detail: level.map { "level \($0)" }))
    }
}

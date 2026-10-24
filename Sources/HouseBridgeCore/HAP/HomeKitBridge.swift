import Foundation

public struct HomeKitConfig: Sendable {
    /// Name of the bridge in Home.app.
    public var name = "HouseBridge"
    /// TCP port; nil lets the system pick (Bonjour tells HomeKit where it landed).
    public var port: Int?
    /// `XXX-XX-XXX`; generated and remembered when not set.
    public var setupCode: String?
    /// Also publish a motion sensor per smart detection (person, vehicle, ...), not just plain motion.
    public var smartDetections = false
    public init() {}
}

public struct HomeKitPairingInfo: Sendable {
    public var setupCode: String
    public var setupURI: String
    public var deviceID: String
    public var controllers: [String]
    public var accessoryCount: Int
    public var isPaired: Bool { !controllers.isEmpty }
}

/// Publishes Protect cameras and sensors to Apple Home as a HomeKit bridge (motion, contact, leak, doorbell).
/// Fed by the same Protect connection the rules use; it never talks to the console itself.
public final class HomeKitBridge: @unchecked Sendable {
    private let config: HomeKitConfig
    private let paths: Paths
    private let log: @Sendable (LogEntry) -> Void
    private let status: @Sendable (ConnectionStatus) -> Void
    private let queue = DispatchQueue(label: "housebridge.homekit")

    private var lockDescriptor: Int32 = -1
    private var store: HAPStore?
    private var server: HAPServer?
    private var listener: HAPListener?
    private var routes: [String: HAPRoute] = [:]
    private var pendingInventory: [ProtectInventory.Item]?
    private var running = false

    public init(config: HomeKitConfig, paths: Paths,
                log: @escaping @Sendable (LogEntry) -> Void,
                status: @escaping @Sendable (ConnectionStatus) -> Void) {
        self.config = config
        self.paths = paths
        self.log = log
        self.status = status
    }

    // MARK: Pairing info (for the CLI and menu bar app)

    /// Reads the saved identity. With `create`, a missing one is made (so a setup code can be shown before the first run).
    public static func pairingInfo(paths: Paths, setupCode: String? = nil, create: Bool = false) -> HomeKitPairingInfo? {
        let url = paths.homeKitFile
        guard create || FileManager.default.fileExists(atPath: url.path) else { return nil }
        let store = HAPStore(url: url, setupCode: setupCode)
        return HomeKitPairingInfo(setupCode: store.state.setupCode, setupURI: store.setupURI, deviceID: store.state.deviceID,
                                  controllers: store.state.pairings.map(\.id), accessoryCount: store.state.devices.count)
    }

    /// Deletes the bridge identity and every pairing. Home.app must remove the old bridge by hand afterwards.
    /// Returns false when a running HouseBridge currently owns it.
    public static func reset(paths: Paths) -> Bool {
        guard let fd = HomeKitBridge.lock(paths.homeKitLockFile) else { return false }
        defer { close(fd) }
        try? FileManager.default.removeItem(at: paths.homeKitFile)
        return true
    }

    private static func lock(_ url: URL) -> Int32? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        close(fd)
        return nil
    }

    // MARK: Lifecycle

    public func start() {
        queue.async { self.startOnQueue() }
    }

    /// Synchronous so a replacement bridge (after a config reload) can take over the lock and identity.
    public func stop() {
        queue.sync {
            running = false
            listener?.stop()
            listener = nil
            server = nil
            store = nil
            if lockDescriptor >= 0 { close(lockDescriptor); lockDescriptor = -1 }
        }
    }

    private func emit(_ message: String, _ level: LogLevel = .info) {
        log(LogEntry(level: level, category: "homekit", message: message))
    }

    private func startOnQueue() {
        guard let fd = HomeKitBridge.lock(paths.homeKitLockFile) else {
            status(.needsSetup("another HouseBridge is already running the HomeKit bridge"))
            emit("HomeKit bridge not started: another HouseBridge process already owns it (quit it first)", .warning)
            return
        }
        lockDescriptor = fd
        running = true
        status(.connecting)

        let store = HAPStore(url: paths.homeKitFile, setupCode: config.setupCode)
        let server = HAPServer(store: store)
        server.log = { [weak self] message in self?.emit(message) }
        server.onPairingsChanged = { [weak self] in self?.pairingsChanged() }
        self.store = store
        self.server = server
        applyDevices(store.state.devices)

        let listener = HAPListener(server: server, queue: queue, name: config.name, txt: { [weak self] in self?.txtRecord() ?? [:] },
                                   log: { [weak self] in self?.emit($0) })
        self.listener = listener
        do {
            try listener.start(port: config.port.flatMap { UInt16(exactly: $0) }, ready: { [weak self] port in
                self?.queue.async {
                    guard let self, self.running else { return }
                    self.emit("listening on port \(port)")
                    self.reportStatus()
                }
            }, failed: { [weak self] error in
                self?.queue.async {
                    self?.status(.disconnected("listener failed: \(error)"))
                    self?.emit("listener failed: \(describeError(error))", .error)
                }
            })
        } catch {
            status(.disconnected("could not listen: \(error)"))
            emit("could not start listener: \(describeError(error))", .error)
            return
        }
        if let pending = pendingInventory { pendingInventory = nil; applyInventory(pending) }
        if !store.isPaired { emit("not paired yet — in Home.app choose Add Accessory and enter code \(store.state.setupCode)") }
    }

    private func txtRecord() -> [String: String] {
        guard let store else { return [:] }
        return ["c#": String(store.state.configNumber), "ff": "0", "id": store.state.deviceID, "md": "HouseBridge", "pv": "1.1",
                "s#": "1", "sf": store.isPaired ? "0" : "1", "ci": String(HAPStore.categoryBridge), "sh": store.setupHash]
    }

    private func pairingsChanged() {
        listener?.refreshAdvertisement()
        reportStatus()
    }

    private func reportStatus() {
        guard let store else { return }
        if store.isPaired {
            let n = store.state.pairings.count
            status(.connected("\(n) controller\(n == 1 ? "" : "s"), \(store.state.devices.count) accessories"))
        } else {
            status(.needsSetup("add to Home.app with code \(store.state.setupCode)"))
        }
    }

    // MARK: Accessories

    private func applyDevices(_ devices: [HAPDevice]) {
        guard let store, let server else { return }
        store.mutate { state in
            for device in devices where state.aids[device.id] == nil {
                state.aids[device.id] = state.nextAid
                state.nextAid += 1
            }
            state.devices = devices
        }
        let placed = devices.map { (device: $0, aid: store.state.aids[$0.id] ?? 0) }.sorted { $0.aid < $1.aid }
        let built = HAPLayout.build(bridgeName: config.name, bridgeID: store.state.deviceID, devices: placed,
                                    smartDetections: config.smartDetections)
        routes = built.routes
        server.setAccessories(built.accessories)
        let fingerprint = HAPLayout.fingerprint(built.accessories)
        if fingerprint != store.state.layoutHash {
            store.mutate { state in
                state.layoutHash = fingerprint
                state.configNumber = state.configNumber >= Int(UInt32.max) ? 1 : state.configNumber + 1
            }
            listener?.refreshAdvertisement()   // controllers re-read the accessory list when c# changes
            emit("accessory list changed (\(built.accessories.count - 1) accessories, c#\(store.state.configNumber))")
        }
        reportStatus()
    }

    /// Called with the console's current devices after every (re)connect.
    public func updateInventory(_ inventory: ProtectInventory) {
        queue.async {
            guard self.running else { return }
            if self.server == nil { self.pendingInventory = inventory.items } else { self.applyInventory(inventory.items) }
        }
    }

    private func applyInventory(_ items: [ProtectInventory.Item]) {
        let devices = items.map { HAPDevice(id: $0.id, name: $0.name, model: $0.model, kind: $0.kind, provides: $0.provides) }
        if devices != store?.state.devices { applyDevices(devices) }
        for item in items {
            for (input, on) in item.state { set(deviceID: item.id, input: input, on: on) }
        }
    }

    // MARK: Events

    public func handle(_ event: TriggerEvent) {
        guard event.source == .unifi, let id = event.deviceID else { return }
        queue.async {
            guard self.running, let server = self.server, let route = self.routes["\(id)|\(event.input)"] else { return }
            switch (route.kind, event.kind) {
            case (.motion, "start"), (.leak, "start"): self.set(route, true)
            case (.motion, "end"), (.leak, "end"): self.set(route, false)
            case (.contact, "open"): self.set(route, true)
            case (.contact, "closed"): self.set(route, false)
            case (.button, "start"): server.fireEvent(route.key, value: .int(0))   // 0 = single press
            default: break
            }
        }
    }

    private func set(deviceID: String, input: String, on: Bool) {
        guard let route = routes["\(deviceID)|\(input)"] else { return }
        set(route, on)
    }

    private func set(_ route: HAPRoute, _ on: Bool) {
        switch route.kind {
        case .motion: server?.setValue(route.key, .bool(on))
        case .contact, .leak: server?.setValue(route.key, .int(on ? 1 : 0))   // contact: 1 = open, leak: 1 = detected
        case .button: break
        }
    }
}

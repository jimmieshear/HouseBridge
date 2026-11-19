import Foundation

final class ActiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = true
    var isOn: Bool { lock.withLock { on } }
    func turnOff() { lock.withLock { on = false } }
}

/// Sends `lutron` actions to the Lutron bridge, `plug` actions to Kasa and everything else to Hue.
final class ActionRouter: ActionExecutor, @unchecked Sendable {
    private let hue: ActionExecutor
    private let log: @Sendable (LogEntry) -> Void
    private let lock = NSLock()
    private var _lutron: LutronBridge?
    var lutron: LutronBridge? {
        get { lock.withLock { _lutron } }
        set { lock.withLock { _lutron = newValue } }
    }

    init(hue: ActionExecutor, log: @escaping @Sendable (LogEntry) -> Void) { self.hue = hue; self.log = log }

    /// nil in dry-run, so a rehearsal never starts a Shortcut.
    var shortcuts: ShortcutRunner? {
        get { lock.withLock { _shortcuts } }
        set { lock.withLock { _shortcuts = newValue } }
    }
    private var _shortcuts: ShortcutRunner?

    private var _kasa: KasaBridge?
    var kasa: KasaBridge? {
        get { lock.withLock { _kasa } }
        set { lock.withLock { _kasa = newValue } }
    }

    func execute(_ action: Action) async throws {
        switch action {
        case .alarm(.lutron(let device, let on)):
            return try await execute(.lutron(device: device, on: on, offAfterSeconds: nil))
        case .alarm(.soundStart(let name)):
            guard let runner = shortcuts else { log(LogEntry(category: "dry-run", message: "would run Shortcut ‘\(name)’")); return }
            return try runner.start(name)
        case .alarm(.soundStop(let started, let stop)):
            guard let runner = shortcuts else { log(LogEntry(category: "dry-run", message: "would stop Shortcut ‘\(started)’")); return }
            return await runner.stop(started: started, stop: stop)
        default: break
        }
        if case .plug(let device, let on, let offAfter) = action {
            guard let bridge = kasa else {
                log(LogEntry(category: "dry-run", message: "would run \(action)"))
                return
            }
            return try await bridge.setPlug(device, on: on, offAfter: offAfter)
        }
        guard case .lutron(let device, let on, let offAfter) = action else { return try await hue.execute(action) }
        guard let bridge = lutron else {
            log(LogEntry(category: "dry-run", message: "would run \(action)"))
            return
        }
        try await bridge.setSwitch(device, on: on, offAfter: offAfter)
    }
}

/// Lets the rule engine (built first) reach the HomeKit bridge (built after it).
private final class SwitchRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var bridge: HomeKitBridge?
    func attach(_ bridge: HomeKitBridge?) { lock.lock(); self.bridge = bridge; lock.unlock() }
    func set(_ name: String, _ on: Bool) { lock.lock(); let b = bridge; lock.unlock(); b?.setSwitch(name, on: on) }
    func setOutlet(_ name: String, _ on: Bool) { lock.lock(); let b = bridge; lock.unlock(); b?.setOutlet(name, on: on) }
}

/// Lets the HomeKit bridge (built before the Protect client) ask the client for snapshots.
private final class SnapshotRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var client: ProtectClient?
    func attach(_ client: ProtectClient) { lock.withLock { self.client = client } }
    func snapshot(_ id: String, _ width: Int, _ height: Int) async -> Data? {
        guard let client = lock.withLock({ client }) else { return nil }
        return try? await client.snapshot(cameraID: id, width: width, height: height)
    }
}

/// Wires the configured sources (Lutron, UniFi) to the rule engine and Hue. One Hub per loaded config.
public final class Hub: @unchecked Sendable {
    public let config: Config
    private let paths: Paths
    private let dryRun: Bool
    private let hosts: KnownHosts
    public let fileLog: FileLog
    private let logSink: @Sendable (LogEntry) -> Void
    private let statusSink: @Sendable (Subsystem, ConnectionStatus) -> Void
    private let eventSink: @Sendable (TriggerEvent) -> Void
    private var engine: RuleEngine?
    private var homekit: HomeKitBridge?
    private var kasaBridge: KasaBridge?
    private var tasks: [Task<Void, Never>] = []
    private let active = ActiveFlag()

    public init(config: Config, paths: Paths, dryRun: Bool = false,
                log: @escaping @Sendable (LogEntry) -> Void,
                status: @escaping @Sendable (Subsystem, ConnectionStatus) -> Void,
                onEvent: @escaping @Sendable (TriggerEvent) -> Void = { _ in }) {
        self.config = config
        self.paths = paths
        self.dryRun = dryRun
        self.hosts = KnownHosts(url: paths.knownHostsFile)
        let fileLog = FileLog(directory: paths.logsDirectory)
        self.fileLog = fileLog
        // Everything the UI sees is also written to ~/.config/housebridge/logs/housebridge.log
        let active = self.active
        self.logSink = { entry in guard active.isOn else { return }; fileLog.write(entry); log(entry) }
        self.statusSink = { subsystem, st in
            guard active.isOn else { return }   // a stopped hub must not overwrite its replacement's status
            fileLog.write(category: subsystem.rawValue, message: "status: \(st.label)")
            status(subsystem, st)
        }
        self.eventSink = { event in
            guard active.isOn else { return }
            fileLog.write(category: "event", message: event.summary)
            onEvent(event)
        }
    }

    public func start() {
        let log = logSink
        log(LogEntry(category: "hub", message: "starting: \(config.rules.count) rule(s), lutron=\(config.lutron != nil), hue=\(config.hue != nil), unifi=\(config.unifi != nil), kasa=\(config.kasa != nil), homekit=\(config.homekit != nil), dryRun=\(dryRun)"))
        let status = statusSink

        // Hue (the output side)
        let executor: ActionExecutor
        if dryRun {
            executor = DryRunExecutor(log: log)
            status(.hue, config.hue == nil ? .notConfigured : .connected("dry run"))
        } else if let hue = config.hue {
            if let creds = HueClient.load(from: paths.hueFile), creds.host == hue.host {
                let client = HueClient(credentials: creds, hosts: hosts)
                executor = HueActions(client: client)
                if let defaults = config.lightDefaults {
                    let verifier = LightTemperatureVerifier(client: client, defaults: defaults, log: log)
                    tasks.append(Task { await verifier.run() })
                }
                status(.hue, .connecting)
                // Keeps the status honest: a cheap ping every minute while healthy; while down, a retry every 30 s that
                // reloads the inventory on success. Each outage and recovery is logged once.
                tasks.append(Task {
                    var healthy = false, failedBefore = false
                    while !Task.isCancelled {
                        do {
                            if healthy { try await client.ping() }
                            else {
                                let inv = try await client.inventory(refresh: true)
                                status(.hue, .connected("\(inv.lights.count) lights, \(inv.rooms.count) rooms, \(inv.scenes.count) scenes"))
                                if failedBefore { log(LogEntry(category: "hue", message: "Hue bridge is reachable again")) }
                                healthy = true; failedBefore = false
                            }
                        } catch {
                            if healthy || !failedBefore {
                                let hint = localNetworkHint(for: error, host: hue.host)
                                log(LogEntry(level: .error, category: "hue", message: describeError(error) + (hint.map { "\n" + $0 } ?? "")))
                                status(.hue, .disconnected(hint != nil ? "can't reach \(hue.host) — check Local Network permission (see log)" : "\(error)"))
                            }
                            healthy = false; failedBefore = true
                        }
                        try? await Task.sleep(for: .seconds(healthy ? 60 : 30))
                    }
                })
            } else {
                executor = DryRunExecutor(log: log)
                status(.hue, .needsSetup("run: housebridgectl pair-hue"))
                log(LogEntry(level: .warning, category: "hue", message: "Hue bridge not paired for \(hue.host); actions will only be logged. Run: housebridgectl pair-hue"))
            }
        } else {
            executor = DryRunExecutor(log: log)
            status(.hue, .notConfigured)
        }

        // Lutron (input, and output for `lutron` actions)
        var lutronBridge: LutronBridge?
        let router = ActionRouter(hue: executor, log: log)
        if !dryRun { router.shortcuts = ShortcutRunner(log: log) }
        // Dry runs must not touch the real hold state.
        let relay = SwitchRelay()
        let snapshotRelay = SnapshotRelay()
        let engine = RuleEngine(config: config, executor: router, onEvent: eventSink,
                                holdStore: dryRun ? nil : HoldStore(url: paths.holdsFile),
                                overrideStore: dryRun ? nil : HoldStore(url: paths.overridesFile),
                                skipStore: dryRun ? nil : HoldStore(url: paths.skipsFile),
                                onSwitch: { relay.set($0, $1) },
                                cancelLutronTimers: { [weak router] in router?.lutron?.cancelOffTimers(for: $0) },
                                cancelPlugTimers: { [weak router] in router?.kasa?.cancelOffTimers(for: $0) },
                                catchUpOnStart: dryRun ? nil : 5, log: log)
        self.engine = engine
        Task { await engine.start() }

        let schedules = config.rules.filter(\.enabled).compactMap(\.trigger.schedule)
        if !schedules.isEmpty {
            let scheduler = ClockScheduler(schedules: schedules, location: config.location, emit: { engine.submit($0) },
                                          onWake: { [dryRun] in if !dryRun { Task { await engine.catchUp(reason: "wake") } } }, log: log)
            tasks.append(Task { await scheduler.run() })
        }

        if let lutron = config.lutron, case let missing = lutron.missingFiles(), !missing.isEmpty {
            status(.lutron, .needsSetup("PEM file not found"))
            log(LogEntry(level: .error, category: "lutron", message: "Cannot read Lutron certificate file(s) — fix the paths under 'lutron:' in the config:\n  " + missing.joined(separator: "\n  ")))
        } else if let lutron = config.lutron {
            let bridge = LutronBridge(config: lutron, emit: { engine.submit($0) },
                                      status: { status(.lutron, $0) }, log: log)
            lutronBridge = dryRun ? nil : bridge
            router.lutron = lutronBridge
            tasks.append(Task { await bridge.run() })
        } else {
            status(.lutron, .notConfigured)
        }

        if let kasa = config.kasa {
            if dryRun {
                status(.kasa, .connected("dry run"))
            } else {
                let bridge = KasaBridge(config: kasa, log: log, status: { status(.kasa, $0) })
                router.kasa = bridge
                kasaBridge = bridge   // its monitor starts below, once the HomeKit outlets can receive its readings
            }
        } else {
            status(.kasa, .notConfigured)
        }

        if let hk = config.homekit {
            if dryRun {
                status(.homekit, .notConfigured)
                log(LogEntry(category: "homekit", message: "HomeKit bridge is not started in dry-run mode"))
            } else {
                let bridge = HomeKitBridge(config: hk, paths: paths, switches: config.homekitSwitches,
                                           onSwitchWrite: { name, on in Task { await engine.setSwitch(name, on: on) } },
                                           outlets: config.homekitOutlets,
                                           onOutletWrite: { [weak router] name, on in
                                               Task {
                                                   guard let kasa = router?.kasa else { return }
                                                   do { try await kasa.setPlug(name, on: on) }
                                                   catch {
                                                       log(LogEntry(level: .error, category: "homekit", message: "switching ‘\(name)’ from Home.app failed: \(describeError(error))"))
                                                       if let real = await kasa.isOn(name) { relay.setOutlet(name, real) }   // put Home.app back
                                                   }
                                               }
                                           },
                                           snapshots: { await snapshotRelay.snapshot($0, $1, $2) },
                                           streaming: config.unifi.map { HomeKitStreaming(host: $0.host, hosts: hosts) },
                                           log: log, status: { status(.homekit, $0) })
                homekit = bridge
                relay.attach(bridge)
                bridge.start()
            }
        } else {
            status(.homekit, .notConfigured)
        }
        let homekit = self.homekit
        // Keep Home.app's outlets in step with the plugs: changes made through HouseBridge arrive at once, changes made
        // elsewhere (Kasa app, the plug's button) within a minute.
        if let kasa = kasaBridge {
            let outlets = Set(config.homekitOutlets.map { $0.lowercased() })
            if !outlets.isEmpty {
                kasa.onChange = { name, on in relay.setOutlet(name, on) }
                kasa.onState = { name, on in if outlets.contains(name.lowercased()) { relay.setOutlet(name, on) } }
            }
            tasks.append(Task { await kasa.monitor() })
        }

        if let unifi = config.unifi {
            if unifi.resolvedPassword() == nil {
                status(.unifi, .needsSetup("no password: run housebridgectl set-unifi-password"))
                log(LogEntry(level: .warning, category: "unifi", message: "No UniFi password found. Store it in the Keychain with: housebridgectl set-unifi-password (or set unifi.password / unifi.password_env)"))
            } else {
                let client = ProtectClient(config: unifi, hosts: hosts, emit: { engine.submit($0); homekit?.handle($0) },
                                           onInventory: { homekit?.updateInventory($0) },
                                           status: { status(.unifi, $0) }, log: log)
                snapshotRelay.attach(client)
                tasks.append(Task { await client.run() })
            }
        } else {
            status(.unifi, .notConfigured)
        }
    }

    /// "Run now" for a scheduled rule (see `RuleEngine.runNow`).
    public func runRuleNow(_ name: String) {
        guard let engine else { return }
        Task { await engine.runNow(name) }
    }

    /// Skips one occurrence of a scheduled rule, or takes the skip back (see `RuleEngine.skip`).
    public func skipRule(_ name: String, at date: Date, undo: Bool = false) {
        guard let engine else { return }
        Task { if undo { await engine.unskip(name, at: date) } else { await engine.skip(name, at: date) } }
    }

    public func stop() {
        active.turnOff()
        tasks.forEach { $0.cancel() }
        tasks = []
        if let engine { Task { await engine.stop() } }
        engine = nil
        homekit?.stop()
        homekit = nil
        kasaBridge?.stop()
        kasaBridge = nil
    }
}

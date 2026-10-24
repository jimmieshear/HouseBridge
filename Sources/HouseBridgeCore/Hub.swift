import Foundation

final class ActiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = true
    var isOn: Bool { lock.withLock { on } }
    func turnOff() { lock.withLock { on = false } }
}

/// Sends `lutron` actions to the Lutron bridge and everything else to Hue.
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

    func execute(_ action: Action) async throws {
        guard case .lutron(let device, let on, let offAfter) = action else { return try await hue.execute(action) }
        guard let bridge = lutron else {
            log(LogEntry(category: "dry-run", message: "would run \(action)"))
            return
        }
        try await bridge.setSwitch(device, on: on, offAfter: offAfter)
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
        log(LogEntry(category: "hub", message: "starting: \(config.rules.count) rule(s), lutron=\(config.lutron != nil), hue=\(config.hue != nil), unifi=\(config.unifi != nil), homekit=\(config.homekit != nil), dryRun=\(dryRun)"))
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
                status(.hue, .connecting)
                tasks.append(Task {
                    do {
                        let inv = try await client.inventory()
                        status(.hue, .connected("\(inv.lights.count) lights, \(inv.rooms.count) rooms, \(inv.scenes.count) scenes"))
                    } catch {
                        let hint = localNetworkHint(for: error, host: hue.host)
                        log(LogEntry(level: .error, category: "hue", message: describeError(error) + (hint.map { "\n" + $0 } ?? "")))
                        status(.hue, .disconnected(hint != nil ? "can't reach \(hue.host) — check Local Network permission (see log)" : "\(error)"))
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
        let engine = RuleEngine(config: config, executor: router, onEvent: eventSink, log: log)
        self.engine = engine
        Task { await engine.start() }

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

        if let hk = config.homekit {
            if dryRun {
                status(.homekit, .notConfigured)
                log(LogEntry(category: "homekit", message: "HomeKit bridge is not started in dry-run mode"))
            } else {
                let bridge = HomeKitBridge(config: hk, paths: paths, log: log, status: { status(.homekit, $0) })
                homekit = bridge
                bridge.start()
            }
        } else {
            status(.homekit, .notConfigured)
        }
        let homekit = self.homekit

        if let unifi = config.unifi {
            if unifi.resolvedPassword() == nil {
                status(.unifi, .needsSetup("no password: run housebridgectl set-unifi-password"))
                log(LogEntry(level: .warning, category: "unifi", message: "No UniFi password found. Store it in the Keychain with: housebridgectl set-unifi-password (or set unifi.password / unifi.password_env)"))
            } else {
                let client = ProtectClient(config: unifi, hosts: hosts, emit: { engine.submit($0); homekit?.handle($0) },
                                           onInventory: { homekit?.updateInventory($0) },
                                           status: { status(.unifi, $0) }, log: log)
                tasks.append(Task { await client.run() })
            }
        } else {
            status(.unifi, .notConfigured)
        }
    }

    public func stop() {
        active.turnOff()
        tasks.forEach { $0.cancel() }
        tasks = []
        if let engine { Task { await engine.stop() } }
        engine = nil
        homekit?.stop()
        homekit = nil
    }
}

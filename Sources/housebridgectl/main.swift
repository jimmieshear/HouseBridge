import Foundation
import HouseBridgeCore

// Minimal command-line front end. Configuration lives in a YAML file; this tool runs it and helps with setup.

let paths = Paths.standard()
let fileLog = FileLog(directory: paths.logsDirectory)
var args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    housebridgectl — bridge Lutron Caseta, Philips Hue and UniFi Protect

    USAGE: housebridgectl <command> [options]

    COMMANDS
      init                 Write a starter config to \(paths.configFile.path)
      validate             Check the config file and print a summary of its rules
      schedule             Show today's sunrise/sunset, when each time-of-day rule fires next, and planned simulated-occupancy sessions
      presence             Show each presence hold (which automation is paused, and until when)
      run [--dry-run]      Run the bridge (Ctrl-C to stop). --dry-run logs actions instead of changing lights.
      set-unifi-password   Store the UniFi password in the macOS Keychain (--delete removes it)
      set-kasa-password    Store the Kasa/TP-Link account password in the macOS Keychain (--delete removes it)
      pair-hue             Pair with the Hue bridge (press its link button first)
      pair-lutron [<ip>] [--out <dir>]  Pair with a Lutron Smart Bridge (Pro/RA2 Select) and write ca.pem, cert.pem, key.pem (default: <config home>/lutron)
      import-homebridge    Read a running Homebridge's config (found over Bonjour and its web UI, or --from-file) and add it to your HouseBridge config
                           (appends the missing unifi:/homekit: sections to an existing config, never overwrites; creates one if absent)
                           [--from-file <config.json>] [--ui <http://host:8581>] [--ui-user <name>] [--out <file>] [--print] [--store-password]
      pair-matter <code> [--name <label>]  Join a Matter device that is already in Apple Home (Home.app: accessory → Settings → Turn On Pairing Mode, then pass the code)
      unpair-matter <node>  Forget a Matter node this Mac joined (it stays in Apple Home)
      homekit [--reset]    Show the code for adding HouseBridge to Home.app and who is paired (--reset forgets everything)
      list appletv [--all]  Find Apple TVs on this network with model and generation (--all also lists HomePods, TVs, Macs)
      list lutron|hue|unifi|kasa|matter  Show (add --raw to lutron to dump the bridge's raw replies) the devices, buttons, lights, scenes or cameras you can use in rules
      camera-test [name] [--seconds N]  Check what HomeKit live view needs, camera by camera: snapshot, RTSP stream, H.264 and audio (run it on the Mac that runs HouseBridge)
      devices [--brief] [--save]  List every Lutron, Hue and UniFi device: what it reports, what you can do with it, example rules
      diagnose [--save]    Print a report (config, certificates, live connection tests, recent log) to share when something fails
      logs [-n N]          Show the last N lines of the log file (default 80) and its location
      events               Run with every action disabled and print each incoming event (find button/sensor names)

    OPTIONS
      --config <path>      Use a different config file (default: \(paths.configFile.path))
    """)
    exit(2)
}

func fail(_ message: String) -> Never {
    fileLog.write(level: .error, category: "cli", message: "\(CommandLine.arguments.dropFirst().joined(separator: " ")): \(message)")
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func takeOption(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func takeFlag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

let configURL = takeOption("--config").map { URL(fileURLWithPath: Paths.expand($0)) } ?? paths.configFile
let dryRun = takeFlag("--dry-run")
guard let command = args.first else { usage() }
let rest = Array(args.dropFirst())

func loadConfig() -> Config {
    do { return try ConfigLoader.load(from: configURL) }
    catch let e as ConfigError { fail("Config error in \(configURL.path)\n  \(e)") }
    catch let e as YAMLError { fail("Config error in \(configURL.path)\n  \(e)") }
    catch { fail("Could not read \(configURL.path): \(error)") }
}

@Sendable func timestamp(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
}

final class HubBox: @unchecked Sendable { var hub: Hub? }

func runHub(printEventsOnly: Bool) async {
    let box = HubBox()
    let dry = dryRun || printEventsOnly
    @Sendable func launch(_ config: Config) {
        var config = config
        if printEventsOnly { config.rules = [] }
        box.hub?.stop()
        let hub = Hub(config: config, paths: paths, dryRun: dry,
                      log: { e in print("\(timestamp(e.date)) [\(e.category)] \(e.message)") },
                      status: { s, st in print("\(timestamp(Date())) [\(s.rawValue)] \(st.label)") },
                      onEvent: { e in print("\(timestamp(e.date)) EVENT \(e.summary)") })
        box.hub = hub
        hub.start()
        print("Running with \(config.rules.count) rule(s)\(dry ? " (dry run)" : ""). Ctrl-C to stop.")
    }
    launch(loadConfig())

    // Reload live when the YAML changes; a broken edit keeps the previous config running.
    let watcher = FileWatcher(url: configURL) {
        do {
            let config = try ConfigLoader.load(from: configURL)
            print("\(timestamp(Date())) config changed — reloading")
            launch(config)
        } catch {
            print("\(timestamp(Date())) config changed but is invalid; keeping the previous one:\n  \(error)")
        }
    }
    watcher.start()

    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler { box.hub?.stop(); print("\nStopped."); exit(0) }
    source.resume()
    try? await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
}

switch command {
case "devices":
    let config = loadConfig()
    let result = await Catalog.load(config: config, paths: paths)
    let text = result.text(includeSnippets: !rest.contains("--brief"))
    print(text)
    if rest.contains("--save") {
        let url = paths.home.appendingPathComponent("devices.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        print("\nSaved to \(url.path)")
    }

case "diagnose":
    let text = await Diagnostics.report(paths: paths, configURL: configURL, log: fileLog)
    print(text)
    if args.contains("--save") || rest.contains("--save") {
        let name = "diagnostics-\(Int(Date().timeIntervalSince1970)).txt"
        let url = paths.logsDirectory.appendingPathComponent(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        print("\nSaved to \(url.path)")
    }

case "logs":
    var n = 80
    if let i = rest.firstIndex(of: "-n"), i + 1 < rest.count, let v = Int(rest[i + 1]) { n = v }
    print("# \(fileLog.url.path)")
    print(fileLog.tail(lines: n))

case "init":
    try? paths.ensureExists()
    if FileManager.default.fileExists(atPath: configURL.path) { fail("\(configURL.path) already exists; not overwriting.") }
    do {
        try exampleConfig.write(to: configURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        print("Wrote \(configURL.path). Edit it, then run: housebridgectl validate")
    } catch { fail("\(error)") }

case "validate":
    let config = loadConfig()
    print("OK — \(config.rules.count) rule(s)")
    if let missing = config.lutron?.missingFiles(), !missing.isEmpty {
        print("WARNING: Lutron certificate file(s) not readable:")
        missing.forEach { print("  \($0)") }
    } else if let l = config.lutron {
        print("Lutron certificates: \(l.caPath)\n                     \(l.certPath)\n                     \(l.keyPath)")
    }
    for r in config.rules {
        let t = r.trigger
        if let sched = t.schedule { print("  • \(r.name): \(sched.summary) → \(r.actions.count) action(s)\(r.enabled ? "" : "  [disabled]")"); continue }
        print("  • \(r.name): \(t.source.rawValue) \(t.device ?? "*") / \(t.input ?? "*") / \(t.kind) → \(r.actions.count) action(s)\(r.enabled ? "" : "  [disabled]")")
    }

case "schedule":
    let config = loadConfig()
    let f = DateFormatter(); f.dateFormat = "EEE MMM d HH:mm"
    if let loc = config.location {
        print("Location: \(loc.latitude), \(loc.longitude)  ·  time zone \(TimeZone.current.identifier)")
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        for e in [Sun.Event.sunrise, .sunset] {
            let t = Sun.time(e, year: c.year!, month: c.month!, day: c.day!, at: loc)
            print("  today's \(e.rawValue): \(t.map { f.string(from: $0) } ?? "none (polar)")")
        }
    } else { print("No location: set — sunrise/sunset rules are unavailable.") }
    let timed = config.rules.filter { $0.trigger.schedule != nil }
    if timed.isEmpty { print("No time-of-day rules (use `when: { at: \"18:30\" }` or `at: sunset`).") }
    for r in timed {
        let sched = r.trigger.schedule!
        let next = sched.next(after: Date(), location: config.location).map { f.string(from: $0) } ?? "never"
        print("  • \(r.name): \(sched.summary) → next \(next)\(r.enabled ? "" : "  [disabled]")")
    }
    // The plan is deterministic per night, so this is what the running app will do (unless someone is home).
    let tf = DateFormatter(); tf.dateFormat = "HH:mm"
    for h in config.holidays {
        let windows = h.upcoming(after: Date(), location: config.location, days: 400).prefix(2)
            .map { "\(f.string(from: $0.start))–\(tf.string(from: $0.end))" }
        print("Holiday ‘\(h.name)’\(h.enabled ? "" : "  [disabled]"): \(h.colors.joined(separator: " ")) → next \(windows.first ?? "never")\(windows.count > 1 ? ", then \(windows[1])" : "")")
    }
    for sim in config.simulations {
        print("Simulated occupancy ‘\(sim.name)’\(sim.enabled ? "" : "  [disabled]"), next 7 days:")
        let sessions = sim.upcoming(after: Date(), location: config.location, days: 7)
        if sessions.isEmpty { print("  (no sessions planned)") }
        for s in sessions {
            let target = sim.choices[s.choice].target
            print("  • \(f.string(from: s.start))–\(tf.string(from: s.end)): \((target.rooms + target.lights + target.zones).joined(separator: ", "))")
        }
    }

case "presence":
    let config = loadConfig()
    if config.presence.isEmpty { print("No presence holds (add a `presence:` section; see README).") }
    let saved = HoldStore(url: paths.holdsFile).load()
    let f = DateFormatter(); f.dateFormat = "EEE MMM d HH:mm"
    for h in config.presence {
        let p = h.pauses
        let devices = (p.lutron + p.lights + p.rooms + p.zones).joined(separator: ", ")
        let state = saved[h.name].flatMap { $0 > Date() ? "PAUSED until \(f.string(from: $0))" : nil } ?? "automation running"
        print("• \(h.name): \(state)  [hold \(Int(h.duration / 60)) min after any of \(h.triggers.count) trigger(s)]\n    pauses: \(devices)")
    }

case "run":
    await runHub(printEventsOnly: false)

case "events":
    await runHub(printEventsOnly: true)

case "set-unifi-password":
    let config = loadConfig()
    guard let u = config.unifi else { fail("Add a 'unifi:' section (host, username) to \(configURL.path) first.") }
    if rest.contains("--delete") {
        do {
            let removed = try Keychain.deletePassword(host: u.host, username: u.username)
            print(removed ? "Removed the stored password for \(u.username)@\(u.host)." : "Nothing stored for \(u.username)@\(u.host).")
        } catch { fail("\(error)") }
        exit(0)
    }
    guard let raw = getpass("UniFi password for \(u.username)@\(u.host) (input hidden): ") else { fail("No input.") }
    let password = String(cString: raw)
    guard !password.isEmpty else { fail("Empty password; nothing saved.") }
    do {
        try Keychain.savePassword(password, host: u.host, username: u.username)
        print("Saved to the macOS Keychain. You can remove 'password:' / 'password_env:' from the config.")
        do {
            _ = try await ProtectClient(config: u, hosts: KnownHosts(url: paths.knownHostsFile)).discover()
            print("Verified: logged in to \(u.host) as \(u.username).")
        } catch { print("Saved, but the login test failed: \(describeError(error))") }
    } catch { fail("\(describeError(error))") }

case "set-kasa-password":
    let config = loadConfig()
    guard let k = config.kasa, let user = k.username else { fail("Add a 'kasa:' section with 'username:' (your Kasa/TP-Link account e-mail) to \(configURL.path) first.") }
    if rest.contains("--delete") {
        do {
            let removed = try Keychain.deletePassword(host: KasaConfig.keychainHost, username: user, service: KasaConfig.keychainService)
            print(removed ? "Removed the stored password for \(user)." : "Nothing stored for \(user).")
        } catch { fail("\(error)") }
        exit(0)
    }
    guard let raw = getpass("Kasa/TP-Link password for \(user) (input hidden): ") else { fail("No input.") }
    let password = String(cString: raw)
    guard !password.isEmpty else { fail("Empty password; nothing saved.") }
    do {
        try Keychain.savePassword(password, host: KasaConfig.keychainHost, username: user, service: KasaConfig.keychainService)
        print("Saved to the macOS Keychain. You can remove 'password:' / 'password_env:' from the config.")
        print("Testing the plugs:")
        for line in await KasaBridge.describe(config: k) { print(line) }
    } catch { fail("\(describeError(error))") }

case "import-homebridge":
    func note(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    func ask(_ prompt: String) -> String {
        FileHandle.standardError.write(Data(prompt.utf8))
        return readLine() ?? ""
    }
    let fromFile = takeOption("--from-file")
    let uiOption = takeOption("--ui")
    let uiUser = takeOption("--ui-user")
    let outPath = takeOption("--out")
    let printOnly = takeFlag("--print")
    let storePassword = takeFlag("--store-password")

    var configData: Data
    var source: String
    var accessoryNames: [String] = []
    if let fromFile {
        guard let d = FileManager.default.contents(atPath: Paths.expand(fromFile)) else { fail("Could not read \(fromFile)") }
        configData = d
        source = fromFile
    } else {
        let hosts = KnownHosts(url: paths.knownHostsFile)
        var base: URL?
        if let uiOption {
            base = URL(string: uiOption.contains("://") ? uiOption : "http://\(uiOption)")
        } else {
            note("Looking for HomeKit bridges on the network (4s)…")
            let found = await BonjourDiscovery.findBridges()
            if found.isEmpty { note("  none found. If this Mac has no Local Network permission, allow it in System Settings → Privacy & Security.") }
            for b in found {
                note("  “\(b.name)”  \(b.host ?? "?"):\(b.port.map(String.init) ?? "?")  \(b.paired ? "paired" : "not paired")")
            }
            var candidates: [URL] = []
            var seen = Set<String>()
            for b in found {
                guard let host = b.host, seen.insert(host).inserted else { continue }
                for scheme in ["http", "https"] {
                    let url = URL(string: "\(scheme)://\(host):8581")!
                    if await HomebridgeUIClient(baseURL: url, hosts: hosts).requiresLogin() != nil { candidates.append(url); break }
                }
            }
            switch candidates.count {
            case 1:
                base = candidates[0]
                note("Homebridge UI found at \(candidates[0].absoluteString)")
            case 0:
                fail("No Homebridge web UI answered on port 8581 of those hosts. Give its address with --ui http://<vm-address>:8581, or copy its config.json and use --from-file.")
            default:
                fail("Several Homebridge UIs answered: " + candidates.map(\.absoluteString).joined(separator: ", ") + ". Pick one with --ui.")
            }
        }
        guard let base else { fail("Could not understand the --ui address.") }
        let client = HomebridgeUIClient(baseURL: base, hosts: hosts)
        guard let needsLogin = await client.requiresLogin(timeout: 10) else {
            fail("\(base.absoluteString) did not answer like the Homebridge UI (expected GET /api/auth/settings).")
        }
        var user = uiUser
        var password: String?
        if needsLogin {
            if user == nil { user = ask("Homebridge UI username: ") }
            guard let raw = getpass("Homebridge UI password for \(user ?? "") (input hidden): ") else { fail("No input.") }
            password = String(cString: raw)
        }
        do {
            do { try await client.authenticate(username: user, password: password) }
            catch is HomebridgeUIClient.OTPRequired {
                try await client.authenticate(username: user, password: password, otp: ask("Homebridge UI one-time code: "))
            }
            configData = try await client.fetchConfig()
        } catch { fail("Could not read the config from \(base.absoluteString): \(describeError(error))") }
        accessoryNames = await client.fetchAccessoryNames()
        source = base.absoluteString
    }

    let imported: HomebridgeImport
    do { imported = try HomebridgeImport.parse(configData) } catch { fail("\(error)") }
    note(imported.report(source: source, accessories: accessoryNames))

    if printOnly {
        note("\n--- generated config (nothing was written) ---")
        print(imported.yaml(source: source))
    } else {
        let target = outPath.map { URL(fileURLWithPath: Paths.expand($0)) } ?? configURL
        do {
            let outcome = try ConfigAppend.apply(imported, source: source, to: target)
            switch outcome.action {
            case .created:
                note("\nNo config existed, so created \(target.path) (unifi + homekit).")
            case .appended:
                note("\nAppended \(outcome.added.joined(separator: " + ")) to \(target.path); everything already in it is unchanged.")
                if !outcome.skipped.isEmpty { note("Left your existing \(outcome.skipped.joined(separator: " and ")) section as it was.") }
                if let backup = outcome.backup { note("Backup of the original: \(backup.path)") }
            case .nothingToDo:
                note("\n\(target.path) already has \(outcome.skipped.joined(separator: " and ")); nothing to add, nothing changed.")
            }
            if outcome.action != .nothingToDo { note("Checked: the result parses and validates.") }
        } catch { fail("\(error)") }
    }

    let controller = imported.primary
    if storePassword, let secret = controller.password {
        do {
            try Keychain.savePassword(secret, host: controller.host, username: controller.username)
            note("Stored the UniFi password in the macOS Keychain for \(controller.username)@\(controller.host).")
        } catch { note("Could not store the password: \(describeError(error))") }
    } else if controller.password != nil {
        note("Next: store the UniFi password with `housebridgectl set-unifi-password` (or rerun with --store-password).")
    } else {
        note("Next: store the UniFi password with `housebridgectl set-unifi-password`.")
    }
    note("Then: `housebridgectl validate`, `housebridgectl homekit` for the Home.app setup code, and start HouseBridge.")

case "homekit":
    if rest.contains("--reset") {
        guard HomeKitBridge.reset(paths: paths) else { fail("HouseBridge is running and owns the HomeKit bridge. Quit it first, then retry.") }
        print("Forgot the HomeKit identity and all pairings. In Home.app, remove the old “HouseBridge” bridge, then run again to get a new code.")
        exit(0)
    }
    let config = loadConfig()
    guard let hk = config.homekit else { fail("Add a 'homekit:' section to \(configURL.path) first (see README).") }
    guard let info = HomeKitBridge.pairingInfo(paths: paths, setupCode: hk.setupCode, create: true) else { fail("Could not read \(paths.homeKitFile.path)") }
    print("HomeKit bridge “\(hk.name)”  (id \(info.deviceID))")
    print("  Setup code:  \(info.setupCode)")
    print("  Setup URI:   \(info.setupURI)   (the content of the QR code; the menu bar app shows it as a QR image)")
    print(info.isPaired ? "  Paired with \(info.controllers.count) controller(s)." : "  Not paired yet: start HouseBridge, then in Home.app choose Add Accessory → More options and enter the code.")
    print("  Accessories: \(info.accessoryCount) (filled in once HouseBridge has connected to UniFi Protect)")

case "pair-hue":
    let config = loadConfig()
    guard let hue = config.hue else { fail("Add a 'hue:' section with the bridge's IP address to \(configURL.path) first.") }
    let hosts = KnownHosts(url: paths.knownHostsFile)
    print("Press the round link button on the Hue bridge at \(hue.host) now… (waiting up to 60s)")
    fileLog.write(category: "hue", message: "pairing started with \(hue.host)")
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
        do {
            let creds = try await HueClient.pair(host: hue.host, hosts: hosts)
            try HueClient.save(creds, to: paths.hueFile)
            fileLog.write(category: "hue", message: "paired; credentials saved to \(paths.hueFile.path)")
            print("Paired. Credentials saved to \(paths.hueFile.path)")
            exit(0)
        } catch HueError.linkButtonNotPressed {
            try? await Task.sleep(for: .seconds(2))
        } catch {
            fail("Hue pairing failed: \(describeError(error))\nRun 'housebridgectl diagnose' for connection tests.")
        }
    }
    fail("Timed out waiting for the link button.")

case "camera-test":
    let config = loadConfig()
    guard let unifi = config.unifi else { print("No unifi: section in the config."); exit(1) }
    var name: String?
    var seconds = 6.0
    var i = 0
    let rest = Array(args.dropFirst())
    while i < rest.count {
        if rest[i] == "--seconds", i + 1 < rest.count, let n = Double(rest[i + 1]) { seconds = max(1, min(60, n)); i += 2 }
        else { name = (name.map { $0 + " " } ?? "") + rest[i]; i += 1 }
    }
    await CameraDiagnostics.run(unifi: unifi, hosts: KnownHosts(url: paths.knownHostsFile), camera: name, seconds: seconds, say: { print($0) })

case "pair-lutron":
    let outDir = takeOption("--out").map { URL(fileURLWithPath: Paths.expand($0)) } ?? paths.home.appendingPathComponent("lutron")
    let host: String
    if let given = args.dropFirst().first, !given.hasPrefix("-") { host = given }
    else if let configured = (try? ConfigLoader.load(from: configURL))?.lutron?.host { host = configured }
    else { fail("Give the bridge's IP address (housebridgectl pair-lutron <ip>) or set lutron.host in \(configURL.path).") }
    if FileManager.default.fileExists(atPath: outDir.appendingPathComponent("key.pem").path) && !takeFlag("--force") {
        fail("\(outDir.path) already holds Lutron certificates. Pick another folder with --out, or add --force to replace them.")
    }
    fileLog.write(category: "lutron", message: "pairing started with \(host)")
    do {
        let creds = try await LutronPairing.pair(host: host) {
            print("Connected to \(host). Press the small button on the back of the bridge now… (waiting up to 3 minutes)")
        }
        try LutronPairing.save(creds, to: outDir)
        fileLog.write(category: "lutron", message: "paired; certificates saved to \(outDir.path)")
        print("Paired (LEAP \(creds.leapVersion ?? "?")). Certificates saved to \(outDir.path)")
        print("Add to your config:\n  lutron:\n    host: \(host)\n    certs_dir: \(outDir.path)")
        exit(0)
    } catch {
        fail("Lutron pairing failed: \(describeError(error))\nCheck the IP, that this Mac is on the bridge's LAN, and that it is a Smart Bridge Pro or RA2 Select (LEAP). Run 'housebridgectl diagnose' for connection tests.")
    }

case "pair-matter":
    guard let code = args.dropFirst().first, !code.hasPrefix("-") else { fail("Give the pairing code: housebridgectl pair-matter <code> [--name <label>]") }
    let label = takeOption("--name")
    do { _ = try MatterController.parse(code: code) } catch { fail("\(error)") }
    let matter = MatterController(store: MatterStore(url: paths.matterFile), log: { fileLog.write($0) })
    do {
        try matter.start()
        print("Pairing… (up to 2 minutes; keep the device powered and this Mac on its network)")
        let node = try await matter.pair(code: code, name: label)
        print("Paired as node \(node)\(label.map { " (“\($0)”)" } ?? ""). Next: housebridgectl list matter")
        matter.stop()
        exit(0)
    } catch {
        matter.stop()
        fail("Matter pairing failed: \(describeError(error))\nGet a fresh code from Home.app (Turn On Pairing Mode) and check 'housebridgectl logs'. macOS may ask for Local Network permission.")
    }

case "unpair-matter":
    guard let id = args.dropFirst().first.flatMap(UInt64.init) else { fail("Give the node number shown by 'list matter'.") }
    let matter = MatterController(store: MatterStore(url: paths.matterFile), log: { fileLog.write($0) })
    try? matter.start()
    matter.unpair(node: id)
    matter.stop()
    print("Forgot node \(id) here. It is still paired to Apple Home.")
    exit(0)

case "list":
    if args.dropFirst().first == "matter" {
        let matter = MatterController(store: MatterStore(url: paths.matterFile), log: { fileLog.write($0) })
        guard !matter.store.nodes.isEmpty else { fail("No Matter devices yet. Run: housebridgectl pair-matter <code>") }
        do { try matter.start() } catch { fail("\(error)") }
        for node in matter.store.nodes {
            print("\nNode \(node.id)" + (node.name.map { " “\($0)”" } ?? ""))
            do {
                let all = try await matter.readEverything(node: node.id)
                for ep in all.keys.sorted() {
                    var heading = "  endpoint \(ep)"
                    // Descriptor (0x1D) attribute 0 = DeviceTypeList: {0: type, 1: revision} entries.
                    if let list = all[ep]?[0x1D]?[0] { heading += "  device types: " + list }
                    print(heading)
                    for cl in all[ep]!.keys.sorted() {
                        print("    cluster 0x\(String(cl, radix: 16, uppercase: true)) \(MatterNames.clusters[cl].map { "(\($0))" } ?? "")")
                        // 0xFFF8-0xFFFD are the global list/feature attributes; skip the noise but show real values.
                        for (attr, value) in all[ep]![cl]!.sorted(by: { $0.key < $1.key }) where attr < 0xFFF0 {
                            print("      0x\(String(attr, radix: 16, uppercase: true)) = \(value.prefix(160))")
                        }
                    }
                }
            } catch { print("  could not read: \(describeError(error))") }
        }
        matter.stop()
        exit(0)
    }
    if args.dropFirst().first == "appletv" {
        let all = rest.contains("--all")
        print("Browsing the local network for AirPlay devices (this Mac's LAN/VLAN only)…")
        let found = await AppleTVDiscovery.find().filter { all || $0.isAppleTV }
        if found.isEmpty { fail(all ? "No AirPlay devices found." : "No Apple TVs found. Try --all, and check Local Network permission and VLAN/mDNS reachability.") }
        for d in found {
            print("  “\(d.name)”  \(d.host ?? "?")  [\(d.model.isEmpty ? "?" : d.model)]  \(d.description)")
        }
        exit(0)
    }
    let config = loadConfig()
    guard let what = rest.first else { usage() }
    do {
        switch what {
        case "lutron":
            guard let l = config.lutron else { fail("No 'lutron:' section in config.") }
            let inv = try await LutronBridge.discover(config: l, trace: { print("  [discovery] \($0)") })
            if rest.contains("--raw") { print(try await LutronBridge.rawDump(config: l)) }
            print("Remotes / keypads (use the name after 'pico:'):")
            for d in inv.picos {
                let buttons = inv.buttons.filter { $0.deviceHref == d.href }.sorted { $0.number < $1.number }
                    .map { "\(LutronInventory.buttonName(number: $0.number))(\($0.number))" }.joined(separator: ", ")
                print("  “\(d.fullName)”  [\(d.type) \(d.model)]  buttons: \(buttons)")
            }
            print("Wired switches / dimmers (use the name after 'switch:'):")
            for d in inv.switches { print("  “\(d.fullName)”  [\(d.type) \(d.model)]") }
        case "hue":
            guard let h = config.hue, let creds = HueClient.load(from: paths.hueFile), creds.host == h.host else {
                fail("Hue is not paired yet. Run: housebridgectl pair-hue")
            }
            let inv = try await HueClient(credentials: creds, hosts: KnownHosts(url: paths.knownHostsFile)).inventory(refresh: true)
            print("Lights:");  inv.lights.forEach { print("  “\($0.name)”") }
            print("Rooms:");   inv.rooms.forEach { print("  “\($0.name)”") }
            print("Zones:");   inv.zones.forEach { print("  “\($0.name)”") }
            print("Scenes (room: scene):"); inv.scenes.forEach { print("  “\($0.groupName ?? "?")”: “\($0.name)”") }
        case "unifi":
            guard let u = config.unifi else { fail("No 'unifi:' section in config.") }
            let inv = try await ProtectClient(config: u, hosts: KnownHosts(url: paths.knownHostsFile)).discover()
            for item in inv.items { print("  \(item.kind): “\(item.name)”  [\(item.model)]") }
        case "kasa":
            guard let k = config.kasa else { fail("No 'kasa:' section in config.") }
            print("Plugs (use the name after 'device:' in a plug action):")
            for line in await KasaBridge.describe(config: k) { print(line) }
        default: usage()
        }
    } catch { fail("list \(what) failed: \(describeError(error))\nRun 'housebridgectl diagnose' for connection tests.") }

default:
    usage()
}

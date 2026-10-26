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
      schedule             Show today's sunrise/sunset and when each time-of-day rule fires next
      presence             Show each presence hold (which automation is paused, and until when)
      run [--dry-run]      Run the bridge (Ctrl-C to stop). --dry-run logs actions instead of changing lights.
      set-unifi-password   Store the UniFi password in the macOS Keychain (--delete removes it)
      pair-hue             Pair with the Hue bridge (press its link button first)
      import-homebridge    Read a running Homebridge's config (found over Bonjour and its web UI, or --from-file) and add it to your HouseBridge config
                           (appends the missing unifi:/homekit: sections to an existing config, never overwrites; creates one if absent)
                           [--from-file <config.json>] [--ui <http://host:8581>] [--ui-user <name>] [--out <file>] [--print] [--store-password]
      homekit [--reset]    Show the code for adding HouseBridge to Home.app and who is paired (--reset forgets everything)
      list lutron|hue|unifi  Show (add --raw to lutron to dump the bridge's raw replies) the devices, buttons, lights, scenes or cameras you can use in rules
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

case "list":
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
        default: usage()
        }
    } catch { fail("list \(what) failed: \(describeError(error))\nRun 'housebridgectl diagnose' for connection tests.") }

default:
    usage()
}

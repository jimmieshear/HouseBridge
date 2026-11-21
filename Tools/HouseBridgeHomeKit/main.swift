// HouseBridgeHomeKit: a small Mac Catalyst app that watches HomeKit sensors (smoke, CO, temperature, humidity, air
// quality) and forwards every reading to HouseBridge over a Unix socket, one JSON object per line. HomeKit only exists
// in the iOS SDK, so HouseBridge itself (a SwiftPM app) cannot read it; this is the bridge between the two.
//
// It only reads; it never writes to an accessory. Build with scripts/build-homekit-helper.sh (needs the HomeKit
// entitlement, so a developer profile). Run it where HouseBridge runs and add it to Login Items.
//
//   HouseBridgeHomeKit.app/Contents/MacOS/HouseBridgeHomeKit [--socket /path/to/sensors.sock]
//
// Lines sent (HouseBridge: Sources/HouseBridgeCore/HomeSensors):
//   {"t":"hello","helper":"HouseBridgeHomeKit","version":1}
//   {"t":"reading","id":<accessory uuid>,"home":..,"name":..,"room":..,"kind":"smoke|co|temperature|humidity|air_quality|pm25|voc|co2",
//    "value":<number>,"reachable":<bool>,"ts":<unix seconds>}
import Foundation
import HomeKit

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// MARK: - Socket link to HouseBridge

/// Keeps a connection to HouseBridge's socket, reconnecting every few seconds, and remembers nothing: when it
/// (re)connects, `onConnect` is called so the watcher can send every reading again.
final class Link: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "housebridge.link")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    var onConnect: (@Sendable () -> Void)?
    /// When HouseBridge was last connected (or we started): lets the app quit once HouseBridge is gone for good.
    private(set) var lastContact = Date()
    private(set) var everConnected = false
    var isConnected: Bool { queue.sync { fd >= 0 } }
    var secondsSinceContact: TimeInterval { queue.sync { fd >= 0 ? 0 : Date().timeIntervalSince(lastContact) } }

    init(path: String) { self.path = path }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 5)
        t.setEventHandler { [weak self] in self?.connectIfNeeded() }
        timer = t
        t.resume()
    }

    private func connectIfNeeded() {
        guard fd < 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { err("socket path too long"); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { close(s); return }   // HouseBridge is not running (yet)
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = s
        lastContact = Date(); everConnected = true
        // HouseBridge never talks back; a read of 0 bytes is how we learn it went away.
        let source = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 256)
            let n = read(s, &buf, buf.count)
            if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { self?.disconnect() }
        }
        readSource = source
        source.resume()
        err("connected to HouseBridge")
        write(["t": "hello", "helper": "HouseBridgeHomeKit", "version": 1])
        onConnect?()
    }

    private func disconnect() {
        guard fd >= 0 else { return }
        readSource?.cancel(); readSource = nil
        close(fd); fd = -1
        lastContact = Date()
        err("HouseBridge disconnected; will retry")
    }

    func send(_ object: [String: Any]) { queue.async { self.write(object) } }

    private func write(_ object: [String: Any]) {
        guard fd >= 0, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        let ok = data.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let n = Foundation.write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { if errno == EINTR { continue }; return false }
                sent += n
            }
            return true
        }
        if !ok { disconnect() }
    }
}

// MARK: - HomeKit

/// The characteristics we forward, by the first eight hex digits of their HomeKit UUID.
let characteristicKinds: [String: String] = [
    "00000076": "smoke",        // Smoke Detected
    "00000069": "co",           // Carbon Monoxide Detected
    "00000011": "temperature",  // Current Temperature (°C)
    "00000010": "humidity",     // Current Relative Humidity (%)
    "00000095": "air_quality",  // Air Quality (0 unknown … 5 poor)
    "000000C6": "pm25",         // PM2.5 Density
    "000000C8": "voc",          // VOC Density
    "00000093": "co2",          // Carbon Dioxide Level
]

final class Watcher: NSObject, HMHomeManagerDelegate, HMHomeDelegate, HMAccessoryDelegate {
    private let manager = HMHomeManager()
    private let link: Link
    /// Every characteristic we watch, with the accessory and kind it reports.
    private var tracked: [(characteristic: HMCharacteristic, accessory: HMAccessory, home: HMHome, kind: String)] = []
    private var rescanPending = false

    init(link: Link) {
        self.link = link
        super.init()
        manager.delegate = self
        link.onConnect = { [weak self] in DispatchQueue.main.async { self?.sendAll() } }
        // Notifications are the fast path (smoke must arrive at once); this is the safety net for accessories whose
        // notifications lapse, and it lets HouseBridge's window show a fresh "updated" time.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refreshAll() }
        // Smoke and CO are re-read every 30 s as well: if notifications do not arrive for any reason, an alarm is still
        // reported within about half a minute rather than five minutes.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh(self.tracked.filter { $0.kind == "smoke" || $0.kind == "co" })
        }
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) { scheduleRescan() }
    func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) { scheduleRescan() }
    func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) { scheduleRescan() }
    func home(_ home: HMHome, didAdd accessory: HMAccessory) { scheduleRescan() }
    func home(_ home: HMHome, didRemove accessory: HMAccessory) { scheduleRescan() }
    func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) { scheduleRescan() }

    func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        if let item = tracked.first(where: { $0.characteristic === characteristic }) { emit(item) }
    }

    func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        for item in tracked where item.accessory === accessory { emit(item) }
        if accessory.isReachable { refresh(tracked.filter { $0.accessory === accessory }) }
    }

    /// Several callbacks arrive in a burst when homes sync; scan once after they settle.
    private func scheduleRescan() {
        guard !rescanPending else { return }
        rescanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.rescanPending = false; self.rescan() }
    }

    private func rescan() {
        tracked = []
        for home in manager.homes {
            home.delegate = self
            for accessory in home.accessories {
                accessory.delegate = self
                var seen = Set<String>()   // first characteristic of each kind per accessory
                for service in accessory.services {
                    for c in service.characteristics {
                        guard let kind = characteristicKinds[String(c.characteristicType.prefix(8)).uppercased()], seen.insert(kind).inserted else { continue }
                        tracked.append((c, accessory, home, kind))
                        c.enableNotification(true) { error in
                            if let error { err("notifications for \(accessory.name) \(kind): \(error.localizedDescription)") }
                        }
                    }
                }
            }
        }
        err("watching \(tracked.count) characteristic(s) on \(Set(tracked.map { $0.accessory.uniqueIdentifier }).count) accessory(ies) in \(manager.homes.count) home(s)")
        refreshAll()
    }

    /// Asks every reachable accessory for fresh values (5 s each at most), then sends everything.
    private func refreshAll() { refresh(tracked) }

    private func refresh(_ items: [(characteristic: HMCharacteristic, accessory: HMAccessory, home: HMHome, kind: String)]) {
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for item in items where item.accessory.isReachable {
                    group.addTask {
                        await withTaskGroup(of: Void.self) { race in
                            race.addTask { try? await item.characteristic.readValue() }
                            race.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                            _ = await race.next()
                            race.cancelAll()
                        }
                    }
                }
            }
            for item in items { emit(item) }
        }
    }

    private func sendAll() { for item in tracked { emit(item) } }

    private func emit(_ item: (characteristic: HMCharacteristic, accessory: HMAccessory, home: HMHome, kind: String)) {
        guard let number = item.characteristic.value as? NSNumber else { return }
        link.send(["t": "reading", "id": item.accessory.uniqueIdentifier.uuidString, "home": item.home.name,
                   "name": item.accessory.name, "room": item.accessory.room?.name ?? "", "kind": item.kind,
                   "value": number.doubleValue, "reachable": item.accessory.isReachable,
                   "ts": Date().timeIntervalSince1970])
    }
}

func defaultSocketPath() -> String {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--socket"), i + 1 < args.count { return args[i + 1] }
    let env = ProcessInfo.processInfo.environment["HOUSEBRIDGE_HOME"] ?? ""
    let home = env.isEmpty ? NSString(string: "~/.config/housebridge").expandingTildeInPath : NSString(string: env).expandingTildeInPath
    return home + "/sensors.sock"
}

// MARK: - --list

/// Every sensor-like characteristic HomeKit knows (first eight hex digits of its UUID), for `--list`. Those that are also
/// in `characteristicKinds` are already forwarded to HouseBridge; the others show what could be added.
let listableCharacteristics: [String: String] = [
    "00000011": "temperature (°C)", "00000010": "humidity (%)", "0000006B": "light level (lux)",
    "00000070": "leak detected", "0000006A": "contact (0 closed, 1 open)", "00000022": "motion detected",
    "00000071": "occupancy detected", "00000076": "smoke detected", "00000069": "carbon monoxide detected",
    "00000092": "carbon dioxide detected", "00000093": "carbon dioxide level", "00000095": "air quality (1 excellent … 5 poor)",
    "000000C6": "PM2.5 density", "000000C8": "VOC density", "00000068": "battery level (%)", "00000079": "low battery",
    "0000007A": "tampered",
]

/// `HouseBridgeHomeKit --list [--match words]`: prints every accessory that has a sensor characteristic, in every home,
/// with its current value, then exits. Used to see what a house offers before adding it to `home_sensors:`.
final class Lister: NSObject, HMHomeManagerDelegate {
    private let manager = HMHomeManager()
    private var started = false
    private let match: [String]
    override init() {
        let args = CommandLine.arguments
        match = args.firstIndex(of: "--match").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
        super.init()
        manager.delegate = self
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        guard !started else { return }
        started = true
        err("authorization: \(manager.authorizationStatus.rawValue) (bit 4 = authorized), homes: \(manager.homes.count)")
        Task { @MainActor in await self.dump(); exit(0) }
    }

    @MainActor private func dump() async {
        func line(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
        for home in manager.homes {
            var printedHome = false
            for accessory in home.accessories {
                if !match.isEmpty && !match.contains(where: { accessory.name.lowercased().contains($0) }) { continue }
                let items = accessory.services.flatMap { service in
                    service.characteristics.compactMap { c -> (HMCharacteristic, String)? in
                        listableCharacteristics[String(c.characteristicType.prefix(8)).uppercased()].map { (c, $0) }
                    }
                }
                guard !items.isEmpty else { continue }
                if accessory.isReachable {
                    await withTaskGroup(of: Void.self) { group in
                        for (c, _) in items where c.properties.contains(HMCharacteristicPropertyReadable) {
                            group.addTask {
                                await withTaskGroup(of: Void.self) { race in
                                    race.addTask { try? await c.readValue() }
                                    race.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                                    _ = await race.next(); race.cancelAll()
                                }
                            }
                        }
                    }
                }
                if !printedHome { line("\nHOME \(home.name)"); printedHome = true }
                line("  \(accessory.name)  [\(accessory.manufacturer ?? "?") \(accessory.model ?? "?")]  room=\(accessory.room?.name ?? "-")  bridged=\(accessory.isBridged)  reachable=\(accessory.isReachable)")
                var seen = Set<String>()
                for (c, label) in items {
                    let prefix = String(c.characteristicType.prefix(8)).uppercased()
                    let supported = characteristicKinds[prefix] != nil
                    let value = c.value.map { "\($0)" } ?? "nil"
                    // A second service of the same kind (two leak probes, say) is shown too; HouseBridge forwards the first only.
                    let repeated = !seen.insert(prefix).inserted
                    line("      \(label): \(value)   [\(supported ? (repeated ? "only the first is forwarded" : "forwarded to HouseBridge") : "not forwarded yet")]")
                }
            }
        }
    }
}

if CommandLine.arguments.contains("--list") {
    let lister = Lister()
    DispatchQueue.main.asyncAfter(deadline: .now() + 120) { err("timed out waiting for HomeKit"); exit(2) }
    withExtendedLifetime(lister) { RunLoop.main.run() }
}

// MARK: - Process

// No UIApplication and no scenes: UIKit would open a window for the first scene, and nothing here needs one (HomeKit
// only needs the entitlement and a run loop). Info.plist has LSBackgroundOnly, so there is no Dock icon or menu bar either.
// Without this flag macOS may throttle the timers of an app with no visible window.
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Watching HomeKit smoke and CO sensors")
let socketPath = defaultSocketPath()
let link = Link(path: socketPath)
let watcher = Watcher(link: link)
link.start()
err("HouseBridgeHomeKit started; sending to \(socketPath)")

// HouseBridge starts this process and restarts it if needed, so when HouseBridge is gone for good there is nothing
// left to watch for: quit (a reload takes a second or two, so allow a minute and a half). Started by hand before
// HouseBridge, allow ten minutes for it to appear. `--stay` keeps it running regardless.
if !CommandLine.arguments.contains("--stay") {
    Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
        let limit: TimeInterval = link.everConnected ? 90 : 600
        if link.secondsSinceContact > limit { err("HouseBridge has been gone for \(Int(limit)) s; quitting"); exit(0) }
    }
}
RunLoop.main.run()
withExtendedLifetime((activity, watcher)) {}

// HouseBridgeProbe: read-only dump of everything Home.app knows (homes, rooms, accessories, services, characteristics
// with current values) so we can see what HomeKit exposes, e.g. the Owl smoke detector's sensors. Mac Catalyst app
// (HomeKit only ships in the iOS SDK), needs the com.apple.developer.homekit entitlement, so build it with
// scripts/build-probe.sh. It never writes to an accessory.
//
//   HouseBridgeProbe.app/Contents/MacOS/HouseBridgeProbe [--match Owl,Environmental] [--read] > ~/Desktop/homekit-dump.txt
import UIKit
import HomeKit

func out(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// Options: --match a,b   only accessories whose name contains one of these (case-insensitive)
//          --read        refresh each readable characteristic from the device (concurrent, 5 s each) instead of
//                        printing HomeKit's cached value; slower, and an unreachable accessory is skipped
struct Options {
    var match: [String] = []
    var read = false
    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--match": match = (it.next() ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            case "--read": read = true
            default: break
            }
        }
    }
    func wants(_ name: String) -> Bool { match.isEmpty || match.contains { name.lowercased().contains($0) } }
}
let options = Options(CommandLine.arguments)

/// Reads a characteristic, giving up after `seconds` so one stuck accessory cannot stall the dump.
func refresh(_ c: HMCharacteristic, seconds: Double = 5) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask { try? await c.readValue() }
        group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        _ = await group.next()
        group.cancelAll()
    }
}

final class Probe: NSObject, HMHomeManagerDelegate {
    let manager = HMHomeManager()
    private var started = false

    override init() { super.init(); manager.delegate = self }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        guard !started else { return }
        started = true
        err("authorization: \(manager.authorizationStatus.rawValue) (bit 1 = determined, 2 = restricted, 4 = authorized), homes: \(manager.homes.count)")
        Task { await dump(); err("done"); exit(0) }
    }

    func dump() async {
        for home in manager.homes {
            out("HOME \(home.name)  primary=\(home.isPrimary)")
            for room in home.rooms { out("  room: \(room.name) (\(room.accessories.count) accessories)") }
            for acc in home.accessories where options.wants(acc.name) {
                out("\nACCESSORY \(acc.name)  home=\(home.name)  room=\(acc.room?.name ?? "-")  reachable=\(acc.isReachable)  bridged=\(acc.isBridged)")
                out("  manufacturer=\(acc.manufacturer ?? "-") model=\(acc.model ?? "-") firmware=\(acc.firmwareVersion ?? "-") category=\(acc.category.localizedDescription)")
                if options.read, acc.isReachable {
                    let readable = acc.services.flatMap(\.characteristics).filter { $0.properties.contains(HMCharacteristicPropertyReadable) }
                    await withTaskGroup(of: Void.self) { group in
                        for c in readable { group.addTask { await refresh(c) } }
                    }
                }
                for service in acc.services {
                    out("  SERVICE \(service.name)  type=\(service.serviceType) (\(service.localizedDescription))")
                    for c in service.characteristics {
                        let value = c.value.map { "\($0)" } ?? "nil"
                        out("    \(c.localizedDescription)  type=\(c.characteristicType)  value=\(value)  props=\(c.properties.map { $0.replacingOccurrences(of: "HMCharacteristicProperty", with: "") }.joined(separator: ","))")
                    }
                }
            }
        }
    }
}

// The current SDK requires the UIScene lifecycle, so a (blank) scene is needed even though nothing is drawn.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let label = UILabel()
        label.text = "HouseBridgeProbe: reading HomeKit, output goes to stdout…"
        label.textAlignment = .center
        let vc = UIViewController()
        vc.view = label
        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = vc
        window?.makeKeyAndVisible()
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    let probe = Probe()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { err("timed out (no permission prompt answered, entitlement missing, or a read hung)"); exit(2) }
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))

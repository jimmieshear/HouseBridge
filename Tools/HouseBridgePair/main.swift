// HouseBridgePair: shows Apple's "Add Accessory" sheet on a Mac so the HouseBridge HomeKit bridge can be paired
// where Home.app has no Add Accessory command (macOS 27+, HMAccessorySetupManager). Built as a Mac Catalyst app
// by scripts/build-pair.sh; it is not part of the SwiftPM package because HomeKit only ships in the iOSSupport SDK.
//
//   HouseBridgePair.app/Contents/MacOS/HouseBridgePair --code 031-45-154 [--uri 'X-HM://…' --use-payload]
//
// Without --use-payload the system sheet asks for the setup code (type the one shown in the window). With it, the
// X-HM payload is handed over so no typing is needed, but that needs the restricted
// com.apple.developer.homekit.allow-setup-payload entitlement (see build-pair.sh).
import UIKit
import HomeKit

struct Options {
    var code: String?
    var uri: String?
    var usePayload = false

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--code": code = it.next()
            case "--uri": uri = it.next()
            case "--use-payload": usePayload = true
            default: break
            }
        }
    }
}

let options = Options(CommandLine.arguments)

func report(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

final class PairViewController: UIViewController {
    private let status = UILabel()
    private let button = UIButton(type: .system)
    private let manager = HMAccessorySetupManager()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "Add HouseBridge to Home"
        title.font = .preferredFont(forTextStyle: .title2)
        let code = UILabel()
        code.text = options.code.map { "Setup code: \($0)" } ?? "Run with --code to show the setup code here."
        code.font = .monospacedSystemFont(ofSize: 20, weight: .medium)
        status.numberOfLines = 0
        status.textAlignment = .center
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        button.setTitle("Add Accessory…", for: .normal)
        button.addTarget(self, action: #selector(start), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, code, button, status])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])
        // In the Mac Catalyst copy of HomeKit, isSupported is hard-wired to NO (even on macOS 27.2), so it is not a
        // reliable gate: try anyway and report the system's own error if it fails.
        if HMAccessorySetupManager.isSupported {
            show("Click the button, choose the Bend House home, then enter the setup code above when asked.")
        } else {
            show("The system reports Add Accessory as unsupported here (isSupported = NO); trying anyway may fail. Click the button to see the system's error.")
        }
    }

    private func show(_ text: String) {
        status.text = text
        report(text)
    }

    @objc private func start() {
        let request = HMAccessorySetupRequest()
        request.suggestedAccessoryName = "HouseBridge"
        if options.usePayload {
            guard let uri = options.uri, let url = URL(string: uri), let payload = HMAccessorySetupPayload(url: url) else {
                show("--use-payload needs a valid --uri X-HM://… value.")
                return
            }
            request.payload = payload
        }
        button.isEnabled = false
        manager.performAccessorySetup(using: request) { [weak self] result, error in
            DispatchQueue.main.async {
                self?.button.isEnabled = true
                if let error {
                    self?.show("Setup failed: \(error) (\((error as NSError).domain) \((error as NSError).code))")
                } else {
                    self?.show("Done: \(result.map { String(describing: $0) } ?? "accessory added"). You can quit this app.")
                }
            }
        }
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = PairViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))

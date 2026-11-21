import SwiftUI
import AppKit
import HouseBridgeCore
import CoreImage.CIFilterBuiltins

/// Menu bar front end. All behaviour comes from ~/.config/housebridge/config.yaml; this just shows status
/// and recent activity, and reloads the file whenever it changes.
@MainActor
final class AppModel: ObservableObject {
    @Published var statuses: [Subsystem: ConnectionStatus] = [:]
    @Published var activity: [LogEntry] = []
    @Published var configError: String?
    @Published var ruleCount = 0
    /// Occurrences the person skipped (`Upcoming.skipKey`); the engine keeps the same set on disk.
    @Published var skippedKeys: Set<String> = []
    /// Setup code and pairing state for the HomeKit bridge, when one is configured.
    @Published var homeKit: HomeKitPairingInfo?
    /// Latest readings from HomeKit sensors (via the HouseBridgeHomeKit helper), and whether the helper is connected.
    @Published var sensors: [SensorReading] = []
    @Published var sensorHelperConnected = false
    @Published var sensorsConfigured = false
    /// True when `home_sensors: devices:` lists HomeKit accessories, which are read through the helper.
    @Published var sensorHelperNeeded = false

    @Published var catalog: CatalogResult?
    @Published var catalogLoading = false
    private var currentConfig: Config?
    private let paths = Paths.standard()
    private var hub: Hub?
    private var watcher: FileWatcher?

    init() {
        try? paths.ensureExists()
        if !FileManager.default.fileExists(atPath: paths.configFile.path) {
            try? exampleConfig.write(to: paths.configFile, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configFile.path)
        }
        reload()
        watcher = FileWatcher(url: paths.configFile) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watcher?.start()
    }

    var configPath: URL { paths.configFile }
    var logsFolder: URL { paths.logsDirectory }
    @Published var diagnosticsBusy = false

    /// Asks the bridges for every device and what it can do (read-only).
    func loadCatalog() {
        guard !catalogLoading, let config = currentConfig else { return }
        catalogLoading = true
        let paths = self.paths
        Task {
            let result = await Catalog.load(config: config, paths: paths)
            catalog = result
            catalogLoading = false
            append(LogEntry(category: "devices", message: "found \(result.entries.count) item(s)" + (result.problems.isEmpty ? "" : "; problems: " + result.problems.map { "\($0.key.rawValue)" }.joined(separator: ", "))))
        }
    }

    /// Runs the connection tests and puts the report on the clipboard, ready to paste.
    func copyDiagnostics() {
        guard !diagnosticsBusy else { return }
        diagnosticsBusy = true
        let paths = self.paths
        Task {
            let log = FileLog(directory: paths.logsDirectory)
            let text = await Diagnostics.report(paths: paths, configURL: paths.configFile, log: log)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            append(LogEntry(category: "diagnostics", message: "report copied to clipboard (\(text.count) characters)"))
            diagnosticsBusy = false
        }
    }

    var overallSymbol: String {
        if configError != nil { return "exclamationmark.triangle" }   // config needs attention
        let active = statuses.values.filter { $0 != .notConfigured }
        if !active.isEmpty && active.allSatisfy(\.isHealthy) { return "house.fill" }   // everything connected
        return "house"   // starting up, or something is disconnected
    }

    func reload() {
        do {
            let config = try ConfigLoader.load(from: paths.configFile)
            hub?.stop()
            statuses = [:]
            sensors = []
            sensorHelperConnected = false
            sensorsConfigured = config.homeSensors != nil
            sensorHelperNeeded = config.homeSensors?.needsHelper ?? false
            ruleCount = config.rules.count
            currentConfig = config
            configError = nil
            let hub = Hub(config: config, paths: paths,
                          log: { [weak self] e in Task { @MainActor in self?.append(e) } },
                          status: { [weak self] s, st in
                              Task { @MainActor in
                                  self?.statuses[s] = st
                                  if s == .homekit { self?.refreshHomeKit() }
                              }
                          },
                          onEvent: { [weak self] e in
                              Task { @MainActor in self?.append(LogEntry(category: "event", message: e.summary)) }
                          },
                          onSensors: { [weak self] readings, connected in
                              Task { @MainActor in self?.sensors = readings; self?.sensorHelperConnected = connected }
                          })
            self.hub = hub
            skippedKeys = Set(HoldStore(url: paths.skipsFile).load().keys)
            hub.start()
            append(LogEntry(category: "config", message: "loaded \(config.rules.count) rule(s)"))
        } catch {
            // Keep whatever was running; surface the problem.
            configError = "\(error)"
            append(LogEntry(level: .error, category: "config", message: "\(error)"))
        }
    }

    /// A sensor's reading is old: its source is disconnected (the HomeKit helper, or the UniFi console), it is unreachable,
    /// or nothing arrived for a while (15 minutes for HomeKit, which the helper refreshes every 5; 30 for Protect, which
    /// HouseBridge re-reads every 5).
    func sensorIsStale(_ group: [SensorReading], now: Date) -> Bool {
        if group.contains(where: { !$0.reachable }) { return true }
        let newest = group.map(\.date).max() ?? .distantPast
        if group.first?.isProtect == true {
            return !(statuses[.unifi]?.isHealthy ?? false) || now.timeIntervalSince(newest) > 30 * 60
        }
        return !sensorHelperConnected || now.timeIntervalSince(newest) > 15 * 60
    }

    private func refreshHomeKit() {
        homeKit = currentConfig?.homekit == nil ? nil : HomeKitBridge.pairingInfo(paths: paths)
    }

    private func append(_ entry: LogEntry) {
        activity.insert(entry, at: 0)
        if activity.count > 60 { activity.removeLast(activity.count - 60) }
    }

    /// Everything automatic that is coming up (see `Upcoming`).
    func upcomingEvents(now: Date) -> [UpcomingEvent] {
        guard let config = currentConfig else { return [] }
        return Upcoming.events(config: config, holds: HoldStore(url: paths.holdsFile).load(), skips: skippedKeys, now: now)
    }

    /// Skips this one occurrence of a scheduled rule (or takes the skip back); later occurrences are unaffected.
    func setSkipped(_ event: UpcomingEvent, _ skipped: Bool) {
        guard let rule = event.ruleName else { return }
        let key = Upcoming.skipKey(rule, event.date)
        if skipped { skippedKeys.insert(key) } else { skippedKeys.remove(key) }
        hub?.skipRule(rule, at: event.date, undo: !skipped)
    }

    /// Runs a scheduled rule right now; it stays in place until the schedule next changes those devices.
    func runNow(_ ruleName: String) { hub?.runRuleNow(ruleName) }

    func quit() { hub?.stop(); NSApplication.shared.terminate(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    }
}

@main
struct HouseBridgeMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("HouseBridge", systemImage: model.overallSymbol) {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("HouseBridge", id: "main") {
            MainWindowView(model: model)
        }
        .defaultSize(width: 920, height: 720)
        .defaultLaunchBehavior(.suppressed)   // a menu bar app: the window opens from the menu, not at launch

        Window("HouseBridge Devices", id: "devices") {
            DevicesView(model: model)
        }
    }
}

/// The menu bar menu only opens the window (or quits); everything else lives in the window.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 8) {
            Button("Open HouseBridge") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(.defaultAction)
            Button("Quit") { model.quit() }
        }
        .padding(12)
        .frame(width: 200)
    }
}

import SwiftUI
import AppKit
import HouseBridgeCore

/// Menu bar front end. All behaviour comes from ~/.config/housebridge/config.yaml; this just shows status
/// and recent activity, and reloads the file whenever it changes.
@MainActor
final class AppModel: ObservableObject {
    @Published var statuses: [Subsystem: ConnectionStatus] = [:]
    @Published var activity: [LogEntry] = []
    @Published var configError: String?
    @Published var ruleCount = 0

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
            ruleCount = config.rules.count
            currentConfig = config
            configError = nil
            let hub = Hub(config: config, paths: paths,
                          log: { [weak self] e in Task { @MainActor in self?.append(e) } },
                          status: { [weak self] s, st in Task { @MainActor in self?.statuses[s] = st } },
                          onEvent: { [weak self] e in
                              Task { @MainActor in self?.append(LogEntry(category: "event", message: e.summary)) }
                          })
            self.hub = hub
            hub.start()
            append(LogEntry(category: "config", message: "loaded \(config.rules.count) rule(s)"))
        } catch {
            // Keep whatever was running; surface the problem.
            configError = "\(error)"
            append(LogEntry(level: .error, category: "config", message: "\(error)"))
        }
    }

    private func append(_ entry: LogEntry) {
        activity.insert(entry, at: 0)
        if activity.count > 60 { activity.removeLast(activity.count - 60) }
    }

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

        Window("HouseBridge Devices", id: "devices") {
            DevicesView(model: model)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HouseBridge").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Subsystem.allCases, id: \.self) { sub in
                    let status = model.statuses[sub] ?? .notConfigured
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(color(for: status)).frame(width: 8, height: 8)
                        Text(sub.rawValue.capitalized).frame(width: 52, alignment: .leading)
                        Text(status.label).foregroundStyle(.secondary).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }

            if let error = model.configError {
                Text("Config problem — still running the previous version:\n\(error)")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(model.ruleCount) rule(s) loaded").font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Text("Recent activity").font(.subheadline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if model.activity.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
                    ForEach(model.activity.prefix(30)) { entry in
                        Text("\(Self.time.string(from: entry.date))  \(entry.category): \(entry.message)")
                            .foregroundStyle(entry.level == .error ? .red : entry.level == .warning ? .orange : .primary)
                            .lineLimit(2)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 170)

            Divider()
            HStack {
                Button("Edit Config") { NSWorkspace.shared.open(model.configPath) }
                Button("Reload") { model.reload() }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.configPath]) }
            }
            HStack {
                Button(model.diagnosticsBusy ? "Testing…" : "Copy Diagnostics") { model.copyDiagnostics() }
                    .disabled(model.diagnosticsBusy)
                Button("Open Logs") { NSWorkspace.shared.open(model.logsFolder) }
                Button("Devices…") {
                    openWindow(id: "devices")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { model.quit() }
            }
        }
        .padding(12)
        .frame(width: 420)
    }

    private func color(for status: ConnectionStatus) -> Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .notConfigured: return .gray
        case .disconnected, .needsSetup: return .red
        }
    }
}

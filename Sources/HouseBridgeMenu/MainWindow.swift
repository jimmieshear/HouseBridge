import SwiftUI
import AppKit
import HouseBridgeCore
import CoreImage.CIFilterBuiltins

/// The main window: icon, connection status and actions on top, what is coming up in the middle, the activity log below.
struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var recentlyRun: Set<String> = []

    private static let logTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            actions.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if model.sensorsConfigured {
                sensorSection.padding(16)
                Divider()
            }
            upcoming.padding(16)
            Divider()
            log.padding(16)
        }
        .frame(minWidth: 820, minHeight: 620)
    }

    // MARK: Icon, status, buttons

    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left: identity.
            VStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 88, height: 88)
                Text("HouseBridge").font(.title3.weight(.semibold))
                if model.sensorsConfigured { climate }
            }
            .frame(width: 150)
            .padding(.trailing, 36)

            Divider()

            // Right: connection status, laid out as a table so the dots, names and messages each line up.
            VStack(alignment: .leading, spacing: 16) {
                Text("CONNECTIONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.8)

                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(Subsystem.allCases, id: \.self) { sub in
                        let status = model.statuses[sub] ?? .notConfigured
                        GridRow(alignment: .firstTextBaseline) {
                            Circle().fill(status.color).frame(width: 10, height: 10)
                            Text(sub == .homekit ? "HomeKit" : sub == .sensors ? "Home sensors" : sub.rawValue.capitalized).fontWeight(.medium)
                            Text(status.label).foregroundStyle(.secondary).lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let info = model.homeKit, !info.isPaired {
                    HStack(spacing: 12) {
                        if let qr = QRCode.image(info.setupURI) { Image(nsImage: qr).interpolation(.none).resizable().frame(width: 96, height: 96) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Add to Home.app").font(.subheadline)
                            Text(info.setupCode).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                            Text("Scan the code, or choose More options and type it in.").font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Spacer(minLength: 0)
                if let error = model.configError {
                    Text("Config problem — still running the previous version:\n\(error)")
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("\(model.ruleCount) rule(s) loaded").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 36)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .fixedSize(horizontal: false, vertical: true)   // the divider and columns take the height of the taller side
    }

    // MARK: Actions

    /// One row of equal-width buttons.
    private var actions: some View {
        HStack(spacing: 10) {
            sidebarButton("Edit Config") { NSWorkspace.shared.open(model.configPath) }
            sidebarButton("Reload") { model.reload() }
            sidebarButton("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.configPath]) }
            sidebarButton(model.diagnosticsBusy ? "Testing…" : "Copy Diagnostics") { model.copyDiagnostics() }
                .disabled(model.diagnosticsBusy)
            sidebarButton("Open Logs") { NSWorkspace.shared.open(model.logsFolder) }
            sidebarButton("Devices…") {
                openWindow(id: "devices")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            sidebarButton("Quit", role: .destructive) { model.quit() }
        }
    }

    /// A button as wide as its share of the row, so the edges line up.
    private func sidebarButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title) }
            .buttonStyle(SidebarButtonStyle(destructive: role == .destructive))
    }

    // MARK: Temperature and humidity

    /// Big temperature and humidity for each sensor that reports them, under the icon. Both take the colour of the
    /// temperature (red above 80°F, blue below 68°F, green between); greyed when the reading is old or unreachable.
    private var climate: some View {
        let groups = Dictionary(grouping: model.sensors.filter { $0.kind == "temperature" || $0.kind == "humidity" }, by: \.accessory)
            .values.sorted { ($0.first?.name.lowercased() ?? "") < ($1.first?.name.lowercased() ?? "") }
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 10) {
                ForEach(groups.prefix(3), id: \.first?.accessory) { group in
                    let temperature = group.first { $0.kind == "temperature" }
                    let humidity = group.first { $0.kind == "humidity" }
                    let stale = model.sensorIsStale(group, now: context.date)
                    let color = Self.climateColor(temperature?.value)
                    VStack(spacing: 1) {
                        if let t = temperature {
                            Text(String(format: "%.1f°F", t.value * 9 / 5 + 32))
                                .font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(color)
                                .help(String(format: "%.1f °C", t.value))
                        }
                        if let h = humidity {
                            Text(String(format: "%.0f%% humidity", h.value))
                                .font(.system(size: 17, weight: .medium, design: .rounded)).foregroundStyle(color)
                        }
                        Text(group[0].room.isEmpty ? group[0].name : "\(group[0].name) · \(group[0].room)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .minimumScaleFactor(0.7)
                    .opacity(stale ? 0.45 : 1)
                    .help(stale ? "Old reading, or the sensor or helper is not connected" : "")
                }
            }
        }
        .padding(.top, 6)
    }

    private static func climateColor(_ celsius: Double?) -> Color {
        guard let celsius else { return .green }
        switch TemperatureBand(celsius: celsius) {
        case .hot: return .red
        case .cold: return Color(nsColor: .systemBlue)   // plain .blue is too dark on the window's dark background
        case .comfortable: return .green
        }
    }

    // MARK: Sensors

    /// One row per HomeKit accessory: temperature, humidity, air quality (when the accessory has it) and the smoke / CO state.
    private var sensorSection: some View {
        let groups = Dictionary(grouping: model.sensors, by: \.accessory)
            .values.sorted { ($0.first?.name.lowercased() ?? "") < ($1.first?.name.lowercased() ?? "") }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sensors").font(.headline)
                if model.sensorHelperNeeded && !model.sensorHelperConnected {
                    Text("helper not connected, readings may be old and alarms are not being watched")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            // Re-evaluated every 30 seconds so "updated" ages and stale readings grey out.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if groups.isEmpty {
                    Text(model.sensorHelperNeeded && !model.sensorHelperConnected ? "Waiting for the HomeKit helper to start…" : "Waiting for readings…")
                        .foregroundStyle(.secondary)
                } else {
                    let rows = VStack(alignment: .leading, spacing: 6) {
                        ForEach(groups, id: \.first?.accessory) { group in sensorRow(group, now: context.date) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Exactly as tall as its rows; only a long list (more than four) scrolls, so there is no empty gap.
                    if groups.count > 4 {
                        ScrollView { rows }.frame(maxHeight: 190)
                    } else {
                        rows
                    }
                }
            }
        }
    }

    private func sensorRow(_ group: [SensorReading], now: Date) -> some View {
        let first = group[0]
        let newest = group.map(\.date).max() ?? first.date
        let stale = model.sensorIsStale(group, now: now)
        func value(_ kind: String) -> Double? { group.first { $0.kind == kind }?.value }
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(first.name).fontWeight(.medium)
                Text([first.room, first.home].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 210, alignment: .leading)
            if let c = value("temperature") { Text(Self.temperature(c)).help(String(format: "%.1f °C", c)) }
            if let h = value("humidity") { Text(String(format: "%.0f%% humidity", h)) }
            if let q = value("air_quality") { Text("air: " + Self.airQuality(q)) }
            if let p = value("pm25") { Text(String(format: "PM2.5 %.0f µg/m³", p)) }
            if let s = value("smoke") { alarmBadge("Smoke", s) }
            if let co = value("co") { alarmBadge("CO", co) }
            Spacer(minLength: 0)
            Text(group.contains { !$0.reachable } ? "unreachable" : "updated " + Self.ago(newest, now: now))
                .font(.caption).foregroundStyle(stale ? .orange : .secondary)
        }
        .font(.callout)
        .opacity(stale ? 0.65 : 1)
    }

    private func alarmBadge(_ label: String, _ value: Double) -> some View {
        let alarming = value >= 1
        return Text(alarming ? "\(label) DETECTED" : "\(label) OK")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(alarming ? Color.red : Color.green.opacity(0.25)))
            .foregroundStyle(alarming ? Color.white : Color.primary)
    }

    private static func temperature(_ celsius: Double) -> String { String(format: "%.1f°F", celsius * 9 / 5 + 32) }

    /// HomeKit's AirQuality enumeration.
    private static func airQuality(_ v: Double) -> String {
        ["unknown", "excellent", "good", "fair", "inferior", "poor"][max(0, min(5, Int(v)))]
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let s = Int(max(0, now.timeIntervalSince(date)))
        if s < 90 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }

    // MARK: Upcoming events

    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upcoming Events").font(.headline)
            // Re-evaluated every minute so past events drop off.
            TimelineView(.everyMinute) { context in
                let events = model.upcomingEvents(now: context.date)
                if events.isEmpty {
                    Text("No automation configured, use the config file")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(events) { event in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(Self.when(event.date, now: context.date))
                                        .font(.system(.callout, design: .monospaced)).frame(width: 150, alignment: .leading)
                                    Text(event.title).strikethrough(event.skipped)
                                    Text(event.skipped ? "skipped" : event.detail).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                    if let rule = event.ruleName {
                                        skipButton(event)
                                        runNowButton(rule)
                                    }
                                }
                                .opacity(event.skipped ? 0.6 : 1)
                                .font(.callout)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(minHeight: 110, maxHeight: 230, alignment: .top)
    }

    /// Skips just this occurrence (the schedule carries on afterwards); pressed again it takes the skip back.
    @ViewBuilder private func skipButton(_ event: UpcomingEvent) -> some View {
        Button {
            model.setSkipped(event, !event.skipped)
        } label: {
            Label(event.skipped ? "Undo skip" : "Skip", systemImage: event.skipped ? "arrow.uturn.backward" : "forward.end.fill").font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(event.skipped ? "Run this one after all." : "Don't run this one; the schedule carries on after it.")
    }

    /// Runs the rule's actions right away and keeps the result in place until the schedule next changes those devices.
    @ViewBuilder private func runNowButton(_ rule: String) -> some View {
        let done = recentlyRun.contains(rule)
        Button {
            model.runNow(rule)
            recentlyRun.insert(rule)
            Task { try? await Task.sleep(for: .seconds(3)); recentlyRun.remove(rule) }
        } label: {
            Label(done ? "Ran" : "Run now", systemImage: done ? "checkmark" : "play.fill").font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(done)
        .help("Run this now. It stays in place until the schedule next changes these devices.")
    }

    /// "Today 18:30", "Tomorrow 06:51", "Fri Nov 20 18:30"
    private static func when(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = DateFormatter(); time.dateFormat = "HH:mm"
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time.string(from: date))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(time.string(from: date))"
        }
        let f = DateFormatter(); f.dateFormat = "EEE MMM d HH:mm"
        return f.string(from: date)
    }

    // MARK: Log

    private var log: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent activity").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if model.activity.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
                    ForEach(model.activity) { entry in
                        Text("\(Self.logTime.string(from: entry.date))  \(entry.category): \(entry.message)")
                            .foregroundStyle(entry.level == .error ? .red : entry.level == .warning ? .orange : .primary)
                            .textSelection(.enabled)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// A full-width rounded button, so the column of actions lines up and every button is the same size.
private struct SidebarButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.07)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.5)
    }
}

extension ConnectionStatus {
    var color: Color {
        switch self {
        case .connected: return .green
        case .connecting: return .yellow
        case .notConfigured: return .gray
        case .disconnected, .needsSetup: return .red
        }
    }
}

enum QRCode {
    static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

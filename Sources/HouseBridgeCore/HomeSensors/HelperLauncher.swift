import Foundation

/// Thread-safe boolean, for "is the helper connected" shared between the socket callbacks and the watchdog.
final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { get { lock.withLock { flag } } set { lock.withLock { flag = newValue } } }
}

/// Starts the HouseBridgeHomeKit helper that is bundled inside HouseBridge.app, so there is no second app to install,
/// open or add to Login Items. The helper must be its own (Mac Catalyst) process because HomeKit only loads there; it
/// has no Dock icon or window, quits by itself when HouseBridge has been gone for a while, and is restarted here if it
/// dies. `open` is idempotent: an already running helper is left alone.
struct HomeKitHelperLauncher {
    let log: @Sendable (LogEntry) -> Void
    /// The helper's own output (why it could not reach HomeKit, connects, disconnects) when we start it ourselves.
    var helperLog: URL?

    /// `HOUSEBRIDGE_HOMEKIT_HELPER` (a path to the .app, for running from a build folder), else the copy inside
    /// the app bundle, found from whichever HouseBridge executable is running (the menu app or housebridgectl).
    static func helperURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                          executable: URL? = Bundle.main.executableURL) -> URL? {
        if let path = environment["HOUSEBRIDGE_HOMEKIT_HELPER"], !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard let contents = executable?.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent() else { return nil }
        let url = contents.appendingPathComponent("Helpers/HouseBridgeHomeKit.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// True while a HouseBridgeHomeKit process exists, however it was started (including by hand).
    static func isRunning() -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "HouseBridgeHomeKit"]
        pgrep.standardOutput = FileHandle.nullDevice
        do { try pgrep.run(); pgrep.waitUntilExit(); return pgrep.terminationStatus == 0 } catch { return false }
    }

    /// Starts the helper's executable directly, as a child of HouseBridge, when LaunchServices (`open`) refuses.
    func launchDirectly(_ url: URL) -> String? {
        let executable = url.appendingPathComponent("Contents/MacOS/HouseBridgeHomeKit")
        let process = Process()
        process.executableURL = executable
        process.standardInput = FileHandle.nullDevice
        if let helperLog {
            if !FileManager.default.fileExists(atPath: helperLog.path) {
                FileManager.default.createFile(atPath: helperLog.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            if let handle = try? FileHandle(forWritingTo: helperLog) {
                handle.seekToEndOfFile()
                process.standardOutput = handle; process.standardError = handle
            }
        }
        do { try process.run() } catch { return "\(error)" }
        return nil
    }

    /// Returns nil on success, else why it failed (the text `open` printed, or its exit status).
    func launch(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-j", "-a", url.path]   // don't activate, start hidden
        let output = Pipe()
        process.standardError = output; process.standardOutput = output
        do { try process.run() } catch { return "\(error)" }
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return "open exited \(process.terminationStatus)" + (text.isEmpty ? "" : ": \(text)")
    }

    /// Every 30 seconds without a connected helper, start it. Logs once per outage, not per attempt.
    func keepRunning(isConnected: @Sendable () -> Bool) async {
        guard let url = HomeKitHelperLauncher.helperURL() else {
            log(LogEntry(level: .warning, category: "sensors", message: "HouseBridgeHomeKit helper is not inside this app (rebuild with scripts/bundle.sh, or set HOUSEBRIDGE_HOMEKIT_HELPER to HouseBridgeHomeKit.app). Start it by hand to receive sensor readings."))
            return
        }
        var announced = false, lastFailure: String?
        while !Task.isCancelled {
            if !isConnected() && !HomeKitHelperLauncher.isRunning() {
                var failure = launch(url)
                if let openFailure = failure {
                    // `open` can refuse (e.g. LaunchServices state on a Mac) even though the app itself runs fine.
                    failure = launchDirectly(url).map { "\(openFailure); starting it directly also failed: \($0)" }
                    if failure == nil, !announced {
                        log(LogEntry(level: .warning, category: "sensors", message: "open could not start the helper (\(openFailure)); started its executable directly instead"))
                    }
                }
                if !announced || failure != lastFailure {
                    if let failure {
                        log(LogEntry(level: .error, category: "sensors", message: "could not start the bundled HouseBridgeHomeKit helper at \(url.path): \(failure). If this says the app is damaged or not allowed, this Mac may not be in the helper's provisioning profile (see README, HomeKit sensors)."))
                    } else if !announced {
                        log(LogEntry(category: "sensors", message: "starting the bundled HouseBridgeHomeKit helper; waiting for it to connect"))
                    }
                    announced = true; lastFailure = failure
                }
            } else {
                announced = false
            }
            try? await Task.sleep(for: .seconds(isConnected() ? 60 : 30))
        }
    }
}

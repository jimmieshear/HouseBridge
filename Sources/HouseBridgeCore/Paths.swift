import Foundation

public struct Paths: Sendable {
    public let home: URL

    public var configFile: URL { home.appendingPathComponent("config.yaml") }
    public var hueFile: URL { home.appendingPathComponent("hue.json") }
    public var logsDirectory: URL { home.appendingPathComponent("logs") }
    public var knownHostsFile: URL { home.appendingPathComponent("known_hosts.json") }

    public init(home: URL) { self.home = home }

    public static func standard() -> Paths {
        if let override = ProcessInfo.processInfo.environment["HOUSEBRIDGE_HOME"], !override.isEmpty {
            return Paths(home: URL(fileURLWithPath: expand(override)))
        }
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/housebridge")
        return Paths(home: base)
    }

    public func ensureExists() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    public static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

/// Polls a file's modification date; calls back when it changes. Polling survives editors that replace files.
public final class FileWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private var last: Date?
    private var timer: DispatchSourceTimer?

    public init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
        self.last = FileWatcher.modified(url)
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = FileWatcher.modified(self.url)
            if now != self.last {
                self.last = now
                self.onChange()
            }
        }
        t.resume()
        timer = t
    }

    public func stop() { timer?.cancel(); timer = nil }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

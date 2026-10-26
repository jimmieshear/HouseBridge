import Foundation

public enum Source: String, Sendable {
    case pico
    case lutronSwitch = "switch"
    case unifi
    case clock
}

/// Something that happened in the house. Rules match against these.
///
/// - pico:    `input` is the button (on/off/raise/lower/favorite/button_N), `kind` is
///            press | release | tap | double_tap | hold | hold_release
/// - switch:  `input` is "power", `kind` is on | off
/// - clock:   `input` is the schedule key (e.g. "18:30", "sunset-30"), `kind` is "fire"
/// - unifi:   `input` is motion | person | vehicle | animal | package | licensePlate | ring | contact | leak ...,
///            `kind` is start | end | clear (contact: open | closed)
public struct TriggerEvent: Sendable {
    public var source: Source
    public var device: String
    public var deviceAliases: [String]
    public var input: String
    public var inputAliases: [String]
    public var kind: String
    public var detail: String?
    public var date: Date
    /// The source system's id for the device (UniFi Protect id), when it has one.
    public var deviceID: String?

    public init(source: Source, device: String, deviceAliases: [String] = [], input: String,
                inputAliases: [String] = [], kind: String, detail: String? = nil, date: Date = Date(), deviceID: String? = nil) {
        self.source = source
        self.device = device
        self.deviceAliases = deviceAliases
        self.input = input
        self.inputAliases = inputAliases
        self.kind = kind
        self.detail = detail
        self.date = date
        self.deviceID = deviceID
    }

    public func with(kind: String) -> TriggerEvent {
        var copy = self
        copy.kind = kind
        copy.date = Date()
        return copy
    }

    /// Identifies the physical thing (a button, a sensor) independent of the gesture.
    public var key: String { "\(source.rawValue)|\(device.lowercased())|\(input.lowercased())" }

    public var summary: String {
        "\(source.rawValue) \(device) · \(input) · \(kind)" + (detail.map { " (\($0))" } ?? "")
    }
}

public enum LogLevel: String, Sendable { case info, warning, error }

public struct LogEntry: Sendable, Identifiable {
    public let id = UUID()
    public let date: Date
    public let level: LogLevel
    public let category: String
    public let message: String

    public init(level: LogLevel = .info, category: String, message: String, date: Date = Date()) {
        self.level = level
        self.category = category
        self.message = message
        self.date = date
    }
}

public enum Subsystem: String, Sendable, CaseIterable { case lutron, hue, unifi, homekit }

public enum ConnectionStatus: Sendable, Equatable {
    case notConfigured
    case connecting
    case connected(String)
    case disconnected(String)
    case needsSetup(String)

    public var label: String {
        switch self {
        case .notConfigured: return "Not configured"
        case .connecting: return "Connecting…"
        case .connected(let s): return s.isEmpty ? "Connected" : "Connected · \(s)"
        case .disconnected(let s): return "Disconnected · \(s)"
        case .needsSetup(let s): return "Setup needed · \(s)"
        }
    }

    public var isHealthy: Bool { if case .connected = self { return true } else { return false } }
}

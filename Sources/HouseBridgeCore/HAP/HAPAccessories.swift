import Foundation
import CryptoKit

struct HAPCharKey: Hashable, Sendable {
    var aid: Int
    var iid: Int
}

enum HAPValue: Equatable {
    case bool(Bool), int(Int), double(Double), string(String), data(Data), null

    var json: Any {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .data(let d): return d.base64EncodedString()   // tlv8 and data formats travel as base64 text
        case .null: return NSNull()
        }
    }
}

struct HAPCharacteristic {
    var iid: Int
    var type: String
    var format: String
    var perms: [String]
    var description: String
    var initial: HAPValue = .null
    var extra: [String: Any] = [:]

    var readable: Bool { perms.contains("pr") }
    var writable: Bool { perms.contains("pw") }
    var notifies: Bool { perms.contains("ev") }

    func json(value: HAPValue?) -> [String: Any] {
        var out: [String: Any] = ["iid": iid, "type": type, "format": format, "perms": perms, "description": description]
        for (k, v) in extra { out[k] = v }
        if readable, let value { out["value"] = value.json }
        return out
    }
}

struct HAPService {
    var iid: Int
    var type: String
    var characteristics: [HAPCharacteristic]
}

struct HAPAccessory {
    var aid: Int
    var services: [HAPService]

    func json(values: (HAPCharKey) -> HAPValue?) -> [String: Any] {
        ["aid": aid, "services": services.map { service in
            ["iid": service.iid, "type": service.type,
             "characteristics": service.characteristics.map { $0.json(value: values(HAPCharKey(aid: aid, iid: $0.iid))) }] as [String: Any]
        }]
    }
}

/// How a Protect event input maps onto a HomeKit characteristic.
struct HAPRoute: Equatable {
    enum Kind { case motion, contact, leak, button, temperature, humidity }
    var key: HAPCharKey
    var kind: Kind
}

enum HAPLayout {
    // Service and characteristic types (short form of the HomeKit base UUID).
    static let accessoryInformation = "3E", protocolInformation = "A2"
    static let switchService = "49", outletService = "47", motionSensor = "85", contactSensor = "80", leakSensor = "83", statelessSwitch = "89"
    static let temperatureSensor = "8A", humiditySensor = "82"

    /// Inputs that have their own handling; anything else a camera reports is a smart detection (person, vehicle, ...).
    private static let knownInputs: Set<String> = ["motion", "ring", "contact", "leak", "tamper", "alarm", "temperature", "humidity"]

    struct Built {
        var accessories: [HAPAccessory] = []
        /// Keyed by `"<protect device id>|<input>"`.
        var routes: [String: HAPRoute] = [:]
        /// Keyed by the lowercased switch name; the On characteristic of that switch.
        var switches: [String: HAPCharKey] = [:]
        /// Keyed by the lowercased plug name; the On characteristic of that outlet.
        var outlets: [String: HAPCharKey] = [:]
        /// Camera accessories: aid -> Protect device id, and each camera's SetupEndpoints characteristic.
        var cameras: [Int: String] = [:]
        var setupEndpoints: [HAPCharKey: Int] = [:]
        var selectedStreams: [HAPCharKey: Int] = [:]
        var streamingStatus: [Int: HAPCharKey] = [:]
    }

    private struct IIDs {
        var next = 1
        mutating func take() -> Int { defer { next += 1 }; return next }
    }

    private static func string(_ ids: inout IIDs, _ type: String, _ description: String, _ value: String) -> HAPCharacteristic {
        HAPCharacteristic(iid: ids.take(), type: type, format: "string", perms: ["pr"], description: description,
                          initial: .string(value), extra: ["maxLen": 64])
    }

    private static func information(_ ids: inout IIDs, name: String, manufacturer: String, model: String,
                                    serial: String, firmware: String) -> HAPService {
        let serviceIID = ids.take()
        let identify = HAPCharacteristic(iid: ids.take(), type: "14", format: "bool", perms: ["pw"], description: "Identify")
        let characteristics = [
            identify,
            string(&ids, "20", "Manufacturer", manufacturer),
            string(&ids, "21", "Model", model),
            string(&ids, "23", "Name", name),
            string(&ids, "30", "Serial Number", serial),
            string(&ids, "52", "Firmware Revision", firmware),
        ]
        return HAPService(iid: serviceIID, type: accessoryInformation, characteristics: characteristics)
    }

    private static func sensor(_ ids: inout IIDs, aid: Int, name: String, kind: HAPRoute.Kind) -> (HAPService, HAPRoute) {
        let serviceIID = ids.take()
        let nameCharacteristic = string(&ids, "23", "Name", name)
        let serviceType: String
        var state: HAPCharacteristic
        let iid = ids.take()
        switch kind {
        case .motion:
            serviceType = motionSensor
            state = HAPCharacteristic(iid: iid, type: "22", format: "bool", perms: ["pr", "ev"],
                                      description: "Motion Detected", initial: .bool(false))
        case .contact:
            serviceType = contactSensor   // 0 = contact detected (closed), 1 = not detected (open)
            state = HAPCharacteristic(iid: iid, type: "6", format: "uint8", perms: ["pr", "ev"],
                                      description: "Contact Sensor State", initial: .int(0), extra: ["minValue": 0, "maxValue": 1])
        case .leak:
            serviceType = leakSensor
            state = HAPCharacteristic(iid: iid, type: "70", format: "uint8", perms: ["pr", "ev"],
                                      description: "Leak Detected", initial: .int(0), extra: ["minValue": 0, "maxValue": 1])
        case .temperature, .humidity:
            preconditionFailure("measurement services are built by `measurement`")
        case .button:
            serviceType = statelessSwitch   // reads as null; each press is delivered as an event with value 0 (single press)
            state = HAPCharacteristic(iid: iid, type: "73", format: "uint8", perms: ["pr", "ev"],
                                      description: "Programmable Switch Event", initial: .null,
                                      extra: ["minValue": 0, "maxValue": 2, "valid-values": [0]])
        }
        let service = HAPService(iid: serviceIID, type: serviceType, characteristics: [nameCharacteristic, state])
        return (service, HAPRoute(key: HAPCharKey(aid: aid, iid: iid), kind: kind))
    }

    /// A Temperature Sensor (°C) or Humidity Sensor (%) service; the real value is set once the layout is in place.
    private static func measurement(_ ids: inout IIDs, aid: Int, name: String, kind: HAPRoute.Kind) -> (HAPService, HAPRoute) {
        let serviceIID = ids.take()
        let nameCharacteristic = string(&ids, "23", "Name", name)
        let iid = ids.take()
        let isTemperature = kind == .temperature
        let value = HAPCharacteristic(iid: iid, type: isTemperature ? "11" : "10", format: "float", perms: ["pr", "ev"],
                                      description: isTemperature ? "Current Temperature" : "Current Relative Humidity",
                                      initial: .double(0),
                                      extra: isTemperature ? ["unit": "celsius", "minValue": -270, "maxValue": 100, "minStep": 0.1]
                                                           : ["unit": "percentage", "minValue": 0, "maxValue": 100, "minStep": 1])
        let service = HAPService(iid: serviceIID, type: isTemperature ? temperatureSensor : humiditySensor, characteristics: [nameCharacteristic, value])
        return (service, HAPRoute(key: HAPCharKey(aid: aid, iid: iid), kind: kind))
    }

    /// "licensePlate" -> "License Plate"
    static func label(_ input: String) -> String {
        var out = ""
        for ch in input {
            if ch.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(out.isEmpty ? Character(ch.uppercased()) : ch)
        }
        return out
    }

    static func build(bridgeName: String, bridgeID: String, devices: [(device: HAPDevice, aid: Int)],
                      smartDetections: Bool, cameras: Bool = false,
                      switches: [(name: String, aid: Int)] = [], outlets: [(name: String, aid: Int)] = []) -> Built {
        var built = Built()

        var ids = IIDs()
        let bridgeInfo = information(&ids, name: bridgeName, manufacturer: "HouseBridge", model: "HouseBridge",
                                     serial: bridgeID, firmware: "1.0")
        let protocolIID = ids.take()
        let version = string(&ids, "37", "Version", "1.1.0")
        built.accessories.append(HAPAccessory(aid: 1, services: [
            bridgeInfo, HAPService(iid: protocolIID, type: protocolInformation, characteristics: [version]),
        ]))

        for (device, aid) in devices {
            var ids = IIDs()
            var services = [information(&ids, name: device.name, manufacturer: "Ubiquiti",
                                        model: device.model.isEmpty ? "UniFi Protect" : device.model,
                                        serial: device.id, firmware: "1.0")]
            func add(_ input: String, _ suffix: String, _ kind: HAPRoute.Kind) {
                let (service, route) = sensor(&ids, aid: aid, name: "\(device.name) \(suffix)", kind: kind)
                services.append(service)
                built.routes["\(device.id)|\(input)"] = route
            }
            let provides = Set(device.provides)
            if provides.contains("contact") { add("contact", "Contact", .contact) }
            if provides.contains("motion") { add("motion", "Motion", .motion) }
            if provides.contains("leak") { add("leak", "Leak", .leak) }
            if provides.contains("ring") { add("ring", "Doorbell", .button) }
            for (input, suffix, kind) in [("temperature", "Temperature", HAPRoute.Kind.temperature), ("humidity", "Humidity", .humidity)]
            where provides.contains(input) {
                let (service, route) = measurement(&ids, aid: aid, name: "\(device.name) \(suffix)", kind: kind)
                services.append(service)
                built.routes["\(device.id)|\(input)"] = route
            }
            if smartDetections {
                for input in device.provides.filter({ !knownInputs.contains($0) }) { add(input, label(input), .motion) }
            }
            if cameras, device.kind == "camera" {
                services += cameraServices(&ids, aid: aid, name: device.name, built: &built)
                built.cameras[aid] = device.id
            }
            built.accessories.append(HAPAccessory(aid: aid, services: services))
        }

        // Rule switches: on while the automation's lights are on, writable so Home.app can start or stop it.
        for (name, aid) in switches {
            var ids = IIDs()
            let info = information(&ids, name: name, manufacturer: "HouseBridge", model: "Automation Switch",
                                   serial: "switch-\(aid)", firmware: "1.0")
            let serviceIID = ids.take()
            let nameCharacteristic = string(&ids, "23", "Name", name)
            let on = HAPCharacteristic(iid: ids.take(), type: "25", format: "bool", perms: ["pr", "pw", "ev"],
                                       description: "On", initial: .bool(false))
            let service = HAPService(iid: serviceIID, type: switchService, characteristics: [nameCharacteristic, on])
            built.accessories.append(HAPAccessory(aid: aid, services: [info, service]))
            built.switches[name.lowercased()] = HAPCharKey(aid: aid, iid: on.iid)
        }

        // Kasa plugs: an Outlet, writable. Outlet In Use stays true (a plug cannot tell whether something is drawing power).
        for (name, aid) in outlets {
            var ids = IIDs()
            let info = information(&ids, name: name, manufacturer: "TP-Link", model: "Kasa Plug",
                                   serial: "outlet-\(aid)", firmware: "1.0")
            let serviceIID = ids.take()
            let nameCharacteristic = string(&ids, "23", "Name", name)
            let on = HAPCharacteristic(iid: ids.take(), type: "25", format: "bool", perms: ["pr", "pw", "ev"],
                                       description: "On", initial: .bool(false))
            let inUse = HAPCharacteristic(iid: ids.take(), type: "26", format: "bool", perms: ["pr", "ev"],
                                          description: "Outlet In Use", initial: .bool(true))
            let service = HAPService(iid: serviceIID, type: outletService, characteristics: [nameCharacteristic, on, inUse])
            built.accessories.append(HAPAccessory(aid: aid, services: [info, service]))
            built.outlets[name.lowercased()] = HAPCharKey(aid: aid, iid: on.iid)
        }
        return built
    }

    /// The services that make an accessory a camera in Home.app: stream management (what it can send and how to ask
    /// for it) and a microphone. Snapshots need no characteristic; they are fetched through `POST /resource`.
    private static func cameraServices(_ ids: inout IIDs, aid: Int, name: String, built: inout Built) -> [HAPService] {
        func tlvChar(_ type: String, _ description: String, _ perms: [String], _ value: Data) -> HAPCharacteristic {
            HAPCharacteristic(iid: ids.take(), type: type, format: "tlv8", perms: perms, description: description, initial: .data(value))
        }
        let managementIID = ids.take()
        let video = tlvChar(HAPCamera.supportedVideo, "Supported Video Stream Configuration", ["pr"], HAPCamera.supportedVideoConfiguration())
        let audio = tlvChar(HAPCamera.supportedAudio, "Supported Audio Stream Configuration", ["pr"], HAPCamera.supportedAudioConfiguration())
        let rtp = tlvChar(HAPCamera.supportedRTP, "Supported RTP Configuration", ["pr"], HAPCamera.supportedRTPConfiguration())
        let selected = tlvChar(HAPCamera.selectedStream, "Selected RTP Stream Configuration", ["pr", "pw"], HAPCamera.idleSelection())
        let setup = tlvChar(HAPCamera.setupEndpoints, "Setup Endpoints", ["pr", "pw"], Data())
        let status = tlvChar(HAPCamera.streamingStatus, "Streaming Status", ["pr", "ev"], HAPCamera.streamingStatus())
        let active = HAPCharacteristic(iid: ids.take(), type: HAPCamera.active, format: "uint8", perms: ["pr", "pw", "ev"],
                                       description: "Active", initial: .int(1), extra: ["minValue": 0, "maxValue": 1])
        built.setupEndpoints[HAPCharKey(aid: aid, iid: setup.iid)] = aid
        built.selectedStreams[HAPCharKey(aid: aid, iid: selected.iid)] = aid
        built.streamingStatus[aid] = HAPCharKey(aid: aid, iid: status.iid)
        let micIID = ids.take()
        let mute = HAPCharacteristic(iid: ids.take(), type: HAPCamera.mute, format: "bool", perms: ["pr", "pw", "ev"],
                                     description: "Mute", initial: .bool(false))
        return [HAPService(iid: managementIID, type: HAPCamera.streamManagement, characteristics: [video, audio, rtp, selected, setup, status, active]),
                HAPService(iid: micIID, type: HAPCamera.microphone, characteristics: [mute])]
    }

    /// Changes whenever the shape of the accessory database changes (values excluded); drives the `c#` number.
    static func fingerprint(_ accessories: [HAPAccessory]) -> String {
        let json = accessories.map { $0.json(values: { _ in nil }) }
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

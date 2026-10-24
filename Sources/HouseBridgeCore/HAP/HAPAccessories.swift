import Foundation
import CryptoKit

struct HAPCharKey: Hashable, Sendable {
    var aid: Int
    var iid: Int
}

enum HAPValue: Equatable {
    case bool(Bool), int(Int), string(String), null

    var json: Any {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i
        case .string(let s): return s
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
    enum Kind { case motion, contact, leak, button }
    var key: HAPCharKey
    var kind: Kind
}

enum HAPLayout {
    // Service and characteristic types (short form of the HomeKit base UUID).
    static let accessoryInformation = "3E", protocolInformation = "A2"
    static let motionSensor = "85", contactSensor = "80", leakSensor = "83", statelessSwitch = "89"

    /// Inputs that have their own handling; anything else a camera reports is a smart detection (person, vehicle, ...).
    private static let knownInputs: Set<String> = ["motion", "ring", "contact", "leak", "tamper", "alarm"]

    struct Built {
        var accessories: [HAPAccessory] = []
        /// Keyed by `"<protect device id>|<input>"`.
        var routes: [String: HAPRoute] = [:]
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
        case .button:
            serviceType = statelessSwitch   // reads as null; each press is delivered as an event with value 0 (single press)
            state = HAPCharacteristic(iid: iid, type: "73", format: "uint8", perms: ["pr", "ev"],
                                      description: "Programmable Switch Event", initial: .null,
                                      extra: ["minValue": 0, "maxValue": 2, "valid-values": [0]])
        }
        let service = HAPService(iid: serviceIID, type: serviceType, characteristics: [nameCharacteristic, state])
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
                      smartDetections: Bool) -> Built {
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
            if smartDetections {
                for input in device.provides.filter({ !knownInputs.contains($0) }) { add(input, label(input), .motion) }
            }
            built.accessories.append(HAPAccessory(aid: aid, services: services))
        }
        return built
    }

    /// Changes whenever the shape of the accessory database changes (values excluded); drives the `c#` number.
    static func fingerprint(_ accessories: [HAPAccessory]) -> String {
        let json = accessories.map { $0.json(values: { _ in nil }) }
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

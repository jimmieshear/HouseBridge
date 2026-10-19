import Foundation
import Compression

/// One update from the Protect `/ws/updates` socket: an "action" header and a "data" payload.
struct ProtectUpdate {
    var action: JSON
    var data: JSON
}

enum ProtectPacket {
    enum DecodeError: Error { case truncated, badFormat, inflate }

    /// Frame layout: [type, format, deflated, 0, size(UInt32 BE)] header (8 bytes) + payload, twice.
    /// format: 1 = JSON, 2 = UTF-8 string, 3 = binary. deflated: 1 if zlib-compressed.
    static func decode(_ data: Data) throws -> ProtectUpdate {
        let bytes = [UInt8](data)
        var offset = 0
        func frame() throws -> (format: UInt8, payload: Data) {
            guard bytes.count >= offset + 8 else { throw DecodeError.truncated }
            let format = bytes[offset + 1]
            let deflated = bytes[offset + 2] == 1
            let size = Int(bytes[offset + 4]) << 24 | Int(bytes[offset + 5]) << 16 | Int(bytes[offset + 6]) << 8 | Int(bytes[offset + 7])
            offset += 8
            guard bytes.count >= offset + size else { throw DecodeError.truncated }
            var payload = Data(bytes[offset..<offset + size])
            offset += size
            if deflated { payload = try inflate(payload) }
            return (format, payload)
        }
        let actionFrame = try frame()
        let dataFrame = try frame()
        guard actionFrame.format == 1, let action = try JSONSerialization.jsonObject(with: actionFrame.payload) as? JSON else {
            throw DecodeError.badFormat
        }
        let body: JSON = dataFrame.format == 1
            ? ((try? JSONSerialization.jsonObject(with: dataFrame.payload)) as? JSON ?? [:])
            : [:]
        return ProtectUpdate(action: action, data: body)
    }

    /// Protect uses zlib-wrapped deflate; Compression's COMPRESSION_ZLIB wants the raw stream, so skip the 2-byte header.
    static func inflate(_ data: Data) throws -> Data {
        guard data.count > 2 else { throw DecodeError.inflate }
        let raw = data.dropFirst(2)
        var capacity = max(raw.count * 8, 4096)
        for _ in 0..<6 {
            var out = [UInt8](repeating: 0, count: capacity)
            let written = raw.withUnsafeBytes { src -> Int in
                guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(&out, capacity, base, raw.count, nil, COMPRESSION_ZLIB)
            }
            if written > 0 && written < capacity { return Data(out[0..<written]) }
            capacity *= 4
        }
        throw DecodeError.inflate
    }
}

/// Turns raw Protect updates into TriggerEvents.
///
/// Cameras: `event` records (type motion / smartDetectZone / smartDetectLine / ring) are tracked by id so that
/// later "update" messages (which only carry the changed fields, e.g. `end`) can be tied back to the camera and type.
/// Sensors: field changes (`isOpened`, `isMotionDetected`, `leakDetectedAt`, ...).
final class ProtectInterpreter {
    struct Device { var name: String; var kind: String }
    private struct TrackedEvent {
        var cameraId: String
        var startedInputs: Set<String> = []
        var finished = false
    }

    var devices: [String: Device] = [:]
    private var events: [String: TrackedEvent] = [:]
    private var order: [String] = []

    func interpret(_ update: ProtectUpdate) -> [TriggerEvent] {
        let action = update.action["action"] as? String ?? ""
        let model = update.action["modelKey"] as? String ?? ""
        let id = update.action["id"] as? String ?? ""
        switch model {
        case "event": return interpretEvent(action: action, id: id, data: update.data)
        case "sensor": return interpretSensor(id: id, data: update.data)
        default: return []
        }
    }

    private func event(_ device: Device, input: String, kind: String, detail: String? = nil) -> TriggerEvent {
        TriggerEvent(source: .unifi, device: device.name, deviceAliases: [], input: input, inputAliases: [], kind: kind, detail: detail)
    }

    private func interpretEvent(action: String, id: String, data: JSON) -> [TriggerEvent] {
        var tracked: TrackedEvent
        if action == "add" {
            guard let cameraId = data["camera"] as? String ?? data["device"] as? String else { return [] }
            tracked = TrackedEvent(cameraId: cameraId)
            order.append(id)
            if order.count > 500, let old = order.first { events.removeValue(forKey: old); order.removeFirst() }
        } else if action == "update", let existing = events[id] {
            tracked = existing
        } else {
            return []
        }
        guard let camera = devices[tracked.cameraId] else { return [] }

        var out: [TriggerEvent] = []
        var inputs = Set<String>()
        switch data["type"] as? String {
        case "motion": inputs.insert("motion")
        case "ring": inputs.insert("ring")
        default: break
        }
        // smartDetectTypes may arrive on "add" or on a later "update".
        if let types = data["smartDetectTypes"] as? [String] { types.forEach { inputs.insert($0) } }
        // An update to a tracked event that doesn't restate type keeps its previously-started inputs alive.

        if tracked.finished { return [] }
        for input in inputs.sorted() where !tracked.startedInputs.contains(input) {
            tracked.startedInputs.insert(input)
            out.append(event(camera, input: input, kind: "start", detail: (data["score"] as? Int).map { "score \($0)" }))
            if input == "ring" { /* a ring is momentary; treat as start+end */ }
        }
        if let end = data["end"], !(end is NSNull) {
            tracked.finished = true
            for input in tracked.startedInputs.sorted() { out.append(event(camera, input: input, kind: "end")) }
        }
        events[id] = tracked
        return out
    }

    private func interpretSensor(id: String, data: JSON) -> [TriggerEvent] {
        guard let sensor = devices[id] else { return [] }
        var out: [TriggerEvent] = []
        if let opened = data["isOpened"] as? Bool {
            out.append(event(sensor, input: "contact", kind: opened ? "open" : "closed"))
        }
        if let motion = data["isMotionDetected"] as? Bool {
            out.append(event(sensor, input: "motion", kind: motion ? "start" : "end"))
        }
        for (field, input) in [("leakDetectedAt", "leak"), ("externalLeakDetectedAt", "leak"),
                               ("alarmTriggeredAt", "alarm"), ("tamperingDetectedAt", "tamper")] {
            if let value = data[field] {
                if value is NSNull { out.append(event(sensor, input: input, kind: "end")) }
                else if value is NSNumber { out.append(event(sensor, input: input, kind: "start")) }
            }
        }
        return out
    }
}

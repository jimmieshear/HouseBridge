import Foundation

/// `housebridgectl check-hue`: what the Hue bridge itself has set up that can change the lights without HouseBridge:
/// scenes (and whether their white temperature matches `light_defaults`), smart scenes (Natural light and other
/// time-based ones, with their time slots) and the routines made in the Hue app. Read-only. The bridge's field names are
/// from memory of the CLIP v2 API, so the parts that cannot be read are printed raw rather than guessed at.
public enum HueSchedule {
    /// Every `mirek` number anywhere inside `value` (a scene's actions, a routine's configuration).
    static func mirekValues(in value: Any) -> [Int] {
        var out: [Int] = []
        func walk(_ v: Any) {
            if let d = v as? JSON {
                for (k, x) in d {
                    if k == "mirek", let n = x as? Int { out.append(n) } else { walk(x) }
                }
            } else if let a = v as? [Any] { a.forEach(walk) }
        }
        walk(value)
        return out
    }

    /// "20:00" for every `{"hour": 20, "minute": 0}` found.
    static func times(in value: Any) -> [String] {
        var out: [String] = []
        func walk(_ v: Any) {
            if let d = v as? JSON {
                if let h = d["hour"] as? Int, let m = d["minute"] as? Int { out.append(String(format: "%02d:%02d", h, m)) }
                d.values.forEach(walk)
            } else if let a = v as? [Any] { a.forEach(walk) }
        }
        walk(value)
        return out
    }

    /// (type, id) of every `{"rid": …, "rtype": …}` reference found.
    static func references(in value: Any) -> [(type: String, id: String)] {
        var out: [(String, String)] = []
        func walk(_ v: Any) {
            if let d = v as? JSON {
                if let id = d["rid"] as? String, let type = d["rtype"] as? String { out.append((type, id)) }
                d.values.forEach(walk)
            } else if let a = v as? [Any] { a.forEach(walk) }
        }
        walk(value)
        return out.map { (type: $0.0, id: $0.1) }
    }

    static func kelvin(_ mirek: Int) -> Int { LightTemperature.kelvin(mirek: mirek) }

    static func kelvinText(_ mireks: [Int]) -> String {
        guard let lo = mireks.max(), let hi = mireks.min() else { return "no temperature" }
        let a = kelvin(lo), b = kelvin(hi)
        return a == b ? "\(a) K" : "\(a)–\(b) K"
    }

    static func report(scenes: [JSON], smartScenes: [JSON], routines: [JSON], groupNames: [String: String],
                              target: (kelvin: Int, tolerance: Int)?, filter: String? = nil,
                              smartScenesError: String? = nil, routinesError: String? = nil,
                              lights: [JSON] = [], lightRooms: [String: String] = [:]) -> String {
        var out: [String] = []
        func name(_ item: JSON) -> String { (item["metadata"] as? JSON)?["name"] as? String ?? "(unnamed)" }
        func group(_ item: JSON) -> String { ((item["group"] as? JSON)?["rid"] as? String).flatMap { groupNames[$0] } ?? "?" }
        let sceneByID = Dictionary(scenes.compactMap { s in (s["id"] as? String).map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        let matching: (JSON) -> Bool = { s in filter.map { name(s).lowercased().contains($0.lowercased()) || group(s).lowercased().contains($0.lowercased()) } ?? true }

        if let target {
            let m = HueScene.mirek(kelvin: target.kelvin) ?? 0
            out.append("light_defaults target: \(target.kelvin) K (Hue stores it as mirek \(m), shown as \(kelvin(m)) K), tolerance ±\(target.tolerance) K")
        } else {
            out.append("no light_defaults in the config: scenes are listed without a target")
        }

        // Lights that can show a white temperature, and whether each is showing one or a color right now.
        let whiteCapable = lights.filter { ($0["color_temperature"] as? JSON) != nil }
        if !whiteCapable.isEmpty {
            out.append("\n== Lights (color mode = shows a color, not a white; light_defaults leaves those alone unless an override has reset_color: true) ==")
            func lightName(_ l: JSON) -> String { (l["metadata"] as? JSON)?["name"] as? String ?? "(unnamed)" }
            func room(_ l: JSON) -> String { (l["id"] as? String).flatMap { lightRooms[$0] } ?? "?" }
            for l in whiteCapable.sorted(by: { (room($0), lightName($0)) < (room($1), lightName($1)) }) {
                let on = (l["on"] as? JSON)?["on"] as? Bool ?? false
                let brightness = ((l["dimming"] as? JSON)?["brightness"] as? Double).map { "\(Int($0.rounded()))%" } ?? "?"
                let ct = l["color_temperature"] as? JSON
                let mode: String
                if ct?["mirek_valid"] as? Bool == true, let mirek = ct?["mirek"] as? Int {
                    mode = "white \(kelvin(mirek)) K"
                } else if let xy = (l["color"] as? JSON)?["xy"] as? JSON, let x = xy["x"] as? Double, let y = xy["y"] as? Double {
                    mode = String(format: "COLOR MODE xy(%.3f, %.3f)", x, y)
                } else {
                    mode = "COLOR MODE"
                }
                out.append("  \(room(l)) / \(lightName(l)): \(on ? "on \(brightness)" : "off")  \(mode)")
            }
        }

        out.append("\n== Scenes\(filter.map { " matching “\($0)”" } ?? "") ==")
        let shown = scenes.filter(matching).sorted { (group($0), name($0)) < (group($1), name($1)) }
        for s in shown {
            let mireks = mirekValues(in: s["actions"] as Any)
            var flag = ""
            if let target, !mireks.isEmpty {
                let off = mireks.filter { abs(kelvin($0) - kelvin(HueScene.mirek(kelvin: target.kelvin) ?? $0)) > target.tolerance }
                flag = off.isEmpty ? "   ok" : "   DIFFERENT (\(off.count) of \(mireks.count) lights)"
            }
            let active = ((s["status"] as? JSON)?["active"] as? String).map { $0 == "inactive" ? "" : "   [ACTIVE: \($0)]" } ?? ""
            out.append("  \(group(s)) / \(name(s)): \(kelvinText(mireks))\(flag)\(active)")
        }
        if shown.isEmpty { out.append("  (none)") }

        out.append("\n== Smart scenes (time-based; Natural light is one) ==")
        for s in smartScenes.filter(matching).sorted(by: { (group($0), name($0)) < (group($1), name($1)) }) {
            out.append("  \(group(s)) / \(name(s)): \(s["state"] as? String ?? "?")")
            var seen = Set<String>()
            for slot in (s["week_timeslots"] as? [JSON]) ?? [] {
                let days = ((slot["recurrence"] as? [String]) ?? []).map { String($0.prefix(3)) }.joined(separator: ",")
                for t in (slot["timeslots"] as? [JSON]) ?? [] {
                    let start = times(in: t["start_time"] as Any).first ?? "?"
                    let target = (t["target"] as? JSON)?["rid"] as? String
                    let scene = target.flatMap { sceneByID[$0] }
                    let line = "      \(start)  \(scene.map { "\(name($0)): \(kelvinText(mirekValues(in: $0["actions"] as Any)))" } ?? "scene \(target ?? "?")")  (\(days))"
                    if seen.insert(line).inserted { out.append(line) }
                }
            }
        }
        if let smartScenesError { out.append("  COULD NOT READ: \(smartScenesError)") }
        else if smartScenes.isEmpty { out.append("  (none)") }

        out.append("\n== Routines and automations made in the Hue app ==")
        for r in routines.sorted(by: { name($0) < name($1) }) {
            let config = r["configuration"] as Any
            let t = Array(Set(times(in: config))).sorted().joined(separator: ", ")
            let scenesUsed = references(in: config).filter { $0.type == "scene" }.compactMap { sceneByID[$0.id].map { "\(group($0)) / \(name($0))" } }
            out.append("  “\(name(r))”  \(r["enabled"] as? Bool == false ? "DISABLED" : "enabled")  \(r["status"] as? String ?? "")"
                       + (t.isEmpty ? "" : "  at \(t)") + (scenesUsed.isEmpty ? "" : "  scenes: \(Set(scenesUsed).sorted().joined(separator: "; "))"))
            if t.isEmpty && scenesUsed.isEmpty, let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                out.append("      configuration: \(text.prefix(300))")   // shape not recognised: show it as it is
            }
        }
        if let routinesError { out.append("  COULD NOT READ: \(routinesError)") }
        else if routines.isEmpty { out.append("  (none)") }
        return out.joined(separator: "\n")
    }
}

extension HueClient {
    /// Fetches what `HueSchedule.report` needs (smart scenes and routines are optional: not every bridge has them).
    public func scheduleReport(target: (kelvin: Int, tolerance: Int)?, filter: String? = nil) async throws -> String {
        let inv = try await inventory(refresh: true)
        let names = Dictionary((inv.rooms + inv.zones).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let scenes = try await request("GET", "/resource/scene")
        // Not every bridge has these, and a failure must not read as "there are none": say what went wrong.
        var smartError: String?, routinesError: String?
        let smart: [JSON], routines: [JSON]
        do { smart = try await request("GET", "/resource/smart_scene") } catch { smart = []; smartError = describeError(error) }
        do { routines = try await request("GET", "/resource/behavior_instance") } catch { routines = []; routinesError = describeError(error) }
        let lights = (try? await request("GET", "/resource/light")) ?? []
        var lightRooms: [String: String] = [:]
        for room in inv.rooms { for id in room.lightIds { lightRooms[id] = room.name } }
        return HueSchedule.report(scenes: scenes, smartScenes: smart, routines: routines, groupNames: names, target: target, filter: filter,
                                  smartScenesError: smartError, routinesError: routinesError, lights: lights, lightRooms: lightRooms)
    }
}

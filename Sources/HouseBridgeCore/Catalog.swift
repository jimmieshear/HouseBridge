import Foundation

/// One thing HouseBridge knows about: what it reports (use in `when:`), what you can do with it (use in `then:`),
/// and a rule skeleton to paste into config.yaml.
public struct CatalogEntry: Identifiable, Sendable {
    public let id: String
    public let system: Subsystem
    public let kind: String
    public let name: String
    public let model: String
    public let provides: [String]
    public let accepts: [String]
    public let details: [String]
    public let snippet: String
    /// Name used to guess which Hue room this belongs to (a remote's area, a camera's name, ...).
    public var hint: String = ""
}

public struct CatalogResult: Sendable {
    public var entries: [CatalogEntry] = []
    /// Per-system problems (unreachable, not paired, ...). The rest of the catalog is still returned.
    public var problems: [Subsystem: String] = [:]

    public func text(includeSnippets: Bool = true) -> String {
        var out: [String] = []
        for system in Subsystem.allCases {
            let items = entries.filter { $0.system == system }
            if items.isEmpty && problems[system] == nil { continue }
            out.append("\n##### \(system.rawValue.uppercased()) #####")
            if let p = problems[system] { out.append("(could not load: \(p))") }
            for e in items {
                out.append("\n\(e.kind): “\(e.name)”" + (e.model.isEmpty ? "" : "  [\(e.model)]"))
                if !e.provides.isEmpty { out.append("  reports:") ; e.provides.forEach { out.append("    • \($0)") } }
                if !e.accepts.isEmpty { out.append("  you can:"); e.accepts.forEach { out.append("    • \($0)") } }
                if !e.details.isEmpty { out.append("  details: " + e.details.joined(separator: "; ")) }
                if includeSnippets, !e.snippet.isEmpty {
                    out.append("  example rule:")
                    e.snippet.split(separator: "\n", omittingEmptySubsequences: false).forEach { out.append("    \($0)") }
                }
            }
        }
        return out.joined(separator: "\n")
    }
}

public enum Catalog {
    static func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    public static func load(config: Config, paths: Paths) async -> CatalogResult {
        var result = CatalogResult()
        let hosts = KnownHosts(url: paths.knownHostsFile)
        var lutronInv: LutronInventory?
        var hueInv: HueInventory?

        if let l = config.lutron {
            if !l.missingFiles().isEmpty {
                result.problems[.lutron] = "certificate file(s) not found: " + l.missingFiles().joined(separator: ", ")
            } else {
                do {
                    let inv = try await withTimeout(20) { try await LutronBridge.discover(config: l) }
                    lutronInv = inv
                    result.entries += lutronEntries(inv)
                } catch { result.problems[.lutron] = describeError(error) }
            }
        }
        if let h = config.hue {
            if let creds = HueClient.load(from: paths.hueFile), creds.host == h.host {
                do {
                    let inv = try await withTimeout(20) { try await HueClient(credentials: creds, hosts: hosts).inventory(refresh: true) }
                    hueInv = inv
                    result.entries += hueEntries(inv)
                } catch { result.problems[.hue] = describeError(error) }
            } else {
                result.problems[.hue] = "not paired (run: housebridgectl pair-hue)"
            }
        }
        if let u = config.unifi {
            if u.resolvedPassword() == nil {
                result.problems[.unifi] = "no password (run: housebridgectl set-unifi-password)"
            } else {
                do {
                    let inv = try await withTimeout(30) { try await ProtectClient(config: u, hosts: hosts).discover() }
                    result.entries += unifiEntries(inv)
                } catch { result.problems[.unifi] = describeError(error) }
            }
        }
        result.entries = fillGuesses(result.entries, hue: hueInv, picos: lutronInv?.picos ?? [])
        return result
    }

    // MARK: Guessing names

    /// Replaces <hue room>, <remote> and <scene> with real names when a confident match exists, and says so in a header comment.
    static func fillGuesses(_ entries: [CatalogEntry], hue: HueInventory?, picos: [LutronDevice]) -> [CatalogEntry] {
        guard let hue else { return entries }
        let rooms = hue.rooms.map(\.name)
        let zones = hue.zones.map(\.name)
        return entries.map { e in
            var snippet = e.snippet
            var notes: [String] = []
            let usesRoom = snippet.contains("\"<hue room>\"")
            let usesRemote = snippet.contains("\"<remote>\"")
            let usesScene = snippet.contains("\"<scene>\"")

            var room: String?
            if usesRoom || usesScene, !e.hint.isEmpty { room = NameMatcher.bestMatch(for: e.hint, in: rooms) }
            if usesRoom {
                if let room {
                    snippet = snippet.replacingOccurrences(of: "\"<hue room>\"", with: Catalog.q(room))
                    notes.append("Hue room “\(room)” was guessed from the name “\(e.hint)” — change it if that's wrong.")
                } else if !rooms.isEmpty {
                    notes.append("Replace <hue room> with one of: " + rooms.sorted().joined(separator: ", ") + ".")
                }
            }
            if usesScene {
                let source = room ?? (e.kind == "Scene" ? e.model : "")
                if let scene = hue.scenes.filter({ $0.groupName == source }).map(\.name).sorted().first {
                    snippet = snippet.replacingOccurrences(of: "\"<scene>\"", with: Catalog.q(scene))
                    notes.append("Scene “\(scene)” is just the first one in that room — pick the one you want.")
                } else {
                    notes.append("Replace <scene> with a scene name from the Hue list.")
                }
            }
            if usesRemote, e.kind == "Room" || e.kind == "Zone" || e.kind == "Scene" {
                let group = e.kind == "Scene" ? e.model : e.name
                let candidates = Dictionary(picos.map { ($0.area.isEmpty ? $0.fullName : $0.area, $0) }, uniquingKeysWith: { a, _ in a })
                if !group.isEmpty, let key = NameMatcher.bestMatch(for: group, in: Array(candidates.keys)), let pico = candidates[key] {
                    snippet = snippet.replacingOccurrences(of: "\"<remote>\"", with: Catalog.q(pico.fullName))
                    notes.append("Remote “\(pico.fullName)” was guessed from the name — change it if that's wrong.")
                } else if !picos.isEmpty {
                    notes.append("Replace <remote> with one of: " + picos.map(\.fullName).sorted().joined(separator: ", ") + ".")
                }
            }
            if snippet.contains("\"<hue zone>\""), !zones.isEmpty {
                notes.append("Replace <hue zone> with one of: " + zones.sorted().joined(separator: ", ") + ".")
            }
            guard !notes.isEmpty else { return e }
            let header = notes.map { "# " + $0 }.joined(separator: "\n")
            return CatalogEntry(id: e.id, system: e.system, kind: e.kind, name: e.name, model: e.model,
                                provides: e.provides, accepts: e.accepts, details: e.details,
                                snippet: header + "\n" + snippet, hint: e.hint)
        }
    }

    // MARK: Example rules

    /// Strips the common leading indent from a multi-line literal and joins with newlines.
    static func lines(_ l: [String]) -> String { l.joined(separator: "\n") }

    /// Rules for a remote, shaped to the buttons it actually has (5-button: on / favorite / off / raise / lower).
    static func picoSnippet(shortName: String, fullName: String, buttons: [String]) -> String {
        let pico = q(fullName)
        let has = Set(buttons)
        var o: [String] = []
        let kind = buttons.count >= 5 ? "five-button" : (buttons.count >= 3 ? "three-button" : "two-button")
        o.append("# \(shortName): \(kind) remote (\(buttons.joined(separator: " / ")))")
        if has.contains("on") {
            o += ["- name: \(shortName) - on", "  when: { pico: \(pico), button: on, gesture: tap }",
                  "  then:", "    - action: light", "      room: \(q("<hue room>"))", "      on: true", ""]
        }
        if has.contains("off") {
            o += ["- name: \(shortName) - off", "  when: { pico: \(pico), button: off, gesture: tap }",
                  "  then:", "    - action: light", "      room: \(q("<hue room>"))", "      on: false", ""]
        }
        if has.contains("raise") && has.contains("lower") {
            o += ["# Raise / lower step through the room's Hue scenes. Wraps around at either end, and follows",
                  "# whichever scene is active (even if you changed it in the Hue app).",
                  "- name: \(shortName) - next scene", "  when: { pico: \(pico), button: raise, gesture: tap }",
                  "  then:", "    - action: cycle_scenes", "      room: \(q("<hue room>"))", "      direction: next",
                  "      # scenes: [Read, Relax, Energize]   # optional: sets the order; default is every scene in the room, A-Z", "",
                  "- name: \(shortName) - previous scene", "  when: { pico: \(pico), button: lower, gesture: tap }",
                  "  then:", "    - action: cycle_scenes", "      room: \(q("<hue room>"))", "      direction: previous", ""]
        }
        if has.contains("favorite") {
            o += ["# The middle button puts the room back to neutral white at full brightness.",
                  "- name: \(shortName) - reset to neutral white", "  when: { pico: \(pico), button: favorite, gesture: tap }",
                  "  then:", "    - action: light", "      room: \(q("<hue room>"))", "      on: true", "      brightness: 100",
                  "      color_temp_kelvin: 3655", ""]
        }
        o.append("# ---- More ideas (copy and adjust) ----")
        if has.contains("on") {
            o += ["# Double-tap 'on' to jump straight to one scene:",
                  "- name: \(shortName) - on double-tap = a specific scene", "  when: { pico: \(pico), button: on, gesture: double_tap }",
                  "  then:", "    - action: scene", "      room: \(q("<hue room>"))", "      name: \(q("<scene>"))", ""]
        }
        if has.contains("raise") {
            o += ["# Hold 'raise' to brighten smoothly until you let go (tap above still changes scene):",
                  "- name: \(shortName) - brighter while held", "  when: { pico: \(pico), button: raise, gesture: hold }",
                  "  then:", "    - action: dim", "      room: \(q("<hue room>"))", "      direction: up", "      step: 10",
                  "      repeat_while_held: true", ""]
        }
        if has.contains("lower") {
            o += ["- name: \(shortName) - dimmer while held", "  when: { pico: \(pico), button: lower, gesture: hold }",
                  "  then:", "    - action: dim", "      room: \(q("<hue room>"))", "      direction: down", "      step: 10",
                  "      repeat_while_held: true", ""]
        }
        if has.contains("off") {
            o += ["# Hold 'off' for a slow 5-second fade out:",
                  "- name: \(shortName) - slow fade off", "  when: { pico: \(pico), button: off, gesture: hold }",
                  "  then:", "    - action: light", "      room: \(q("<hue room>"))", "      on: false", "      transition_ms: 5000"]
        }
        if buttons.isEmpty || !(has.contains("on") || has.contains("off") || has.contains("raise")) {
            let b = buttons.first ?? "button_1"
            o += ["- name: \(shortName) - \(b)", "  when: { pico: \(pico), button: \(b), gesture: tap }",
                  "  then:", "    - action: scene", "      room: \(q("<hue room>"))", "      name: \(q("<scene>"))"]
        }
        while o.last == "" { o.removeLast() }
        return lines(o)
    }

    // MARK: Lutron

    static func lutronEntries(_ inv: LutronInventory) -> [CatalogEntry] {
        var out: [CatalogEntry] = []
        for d in inv.picos.sorted(by: { $0.fullName < $1.fullName }) {
            let buttons = inv.buttons.filter { $0.deviceHref == d.href }.sorted { $0.number < $1.number }
            let names = buttons.map { LutronInventory.buttonName(number: $0.number) }
            var provides = buttons.map { b in
                "button “\(LutronInventory.buttonName(number: b.number))” (number \(b.number)): press, release, tap, double_tap, hold, hold_release"
            }
            provides.append("tap = quick press · double_tap = two quick presses · hold = held past hold_ms · press/release = raw down/up")
            out.append(CatalogEntry(
                id: "lutron:\(d.href)", system: .lutron, kind: "Remote", name: d.fullName, model: [d.type, d.model].filter { !$0.isEmpty }.joined(separator: " "),
                provides: provides, accepts: ["(an input device — it triggers rules; HouseBridge doesn't send commands to it)"],
                details: ["\(buttons.count) buttons", "also matches as “\(d.name)”", "a button can use different rules for tap, double_tap and hold"],
                snippet: picoSnippet(shortName: d.fullName, fullName: d.fullName, buttons: names), hint: d.area.isEmpty ? d.fullName : d.area))
        }
        for d in inv.switches.sorted(by: { $0.fullName < $1.fullName }) {
            let isDimmer = d.type.localizedCaseInsensitiveContains("dimmer")
            let n = q(d.fullName)
            out.append(CatalogEntry(
                id: "lutron:\(d.href)", system: .lutron, kind: isDimmer ? "Wired dimmer" : "Wired switch", name: d.fullName,
                model: [d.type, d.model].filter { !$0.isEmpty }.joined(separator: " "),
                provides: ["power on / off (when its state changes — physical presses aren't reported separately)"],
                accepts: ["(HouseBridge reads its state; it doesn't switch it)"],
                details: ["Hue bulbs wired to a switch that is turned off lose power — use it as a trigger only if the load is something else."],
                snippet: lines([
                    "# \(d.fullName) is a trigger: react when it is switched.",
                    "- name: \(d.name) on = movie scene", "  when: { switch: \(n), state: on }",
                    "  then:", "    - action: scene", "      room: \(q("<hue room>"))", "      name: \(q("<scene>"))", "",
                    "- name: \(d.name) off = everything in the room off", "  when: { switch: \(n), state: off }",
                    "  then:", "    - action: light", "      room: \(q("<hue room>"))", "      on: false", "      transition_ms: 2000", "",
                    "# Just record that it happened (useful while testing):",
                    "- name: \(d.name) logger", "  when: { switch: \(n), state: on }",
                    "  then:", "    - action: log", "      message: \(q("\(d.fullName) turned on"))"]),
                hint: d.area.isEmpty ? d.fullName : d.area))
        }
        return out
    }

    // MARK: Hue

    static func hueEntries(_ inv: HueInventory) -> [CatalogEntry] {
        var out: [CatalogEntry] = []
        let roomNames = Set(inv.rooms.map(\.name))

        for l in inv.lights.sorted(by: { $0.name < $1.name }) {
            let dimmable = l.details.contains { $0.hasPrefix("brightness") }
            let ctText = l.details.first { $0.hasPrefix("color temperature") }
            let hasColor = l.details.contains("full color")
            var accepts = ["action: light — on / off"]
            if dimmable { accepts.append("action: light — brightness: 0–100") }
            if let ctText { accepts.append("action: light — color_temp_kelvin: " + ctText.replacingOccurrences(of: "color temperature ", with: "")) }
            if hasColor { accepts.append("action: light — color: \"#RRGGBB\"") }
            accepts += ["action: toggle", "action: dim — step brightness up/down (with repeat_while_held on a hold gesture)", "transition_ms — fade time on any light action"]
            let n = q(l.name)
            var o: [String] = [
                "# Turn \(l.name) on" + (dimmable ? " at full brightness" : "") + (ctText != nil ? " in warm white" : ""),
                "- name: \(l.name) on", "  when: { pico: \(q("<remote>")), button: on, gesture: tap }",
                "  then:", "    - action: light", "      light: \(n)", "      on: true"]
            if dimmable { o.append("      brightness: 100") }
            if ctText != nil { o.append("      color_temp_kelvin: 2700") }
            o += ["", "# Press once to flip it:",
                  "- name: \(l.name) toggle", "  when: { pico: \(q("<remote>")), button: favorite, gesture: tap }",
                  "  then:", "    - action: toggle", "      light: \(n)"]
            if dimmable {
                o += ["", "# Hold to brighten smoothly:",
                      "- name: \(l.name) brighter while held", "  when: { pico: \(q("<remote>")), button: raise, gesture: hold }",
                      "  then:", "    - action: dim", "      light: \(n)", "      direction: up", "      step: 10", "      repeat_while_held: true",
                      "", "# Hold to slowly fade out:",
                      "- name: \(l.name) fade off", "  when: { pico: \(q("<remote>")), button: off, gesture: hold }",
                      "  then:", "    - action: light", "      light: \(n)", "      on: false", "      transition_ms: 5000"]
            }
            if hasColor {
                o += ["", "# Jump to a color on double-tap:",
                      "- name: \(l.name) amber", "  when: { pico: \(q("<remote>")), button: on, gesture: double_tap }",
                      "  then:", "    - action: light", "      light: \(n)", "      color: \(q("#FF8800"))", "      brightness: 60"]
            }
            out.append(CatalogEntry(id: "hue:light:\(l.id)", system: .hue, kind: "Light", name: l.name, model: l.product,
                                    provides: [], accepts: accepts, details: l.details, snippet: lines(o)))
        }

        for (kind, items, key) in [("Room", inv.rooms, "room"), ("Zone", inv.zones, "zone")] {
            for g in items.sorted(by: { $0.name < $1.name }) {
                let scenes = inv.scenes.filter { $0.groupName == g.name }.map(\.name).sorted()
                let n = q(g.name)
                var o: [String] = []
                if scenes.count >= 2 {
                    let list = scenes.prefix(6).map { q($0) }.joined(separator: ", ")
                    o += ["# Step through \(g.name)'s scenes with a remote's raise / lower buttons.",
                          "# Leave out 'scenes:' to cycle through all \(scenes.count) in A-Z order.",
                          "- name: \(g.name) next scene", "  when: { pico: \(q("<remote>")), button: raise, gesture: tap }",
                          "  then:", "    - action: cycle_scenes", "      \(key): \(n)", "      scenes: [\(list)]", "      direction: next", "",
                          "- name: \(g.name) previous scene", "  when: { pico: \(q("<remote>")), button: lower, gesture: tap }",
                          "  then:", "    - action: cycle_scenes", "      \(key): \(n)", "      scenes: [\(list)]", "      direction: previous", ""]
                } else {
                    o += ["# (Create two or more scenes for \(g.name) in the Hue app to use cycle_scenes.)", ""]
                }
                if let first = scenes.first {
                    o += ["# Recall one scene at a set brightness:",
                          "- name: \(g.name) - \(first)", "  when: { pico: \(q("<remote>")), button: favorite, gesture: tap }",
                          "  then:", "    - action: scene", "      \(key): \(n)", "      name: \(q(first))", "      brightness: 80", ""]
                }
                o += ["# Whole \(key) on / off, with the neutral-white reset on the middle button:",
                      "- name: \(g.name) neutral white", "  when: { pico: \(q("<remote>")), button: favorite, gesture: double_tap }",
                      "  then:", "    - action: light", "      \(key): \(n)", "      on: true", "      brightness: 100", "      color_temp_kelvin: 3655", "",
                      "# Hold raise / lower to dim the whole \(key):",
                      "- name: \(g.name) brighter while held", "  when: { pico: \(q("<remote>")), button: raise, gesture: hold }",
                      "  then:", "    - action: dim", "      \(key): \(n)", "      direction: up", "      step: 10", "      repeat_while_held: true", "",
                      "- name: \(g.name) fade off", "  when: { pico: \(q("<remote>")), button: off, gesture: hold }",
                      "  then:", "    - action: light", "      \(key): \(n)", "      on: false", "      transition_ms: 5000"]
                out.append(CatalogEntry(
                    id: "hue:\(key):\(g.id)", system: .hue, kind: kind, name: g.name, model: "",
                    provides: [],
                    accepts: ["action: light / toggle / dim on all its lights at once", "action: scene — recall one of its scenes",
                              "action: cycle_scenes — step through its \(scenes.count) scene(s), next or previous"],
                    details: g.details + (scenes.isEmpty ? ["no scenes yet"] : ["scenes: " + scenes.joined(separator: ", ")]),
                    snippet: lines(o)))
            }
        }

        for s in inv.scenes.sorted(by: { ($0.groupName ?? "", $0.name) < ($1.groupName ?? "", $1.name) }) {
            let group = s.groupName ?? "<hue room>"
            let key = (s.groupName.map { roomNames.contains($0) } ?? true) ? "room" : "zone"
            out.append(CatalogEntry(
                id: "hue:scene:\(s.id)", system: .hue, kind: "Scene", name: s.name, model: s.groupName ?? "",
                provides: [], accepts: ["action: scene — recall it (optional brightness: 0–100)", "also reachable with action: cycle_scenes for its \(key)"],
                details: s.groupName.map { ["belongs to “\($0)”"] } ?? [],
                snippet: lines([
                    "# Recall “\(s.name)” in \(group) when a remote button is double-tapped:",
                    "- name: \(group) - \(s.name)", "  when: { pico: \(q("<remote>")), button: on, gesture: double_tap }",
                    "  then:", "    - action: scene", "      \(key): \(q(group))", "      name: \(q(s.name))", "",
                    "# Same scene, dimmed to 30%, when a camera sees someone at night:",
                    "- name: \(group) - \(s.name) at night", "  when: { unifi: \(q("<camera>")), event: person, state: start }",
                    "  between: [\"22:00\", \"06:00\"]", "  cooldown_seconds: 60",
                    "  then:", "    - action: scene", "      \(key): \(q(group))", "      name: \(q(s.name))", "      brightness: 30"])))
        }
        return out
    }

    // MARK: UniFi

    static func unifiEntries(_ inv: ProtectInventory) -> [CatalogEntry] {
        inv.items.sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }.map { i in
            let inputs = i.provides
            let n = q(i.name)
            var provides = inputs.map { input -> String in
                switch input {
                case "contact": return "contact — state: open / closed"
                case "ring": return "ring — doorbell pressed (state: start)"
                case "leak", "tamper", "alarm": return "\(input) — state: start (triggered), end (cleared)"
                default: return "\(input) — state: start (detected), end (stopped), clear (quiet for clear_after_seconds)"
                }
            }
            if provides.isEmpty { provides = ["motion"] }
            var o: [String] = []
            if i.kind == "camera" {
                let smart = inputs.first { ["person", "vehicle", "animal", "package"].contains($0) } ?? "motion"
                o += ["# Turn the lights on when \(smart == "motion" ? "there is motion" : "a \(smart) is seen") (only in the evening/night),",
                      "# and off again once it has been quiet for clear_after_seconds (set under unifi: in this file).",
                      "- name: \(i.name) - \(smart) detected", "  when: { unifi: \(n), event: \(smart), state: start }",
                      "  between: [\"18:00\", \"06:00\"]", "  cooldown_seconds: 30",
                      "  then:", "    - action: light", "      room: \(q("<hue room>"))", "      on: true", "      brightness: 100", "",
                      "- name: \(i.name) - \(smart) gone", "  when: { unifi: \(n), event: \(smart), state: clear }",
                      "  then:", "    - action: light", "      room: \(q("<hue room>"))", "      on: false", "      transition_ms: 4000"]
                if inputs.contains("vehicle") && smart != "vehicle" {
                    o += ["", "# A vehicle (not a person) lights the driveway at full brightness:",
                          "- name: \(i.name) - vehicle", "  when: { unifi: \(n), event: vehicle, state: start }",
                          "  then:", "    - action: light", "      zone: \(q("<hue zone>"))", "      on: true", "      brightness: 100"]
                }
                if inputs.contains("ring") {
                    o += ["", "# Doorbell: bring the hall to full brightness when it's pressed:",
                          "- name: \(i.name) - doorbell", "  when: { unifi: \(n), event: ring }",
                          "  then:", "    - action: light", "      room: \(q("<hue room>"))", "      on: true", "      brightness: 100", "      color_temp_kelvin: 3655"]
                }
                o += ["", "# Not sure which camera does what? Match any camera with \"*\":",
                      "- name: any camera sees a person", "  when: { unifi: \"*\", event: person, state: start }",
                      "  then:", "    - action: log", "      message: \"a camera saw a person\""]
            } else {
                if inputs.contains("contact") {
                    o += ["# Door/window sensor: light on when opened, off again shortly after it closes.",
                          "- name: \(i.name) opened", "  when: { unifi: \(n), event: contact, state: open }",
                          "  then:", "    - action: light", "      room: \(q("<hue room>"))", "      on: true", "      brightness: 80", "",
                          "- name: \(i.name) closed", "  when: { unifi: \(n), event: contact, state: closed }",
                          "  then:", "    - action: wait", "      seconds: 30", "    - action: light", "      room: \(q("<hue room>"))", "      on: false"]
                }
                if inputs.contains("motion") {
                    o += (o.isEmpty ? [] : [""]) + ["# Motion from this sensor:",
                          "- name: \(i.name) motion", "  when: { unifi: \(n), event: motion, state: start }",
                          "  between: [\"18:00\", \"06:00\"]", "  then:", "    - action: light", "      room: \(q("<hue room>"))", "      on: true", "      brightness: 40"]
                }
                if inputs.contains("leak") {
                    o += (o.isEmpty ? [] : [""]) + ["# Leak: turn a light red so you notice.",
                          "- name: \(i.name) leak", "  when: { unifi: \(n), event: leak, state: start }",
                          "  then:", "    - action: light", "      room: \(q("<hue room>"))", "      on: true", "      color: \(q("#FF0000"))", "      brightness: 100"]
                }
                if o.isEmpty {
                    o = ["- name: \(i.name)", "  when: { unifi: \(n), event: \(inputs.first ?? "motion"), state: start }",
                         "  then:", "    - action: log", "      message: \(q("\(i.name) triggered"))"]
                }
            }
            return CatalogEntry(
                id: "unifi:\(i.id)", system: .unifi, kind: i.kind == "camera" ? "Camera" : "Sensor", name: i.name, model: i.model,
                provides: provides, accepts: ["(an input device — it triggers rules)"], details: i.details,
                snippet: lines(o), hint: i.name)
        }
    }
}

/// Matches a device's name ("Master Bedroom Pico", "Front Camera") to a Hue room by comparing the meaningful words.
enum NameMatcher {
    private static let noise: Set<String> = ["room", "the", "pico", "remote", "switch", "dimmer", "camera", "cam", "sensor",
                                             "g6", "g5", "pro", "dome", "ptz", "light", "lights", "lamp", "and", "of"]

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !noise.contains($0) })
    }

    /// The single best candidate, or nil when nothing is clearly better than the rest.
    static func bestMatch(for name: String, in candidates: [String]) -> String? {
        let target = words(name)
        guard !target.isEmpty else { return nil }
        let scored = candidates.map { c -> (String, Double) in
            let w = words(c)
            guard !w.isEmpty else { return (c, 0) }
            return (c, Double(target.intersection(w).count) / Double(target.union(w).count))
        }.sorted { $0.1 > $1.1 }
        guard let top = scored.first, top.1 >= 0.34 else { return nil }
        if scored.count > 1, scored[1].1 == top.1 { return nil }   // ambiguous
        return top.0
    }
}

import Foundation

/// Which Protect stream a viewer asking for `width` pixels across should get: the smallest enabled one that is wide
/// enough (the cheapest that still looks right), else the biggest there is.
enum CameraChannels {
    static func choose(_ channels: [ProtectInventory.Channel], width: Int) -> ProtectInventory.Channel? {
        let enabled = channels.filter { $0.rtspEnabled && $0.rtspAlias != nil }.sorted { $0.width < $1.width }
        return enabled.first { $0.width >= width } ?? enabled.last
    }
}

/// `housebridgectl camera-test`: exercises what live view depends on (the Protect login, snapshots, the RTSP stream,
/// the video and audio the camera sends) from the command line, with no HomeKit in the way.
public enum CameraDiagnostics {
    public static func run(unifi: UnifiConfig, hosts: KnownHosts, camera: String?, seconds: Double, say: @escaping (String) -> Void) async {
        let protect = ProtectClient(config: unifi, hosts: hosts)
        let inventory: ProtectInventory
        do { inventory = try await protect.discover(); say("Protect login and device list: OK") }
        catch { say("Protect login and device list: FAILED — \(describeError(error))"); return }

        let wanted = camera?.trimmingCharacters(in: .whitespaces) ?? ""
        let cameras = inventory.items.filter { $0.kind == "camera" && (wanted.isEmpty || wanted == "*" || $0.name.localizedCaseInsensitiveContains(wanted)) }
        guard !cameras.isEmpty else {
            say("No camera matches ‘\(wanted)’. Cameras: " + inventory.items.filter { $0.kind == "camera" }.map(\.name).joined(separator: ", "))
            return
        }
        for item in cameras {
            say("\n== \(item.name) (\(item.model)) ==")
            if item.channels.isEmpty { say("  no stream information from Protect") }
            for c in item.channels {
                say("  stream \(c.width)x\(c.height) \(c.fps) fps \(c.bitrate / 1000) kbps — RTSP \(c.rtspEnabled ? "on" : "OFF")")
            }
            do {
                let jpeg = try await protect.snapshot(cameraID: item.id, width: 1280, height: 720)
                say("  snapshot: OK, \(jpeg.count) bytes\(jpeg.starts(with: [0xFF, 0xD8]) ? "" : " (not a JPEG!)")")
            } catch { say("  snapshot: FAILED — \(describeError(error))") }

            guard let channel = CameraChannels.choose(item.channels, width: 1280), let alias = channel.rtspAlias else {
                say("  live view: NOT POSSIBLE — no RTSP stream is enabled. In UniFi Protect open this camera's settings, Advanced, Share Livestream, and enable RTSPS on a stream")
                continue
            }
            say("  live view would use the \(channel.width)x\(channel.height) stream")
            await probe(host: unifi.host, alias: alias, hosts: hosts, seconds: seconds, say: say)
        }
    }

    private static func probe(host: String, alias: String, hosts: KnownHosts, seconds: Double, say: @escaping (String) -> Void) async {
        let queue = DispatchQueue(label: "housebridge.camera-test")
        let transport = NWRTSPTransport(host: host, port: 7441, tls: true, hosts: hosts, queue: queue)
        let client = RTSPClient(url: URL(string: "rtsps://\(host):7441/\(alias)")!, transport: transport, queue: queue)
        final class Tally: @unchecked Sendable {
            var video = 0, audio = 0, frames = 0, keyFrames = 0, opus = 0, audioFrames = 0
            var sps: Data?
            var depacketizer = H264Depacketizer()
            var aac: AACDepacketizer?
            var transcoder: AudioTranscoder?
            var closedWith: String?
        }
        let tally = Tally()
        client.onPacket = { media, packet in
            if media.kind == "video" {
                tally.video += 1
                for unit in tally.depacketizer.push(packet) {
                    tally.frames += 1
                    if unit.isKeyFrame { tally.keyFrames += 1 }
                    if tally.sps == nil { tally.sps = unit.nals.first { ($0.first ?? 0) & 0x1F == 7 } }
                }
            } else {
                tally.audio += 1
                guard let aac = tally.aac, let transcoder = tally.transcoder else { return }
                for frame in aac.frames(in: packet.payload) { tally.audioFrames += 1; tally.opus += transcoder.opusPackets(forAAC: frame).count }
            }
        }
        client.onClose = { error in tally.closedWith = error.map { "\($0)" } ?? "closed" }
        do {
            let chosen = try await client.play { offered in
                say("  RTSP: OK, the camera offers " + offered.map { "\($0.kind) \($0.codec)" }.joined(separator: ", "))
                return offered.filter { ($0.kind == "video" && $0.codec == "H264") || ($0.kind == "audio" && $0.codec == "MPEG4-GENERIC") }
            }
            if let v = chosen.first(where: { $0.kind == "video" }) {
                let sets = SDP.parameterSets(v.fmtp)
                if let sps = sets.sps, sps.count > 3 { say("  video: H.264 profile \(profile(Int(sps[1]))), level \(Double(sps[3]) / 10)") }
            } else { say("  video: FAILED — the camera does not offer H.264 (HomeKit live view here needs H.264, not H.265)") }
            if let a = chosen.first(where: { $0.kind == "audio" }) {
                tally.aac = AACDepacketizer(fmtp: a.fmtp)
                if let config = AudioTranscoder.configBytes(a.fmtp["config"]) {
                    tally.transcoder = AudioTranscoder(config: config, sampleRate: Double(a.clockRate), channels: a.channels)
                }
                say("  audio: AAC \(a.clockRate) Hz, \(a.channels) ch; converter \(tally.transcoder == nil ? "UNAVAILABLE (video only)" : "ok")")
            } else { say("  audio: none offered (video only)") }
            try? await Task.sleep(for: .seconds(seconds))
            say("  after \(Int(seconds)) s: \(tally.video) video packets, \(tally.frames) frames (\(tally.keyFrames) key frames); \(tally.audio) audio packets → \(tally.opus) Opus packets")
            if tally.video == 0 { say("  video: FAILED — connected but no video arrived") }
            else if tally.keyFrames == 0 { say("  video: WARNING — no key frame in \(Int(seconds)) s; viewers wait for one, so use a longer --seconds") }
            else { say("  stream: OK") }
        } catch {
            say("  RTSP: FAILED — \(error)")
            say("  (if this is a certificate error, the pinned certificate for \(host):7441 may have changed: remove that entry from the known-hosts file in the HouseBridge folder and try again)")
        }
        client.stop()
        if let closed = tally.closedWith, closed != "closed" { say("  connection ended: \(closed)") }
    }

    private static func profile(_ idc: Int) -> String {
        switch idc { case 66: "Baseline"; case 77: "Main"; case 88: "Extended"; case 100: "High"; case 110: "High 10"; default: "\(idc)" }
    }
}

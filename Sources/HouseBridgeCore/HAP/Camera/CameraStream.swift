import Foundation
import Network
import Security

// MARK: - Stream TLVs

/// What a controller asks for in a SetupEndpoints write: where to send media, and the SRTP keys to protect it with.
struct StreamSetup {
    var sessionID: Data
    var address: String
    var ipv6: Bool
    var videoPort: Int
    var audioPort: Int
    var videoKey: Data, videoSalt: Data
    var audioKey: Data, audioSalt: Data
}

/// What a controller picked in a SelectedRTPStreamConfiguration write.
struct StreamSelection {
    enum Command: Int { case end = 0, start = 1, suspend = 2, resume = 3, reconfigure = 4 }
    struct Video { var payloadType: UInt8; var ssrc: UInt32; var maxBitrateKbps: Int; var mtu: Int; var width: Int; var height: Int; var fps: Int }
    struct Audio { var payloadType: UInt8; var ssrc: UInt32; var codec: Int; var sampleRateCode: Int; var packetTimeMs: Int }
    var sessionID: Data
    var command: Command
    var video: Video?
    var audio: Audio?
}

enum CameraStreamTLV {
    private static func le(_ data: Data?, bytes: Int) -> Int? {
        guard let data, data.count == bytes else { return nil }
        return data.enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
    }
    private static func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    private static func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: v >> UInt32(8 * $0)) }) }

    static func parseSetup(_ data: Data) -> StreamSetup? {
        guard let top = TLV8.dictionary(data), let session = top[1], session.count == 16,
              let addressTLV = top[3].flatMap(TLV8.dictionary), let hostData = addressTLV[2],
              let video = top[4].flatMap(TLV8.dictionary), let audio = top[5].flatMap(TLV8.dictionary),
              let vp = le(addressTLV[3], bytes: 2), let ap = le(addressTLV[4], bytes: 2),
              let vk = video[2], let vs = video[3], let ak = audio[2], let asl = audio[3],
              vk.count == 16, vs.count == 14, ak.count == 16, asl.count == 14,
              (1...65535).contains(vp), (1...65535).contains(ap) else { return nil }
        return StreamSetup(sessionID: session, address: String(decoding: hostData, as: UTF8.self), ipv6: addressTLV[1] == Data([1]),
                           videoPort: vp, audioPort: ap, videoKey: vk, videoSalt: vs, audioKey: ak, audioSalt: asl)
    }

    /// The accessory's answer: where to send controller RTCP, its SRTP parameters (the controller's own are echoed, which
    /// is what controllers expect when only the accessory sends media), and the SSRCs it will use.
    static func setupResponse(_ setup: StreamSetup, address: String, ipv6: Bool, videoPort: Int, audioPort: Int,
                              videoSSRC: UInt32, audioSSRC: UInt32) -> Data {
        let addressTLV = HAPCamera.tlv([(1, Data([ipv6 ? 1 : 0])), (2, Data(address.utf8)), (3, le16(videoPort)), (4, le16(audioPort))])
        func srtp(_ key: Data, _ salt: Data) -> Data { HAPCamera.tlv([(1, Data([0])), (2, key), (3, salt)]) }
        return HAPCamera.tlv([(1, setup.sessionID), (2, Data([0])), (3, addressTLV),
                              (4, srtp(setup.videoKey, setup.videoSalt)), (5, srtp(setup.audioKey, setup.audioSalt)),
                              (6, le32(videoSSRC)), (7, le32(audioSSRC))])
    }

    static func failureResponse(sessionID: Data, busy: Bool) -> Data { HAPCamera.tlv([(1, sessionID), (2, Data([busy ? 1 : 2]))]) }

    static func parseSelection(_ data: Data) -> StreamSelection? {
        guard let top = TLV8.dictionary(data), let control = top[1].flatMap(TLV8.dictionary), let id = control[1], id.count == 16,
              let raw = control[2]?.first, let command = StreamSelection.Command(rawValue: Int(raw)) else { return nil }
        var selection = StreamSelection(sessionID: id, command: command)
        if let v = top[2].flatMap(TLV8.dictionary), let attributes = v[3].flatMap(TLV8.dictionary), let rtp = v[4].flatMap(TLV8.dictionary),
           let pt = rtp[1]?.first, let ssrc = le(rtp[2], bytes: 4) {
            selection.video = .init(payloadType: pt, ssrc: UInt32(ssrc), maxBitrateKbps: le(rtp[3], bytes: 2) ?? 0, mtu: le(rtp[5], bytes: 2) ?? 1378,
                                    width: le(attributes[1], bytes: 2) ?? 0, height: le(attributes[2], bytes: 2) ?? 0, fps: Int(attributes[3]?.first ?? 30))
        }
        if let a = top[3].flatMap(TLV8.dictionary), let params = a[2].flatMap(TLV8.dictionary), let rtp = a[3].flatMap(TLV8.dictionary),
           let pt = rtp[1]?.first, let ssrc = le(rtp[2], bytes: 4), let codec = a[1]?.first {
            selection.audio = .init(payloadType: pt, ssrc: UInt32(ssrc), codec: Int(codec), sampleRateCode: Int(params[3]?.first ?? 2),
                                    packetTimeMs: Int(params[4]?.first ?? 20))
        }
        return selection
    }
}

// MARK: - Media sockets

/// Where encrypted media goes: a UDP flow to the controller from a fixed local port (controllers answer to it).
protocol MediaSocket: AnyObject {
    func send(_ data: Data)
    func close()
}

final class NWMediaSocket: MediaSocket, @unchecked Sendable {
    private let connection: NWConnection
    init(host: String, port: Int, localPort: Int, queue: DispatchQueue) {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        if let local = NWEndpoint.Port(rawValue: UInt16(clamping: localPort)) { parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: local) }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 1, using: parameters)
        connection.start(queue: queue)
        drain()
    }
    /// Controllers send RTCP back; nothing needs it, but unread datagrams would pile up.
    private func drain() {
        connection.receiveMessage { [weak self] _, _, _, error in if error == nil { self?.drain() } }
    }
    func send(_ data: Data) { connection.send(content: data, completion: .contentProcessed { _ in }) }
    func close() { connection.cancel() }
}

// MARK: - Manager

/// Runs HomeKit live-view sessions: answers SetupEndpoints, and on Start pulls the camera's RTSP stream and forwards it,
/// re-packetized and SRTP-encrypted, to the viewer. Not thread-safe: every call and every callback happens on `queue`.
final class CameraStreamManager: @unchecked Sendable {
    /// Connects to a camera's stream for a viewer asking for `width` pixels across, or nil when it has none to offer.
    typealias RTSPFactory = (_ cameraID: String, _ width: Int, _ maxBitrateKbps: Int) -> RTSPClient?
    typealias SocketFactory = (_ host: String, _ port: Int, _ localPort: Int) -> MediaSocket

    static let maxSessions = 8

    private let queue: DispatchQueue
    private let makeRTSP: RTSPFactory
    private let makeSocket: SocketFactory
    private let log: (String, LogLevel) -> Void
    /// A camera started or stopped being watched.
    var onActivity: (_ cameraID: String, _ active: Bool) -> Void = { _, _ in }
    private var sessions: [Data: Session] = [:]
    private var usedPorts: Set<Int> = []

    init(queue: DispatchQueue, makeRTSP: @escaping RTSPFactory, makeSocket: @escaping SocketFactory, log: @escaping (String, LogLevel) -> Void) {
        self.queue = queue; self.makeRTSP = makeRTSP; self.makeSocket = makeSocket; self.log = log
    }

    var activeSessions: Int { sessions.count }

    final class Session {
        let setup: StreamSetup
        let cameraID: String
        let connection: ObjectIdentifier
        let localVideoPort: Int, localAudioPort: Int
        let videoSSRC: UInt32, audioSSRC: UInt32
        var started = false
        var client: RTSPClient?
        var videoSocket: MediaSocket?, audioSocket: MediaSocket?
        var videoSRTP: SRTPSender?, audioSRTP: SRTPSender?
        var videoPacketizer: H264Packetizer?
        var depacketizer = H264Depacketizer()
        var sawKeyFrame = false
        var aac: AACDepacketizer?
        var transcoder: AudioTranscoder?
        var audioPayloadType: UInt8 = 110
        var audioSequence = UInt16.random(in: 0...0xFFFF)
        var audioTimestamp = UInt32.random(in: 0...0xFFFF_FFFF)
        var counters = (videoPackets: 0, videoBytes: 0, audioPackets: 0, audioBytes: 0)
        var lastVideoTimestamp: UInt32 = 0
        var timer: DispatchSourceTimer?
        var setupTimeout: DispatchWorkItem?
        init(setup: StreamSetup, cameraID: String, connection: ObjectIdentifier, ports: (Int, Int), ssrcs: (UInt32, UInt32)) {
            self.setup = setup; self.cameraID = cameraID; self.connection = connection
            localVideoPort = ports.0; localAudioPort = ports.1; videoSSRC = ssrcs.0; audioSSRC = ssrcs.1
        }
    }

    // MARK: SetupEndpoints

    /// Answers a SetupEndpoints write (the TLV to store as the characteristic's value).
    func setup(cameraID: String, request: Data, connection: ObjectIdentifier, localAddress: String?) -> Data {
        guard let setup = CameraStreamTLV.parseSetup(request) else {
            log("camera \(cameraID): unreadable stream setup request", .warning)
            return CameraStreamTLV.failureResponse(sessionID: TLV8.dictionary(request)?[1] ?? Data(count: 16), busy: false)
        }
        guard let localAddress else {
            log("camera \(cameraID): cannot tell which address the viewer reaches us on", .warning)
            return CameraStreamTLV.failureResponse(sessionID: setup.sessionID, busy: false)
        }
        guard sessions.count < Self.maxSessions else { return CameraStreamTLV.failureResponse(sessionID: setup.sessionID, busy: true) }
        endSession(setup.sessionID)   // a controller reusing an id replaces the old session
        let ports = (allocatePort(), allocatePort())
        let session = Session(setup: setup, cameraID: cameraID, connection: connection, ports: ports,
                              ssrcs: (UInt32.random(in: 1...UInt32.max), UInt32.random(in: 1...UInt32.max)))
        sessions[setup.sessionID] = session
        // A viewer that asks and never starts must not hold ports forever.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let s = self.sessions[setup.sessionID], !s.started else { return }
            self.log("camera \(cameraID): live view was set up but never started", .warning)
            self.endSession(setup.sessionID)
        }
        session.setupTimeout = timeout
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        let v6 = localAddress.contains(":")
        return CameraStreamTLV.setupResponse(setup, address: localAddress, ipv6: v6, videoPort: ports.0, audioPort: ports.1,
                                             videoSSRC: session.videoSSRC, audioSSRC: session.audioSSRC)
    }

    private func allocatePort() -> Int {
        for _ in 0..<200 {
            let port = Int.random(in: 50_000..<60_000)
            if usedPorts.insert(port).inserted { return port }
        }
        return Int.random(in: 60_000..<65_000)
    }

    // MARK: Selected configuration

    func select(cameraID: String, request: Data) {
        guard let selection = CameraStreamTLV.parseSelection(request) else { log("camera \(cameraID): unreadable stream selection", .warning); return }
        switch selection.command {
        case .start:
            guard let session = sessions[selection.sessionID], !session.started else { return }
            session.started = true
            session.setupTimeout?.cancel()
            start(session, selection)
        case .end:
            endSession(selection.sessionID)
        case .suspend, .resume, .reconfigure:
            break   // the stream keeps going at the camera's own quality
        }
    }

    func connectionClosed(_ connection: ObjectIdentifier) {
        for (id, session) in sessions where session.connection == connection { endSession(id) }
    }

    func stopAll() { for id in Array(sessions.keys) { endSession(id) } }

    // MARK: Streaming

    private func start(_ session: Session, _ selection: StreamSelection) {
        guard let video = selection.video else { log("camera \(session.cameraID): the viewer chose no video stream", .warning); endSession(selection.sessionID); return }
        guard let client = makeRTSP(session.cameraID, video.width, video.maxBitrateKbps) else {
            endSession(selection.sessionID); return
        }
        session.client = client
        session.videoSRTP = SRTPSender(masterKey: session.setup.videoKey, masterSalt: session.setup.videoSalt)
        session.audioSRTP = SRTPSender(masterKey: session.setup.audioKey, masterSalt: session.setup.audioSalt)
        session.videoSocket = makeSocket(session.setup.address, session.setup.videoPort, session.localVideoPort)
        session.audioSocket = makeSocket(session.setup.address, session.setup.audioPort, session.localAudioPort)
        let wantsAudio = selection.audio.map { $0.codec == 3 && $0.sampleRateCode == 2 } ?? false   // Opus at 24 kHz is all we offer
        let audio = selection.audio
        let id = selection.sessionID
        let cameraID = session.cameraID
        log("camera \(cameraID): live view started for \(session.setup.address) (\(video.width)x\(video.height), up to \(video.maxBitrateKbps) kbps)", .info)
        onActivity(cameraID, true)

        client.onPacket = { [weak self, weak session] media, packet in
            guard let self, let session, self.sessions[id] === session else { return }
            self.deliver(media, packet, session)
        }
        client.onClose = { [weak self] error in
            guard let self, self.sessions[id] != nil else { return }
            self.log("camera \(cameraID): the camera stream ended\(error.map { ": \($0)" } ?? "")", .warning)
            self.endSession(id)
        }
        Task { [weak self] in
            do {
                let chosen = try await client.play { offered in
                    var out: [SDPMedia] = []
                    if let v = offered.first(where: { $0.kind == "video" && $0.codec == "H264" }) { out.append(v) }
                    if wantsAudio, let a = offered.first(where: { $0.kind == "audio" && $0.codec == "MPEG4-GENERIC" }) { out.append(a) }
                    return out
                }
                self?.queue.async { self?.streamsReady(id, chosen, video, audio) }
            } catch {
                self?.queue.async {
                    self?.log("camera \(cameraID): could not open the camera stream: \(error)", .error)
                    self?.endSession(id)
                }
            }
        }
    }

    private func streamsReady(_ id: Data, _ chosen: [SDPMedia], _ video: StreamSelection.Video, _ audio: StreamSelection.Audio?) {
        guard let session = sessions[id] else { return }
        if let v = chosen.first(where: { $0.kind == "video" }) {
            let sets = SDP.parameterSets(v.fmtp)
            session.videoPacketizer = H264Packetizer(payloadType: video.payloadType, ssrc: video.ssrc, mtu: video.mtu, sps: sets.sps, pps: sets.pps)
        }
        if let a = chosen.first(where: { $0.kind == "audio" }), let audio, let config = AudioTranscoder.configBytes(a.fmtp["config"]) {
            session.aac = AACDepacketizer(fmtp: a.fmtp)
            session.transcoder = AudioTranscoder(config: config, sampleRate: Double(a.clockRate), channels: a.channels)
            session.audioPayloadType = audio.payloadType
            if session.transcoder == nil { log("camera \(session.cameraID): this camera's audio cannot be converted; sending video only", .warning) }
        }
        // RTCP sender reports keep the viewer's player in sync and tell it the stream is alive.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 5)
        timer.setEventHandler { [weak self, weak session] in if let self, let session { self.sendReports(session, video.ssrc, audio?.ssrc ?? session.audioSSRC) } }
        timer.resume()
        session.timer = timer
    }

    private func deliver(_ media: SDPMedia, _ packet: RTPPacket, _ session: Session) {
        if media.kind == "video" {
            guard let packetizer = session.videoPacketizer, let srtp = session.videoSRTP, let socket = session.videoSocket else { return }
            for unit in session.depacketizer.push(packet) {
                // A viewer cannot start from the middle of a group of pictures.
                if !session.sawKeyFrame { guard unit.isKeyFrame else { continue }; session.sawKeyFrame = true }
                for out in packetizer.packets(for: unit) {
                    session.lastVideoTimestamp = out.timestamp
                    guard let protected = srtp.protect(rtp: out.data) else { continue }
                    session.counters.videoPackets += 1; session.counters.videoBytes += out.payload.count
                    socket.send(protected)
                }
            }
        } else if media.kind == "audio", let aac = session.aac, let transcoder = session.transcoder, let srtp = session.audioSRTP, let socket = session.audioSocket {
            for frame in aac.frames(in: packet.payload) {
                for opus in transcoder.opusPackets(forAAC: frame) {
                    let out = RTPPacket(marker: false, payloadType: session.audioPayloadType, sequence: session.audioSequence,
                                        timestamp: session.audioTimestamp, ssrc: session.audioSSRC, payload: opus)
                    session.audioSequence &+= 1
                    session.audioTimestamp &+= 960   // 20 ms on Opus's 48 kHz RTP clock
                    guard let protected = srtp.protect(rtp: out.data) else { continue }
                    session.counters.audioPackets += 1; session.counters.audioBytes += opus.count
                    socket.send(protected)
                }
            }
        }
    }

    /// RTCP sender reports (RFC 3550 6.4.1), protected with SRTCP.
    private func sendReports(_ session: Session, _ videoSSRC: UInt32, _ audioSSRC: UInt32) {
        func report(ssrc: UInt32, rtpTimestamp: UInt32, packets: Int, bytes: Int) -> Data {
            let now = Date().timeIntervalSince1970 + 2_208_988_800   // NTP epoch is 1900
            let seconds = UInt32(truncatingIfNeeded: Int(now)), fraction = UInt32(truncatingIfNeeded: Int((now - floor(now)) * 4_294_967_296))
            func be(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> UInt32(24 - 8 * $0)) } }
            return Data([0x80, 200, 0, 6] + be(ssrc) + be(seconds) + be(fraction) + be(rtpTimestamp) + be(UInt32(truncatingIfNeeded: packets)) + be(UInt32(truncatingIfNeeded: bytes)))
        }
        if session.counters.videoPackets > 0,
           let protected = session.videoSRTP?.protect(rtcp: report(ssrc: videoSSRC, rtpTimestamp: session.lastVideoTimestamp,
                                                                  packets: session.counters.videoPackets, bytes: session.counters.videoBytes)) {
            session.videoSocket?.send(protected)
        }
        if session.counters.audioPackets > 0,
           let protected = session.audioSRTP?.protect(rtcp: report(ssrc: audioSSRC, rtpTimestamp: session.audioTimestamp,
                                                                  packets: session.counters.audioPackets, bytes: session.counters.audioBytes)) {
            session.audioSocket?.send(protected)
        }
    }

    func endSession(_ id: Data) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.setupTimeout?.cancel()
        session.timer?.cancel()
        session.client?.onPacket = nil
        session.client?.onClose = nil
        session.client?.stop()
        session.videoSocket?.close(); session.audioSocket?.close()
        usedPorts.remove(session.localVideoPort); usedPorts.remove(session.localAudioPort)
        if session.started {
            log("camera \(session.cameraID): live view ended", .info)
            if !sessions.values.contains(where: { $0.cameraID == session.cameraID && $0.started }) { onActivity(session.cameraID, false) }
        }
    }
}

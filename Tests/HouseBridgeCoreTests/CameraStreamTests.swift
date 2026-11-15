import XCTest
import AVFoundation
@testable import HouseBridgeCore

final class FakeSocket: MediaSocket, @unchecked Sendable {
    let port: Int, localPort: Int, host: String
    private let box = Mutex<[Data]>([])
    private let closedBox = Mutex<Bool>(false)
    init(host: String, port: Int, localPort: Int) { self.host = host; self.port = port; self.localPort = localPort }
    func send(_ data: Data) { box.mutate { $0.append(data) } }
    func close() { closedBox.mutate { $0 = true } }
    var sent: [Data] { box.value }
    var closed: Bool { closedBox.value }
}

final class CameraStreamTests: XCTestCase {
    let queue = DispatchQueue(label: "camera-stream-test")
    let sdp = """
    v=0\r
    m=video 0 RTP/AVP 96\r
    a=control:trackID=0\r
    a=rtpmap:96 H264/90000\r
    a=fmtp:96 packetization-mode=1;sprop-parameter-sets=Z0IAH5WoFAFuQA==,aM4G8A==\r
    m=audio 0 RTP/AVP 97\r
    a=control:trackID=1\r
    a=rtpmap:97 MPEG4-GENERIC/48000/1\r
    a=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config=1188\r

    """
    var camera: FakeCamera!
    var sockets: [FakeSocket] = []
    var manager: CameraStreamManager!
    var activity: [String] = []
    var logs: [String] = []
    var requestedWidths: [Int] = []

    // the controller's side
    let session = Data((0..<16).map { UInt8($0 + 1) })
    let videoKey = Data((0..<16).map { UInt8($0 * 3) }), videoSalt = Data((0..<14).map { UInt8($0 * 5) })
    let audioKey = Data((0..<16).map { UInt8($0 * 7) }), audioSalt = Data((0..<14).map { UInt8($0 * 11) })

    override func setUp() {
        camera = FakeCamera(sdp: sdp)
        manager = CameraStreamManager(queue: queue, makeRTSP: { [unowned self] _, width, _ in
            requestedWidths.append(width)
            return RTSPClient(url: URL(string: "rtsp://cam/stream")!, transport: camera, queue: queue)
        }, makeSocket: { [unowned self] host, port, local in
            let s = FakeSocket(host: host, port: port, localPort: local)
            sockets.append(s)
            return s
        }, log: { [unowned self] message, _ in logs.append(message) })
        manager.onActivity = { [unowned self] id, active in activity.append("\(id):\(active)") }
    }

    private func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: v >> UInt32(8 * $0)) }) }

    private func setupRequest(id: Data? = nil) -> Data {
        let address = HAPCamera.tlv([(1, Data([0])), (2, Data("10.0.0.50".utf8)), (3, le16(51000)), (4, le16(51002))])
        func srtp(_ k: Data, _ s: Data) -> Data { HAPCamera.tlv([(1, Data([0])), (2, k), (3, s)]) }
        return HAPCamera.tlv([(1, id ?? session), (3, address), (4, srtp(videoKey, videoSalt)), (5, srtp(audioKey, audioSalt))])
    }

    private func selection(command: Int, videoSSRC: UInt32, audioSSRC: UInt32, id: Data? = nil, audioCodec: Int = 3) -> Data {
        let control = HAPCamera.tlv([(1, id ?? session), (2, Data([UInt8(command)]))])
        let video = HAPCamera.tlv([(1, Data([0])), (2, HAPCamera.tlv([(1, Data([2])), (2, Data([2])), (3, Data([0]))])),
                                   (3, HAPCamera.tlv([(1, le16(1280)), (2, le16(720)), (3, Data([30]))])),
                                   (4, HAPCamera.tlv([(1, Data([99])), (2, le32(videoSSRC)), (3, le16(299)), (4, Data([0, 0, 0, 0])), (5, le16(1378))]))])
        let audio = HAPCamera.tlv([(1, Data([UInt8(audioCodec)])), (2, HAPCamera.tlv([(1, Data([1])), (2, Data([0])), (3, Data([2])), (4, Data([20]))])),
                                   (3, HAPCamera.tlv([(1, Data([110])), (2, le32(audioSSRC)), (3, le16(24)), (4, Data([0, 0, 0, 0])), (5, Data([13]))]))])
        return HAPCamera.tlv([(1, control), (2, video), (3, audio)])
    }

    private func le(_ d: Data) -> UInt32 { d.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32(8 * $1.offset) } }

    /// Runs setup + start and waits until the camera stream is flowing.
    private func startViewing(audioCodec: Int = 3) async throws -> (video: UInt32, audio: UInt32, response: [UInt8: Data]) {
        var response = Data()
        queue.sync { response = manager.setup(cameraID: "cam1", request: setupRequest(), connection: ObjectIdentifier(self), localAddress: "10.0.0.2") }
        let fields = try XCTUnwrap(TLV8.dictionary(response))
        XCTAssertEqual(fields[2], Data([0]), "status: success")
        let video = le(try XCTUnwrap(fields[6])), audio = le(try XCTUnwrap(fields[7]))
        queue.sync { manager.select(cameraID: "cam1", request: selection(command: 1, videoSSRC: video, audioSSRC: audio, audioCodec: audioCodec)) }
        for _ in 0..<100 where !camera.requests.contains(where: { $0.hasPrefix("PLAY") }) { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(150))   // let the stream become ready
        return (video, audio, fields)
    }

    private func push(_ channel: UInt8, _ packet: RTPPacket) { queue.sync { camera.push(channel: channel, packet.data) } }

    private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), what)
    }

    func testSetupAnswersWithPortsSSRCsAndEchoedKeys() throws {
        var response = Data()
        queue.sync { response = manager.setup(cameraID: "cam1", request: setupRequest(), connection: ObjectIdentifier(self), localAddress: "10.0.0.2") }
        let fields = try XCTUnwrap(TLV8.dictionary(response))
        XCTAssertEqual(fields[1], session)
        let address = try XCTUnwrap(TLV8.dictionary(try XCTUnwrap(fields[3])))
        XCTAssertEqual(String(decoding: try XCTUnwrap(address[2]), as: UTF8.self), "10.0.0.2"); XCTAssertEqual(address[1], Data([0]))
        let videoPort = Int(address[3]![0]) | Int(address[3]![1]) << 8
        XCTAssertTrue((50_000..<65_000).contains(videoPort))
        XCTAssertEqual(TLV8.dictionary(try XCTUnwrap(fields[4]))?[2], videoKey, "the controller's key is echoed")
        XCTAssertEqual(TLV8.dictionary(try XCTUnwrap(fields[5]))?[3], audioSalt)
        XCTAssertNotEqual(le(try XCTUnwrap(fields[6])), 0)
        XCTAssertEqual(manager.activeSessions, 1)
    }

    func testBadRequestsAreRefusedWithStatusTwo() throws {
        queue.sync {
            let bad = manager.setup(cameraID: "cam1", request: HAPCamera.tlv([(1, session)]), connection: ObjectIdentifier(self), localAddress: "10.0.0.2")
            XCTAssertEqual(TLV8.dictionary(bad)?[2], Data([2]))
            let noAddress = manager.setup(cameraID: "cam1", request: setupRequest(), connection: ObjectIdentifier(self), localAddress: nil)
            XCTAssertEqual(TLV8.dictionary(noAddress)?[2], Data([2]))
            XCTAssertEqual(manager.activeSessions, 0)
            XCTAssertEqual(TLV8.dictionary(manager.setup(cameraID: "cam1", request: Data([1]), connection: ObjectIdentifier(self), localAddress: "x"))?[1]?.count, 16)
        }
    }

    func testLiveViewForwardsDecodableEncryptedVideoStartingAtAKeyFrame() async throws {
        let (videoSSRC, _, _) = try await startViewing()
        XCTAssertEqual(requestedWidths, [1280])
        XCTAssertEqual(sockets.map(\.port), [51000, 51002]); XCTAssertEqual(sockets.map(\.host), ["10.0.0.50", "10.0.0.50"])
        XCTAssertEqual(activity, ["cam1:true"])

        // A delta frame first (must be dropped), then an IDR split in two FU-As, then another delta frame.
        let delta: [UInt8] = [0x41, 1, 2, 3]
        let idr: [UInt8] = [0x65] + (0..<2000).map { UInt8($0 % 200) }
        push(0, RTPPacket(marker: true, payloadType: 96, sequence: 1, timestamp: 90_000, ssrc: 7, payload: Data(delta)))
        push(0, RTPPacket(marker: false, payloadType: 96, sequence: 2, timestamp: 93_000, ssrc: 7, payload: Data([0x7C, 0x85]) + idr[1..<1000]))
        push(0, RTPPacket(marker: true, payloadType: 96, sequence: 3, timestamp: 93_000, ssrc: 7, payload: Data([0x7C, 0x45]) + idr[1000...]))
        push(0, RTPPacket(marker: true, payloadType: 96, sequence: 4, timestamp: 96_000, ssrc: 7, payload: Data(delta)))

        let video = sockets[0]
        try await waitFor("video reaches the viewer") { video.sent.count >= 5 }
        let receiver = try XCTUnwrap(SRTPReceiver(masterKey: videoKey, masterSalt: videoSalt))
        var packets: [RTPPacket] = []
        for raw in video.sent {
            let plain = try XCTUnwrap(receiver.unprotect(rtp: raw), "every packet authenticates with the controller's key")
            packets.append(try XCTUnwrap(RTPPacket(plain)))
        }
        XCTAssertTrue(packets.allSatisfy { $0.ssrc == videoSSRC && $0.payloadType == 99 && $0.payload.count + 12 + 10 <= 1378 })

        let back = H264Depacketizer()
        var units: [H264AccessUnit] = []
        for p in packets { units += back.push(p) }
        XCTAssertEqual(units.count, 2, "the leading delta frame was dropped: key frame, then the next delta")
        XCTAssertEqual(units[0].nals.count, 3, "SPS, PPS from the SDP, then the IDR")
        XCTAssertEqual(units[0].nals[0].first, 0x67); XCTAssertEqual(units[0].nals[1].first, 0x68)
        XCTAssertEqual(units[0].nals[2], Data(idr), "the frame survives fragmenting, re-fragmenting and encryption byte for byte")
        XCTAssertEqual(units[1].nals, [Data(delta)])
        XCTAssertEqual(units[1].timestamp &- units[0].timestamp, 3000, "frame timing is preserved")
    }

    func testAudioIsTranscodedToOpusAndEncryptedWithTheAudioKey() async throws {
        let (_, audioSSRC, _) = try await startViewing()
        // build real AAC frames and wrap them the way a camera does (RFC 3640)
        let frames = try AACTestSource.frames(count: 40)
        for (i, frame) in frames.enumerated() {
            let header = UInt16(frame.count << 3)
            let payload = Data([0, 16, UInt8(header >> 8), UInt8(header & 0xFF)]) + frame
            push(2, RTPPacket(marker: true, payloadType: 97, sequence: UInt16(i), timestamp: UInt32(i * 1024), ssrc: 9, payload: payload))
        }
        let audio = sockets[1]
        try await waitFor("audio reaches the viewer") { audio.sent.count >= 30 }
        let receiver = try XCTUnwrap(SRTPReceiver(masterKey: audioKey, masterSalt: audioSalt))
        let packets = try audio.sent.map { try XCTUnwrap(RTPPacket(try XCTUnwrap(receiver.unprotect(rtp: $0)))) }
        XCTAssertTrue(packets.allSatisfy { $0.ssrc == audioSSRC && $0.payloadType == 110 && !$0.payload.isEmpty })
        XCTAssertEqual(packets.map(\.sequence), (0..<packets.count).map { packets[0].sequence &+ UInt16($0) }, "contiguous sequence numbers")
        XCTAssertEqual(packets[1].timestamp &- packets[0].timestamp, 960, "20 ms on the 48 kHz Opus clock")
    }

    func testEndingStopsEverythingAndReleasesPorts() async throws {
        _ = try await startViewing()
        queue.sync { manager.select(cameraID: "cam1", request: selection(command: 0, videoSSRC: 1, audioSSRC: 2)) }
        XCTAssertEqual(manager.activeSessions, 0)
        try await waitFor("camera connection closed") { self.camera.closed }
        XCTAssertTrue(sockets.allSatisfy(\.closed))
        XCTAssertEqual(activity, ["cam1:true", "cam1:false"])
    }

    func testViewerDisconnectEndsItsSessions() async throws {
        _ = try await startViewing()
        queue.sync { manager.connectionClosed(ObjectIdentifier(self)) }
        XCTAssertEqual(manager.activeSessions, 0)
        XCTAssertTrue(sockets.allSatisfy(\.closed))
        XCTAssertEqual(activity.last, "cam1:false")
        queue.sync { manager.connectionClosed(ObjectIdentifier(self)) }   // harmless the second time
    }

    func testCameraThatCannotBePlayedEndsTheSession() async throws {
        camera.failPlay = true
        var response = Data()
        queue.sync { response = manager.setup(cameraID: "cam1", request: setupRequest(), connection: ObjectIdentifier(self), localAddress: "10.0.0.2") }
        let fields = try XCTUnwrap(TLV8.dictionary(response))
        queue.sync { manager.select(cameraID: "cam1", request: selection(command: 1, videoSSRC: le(fields[6]!), audioSSRC: le(fields[7]!))) }
        try await waitFor("session ends") { self.manager.activeSessions == 0 }
        XCTAssertTrue(logs.contains { $0.contains("could not open the camera stream") }, "\(logs)")
        XCTAssertEqual(activity.last, "cam1:false")
    }

    func testVideoOnlyWhenTheViewerDidNotChooseOpus() async throws {
        _ = try await startViewing(audioCodec: 2)   // AAC-ELD is not something we offered
        XCTAssertFalse(camera.requests.contains { $0.contains("trackID=1") }, "the audio track is not even set up")
    }

    func testSessionLimit() {
        queue.sync {
            for i in 0..<CameraStreamManager.maxSessions {
                var id = session; id[0] = UInt8(100 + i)
                XCTAssertEqual(TLV8.dictionary(manager.setup(cameraID: "cam1", request: setupRequest(id: id), connection: ObjectIdentifier(self), localAddress: "10.0.0.2"))?[2], Data([0]))
            }
            var extra = session; extra[0] = 250
            XCTAssertEqual(TLV8.dictionary(manager.setup(cameraID: "cam1", request: setupRequest(id: extra), connection: ObjectIdentifier(self), localAddress: "10.0.0.2"))?[2], Data([1]), "busy")
            manager.stopAll()
            XCTAssertEqual(manager.activeSessions, 0)
        }
    }
}

/// AAC-LC frames made with the system encoder, as a camera would produce them (48 kHz mono, config 1188).
enum AACTestSource {
    static func frames(count: Int) throws -> [Data] {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 2, mBytesPerPacket: 0,
                                                      mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        let aac = try XCTUnwrap(AVAudioFormat(streamDescription: &description))
        let pcm = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let encoder = try XCTUnwrap(AVAudioConverter(from: pcm, to: aac))
        var frames: [Data] = [], phase = 0
        while frames.count < count {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 1024))
            buffer.frameLength = 1024
            for i in 0..<1024 { buffer.floatChannelData![0][i] = 0.5 * sinf(2 * .pi * 440 * Float(phase + i) / 48_000) }
            phase += 1024
            let out = AVAudioCompressedBuffer(format: aac, packetCapacity: 8, maximumPacketSize: 2048)
            var fed = false
            var error: NSError?
            _ = encoder.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            if out.byteLength > 0 { frames.append(Data(bytes: out.data, count: Int(out.byteLength))) }
        }
        return frames
    }
}

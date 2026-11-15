import XCTest
@testable import HouseBridgeCore

/// Plays the camera: answers each RTSP request with a canned response and can push interleaved packets.
final class FakeCamera: RTSPTransport, @unchecked Sendable {
    var onData: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
    private(set) var requests: [String] = []
    private(set) var closed = false
    var sdp: String
    var failPlay = false

    init(sdp: String) { self.sdp = sdp }

    func connect(_ done: @escaping (Error?) -> Void) { done(nil) }
    func close() { closed = true }

    func send(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        requests.append(text)
        let method = String(text.prefix(while: { $0 != " " }))
        let cseq = text.components(separatedBy: "\r\n").first { $0.hasPrefix("CSeq:") }!.dropFirst(5).trimmingCharacters(in: .whitespaces)
        var reply = "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\n"
        var body = ""
        switch method {
        case "DESCRIBE": reply += "Content-Base: rtsp://cam/stream/\r\nContent-Type: application/sdp\r\n"; body = sdp
        case "SETUP": reply += "Session: ABC123;timeout=60\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n"
        case "PLAY": if failPlay { reply = "RTSP/1.0 454 Session Not Found\r\nCSeq: \(cseq)\r\n" }
        default: break
        }
        reply += "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        let bytes = Data(reply.utf8)
        // deliver in two pieces to exercise buffering
        DispatchQueue.global().async {
            self.onData?(bytes.prefix(10)); self.onData?(bytes.dropFirst(10))
        }
    }

    func push(channel: UInt8, _ rtp: Data) { onData?(Data([0x24, channel, UInt8(rtp.count >> 8), UInt8(rtp.count & 0xFF)]) + rtp) }
}

let testSDP = """
v=0\r
o=- 0 0 IN IP4 10.0.0.2\r
s=Stream\r
m=video 0 RTP/AVP 96\r
a=control:trackID=0\r
a=rtpmap:96 H264/90000\r
a=fmtp:96 packetization-mode=1;profile-level-id=640029;sprop-parameter-sets=Z2QAKa0=,aO48gA==\r
m=audio 0 RTP/AVP 97\r
a=control:trackID=1\r
a=rtpmap:97 MPEG4-GENERIC/48000/2\r
a=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config=1190\r

"""

final class RTSPTests: XCTestCase {
    func testSDPParsing() throws {
        let media = SDP.parse(testSDP)
        XCTAssertEqual(media.map(\.kind), ["video", "audio"])
        XCTAssertEqual(media[0].codec, "H264"); XCTAssertEqual(media[0].payloadType, 96); XCTAssertEqual(media[0].clockRate, 90000)
        XCTAssertEqual(media[0].control, "trackID=0")
        let sets = SDP.parameterSets(media[0].fmtp)
        XCTAssertEqual(sets.sps?.first, 0x67); XCTAssertEqual(sets.pps?.first, 0x68)
        XCTAssertEqual(media[1].codec, "MPEG4-GENERIC"); XCTAssertEqual(media[1].clockRate, 48000); XCTAssertEqual(media[1].channels, 2)
        XCTAssertEqual(media[1].fmtp["config"], "1190"); XCTAssertEqual(media[1].fmtp["sizelength"], "13")
    }

    func testNegotiatesAndDeliversInterleavedPacketsAcrossSplitReads() async throws {
        let camera = FakeCamera(sdp: testSDP)
        let queue = DispatchQueue(label: "rtsp-test")
        let client = RTSPClient(url: URL(string: "rtsp://cam/stream")!, transport: camera, queue: queue)
        let got = Mutex<[(String, UInt16)]>([])
        client.onPacket = { media, packet in got.mutate { $0.append((media.kind, packet.sequence)) } }

        let chosen = try await client.play { $0 }
        XCTAssertEqual(chosen.map(\.kind), ["video", "audio"])
        let methods = camera.requests.map { String($0.prefix(while: { $0 != " " })) }
        XCTAssertEqual(methods, ["DESCRIBE", "SETUP", "SETUP", "PLAY"])
        XCTAssertTrue(camera.requests[1].contains("rtsp://cam/stream/trackID=0"), "relative control resolved against Content-Base")
        XCTAssertTrue(camera.requests[1].contains("interleaved=0-1")); XCTAssertTrue(camera.requests[2].contains("interleaved=2-3"))
        XCTAssertTrue(camera.requests[3].contains("Session: ABC123"), "the session id is echoed")

        let video = RTPPacket(marker: true, payloadType: 96, sequence: 5, timestamp: 0, ssrc: 1, payload: Data([0x41])).data
        let audio = RTPPacket(marker: true, payloadType: 97, sequence: 9, timestamp: 0, ssrc: 2, payload: Data([0, 16])).data
        // one frame split across two reads, then RTCP (ignored) and another packet glued on
        let framed = Data([0x24, 0, 0, UInt8(video.count)]) + video
        queue.sync { client.receive(framed.prefix(7)) }
        queue.sync { client.receive(framed.dropFirst(7) + Data([0x24, 1, 0, 3, 1, 2, 3]) + Data([0x24, 2, 0, UInt8(audio.count)]) + audio) }
        XCTAssertEqual(got.value.map(\.0), ["video", "audio"]); XCTAssertEqual(got.value.map(\.1), [5, 9])
        client.stop()
    }

    func testOnlyWantedTracksAreSetUp() async throws {
        let camera = FakeCamera(sdp: testSDP)
        let client = RTSPClient(url: URL(string: "rtsp://cam/stream")!, transport: camera, queue: DispatchQueue(label: "rtsp-test2"))
        let chosen = try await client.play { $0.filter { $0.kind == "video" } }
        XCTAssertEqual(chosen.count, 1)
        XCTAssertEqual(camera.requests.filter { $0.hasPrefix("SETUP") }.count, 1)
        client.stop()
    }

    func testFailuresSurface() async {
        let camera = FakeCamera(sdp: testSDP)
        camera.failPlay = true
        let client = RTSPClient(url: URL(string: "rtsp://cam/stream")!, transport: camera, queue: DispatchQueue(label: "rtsp-test3"))
        do { _ = try await client.play { $0 }; XCTFail("should have thrown") }
        catch { XCTAssertTrue("\(error)".contains("454"), "\(error)") }

        let none = RTSPClient(url: URL(string: "rtsp://cam/stream")!, transport: FakeCamera(sdp: testSDP), queue: DispatchQueue(label: "rtsp-test4"))
        do { _ = try await none.play { _ in [] }; XCTFail("should have thrown") }
        catch { XCTAssertTrue("\(error)".contains("no usable stream")) }
    }
}

/// Tiny lock-protected box for collecting results from callbacks.
final class Mutex<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ change: (inout T) -> Void) { lock.withLock { change(&stored) } }
}

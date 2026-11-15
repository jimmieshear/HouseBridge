import XCTest
@testable import HouseBridgeCore

final class RTPTests: XCTestCase {
    func testPacketRoundTripAndHeaderExtensionsAndPadding() throws {
        let packet = RTPPacket(marker: true, payloadType: 96, sequence: 65535, timestamp: 0xFFFF_FFF0, ssrc: 0x01020304, payload: Data([1, 2, 3]))
        XCTAssertEqual(packet.data.count, 15)
        let parsed = try XCTUnwrap(RTPPacket(packet.data))
        XCTAssertEqual(parsed.marker, true); XCTAssertEqual(parsed.payloadType, 96); XCTAssertEqual(parsed.sequence, 65535)
        XCTAssertEqual(parsed.timestamp, 0xFFFF_FFF0); XCTAssertEqual(parsed.ssrc, 0x01020304); XCTAssertEqual(parsed.payload, Data([1, 2, 3]))

        // one CSRC, a one-word extension, and 2 bytes of padding
        var raw = packet.data
        raw[0] = 0x80 | 0x20 | 0x10 | 1
        raw.insert(contentsOf: [0, 0, 0, 9] + [0xBE, 0xDE, 0, 1, 0xAA, 0xAA, 0xAA, 0xAA], at: 12)
        raw.append(contentsOf: [0, 2])
        XCTAssertEqual(RTPPacket(raw)?.payload, Data([1, 2, 3]))
        XCTAssertNil(RTPPacket(Data(count: 5))); XCTAssertNil(RTPPacket(Data([0x40]) + Data(count: 20)), "version must be 2")
    }

    private func packet(_ payload: [UInt8], ts: UInt32 = 1000, marker: Bool = false, seq: UInt16 = 0) -> RTPPacket {
        RTPPacket(marker: marker, payloadType: 96, sequence: seq, timestamp: ts, ssrc: 1, payload: Data(payload))
    }

    func testDepacketizesSingleStapAndFragmentedUnits() {
        let d = H264Depacketizer()
        let sps: [UInt8] = [0x67, 1, 2], pps: [UInt8] = [0x68, 3]
        XCTAssertTrue(d.push(packet([24, 0, 3] + sps + [0, 2] + pps)).isEmpty)   // STAP-A with SPS+PPS
        let idr: [UInt8] = [0x65] + Array(repeating: 7, count: 10)
        // FU-A split of the IDR: indicator keeps NRI (0x60) and type 28; header carries S/E and the NAL type 5
        XCTAssertTrue(d.push(packet([0x7C, 0x85] + idr[1..<5])).isEmpty)
        XCTAssertTrue(d.push(packet([0x7C, 0x05] + idr[5..<8])).isEmpty)
        let done = d.push(packet([0x7C, 0x45] + idr[8...], marker: true))
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done[0].nals, [Data(sps), Data(pps), Data(idr)])
        XCTAssertTrue(done[0].isKeyFrame)
    }

    func testNewTimestampEndsAFrameWhenTheMarkerWasLost() {
        let d = H264Depacketizer()
        XCTAssertTrue(d.push(packet([0x41, 1], ts: 1000)).isEmpty)
        let done = d.push(packet([0x41, 2], ts: 4000, marker: true))
        XCTAssertEqual(done.map(\.timestamp), [1000, 4000])
        XCTAssertFalse(done[0].isKeyFrame)
    }

    func testPacketizerInjectsParameterSetsAndFragmentsToTheMTU() throws {
        let sps = Data([0x67, 0x42, 0x00, 0x1F]), pps = Data([0x68, 0xCE])
        let p = H264Packetizer(payloadType: 99, ssrc: 0xAABBCCDD, mtu: 1378, sps: sps, pps: pps, initialSequence: 65534, timestampOffset: 1_000)
        XCTAssertEqual(p.maxPayload, 1378 - 12 - 10)

        let idr = Data([0x65]) + Data((0..<3000).map { UInt8($0 % 200) })
        let key = p.packets(for: H264AccessUnit(timestamp: 90_000, nals: [idr]))
        XCTAssertEqual(key.first?.payload, sps); XCTAssertEqual(key.dropFirst().first?.payload, pps)
        XCTAssertEqual(key.map(\.sequence).prefix(3), [65534, 65535, 0], "sequence wraps")
        XCTAssertEqual(key.filter(\.marker).count, 1); XCTAssertTrue(key.last!.marker)
        XCTAssertTrue(key.allSatisfy { $0.payload.count <= p.maxPayload && $0.ssrc == 0xAABBCCDD && $0.payloadType == 99 })
        XCTAssertTrue(key.allSatisfy { $0.timestamp == 1_000 }, "first frame defines the timeline")

        // what a receiver rebuilds is the original stream
        let back = H264Depacketizer()
        var out: [H264AccessUnit] = []
        for pkt in key { out += back.push(pkt) }
        XCTAssertEqual(out.first?.nals, [sps, pps, idr])

        // a later frame: not a key frame, so nothing injected, 1 packet, timeline offset by the camera's delta
        let delta = p.packets(for: H264AccessUnit(timestamp: 93_000, nals: [Data([0x41, 9, 9])]))
        XCTAssertEqual(delta.count, 1); XCTAssertEqual(delta[0].timestamp, 4_000); XCTAssertEqual(delta[0].payload, Data([0x41, 9, 9]))
        XCTAssertEqual(delta[0].sequence, key.last!.sequence &+ 1)
    }

    func testPacketizerLearnsParameterSetsFromTheStreamAndDropsDelimiters() {
        let p = H264Packetizer(payloadType: 99, ssrc: 1, mtu: 1378)
        let sps = Data([0x67, 1]), pps = Data([0x68, 2]), idr = Data([0x65, 3])
        _ = p.packets(for: H264AccessUnit(timestamp: 0, nals: [Data([0x09, 0xF0]), sps, pps, idr]))
        let later = p.packets(for: H264AccessUnit(timestamp: 3000, nals: [Data([0x09, 0xF0]), idr]))
        XCTAssertEqual(later.map(\.payload), [sps, pps, idr], "key frame without its own parameter sets gets the remembered ones; delimiter dropped")
    }
}

import Foundation

/// A parsed RTP packet (RFC 3550).
struct RTPPacket {
    var marker: Bool
    var payloadType: UInt8
    var sequence: UInt16
    var timestamp: UInt32
    var ssrc: UInt32
    var payload: Data

    init(marker: Bool, payloadType: UInt8, sequence: UInt16, timestamp: UInt32, ssrc: UInt32, payload: Data) {
        self.marker = marker; self.payloadType = payloadType; self.sequence = sequence
        self.timestamp = timestamp; self.ssrc = ssrc; self.payload = payload
    }

    init?(_ data: Data) {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data.prefix(12))
        guard b[0] >> 6 == 2 else { return nil }
        var offset = 12 + 4 * Int(b[0] & 0x0F)
        if b[0] & 0x10 != 0 {
            guard data.count >= offset + 4 else { return nil }
            offset += 4 + 4 * (Int(data[data.startIndex + offset + 2]) << 8 | Int(data[data.startIndex + offset + 3]))
        }
        guard data.count >= offset else { return nil }
        var end = data.count
        if b[0] & 0x20 != 0, let pad = data.last { end -= Int(pad) }          // padding
        guard end >= offset else { return nil }
        marker = b[1] & 0x80 != 0
        payloadType = b[1] & 0x7F
        sequence = UInt16(b[2]) << 8 | UInt16(b[3])
        timestamp = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        ssrc = UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11])
        payload = Data(data[(data.startIndex + offset)..<(data.startIndex + end)])
    }

    var data: Data {
        var out = Data(capacity: 12 + payload.count)
        out.append(0x80)
        out.append((marker ? 0x80 : 0) | (payloadType & 0x7F))
        out.append(UInt8(sequence >> 8)); out.append(UInt8(sequence & 0xFF))
        for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: timestamp >> UInt32(shift))) }
        for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: ssrc >> UInt32(shift))) }
        out.append(payload)
        return out
    }
}

/// One video frame: the NAL units (without start codes) that share an RTP timestamp.
struct H264AccessUnit {
    var timestamp: UInt32
    var nals: [Data]
    var isKeyFrame: Bool { nals.contains { ($0.first ?? 0) & 0x1F == 5 } }
}

/// Turns the camera's RTP/H.264 (RFC 6184: single NAL, STAP-A, FU-A) back into whole NAL units, grouped per frame.
final class H264Depacketizer {
    private var current: [Data] = []
    private var currentTimestamp: UInt32?
    private var fragment: Data?

    /// Feed packets in order; returns the frames that completed with this packet.
    func push(_ packet: RTPPacket) -> [H264AccessUnit] {
        var done: [H264AccessUnit] = []
        if let ts = currentTimestamp, ts != packet.timestamp, !current.isEmpty {
            done.append(H264AccessUnit(timestamp: ts, nals: current))   // the marker bit was lost; the new timestamp ends it
            current = []
        }
        currentTimestamp = packet.timestamp
        let p = packet.payload
        guard let first = p.first else { return done }
        switch first & 0x1F {
        case 1...23:
            current.append(p)
        case 24:   // STAP-A: 2-byte size before each NAL
            var i = p.startIndex + 1
            while i + 2 <= p.endIndex {
                let size = Int(p[i]) << 8 | Int(p[i + 1])
                i += 2
                guard size > 0, i + size <= p.endIndex else { break }
                current.append(Data(p[i..<(i + size)]))
                i += size
            }
        case 28:   // FU-A
            guard p.count >= 2 else { break }
            let header = p[p.startIndex + 1]
            let start = header & 0x80 != 0, end = header & 0x40 != 0
            if start {
                fragment = Data([(first & 0xE0) | (header & 0x1F)]) + p.dropFirst(2)
            } else if fragment != nil {
                fragment!.append(p.dropFirst(2))
            }
            if end, let complete = fragment { current.append(complete); fragment = nil }
        default: break   // STAP-B, MTAP, FU-B are not used by cameras
        }
        if packet.marker, !current.isEmpty {
            done.append(H264AccessUnit(timestamp: packet.timestamp, nals: current))
            current = []
            currentTimestamp = nil
        }
        return done
    }
}

/// Builds RTP packets for HomeKit from whole frames: size limited by the controller's MTU, with SPS/PPS put in front of
/// every key frame (a viewer that joins mid-stream, which is every viewer, cannot decode without them).
final class H264Packetizer {
    let payloadType: UInt8
    let ssrc: UInt32
    /// Largest RTP payload; the controller's MTU less the 12-byte header and the SRTP tag.
    let maxPayload: Int
    private(set) var sequence: UInt16
    private var sps: Data?
    private var pps: Data?
    private var baseTimestamp: UInt32?
    private let timestampOffset: UInt32

    init(payloadType: UInt8, ssrc: UInt32, mtu: Int, sps: Data? = nil, pps: Data? = nil,
         initialSequence: UInt16 = UInt16.random(in: 0...0xFFFF), timestampOffset: UInt32 = UInt32.random(in: 0...0xFFFF_FFFF)) {
        self.payloadType = payloadType; self.ssrc = ssrc
        self.maxPayload = max(100, mtu - 12 - SRTPSender.tagLength)
        self.sps = sps; self.pps = pps
        sequence = initialSequence
        self.timestampOffset = timestampOffset
    }

    /// RTP timestamp for the next packet, as sent (also what an RTCP sender report must carry).
    func rtpTimestamp(for cameraTimestamp: UInt32) -> UInt32 {
        if baseTimestamp == nil { baseTimestamp = cameraTimestamp }
        return (cameraTimestamp &- baseTimestamp!) &+ timestampOffset
    }

    func packets(for unit: H264AccessUnit) -> [RTPPacket] {
        var nals = unit.nals
        for nal in nals {
            switch (nal.first ?? 0) & 0x1F {
            case 7: sps = nal
            case 8: pps = nal
            default: break
            }
        }
        if unit.isKeyFrame {
            var lead: [Data] = []
            if !nals.contains(where: { ($0.first ?? 0) & 0x1F == 7 }), let sps { lead.append(sps) }
            if !nals.contains(where: { ($0.first ?? 0) & 0x1F == 8 }), let pps { lead.append(pps) }
            nals = lead + nals
        }
        nals.removeAll { [9, 12].contains(($0.first ?? 0) & 0x1F) }   // access unit delimiters and filler only waste bytes
        guard !nals.isEmpty else { return [] }

        let timestamp = rtpTimestamp(for: unit.timestamp)
        var payloads: [Data] = []
        for nal in nals {
            if nal.count <= maxPayload { payloads.append(nal); continue }
            let indicator = (nal[nal.startIndex] & 0xE0) | 28
            let type = nal[nal.startIndex] & 0x1F
            var offset = nal.startIndex + 1
            let size = maxPayload - 2
            while offset < nal.endIndex {
                let end = min(offset + size, nal.endIndex)
                let header = (offset == nal.startIndex + 1 ? 0x80 : 0) | (end == nal.endIndex ? 0x40 : 0) | type
                payloads.append(Data([indicator, UInt8(header)]) + nal[offset..<end])
                offset = end
            }
        }
        return payloads.enumerated().map { index, payload in
            defer { sequence &+= 1 }
            return RTPPacket(marker: index == payloads.count - 1, payloadType: payloadType, sequence: sequence,
                             timestamp: timestamp, ssrc: ssrc, payload: payload)
        }
    }
}

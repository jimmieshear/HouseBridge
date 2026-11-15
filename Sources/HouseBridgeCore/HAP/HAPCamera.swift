import Foundation

/// HomeKit camera description: the TLV8 blobs that tell Home.app what a camera can stream, and the (for now, refusing)
/// answer to a live-view request. Stage 1 serves snapshots only; the streaming setup is answered with an error.
///
/// Written from the HAP specification without a reference implementation to compare against, and not yet
/// seen working in Home.app: treat the exact byte layouts as unverified.
enum HAPCamera {
    // Service and characteristic types (short form of the HomeKit base UUID).
    static let streamManagement = "110", microphone = "112"
    static let supportedVideo = "114", supportedAudio = "115", supportedRTP = "116", selectedStream = "117"
    static let setupEndpoints = "118", streamingStatus = "120", active = "B0", mute = "11"

    /// Raw TLV with arbitrary tags. Adjacent items of the same tag would need a separator, so callers avoid them.
    static func tlv(_ items: [(UInt8, Data)]) -> Data { TLV8.encode(raw: items) }
    private static func byte(_ v: Int) -> Data { Data([UInt8(truncatingIfNeeded: v)]) }
    private static func le16(_ v: Int) -> Data { Data([UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]) }

    /// One H.264 configuration (Main profile, level 3.1, non-interleaved packetization) at one resolution.
    static func supportedVideoConfiguration(width: Int = 1280, height: Int = 720, fps: Int = 30) -> Data {
        let params = tlv([(1, byte(1)), (2, byte(0)), (3, byte(0))])                 // profile Main, level 3.1, packetization 0
        let attributes = tlv([(1, le16(width)), (2, le16(height)), (3, byte(fps))])
        let codec = tlv([(1, byte(0)), (2, params), (3, attributes)])                 // codec type 0 = H.264
        return tlv([(1, codec)])
    }

    /// One Opus configuration: mono, variable bitrate, 24 kHz, 20 ms packets.
    static func supportedAudioConfiguration() -> Data {
        let params = tlv([(1, byte(1)), (2, byte(0)), (3, byte(2)), (4, byte(20))])   // 1 channel, VBR, 24 kHz, ptime 20
        let codec = tlv([(1, byte(3)), (2, params)])                                   // codec type 3 = Opus
        return tlv([(1, codec), (2, byte(0))])                                        // no comfort noise
    }

    /// SRTP with AES-CM-128 and HMAC-SHA1 (80-bit tag), the suite every controller supports.
    static func supportedRTPConfiguration() -> Data { tlv([(2, byte(0))]) }

    /// Streaming status: 0 = available.
    static func streamingStatus(_ status: Int = 0) -> Data { tlv([(1, byte(status))]) }

    /// Selected stream configuration at rest: a session-control entry with no session and the "end" command.
    static func idleSelection() -> Data { tlv([(1, tlv([(1, Data(count: 16)), (2, byte(0))]))]) }

    /// Answer to a SetupEndpoints write while live video is not available: the session id back, with status 2 (error).
    /// `nil` when the request has no session id.
    static func refuseSetup(_ request: Data) -> Data? {
        guard let fields = TLV8.dictionary(request), let session = fields[1], session.count == 16 else { return nil }
        return tlv([(1, session), (2, byte(2))])
    }
}

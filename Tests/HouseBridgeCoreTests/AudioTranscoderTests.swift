import XCTest
import AVFoundation
@testable import HouseBridgeCore

final class AudioTranscoderTests: XCTestCase {
    func testDepacketizesAUHeaders() {
        // two frames of 5 and 3 bytes: AU-headers-length = 32 bits; each header is size(13) | index(3)
        let h1 = UInt16(5 << 3), h2 = UInt16(3 << 3 | 1)
        let payload = Data([0, 32, UInt8(h1 >> 8), UInt8(h1 & 0xFF), UInt8(h2 >> 8), UInt8(h2 & 0xFF)]) + Data([1, 2, 3, 4, 5]) + Data([6, 7, 8])
        XCTAssertEqual(AACDepacketizer(fmtp: [:]).frames(in: payload), [Data([1, 2, 3, 4, 5]), Data([6, 7, 8])])
        XCTAssertTrue(AACDepacketizer(fmtp: [:]).frames(in: Data([0, 16, 0xFF, 0xF8, 1])).isEmpty, "size larger than the data")
        XCTAssertTrue(AACDepacketizer(fmtp: [:]).frames(in: Data([1])).isEmpty)
    }

    func testConfigHex() {
        XCTAssertEqual(AudioTranscoder.configBytes("1190"), Data([0x11, 0x90]))
        XCTAssertNil(AudioTranscoder.configBytes("119")); XCTAssertNil(AudioTranscoder.configBytes(nil)); XCTAssertNil(AudioTranscoder.configBytes("zz90"))
    }

    /// Encodes a tone to AAC with the system encoder, then runs it through the transcoder as a camera would send it.
    func testAACToneBecomesOpusPackets() throws {
        let rate = 48_000.0
        var aacDescription = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 2,   // AAC-LC
                                                         mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                                         mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        let aac = try XCTUnwrap(AVAudioFormat(streamDescription: &aacDescription))
        let pcmFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let encoder = try XCTUnwrap(AVAudioConverter(from: pcmFormat, to: aac))

        // 2 seconds of a 440 Hz tone, fed to the encoder 1024 samples at a time
        var frames: [Data] = []
        var phase = 0
        for _ in 0..<94 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 1024))
            buffer.frameLength = 1024
            for i in 0..<1024 { buffer.floatChannelData![0][i] = 0.5 * sinf(2 * .pi * 440 * Float(phase + i) / Float(rate)) }
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
        XCTAssertGreaterThan(frames.count, 80)

        // The AudioSpecificConfig a camera puts in its SDP: AAC-LC, 48 kHz, mono.
        let asc = try XCTUnwrap(AudioTranscoder.configBytes("1188"), "48 kHz mono AAC-LC")
        let transcoder = try XCTUnwrap(AudioTranscoder(config: asc, sampleRate: rate, channels: 1))
        var packets: [Data] = []
        for frame in frames { packets += transcoder.opusPackets(forAAC: frame) }
        XCTAssertGreaterThan(packets.count, 85, "~2 s of audio is ~100 packets of 20 ms")
        XCTAssertLessThan(packets.count, 105)
        XCTAssertTrue(packets.allSatisfy { !$0.isEmpty && $0.count < 400 })

        // Decode the Opus back and check the tone survived (energy is there and it is a 24 kHz stream)
        var opusDescription = AudioStreamBasicDescription(mSampleRate: 24_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                                          mFramesPerPacket: 480, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        let opus = try XCTUnwrap(AVAudioFormat(streamDescription: &opusDescription))
        let monoFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false))
        let decoder = try XCTUnwrap(AVAudioConverter(from: opus, to: monoFormat))
        var energy: Float = 0, count = 0
        for packet in packets.dropFirst(10).prefix(40) {
            let input = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: packet.count)
            packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
            input.byteLength = UInt32(packet.count); input.packetCount = 1
            input.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 960))
            var given = false
            var error: NSError?
            _ = decoder.convert(to: pcm, error: &error) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true; status.pointee = .haveData; return input
            }
            for i in 0..<Int(pcm.frameLength) { energy += pcm.floatChannelData![0][i] * pcm.floatChannelData![0][i]; count += 1 }
        }
        XCTAssertGreaterThan(count, 10_000)
        let rms = sqrtf(energy / Float(count))
        XCTAssertEqual(rms, 0.5 / sqrtf(2), accuracy: 0.08, "a 0.5-amplitude sine has RMS 0.354; got \(rms)")
    }

    func testRejectsGarbage() {
        XCTAssertNotNil(AudioTranscoder(config: Data([0x11, 0x88]), sampleRate: 48_000, channels: 1))
        let transcoder = AudioTranscoder(config: Data([0x11, 0x88]), sampleRate: 48_000, channels: 1)
        XCTAssertTrue(transcoder?.opusPackets(forAAC: Data([1, 2, 3])).isEmpty ?? false, "undecodable frame produces nothing and does not crash")
    }
}

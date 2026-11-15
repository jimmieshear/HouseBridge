import Foundation
import AVFoundation
import AudioToolbox

/// Extracts AAC frames from RTP (RFC 3640, mode AAC-hbr): a 16-bit "AU headers length" in bits, one header per frame
/// (size and index bits), then the frames back to back.
struct AACDepacketizer {
    var sizeLength = 13
    var indexLength = 3
    var indexDeltaLength = 3

    init(fmtp: [String: String]) {
        sizeLength = Int(fmtp["sizelength"] ?? "") ?? 13
        indexLength = Int(fmtp["indexlength"] ?? "") ?? 3
        indexDeltaLength = Int(fmtp["indexdeltalength"] ?? "") ?? 3
    }

    func frames(in payload: Data) -> [Data] {
        let bytes = [UInt8](payload)
        guard bytes.count >= 2 else { return [] }
        let headerBits = Int(bytes[0]) << 8 | Int(bytes[1])
        var bit = 16
        var sizes: [Int] = []
        var first = true
        while bit - 16 < headerBits {
            let width = sizeLength + (first ? indexLength : indexDeltaLength)
            guard bit + width <= bytes.count * 8 else { return [] }
            var size = 0
            for i in 0..<sizeLength { size = size << 1 | Int((bytes[(bit + i) / 8] >> UInt8(7 - (bit + i) % 8)) & 1) }
            sizes.append(size)
            bit += width
            first = false
        }
        var offset = 2 + (headerBits + 7) / 8
        var out: [Data] = []
        for size in sizes {
            guard size > 0, offset + size <= bytes.count else { break }
            out.append(Data(bytes[offset..<(offset + size)]))
            offset += size
        }
        return out
    }
}

/// Camera audio (AAC) to what HomeKit plays (Opus, mono, 24 kHz, 20 ms packets), using the system's audio converters.
/// Not thread-safe; feed it from one queue.
final class AudioTranscoder {
    static let outputRate = 24_000.0
    static let frameSamples: AVAudioFrameCount = 480   // 20 ms at 24 kHz

    private let decoder: AVAudioConverter
    private let mixer: AVAudioConverter
    private let encoder: AVAudioConverter
    private let decodedFormat: AVAudioFormat
    private let monoFormat: AVAudioFormat
    private var pending: [Float] = []

    /// `config` is the AudioSpecificConfig from the SDP (`config=1190`); `sampleRate` and `channels` come from the rtpmap.
    init?(config: Data, sampleRate: Double, channels: Int) {
        var description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                                      mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                                      mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        guard let aac = AVAudioFormat(streamDescription: &description),
              let decoded = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false),
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate, channels: 1, interleaved: false),
              let decoder = AVAudioConverter(from: aac, to: decoded),
              let mixer = AVAudioConverter(from: decoded, to: mono) else { return nil }
        decoder.magicCookie = config
        var opusDescription = AudioStreamBasicDescription(mSampleRate: Self.outputRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                                          mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.frameSamples), mBytesPerFrame: 0,
                                                          mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &opusDescription), let encoder = AVAudioConverter(from: mono, to: opus) else { return nil }
        encoder.bitRate = 24_000
        self.decoder = decoder; self.mixer = mixer; self.encoder = encoder
        decodedFormat = decoded; monoFormat = mono
    }

    /// AudioSpecificConfig bytes from the SDP's hex `config=` value.
    static func configBytes(_ hex: String?) -> Data? {
        guard let hex, hex.count >= 4, hex.count % 2 == 0 else { return nil }
        let digits = Array(hex)
        var out = Data()
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(digits[i...i + 1]), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }

    /// Decodes one AAC frame and returns whatever complete 20 ms Opus packets that makes available.
    func opusPackets(forAAC frame: Data) -> [Data] {
        guard let compressed = Optional(AVAudioCompressedBuffer(format: decoder.inputFormat, packetCapacity: 1, maximumPacketSize: max(frame.count, 1))) else { return [] }
        frame.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: frame.count) }
        compressed.byteLength = UInt32(frame.count)
        compressed.packetCount = 1
        compressed.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count))

        guard let pcm = AVAudioPCMBuffer(pcmFormat: decodedFormat, frameCapacity: 2048) else { return [] }
        var supplied = false
        var error: NSError?
        let status = decoder.convert(to: pcm, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return compressed
        }
        guard status != .error, pcm.frameLength > 0 else { return [] }

        // channels -> mono, sample rate -> 24 kHz
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * Self.outputRate / decodedFormat.sampleRate) + 64
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity) else { return [] }
        var given = false
        let mixStatus = mixer.convert(to: mono, error: &error) { _, outStatus in
            if given { outStatus.pointee = .noDataNow; return nil }
            given = true
            outStatus.pointee = .haveData
            return pcm
        }
        guard mixStatus != .error, let samples = mono.floatChannelData?[0] else { return [] }
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(mono.frameLength)))

        var packets: [Data] = []
        while pending.count >= Int(Self.frameSamples) {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: Self.frameSamples) else { break }
            chunk.frameLength = Self.frameSamples
            pending.withUnsafeBufferPointer { chunk.floatChannelData![0].update(from: $0.baseAddress!, count: Int(Self.frameSamples)) }
            pending.removeFirst(Int(Self.frameSamples))
            let out = AVAudioCompressedBuffer(format: encoder.outputFormat, packetCapacity: 1, maximumPacketSize: 1500)
            var fed = false
            let result = encoder.convert(to: out, error: &error) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return chunk
            }
            if result != .error, out.byteLength > 0 { packets.append(Data(bytes: out.data, count: Int(out.byteLength))) }
        }
        return packets
    }
}

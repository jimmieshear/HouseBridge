import Foundation
import CryptoKit
import CommonCrypto

/// AES-128 in counter mode (the SRTP cipher), through CommonCrypto.
enum AESCounterMode {
    /// XORs `data` with the keystream that starts at the 16-byte counter block `iv` (big-endian increment).
    static func apply(key: Data, iv: Data, to data: Data) -> Data {
        precondition(key.count == 16 && iv.count == 16)
        guard !data.isEmpty else { return data }
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                        v.baseAddress, k.baseAddress, 16, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        precondition(created == CCCryptorStatus(kCCSuccess), "AES-CTR unavailable")
        defer { CCCryptorRelease(cryptor) }
        var out = Data(count: data.count)
        var moved = 0
        let status = data.withUnsafeBytes { input in
            out.withUnsafeMutableBytes { output in
                CCCryptorUpdate(cryptor, input.baseAddress, data.count, output.baseAddress, data.count, &moved)
            }
        }
        precondition(status == CCCryptorStatus(kCCSuccess) && moved == data.count, "AES-CTR failed")
        return out
    }
}

/// The sending half of SRTP/SRTCP with the default HomeKit suite, AES_CM_128_HMAC_SHA1_80 (RFC 3711): AES counter-mode
/// encryption and an 80-bit HMAC-SHA1 tag. One instance per direction and stream; not thread-safe.
final class SRTPSender {
    static let tagLength = 10

    private let rtpKey: Data, rtpSalt: Data, rtpAuth: Data
    private let rtcpKey: Data, rtcpSalt: Data, rtcpAuth: Data
    private var roc: UInt32 = 0
    private var lastSequence: UInt16?
    private var rtcpIndex: UInt32 = 0

    /// `masterKey` is 16 bytes and `masterSalt` 14, as HomeKit hands them over.
    init?(masterKey: Data, masterSalt: Data) {
        guard masterKey.count == 16, masterSalt.count == 14 else { return nil }
        rtpKey = Self.derive(masterKey, masterSalt, label: 0, length: 16)
        rtpAuth = Self.derive(masterKey, masterSalt, label: 1, length: 20)
        rtpSalt = Self.derive(masterKey, masterSalt, label: 2, length: 14)
        rtcpKey = Self.derive(masterKey, masterSalt, label: 3, length: 16)
        rtcpAuth = Self.derive(masterKey, masterSalt, label: 4, length: 20)
        rtcpSalt = Self.derive(masterKey, masterSalt, label: 5, length: 14)
    }

    /// RFC 3711 section 4.3 with a key derivation rate of 0: the keystream of AES-CM over IV = (salt XOR label) || 0x0000.
    static func derive(_ masterKey: Data, _ masterSalt: Data, label: UInt8, length: Int) -> Data {
        var x = [UInt8](masterSalt)
        x[7] ^= label                                   // the label sits in the byte just left of the 48-bit index (all zero here)
        let stream = AESCounterMode.apply(key: masterKey, iv: Data(x + [0, 0]), to: Data(count: length))
        return stream
    }

    /// Encrypts the payload of one RTP packet (12-byte header assumed to be followed directly by the payload, plus any
    /// CSRCs/extension the header declares) and appends the authentication tag. Sequence numbers must come in order.
    func protect(rtp packet: Data) -> Data? {
        guard packet.count >= 12 else { return nil }
        let b = [UInt8](packet.prefix(12))
        let csrc = Int(b[0] & 0x0F)
        var headerLength = 12 + 4 * csrc
        if b[0] & 0x10 != 0 {
            guard packet.count >= headerLength + 4 else { return nil }
            let extWords = Int(packet[packet.startIndex + headerLength + 2]) << 8 | Int(packet[packet.startIndex + headerLength + 3])
            headerLength += 4 + 4 * extWords
        }
        guard packet.count >= headerLength else { return nil }
        let sequence = UInt16(b[2]) << 8 | UInt16(b[3])
        let ssrc = UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11])
        if let last = lastSequence, sequence < last, last - sequence > 0x8000 { roc &+= 1 }   // wrapped
        lastSequence = sequence
        let index = UInt64(roc) << 16 | UInt64(sequence)

        var iv = [UInt8](rtpSalt + [0, 0])
        for i in 0..<4 { iv[4 + i] ^= UInt8(truncatingIfNeeded: ssrc >> UInt32(24 - 8 * i)) }
        for i in 0..<6 { iv[8 + i] ^= UInt8(truncatingIfNeeded: index >> UInt64(40 - 8 * i)) }
        let header = packet.prefix(headerLength)
        let encrypted = AESCounterMode.apply(key: rtpKey, iv: Data(iv), to: Data(packet.dropFirst(headerLength)))

        var authenticated = Data(header) + encrypted
        var rocBytes = Data()
        for i in 0..<4 { rocBytes.append(UInt8(truncatingIfNeeded: roc >> UInt32(24 - 8 * i))) }
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: authenticated + rocBytes, using: SymmetricKey(data: rtpAuth))
        authenticated.append(Data(mac.prefix(Self.tagLength)))
        return authenticated
    }

    /// Encrypts a (compound) RTCP packet: everything after the first 8 bytes is encrypted, then the E flag and 31-bit
    /// SRTCP index and the tag are appended.
    func protect(rtcp packet: Data) -> Data? {
        guard packet.count >= 8 else { return nil }
        let b = [UInt8](packet.prefix(8))
        let ssrc = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        let index = rtcpIndex & 0x7FFF_FFFF
        rtcpIndex = (rtcpIndex &+ 1) & 0x7FFF_FFFF

        var iv = [UInt8](rtcpSalt + [0, 0])
        for i in 0..<4 { iv[4 + i] ^= UInt8(truncatingIfNeeded: ssrc >> UInt32(24 - 8 * i)) }
        for i in 0..<4 { iv[10 + i] ^= UInt8(truncatingIfNeeded: index >> UInt32(24 - 8 * i)) }
        var out = Data(packet.prefix(8)) + AESCounterMode.apply(key: rtcpKey, iv: Data(iv), to: Data(packet.dropFirst(8)))
        let word = 0x8000_0000 | index
        for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: word >> UInt32(24 - 8 * i))) }
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: out, using: SymmetricKey(data: rtcpAuth))
        out.append(Data(mac.prefix(Self.tagLength)))
        return out
    }
}

/// Test-side counterpart: checks and decrypts what `SRTPSender` produced (also what a controller does with our stream).
final class SRTPReceiver {
    private let sender: SRTPSender   // shares the derived keys
    private let rtpKey: Data, rtpSalt: Data, rtpAuth: Data
    private let rtcpKey: Data, rtcpSalt: Data, rtcpAuth: Data

    init?(masterKey: Data, masterSalt: Data) {
        guard let s = SRTPSender(masterKey: masterKey, masterSalt: masterSalt) else { return nil }
        sender = s
        rtpKey = SRTPSender.derive(masterKey, masterSalt, label: 0, length: 16)
        rtpAuth = SRTPSender.derive(masterKey, masterSalt, label: 1, length: 20)
        rtpSalt = SRTPSender.derive(masterKey, masterSalt, label: 2, length: 14)
        rtcpKey = SRTPSender.derive(masterKey, masterSalt, label: 3, length: 16)
        rtcpAuth = SRTPSender.derive(masterKey, masterSalt, label: 4, length: 20)
        rtcpSalt = SRTPSender.derive(masterKey, masterSalt, label: 5, length: 14)
    }

    /// Verifies the tag and returns the plain RTP packet, or nil. `roc` is the rollover counter the sender is on.
    func unprotect(rtp packet: Data, roc: UInt32 = 0) -> Data? {
        let n = SRTPSender.tagLength
        guard packet.count >= 12 + n else { return nil }
        let body = Data(packet.dropLast(n)), tag = Data(packet.suffix(n))
        var rocBytes = Data()
        for i in 0..<4 { rocBytes.append(UInt8(truncatingIfNeeded: roc >> UInt32(24 - 8 * i))) }
        let expected = Data(HMAC<Insecure.SHA1>.authenticationCode(for: body + rocBytes, using: SymmetricKey(data: rtpAuth)).prefix(n))
        guard expected == tag else { return nil }
        let b = [UInt8](body.prefix(12))
        let headerLength = 12 + 4 * Int(b[0] & 0x0F)
        let sequence = UInt16(b[2]) << 8 | UInt16(b[3])
        let ssrc = UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11])
        let index = UInt64(roc) << 16 | UInt64(sequence)
        var iv = [UInt8](rtpSalt + [0, 0])
        for i in 0..<4 { iv[4 + i] ^= UInt8(truncatingIfNeeded: ssrc >> UInt32(24 - 8 * i)) }
        for i in 0..<6 { iv[8 + i] ^= UInt8(truncatingIfNeeded: index >> UInt64(40 - 8 * i)) }
        return Data(body.prefix(headerLength)) + AESCounterMode.apply(key: rtpKey, iv: Data(iv), to: Data(body.dropFirst(headerLength)))
    }

    func unprotect(rtcp packet: Data) -> Data? {
        let n = SRTPSender.tagLength
        guard packet.count >= 8 + 4 + n else { return nil }
        let body = Data(packet.dropLast(n)), tag = Data(packet.suffix(n))
        guard Data(HMAC<Insecure.SHA1>.authenticationCode(for: body, using: SymmetricKey(data: rtcpAuth)).prefix(n)) == tag else { return nil }
        let words = [UInt8](body.suffix(4))
        let index = (UInt32(words[0] & 0x7F) << 24) | UInt32(words[1]) << 16 | UInt32(words[2]) << 8 | UInt32(words[3])
        let b = [UInt8](body.prefix(8))
        let ssrc = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        var iv = [UInt8](rtcpSalt + [0, 0])
        for i in 0..<4 { iv[4 + i] ^= UInt8(truncatingIfNeeded: ssrc >> UInt32(24 - 8 * i)) }
        for i in 0..<4 { iv[10 + i] ^= UInt8(truncatingIfNeeded: index >> UInt32(24 - 8 * i)) }
        return Data(body.prefix(8)) + AESCounterMode.apply(key: rtcpKey, iv: Data(iv), to: Data(body.dropFirst(8).dropLast(4)))
    }
}

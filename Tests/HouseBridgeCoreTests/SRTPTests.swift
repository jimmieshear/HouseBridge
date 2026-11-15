import XCTest
@testable import HouseBridgeCore

private func hex(_ s: String) -> Data {
    let digits = Array(s.filter { !$0.isWhitespace })
    return Data(stride(from: 0, to: digits.count - 1, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
}
private func hexString(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

final class SRTPTests: XCTestCase {
    private let masterKey = hex("E1F97A0D3E018BE0D64FA32C06DE4139")
    private let masterSalt = hex("0EC675AD498AFEEBB6960B3AABE6")

    func testAESCounterModeMatchesNISTVector() {
        // NIST SP 800-38A F.5.1, CTR-AES128.Encrypt, first two blocks
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c"), counter = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let plain = hex("6bc1bee22e409f96e93d7e117393172a ae2d8a571e03ac9c9eb76fac45af8e51")
        XCTAssertEqual(hexString(AESCounterMode.apply(key: key, iv: counter, to: plain)),
                       "874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff")
    }

    func testKeyDerivationMatchesRFC3711AppendixB3() {
        XCTAssertEqual(hexString(SRTPSender.derive(masterKey, masterSalt, label: 0, length: 16)), "c61e7a93744f39ee10734afe3ff7a087")
        XCTAssertEqual(hexString(SRTPSender.derive(masterKey, masterSalt, label: 2, length: 14)), "30cbbc08863d8c85d49db34a9ae1")
        XCTAssertEqual(hexString(SRTPSender.derive(masterKey, masterSalt, label: 1, length: 20)), "cebe321f6ff7716b6fd4ab49af256a156d38baa4")
    }

    private func rtp(seq: UInt16, ssrc: UInt32 = 0xDEADBEEF, payload: Data) -> Data {
        Data([0x80, 0x60, UInt8(seq >> 8), UInt8(seq & 0xFF), 0, 0, 0x10, 0, UInt8(ssrc >> 24), UInt8((ssrc >> 16) & 0xFF), UInt8((ssrc >> 8) & 0xFF), UInt8(ssrc & 0xFF)]) + payload
    }

    func testRTPRoundTripAndTamperDetection() throws {
        let sender = try XCTUnwrap(SRTPSender(masterKey: masterKey, masterSalt: masterSalt))
        let receiver = try XCTUnwrap(SRTPReceiver(masterKey: masterKey, masterSalt: masterSalt))
        let payload = Data((0..<1200).map { UInt8($0 % 253) })
        let packet = rtp(seq: 7, payload: payload)
        let protected = try XCTUnwrap(sender.protect(rtp: packet))
        XCTAssertEqual(protected.count, packet.count + 10)
        XCTAssertEqual(protected.prefix(12), packet.prefix(12), "header stays in the clear")
        XCTAssertNotEqual(protected.dropFirst(12).prefix(1200), payload, "payload is encrypted")
        XCTAssertEqual(receiver.unprotect(rtp: protected), packet)
        var tampered = protected; tampered[20] ^= 1
        XCTAssertNil(receiver.unprotect(rtp: tampered))
        XCTAssertNil(try SRTPReceiver(masterKey: hex("00112233445566778899aabbccddeeff"), masterSalt: masterSalt)?.unprotect(rtp: protected), "wrong key")
    }

    func testRolloverCounterAdvancesWhenSequenceWraps() throws {
        let sender = try XCTUnwrap(SRTPSender(masterKey: masterKey, masterSalt: masterSalt))
        let receiver = try XCTUnwrap(SRTPReceiver(masterKey: masterKey, masterSalt: masterSalt))
        let body = Data(repeating: 9, count: 100)
        for seq in [UInt16(65534), 65535] {
            let p = rtp(seq: seq, payload: body)
            XCTAssertEqual(receiver.unprotect(rtp: try XCTUnwrap(sender.protect(rtp: p)), roc: 0), p)
        }
        let wrapped = rtp(seq: 0, payload: body)
        let out = try XCTUnwrap(sender.protect(rtp: wrapped))
        XCTAssertNil(receiver.unprotect(rtp: out, roc: 0), "needs the new rollover count")
        XCTAssertEqual(receiver.unprotect(rtp: out, roc: 1), wrapped)
    }

    func testRTCPRoundTripAndIndexIncrements() throws {
        let sender = try XCTUnwrap(SRTPSender(masterKey: masterKey, masterSalt: masterSalt))
        let receiver = try XCTUnwrap(SRTPReceiver(masterKey: masterKey, masterSalt: masterSalt))
        // a minimal sender report: V=2, RC=0, PT=200, length=6 words, SSRC, then 20 bytes of sender info
        let report = Data([0x80, 200, 0, 6, 0x11, 0x22, 0x33, 0x44]) + Data((0..<20).map(UInt8.init))
        let first = try XCTUnwrap(sender.protect(rtcp: report)), second = try XCTUnwrap(sender.protect(rtcp: report))
        XCTAssertEqual(first.count, report.count + 4 + 10)
        XCTAssertNotEqual(first, second, "the index changes the keystream")
        XCTAssertEqual(receiver.unprotect(rtcp: first), report)
        XCTAssertEqual(receiver.unprotect(rtcp: second), report)
    }

    func testRejectsBadKeyMaterial() {
        XCTAssertNil(SRTPSender(masterKey: Data(count: 15), masterSalt: masterSalt))
        XCTAssertNil(SRTPSender(masterKey: masterKey, masterSalt: Data(count: 13)))
    }
}

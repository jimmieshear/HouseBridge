import Foundation
import CryptoKit

enum HAPCrypto {
    struct Failure: Error {}

    static func hkdf(_ secret: Data, salt: String, info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(salt.utf8),
                               info: Data(info.utf8), outputByteCount: 32)
    }

    static func keyData(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    /// Pairing messages use a fixed ASCII label ("PS-Msg05", "PV-Msg02", ...) as the low 8 bytes of the nonce.
    static func labelNonce(_ label: String) -> Data { Data(repeating: 0, count: 4) + Data(label.utf8) }

    /// Session frames use a 64-bit little-endian message counter.
    static func counterNonce(_ counter: UInt64) -> Data {
        var data = Data(repeating: 0, count: 4)
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8(truncatingIfNeeded: counter >> UInt64(shift))) }
        return data
    }

    /// Returns ciphertext followed by the 16-byte tag.
    static func seal(_ plain: Data, key: SymmetricKey, nonce: Data, aad: Data = Data()) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: key, nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
        return box.ciphertext + box.tag
    }

    static func open(_ data: Data, key: SymmetricKey, nonce: Data, aad: Data = Data()) throws -> Data {
        guard data.count >= 16 else { throw Failure() }
        let split = data.index(data.endIndex, offsetBy: -16)
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce),
                                           ciphertext: data[data.startIndex..<split], tag: data[split...])
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    }
}

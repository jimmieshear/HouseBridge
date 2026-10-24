import Foundation
import CryptoKit

/// SRP-6a as HomeKit's Pair Setup uses it: 3072-bit group, SHA-512, username "Pair-Setup", password = setup code.
enum SRP {
    static let identity = "Pair-Setup"
    static let width = 384                       // bytes in the group modulus
    static let N = BigUInt(hex: primeHex)
    static let g = BigUInt(5)
    static let field = Montgomery(modulus: N)

    static func hash(_ parts: Data...) -> Data {
        var h = SHA512()
        for part in parts { h.update(data: part) }
        return Data(h.finalize())
    }

    /// k = H(N | PAD(g))
    static let k = BigUInt(bytes: hash(N.bytes(count: width), g.bytes(count: width)))

    static func x(salt: Data, password: String) -> BigUInt {
        BigUInt(bytes: hash(salt, hash(Data("\(identity):\(password)".utf8))))
    }

    static func randomBytes(_ count: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    static func scramble(_ A: Data, _ B: Data) -> BigUInt { BigUInt(bytes: hash(A, B)) }

    static func clientProof(A: Data, B: Data, salt: Data, key: Data) -> Data {
        let xorNg = Data(zip(hash(N.bytes()), hash(g.bytes())).map { $0 ^ $1 })
        return hash(xorNg, hash(Data(identity.utf8)), salt, A, B, key)
    }

    static func serverProof(A: Data, clientProof: Data, key: Data) -> Data { hash(A, clientProof, key) }

    /// The accessory side. One instance per pairing attempt.
    final class Server {
        let salt: Data
        /// B, padded to the full modulus width.
        let publicKey: Data
        private let verifier: BigUInt
        private let secret: BigUInt
        private var clientPublic: Data?
        private(set) var sessionKey: Data?

        init(password: String, salt: Data = SRP.randomBytes(16), secret: Data = SRP.randomBytes(32)) {
            self.salt = salt
            let b = BigUInt(bytes: secret)
            self.secret = b
            let v = SRP.field.pow(SRP.g, SRP.x(salt: salt, password: password))
            verifier = v
            let B = SRP.field.add(SRP.field.mul(SRP.k, v), SRP.field.pow(SRP.g, b))
            publicKey = B.bytes(count: SRP.width)
        }

        /// Returns false if the client's public value is invalid (zero or not below N).
        func setClientPublic(_ data: Data) -> Bool {
            let A = BigUInt(bytes: data)
            guard !A.isZero, A < SRP.N else { return false }
            let a = A.bytes(count: SRP.width)
            let u = SRP.scramble(a, publicKey)
            let S = SRP.field.pow(SRP.field.mul(A, SRP.field.pow(verifier, u)), secret)
            guard !S.isZero else { return false }
            clientPublic = a
            sessionKey = SRP.hash(S.bytes())
            return true
        }

        /// Checks the controller's proof; returns the accessory's proof (M2) when it is right.
        func verify(clientProof proof: Data) -> Data? {
            guard let A = clientPublic, let K = sessionKey else { return nil }
            guard SRP.clientProof(A: A, B: publicKey, salt: salt, key: K) == proof else { return nil }
            return SRP.serverProof(A: A, clientProof: proof, key: K)
        }
    }

    /// The controller side; the app never pairs *to* anything, so this exists to test the server against.
    struct Client {
        let password: String
        private let secret = BigUInt(bytes: SRP.randomBytes(32))
        var publicKey: Data { SRP.field.pow(SRP.g, secret).bytes(count: SRP.width) }

        init(password: String) { self.password = password }

        func session(salt: Data, serverPublic: Data) -> (key: Data, proof: Data) {
            let B = BigUInt(bytes: serverPublic)
            let u = SRP.scramble(publicKey, serverPublic)
            let x = SRP.x(salt: salt, password: password)
            let base = SRP.field.sub(B, SRP.field.mul(SRP.k, SRP.field.pow(SRP.g, x)))
            let S = SRP.field.pow(base, secret + u * x)
            let K = SRP.hash(S.bytes())
            return (K, SRP.clientProof(A: publicKey, B: serverPublic, salt: salt, key: K))
        }
    }
}

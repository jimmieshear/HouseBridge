import Foundation

/// Minimal unsigned big integer: just what SRP-6a over a 3072-bit group needs. CryptoKit has no big-number
/// support and HouseBridge takes no third-party packages, so modular arithmetic is done here (Montgomery form,
/// so nothing needs long division).
struct BigUInt: Equatable, Comparable, Sendable {
    /// Little-endian 32-bit limbs with no trailing zero limbs (zero is the empty array).
    private(set) var limbs: [UInt32]

    init() { limbs = [] }

    init(_ value: UInt64) {
        limbs = [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)]
        normalize()
    }

    /// Big-endian bytes.
    init(bytes: Data) {
        var out: [UInt32] = []
        var acc: UInt32 = 0
        var shift: UInt32 = 0
        for byte in bytes.reversed() {
            acc |= UInt32(byte) << shift
            shift += 8
            if shift == 32 { out.append(acc); acc = 0; shift = 0 }
        }
        if shift > 0 { out.append(acc) }
        limbs = out
        normalize()
    }

    init(hex: String) {
        let digits = hex.filter { $0.isHexDigit }
        let padded = digits.count % 2 == 0 ? digits : "0" + digits
        var data = Data()
        var index = padded.startIndex
        while index < padded.endIndex {
            let next = padded.index(index, offsetBy: 2)
            data.append(UInt8(padded[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes: data)
    }

    fileprivate init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    var isZero: Bool { limbs.isEmpty }

    var bitWidth: Int { limbs.isEmpty ? 0 : limbs.count * 32 - limbs[limbs.count - 1].leadingZeroBitCount }

    func bit(_ index: Int) -> Bool {
        let word = index / 32
        return word < limbs.count && (limbs[word] >> UInt32(index % 32)) & 1 == 1
    }

    /// Big-endian bytes, without leading zeros unless `count` pads it out.
    func bytes(count: Int = 0) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(limbs.count * 4)
        for limb in limbs.reversed() {
            out.append(UInt8(truncatingIfNeeded: limb >> 24))
            out.append(UInt8(truncatingIfNeeded: limb >> 16))
            out.append(UInt8(truncatingIfNeeded: limb >> 8))
            out.append(UInt8(truncatingIfNeeded: limb))
        }
        while out.first == 0 { out.removeFirst() }
        if out.count < count { out.insert(contentsOf: [UInt8](repeating: 0, count: count - out.count), at: 0) }
        return Data(out)
    }

    static func < (a: BigUInt, b: BigUInt) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for i in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[i] != b.limbs[i] {
            return a.limbs[i] < b.limbs[i]
        }
        return false
    }

    static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        var out: [UInt32] = []
        out.reserveCapacity(max(a.limbs.count, b.limbs.count) + 1)
        var carry: UInt64 = 0
        for i in 0..<max(a.limbs.count, b.limbs.count) {
            let sum = UInt64(i < a.limbs.count ? a.limbs[i] : 0) + UInt64(i < b.limbs.count ? b.limbs[i] : 0) + carry
            out.append(UInt32(truncatingIfNeeded: sum))
            carry = sum >> 32
        }
        if carry > 0 { out.append(UInt32(carry)) }
        return BigUInt(limbs: out)
    }

    /// Requires `a >= b`.
    static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        precondition(a >= b, "BigUInt subtraction underflow")
        var out = a.limbs
        var borrow: Int64 = 0
        for i in 0..<out.count {
            var diff = Int64(out[i]) - borrow - Int64(i < b.limbs.count ? b.limbs[i] : 0)
            if diff < 0 { diff += 1 << 32; borrow = 1 } else { borrow = 0 }
            out[i] = UInt32(truncatingIfNeeded: diff)
        }
        return BigUInt(limbs: out)
    }

    static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        if a.isZero || b.isZero { return BigUInt() }
        var out = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            let ai = UInt64(a.limbs[i])
            for j in 0..<b.limbs.count {
                let t = ai * UInt64(b.limbs[j]) + UInt64(out[i + j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
            }
            out[i + b.limbs.count] = UInt32(carry)
        }
        return BigUInt(limbs: out)
    }

    fileprivate func padded(to count: Int) -> [UInt32] {
        limbs + [UInt32](repeating: 0, count: count - limbs.count)
    }
}

/// Arithmetic modulo a fixed odd modulus. Operands must already be reduced (`< modulus`).
struct Montgomery: Sendable {
    let modulus: BigUInt
    private let m: [UInt32]
    private let size: Int
    private let nPrime: UInt32      // -modulus^-1 mod 2^32
    private let r2: [UInt32]        // 2^(64*size) mod modulus

    init(modulus: BigUInt) {
        precondition(modulus.limbs.first.map { $0 & 1 == 1 } ?? false, "modulus must be odd")
        precondition(modulus.limbs.count > 0 && modulus > BigUInt(1))
        self.modulus = modulus
        size = modulus.limbs.count
        m = modulus.limbs
        var inverse: UInt32 = 1
        for _ in 0..<5 { inverse = inverse &* (2 &- modulus.limbs[0] &* inverse) }   // Newton: doubles the correct bits each step
        nPrime = 0 &- inverse
        var x = BigUInt(1)
        for _ in 0..<(64 * modulus.limbs.count) {
            x = x + x
            if x >= modulus { x = x - modulus }
        }
        r2 = x.padded(to: modulus.limbs.count)
    }

    /// a * b * R^-1 mod N (CIOS Montgomery multiplication).
    private func montMul(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        let n = size
        let nPrime = self.nPrime
        var t = [UInt32](repeating: 0, count: n + 2)
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                m.withUnsafeBufferPointer { m in
                    t.withUnsafeMutableBufferPointer { t in
                        for i in 0..<n {
                            var carry: UInt64 = 0
                            let ai = UInt64(a[i])
                            for j in 0..<n {
                                let s = UInt64(t[j]) + ai * UInt64(b[j]) + carry
                                t[j] = UInt32(truncatingIfNeeded: s)
                                carry = s >> 32
                            }
                            var s = UInt64(t[n]) + carry
                            t[n] = UInt32(truncatingIfNeeded: s)
                            t[n + 1] = UInt32(truncatingIfNeeded: s >> 32)

                            let q = UInt64(t[0] &* nPrime)
                            s = UInt64(t[0]) + q * UInt64(m[0])
                            carry = s >> 32
                            for j in 1..<n {
                                s = UInt64(t[j]) + q * UInt64(m[j]) + carry
                                t[j - 1] = UInt32(truncatingIfNeeded: s)
                                carry = s >> 32
                            }
                            s = UInt64(t[n]) + carry
                            t[n - 1] = UInt32(truncatingIfNeeded: s)
                            t[n] = t[n + 1] &+ UInt32(truncatingIfNeeded: s >> 32)
                        }
                    }
                }
            }
        }
        var result = Array(t[0..<n])
        var needsSubtract = t[n] != 0
        if !needsSubtract {
            needsSubtract = true   // result >= modulus ?
            for i in stride(from: n - 1, through: 0, by: -1) where result[i] != m[i] {
                needsSubtract = result[i] > m[i]
                break
            }
        }
        if needsSubtract {
            var borrow: Int64 = 0
            for i in 0..<n {
                var diff = Int64(result[i]) - Int64(m[i]) - borrow
                if diff < 0 { diff += 1 << 32; borrow = 1 } else { borrow = 0 }
                result[i] = UInt32(truncatingIfNeeded: diff)
            }
        }
        return result
    }

    func mul(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        let aR = montMul(a.padded(to: size), r2)        // a * R
        return BigUInt(limbs: montMul(aR, b.padded(to: size)))
    }

    func add(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        let sum = a + b
        return sum >= modulus ? sum - modulus : sum
    }

    func sub(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        a >= b ? a - b : a + modulus - b
    }

    func pow(_ base: BigUInt, _ exponent: BigUInt) -> BigUInt {
        let baseR = montMul(base.padded(to: size), r2)
        var acc = montMul(BigUInt(1).padded(to: size), r2)   // 1 in Montgomery form
        for i in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
            acc = montMul(acc, acc)
            if exponent.bit(i) { acc = montMul(acc, baseR) }
        }
        return BigUInt(limbs: montMul(acc, BigUInt(1).padded(to: size)))
    }
}

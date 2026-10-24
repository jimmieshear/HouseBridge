import Foundation
import CryptoKit

struct HAPPairing: Codable, Equatable {
    var id: String
    var publicKey: Data
    var admin: Bool
}

/// What the bridge remembers about a Protect device, so HomeKit still sees it while the console is unreachable.
struct HAPDevice: Codable, Equatable {
    var id: String
    var name: String
    var model: String
    var kind: String
    var provides: [String]
}

struct HAPState: Codable {
    var deviceID: String
    var signingKey: Data
    var setupCode: String
    var setupID: String
    var configNumber: Int = 1
    var layoutHash: String = ""
    var pairings: [HAPPairing] = []
    /// Accessory ids are never reused, so removing and re-adding a camera does not resurrect old Home.app settings.
    var aids: [String: Int] = [:]
    var nextAid: Int = 2
    var devices: [HAPDevice] = []
}

/// The bridge's identity and pairings, persisted in `homekit.json` (0600). Losing it means re-pairing in Home.app.
final class HAPStore {
    let url: URL
    private(set) var state: HAPState

    init(url: URL, setupCode: String? = nil) {
        self.url = url
        var changed = false
        if let data = try? Data(contentsOf: url), let loaded = try? JSONDecoder().decode(HAPState.self, from: data) {
            state = loaded
        } else {
            changed = true
            state = HAPState(deviceID: HAPStore.randomDeviceID(),
                             signingKey: Curve25519.Signing.PrivateKey().rawRepresentation,
                             setupCode: HAPStore.generateSetupCode(),
                             setupID: HAPStore.randomSetupID())
        }
        if let setupCode, HAPStore.isValidSetupCode(setupCode), setupCode != state.setupCode {
            state.setupCode = setupCode
            changed = true
        }
        if changed { save() }
    }

    var isPaired: Bool { !state.pairings.isEmpty }

    var signingKey: Curve25519.Signing.PrivateKey {
        // The key is generated here and only ever written back by save(); a corrupt file is replaced rather than trusted.
        (try? Curve25519.Signing.PrivateKey(rawRepresentation: state.signingKey)) ?? Curve25519.Signing.PrivateKey()
    }

    func mutate(_ change: (inout HAPState) -> Void) {
        change(&state)
        save()
    }

    func pairing(id: String) -> HAPPairing? { state.pairings.first { $0.id == id } }

    func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Identity helpers

    static func randomDeviceID() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE   // locally administered, unicast
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func randomSetupID() -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return String((0..<4).map { _ in alphabet.randomElement()! })
    }

    /// HomeKit rejects codes that are trivially guessable.
    static let forbiddenCodes: Set<String> = Set((0...9).map { String(repeating: "\($0)", count: 8) } + ["12345678", "87654321"])

    static func isValidSetupCode(_ code: String) -> Bool {
        let parts = code.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 3, parts[1].count == 2, parts[2].count == 3 else { return false }
        let digits = parts.joined()
        return digits.count == 8 && digits.allSatisfy { $0.isASCII && $0.isNumber } && !forbiddenCodes.contains(digits)
    }

    static func generateSetupCode() -> String {
        while true {
            let digits = (0..<8).map { _ in String(Int.random(in: 0...9)) }.joined()
            if forbiddenCodes.contains(digits) { continue }
            return "\(digits.prefix(3))-\(digits.dropFirst(3).prefix(2))-\(digits.suffix(3))"
        }
    }

    /// The `X-HM://` string behind the QR code Home.app scans (category 2 = bridge, IP transport).
    var setupURI: String {
        let code = UInt64(state.setupCode.filter(\.isNumber)) ?? 0
        let payload = (UInt64(HAPStore.categoryBridge) << 31) | (2 << 27) | code
        let encoded = String(payload, radix: 36, uppercase: true)
        return "X-HM://" + String(repeating: "0", count: max(0, 9 - encoded.count)) + encoded + state.setupID
    }

    /// `sh` in the Bonjour record: lets Home.app match a scanned QR code to this advertisement.
    var setupHash: String {
        Data(SHA512.hash(data: Data((state.setupID + state.deviceID).utf8)).prefix(4)).base64EncodedString()
    }

    static let categoryBridge = 2
}

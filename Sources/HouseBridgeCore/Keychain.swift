import Foundation
import Security

/// Stores the UniFi password in the macOS login keychain (one item per user@host).
///
/// The item is created readable by any application running as the same user, so the menu bar app and
/// `housebridgectl` can both use it without repeated "allow access" prompts (ad-hoc signed builds change
/// identity on every rebuild, which would otherwise re-trigger them). It's still encrypted at rest and
/// far better than a password in a text file.
public enum Keychain {
    public static let defaultService = "housebridge.unifi"

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            "Keychain error \(status): \((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown")"
        }
    }

    static func account(host: String, username: String) -> String { "\(username)@\(host)" }

    public static func readPassword(host: String, username: String, service: String = defaultService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host, username: username),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func savePassword(_ password: String, host: String, username: String,
                                    service: String = defaultService) throws {
        try deletePassword(host: host, username: username, service: service)

        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host, username: username),
            kSecAttrLabel as String: "HouseBridge UniFi (\(account(host: host, username: username)))",
            kSecValueData as String: Data(password.utf8),
        ]
        if let access = openAccess() { attributes[kSecAttrAccess as String] = access }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// An access object with no trusted-application list = any application of this user may read the item without
    /// a prompt. Apple deprecated the file-based keychain API this comes from but offers no replacement that works
    /// for unsigned/ad-hoc builds (the data-protection keychain needs a provisioning profile), so it is looked up at
    /// runtime to keep the compiler from warning about a deliberate choice. If it ever disappears, the item is
    /// still stored — it just becomes private to the app that created it.
    private static func openAccess() -> SecAccess? {
        typealias Create = @convention(c) (CFString, CFArray?, UnsafeMutablePointer<SecAccess?>?) -> OSStatus
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecAccessCreate") else { return nil }   // RTLD_DEFAULT
        var access: SecAccess?
        let status = unsafeBitCast(symbol, to: Create.self)("HouseBridge UniFi password" as CFString, nil, &access)
        return status == errSecSuccess ? access : nil
    }

    @discardableResult
    public static func deletePassword(host: String, username: String, service: String = defaultService) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host, username: username),
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return true
    }
}

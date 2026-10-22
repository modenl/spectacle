import Foundation
import Security

/// Generic-password items in the user's login keychain. Values are never logged.
///
/// Each value is read from the keychain once per launch and then kept in memory. Every keychain read by a build whose
/// signature is not yet on the item's access list makes macOS ask for the login password, and `hasAPIKey` is checked
/// on every app switch, so reading through each time meant a stream of password dialogs.
public enum KeychainStore {
    public static let service = "xyz.alvumo.ModernSpectacle"
    public static let apiKeyAccount = "anthropic-api-key"
    public static let jevKeyAccount = "typesafe-api-key"

    private static let lock = NSLock()
    /// account -> value; a stored nil means "read, not present".
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    public struct Error: Swift.Error {
        public let status: OSStatus
    }

    public static func string(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[account] { return cached }
        let value = readFromKeychain(account)
        cache[account] = .some(value)
        return value
    }

    private static func readFromKeychain(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Passing nil or an empty string removes the item.
    public static func set(_ value: String?, for account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lock.lock()
        defer { lock.unlock() }
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw Error(status: status)
            }
            cache[account] = .some(nil)
            return
        }

        let data = Data(trimmed.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw Error(status: status)
        }
        cache[account] = .some(trimmed)
    }

    public static var hasAPIKey: Bool {
        string(for: apiKeyAccount)?.isEmpty == false
    }

    public static var hasJevKey: Bool {
        string(for: jevKeyAccount)?.isEmpty == false
    }
}

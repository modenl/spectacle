import Foundation
import Security

/// The Jev key, in the user's login keychain. Never logged. Read from the keychain once per launch and then kept in
/// memory: each keychain read by a build the item does not know yet makes macOS ask for the login password.
public enum KeychainStore {
    private static let service = "xyz.alvumo.ModernSpectacle"
    private static let account = "typesafe-api-key"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String?? = nil

    public struct Error: Swift.Error {
        public let status: OSStatus
    }

    public static var jevKey: String? {
        lock.withLock {
            if let cached { return cached }
            let value = read()
            cached = .some(value)
            return value
        }
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Nil or an empty string removes the key.
    public static func setJevKey(_ value: String?) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try lock.withLock {
            guard !trimmed.isEmpty else {
                let status = SecItemDelete(base as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw Error(status: status) }
                cached = .some(nil)
                return
            }
            let data = Data(trimmed.utf8)
            var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var add = base
                add[kSecValueData as String] = data
                status = SecItemAdd(add as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw Error(status: status) }
            cached = .some(trimmed)
        }
    }
}

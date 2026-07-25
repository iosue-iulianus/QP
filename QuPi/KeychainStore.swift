import Foundation
import Security

/// Minimal Keychain wrapper for account tokens. Values are stored as generic
/// passwords under the app's service name.
enum KeychainStore {
    private static let service = "QuPi"

    static func string(for key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Passing nil or an empty string removes the item.
    static func set(_ value: String?, for key: String) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = baseQuery(for: key)
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Reads a secret, migrating it out of UserDefaults if an older build
    /// stored it there.
    static func stringMigratingFromDefaults(for key: String) -> String? {
        if let existing = string(for: key) { return existing }
        guard let legacy = UserDefaults.standard.string(forKey: key), !legacy.isEmpty else {
            return nil
        }
        set(legacy, for: key)
        UserDefaults.standard.removeObject(forKey: key)
        return legacy
    }

    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

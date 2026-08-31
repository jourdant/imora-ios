import Foundation
import Security

/// minimal keychain wrapper for the session token. items are written into the
/// app group's access group so the share extension can authenticate with the
/// same session; reads stay group-less, which searches every group this
/// process can see and also finds tokens written before the group existed.
enum KeychainStore {
    private static let service = "app.imora.credentials"

    private static var accessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "IMORAAppGroup") as? String
    }

    static func set(_ value: String, for key: String) {
        // delete first: an update could match a copy in another group and
        // leave a stale twin behind for reads to trip on.
        delete(key)
        var insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
        ]
        if let accessGroup {
            insert[kSecAttrAccessGroup as String] = accessGroup
        }
        let status = SecItemAdd(insert as CFDictionary, nil)
        // sharing is best effort: on a build whose provisioning rejects the
        // group, a private token still beats losing the session.
        if status == errSecMissingEntitlement, insert.removeValue(forKey: kSecAttrAccessGroup as String) != nil {
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

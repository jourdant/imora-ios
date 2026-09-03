import Foundation
import Security

/// minimal keychain wrapper for the session token. items are written into the
/// app group's access group so the share extension can authenticate with the
/// same session; reads stay group-less, which searches every group this
/// process can see and also finds tokens written before the group existed.
enum KeychainStore {
    enum ReadResult {
        case value(String)
        case missing
        case unavailable(OSStatus)
    }

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
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
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

    static func get(_ key: String) -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8)
            else { return .missing }
            return .value(value)
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed:
            return .unavailable(status)
        default:
            return .missing
        }
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

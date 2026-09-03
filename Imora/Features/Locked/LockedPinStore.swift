import Foundation
import LocalAuthentication
import Security

/// keychain item holding the locked folder pin behind the device's biometry,
/// so face id can replay it to the server. written without the app group on
/// purpose: the share extension has no business reading it. the access
/// control ties the item to the current biometric enrollment, which is what
/// makes a changed face id set fall back to typing the pin.
nonisolated enum LockedPinStore {
    enum Failure: Error {
        case cancelled
        case unavailable
    }

    private static let service = "app.imora.lockedFolder"

    static func store(_ pin: String, account: String) throws {
        delete(account: account)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            &error
        ) else { throw Failure.unavailable }
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: Data(pin.utf8),
        ]
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            throw Failure.unavailable
        }
    }

    /// presence without a prompt: a context that refuses interaction makes a
    /// protected item answer interaction-not-allowed, which is it existing.
    static func exists(account: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// one biometric prompt both authenticates and yields the pin. blocks the
    /// calling thread while the prompt is up, hence off the main actor.
    @concurrent
    static func read(account: String, reason: String) async throws -> String {
        let context = LAContext()
        context.localizedReason = reason
        context.localizedCancelTitle = "Enter PIN"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let pin = String(data: data, encoding: .utf8) else {
                throw Failure.unavailable
            }
            return pin
        case errSecUserCanceled:
            throw Failure.cancelled
        default:
            throw Failure.unavailable
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// nil when the device has no usable biometry.
    static var biometryType: LABiometryType? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return nil
        }
        return context.biometryType
    }

    static var biometryName: String {
        switch biometryType {
        case .faceID: "Face ID"
        case .opticID: "Optic ID"
        case .touchID: "Touch ID"
        default: "Biometrics"
        }
    }
}

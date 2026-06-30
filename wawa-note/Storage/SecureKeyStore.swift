import Foundation
import Security

// Related JIRA: KAN-11, KAN-117

enum SecureKeyStoreError: Error {
    case saveFailed
    case loadFailed
    case deleteFailed
    case itemNotFound
}

/// Controls when a Keychain item is accessible.
/// - `whenUnlocked`: Only when device is unlocked. Use for keys that don't need background access (chat, export).
/// - `afterFirstUnlock`: After first unlock until reboot. Use for keys needed by background pipelines (transcription, auto-analysis).
enum KeychainAccessLevel {
    case whenUnlocked
    case afterFirstUnlock

    var secAttr: CFString {
        switch self {
        case .whenUnlocked: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .afterFirstUnlock: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }
}

final class SecureKeyStore: @unchecked Sendable {
    private let serviceName: String

    init(serviceName: String = "com.wawa-note.keychain") {
        self.serviceName = serviceName
    }

    // MARK: - API Key

    /// Save an API key to the Keychain.
    /// - Parameter accessLevel: Controls key accessibility. Default `.afterFirstUnlock` for background pipeline access.
    ///   Use `.whenUnlocked` for keys that don't need background access (e.g., chat-only providers).
    func saveAPIKey(_ key: String, for identifier: String, accessLevel: KeychainAccessLevel = .afterFirstUnlock) throws {
        guard let data = key.data(using: .utf8) else {
            throw SecureKeyStoreError.saveFailed
        }

        try deleteAPIKey(for: identifier)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: identifier,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessLevel.secAttr,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureKeyStoreError.saveFailed
        }
    }

    func loadAPIKey(for identifier: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            if status == errSecItemNotFound {
                throw SecureKeyStoreError.itemNotFound
            }
            throw SecureKeyStoreError.loadFailed
        }

        return key
    }

    func deleteAPIKey(for identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: identifier,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureKeyStoreError.deleteFailed
        }
    }
}

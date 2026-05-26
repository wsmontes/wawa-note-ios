import Foundation
import Security

enum SecureKeyStoreError: Error {
    case saveFailed
    case loadFailed
    case deleteFailed
    case itemNotFound
}

final class SecureKeyStore: @unchecked Sendable {
    private let serviceName: String

    init(serviceName: String = "com.wawa-note.keychain") {
        self.serviceName = serviceName
    }

    // MARK: - API Key

    func saveAPIKey(_ key: String, for identifier: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw SecureKeyStoreError.saveFailed
        }

        try deleteAPIKey(for: identifier)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: identifier,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
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
            kSecMatchLimit as String: kSecMatchLimitOne
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
            kSecAttrAccount as String: identifier
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureKeyStoreError.deleteFailed
        }
    }
}

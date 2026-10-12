import Foundation
import Security

// MARK: - Keychain storage for the bearer token (never in UserDefaults/logs)

public final class KeychainTokenStore {
    public enum StoreError: Error {
        case unexpected(OSStatus)
    }

    private let service: String
    private let account: String

    public init(service: String = "com.example.opendictation", account: String = "transcription-bearer-token") {
        self.service = service
        self.account = account
    }

    public func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func saveToken(_ token: String?) throws {
        if let token, !token.isEmpty {
            let data = Data(token.utf8)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            if status == errSecSuccess {
                let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                if updateStatus != errSecSuccess { throw StoreError.unexpected(updateStatus) }
            } else if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                // This item is only usable while the device is unlocked.
                add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                let addStatus = SecItemAdd(add as CFDictionary, nil)
                if addStatus != errSecSuccess { throw StoreError.unexpected(addStatus) }
            } else {
                throw StoreError.unexpected(status)
            }
        } else {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw StoreError.unexpected(status)
            }
        }
    }
}

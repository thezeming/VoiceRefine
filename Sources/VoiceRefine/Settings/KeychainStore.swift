import Foundation
import Security

extension Notification.Name {
    /// Posted by `KeychainStore` when an entry is deleted (singly or via `deleteAll`).
    /// Fields that mirror Keychain content should re-read on this notification.
    static let voiceRefineKeychainDidChange = Notification.Name("VoiceRefineKeychainDidChange")
}

enum KeychainError: Error, CustomStringConvertible {
    case unexpectedStatus(OSStatus)

    var description: String {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain error \(status): \(message)"
        }
    }
}

final class KeychainStore: @unchecked Sendable {
    // @unchecked Sendable: holds only a let String; all Keychain APIs are
    // thread-safe by design — no mutable instance state after init.
    static let shared = KeychainStore()

    private let service: String

    private init() {
        self.service = Bundle.main.bundleIdentifier ?? "com.voicerefine.VoiceRefine"
    }

    func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    func set(_ value: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery.merge(attributes) { $1 }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    func delete(account: String) throws {
        try deleteWithoutNotifying(account: account)
        NotificationCenter.default.post(name: .voiceRefineKeychainDidChange, object: self)
    }

    func deleteAll(withPrefix prefix: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess, let entries = items as? [[String: Any]] else {
            if status == errSecItemNotFound {
                NotificationCenter.default.post(name: .voiceRefineKeychainDidChange, object: self)
                return
            }
            throw KeychainError.unexpectedStatus(status)
        }
        // Delete silently in the loop, then post a single change
        // notification — listeners don't care *which* account was
        // cleared, just that the set changed.
        for entry in entries {
            if let account = entry[kSecAttrAccount as String] as? String,
               account.hasPrefix(prefix) {
                try deleteWithoutNotifying(account: account)
            }
        }
        NotificationCenter.default.post(name: .voiceRefineKeychainDidChange, object: self)
    }

    /// Does the Keychain delete without posting `.voiceRefineKeychainDidChange`.
    /// Public `delete` / `deleteAll` wrap this so callers always see a
    /// notification at the right time without a post-per-item flood.
    private func deleteWithoutNotifying(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

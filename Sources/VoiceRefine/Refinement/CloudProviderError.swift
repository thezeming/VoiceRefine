import Foundation

// MARK: - CloudProviderError

/// Marker protocol for all cloud-provider error enums. Conforming types
/// must also be `CustomStringConvertible` so error toasts always have a
/// readable message without extra casting.
protocol CloudProviderError: Error, CustomStringConvertible {}

// MARK: - APIKeyed

/// Adopted by provider types whose ID exposes a Keychain account for
/// a mandatory API key. Provides a single `requireAPIKey()` helper that
/// reads from `KeychainStore` and throws a caller-supplied error when the
/// key is absent or empty — replacing the guard/get boilerplate in each
/// provider's `refine` / `transcribe` method.
protocol APIKeyed {
    /// The Keychain account string for this provider's API key.
    static var apiKeyAccount: String { get }

    /// The error to throw when the key is missing or empty.
    static var missingAPIKeyError: any Error { get }
}

extension APIKeyed {
    /// Reads the API key from Keychain and throws `missingAPIKeyError`
    /// when it is absent or empty.
    static func requireAPIKey() throws -> String {
        let key = KeychainStore.shared.get(account: apiKeyAccount) ?? ""
        guard !key.isEmpty else { throw missingAPIKeyError }
        return key
    }
}

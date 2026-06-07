import Foundation
import Security

/// Thin wrapper over the macOS Security framework for storing secret values.
///
/// Design notes (see plan `26.06.05 - SwiftMaestro Secrets Management`):
/// - Uses the **legacy login keychain** (we deliberately do NOT set
///   `kSecUseDataProtectionKeychain`) so the `ai-context-bridge` `/usr/bin/security`
///   CLI reads the exact same items this app writes.
/// - Synced secrets use `kSecAttrSynchronizable = true` + `AfterFirstUnlock`, which
///   lets iCloud Keychain replicate them across the user's signed-in Macs
///   (end-to-end encrypted by Apple). Machine-local secrets use
///   `synchronizable = false` + `AfterFirstUnlockThisDeviceOnly`.
/// - Only raw secret VALUES live here. Non-secret metadata lives in
///   `secrets-index.json` (see `SecretsStore`).
enum KeychainService {
    /// Shared keychain service name. Matches the convention already read by the
    /// ai-context-bridge (`server.js`), so secrets are usable cross-agent.
    static let service = "com.woodseedigi.SwiftMaestro"

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown"
                return "Keychain error \(status): \(message)"
            case .encodingFailed:
                return "Failed to encode secret value as UTF-8."
            }
        }
    }

    // MARK: - Write

    /// Store (or replace) a secret value for `account`.
    /// - Parameter synchronizable: when true the item is eligible for iCloud Keychain sync.
    static func store(account: String, value: String, synchronizable: Bool) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encodingFailed }

        // Remove any existing item (matching either sync state) first for idempotency.
        try? delete(account: account)

        let accessible: CFString = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
            kSecAttrAccessible as String: accessible,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    // MARK: - Read

    /// Read a secret value for `account`. Matches both synced and local items.
    static func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    // MARK: - Delete

    /// Delete the secret for `account` (matching either sync state).
    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Enumerate

    /// List all account names under `service` that start with `prefix`.
    static func accounts(withPrefix prefix: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let items = result as? [[String: Any]] else { return [] }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix(prefix) }
    }
}

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

    /// The keychain access group declared in the app's entitlements.
    /// For signed builds this is required on every SecItem query when the
    /// `com.apple.security.cs.keychain-access-groups` entitlement is present;
    /// omitting it causes errSecMissingEntitlement (-34018). For unsigned local
    /// builds the entitlement is absent, so no access group is added.
    private static var accessGroup: String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        guard let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.cs.keychain-access-groups" as CFString,
            nil
        ) else { return nil }
        guard let groups = value as? [String], let first = groups.first else { return nil }
        return first
    }

    private static func queryWithAccessGroup(_ base: [String: Any]) -> [String: Any] {
        var query = base
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    // MARK: - UI suppression

    /// The legacy login keychain does not always honor `kSecUseAuthenticationUIFail`.
    /// For background reads we temporarily disable keychain user-interaction prompts
    /// process-wide, then restore the previous (default: enabled) state.
    // Access to the depth counter is protected by uiLock; marking unsafe avoids
    // Swift 6 strict-concurrency warnings for process-wide keychain UI state.
    // (`uiLock` itself needs no `nonisolated(unsafe)` — `NSLock` is already
    // `Sendable`, so the qualifier there was redundant.)
    private static let uiLock = NSLock()
    nonisolated(unsafe) private static var uiDisableDepth = 0

    private static func performWithoutKeychainUI<T>(_ action: () throws -> T) rethrows -> T {
        uiLock.lock()
        if uiDisableDepth == 0 {
            SecKeychainSetUserInteractionAllowed(false)
        }
        uiDisableDepth += 1
        uiLock.unlock()

        defer {
            uiLock.lock()
            uiDisableDepth -= 1
            if uiDisableDepth == 0 {
                SecKeychainSetUserInteractionAllowed(true)
            }
            uiLock.unlock()
        }

        return try action()
    }

    // MARK: - Write

    /// Store (or replace) a secret value for `account`.
    /// - Parameter synchronizable: when true the item is eligible for iCloud Keychain sync.
    static func store(account: String, value: String, synchronizable: Bool) throws {
        try _store(account: account, value: value, synchronizable: synchronizable)
    }

    private static func _store(account: String, value: String, synchronizable: Bool, isRetry: Bool = false) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encodingFailed }

        let accessible: CFString = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        // Update-in-place first: SecItemUpdate preserves the item's access
        // control list. The previous delete+add destroyed every "Always
        // Allow" grant the item had accumulated — including grants made to
        // OTHER identities sharing this login keychain (the Developer-ID DMG,
        // /usr/bin/security, older ad-hoc builds) — so two identities that
        // both write the same account (e.g. DMG and Xcode Debug both
        // refreshing plugin tokens) ping-ponged password prompts forever.
        let findQuery = queryWithAccessGroup([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ])
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
        let updateStatus = SecItemUpdate(findQuery as CFDictionary, updates as CFDictionary)

        if updateStatus == errSecItemNotFound {
            let query = queryWithAccessGroup([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
                kSecAttrAccessible as String: accessible,
            ])
            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecMissingEntitlement && synchronizable && !isRetry {
                // Some signed builds (Xcode local development, certain Developer-ID
                // configurations) do not provide a valid keychain access group, so
                // iCloud-synced writes fail with -34018. Fall back to a local-only
                // item so the secret can still be saved on this Mac.
                try _store(account: account, value: value, synchronizable: false, isRetry: true)
                return
            }
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    // MARK: - Read

    /// Read a secret value for `account`. Matches both synced and local items.
    /// - Parameter allowUI: when false, adds `kSecUseAuthenticationUIFail` and
    ///   temporarily disables keychain user interaction so the call returns nil
    ///   instead of showing a keychain password dialog. Use false for background
    ///   reads (e.g. redaction during memory writes) where a modal would block
    ///   the agent.
    static func read(account: String, allowUI: Bool = true) throws -> String? {
        try read(service: service, account: account, allowUI: allowUI)
    }

    /// Read a secret value for an arbitrary keychain service/account.
    /// This lets SwiftMaestro read secrets created by other scripts (e.g.
    /// `upload-release.sh`) without requiring them to use the app's bundle
    /// service name.
    static func read(service customService: String, account: String, allowUI: Bool = true) throws -> String? {
        guard !allowUI else {
            return try _read(service: customService, account: account, allowUI: true)
        }
        return try performWithoutKeychainUI {
            try _read(service: customService, account: account, allowUI: false)
        }
    }

    private static func _read(service customService: String, account: String, allowUI: Bool, triedLocalFallback: Bool = false) throws -> String? {
        var query = queryWithAccessGroup([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: customService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: triedLocalFallback ? false : kSecAttrSynchronizableAny,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
        if !allowUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        // -34018 (errSecMissingEntitlement / errSecNotAvailable) can occur when
        // reading a synced item from a build without the keychain access group entitlement.
        // Fall back to reading the local-only copy (synchronizable=false).
        if status == errSecMissingEntitlement && !triedLocalFallback {
            return try _read(service: customService, account: account, allowUI: allowUI, triedLocalFallback: true)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    // MARK: - Delete

    /// Delete the secret for `account` (matching either sync state).
    static func delete(account: String) throws {
        let query = queryWithAccessGroup([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ])
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Keychain state

    /// Check whether the user's default (login) keychain is currently unlocked.
    /// Used as a guard to avoid prompting for the keychain password when the
    /// keychain is locked; callers can skip reads instead of showing a dialog.
    static func isDefaultKeychainUnlocked() -> Bool {
        var keychain: SecKeychain?
        let copyStatus = SecKeychainCopyDefault(&keychain)
        guard copyStatus == errSecSuccess, let keychain else { return false }
        var state: UInt32 = 0
        let status = SecKeychainGetStatus(keychain, &state)
        guard status == errSecSuccess else { return false }
        return (state & UInt32(kSecUnlockStateStatus)) != 0
    }

    // MARK: - Enumerate

    /// List all account names under `service` that start with `prefix`.
    /// - Parameter allowUI: when false, suppresses keychain password dialogs.
    static func accounts(withPrefix prefix: String, allowUI: Bool = true) throws -> [String] {
        // If the login keychain is locked, skip enumeration to avoid prompting.
        guard isDefaultKeychainUnlocked() else { return [] }

        guard !allowUI else {
            return try _accounts(withPrefix: prefix, allowUI: true)
        }
        return try performWithoutKeychainUI {
            try _accounts(withPrefix: prefix, allowUI: false)
        }
    }

    private static func _accounts(withPrefix prefix: String, allowUI: Bool) throws -> [String] {
        var query = queryWithAccessGroup([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ])
        if !allowUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let items = result as? [[String: Any]] else { return [] }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix(prefix) }
    }
}

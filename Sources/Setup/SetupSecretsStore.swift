import Foundation
import Security

/// Writes secrets directly into the main SwiftMaestro app's Keychain so that
/// credentials entered during Setup are usable by SwiftMaestro on first launch.
///
/// This is a minimal, standalone copy of the main app's secrets-onboarding path:
/// values go to the login Keychain under `com.woodseedigi.SwiftMaestro`, and
/// non-secret metadata is merged into the main app's `secrets-index.json`.
enum SetupSecretsStore {

    static let service = "com.woodseedigi.SwiftMaestro"
    static let referencePrefix = "secret://"

    enum SetupSecretError: LocalizedError {
        case encodingFailed
        case keychain(OSStatus)
        case indexWrite(Error)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Failed to encode the secret as UTF-8."
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown"
                return "Keychain error \(status): \(message)"
            case .indexWrite(let error):
                return "Could not update secrets index: \(error.localizedDescription)"
            }
        }
    }

    /// Non-secret descriptor persisted to the main app's `secrets-index.json`.
    /// Matches the shape expected by the main app's `SecretMetadata`.
    private struct Metadata: Codable, Equatable {
        var name: String
        var scopeKind: String
        var projectId: String?
        var synced: Bool
        var note: String?
        var createdAt: Date
        var updatedAt: Date
        var lastUsedAt: Date?
    }

    private static var indexURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SwiftMaestro/secrets-index.json")
    }

    private static var appSupportURL: URL {
        indexURL.deletingLastPathComponent()
    }

    /// Store a global secret and return a `secret://` reference.
    /// - Parameters:
    ///   - name: The short secret name (e.g. `remote-kimi-api-key`).
    ///   - value: The raw API key or token.
    ///   - synced: Whether the item should be eligible for iCloud Keychain sync.
    ///   - note: Human-readable note shown in Settings → Secrets.
    static func store(
        name: String,
        value: String,
        synced: Bool = true,
        note: String? = nil
    ) throws -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = "secret.global.\(cleanName)"

        // Write the value to the Keychain under the same service the main app uses.
        try storeKeychain(account: account, value: value, synchronizable: synced)

        // Merge metadata into the main app's secrets index so it appears in
        // Settings → Secrets and participates in redaction.
        try mergeMetadata(
            Metadata(
                name: cleanName,
                scopeKind: "global",
                projectId: nil,
                synced: synced,
                note: note,
                createdAt: Date(),
                updatedAt: Date(),
                lastUsedAt: nil
            )
        )

        return "\(referencePrefix)\(cleanName)"
    }

    // MARK: - Keychain

    private static func storeKeychain(account: String, value: String, synchronizable: Bool) throws {
        guard let data = value.data(using: .utf8) else {
            throw SetupSecretError.encodingFailed
        }

        let accessible: CFString = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let findQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]

        let updateStatus = SecItemUpdate(findQuery as CFDictionary, updates as CFDictionary)

        if updateStatus == errSecItemNotFound {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
                kSecAttrAccessible as String: accessible,
            ]
            let status = SecItemAdd(query as CFDictionary, nil)
            if (status == errSecMissingEntitlement || status == errSecNotAvailable) && synchronizable {
                // iCloud Keychain may be unavailable; fall back to local-only.
                try storeKeychain(account: account, value: value, synchronizable: false)
                return
            }
            guard status == errSecSuccess else {
                throw SetupSecretError.keychain(status)
            }
        } else if (updateStatus == errSecMissingEntitlement || updateStatus == errSecNotAvailable) && synchronizable {
            try storeKeychain(account: account, value: value, synchronizable: false)
            return
        } else if updateStatus != errSecSuccess {
            throw SetupSecretError.keychain(updateStatus)
        }
    }

    // MARK: - Metadata index

    private static func mergeMetadata(_ metadata: Metadata) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        var items: [Metadata] = []
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder.secrets.decode([Metadata].self, from: data) {
            items = decoded
        }

        if let idx = items.firstIndex(where: { $0.name == metadata.name && $0.scopeKind == metadata.scopeKind }) {
            items[idx].synced = metadata.synced
            items[idx].note = metadata.note
            items[idx].updatedAt = metadata.updatedAt
        } else {
            items.append(metadata)
        }

        let data = try JSONEncoder.secrets.encode(items)
        do {
            try data.write(to: indexURL, options: .atomic)
        } catch {
            throw SetupSecretError.indexWrite(error)
        }
    }
}

private extension JSONEncoder {
    static var secrets: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

private extension JSONDecoder {
    static var secrets: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

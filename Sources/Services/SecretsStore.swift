import Foundation

// MARK: - Scope

/// Where a secret applies. `global` = permanent across all projects; `project`
/// = bound to a single project id (persists until explicitly purged).
enum SecretScope: Equatable, Codable {
    case global
    case project(String)

    var kind: String {
        switch self {
        case .global: return "global"
        case .project: return "project"
        }
    }

    var projectId: String? {
        if case .project(let id) = self { return id }
        return nil
    }

    /// Keychain account name encoding the scope. Mirrors the bridge convention.
    func account(for name: String) -> String {
        switch self {
        case .global: return "secret.global.\(name)"
        case .project(let id): return "secret.project.\(id).\(name)"
        }
    }
}

// MARK: - Metadata

/// Non-secret descriptor for a stored secret. Persisted to `secrets-index.json`.
/// NEVER contains the secret value.
struct SecretMetadata: Identifiable, Codable, Equatable {
    var name: String
    var scopeKind: String        // "global" | "project"
    var projectId: String?
    var synced: Bool             // eligible for iCloud Keychain sync
    var note: String?
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?

    var id: String { account }

    var scope: SecretScope {
        if scopeKind == "project", let projectId { return .project(projectId) }
        return .global
    }

    var account: String { scope.account(for: name) }
}

// MARK: - Store / Broker

/// Single entry point for storing, listing, resolving, and deleting secrets.
/// Values live in the Keychain (`KeychainService`); descriptors live in a
/// machine-local JSON index. The model never receives raw values — callers
/// resolve `secret://<name>` references only at injection points.
enum SecretsStore {
    static let referencePrefix = "secret://"

    // MARK: Index location (machine-local; only Keychain values sync)

    private static var indexURL: URL { SwiftMaestroPaths.secretsIndexURL }

    private static let lock = NSLock()
    // Access is always guarded by `lock`, so this shared mutable state is safe.
    nonisolated(unsafe) private static var valueCache: [String]? // cached raw values for redaction
    // Cached resolved values per (account) to avoid repeated keychain auth prompts.
    // Invalidated whenever secrets are added/removed/updated.
    nonisolated(unsafe) private static var resolvedCache: [String: String] = [:]

    // MARK: Index IO

    static func listMetadata() -> [SecretMetadata] {
        lock.lock(); defer { lock.unlock() }
        return loadIndexLocked()
    }

    private static func loadIndexLocked() -> [SecretMetadata] {
        guard let data = try? Data(contentsOf: indexURL),
              let items = try? JSONDecoder.secrets.decode([SecretMetadata].self, from: data)
        else { return [] }
        return items
    }

    private static func saveIndexLocked(_ items: [SecretMetadata]) {
        if let data = try? JSONEncoder.secrets.encode(items) {
            try? data.write(to: indexURL, options: [.atomic])
        }
    }

    // MARK: Mutations

    /// Create or replace a secret. Writes the value to Keychain and the
    /// descriptor to the index. Returns the stored metadata.
    @discardableResult
    static func upsert(
        name: String,
        value: String,
        scope: SecretScope,
        synced: Bool,
        note: String? = nil
    ) throws -> SecretMetadata {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try KeychainService.store(account: scope.account(for: cleanName), value: value, synchronizable: synced)

        lock.lock(); defer { lock.unlock() }
        var items = loadIndexLocked()
        let now = Date()
        if let idx = items.firstIndex(where: { $0.name == cleanName && $0.scope == scope }) {
            items[idx].synced = synced
            items[idx].note = note
            items[idx].updatedAt = now
            valueCache = nil
            resolvedCache.removeValue(forKey: scope.account(for: cleanName))
            saveIndexLocked(items)
            return items[idx]
        }
        let meta = SecretMetadata(
            name: cleanName,
            scopeKind: scope.kind,
            projectId: scope.projectId,
            synced: synced,
            note: note,
            createdAt: now,
            updatedAt: now,
            lastUsedAt: nil
        )
        items.append(meta)
        valueCache = nil
        resolvedCache.removeValue(forKey: scope.account(for: cleanName))
        saveIndexLocked(items)
        return meta
    }

    /// Update a secret's metadata and/or value, moving the Keychain item when the
    /// scope or name changes so references keep resolving correctly.
    ///
    /// Keychain reads are performed with `allowUI: false` so the user never sees a
    /// keychain password dialog. If the keychain is locked and the account needs to
    /// move, the caller must provide the new value explicitly.
    static func update(
        original: SecretMetadata,
        name: String? = nil,
        value: String? = nil,
        scope: SecretScope? = nil,
        synced: Bool? = nil,
        note: String? = nil
    ) throws -> SecretMetadata {
        let newName = (name ?? original.name).trimmingCharacters(in: .whitespacesAndNewlines)
        let newScope = scope ?? original.scope
        let newSynced = synced ?? original.synced
        let newNote = note ?? original.note

        let accountChanged = newName != original.name || newScope != original.scope
        let targetAccount = newScope.account(for: newName)

        // Resolve the value that should end up in the (possibly new) Keychain account.
        let resolvedValue: String
        if let provided = value, !provided.isEmpty {
            resolvedValue = provided
        } else {
            // Background read: never pop a keychain unlock dialog. If the keychain is
            // locked we cannot retrieve the value, so the caller must supply it.
            guard let existing = try? KeychainService.read(account: original.account, allowUI: false),
                  !existing.isEmpty else {
                throw SecretError.keychainLocked
            }
            resolvedValue = existing
        }

        if accountChanged {
            // Move the secret to the account implied by the new name/scope.
            try KeychainService.store(account: targetAccount, value: resolvedValue, synchronizable: newSynced)
            try KeychainService.delete(account: original.account)
        } else if newSynced != original.synced || (value != nil && !value!.isEmpty) {
            // Same account, but value or sync flag changed.
            try KeychainService.store(account: targetAccount, value: resolvedValue, synchronizable: newSynced)
        }

        lock.lock(); defer { lock.unlock() }
        var items = loadIndexLocked()
        items.removeAll { $0.account == original.account }
        let updated = SecretMetadata(
            name: newName,
            scopeKind: newScope.kind,
            projectId: newScope.projectId,
            synced: newSynced,
            note: newNote,
            createdAt: original.createdAt,
            updatedAt: Date(),
            lastUsedAt: original.lastUsedAt
        )
        items.append(updated)
        valueCache = nil
        resolvedCache.removeValue(forKey: original.account)
        resolvedCache.removeValue(forKey: targetAccount)
        saveIndexLocked(items)
        return updated
    }

    enum SecretError: LocalizedError {
        case keychainLocked

        var errorDescription: String? {
            switch self {
            case .keychainLocked:
                return "The login keychain is locked, so the existing secret value can't be read. "
                    + "Enter the current value in the Value field, or unlock the keychain in Keychain Access."
            }
        }
    }

    static func delete(_ meta: SecretMetadata) throws {
        try KeychainService.delete(account: meta.account)
        lock.lock(); defer { lock.unlock() }
        var items = loadIndexLocked()
        items.removeAll { $0.account == meta.account }
        valueCache = nil
        resolvedCache.removeValue(forKey: meta.account)
        saveIndexLocked(items)
    }

    /// Remove every secret bound to a given project id.
    static func purgeProject(_ projectId: String) throws {
        let targets = listMetadata().filter { $0.projectId == projectId }
        for meta in targets { try delete(meta) }
    }

    // MARK: Resolution (injection points only — never the model)

    /// Resolve a `secret://<name>` reference to its value.
    /// Resolution order: the active project scope first, then global.
    static func resolve(reference: String, currentProject: String?) -> String? {
        guard reference.hasPrefix(referencePrefix) else { return nil }
        let name = String(reference.dropFirst(referencePrefix.count))
        return resolveValue(name: name, currentProject: currentProject)
    }

    static func resolveValue(name: String, currentProject: String?) -> String? {
        // If the login keychain is locked, skip reads entirely rather than
        // risk a keychain password dialog during model inference.
        guard KeychainService.isDefaultKeychainUnlocked() else { return nil }

        let accounts = [currentProject.map { SecretScope.project($0).account(for: name) },
                        SecretScope.global.account(for: name)].compactMap { $0 }

        lock.lock()
        for account in accounts {
            if let cached = resolvedCache[account], !cached.isEmpty {
                lock.unlock()
                return cached
            }
        }
        lock.unlock()

        for account in accounts {
            // Use `allowUI: false` for injection-point reads so background model runs
            // and secret resolution never pop a keychain password dialog. If the item
            // is inaccessible without UI, we fail silently rather than interrupt the user.
            if let value = try? KeychainService.read(account: account, allowUI: false), !value.isEmpty {
                lock.lock()
                resolvedCache[account] = value
                lock.unlock()
                return value
            }
        }
        return nil
    }

    private static func touchLastUsed(name: String, scope: SecretScope) {
        lock.lock(); defer { lock.unlock() }
        var items = loadIndexLocked()
        if let idx = items.firstIndex(where: { $0.name == name && $0.scope == scope }) {
            items[idx].lastUsedAt = Date()
            saveIndexLocked(items)
        }
    }

    // MARK: Redaction support

    /// All raw secret values currently stored (cached). Used only in-process by
    /// `SecretRedactor` to strip values before anything is persisted or logged.
    static func knownValues() -> [String] {
        // If the login keychain is locked, return empty so redaction silently
        // skips instead of triggering a keychain password dialog.
        guard KeychainService.isDefaultKeychainUnlocked() else { return [] }

        lock.lock()
        if let cache = valueCache { lock.unlock(); return cache }
        let metas = loadIndexLocked()
        lock.unlock()

        var values: [String] = []
        for meta in metas {
            if let value = try? KeychainService.read(account: meta.account, allowUI: false), !value.isEmpty {
                values.append(value)
            }
        }
        lock.lock(); valueCache = values; lock.unlock()
        return values
    }

    static func invalidateValueCache() {
        lock.lock()
        valueCache = nil
        resolvedCache.removeAll()
        lock.unlock()
    }
}

// MARK: - Redactor

/// Replaces known secret values with `«redacted»` before content is written to
/// the shared memory store or any log. This is the safety net that keeps tokens
/// out of `~/.ai-context/memory/`.
enum SecretRedactor {
    static func redact(_ text: String) -> String {
        var output = text
        for value in SecretsStore.knownValues() where value.count >= 6 {
            output = output.replacingOccurrences(of: value, with: "«redacted»")
        }
        return output
    }
}

// MARK: - JSON coders

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

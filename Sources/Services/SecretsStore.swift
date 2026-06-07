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

    private static var indexURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("SwiftMaestro", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("secrets-index.json")
    }

    private static let lock = NSLock()
    // Access is always guarded by `lock`, so this shared mutable state is safe.
    nonisolated(unsafe) private static var valueCache: [String]? // cached raw values for redaction

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
        saveIndexLocked(items)
        return meta
    }

    static func delete(_ meta: SecretMetadata) throws {
        try KeychainService.delete(account: meta.account)
        lock.lock(); defer { lock.unlock() }
        var items = loadIndexLocked()
        items.removeAll { $0.account == meta.account }
        valueCache = nil
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
        if let project = currentProject {
            let projectAccount = SecretScope.project(project).account(for: name)
            if let value = try? KeychainService.read(account: projectAccount), !value.isEmpty {
                touchLastUsed(name: name, scope: .project(project))
                return value
            }
        }
        let globalAccount = SecretScope.global.account(for: name)
        if let value = try? KeychainService.read(account: globalAccount), !value.isEmpty {
            touchLastUsed(name: name, scope: .global)
            return value
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
        lock.lock()
        if let cache = valueCache { lock.unlock(); return cache }
        let metas = loadIndexLocked()
        lock.unlock()

        var values: [String] = []
        for meta in metas {
            if let value = try? KeychainService.read(account: meta.account), !value.isEmpty {
                values.append(value)
            }
        }
        lock.lock(); valueCache = values; lock.unlock()
        return values
    }

    static func invalidateValueCache() {
        lock.lock(); valueCache = nil; lock.unlock()
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

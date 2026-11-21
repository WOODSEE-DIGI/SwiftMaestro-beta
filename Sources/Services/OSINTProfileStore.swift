import Foundation

/// Live, per-agent OSINT profile store. Each agent can hold multiple subject
/// profiles, with exactly one profile designated as active at any time. The
/// active profile receives new findings and is shown to the agent in its
/// system prompt.
@Observable
@MainActor
final class OSINTProfileStore {

    /// Shared singleton used by views that need a stable reference independent
    /// of the SwiftUI environment. The app injects this same instance via
    /// `.environment(OSINTProfileStore.shared)` so all code paths observe the
    /// same store.
    static let shared = OSINTProfileStore()

    /// All profiles keyed by agent id, then profile id.
    private(set) var profiles: [UUID: [UUID: OSINTProfile]] = [:]
    /// Active profile id for each agent.
    private(set) var activeProfileIDs: [UUID: UUID] = [:]

    // MARK: - Active profile

    /// Returns the active profile for the agent, creating a default empty one
    /// if none exists yet.
    func profile(for agentId: UUID) -> OSINTProfile {
        ensureLoaded(for: agentId)
        if let activeID = activeProfileIDs[agentId],
           let active = profiles[agentId]?[activeID] {
            return active
        }
        // Fall back to the only profile, or create a default profile.
        let agentProfiles = profiles[agentId] ?? [:]
        if agentProfiles.count == 1, let only = agentProfiles.values.first {
            activeProfileIDs[agentId] = only.id
            return only
        }
        return createProfile(name: nil, activate: true, for: agentId)
    }

    /// The id of the active profile, if one exists.
    func activeProfileID(for agentId: UUID) -> UUID? {
        ensureLoaded(for: agentId)
        return activeProfileIDs[agentId]
    }

    /// All profiles for an agent.
    func allProfiles(for agentId: UUID) -> [OSINTProfile] {
        ensureLoaded(for: agentId)
        return (profiles[agentId] ?? [:]).values.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Profile lifecycle

    /// Create a new profile. If `activate` is true (default), it becomes the
    /// active profile for the agent.
    @discardableResult
    func createProfile(name: String?, activate: Bool = true, for agentId: UUID) -> OSINTProfile {
        ensureLoaded(for: agentId)
        let profile = OSINTProfile(subjectName: name?.trimmingCharacters(in: .whitespacesAndNewlines))
        profiles[agentId, default: [:]][profile.id] = profile
        if activate || activeProfileIDs[agentId] == nil {
            activeProfileIDs[agentId] = profile.id
        }
        saveAgent(agentId)
        return profile
    }

    /// Activate an existing profile.
    @discardableResult
    func switchProfile(id profileID: UUID, for agentId: UUID) -> Bool {
        ensureLoaded(for: agentId)
        guard profiles[agentId]?[profileID] != nil else { return false }
        activeProfileIDs[agentId] = profileID
        saveAgent(agentId)
        return true
    }

    /// Rename a profile's subject.
    @discardableResult
    func renameProfile(id profileID: UUID, name: String?, for agentId: UUID) -> Bool {
        ensureLoaded(for: agentId)
        guard profiles[agentId]?.index(forKey: profileID) != nil else { return false }
        profiles[agentId]?[profileID]?.subjectName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[agentId]?[profileID]?.updatedAt = Date()
        saveAgent(agentId)
        return true
    }

    /// Delete a profile. If it was the active profile, another profile is
    /// activated (or a new default one is created).
    @discardableResult
    func deleteProfile(id profileID: UUID, for agentId: UUID) -> Bool {
        ensureLoaded(for: agentId)
        guard profiles[agentId]?.removeValue(forKey: profileID) != nil else { return false }
        if activeProfileIDs[agentId] == profileID {
            activeProfileIDs[agentId] = profiles[agentId]?.values.first?.id
            if activeProfileIDs[agentId] == nil {
                let fallback = OSINTProfile(subjectName: "Default")
                profiles[agentId, default: [:]][fallback.id] = fallback
                activeProfileIDs[agentId] = fallback.id
            }
        }
        saveAgent(agentId)
        return true
    }

    /// Replace the active profile entirely (e.g. on subject rename).
    func setProfile(_ profile: OSINTProfile, for agentId: UUID) {
        ensureLoaded(for: agentId)
        var updated = profile
        updated.updatedAt = Date()
        profiles[agentId, default: [:]][updated.id] = updated
        activeProfileIDs[agentId] = updated.id
        saveAgent(agentId)
    }

    // MARK: - Finding mutations (active profile)

    /// Add a new finding to the active profile.
    @discardableResult
    func addFinding(_ finding: OSINTProfileFinding, for agentId: UUID) -> OSINTProfile {
        var profile = profile(for: agentId)
        profile.findings.append(finding)
        profile.updatedAt = Date()
        profiles[agentId, default: [:]][profile.id] = profile
        saveAgent(agentId)
        return profile
    }

    /// Add multiple findings to the active profile.
    @discardableResult
    func addFindings(_ findings: [OSINTProfileFinding], for agentId: UUID) -> OSINTProfile {
        var profile = profile(for: agentId)
        profile.findings.append(contentsOf: findings)
        profile.updatedAt = Date()
        profiles[agentId, default: [:]][profile.id] = profile
        saveAgent(agentId)
        return profile
    }

    /// Update a finding's verification status or notes in the active profile.
    @discardableResult
    func updateFinding(
        id findingID: UUID,
        verificationStatus: OSINTVerificationStatus? = nil,
        notes: String? = nil,
        for agentId: UUID
    ) -> OSINTProfile? {
        var profile = profile(for: agentId)
        guard let idx = profile.findings.firstIndex(where: { $0.id == findingID }) else { return nil }
        if let verificationStatus {
            profile.findings[idx].verificationStatus = verificationStatus
        }
        if let notes {
            profile.findings[idx].notes = notes
        }
        profile.updatedAt = Date()
        profiles[agentId, default: [:]][profile.id] = profile
        saveAgent(agentId)
        return profile
    }

    /// Remove a finding from the active profile.
    func removeFinding(id findingID: UUID, for agentId: UUID) {
        var profile = profile(for: agentId)
        profile.findings.removeAll { $0.id == findingID }
        profile.updatedAt = Date()
        profiles[agentId, default: [:]][profile.id] = profile
        saveAgent(agentId)
    }

    /// Clear all findings from the active profile. To delete the profile itself,
    /// use `deleteProfile(id:for:)`.
    func clear(for agentId: UUID) {
        var profile = profile(for: agentId)
        profile.findings = []
        profile.subjectName = nil
        profile.updatedAt = Date()
        profiles[agentId, default: [:]][profile.id] = profile
        saveAgent(agentId)
    }

    /// Findings that are accepted or still unverified/unsure across the active
    /// profile. Rejected findings are excluded.
    func acceptedFindings(for agentId: UUID) -> [OSINTProfileFinding] {
        profile(for: agentId).findings.filter { $0.verificationStatus != .rejected }
    }

    // MARK: - Loading / saving

    private func ensureLoaded(for agentId: UUID) {
        guard profiles[agentId] == nil else { return }
        let container = Self.load(agentId)
        var map: [UUID: OSINTProfile] = [:]
        for profile in container.profiles {
            map[profile.id] = profile
        }
        profiles[agentId] = map
        activeProfileIDs[agentId] = container.activeProfileID
    }

    private func saveAgent(_ agentId: UUID) {
        let agentProfiles = profiles[agentId].map { Array($0.values) } ?? []
        let container = OSINTProfileAgentContainer(
            profiles: agentProfiles,
            activeProfileID: activeProfileIDs[agentId]
        )
        Self.save(container, agentId)
    }

    // MARK: - Persistence (App Support/SwiftMaestro/osint-profiles/<agentId>.json)

    private nonisolated static func dir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SwiftMaestro", isDirectory: true)
            .appendingPathComponent("osint-profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private nonisolated static func fileURL(for agentId: UUID) -> URL {
        dir().appendingPathComponent("\(agentId.uuidString).json")
    }

    private nonisolated static func save(_ container: OSINTProfileAgentContainer, _ agentId: UUID) {
        do {
            let data = try JSONEncoder().encode(container)
            try data.write(to: fileURL(for: agentId), options: .atomic)
        } catch {
            NSLog("[OSINTProfileStore] failed to save profiles for \(agentId): \(error)")
        }
    }

    private nonisolated static func load(_ agentId: UUID) -> OSINTProfileAgentContainer {
        let url = fileURL(for: agentId)
        guard let data = try? Data(contentsOf: url) else {
            return OSINTProfileAgentContainer(profiles: [], activeProfileID: nil)
        }
        // New multi-profile container format.
        if let container = try? JSONDecoder().decode(OSINTProfileAgentContainer.self, from: data) {
            return container
        }
        // Migration: old format was a single OSINTProfile.
        if let legacy = try? JSONDecoder().decode(OSINTProfile.self, from: data) {
            return OSINTProfileAgentContainer(profiles: [legacy], activeProfileID: legacy.id)
        }
        NSLog("[OSINTProfileStore] failed to decode profiles for \(agentId)")
        return OSINTProfileAgentContainer(profiles: [], activeProfileID: nil)
    }
}

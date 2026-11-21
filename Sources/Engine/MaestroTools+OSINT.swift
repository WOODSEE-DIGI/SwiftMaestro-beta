import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - OSINT profile tools

extension MaestroTools {

    /// Categorized as `.memory` alongside todo/plan tools because building an
    /// OSINT profile is a form of structured memory about the investigation.
    static func registerOSINTProfileTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "add_profile_finding",
                spec: osintProfileToolSpecs[0],
                category: ToolCategory.memory.rawValue,
                handler: { call in await addProfileFinding(call) }),
            ToolDefinition(
                name: "read_profile",
                spec: osintProfileToolSpecs[1],
                category: ToolCategory.memory.rawValue,
                handler: { call in await readProfile(call) }),
            ToolDefinition(
                name: "update_finding_status",
                spec: osintProfileToolSpecs[2],
                category: ToolCategory.memory.rawValue,
                handler: { call in await updateFindingStatus(call) }),
            ToolDefinition(
                name: "create_osint_profile",
                spec: osintProfileToolSpecs[3],
                category: ToolCategory.memory.rawValue,
                handler: { call in await createOSINTProfile(call) }),
            ToolDefinition(
                name: "switch_osint_profile",
                spec: osintProfileToolSpecs[4],
                category: ToolCategory.memory.rawValue,
                handler: { call in await switchOSINTProfile(call) }),
            ToolDefinition(
                name: "list_osint_profiles",
                spec: osintProfileToolSpecs[5],
                category: ToolCategory.memory.rawValue,
                handler: { call in await listOSINTProfiles(call) }),
            ToolDefinition(
                name: "rename_osint_profile",
                spec: osintProfileToolSpecs[6],
                category: ToolCategory.memory.rawValue,
                handler: { call in await renameOSINTProfile(call) }),
            ToolDefinition(
                name: "delete_osint_profile",
                spec: osintProfileToolSpecs[7],
                category: ToolCategory.memory.rawValue,
                handler: { call in await deleteOSINTProfile(call) }),
        ])
    }

    private static var osintProfileToolSpecs: [ToolSpec] {
        let entityTypeEnum: [String: any Sendable] = [
            "type": "string",
            "enum": OSINTEntityType.allCases.map(\.rawValue) as [any Sendable],
            "description": "Kind of information: name, account, email, phone, address, location, organization, website, image, document, relationship, alias, or other.",
        ]
        let confidenceEnum: [String: any Sendable] = [
            "type": "string",
            "enum": OSINTConfidence.allCases.map(\.rawValue) as [any Sendable],
            "description": "Model confidence in this finding.",
        ]
        let statusEnum: [String: any Sendable] = [
            "type": "string",
            "enum": OSINTVerificationStatus.allCases.map(\.rawValue) as [any Sendable],
            "description": "Investigator review status.",
        ]
        let statusFilterEnum: [String: any Sendable] = [
            "type": "string",
            "enum": ["all", "accepted", "unverified", "unsure", "rejected"] as [any Sendable],
            "description": "Filter by verification status.",
        ]
        return [
            rawSpec("add_profile_finding",
                "Record a discovered OSINT finding to the subject profile. The investigator "
                + "reviews it in the profile panel. Only record publicly available information "
                + "from lawful sources. Cite the source and URL when possible.",
                properties: [
                    "entity_type": entityTypeEnum,
                    "value": ["type": "string", "description": "The actual value: username, email, address, URL, name, etc."],
                    "label": ["type": "string", "description": "Optional short label, e.g. 'Instagram — professional account'."],
                    "source": ["type": "string", "description": "Where this was found, e.g. 'web_search', 'Instagram public profile', 'company registry'."],
                    "source_url": ["type": "string", "description": "Direct URL to the source, if available."],
                    "confidence": confidenceEnum,
                    "notes": ["type": "string", "description": "Optional context, caveats, or why this matters."],
                ], required: ["entity_type", "value", "source"]),
            rawSpec("read_profile",
                "Read the current OSINT profile for this chat, including all recorded findings "
                + "and their verification status. Use this before planning the next search so "
                + "you build on accepted leads and avoid rejected false positives.",
                properties: [
                    "status_filter": statusFilterEnum,
                ], required: []),
            rawSpec("update_finding_status",
                "Update the verification status or notes of an existing profile finding. "
                + "Usually called in response to the investigator's review, but the agent may "
                + "also refine confidence as more evidence emerges.",
                properties: [
                    "finding_id": ["type": "string", "description": "The UUID of the finding to update."],
                    "status": statusEnum,
                    "notes": ["type": "string", "description": "Updated notes or rationale."],
                ], required: ["finding_id"]),
            rawSpec("create_osint_profile",
                "Create a new OSINT subject profile for this agent. Use this when the user "
                + "wants to investigate a different person/entity without losing the current "
                + "profile. The new profile becomes active by default.",
                properties: [
                    "name": ["type": "string", "description": "Optional subject name, e.g. 'John Doe' or 'Acme Corp'."],
                    "activate": ["type": "boolean", "description": "Make this profile active immediately (default true)."],
                ], required: []),
            rawSpec("switch_osint_profile",
                "Switch the active OSINT profile for this agent. New findings will be recorded "
                + "to the selected profile and its accepted findings will guide the next search.",
                properties: [
                    "profile_id": ["type": "string", "description": "UUID of the profile to activate. Use list_osint_profiles to discover ids."],
                ], required: ["profile_id"]),
            rawSpec("list_osint_profiles",
                "List all saved OSINT profiles for this agent, including ids, subject names, "
                + "finding counts, and which one is active.",
                properties: [:], required: []),
            rawSpec("rename_osint_profile",
                "Rename an existing OSINT profile's subject name.",
                properties: [
                    "profile_id": ["type": "string", "description": "UUID of the profile to rename."],
                    "name": ["type": "string", "description": "New subject name."],
                ], required: ["profile_id", "name"]),
            rawSpec("delete_osint_profile",
                "Permanently delete an OSINT profile and all its findings. Use with care.",
                properties: [
                    "profile_id": ["type": "string", "description": "UUID of the profile to delete."],
                ], required: ["profile_id"]),
        ]
    }

    // MARK: - Args

    private struct AddProfileFindingArgs: Codable {
        let entity_type: String
        let value: String
        let label: String?
        let source: String
        let source_url: String?
        let confidence: String?
        let notes: String?
        let agent_id: String?
    }

    private struct ReadProfileArgs: Codable {
        let status_filter: String?
        let agent_id: String?
    }

    private struct UpdateFindingStatusArgs: Codable {
        let finding_id: String
        let status: String?
        let notes: String?
        let agent_id: String?
    }

    private struct CreateOSINTProfileArgs: Codable {
        let name: String?
        let activate: Bool?
        let agent_id: String?
    }

    private struct SwitchOSINTProfileArgs: Codable {
        let profile_id: String
        let agent_id: String?
    }

    private struct ListOSINTProfilesArgs: Codable {
        let agent_id: String?
    }

    private struct RenameOSINTProfileArgs: Codable {
        let profile_id: String
        let name: String
        let agent_id: String?
    }

    private struct DeleteOSINTProfileArgs: Codable {
        let profile_id: String
        let agent_id: String?
    }

    // MARK: - Handlers

    private static func addProfileFinding(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: AddProfileFindingArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }
        guard let entityType = OSINTEntityType(rawValue: args.entity_type) else {
            return errorJSON("invalid entity_type '\(args.entity_type)'")
        }
        let value = sanitizeModelText(args.value)
        guard !value.isEmpty else {
            return errorJSON("missing or empty value")
        }
        let source = sanitizeModelText(args.source)
        let confidence = args.confidence.flatMap(OSINTConfidence.init(rawValue:)) ?? .medium

        return await MainActor.run {
            guard let store = osintProfileStore else { return errorJSON("OSINT profile store unavailable") }
            let finding = OSINTProfileFinding(
                entityType: entityType,
                value: value,
                label: args.label.map(sanitizeModelText),
                source: source,
                sourceURL: args.source_url.map(sanitizeModelText),
                confidence: confidence,
                notes: args.notes.map(sanitizeModelText)
            )
            store.addFinding(finding, for: agentUUID)
            return jsonString(["finding_id": finding.id.uuidString, "recorded": true])
        }
    }

    private static func readProfile(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ReadProfileArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }
        let filterRaw = args.status_filter ?? "all"
        return await MainActor.run {
            guard let store = osintProfileStore else { return errorJSON("OSINT profile store unavailable") }
            let profile = store.profile(for: agentUUID)
            let findings: [OSINTProfileFinding]
            switch filterRaw {
            case "accepted": findings = profile.findings.filter { $0.verificationStatus == .accepted }
            case "unverified": findings = profile.findings.filter { $0.verificationStatus == .unverified }
            case "unsure": findings = profile.findings.filter { $0.verificationStatus == .unsure }
            case "rejected": findings = profile.findings.filter { $0.verificationStatus == .rejected }
            default: findings = profile.findings
            }
            let payload: [String: Any] = [
                "subject_name": profile.subjectName as Any,
                "finding_count": findings.count,
                "findings": findings.map(findingDict),
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let string = String(data: data, encoding: .utf8) else {
                return errorJSON("failed to serialize profile")
            }
            return string
        }
    }

    private static func updateFindingStatus(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: UpdateFindingStatusArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }
        guard let findingUUID = UUID(uuidString: args.finding_id) else {
            return errorJSON("invalid finding_id")
        }
        let status = args.status.flatMap(OSINTVerificationStatus.init(rawValue:))
        let notes = args.notes.map(sanitizeModelText)
        return await MainActor.run {
            guard let store = osintProfileStore else { return errorJSON("OSINT profile store unavailable") }
            guard store.updateFinding(id: findingUUID, verificationStatus: status, notes: notes, for: agentUUID) != nil else {
                return errorJSON("finding not found")
            }
            return jsonString(["updated": true])
        }
    }

    private static func createOSINTProfile(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: CreateOSINTProfileArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }
        let name = args.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let activate = args.activate ?? true
        return await MainActor.run {
            guard let store = osintProfileStore else { return errorJSON("OSINT profile store unavailable") }
            let profile = store.createProfile(name: name?.isEmpty == false ? name : nil, activate: activate, for: agentUUID)
            return jsonString([
                "profile_id": profile.id.uuidString,
                "subject_name": profile.subjectName as Any,
                "active": activate,
            ])
        }
    }

    private static func switchOSINTProfile(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SwitchOSINTProfileArgs.self),
              let profileUUID = UUID(uuidString: args.profile_id) else {
            return errorJSON("'profile_id' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }
        return await MainActor.run {
            guard let store = osintProfileStore else { return errorJSON("OSINT profile store unavailable") }
            let success = store.switchProfile(id: profileUUID, for: agentUUID)
            return jsonString(["switched": success])
        }
    }

    private static func listOSINTProfiles(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ListOSINTProfilesArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }
        return await MainActor.run {
            guard let store = osintProfileStore else { return errorJSON("OSINT profile store unavailable") }
            let activeID = store.activeProfileID(for: agentUUID)
            let profiles = store.allProfiles(for: agentUUID)
            let payload: [String: Any] = [
                "active_profile_id": activeID?.uuidString as Any,
                "profile_count": profiles.count,
                "profiles": profiles.map { p in
                    [
                        "id": p.id.uuidString,
                        "subject_name": p.subjectName as Any,
                        "finding_count": p.findings.count,
                        "accepted_count": p.findings.filter { $0.verificationStatus == .accepted }.count,
                        "active": p.id == activeID,
                        "updated_at": ISO8601DateFormatter().string(from: p.updatedAt),
                    ] as [String: Any]
                },
            ]
            return jsonString(payload)
        }
    }

    private static func renameOSINTProfile(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: RenameOSINTProfileArgs.self),
              let profileUUID = UUID(uuidString: args.profile_id) else {
            return errorJSON("'profile_id' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }
        return await MainActor.run {
            guard let store = osintProfileStore else { return errorJSON("OSINT profile store unavailable") }
            let success = store.renameProfile(id: profileUUID, name: args.name, for: agentUUID)
            return jsonString(["renamed": success])
        }
    }

    private static func deleteOSINTProfile(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: DeleteOSINTProfileArgs.self),
              let profileUUID = UUID(uuidString: args.profile_id) else {
            return errorJSON("'profile_id' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }
        return await MainActor.run {
            guard let store = osintProfileStore else { return errorJSON("OSINT profile store unavailable") }
            let success = store.deleteProfile(id: profileUUID, for: agentUUID)
            return jsonString(["deleted": success])
        }
    }

    // MARK: - Helpers

    static func findingDict(_ finding: OSINTProfileFinding) -> [String: Any] {
        var dict: [String: Any] = [
            "id": finding.id.uuidString,
            "entity_type": finding.entityType.rawValue,
            "value": finding.value,
            "source": finding.source,
            "confidence": finding.confidence.rawValue,
            "verification_status": finding.verificationStatus.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: finding.timestamp),
        ]
        if let label = finding.label { dict["label"] = label }
        if let sourceURL = finding.sourceURL { dict["source_url"] = sourceURL }
        if let notes = finding.notes { dict["notes"] = notes }
        return dict
    }
}

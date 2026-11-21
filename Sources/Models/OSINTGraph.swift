import Foundation

// MARK: - Graph Node

/// A visual node in the OSINT relationship graph. Each node represents either a
/// profile (the root subject) or a single finding within a profile.
struct OSINTGraphNode: Identifiable {
    let id: UUID
    /// Display label (subject name for profiles, finding label otherwise).
    let label: String
    /// The actual value (email, URL, username, etc.). Empty for profile nodes.
    let value: String
    let entityType: OSINTEntityType
    let profileID: UUID
    let profileName: String?
    /// If nil, this node represents the profile itself.
    let findingID: UUID?
    var position: CGPoint

    var isProfileNode: Bool { findingID == nil }

    var displayTitle: String {
        if isProfileNode { return label }
        return label.isEmpty ? value : label
    }
}

// MARK: - Graph Edge

/// A link between two nodes in the OSINT relationship graph.
struct OSINTGraphEdge: Identifiable {
    let id: UUID
    let source: UUID
    let target: UUID
    let label: String?
    /// 0..1 — higher means a stronger spring and a more prominent line.
    let strength: Double
}

// MARK: - Graph Builder

/// Builds a force-directed graph from one or more OSINT profiles.
enum OSINTGraphBuilder {

    static func graph(for profiles: [OSINTProfile]) -> (nodes: [OSINTGraphNode], edges: [OSINTGraphEdge]) {
        var nodes: [OSINTGraphNode] = []
        var edges: [OSINTGraphEdge] = []
        var valueToNodeIDs: [String: [UUID]] = [:]

        for profile in profiles {
            let profileNode = OSINTGraphNode(
                id: UUID(),
                label: profile.subjectName?.isEmpty == false ? profile.subjectName! : "Untitled profile",
                value: "",
                entityType: .other,
                profileID: profile.id,
                profileName: profile.subjectName,
                findingID: nil,
                position: CGPoint(x: Double.random(in: -50...50), y: Double.random(in: -50...50))
            )
            nodes.append(profileNode)

            for finding in profile.findings {
                let node = OSINTGraphNode(
                    id: UUID(),
                    label: finding.label?.isEmpty == false ? finding.label! : finding.entityType.displayName,
                    value: finding.value,
                    entityType: finding.entityType,
                    profileID: profile.id,
                    profileName: profile.subjectName,
                    findingID: finding.id,
                    position: CGPoint(x: Double.random(in: -50...50), y: Double.random(in: -50...50))
                )
                nodes.append(node)

                // Profile -> finding ownership edge.
                edges.append(OSINTGraphEdge(
                    id: UUID(),
                    source: profileNode.id,
                    target: node.id,
                    label: nil,
                    strength: 0.3
                ))

                // Cross-link by normalized value (email, phone, URL, username).
                let normalized = normalize(finding.value)
                if !normalized.isEmpty {
                    valueToNodeIDs[normalized, default: []].append(node.id)
                }
            }
        }

        // Edges for shared values across findings/profiles.
        for (_, nodeIDs) in valueToNodeIDs where nodeIDs.count > 1 {
            for i in 0..<(nodeIDs.count - 1) {
                edges.append(OSINTGraphEdge(
                    id: UUID(),
                    source: nodeIDs[i],
                    target: nodeIDs[i + 1],
                    label: "shared",
                    strength: 0.9
                ))
            }
        }

        // Additional domain-based links for URLs/accounts from the same hostname.
        var domainToNodeIDs: [String: [UUID]] = [:]
        for node in nodes where !node.isProfileNode {
            guard let domain = domain(from: node.value) else { continue }
            domainToNodeIDs[domain, default: []].append(node.id)
        }
        for (_, nodeIDs) in domainToNodeIDs where nodeIDs.count > 1 {
            for i in 0..<(nodeIDs.count - 1) {
                let alreadyLinked = edges.contains { edge in
                    (edge.source == nodeIDs[i] && edge.target == nodeIDs[i + 1])
                    || (edge.source == nodeIDs[i + 1] && edge.target == nodeIDs[i])
                }
                if !alreadyLinked {
                    edges.append(OSINTGraphEdge(
                        id: UUID(),
                        source: nodeIDs[i],
                        target: nodeIDs[i + 1],
                        label: "same domain",
                        strength: 0.5
                    ))
                }
            }
        }

        return (nodes, edges)
    }

    // MARK: - Helpers

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func domain(from value: String) -> String? {
        let trimmed = normalize(value)
        guard !trimmed.isEmpty else { return nil }
        // Simple heuristic: take the first path component that looks like a domain.
        let host = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        guard host.contains(".") else { return nil }
        return host
    }
}

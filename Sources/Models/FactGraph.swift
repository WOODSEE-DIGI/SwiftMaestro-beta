import Foundation

// MARK: - Fact Graph
//
// The second pillar of Phase 4 advanced memory. A lightweight graph of facts,
// entities, preferences, decisions, projects, and tasks with typed edges.
// Stored as a single JSON document under `maestro://knowledge/facts/graph.json`
// and updated incrementally by tools and the learning engine.

struct FactGraph: Codable, Sendable, Hashable {
    var nodes: [FactNode]
    var edges: [FactEdge]
    var updatedAt: Date

    init(nodes: [FactNode] = [], edges: [FactEdge] = []) {
        self.nodes = nodes
        self.edges = edges
        self.updatedAt = Date()
    }

    mutating func touch() {
        updatedAt = Date()
    }
}

enum FactKind: String, Codable, Sendable, CaseIterable {
    case fact
    case entity
    case preference
    case decision
    case project
    case task
    case relationship
}

struct FactNode: Identifiable, Codable, Sendable, Hashable {
    var id: String
    var label: String
    var kind: FactKind
    var payload: String
    var sourceURI: String?
    var createdAt: Date
    var confidence: Double

    init(
        id: String,
        label: String,
        kind: FactKind,
        payload: String,
        sourceURI: String? = nil,
        createdAt: Date = Date(),
        confidence: Double = 1.0
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.payload = payload
        self.sourceURI = sourceURI
        self.createdAt = createdAt
        self.confidence = max(0.0, min(1.0, confidence))
    }
}

struct FactEdge: Codable, Sendable, Hashable {
    var source: String
    var relation: String
    var target: String
    var createdAt: Date

    init(source: String, relation: String, target: String, createdAt: Date = Date()) {
        self.source = source
        self.relation = relation
        self.target = target
        self.createdAt = createdAt
    }
}

extension FactGraph {
    /// All node IDs matching a free-text query, optionally filtered by kind.
    func nodes(matching query: String, kind: FactKind? = nil, limit: Int = 20) -> [FactNode] {
        let lower = query.lowercased()
        var out: [FactNode] = []
        for node in nodes {
            guard out.count < limit else { break }
            if let kind, node.kind != kind { continue }
            let haystack = "\(node.label) \(node.payload)".lowercased()
            if haystack.contains(lower) {
                out.append(node)
            }
        }
        return out
    }

    /// Nodes that are the target of a relation from the given source node.
    func related(to sourceID: String, relation: String? = nil, limit: Int = 20) -> [FactNode] {
        let targetIDs = edges
            .filter { $0.source == sourceID && (relation == nil || $0.relation == relation) }
            .map(\.target)
        let idSet = Set(targetIDs)
        return nodes.filter { idSet.contains($0.id) }.prefix(limit).map { $0 }
    }

    /// Add a node unless one with the same label+kind already exists; return the
    /// node's ID. If it already exists, optionally merges the payload.
    @discardableResult
    mutating func upsert(
        label: String,
        kind: FactKind,
        payload: String,
        sourceURI: String? = nil,
        confidence: Double = 1.0
    ) -> String {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = nodes.first(where: { $0.label == normalized && $0.kind == kind }) {
            if !payload.isEmpty, existing.payload != payload {
                var merged = existing
                merged.payload = payload
                merged.sourceURI = sourceURI ?? existing.sourceURI
                if let idx = nodes.firstIndex(where: { $0.id == existing.id }) {
                    nodes[idx] = merged
                }
            }
            return existing.id
        }
        let id = "\(kind.rawValue)-\(UUID().uuidString)"
        let node = FactNode(
            id: id,
            label: normalized,
            kind: kind,
            payload: payload,
            sourceURI: sourceURI,
            confidence: confidence)
        nodes.append(node)
        return id
    }

    /// Add a typed edge between two existing nodes. No-op if either node is missing.
    mutating func relate(source: String, relation: String, target: String) {
        guard nodes.contains(where: { $0.id == source }),
              nodes.contains(where: { $0.id == target })
        else { return }
        let trimmed = relation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let edge = FactEdge(source: source, relation: trimmed, target: target)
        edges.append(edge)
    }
}

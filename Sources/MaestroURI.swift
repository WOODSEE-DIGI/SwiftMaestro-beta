import Foundation

/// Canonical URI scheme for SwiftMaestro's OpenViking-style contextual memory.
///
/// Format: `maestro://<kind>[/<path-component>...]`
/// Examples:
///   - `maestro://memory` — root memory namespace
///   - `maestro://memory/conversations/session-2026-05-25` — specific conversation
///   - `maestro://knowledge/swift/observability` — knowledge base entry
///   - `maestro://context/session/current` — current session context
public struct MaestroURI: Hashable, Sendable, CustomStringConvertible {

    /// The OpenViking-style root namespace.
    public enum Kind: String, CaseIterable, Sendable {
        case memory     // Conversations, notes, memories
        case knowledge  // Factual knowledge base
        case context    // Session-specific temporary context
        case skill      // Learned skills and patterns
        
        var displayName: String {
            switch self {
                case .memory: return "Memory"
                case .knowledge: return "Knowledge"
                case .context: return "Context"
                case .skill: return "Skill"
            }
        }
    }

    public static let scheme = "maestro://"

    public let kind: Kind
    public let path: [String]

    // MARK: - Construction

    public init(kind: Kind, path: [String] = []) {
        self.kind = kind
        self.path = path.filter { !$0.isEmpty }
    }

    public init?(_ string: String) {
        guard string.hasPrefix(MaestroURI.scheme) else { return nil }
        let body = String(string.dropFirst(MaestroURI.scheme.count))
        let parts = body.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first, let kind = Kind(rawValue: first) else { return nil }
        self.kind = kind
        self.path = Array(parts.dropFirst())
    }

    // MARK: - Accessors

    public var description: String {
        if path.isEmpty {
            return MaestroURI.scheme + kind.rawValue
        }
        return MaestroURI.scheme + kind.rawValue + "/" + path.joined(separator: "/")
    }

    public var isRoot: Bool { path.isEmpty }

    public var name: String { path.last ?? kind.rawValue }

    public var parent: MaestroURI? {
        guard !path.isEmpty else { return nil }
        return MaestroURI(kind: kind, path: Array(path.dropLast()))
    }

    /// All ancestors from root down to (but not including) this URI.
    public var ancestors: [MaestroURI] {
        var out: [MaestroURI] = []
        var current = MaestroURI(kind: kind, path: [])
        out.append(current)
        for component in path.dropLast() {
            current = MaestroURI(kind: kind, path: current.path + [component])
            out.append(current)
        }
        return out
    }

    public func appending(_ component: String) -> MaestroURI {
        return MaestroURI(kind: kind, path: path + [component])
    }
}

// MARK: - Codable

extension MaestroURI: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let parsed = MaestroURI(s) else {
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "Invalid MaestroURI: \(s)"
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

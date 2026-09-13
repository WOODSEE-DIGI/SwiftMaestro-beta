import Foundation

// MARK: - Smart keep rules

/// Determines which copy of a duplicate/version set should be preserved when
/// the user asks to "keep one, clean the rest".
enum DAMKeepRule: String, CaseIterable, Sendable, Identifiable {
    case first
    case largestResolution
    case newest
    case shortestPath
    case deepestPath

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .first: return "Keep first"
        case .largestResolution: return "Keep largest resolution"
        case .newest: return "Keep newest date"
        case .shortestPath: return "Keep shortest path"
        case .deepestPath: return "Keep deepest path"
        }
    }

    /// Returns the item that should be kept, or nil if the rule cannot be applied.
    func keeper<T: DAMKeepComparable>(among items: [T]) -> T? {
        guard !items.isEmpty else { return nil }
        switch self {
        case .first:
            return items.first
        case .largestResolution:
            return items.max { $0.resolutionPixels < $1.resolutionPixels }
        case .newest:
            return items.max { ($0.sortDate ?? .distantPast) < ($1.sortDate ?? .distantPast) }
        case .shortestPath:
            return items.min { $0.path.count < $1.path.count }
        case .deepestPath:
            return items.max { $0.path.count < $1.path.count }
        }
    }
}

// MARK: - Comparable item protocol

/// Minimal metadata needed by `DAMKeepRule` to decide which file to keep.
protocol DAMKeepComparable: Sendable {
    var path: String { get }
    var resolutionPixels: Int { get }
    var sortDate: Date? { get }
}

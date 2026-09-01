import Foundation
import Observation

// MARK: - Model Visibility Store

/// Persists which models and model sources are visible in the chat pickers.
///
/// The catalog is grouped by *source* (Local MLX, LM Studio, Ollama, and each
/// online provider). Users can collapse sources for tidiness, disable an entire
/// source, or disable individual models. Disabled models are hidden from the
/// global and per-agent model pickers while remaining in the catalog.
@Observable
@MainActor
final class ModelVisibilityStore {

    static let shared = ModelVisibilityStore()

    private static let disabledModelsKey = "models.visibility.disabledModelIDs"
    private static let disabledSourcesKey = "models.visibility.disabledSourceIDs"
    private static let collapsedSourcesKey = "models.visibility.collapsedSourceIDs"

    /// Model IDs the user has explicitly disabled.
    private(set) var disabledModelIDs: Set<String> = []
    /// Source IDs the user has disabled (hides every model in the source).
    private(set) var disabledSourceIDs: Set<String> = []
    /// Sources currently collapsed in Settings → Models.
    private(set) var collapsedSourceIDs: Set<String> = []

    private init() {
        let defaults = UserDefaults.standard
        disabledModelIDs = Set(defaults.stringArray(forKey: Self.disabledModelsKey) ?? [])
        disabledSourceIDs = Set(defaults.stringArray(forKey: Self.disabledSourcesKey) ?? [])
        collapsedSourceIDs = Set(defaults.stringArray(forKey: Self.collapsedSourcesKey) ?? [])
    }

    // MARK: - Source identity

    /// A stable source identifier for grouping and persistence.
    func sourceID(for model: MaestroModel) -> String {
        model.sourceID
    }

    /// Human-readable source name for section headers.
    func sourceName(for model: MaestroModel) -> String {
        if model.isRemote, let kind = model.remoteProviderKind {
            switch kind {
            case .lmStudio:
                return "LM Studio"
            case .ollama:
                return "Ollama"
            case .online:
                // Try to recover the provider name from the display name
                // (formatted as "modelID · Provider Name").
                if let suffix = model.displayName.components(separatedBy: " · ").last {
                    return suffix
                }
                return "Online"
            }
        }
        return "Local MLX"
    }

    /// Badge metadata matching the model pickers.
    func sourceBadge(for model: MaestroModel) -> (icon: String, colorName: String) {
        model.providerBadge
    }

    // MARK: - Query state

    func isModelEnabled(_ modelID: String) -> Bool {
        !disabledModelIDs.contains(modelID)
    }

    func isSourceEnabled(_ sourceID: String) -> Bool {
        !disabledSourceIDs.contains(sourceID)
    }

    func isSourceCollapsed(_ sourceID: String) -> Bool {
        collapsedSourceIDs.contains(sourceID)
    }

    /// True when the model should appear in chat pickers.
    func isVisible(_ model: MaestroModel) -> Bool {
        guard !model.isHidden else { return false }
        let sid = sourceID(for: model)
        guard isSourceEnabled(sid) else { return false }
        return isModelEnabled(model.id)
    }

    /// Filter a catalog down to picker-visible models.
    func visibleModels(from models: [MaestroModel]) -> [MaestroModel] {
        models.filter { isVisible($0) }
    }

    /// Group models by source, preserving a deterministic order:
    /// Local MLX first, then LM Studio, Ollama, then online providers by name.
    func groupedModels(_ models: [MaestroModel]) -> [(sourceID: String, name: String, badge: (icon: String, colorName: String), models: [MaestroModel])] {
        var bySource: [String: (name: String, badge: (icon: String, colorName: String), models: [MaestroModel])] = [:]
        for model in models {
            let sid = sourceID(for: model)
            if bySource[sid] == nil {
                bySource[sid] = (name: sourceName(for: model), badge: sourceBadge(for: model), models: [])
            }
            bySource[sid]!.models.append(model)
        }

        // Stable ordering: local, lmStudio, ollama, then online providers alphabetically.
        return bySource.keys.sorted { lhs, rhs in
            let order: (String) -> Int = { id in
                if id == "local" { return 0 }
                if id == "remote-lmStudio" { return 1 }
                if id == "remote-ollama" { return 2 }
                return 3
            }
            let lhsOrder = order(lhs)
            let rhsOrder = order(rhs)
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return (bySource[lhs]?.name ?? lhs) < (bySource[rhs]?.name ?? rhs)
        }.map { ($0, bySource[$0]!.name, bySource[$0]!.badge, bySource[$0]!.models) }
    }

    // MARK: - Mutations

    func setModelEnabled(_ modelID: String, enabled: Bool) {
        if enabled {
            disabledModelIDs.remove(modelID)
        } else {
            disabledModelIDs.insert(modelID)
        }
        persist()
    }

    func setSourceEnabled(_ sourceID: String, enabled: Bool) {
        if enabled {
            disabledSourceIDs.remove(sourceID)
        } else {
            disabledSourceIDs.insert(sourceID)
        }
        persist()
    }

    func toggleSourceCollapsed(_ sourceID: String) {
        if collapsedSourceIDs.contains(sourceID) {
            collapsedSourceIDs.remove(sourceID)
        } else {
            collapsedSourceIDs.insert(sourceID)
        }
        persist()
    }

    /// Enable every model and source (useful for a "show all" reset).
    func enableAll() {
        disabledModelIDs.removeAll()
        disabledSourceIDs.removeAll()
        persist()
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(Array(disabledModelIDs), forKey: Self.disabledModelsKey)
        defaults.set(Array(disabledSourceIDs), forKey: Self.disabledSourcesKey)
        defaults.set(Array(collapsedSourceIDs), forKey: Self.collapsedSourcesKey)
    }
}

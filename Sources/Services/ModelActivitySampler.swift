import Foundation
import Observation

// MARK: - Model Activity

/// Activity state for a single loaded model.
enum ModelActivityState: String, Sendable {
    case idle
    case loading
    case generating
}

/// A single tok/s sample for sparkline history.
struct ModelActivitySample: Sendable {
    let timestamp: Date
    let tokensPerSecond: Double
}

/// Activity tracking for one model.
struct ModelActivity: Identifiable {
    let id: String
    var name: String
    var estimatedMemoryGB: Int

    var state: ModelActivityState = .idle
    var currentTokensPerSecond: Double = 0
    var history: [ModelActivitySample] = []
    var lastUsed: Date?

    private var tokenBucketStart = Date()
    private var tokensInBucket = 0

    init(
        id: String,
        name: String,
        estimatedMemoryGB: Int,
        state: ModelActivityState = .idle,
        currentTokensPerSecond: Double = 0,
        history: [ModelActivitySample] = [],
        lastUsed: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.estimatedMemoryGB = estimatedMemoryGB
        self.state = state
        self.currentTokensPerSecond = currentTokensPerSecond
        self.history = history
        self.lastUsed = lastUsed
    }

    mutating func startGeneration() {
        state = .generating
        currentTokensPerSecond = 0
        tokenBucketStart = Date()
        tokensInBucket = 0
    }

    mutating func stopGeneration() {
        state = .idle
        currentTokensPerSecond = 0
    }

    mutating func setLoading() {
        state = .loading
        currentTokensPerSecond = 0
    }

    mutating func recordToken() {
        let now = Date()
        lastUsed = now
        tokensInBucket += 1

        let elapsed = now.timeIntervalSince(tokenBucketStart)
        if elapsed >= 1.0 {
            let tps = Double(tokensInBucket) / elapsed
            currentTokensPerSecond = tps
            history.append(ModelActivitySample(
                timestamp: now, tokensPerSecond: tps))
            // Keep 60 seconds of history at 2 samples/sec.
            if history.count > 120 { history.removeFirst() }
            tokenBucketStart = now
            tokensInBucket = 0
        }
    }
}

// MARK: - Sampler

/// Tracks per-model generation activity (state, tok/s, sparkline history).
/// Observed by `ModelResourceMonitor` for a live model dashboard.
@Observable
@MainActor
final class ModelActivitySampler {
    static let shared = ModelActivitySampler()

    private(set) var models: [String: ModelActivity] = [:]

    private init() {}

    /// Register or update a model's metadata. Does not change its activity state.
    func register(_ model: MaestroModel, state: ModelActivityState = .idle) {
        if var existing = models[model.id] {
            existing.name = model.displayName
            existing.estimatedMemoryGB = model.estimatedMemoryGB
            if state != .idle { existing.state = state }
            models[model.id] = existing
        } else {
            models[model.id] = ModelActivity(
                id: model.id,
                name: model.displayName,
                estimatedMemoryGB: model.estimatedMemoryGB,
                state: state)
        }
    }

    /// Mark a model as loading (e.g. while `MLXInferenceEngine` is loading weights).
    func setLoading(id: String) {
        guard models[id] != nil else { return }
        models[id]!.setLoading()
    }

    /// Mark a model as generating and reset its token bucket.
    func startGeneration(id: String) {
        guard models[id] != nil else { return }
        models[id]!.startGeneration()
    }

    /// Record one token for the model's tok/s calculation.
    func recordToken(id: String) {
        guard models[id] != nil else { return }
        models[id]!.recordToken()
    }

    /// Mark a model as idle.
    func stopGeneration(id: String) {
        guard models[id] != nil else { return }
        models[id]!.stopGeneration()
    }

    /// Remove a model that has been evicted from memory.
    func remove(id: String) {
        models.removeValue(forKey: id)
    }

    /// Prune models that have been idle for a long time.
    func pruneInactive(cutoff: TimeInterval = 300) {
        let cutoffDate = Date().addingTimeInterval(-cutoff)
        models = models.filter { _, activity in
            activity.state != .idle ||
            (activity.lastUsed ?? Date()) > cutoffDate
        }
    }
}

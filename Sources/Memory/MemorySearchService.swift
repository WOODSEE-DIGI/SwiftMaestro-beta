import Foundation

/// Coordinates the FTS memory index so a hot `memory_search` call never blocks
/// on a full store reindex, and the index stays warm in the background.
///
/// A first full build of the shared AI Memory store (tens of thousands of
/// files) can take a couple of minutes because every file's content is read to
/// build the token index. Running that on the caller's critical path would make
/// the first search hang. Instead this service:
///
///  - Owns the lazily-created shared ``MemorySearchEngine``.
///  - Answers ``search`` from the *current* index immediately (sub-millisecond).
///  - Keeps the index fresh with a single, cooldown-gated background refresh so
///    the expensive first build happens exactly once.
///  - Returns `nil` while the index is still cold so the caller can fall back to
///    the file-walking ``SimpleMemoryStore.search`` for an immediate answer.
///
/// The heavy `reindex()` runs on a detached utility task so the actor and the
/// UI never block; only the small bookkeeping (starting/finishing a refresh)
/// touches actor-isolated state.
actor MemorySearchService {

    static let shared = MemorySearchService()

    /// Minimum seconds between incremental background refreshes of the index.
    private static let refreshCooldown: TimeInterval = 60

    private var engine: MemorySearchEngine?
    private var refreshTask: Task<Void, Never>?
    private var lastRefreshAt: Date?

    /// Test seam: build the service around a specific engine (e.g. one backed by
    /// a temp memory root and temp index) instead of the process-wide shared one.
    init(engine: MemorySearchEngine? = nil) {
        self.engine = engine
    }

    // MARK: - Lifecycle

    private func loadEngine() -> MemorySearchEngine? {
        if let engine { return engine }
        let eng = MemorySearchEngine.shared()
        engine = eng
        return eng
    }

    /// Kick off a background index build/refresh. Returns immediately — the
    /// heavy walk may still be running when this returns. Intended to be called
    /// once at app launch so the store is warm by the time the user searches.
    func warm() async {
        guard let engine = loadEngine() else { return }
        startRefresh(engine: engine)
    }

    // MARK: - Search

    /// Search the current index. Returns `nil` if the index isn't ready yet so
    /// the caller can fall back to the file-walking scan for an instant answer.
    /// While the index is warm this returns matches from the freshest available
    /// index and, if the cooldown has elapsed, schedules a background refresh.
    func search(_ query: String, limit: Int = 20) async -> [MemorySearchEngine.SearchResult]? {
        guard let engine = loadEngine() else { return nil }

        let cold = engine.indexedCount == 0
        let stale = lastRefreshAt.map { Date().timeIntervalSince($0) > Self.refreshCooldown } ?? true

        if cold || stale {
            startRefresh(engine: engine)
        }

        // No index yet: tell the caller to fall back rather than returning
        // nothing (which would be indistinguishable from "no matches").
        guard !cold else { return nil }
        return (try? engine.search(query, limit: limit)) ?? []
    }

    // MARK: - Background refresh

    /// Spawn the (single) background refresh. Guards against stacking duplicate
    /// walks; the actual reindex runs on a detached utility task so the actor
    /// isn't blocked while the store is being scanned.
    private func startRefresh(engine: MemorySearchEngine) {
        guard refreshTask == nil else { return }
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            try? engine.reindex()
            await self?.markRefreshDone()
        }
    }

    private func markRefreshDone() {
        refreshTask = nil
        lastRefreshAt = Date()
    }
}

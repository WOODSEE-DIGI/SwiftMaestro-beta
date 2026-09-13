import Foundation

// MARK: - Async Semaphore
actor AsyncSemaphore {
    private var count: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var throwingWaiters: [CheckedContinuation<Void, Error>] = []

    init(value: Int) { self.count = value }
    init(permits: Int) { self.count = permits }

    /// Cancellation-aware acquire.
    func acquire() async throws {
        if count > 0 {
            count -= 1
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            throwingWaiters.append(continuation)
        }
    }

    func release() async {
        if !throwingWaiters.isEmpty {
            let next = throwingWaiters.removeFirst()
            next.resume()
        } else if !waiting.isEmpty {
            let next = waiting.removeFirst()
            next.resume()
        } else {
            count += 1
        }
    }

    /// Run an operation after acquiring a permit, releasing it afterward.
    func withPermit<T>(operation: () async throws -> T) async throws -> T {
        try await acquire()
        defer { Task { await release() } }
        return try await operation()
    }

    /// Adjust the permit count dynamically. Positive deltas resume waiters.
    func setPermits(_ newValue: Int) {
        let newCount = max(0, newValue)
        let delta = newCount - count
        count = newCount
        let resumed = min(delta, throwingWaiters.count)
        for _ in 0..<resumed {
            let waiter = throwingWaiters.removeFirst()
            waiter.resume()
        }
        let resumedLegacy = min(delta - resumed, waiting.count)
        for _ in 0..<resumedLegacy {
            let waiter = waiting.removeFirst()
            waiter.resume()
        }
    }
}

// MARK: - Shell Execution Queue (actor)

public actor ShellExecutionQueue {

    public static let shared = ShellExecutionQueue(maxConcurrent: 2)

    public let maxConcurrent: Int
    public private(set) var activeCount: Int = 0

    private let semaphore: AsyncSemaphore

    public init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
        self.semaphore = AsyncSemaphore(value: maxConcurrent)
    }

    // MARK: – Concurrency‑controlled execution

    /// Execute a shell command with concurrency control.
    ///
    /// - Parameter work: An async closure that performs the actual shell work.
    /// - Returns: The value produced by `work`.
    public func execute<T>(_ work: @escaping () async throws -> T) async throws -> T {
        try await semaphore.acquire()
        incrementActiveCount()
        defer {
            Task { [weak self] in
                await self?.release()
            }
        }
        return try await work()
    }

    private func incrementActiveCount() { activeCount += 1 }

    /// Called only from within the actor to decrement the active count and free a semaphore slot.
    private func release() async {
        activeCount -= 1
        await semaphore.release()
    }

    // MARK: – Query the queue -------------------------------------------------
    public func canAcceptMore() -> Bool {
        activeCount < maxConcurrent
    }
}

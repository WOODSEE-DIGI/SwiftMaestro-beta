import Foundation

// MARK: - Async Semaphore (unchanged)
actor AsyncSemaphore {
    private var count: Int
    private let queue = DispatchQueue(label: "shell.semaphore")
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(value: Int) { self.count = value }

    func acquire() async {
        if count > 0 { count -= 1 }
        else { await withCheckedContinuation { waiting.append($0) } }
    }

    func release() async {
        if !waiting.isEmpty {
            let next = waiting.removeFirst()
            next.resume()
        } else {
            count += 1
        }
    }
}

// MARK: - Shell Execution Queue (actor)

public actor ShellExecutionQueue {

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
        await semaphore.acquire()
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

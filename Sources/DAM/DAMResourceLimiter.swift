import Foundation
import SwiftUI

// MARK: - Errors

enum DAMResourceError: Error, LocalizedError {
    case thermalCritical
    case insufficientMemory(requiredGB: Double, availableGB: Double)
    case timeout(operation: String, seconds: TimeInterval)
    case resourceUnavailable

    var errorDescription: String? {
        switch self {
        case .thermalCritical:
            return "Thermal state is critical — heavy work paused until the system cools."
        case .insufficientMemory(let required, let available):
            return String(format: "Need %.1f GB free memory, only %.1f GB available.", required, available)
        case .timeout(let operation, let seconds):
            return "\(operation) timed out after \(Int(seconds))s."
        case .resourceUnavailable:
            return "System resources are currently unavailable for this task."
        }
    }
}

// MARK: - Limit policy

/// The concrete limits derived from a resource snapshot.
struct DAMResourceLimit: Sendable {
    let maxConcurrentHeavyTasks: Int
    let operationTimeoutSeconds: TimeInterval
    let minAvailableMemoryGB: Double
    let frameCapForVideo: Int
    let requiresCooldown: Bool

    static func from(_ resources: DAMSystemResources) -> DAMResourceLimit {
        let thermal = resources.thermalState

        // Base concurrency on thermal state and available memory.
        let baseConcurrency: Int
        let timeout: TimeInterval
        let minMemory: Double
        let cooldown: Bool

        switch thermal {
        case .nominal:
            baseConcurrency = max(1, resources.activeProcessorCount / 2)
            timeout = 60
            minMemory = 1.0
            cooldown = false
        case .fair:
            baseConcurrency = max(1, resources.activeProcessorCount / 3)
            timeout = 45
            minMemory = 1.5
            cooldown = false
        case .serious:
            baseConcurrency = 1
            timeout = 30
            minMemory = 2.0
            cooldown = true
        case .critical:
            baseConcurrency = 0
            timeout = 15
            minMemory = 4.0
            cooldown = true
        @unknown default:
            baseConcurrency = 1
            timeout = 45
            minMemory = 1.5
            cooldown = false
        }

        // If memory is tight, drop concurrency further and tighten timeout.
        var concurrency = baseConcurrency
        if resources.availableMemoryGB < 4.0 {
            concurrency = max(1, concurrency - 1)
        }
        if resources.availableMemoryGB < 2.5 {
            concurrency = 1
        }

        // Cap video frames by available memory: rough rule of 1 frame per 0.5 GB free,
        // never below 10 and never above the user's configured maximum.
        let memoryFrameCap = Int(resources.availableMemoryGB / 0.5)
        let frameCap = max(10, min(memoryFrameCap, 120))

        return DAMResourceLimit(
            maxConcurrentHeavyTasks: concurrency,
            operationTimeoutSeconds: timeout,
            minAvailableMemoryGB: minMemory,
            frameCapForVideo: frameCap,
            requiresCooldown: cooldown
        )
    }
}

// MARK: - Status (UI-facing)

/// Live status published to the UI so users can see why scans are queued or
/// throttled.
@MainActor
@Observable
final class DAMResourceStatus {
    static let shared = DAMResourceStatus()

    private init() {}

    var activeHeavyTasks = 0
    var queuedHeavyTasks = 0
    var lastSnapshot: DAMSystemResources?
    var lastLimit: DAMResourceLimit?
    var lastError: String?

    var isThrottled: Bool {
        guard let limit = lastLimit else { return false }
        return limit.maxConcurrentHeavyTasks <= 1
    }
}

// MARK: - Limiter

/// Central gatekeeper for expensive on-device work. Refreshes the system
/// resource snapshot before each operation, refuses work when thermal/memory
/// conditions are unsafe, enforces timeouts, and serialises/throttles heavy
/// tasks with an async semaphore.
actor DAMResourceLimiter {
    static let shared = DAMResourceLimiter()

    private var semaphore = AsyncSemaphore(permits: 2)
    private var snapshot = DAMSystemResources.current()
    private var limit = DAMResourceLimit.from(DAMSystemResources.current())

    private init() {}

    /// Latest resource snapshot.
    var currentSnapshot: DAMSystemResources { snapshot }

    /// Latest computed limits.
    var currentLimit: DAMResourceLimit { limit }

    /// Refresh the snapshot and recompute limits + semaphore permits.
    func refresh() {
        snapshot = DAMSystemResources.current()
        limit = DAMResourceLimit.from(snapshot)
        Task { await semaphore.setPermits(limit.maxConcurrentHeavyTasks) }

        let capturedSnapshot = snapshot
        let capturedLimit = limit
        Task { @MainActor in
            DAMResourceStatus.shared.lastSnapshot = capturedSnapshot
            DAMResourceStatus.shared.lastLimit = capturedLimit
        }
    }

    /// Run an operation under the heavy-work gate. Throws if thermal state is
    /// critical, memory is below the safe threshold, or the operation times out.
    func withHeavyTask<T: Sendable>(
        name: String,
        timeout: TimeInterval? = nil,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        refresh()

        guard snapshot.thermalState != .critical else {
            await publishError(DAMResourceError.thermalCritical.localizedDescription)
            throw DAMResourceError.thermalCritical
        }
        guard snapshot.availableMemoryGB >= limit.minAvailableMemoryGB else {
            let error = DAMResourceError.insufficientMemory(
                requiredGB: limit.minAvailableMemoryGB,
                availableGB: snapshot.availableMemoryGB
            )
            await publishError(error.localizedDescription)
            throw error
        }

        await MainActor.run {
            DAMResourceStatus.shared.queuedHeavyTasks += 1
        }
        defer {
            Task { @MainActor in
                DAMResourceStatus.shared.queuedHeavyTasks = max(0, DAMResourceStatus.shared.queuedHeavyTasks - 1)
            }
        }

        try await semaphore.acquire()
        await MainActor.run {
            DAMResourceStatus.shared.activeHeavyTasks += 1
            DAMResourceStatus.shared.queuedHeavyTasks = max(0, DAMResourceStatus.shared.queuedHeavyTasks - 1)
        }
        defer {
            Task { @MainActor in
                DAMResourceStatus.shared.activeHeavyTasks = max(0, DAMResourceStatus.shared.activeHeavyTasks - 1)
            }
            Task { await semaphore.release() }
        }

        let effectiveTimeout = timeout ?? limit.operationTimeoutSeconds
        do {
            let result: T
            if effectiveTimeout.isInfinite {
                result = try await operation()
            } else {
                result = try await withTimeout(seconds: effectiveTimeout, operation: operation)
            }
            await cooldownIfNeeded()
            return result
        } catch is TimeoutError {
            let error = DAMResourceError.timeout(operation: name, seconds: effectiveTimeout)
            await publishError(error.localizedDescription)
            throw error
        } catch {
            throw error
        }
    }

    /// Returns the current video frame cap, clamped by the dynamic memory limit
    /// but never below the user's minimum.
    func videoFrameCap(userMaxFrames: Int) -> Int {
        refresh()
        return max(DAMTaggingService.videoTaggingConfig.minFrames,
                   min(limit.frameCapForVideo, userMaxFrames))
    }

    /// Pause briefly when thermal/memory is elevated so the system can recover
    /// before the next heavy task starts.
    private func cooldownIfNeeded() async {
        if limit.requiresCooldown {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func publishError(_ message: String) async {
        await MainActor.run {
            DAMResourceStatus.shared.lastError = message
        }
    }

    // MARK: - Timeout helper

    struct TimeoutError: Error {}

    /// Run an operation with a hard deadline. Public so callers already inside
    /// a resource gate can apply per-step timeouts without nesting permits.
    nonisolated func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            guard let result = try await group.next() else {
                throw DAMResourceError.resourceUnavailable
            }
            group.cancelAll()
            return result
        }
    }
}

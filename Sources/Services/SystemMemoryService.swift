import Foundation

/// A point-in-time breakdown of SYSTEM-WIDE memory, read via
/// `host_statistics64`.
///
/// Unlike `ProcessInfo.physicalMemory` (a static total), these buckets reflect
/// what every process on the machine is holding right now — INCLUDING other
/// logged-in user sessions under fast user switching, whose wired GPU heaps are
/// otherwise invisible to per-app accounting. (The 0.3.6 demo-machine crash:
/// Gemma 4 + Qwen3-Coder-Next loaded on top of the main session's resident
/// models, 2026-08-20.)
struct SystemMemorySnapshot: Sendable, Equatable {
    /// Total physical RAM.
    let totalBytes: Int
    /// Wired (never pageable) — includes GPU heaps and other sessions' models.
    let wiredBytes: Int
    /// Active anonymous application memory.
    let usedBytes: Int
    /// Reclaimable: inactive + purgeable + speculative (file cache etc.).
    let cacheBytes: Int
    /// Held by the compressor (compressed anonymous pages).
    let compressedBytes: Int
    /// Completely untouched.
    let freeBytes: Int
    /// Anything not accounted for above (physical total minus the buckets).
    let otherBytes: Int

    /// What a new allocation can realistically reclaim:
    /// free + inactive + purgeable + speculative. This is the availability
    /// figure the engine's model-load guard uses.
    var availableBytes: Int { freeBytes + cacheBytes }
}

enum SystemMemory {
    /// Read the current system-wide memory breakdown. Returns nil only if the
    /// kernel call itself fails (callers should fail-open — never block a
    /// feature because a statistic was unavailable).
    static func snapshot() -> SystemMemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        // getpagesize() instead of vm_page_size — the latter is a mutable
        // Darwin global and trips Swift 6 strict-concurrency checks.
        let page = Int(getpagesize())
        let total = Int(ProcessInfo.processInfo.physicalMemory)
        let wired = Int(stats.wire_count) * page
        let used = Int(stats.active_count) * page
        let cache = (Int(stats.inactive_count) + Int(stats.purgeable_count) + Int(stats.speculative_count)) * page
        let compressed = Int(stats.compressor_page_count) * page
        let free = Int(stats.free_count) * page
        let other = max(0, total - wired - used - cache - compressed - free)

        return SystemMemorySnapshot(
            totalBytes: total,
            wiredBytes: wired,
            usedBytes: used,
            cacheBytes: cache,
            compressedBytes: compressed,
            freeBytes: free,
            otherBytes: other)
    }

    /// System-wide available bytes, or -1 when the kernel call fails.
    /// Same semantics the model-load guard had before this extraction.
    static func availableMemoryBytes() -> Int {
        snapshot()?.availableBytes ?? -1
    }
}

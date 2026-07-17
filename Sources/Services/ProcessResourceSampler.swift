import Foundation
import Darwin
import Observation

// MARK: - Process Snapshot

/// Lightweight snapshot of the running SwiftMaestro process.
struct ProcessSnapshot: Sendable, Identifiable {
    let id: Int32
    let name: String
    let cpuPercent: Double
    let memoryBytes: UInt64
    let threads: Int
    let timestamp: Date
}

// MARK: - Collector

/// Collects per-process CPU and memory metrics using Darwin/libproc APIs.
/// This mirrors the approach used in the Apex Flow system monitor.
actor ProcessCollector {
    private var previousCPUTime: UInt64?
    private var previousTime: Date?

    /// mach absolute time -> nanoseconds conversion. On Apple Silicon this is 1:1;
    /// on Intel it is not, so we convert to be correct on both architectures.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    func collect(pid: Int32 = getpid()) -> ProcessSnapshot? {
        let now = Date()

        var taskInfo = proc_taskinfo()
        let infoSize = proc_pidinfo(
            pid, PROC_PIDTASKINFO, 0,
            &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
        guard infoSize > 0 else { return nil }

        // Use physical memory footprint to match Xcode's debug navigator.
        // phys_footprint includes resident + compressed + swap, whereas
        // pti_resident_size is only RSS and under-reports large MLX models.
        let memBytes = physicalFootprint() ?? taskInfo.pti_resident_size
        let cpuTime = taskInfo.pti_total_user + taskInfo.pti_total_system
        let threads = Int(taskInfo.pti_threadnum)

        var cpuPercent: Double = 0
        if let prevCPU = previousCPUTime, let prevTime = previousTime {
            let elapsed = now.timeIntervalSince(prevTime)
            let deltaCPU = cpuTime >= prevCPU ? cpuTime - prevCPU : 0
            let deltaNS = deltaCPU * UInt64(Self.timebase.numer) / UInt64(Self.timebase.denom)
            if elapsed > 0 {
                cpuPercent = 100.0 * Double(deltaNS) / (elapsed * 1_000_000_000.0)
            }
        }

        previousCPUTime = cpuTime
        previousTime = now

        return ProcessSnapshot(
            id: pid,
            name: ProcessInfo.processInfo.processName,
            cpuPercent: max(0, cpuPercent),
            memoryBytes: memBytes,
            threads: threads,
            timestamp: now
        )
    }

    private func physicalFootprint() -> UInt64? {
        var vmInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return nil }
        return vmInfo.phys_footprint
    }
}

// MARK: - Subagent Activity

/// Lightweight status for a delegated sub-agent. Sub-agents run in-process, so
/// they share the host CPU/memory graph; this tracks their own generation
/// activity (tokens/second) so the resource monitor can surface them.
struct SubagentStatus: Sendable, Identifiable {
    let id: String
    let name: String
    let startTime: Date
    var isGenerating = true
    var lastTokenTime: Date?
    var tokensPerSecond: Double = 0
    private var tokenBucketStart: Date
    private var tokensInBucket: Int

    init(id: String, name: String) {
        self.id = id
        self.name = name
        self.startTime = Date()
        self.tokenBucketStart = Date()
        self.tokensInBucket = 0
    }

    mutating func recordToken() {
        let now = Date()
        lastTokenTime = now
        tokensInBucket += 1
        let elapsed = now.timeIntervalSince(tokenBucketStart)
        if elapsed >= 1.0 {
            tokensPerSecond = Double(tokensInBucket) / elapsed
            tokenBucketStart = now
            tokensInBucket = 0
        }
    }

    mutating func stop() {
        isGenerating = false
        tokensPerSecond = 0
    }
}

// MARK: - Sampler / Monitor

/// Shared sampler for SwiftMaestro's own process resources and generation activity.
/// Attach the compact `ProcessResourceMonitor` view to surface this in the UI.
@Observable
@MainActor
final class ProcessResourceSampler {
    static let shared = ProcessResourceSampler()

    struct Sample: Sendable {
        let timestamp: Date
        let cpuPercent: Double
        let memoryBytes: UInt64
        let threads: Int
    }

    private(set) var current: Sample?
    private(set) var history: [Sample] = []

    private(set) var isGenerating = false
    private(set) var lastTokenTime: Date?
    private(set) var tokenCount = 0
    private(set) var tokensPerSecond: Double = 0

    /// Delegated sub-agent activity, keyed by agent ID.
    private(set) var subagents: [String: SubagentStatus] = [:]

    private let collector = ProcessCollector()
    private var samplingTask: Task<Void, Never>?
    private var tokenBucketStart = Date()
    private var tokensInBucket = 0

    /// True when the engine reports generation and no token/CPU activity has
    /// been seen for a while. This is a heuristic, not a hang detector.
    var isStuck: Bool {
        guard isGenerating else { return false }
        let silentThreshold: TimeInterval = 15.0
        // CPU activity means the model is working even if no token has been
        // emitted yet (long prefill/thinking on large models), so treat the
        // most recent of token time or CPU-activity time as the last activity.
        let lastActivity = max(lastTokenTime ?? tokenBucketStart, tokenBucketStart)
        return Date().timeIntervalSince(lastActivity) > silentThreshold
    }

    var status: String {
        if isStuck { return "May be stuck" }
        if isGenerating {
            if tokensPerSecond > 0 {
                return String(format: "Generating %.1f tok/s", tokensPerSecond)
            }
            // High CPU with zero tok/s usually means a long prefill/thinking
            // phase on a large model, not an actual stall.
            if (current?.cpuPercent ?? 0) > 10.0 {
                return "Thinking…"
            }
            return "Generating…"
        }
        return "Idle"
    }

    private init() {}

    func start() {
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                // 500ms gives a much more responsive CPU readout (closer to Xcode's
                // debug navigator) while keeping overhead negligible.
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    // MARK: - Generation lifecycle

    func startGeneration() {
        isGenerating = true
        tokenBucketStart = Date()
        tokensInBucket = 0
        tokensPerSecond = 0
    }

    func recordToken() {
        let now = Date()
        lastTokenTime = now
        tokenCount += 1
        tokensInBucket += 1

        let elapsed = now.timeIntervalSince(tokenBucketStart)
        if elapsed >= 1.0 {
            tokensPerSecond = Double(tokensInBucket) / elapsed
            tokenBucketStart = now
            tokensInBucket = 0
        }
    }

    func stopGeneration() {
        isGenerating = false
        tokensPerSecond = 0
    }

    // MARK: - Subagent lifecycle

    func startSubagent(id: String, name: String) {
        subagents[id] = SubagentStatus(id: id, name: name)
    }

    func recordSubagentToken(id: String) {
        guard subagents[id] != nil else { return }
        subagents[id]!.recordToken()
    }

    func stopSubagent(id: String) {
        guard subagents[id] != nil else { return }
        subagents[id]!.stop()
    }

    /// Remove sub-agents that finished more than a few minutes ago so the UI
    /// doesn't accumulate stale entries.
    private func pruneInactiveSubagents() {
        let cutoff = Date().addingTimeInterval(-300)
        subagents = subagents.filter { _, status in
            status.isGenerating || (status.lastTokenTime ?? status.startTime) > cutoff
        }
    }

    // MARK: - Sampling

    private func sample() async {
        guard let snapshot = await collector.collect() else { return }

        let sample = Sample(
            timestamp: snapshot.timestamp,
            cpuPercent: snapshot.cpuPercent,
            memoryBytes: snapshot.memoryBytes,
            threads: snapshot.threads
        )

        current = sample
        history.append(sample)
        // Keep 60 seconds of history at 2 samples/sec.
        if history.count > 120 { history.removeFirst() }

        pruneInactiveSubagents()

        // If CPU is clearly active, the process is not stuck even without tokens
        // (e.g. long prefill or model loading).
        if sample.cpuPercent > 2.0 {
            tokenBucketStart = Date()
        }
    }
}

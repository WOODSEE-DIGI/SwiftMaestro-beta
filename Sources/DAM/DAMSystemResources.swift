import Foundation
import Metal
import os

// MARK: - System resource snapshot

/// A lightweight snapshot of the Mac's current resource situation. Used by
/// `DAMResourceLimiter` to set dynamic concurrency, timeout, and backoff
/// limits before starting heavy on-device work.
struct DAMSystemResources: Sendable, CustomStringConvertible {
    let thermalState: ProcessInfo.ThermalState
    let physicalMemoryBytes: UInt64
    let availableMemoryBytes: UInt64
    let activeProcessorCount: Int
    let gpuName: String
    let hasUnifiedMemory: Bool
    let gpuRecommendedVRAMBytes: UInt64?
    let timestamp: Date

    var availableMemoryGB: Double {
        Double(availableMemoryBytes) / 1_073_741_824.0
    }

    var physicalMemoryGB: Double {
        Double(physicalMemoryBytes) / 1_073_741_824.0
    }

    var isAppleSilicon: Bool {
        hasUnifiedMemory || gpuName.lowercased().contains("apple")
    }

    var description: String {
        String(
            format: "%.1f GB available / %.1f GB total, thermal=%@, cores=%d, gpu=%@",
            availableMemoryGB,
            physicalMemoryGB,
            thermalState.description,
            activeProcessorCount,
            gpuName
        )
    }

    /// Captures a fresh snapshot of the machine's resources.
    static func current() -> DAMSystemResources {
        let device = MTLCreateSystemDefaultDevice()
        let vram = device?.recommendedMaxWorkingSetSize
        return DAMSystemResources(
            thermalState: ProcessInfo.processInfo.thermalState,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            availableMemoryBytes: Self.availableMemoryBytes(),
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            gpuName: device?.name ?? "Unknown",
            hasUnifiedMemory: device?.hasUnifiedMemory ?? false,
            gpuRecommendedVRAMBytes: vram,
            timestamp: Date()
        )
    }

    // MARK: - Mach memory query

    /// Returns the approximate amount of memory available for new allocations
    /// (free + inactive + speculative) in bytes. Falls back to physical memory
    /// if the Mach call fails.
    private static func availableMemoryBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }

        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { bound in
                host_statistics64(hostPort, HOST_VM_INFO64, bound, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return ProcessInfo.processInfo.physicalMemory
        }

        var pageSize: vm_size_t = 0
        guard host_page_size(hostPort, &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return ProcessInfo.processInfo.physicalMemory
        }

        let availablePages = stats.free_count
            + stats.inactive_count
            + stats.speculative_count
        return UInt64(availablePages) * UInt64(pageSize)
    }
}

// MARK: - Thermal state description

extension ProcessInfo.ThermalState {
    var description: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

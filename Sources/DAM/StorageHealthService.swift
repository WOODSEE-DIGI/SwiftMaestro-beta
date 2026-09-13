import Foundation
import GRDB

// MARK: - Storage health model

/// A single user-visible fault condition for a storage volume.
struct StorageHealthFault: Sendable, Hashable, Identifiable {
    let id = UUID()
    var severity: Severity
    var title: String
    var detail: String
    var action: String

    enum Severity: String, Sendable, Hashable {
        case info, warning, critical
    }
}

/// A snapshot of a volume's physical health as reported by diskutil / smartctl.
/// Stored as JSON on `DAMVolume.healthJSON`.
struct StorageHealth: Codable, Sendable, Hashable {
    enum Status: String, Codable, Sendable, Hashable {
        case healthy, caution, failing, unknown, unsupported
    }

    var status: Status
    var smartStatus: String?
    var busProtocol: String?
    var isSSD: Bool?
    var temperatureC: Int?
    var powerOnHours: Int?
    var wearLevelPercent: Int?
    var reallocatedSectorCount: Int?
    var pendingSectorCount: Int?
    var criticalWarning: String?
    var percentageUsed: Int?
    var message: String?
    var capturedAt: Date

    // Volume / filesystem checks
    var freeSpacePercent: Int?
    var filesystemVerifyOK: Bool?
    var filesystemVerifyMessage: String?
    var fileVaultEnabled: Bool?
    var encryptionEnabled: Bool?
    var timeMachineLastBackup: Date?

    // Extra SMART / mechanical counters
    var powerCycleCount: Int?
    var startStopCount: Int?
    var loadCycleCount: Int?
    var udmaCRCErrorCount: Int?
    var offlineUncorrectable: Int?
    var gSenseErrorRate: Int?
    var multiZoneErrorCount: Int?

    /// True when the snapshot suggests the drive should be replaced soon.
    var recommendsReplacement: Bool {
        faults.contains { $0.severity == .critical }
    }

    // MARK: - Human-readable fault summary

    /// A list of every condition that contributed to the health score or
    /// replacement recommendation, ordered from most to least severe.
    var faults: [StorageHealthFault] {
        var result: [StorageHealthFault] = []

        if status == .failing {
            result.append(StorageHealthFault(
                severity: .critical,
                title: "SMART reports failing",
                detail: "The drive’s self-monitoring firmware has reported a failing status. Data loss is possible.",
                action: "Back up immediately and replace the drive."
            ))
        }

        if let criticalWarning {
            result.append(StorageHealthFault(
                severity: .critical,
                title: "NVMe critical warning",
                detail: "Controller reported a critical warning: \(criticalWarning).",
                action: "Back up immediately and replace the drive."
            ))
        }

        if filesystemVerifyOK == false {
            result.append(StorageHealthFault(
                severity: .critical,
                title: "Filesystem verification failed",
                detail: self.filesystemVerifyMessage ?? "diskutil verifyVolume did not report the volume as OK.",
                action: "Run First Aid on the volume in Disk Utility, then back up important data."
            ))
        }

        if let reallocated = reallocatedSectorCount, reallocated > 0 {
            result.append(StorageHealthFault(
                severity: .critical,
                title: "Reallocated sectors detected",
                detail: "\(reallocated) sector(s) have been remapped because the drive could not read them reliably.",
                action: "Back up and replace the drive; reallocated sectors usually mean physical degradation."
            ))
        }

        if let pending = pendingSectorCount, pending > 0 {
            result.append(StorageHealthFault(
                severity: .critical,
                title: "Pending sectors detected",
                detail: "\(pending) sector(s) are waiting to be remapped. They may become readable again or may fail permanently.",
                action: "Clone the drive if possible, then replace it."
            ))
        }

        if let offline = offlineUncorrectable, offline > 0 {
            result.append(StorageHealthFault(
                severity: .critical,
                title: "Offline uncorrectable sectors",
                detail: "\(offline) sector(s) could not be corrected during offline testing.",
                action: "Replace the drive as soon as possible."
            ))
        }

        if let wear = wearLevelPercent, wear > 90 {
            result.append(StorageHealthFault(
                severity: .critical,
                title: "SSD wear level is very high",
                detail: "Wear leveling indicates the NAND has used \(wear)% of its rated life.",
                action: "Plan a replacement soon and keep backups current."
            ))
        }

        if let used = percentageUsed, used > 90 {
            result.append(StorageHealthFault(
                severity: .critical,
                title: "NVMe percentage used is very high",
                detail: "The drive reports \(used)% of its rated endurance used.",
                action: "Plan a replacement soon and keep backups current."
            ))
        }

        if let udma = udmaCRCErrorCount, udma > 0 {
            result.append(StorageHealthFault(
                severity: .warning,
                title: "UDMA CRC errors",
                detail: "\(udma) interface error(s) were detected. This is usually a cable, enclosure, or port issue rather than the drive itself.",
                action: "Try a different cable, port, or enclosure and monitor whether the count rises."
            ))
        }

        if let free = freeSpacePercent, free < 10 {
            result.append(StorageHealthFault(
                severity: .warning,
                title: "Very low free space",
                detail: "Only \(free)% of the volume is free. macOS and video workflows need headroom to avoid slowdowns or corruption.",
                action: "Free up space, archive old material, or expand storage."
            ))
        }

        if let temp = temperatureC, temp > 70 {
            result.append(StorageHealthFault(
                severity: .warning,
                title: "Drive temperature is high",
                detail: "Reported temperature is \(temp)°C, which can accelerate wear.",
                action: "Improve airflow, move the drive away from heat sources, or add a fan."
            ))
        }

        if status == .unknown || status == .unsupported {
            result.append(StorageHealthFault(
                severity: .info,
                title: "Limited health data",
                detail: "SMART data is unavailable or unsupported for this volume, so only filesystem and free-space checks are shown.",
                action: "Use Disk Utility or a dedicated SMART tool if you need deeper diagnostics."
            ))
        }

        return result
    }

    /// A 0-100 score where 100 is healthiest.
    /// Drives without SMART are not penalised — unsupported just means we
    /// cannot confirm health, not that health is degraded.
    var score: Int {
        var s = 100
        switch status {
        case .healthy: break
        case .caution: s -= 25
        case .failing: s -= 75
        case .unknown: s -= 5
        case .unsupported: break
        }
        if criticalWarning != nil { s -= 40 }
        if filesystemVerifyOK == false { s -= 20 }
        if let free = freeSpacePercent, free < 10 { s -= 10 }
        if let reallocated = reallocatedSectorCount, reallocated > 0 { s -= min(30, reallocated * 5) }
        if let pending = pendingSectorCount, pending > 0 { s -= min(30, pending * 5) }
        if let offline = offlineUncorrectable, offline > 0 { s -= 30 }
        if let udma = udmaCRCErrorCount, udma > 0 { s -= 15 }
        if let wear = wearLevelPercent { s -= wear / 4 }
        if let used = percentageUsed { s -= used / 4 }
        if let temp = temperatureC, temp > 70 { s -= 10 }
        return max(0, min(100, s))
    }
}

// MARK: - StorageHealthService
/// Gathers SMART / diskutil health snapshots for cataloged volumes.
/// Runs as an actor so diskutil processes don't overlap.
actor StorageHealthService {
    static let shared = StorageHealthService()

    private init() {}

    /// Updates the health columns for every supplied volume.
    func updateHealth(for volumes: [DAMVolume]) async {
        for volume in volumes where volume.isOnline {
            if let health = await healthSnapshot(for: volume) {
                await persist(health: health, for: volume)
            }
        }
    }

    /// Returns a fresh health snapshot for a single volume, or nil if the
    /// volume is offline or diskutil cannot be queried.
    func healthSnapshot(for volume: DAMVolume) async -> StorageHealth? {
        guard volume.isOnline else { return nil }

        // Prefer the cached mount point; fall back to looking it up by UUID.
        guard let mountPoint = await mountPoint(for: volume),
              let info = await diskutilInfo(at: mountPoint) else {
            return nil
        }

        var health = StorageHealth(
            status: statusFromDiskutil(info),
            smartStatus: info.smartStatus,
            busProtocol: info.busProtocol,
            isSSD: info.isSolidState,
            temperatureC: nil,
            powerOnHours: nil,
            wearLevelPercent: nil,
            reallocatedSectorCount: nil,
            pendingSectorCount: nil,
            criticalWarning: nil,
            percentageUsed: nil,
            message: nil,
            capturedAt: Date(),
            freeSpacePercent: nil,
            filesystemVerifyOK: nil,
            filesystemVerifyMessage: nil,
            fileVaultEnabled: nil,
            encryptionEnabled: nil,
            timeMachineLastBackup: nil,
            powerCycleCount: nil,
            startStopCount: nil,
            loadCycleCount: nil,
            udmaCRCErrorCount: nil,
            offlineUncorrectable: nil,
            gSenseErrorRate: nil,
            multiZoneErrorCount: nil
        )

        // Free space percentage.
        if let total = info.totalSize, total > 0, let free = info.freeSpace {
            health.freeSpacePercent = Int((Double(free) / Double(total)) * 100)
        }

        // Filesystem verify (read-only, with a short timeout).
        if let verify = await verifyVolume(at: mountPoint) {
            health.filesystemVerifyOK = verify.ok
            health.filesystemVerifyMessage = verify.message
        }

        // APFS volume properties (FileVault / encryption).
        if let device = info.deviceIdentifier,
           let container = info.apfsContainerReference {
            let props = await apfsVolumeProperties(deviceIdentifier: device, containerReference: container)
            health.fileVaultEnabled = props.fileVault
            health.encryptionEnabled = props.encryption
        }

        // Time Machine backup age (global, cached per refresh pass).
        health.timeMachineLastBackup = await timeMachineLatestBackup()

        // Enhance with smartctl if available (often requires root, so failure
        // is acceptable; we still keep the diskutil baseline).
        if let wholeDisk = info.parentWholeDisk ?? info.deviceIdentifier,
           smartctlPath() != nil {
            let smart = await smartctlHealth(for: wholeDisk)
            merge(smart: smart, into: &health)
        }

        if health.message == nil {
            health.message = healthMessage(for: health, info: info)
        }

        return health
    }

    // MARK: - Persistence

    private func persist(health: StorageHealth, for volume: DAMVolume) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(health),
              let json = String(data: data, encoding: .utf8) else { return }

        do {
            try await DAMDatabase.shared.dbQueue.write { db in
                try db.execute(
                    sql: """
                        UPDATE volume
                        SET healthJSON = ?,
                            healthWarnReplace = ?
                        WHERE id = ?
                        """,
                    arguments: [json, health.recommendsReplacement, volume.id ?? -1]
                )
            }
        } catch {
            NSLog("[StorageHealthService] persist failed: %@", String(describing: error))
        }
    }

    // MARK: - diskutil

    private struct DiskutilInfo: Sendable {
        var deviceIdentifier: String?
        var parentWholeDisk: String?
        var deviceNode: String?
        var volumeName: String?
        var busProtocol: String?
        var smartStatus: String?
        var isSolidState: Bool?
        var totalSize: Int64?
        var freeSpace: Int64?
        var apfsContainerReference: String?
    }

    private func mountPoint(for volume: DAMVolume) async -> URL? {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeUUIDStringKey],
            options: []
        ) else { return nil }
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]),
                  values.volumeUUIDString == volume.uuid else { continue }
            return url
        }
        return nil
    }

    private func diskutilInfo(at url: URL) async -> DiskutilInfo? {
        let (_, stdout, _) = await run("/usr/sbin/diskutil", arguments: ["info", "-plist", url.path])
        guard let data = stdout.data(using: .utf8) else { return nil }
        return parseDiskutilPlist(data)
    }

    private func parseDiskutilPlist(_ data: Data) -> DiskutilInfo? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: PropertyListSerialization.ReadOptions(), format: nil) as? [String: Any]
        else { return nil }

        return DiskutilInfo(
            deviceIdentifier: plist["DeviceIdentifier"] as? String,
            parentWholeDisk: plist["ParentWholeDisk"] as? String,
            deviceNode: plist["DeviceNode"] as? String,
            volumeName: plist["VolumeName"] as? String,
            busProtocol: plist["BusProtocol"] as? String,
            smartStatus: plist["SMARTStatus"] as? String,
            isSolidState: plist["SolidState"] as? Bool,
            totalSize: (plist["TotalSize"] as? NSNumber)?.int64Value,
            freeSpace: (plist["FreeSpace"] as? NSNumber)?.int64Value,
            apfsContainerReference: plist["APFSContainerReference"] as? String
        )
    }

    private func statusFromDiskutil(_ info: DiskutilInfo) -> StorageHealth.Status {
        if let smart = info.smartStatus {
            switch smart.lowercased() {
            case "verified": return .healthy
            case "failing": return .failing
            default: return .unsupported
            }
        }
        return .unknown
    }

    private func healthMessage(for health: StorageHealth, info: DiskutilInfo) -> String {
        if health.filesystemVerifyOK == false {
            return health.filesystemVerifyMessage ?? "Filesystem verification failed."
        }
        switch health.status {
        case .healthy:
            return "SMART status is verified."
        case .failing:
            return "SMART reported failing. Back up and replace this drive."
        case .unsupported:
            return "SMART is not supported or not available for this device."
        case .caution:
            return "Health indicators suggest caution."
        case .unknown:
            return info.smartStatus == nil
                ? "No SMART data available from diskutil."
                : "Health status could not be determined."
        }
    }

    // MARK: - Filesystem / volume checks

    private func verifyVolume(at url: URL) async -> (ok: Bool, message: String)? {
        // Large spinning disks and full APFS volumes can take minutes to verify,
        // so give diskutil a long leash. We key success on the final summary
        // line rather than the exit code, because a timeout from our side would
        // otherwise be recorded as a filesystem failure.
        let (_, stdout, _) = await run(
            "/usr/sbin/diskutil",
            arguments: ["verifyVolume", url.path],
            timeoutSeconds: 180
        )
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = trimmed.localizedStandardContains("appears to be OK")
        let message = ok
            ? "Filesystem verified"
            : (trimmed.components(separatedBy: "\n").last?.trimmingCharacters(in: .whitespaces) ?? "Verify failed")
        return (ok, message)
    }

    private func apfsVolumeProperties(
        deviceIdentifier: String,
        containerReference: String
    ) async -> (fileVault: Bool?, encryption: Bool?) {
        let (_, stdout, _) = await run(
            "/usr/sbin/diskutil",
            arguments: ["apfs", "list", "-plist", containerReference]
        )
        guard let data = stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: PropertyListSerialization.ReadOptions(), format: nil
              ) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else {
            return (nil, nil)
        }
        for container in containers {
            guard let volumes = container["Volumes"] as? [[String: Any]] else { continue }
            for volume in volumes {
                guard let dev = volume["DeviceIdentifier"] as? String,
                      dev == deviceIdentifier else { continue }
                return (
                    volume["FileVault"] as? Bool,
                    volume["Encryption"] as? Bool
                )
            }
        }
        return (nil, nil)
    }

    // MARK: - Time Machine

    private var cachedTimeMachineBackup: Date?
    private var cachedTimeMachineFetchAt: Date?

    private func timeMachineLatestBackup() async -> Date? {
        if let cached = cachedTimeMachineBackup,
           let fetchedAt = cachedTimeMachineFetchAt,
           Date().timeIntervalSince(fetchedAt) < 60 {
            return cached
        }
        let (_, stdout, _) = await run("/usr/bin/tmutil", arguments: ["latestbackup"])
        let path = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").first ?? ""
        guard !path.isEmpty else {
            cachedTimeMachineBackup = nil
            cachedTimeMachineFetchAt = Date()
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = TimeZone.current
        let last = (path as NSString).lastPathComponent
        let date = formatter.date(from: last)
        cachedTimeMachineBackup = date
        cachedTimeMachineFetchAt = Date()
        return date
    }

    // MARK: - smartctl

    private func smartctlPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/smartctl",
            "/usr/local/bin/smartctl",
            "/usr/sbin/smartctl",
            "/usr/bin/smartctl"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func smartctlHealth(for device: String) async -> StorageHealth? {
        let node = device.hasPrefix("/dev/") ? device : "/dev/\(device)"
        let path = smartctlPath() ?? "smartctl"
        // Cap smartctl at 25s so a sleeping/bad USB drive can't hang the
        // health actor indefinitely and stall subsequent volume checks.
        let (_, stdout, _) = await run(path, arguments: ["-a", node], timeoutSeconds: 25)

        var health = StorageHealth(
            status: .unknown,
            smartStatus: nil,
            busProtocol: nil,
            isSSD: nil,
            temperatureC: nil,
            powerOnHours: nil,
            wearLevelPercent: nil,
            reallocatedSectorCount: nil,
            pendingSectorCount: nil,
            criticalWarning: nil,
            percentageUsed: nil,
            message: nil,
            capturedAt: Date(),
            freeSpacePercent: nil,
            filesystemVerifyOK: nil,
            filesystemVerifyMessage: nil,
            fileVaultEnabled: nil,
            encryptionEnabled: nil,
            timeMachineLastBackup: nil,
            powerCycleCount: nil,
            startStopCount: nil,
            loadCycleCount: nil,
            udmaCRCErrorCount: nil,
            offlineUncorrectable: nil,
            gSenseErrorRate: nil,
            multiZoneErrorCount: nil
        )

        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let text = String(line)

            if text.contains("SMART overall-health self-assessment test result: PASSED") {
                health.status = .healthy
            } else if text.contains("SMART overall-health self-assessment test result: FAILED") {
                health.status = .failing
            }

            // NVMe critical warning
            if text.lowercased().hasPrefix("critical warning:") {
                let value = text.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                if value != "0x00" && !value.isEmpty && value != "0" {
                    health.criticalWarning = value
                    health.status = .failing
                }
            }

            // NVMe percentage used
            if text.lowercased().hasPrefix("percentage used:") {
                health.percentageUsed = intValue(from: text)
            }

            // NVMe / SCSI temperature
            if text.lowercased().hasPrefix("temperature:") {
                health.temperatureC = intValue(from: text)
            }

            // NVMe power on hours
            if text.lowercased().hasPrefix("power on hours:") {
                health.powerOnHours = intValue(from: text)
            }

            // ATA attributes
            if text.contains("Reallocated_Sector_Ct") {
                health.reallocatedSectorCount = ataRawValue(from: text)
            }
            if text.contains("Current_Pending_Sector") {
                health.pendingSectorCount = ataRawValue(from: text)
            }
            if text.contains("Power_On_Hours") {
                health.powerOnHours = ataRawValue(from: text)
            }
            if text.contains("Temperature_Celsius") {
                health.temperatureC = ataRawValue(from: text)
            }
            if text.contains("Wear_Leveling_Count") || text.contains("Media_Wearout_Indicator") {
                if let raw = ataRawValue(from: text), raw > 0, raw <= 100 {
                    health.wearLevelPercent = raw
                }
            }
            if text.contains("Power_Cycle_Count") {
                health.powerCycleCount = ataRawValue(from: text)
            }
            if text.contains("Start_Stop_Count") {
                health.startStopCount = ataRawValue(from: text)
            }
            if text.contains("Load_Cycle_Count") {
                health.loadCycleCount = ataRawValue(from: text)
            }
            if text.contains("UDMA_CRC_Error_Count") {
                health.udmaCRCErrorCount = ataRawValue(from: text)
            }
            if text.contains("Offline_Uncorrectable") {
                health.offlineUncorrectable = ataRawValue(from: text)
            }
            if text.contains("G-Sense_Error_Rate") {
                health.gSenseErrorRate = ataRawValue(from: text)
            }
            if text.contains("Multi_Zone_Error_Rate") {
                health.multiZoneErrorCount = ataRawValue(from: text)
            }
        }

        if health.status == .failing || health.criticalWarning != nil {
            health.message = "SMART reports failing health. Back up and replace this drive."
        } else if health.status == .healthy {
            health.message = "SMART self-test passed."
        }

        return health
    }

    private func merge(smart: StorageHealth?, into health: inout StorageHealth) {
        guard let smart else { return }
        if smart.status != .unknown { health.status = smart.status }
        if let v = smart.temperatureC { health.temperatureC = v }
        if let v = smart.powerOnHours { health.powerOnHours = v }
        if let v = smart.wearLevelPercent { health.wearLevelPercent = v }
        if let v = smart.reallocatedSectorCount { health.reallocatedSectorCount = v }
        if let v = smart.pendingSectorCount { health.pendingSectorCount = v }
        if let v = smart.criticalWarning { health.criticalWarning = v }
        if let v = smart.percentageUsed { health.percentageUsed = v }
        if let v = smart.powerCycleCount { health.powerCycleCount = v }
        if let v = smart.startStopCount { health.startStopCount = v }
        if let v = smart.loadCycleCount { health.loadCycleCount = v }
        if let v = smart.udmaCRCErrorCount { health.udmaCRCErrorCount = v }
        if let v = smart.offlineUncorrectable { health.offlineUncorrectable = v }
        if let v = smart.gSenseErrorRate { health.gSenseErrorRate = v }
        if let v = smart.multiZoneErrorCount { health.multiZoneErrorCount = v }
        if let m = smart.message { health.message = m }
    }

    // MARK: - Parsing helpers

    private func intValue(from line: String) -> Int? {
        let digits = line.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .joined()
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    private func ataRawValue(from line: String) -> Int? {
        // ATA attribute lines are space/column delimited; the raw value is the
        // last integer token (e.g. "200 200 140 ... 0").
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        for token in tokens.reversed() {
            let s = String(token)
            if let value = Int(s) { return value }
            // Some raw values are comma-separated: "1234 (1234 0 ...)"
            if let first = s.components(separatedBy: CharacterSet(charactersIn: "(, )").union(.whitespaces)).first,
               let value = Int(first) {
                return value
            }
        }
        return nil
    }

    // MARK: - Process helper

    private func run(
        _ executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval? = nil
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (
                    process.terminationStatus,
                    String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? ""
                ))
            }

            do {
                try process.run()
                if let timeout = timeoutSeconds {
                    Task {
                        try? await Task.sleep(for: .seconds(timeout))
                        if process.isRunning {
                            process.terminate()
                        }
                    }
                }
            } catch {
                continuation.resume(returning: (-1, "", String(describing: error)))
            }
        }
    }
}

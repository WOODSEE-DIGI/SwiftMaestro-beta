import Foundation
import GRDB

// MARK: - Volume-aware catalog support
//
// Tracks the physical or logical volumes whose files have been cataloged so
// MaestroDAM can browse, search, and show thumbnails for assets even when the
// drive that holds them is not currently connected (NeoFinder-style offline
// catalogs). Also feeds the Storage Health panel with per-drive status.

/// Errors specific to volume discovery.
enum DAMVolumeStoreError: Error, Sendable {
    case missingVolumeUUID(URL)
    case databaseWriteFailed(Error)
}

/// Returns true for APFS snapshot volumes such as "8TB2@snap-149896".
/// These are read-only time-machine-style snapshots and should never appear
/// in the MaestroDAM catalog, storage-health panel, or statistics.
func damIsSnapshotVolume(name: String) -> Bool {
    name.range(of: #"@snap-\d+$"#, options: .regularExpression) != nil
}

/// Returns true for macOS system/synthetic volumes that are not physical
/// drives (e.g. VM, Preboot, Update, xART, iSCPreboot, Hardware, Recovery,
/// Simulator runtimes, Cryptex volumes, Time Machine local snapshots). These
/// should not appear in Storage Health, the Folders sidebar, or be probed with
/// SMART/diskutil.
func damIsSystemOrSyntheticVolume(name: String, url: URL) -> Bool {
    let path = url.path
    if path.hasPrefix("/System/Volumes/") { return true }
    if path.contains("com.apple.TimeMachine.localsnapshots") { return true }
    if path.contains("/Backups.backupdb/") { return true }

    let lower = name.lowercased()
    let syntheticNames: Set<String> = [
        "vm", "preboot", "update", "xart", "iscpreboot", "hardware",
        "recovery", "container", "efi"
    ]
    if syntheticNames.contains(lower) { return true }
    if lower.contains("simulator") || lower.contains("cryptex") { return true }
    if lower.contains("time machine") || lower.contains("timemachine") || lower.contains("mobilebackups") { return true }
    return false
}

/// Observes volume mount/unmount events and keeps the `volume` table in sync
/// with the real world. Runs as an actor so DB writes and notification handlers
/// don't race.
actor DAMVolumeStore {

    static let shared = DAMVolumeStore()

    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?
    private var renameObserver: NSObjectProtocol?

    private init() {}

    /// Nonisolated wrappers so callers outside the actor can test volume names.
    nonisolated static func isSnapshotName(_ name: String) -> Bool {
        damIsSnapshotVolume(name: name)
    }
    nonisolated static func isSystemOrSyntheticName(_ name: String, url: URL) -> Bool {
        damIsSystemOrSyntheticVolume(name: name, url: url)
    }

    /// Call once at app launch. Registers for NSWorkspace mount/unmount
    /// notifications and performs an initial scan.
    func startMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.refreshOnlineState() }
        }
        unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.refreshOnlineState() }
        }
        renameObserver = center.addObserver(
            forName: NSWorkspace.didRenameVolumeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.refreshOnlineState() }
        }

        Task { await refreshOnlineState() }
    }

    /// Returns the catalog `DAMVolume` for a file URL, creating or updating the
    /// row as needed. Returns nil if the volume has no usable UUID.
    func volumeInfo(for url: URL) async -> DAMVolume? {
        do {
            return try await volumeInfoThrowing(for: url)
        } catch DAMVolumeStoreError.missingVolumeUUID {
            // Synthesized volumes (e.g. /System/Volumes/Data/home) may have no
            // usable UUID; skip silently.
            return nil
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Time Machine local snapshots and transient mount points can
            // disappear between enumeration and resource lookup.
            return nil
        } catch {
            NSLog("[DAMVolumeStore] volumeInfo failed for %@: %@", url.path, String(describing: error))
            return nil
        }
    }

    private func volumeInfoThrowing(for url: URL) async throws -> DAMVolume? {
        let keys: Set<URLResourceKey> = [
            .volumeUUIDStringKey,
            .volumeURLKey,
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey
        ]
        let values = try url.resourceValues(forKeys: keys)
        guard let uuid = values.volumeUUIDString, !uuid.isEmpty else {
            throw DAMVolumeStoreError.missingVolumeUUID(url)
        }

        let volumeURL = values.volume ?? url.deletingLastPathComponent()
        let name = values.volumeName ?? volumeURL.lastPathComponent
        // Ignore APFS snapshot volumes and system/synthetic volumes — they
        // are not physical drives and would otherwise clutter Storage Health.
        guard !damIsSnapshotVolume(name: name),
              !damIsSystemOrSyntheticVolume(name: name, url: volumeURL)
        else { return nil }
        let capacity = values.volumeTotalCapacity.map(Int64.init)
        let free = values.volumeAvailableCapacity.map(Int64.init)
        let isInternal = values.volumeIsInternal ?? false
        let mediaType = inferMediaType(isInternal: isInternal, bsdName: nil)

        let now = Date()

        return try await DAMDatabase.shared.dbQueue.write { db in
            if var existing = try DAMVolume.filter(DAMVolume.Columns.uuid == uuid).fetchOne(db) {
                existing.name = name
                existing.capacityBytes = capacity ?? existing.capacityBytes
                existing.freeBytes = free ?? existing.freeBytes
                existing.isOnline = true
                existing.lastSeenAt = now
                if existing.mediaType == nil { existing.mediaType = mediaType }
                try existing.update(db)
                return existing
            } else {
                let volume = DAMVolume(
                    id: nil,
                    uuid: uuid,
                    name: name,
                    bsdName: nil,
                    deviceModel: nil,
                    capacityBytes: capacity,
                    freeBytes: free,
                    mediaType: mediaType,
                    isOnline: true,
                    lastSeenAt: now,
                    healthJSON: nil,
                    healthWarnReplace: false
                )
                var inserted = volume
                try inserted.insert(db)
                return inserted
            }
        }
    }

    /// Re-scans all currently mounted volumes and updates each volume's online
    /// status. Assets on offline volumes are marked unavailable so the UI can
    /// badge or dim them. The heavy SMART/storage-health scan is only run when
    /// `runHealthScan` is `true` (i.e. the user explicitly clicks Refresh).
    @discardableResult
    func refreshOnlineState(runHealthScan: Bool = false) async -> [DAMVolume] {
        guard let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeUUIDStringKey, .volumeNameKey],
            options: []
        ) else {
            await markAllVolumesOffline()
            return []
        }

        var onlineUUIDs = Set<String>()
        var volumes: [DAMVolume] = []
        for url in mounted {
            guard !damIsSystemOrSyntheticVolume(name: url.lastPathComponent, url: url) else { continue }
            if let volume = await volumeInfo(for: url) {
                onlineUUIDs.insert(volume.uuid)
                volumes.append(volume)
            }
        }

        do {
            let now = Date()
            let uuids = onlineUUIDs
            try await DAMDatabase.shared.dbQueue.write { db in
                try db.execute(sql: "UPDATE volume SET isOnline = 0")
                for uuid in uuids {
                    try db.execute(
                        sql: "UPDATE volume SET isOnline = 1, lastSeenAt = ? WHERE uuid = ?",
                        arguments: [now, uuid]
                    )
                }
                try db.execute(
                    sql: """
                        UPDATE asset SET isAvailable = 0
                        WHERE volumeId IS NOT NULL
                          AND volumeId IN (SELECT id FROM volume WHERE isOnline = 0)
                        """
                )
                try db.execute(
                    sql: """
                        UPDATE asset SET isAvailable = 1, lastVerifiedAt = ?
                        WHERE volumeId IS NOT NULL
                          AND volumeId IN (SELECT id FROM volume WHERE isOnline = 1)
                        """,
                    arguments: [now]
                )
            }
        } catch {
            NSLog("[DAMVolumeStore] refreshOnlineState write failed: %@", String(describing: error))
        }

        // Gather SMART / diskutil health snapshots only when the user asked.
        if runHealthScan {
            Task { await StorageHealthService.shared.updateHealth(for: volumes) }
        }

        return volumes
    }

    /// Resolves the current filesystem URL for an asset, taking into account
    /// that the volume may have been re-mounted at a different path. Returns nil
    /// when the volume is offline or cannot be located.
    func resolveURL(for asset: DAMAsset) async -> URL? {
        guard let volumeId = asset.volumeId else {
            return URL(fileURLWithPath: asset.path)
        }

        guard let volume: DAMVolume = try? await DAMDatabase.shared.dbQueue.read({ db in
            try DAMVolume.fetchOne(db, key: volumeId)
        }), volume.isOnline else { return nil }

        guard let mountPoint = mountPointForVolume(uuid: volume.uuid) else { return nil }
        let rel = asset.relativePath ?? String(asset.path.drop(while: { $0 == "/" }))
        return mountPoint.appendingPathComponent(rel)
    }

    /// Computes a path relative to the volume root for an absolute file URL.
    func relativePath(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey]),
              let root = values.volume else { return nil }
        let rootPath = root.path
        let filePath = url.path
        guard filePath.hasPrefix(rootPath) else { return nil }
        let start = filePath.index(filePath.startIndex, offsetBy: rootPath.count)
        let remainder = String(filePath[start...])
        return remainder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Private helpers

    private func markAllVolumesOffline() async {
        do {
            try await DAMDatabase.shared.dbQueue.write { db in
                try db.execute(sql: "UPDATE volume SET isOnline = 0")
                try db.execute(sql: "UPDATE asset SET isAvailable = 0 WHERE volumeId IS NOT NULL")
            }
        } catch {
            NSLog("[DAMVolumeStore] markAllVolumesOffline failed: %@", String(describing: error))
        }
    }

    private func mountPointForVolume(uuid: String) -> URL? {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeUUIDStringKey],
            options: []
        ) else { return nil }
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]),
                  values.volumeUUIDString == uuid else { continue }
            return url
        }
        return nil
    }

    private func inferMediaType(isInternal: Bool, bsdName: String?) -> String? {
        if isInternal { return "internal" }
        if let bsd = bsdName {
            if bsd.contains("disk") && bsd.rangeOfCharacter(from: .decimalDigits.inverted) == nil {
                // Whole disk, not a slice; defer to diskutil for ssd/hdd.
                return nil
            }
        }
        return "external"
    }
}

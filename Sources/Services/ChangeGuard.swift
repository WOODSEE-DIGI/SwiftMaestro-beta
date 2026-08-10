import CryptoKit
import Foundation
import GRDB

// MARK: - ChangeGuard
//
// The data-safeguard layer for agent-driven mutations:
//
//   - write/append/copy-overwrite: pre-mutation snapshot of existing bytes
//   - move: recorded (rollback = move back), destination pre-snapshotted
//   - delete: quarantined (moved to a recoverable store), NEVER destroyed
//   - restore: snapshots the current state first — restores are reversible
//
// Registry: GRDB at `Application Support/SwiftMaestro/ChangeGuard/registry.sqlite`.
// Preserved bytes live under `ChangeGuard/snapshots/` and `ChangeGuard/quarantine/`.
//
// Snapshots of overwrite/append/restore are pruned to the newest 20 per path
// (deduped by content hash). Quarantined deletes and move records are NEVER
// auto-pruned — they're the user's data.

enum ChangeKind: String, Codable, Sendable {
    case overwrite, append, move, copyOverwrite, deleteQuarantine, restore
}

/// One preserved-change record (the rollback unit).
struct FileChange: Codable, FetchableRecord, PersistableRecord, TableRecord,
                   Identifiable, Hashable, Sendable {
    static let databaseTableName = "fileChange"

    var id: Int64?
    var kind: ChangeKind
    var originalPath: String
    var snapshotPath: String?
    var relatedPath: String?
    var sizeBytes: Int64?
    var sha256: String?
    var tool: String
    var agent: String
    var createdAt: Date

    enum Columns {
        static let id = Column("id")
        static let originalPath = Column("originalPath")
        static let createdAt = Column("createdAt")
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

enum ChangeGuardError: Error, LocalizedError, Sendable {
    case snapshotFailed(String)
    case changeNotFound
    case snapshotBytesMissing
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .snapshotFailed(let why): return "Snapshot failed: \(why)"
        case .changeNotFound: return "No change record with that ID."
        case .snapshotBytesMissing: return "The preserved bytes for this change are missing from disk."
        case .restoreFailed(let why): return "Restore failed: \(why)"
        }
    }
}

final class ChangeGuard: Sendable {

    static let shared = ChangeGuard()

    private let dbQueue: DatabaseQueue
    private let snapshotsRoot: URL
    private let quarantineRoot: URL

    /// Snapshot history kept per path for prunable kinds. Quarantine/move
    /// records are exempt (never auto-pruned).
    private static let maxSnapshotsPerPath = 20
    private static let prunableKinds: Set<ChangeKind> = [.overwrite, .append, .copyOverwrite, .restore]

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = appSupport.appendingPathComponent("SwiftMaestro/ChangeGuard", isDirectory: true)
        snapshotsRoot = base.appendingPathComponent("snapshots", isDirectory: true)
        quarantineRoot = base.appendingPathComponent("quarantine", isDirectory: true)
        try? FileManager.default.createDirectory(at: snapshotsRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)

        // The safeguard registry must exist — if it can't be created, fall
        // back to in-memory so callers still get records this session (and
        // snapshot writes will fail closed, blocking the mutation).
        if let queue = try? DatabaseQueue(path: base.appendingPathComponent("registry.sqlite").path) {
            dbQueue = queue
        } else {
            // swiftlint:disable:next force_try
            dbQueue = try! DatabaseQueue()
        }
        try? Self.migrator.migrate(dbQueue)
    }

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-fileChange") { db in
            try db.create(table: "fileChange") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("originalPath", .text).notNull()
                t.column("snapshotPath", .text)
                t.column("relatedPath", .text)
                t.column("sizeBytes", .integer)
                t.column("sha256", .text)
                t.column("tool", .text).notNull()
                t.column("agent", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_fileChange_path", on: "fileChange", columns: ["originalPath"])
        }
        return migrator
    }()

    // MARK: - Snapshot before mutation

    /// Preserves the current bytes of `path` before a write/append/overwrite
    /// style mutation. No-op (but still recorded) when the file doesn't
    /// exist yet. Dedupes on content hash: if the newest snapshot already
    /// matches the current bytes, nothing is copied.
    ///
    /// Throws on failure — callers must treat a snapshot failure as a reason
    /// to BLOCK the mutation (fail closed: an unsnapshotable change is an
    /// unrollbackable change).
    func snapshotForMutation(
        path: String,
        kind: ChangeKind,
        relatedPath: String? = nil,
        tool: String,
        agent: String = "agent"
    ) throws {
        // Moves never copy bytes — the file persists at its destination, so
        // rollback is just moving it back. Only the record matters.
        if kind == .move {
            try record(FileChange(
                id: nil, kind: .move, originalPath: path,
                snapshotPath: nil, relatedPath: relatedPath,
                sizeBytes: nil, sha256: nil, tool: tool, agent: agent,
                createdAt: Date()))
            return
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return // Nothing to preserve for a brand-new file.
        }

        let url = URL(fileURLWithPath: path)
        let hash = try Self.sha256(of: url)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        // Dedupe: newest snapshot for this path with the same hash → no copy.
        if let latestHash = try latestSnapshotHash(forPath: path), latestHash == hash {
            return
        }

        let destination = snapshotURL(for: path, hash: hash)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw ChangeGuardError.snapshotFailed(error.localizedDescription)
        }

        try record(FileChange(
            id: nil, kind: kind, originalPath: path,
            snapshotPath: destination.path, relatedPath: relatedPath,
            sizeBytes: Int64(size), sha256: hash, tool: tool, agent: agent,
            createdAt: Date()))
        try pruneIfNeeded(forPath: path)
    }

    // MARK: - Quarantine delete (never destroys)

    /// Moves the file into the recoverable quarantine store and records it.
    /// Permanent deletion is disabled by data safeguards.
    /// - Returns: the quarantine path (for the tool response).
    func quarantineDelete(path: String, tool: String, agent: String = "agent") throws -> String {
        let source = URL(fileURLWithPath: path)
        let day = Self.dayStamp(Date())
        let destination = quarantineRoot
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw ChangeGuardError.snapshotFailed(error.localizedDescription)
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        try record(FileChange(
            id: nil, kind: .deleteQuarantine, originalPath: path,
            snapshotPath: destination.path, relatedPath: nil,
            sizeBytes: Int64(size), sha256: nil, tool: tool, agent: agent,
            createdAt: Date()))
        return destination.path
    }

    // MARK: - Listing

    /// Change history for one path, newest first (capped for tool output).
    func listChanges(forPath path: String, limit: Int = 50) -> [FileChange] {
        (try? dbQueue.read { db in
            try FileChange
                .filter(FileChange.Columns.originalPath == path)
                .order(FileChange.Columns.createdAt.desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    // MARK: - Restore (rollback)

    /// Rolls back a recorded change. The restore itself snapshots the current
    /// state first, so a rollback is also reversible.
    ///
    /// Handles all kinds:
    /// - overwrite/append/copyOverwrite: copy preserved bytes back over the file
    /// - deleteQuarantine: move the quarantined file back to its original path
    /// - move: move the file back from destination to source
    func restore(changeId: Int64) throws -> String {
        let change = try dbQueue.read { db in
            try FileChange.fetchOne(db, id: changeId)
        }
        guard let change else { throw ChangeGuardError.changeNotFound }

        switch change.kind {
        case .move:
            guard let destination = change.relatedPath else { throw ChangeGuardError.restoreFailed("move record has no destination") }
            guard FileManager.default.fileExists(atPath: destination) else { throw ChangeGuardError.snapshotBytesMissing }
            let back = change.originalPath
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: back).deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: URL(fileURLWithPath: destination), to: URL(fileURLWithPath: back))
            try record(FileChange(
                id: nil, kind: .restore, originalPath: back,
                snapshotPath: nil, relatedPath: destination,
                sizeBytes: nil, sha256: nil, tool: "restore_file_snapshot", agent: "agent",
                createdAt: Date()))
            return "Moved '\(destination)' back to '\(back)'."

        case .deleteQuarantine:
            guard let quarantinePath = change.snapshotPath else { throw ChangeGuardError.snapshotBytesMissing }
            guard FileManager.default.fileExists(atPath: quarantinePath) else { throw ChangeGuardError.snapshotBytesMissing }
            let back = change.originalPath
            if FileManager.default.fileExists(atPath: back) {
                // Something new lives at the original path — preserve it first.
                try snapshotForMutation(path: back, kind: .restore, tool: "restore_file_snapshot")
            }
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: back).deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: URL(fileURLWithPath: quarantinePath), to: URL(fileURLWithPath: back))
            try record(FileChange(
                id: nil, kind: .restore, originalPath: back,
                snapshotPath: nil, relatedPath: quarantinePath,
                sizeBytes: nil, sha256: nil, tool: "restore_file_snapshot", agent: "agent",
                createdAt: Date()))
            return "Restored quarantined file to '\(back)'."

        case .overwrite, .append, .copyOverwrite, .restore:
            guard let snapshotPath = change.snapshotPath else { throw ChangeGuardError.snapshotBytesMissing }
            guard FileManager.default.fileExists(atPath: snapshotPath) else { throw ChangeGuardError.snapshotBytesMissing }
            let target = change.originalPath
            // Preserve the CURRENT bytes before rolling back (reversible).
            if FileManager.default.fileExists(atPath: target) {
                try snapshotForMutation(path: target, kind: .restore, tool: "restore_file_snapshot")
            }
            do {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: target).deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target) {
                    try FileManager.default.removeItem(atPath: target)
                }
                try FileManager.default.copyItem(atPath: snapshotPath, toPath: target)
            } catch {
                throw ChangeGuardError.restoreFailed(error.localizedDescription)
            }
            return "Restored '\(target)' from snapshot #\(changeId)."
        }
    }

    // MARK: - Internals

    private func record(_ change: FileChange) throws {
        try dbQueue.write { db in
            try change.insert(db)
        }
    }

    private func latestSnapshotHash(forPath path: String) throws -> String? {
        try dbQueue.read { db in
            try FileChange
                .filter(FileChange.Columns.originalPath == path)
                .order(FileChange.Columns.createdAt.desc)
                .fetchOne(db)?.sha256
        }
    }

    private func pruneIfNeeded(forPath path: String) throws {
        let prunable = Self.prunableKinds.map(\.rawValue)
        try dbQueue.write { db in
            let rows = try FileChange
                .filter(FileChange.Columns.originalPath == path)
                .order(FileChange.Columns.createdAt.desc)
                .fetchAll(db)
            let prunableRows = rows.filter { prunable.contains($0.kind.rawValue) }
            guard prunableRows.count > Self.maxSnapshotsPerPath else { return }
            for stale in prunableRows.dropFirst(Self.maxSnapshotsPerPath) {
                if let snapshotPath = stale.snapshotPath {
                    try? FileManager.default.removeItem(atPath: snapshotPath)
                }
                if let id = stale.id {
                    _ = try FileChange.deleteOne(db, id: id)
                }
            }
        }
    }

    /// snapshots/<hash-of-path>/<timestamp>-<content-hash-8>.<ext>
    private func snapshotURL(for path: String, hash: String) -> URL {
        let pathHash = Self.sha256Hex(Data(path.utf8))
        let stamp = Self.timeStamp(Date())
        let ext = URL(fileURLWithPath: path).pathExtension
        let name = "\(stamp)-\(hash.prefix(8))\(ext.isEmpty ? "" : ".\(ext)")"
        return snapshotsRoot
            .appendingPathComponent(String(pathHash.prefix(16)), isDirectory: true)
            .appendingPathComponent(name)
    }

    /// Date stamps built manually — DateFormatter isn't Sendable under
    /// strict concurrency (same rule as DAMImportService).
    private static func dayStamp(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func timeStamp(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Streaming SHA-256 (safe for multi-GB files).
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return sha256Hex(Data(hasher.finalize()))
    }

    private static func sha256Hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

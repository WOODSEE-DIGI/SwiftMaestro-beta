import Foundation
import CryptoKit
import GRDB

// MARK: - Models

/// One file that is part of a duplicate group.
struct DAMDuplicateItem: Sendable, Identifiable, Hashable, DAMKeepComparable {
    let id = UUID()
    var path: String
    var size: Int64
    var width: Int?
    var height: Int?
    var captureDate: Date?
    var fileModDate: Date?

    var resolutionPixels: Int { (width ?? 0) * (height ?? 0) }
    var sortDate: Date? { captureDate ?? fileModDate }
}

/// A set of files whose contents hash to the same value.
struct DAMDuplicateGroup: Sendable, Identifiable, Hashable {
    let id = UUID()
    var hash: String
    var items: [DAMDuplicateItem]

    var count: Int { items.count }
    var fileSize: Int64 { items.first?.size ?? 0 }
    var totalSize: Int64 { fileSize * Int64(count) }
    var wastedSpace: Int64 { fileSize * Int64(count - 1) }
}

// MARK: - Delegate

/// Receives progress updates from `DAMDuplicateFinder`. Isolated to the main
/// actor so it can safely update SwiftUI state.
@MainActor
protocol DAMDuplicateFinderDelegate: AnyObject, Sendable {
    func duplicateFinder(_ finder: DAMDuplicateFinder, didUpdate progress: DAMDuplicateFinder.Progress)
}

// MARK: - Finder

/// Finds byte-for-byte duplicate files using SHA-256.
///
/// The workflow is designed for creative users who may have many versions or
/// copies scattered across volumes:
///   1. Pull file paths and sizes from the catalog.
///   2. Group by size — only same-size files can be duplicates.
///   3. SHA-256 hash each candidate (streaming, 1 MB chunks).
///   4. Return groups where the hash matches and there are 2+ files.
actor DAMDuplicateFinder {
    static let shared = DAMDuplicateFinder()

    private init() {}

    /// Progress update emitted while hashing.
    struct Progress: Sendable {
        let hashed: Int
        let total: Int
        let currentPath: String
    }

    private var currentTask: Task<[DAMDuplicateGroup], any Error>?

    /// Cancels an in-flight scan, if any.
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// Scans the catalog for duplicate files under `folderPath` (or the entire
    /// catalog when `folderPath` is nil). Reports progress to `delegate` and
    /// returns duplicate groups sorted by most wasted space first.
    func findDuplicates(
        in folderPath: String?,
        delegate: any DAMDuplicateFinderDelegate
    ) async throws -> [DAMDuplicateGroup] {
        // Capture the current task so `cancel()` can stop it.
        let task = Task { () -> [DAMDuplicateGroup] in
            try await DAMResourceLimiter.shared.withHeavyTask(
                name: "SHA-256 duplicate scan",
                timeout: .infinity
            ) {
                let candidates = try await self.candidatePaths(in: folderPath)

                // Group by size; only groups with 2+ files are worth hashing.
                var bySize: [Int64: [DAMDuplicateItem]] = [:]
                for item in candidates {
                    bySize[item.size, default: []].append(item)
                }
                let groupsToHash = bySize.values.filter { $0.count > 1 }
                let total = groupsToHash.reduce(0) { $0 + $1.count }

                var byHash: [String: DAMDuplicateGroup] = [:]
                var hashed = 0

                for group in groupsToHash {
                    for item in group {
                        if Task.isCancelled { throw CancellationError() }
                        guard FileManager.default.fileExists(atPath: item.path) else { continue }

                        let digest = try await self.sha256(of: URL(fileURLWithPath: item.path))

                        if var existing = byHash[digest] {
                            existing.items.append(item)
                            byHash[digest] = existing
                        } else {
                            byHash[digest] = DAMDuplicateGroup(hash: digest, items: [item])
                        }

                        hashed += 1
                        await delegate.duplicateFinder(
                            self,
                            didUpdate: Progress(hashed: hashed, total: total, currentPath: item.path)
                        )
                    }
                }

                return byHash
                    .values
                    .filter { $0.items.count > 1 }
                    .sorted { $0.wastedSpace > $1.wastedSpace }
            }
        }

        await withTaskCancellationHandler {
            self.currentTask = task
        } onCancel: {
            task.cancel()
        }

        let groups = try await task.value
        currentTask = nil
        return groups
    }

    // MARK: - Catalog candidates

    /// Returns every cataloged file path and metadata under `folderPath`, or
    /// the whole catalog when `folderPath` is nil. Zero-byte files are excluded.
    private func candidatePaths(in folderPath: String?) async throws -> [DAMDuplicateItem] {
        try await DAMDatabase.shared.dbQueue.read { db in
            let sql: String
            let arguments: StatementArguments
            if let folderPath {
                sql = """
                    SELECT path, fileSize, width, height, captureDate, fileModDate
                    FROM asset WHERE fileSize > 0 AND path LIKE ?
                    """
                arguments = ["\(folderPath)%"]
            } else {
                sql = """
                    SELECT path, fileSize, width, height, captureDate, fileModDate
                    FROM asset WHERE fileSize > 0
                    """
                arguments = []
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.map { row in
                DAMDuplicateItem(
                    path: row["path"],
                    size: row["fileSize"],
                    width: row["width"],
                    height: row["height"],
                    captureDate: row["captureDate"],
                    fileModDate: row["fileModDate"]
                )
            }
        }
    }

    // MARK: - Hashing

    /// Streaming SHA-256 of a file, reading 1 MB chunks so large videos/RAWs
    /// don't need to be fully loaded into memory.
    private func sha256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = CryptoKit.SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576) {
            if Task.isCancelled { throw CancellationError() }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

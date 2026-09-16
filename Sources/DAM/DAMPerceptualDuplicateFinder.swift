import Foundation
import GRDB

// MARK: - Perceptual duplicate detection

extension DAMDuplicateFinder {

    /// Generates pHashes for cataloged images that don't already have one.
    /// Returns the number of hashes written. Progress is reported through the
    /// delegate so the UI can show a retro scanning indicator.
    func generatePerceptualHashes(
        in folderPath: String?,
        delegate: any DAMDuplicateFinderDelegate
    ) async throws -> Int {
        try await DAMResourceLimiter.shared.withHeavyTask(
            name: "Perceptual hash generation",
            timeout: .infinity
        ) {
            let idsAndPaths = try await self.imageAssetsMissingHashes(in: folderPath)
            guard !idsAndPaths.isEmpty else { return 0 }

            if !idsAndPaths.isEmpty {
                await delegate.duplicateFinder(
                    self,
                    didUpdate: Progress(hashed: 0, total: idsAndPaths.count, currentPath: "")
                )
            }

            let concurrency = max(1, min(4, ProcessInfo.processInfo.processorCount))
            return try await withThrowingTaskGroup(of: (Int64, String, String?).self) { group in
                var iterator = idsAndPaths.makeIterator()
                var written = 0
                var processed = 0

                func addNext() {
                    guard let (id, path) = iterator.next() else { return }
                    group.addTask {
                        let hash = await PerceptualHashService.shared.hash(for: path)
                        return (id, path, hash)
                    }
                }

                for _ in 0..<concurrency { addNext() }

                while let result = try await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    addNext()
                    processed += 1
                    if let hash = result.2 {
                        try await DAMDatabase.shared.dbQueue.write { db in
                            try db.execute(
                                sql: "UPDATE asset SET perceptualHash = ? WHERE id = ?",
                                arguments: [hash, result.0]
                            )
                        }
                        written += 1
                    }
                    await delegate.duplicateFinder(
                        self,
                        didUpdate: Progress(hashed: processed, total: idsAndPaths.count, currentPath: result.1)
                    )
                }
                return written
            }
        }
    }

    /// Finds groups of images with identical 64-bit pHashes. This catches
    /// resized/cropped/recompressed variants of the same photo because the
    /// DCT-based hash is robust to those transformations.
    func findPerceptualDuplicates(in folderPath: String?) async throws -> [DAMDuplicateGroup] {
        let rows = try await assetsWithPerceptualHash(in: folderPath)

        var byHash: [String: DAMDuplicateGroup] = [:]
        for row in rows {
            if var existing = byHash[row.hash] {
                existing.items.append(row.item)
                byHash[row.hash] = existing
            } else {
                byHash[row.hash] = DAMDuplicateGroup(hash: row.hash, items: [row.item])
            }
        }

        return byHash
            .values
            .filter { $0.items.count > 1 }
            .sorted { $0.wastedSpace > $1.wastedSpace }
    }

    /// Returns the number of available image/raw assets in scope that still
    /// need a perceptual hash. Used by the UI to decide whether to show the
    /// "Generate pHashes" banner.
    func countMissingPerceptualHashes(in folderPath: String?) async throws -> Int {
        try await DAMDatabase.shared.dbQueue.read { db in
            let sql: String
            let arguments: StatementArguments
            if let folderPath {
                sql = """
                    SELECT COUNT(*) FROM asset
                    WHERE perceptualHash IS NULL
                      AND (kind = 'image' OR kind = 'raw')
                      AND isAvailable = 1
                      AND path LIKE ?
                    """
                arguments = ["\(folderPath)%"]
            } else {
                sql = """
                    SELECT COUNT(*) FROM asset
                    WHERE perceptualHash IS NULL
                      AND (kind = 'image' OR kind = 'raw')
                      AND isAvailable = 1
                    """
                arguments = []
            }
            return try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        }
    }

    // MARK: - Database helpers

    private func imageAssetsMissingHashes(in folderPath: String?) async throws -> [(Int64, String)] {
        try await DAMDatabase.shared.dbQueue.read { db in
            let sql: String
            let arguments: StatementArguments
            if let folderPath {
                sql = """
                    SELECT id, path FROM asset
                    WHERE perceptualHash IS NULL
                      AND (kind = 'image' OR kind = 'raw')
                      AND isAvailable = 1
                      AND path LIKE ?
                    """
                arguments = ["\(folderPath)%"]
            } else {
                sql = """
                    SELECT id, path FROM asset
                    WHERE perceptualHash IS NULL
                      AND (kind = 'image' OR kind = 'raw')
                      AND isAvailable = 1
                    """
                arguments = []
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.map { (id: $0["id"], path: $0["path"]) }
        }
    }

    private func assetsWithPerceptualHash(in folderPath: String?) async throws -> [(item: DAMDuplicateItem, hash: String)] {
        try await DAMDatabase.shared.dbQueue.read { db in
            let sql: String
            let arguments: StatementArguments
            if let folderPath {
                sql = """
                    SELECT path, fileSize, width, height, captureDate, fileModDate, perceptualHash FROM asset
                    WHERE perceptualHash IS NOT NULL
                      AND (kind = 'image' OR kind = 'raw')
                      AND isAvailable = 1
                      AND path LIKE ?
                    """
                arguments = ["\(folderPath)%"]
            } else {
                sql = """
                    SELECT path, fileSize, width, height, captureDate, fileModDate, perceptualHash FROM asset
                    WHERE perceptualHash IS NOT NULL
                      AND (kind = 'image' OR kind = 'raw')
                      AND isAvailable = 1
                    """
                arguments = []
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.map { row in
                let item = DAMDuplicateItem(
                    path: row["path"],
                    size: row["fileSize"],
                    width: row["width"],
                    height: row["height"],
                    captureDate: row["captureDate"],
                    fileModDate: row["fileModDate"]
                )
                return (item: item, hash: row["perceptualHash"])
            }
        }
    }
}

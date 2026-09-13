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

            var written = 0
            for (index, (id, path)) in idsAndPaths.enumerated() {
                if Task.isCancelled { throw CancellationError() }

                let hash = await PerceptualHashService.shared.hash(for: path)
                if let hash {
                    try await DAMDatabase.shared.dbQueue.write { db in
                        try db.execute(
                            sql: "UPDATE asset SET perceptualHash = ? WHERE id = ?",
                            arguments: [hash, id]
                        )
                    }
                    written += 1
                }

                await delegate.duplicateFinder(
                    self,
                    didUpdate: Progress(hashed: index + 1, total: idsAndPaths.count, currentPath: path)
                )
            }
            return written
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
                      AND path LIKE ?
                    """
                arguments = ["\(folderPath)%"]
            } else {
                sql = """
                    SELECT id, path FROM asset
                    WHERE perceptualHash IS NULL
                      AND (kind = 'image' OR kind = 'raw')
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
                      AND path LIKE ?
                    """
                arguments = ["\(folderPath)%"]
            } else {
                sql = """
                    SELECT path, fileSize, width, height, captureDate, fileModDate, perceptualHash FROM asset
                    WHERE perceptualHash IS NOT NULL
                      AND (kind = 'image' OR kind = 'raw')
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

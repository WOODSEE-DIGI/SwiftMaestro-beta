import Foundation
import GRDB

// MARK: - Version set finder

/// Finds files that are probably versions of the same creative work based on
/// filename patterns (`_v01`, `_final`, `_02`, etc.). Uses learned patterns
/// from `DAMVersionPatternLearner` and groups within the same parent folder.
actor DAMVersionSetFinder {
    static let shared = DAMVersionSetFinder()

    private init() {}

    struct VersionSet: Sendable, Identifiable, Hashable {
        let id = UUID()
        var baseKey: String
        var items: [DAMDuplicateItem]

        var count: Int { items.count }
        var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    }

    /// Returns version sets under `folderPath` (or the whole catalog when nil).
    /// Only groups with 2+ files are returned, sorted by total size descending.
    func findVersionSets(in folderPath: String?) async throws -> [VersionSet] {
        try await DAMResourceLimiter.shared.withHeavyTask(
            name: "Version set scan",
            timeout: .infinity
        ) {
            let rows = try await self.filenameRows(in: folderPath)
            let patterns = await MainActor.run { DAMVersionPatternStore.shared.patterns }

            var groups: [String: VersionSet] = [:]
            for row in rows {
                if Task.isCancelled { throw CancellationError() }
                let baseKey = self.baseKey(for: row.path, filename: row.filename, patterns: patterns)
                if var existing = groups[baseKey] {
                    existing.items.append(row.item)
                    groups[baseKey] = existing
                } else {
                    groups[baseKey] = VersionSet(baseKey: baseKey, items: [row.item])
                }
            }

            return groups
                .values
                .filter { $0.items.count > 1 }
                .sorted { $0.totalSize > $1.totalSize }
        }
    }

    // MARK: - Database helpers

    private func filenameRows(in folderPath: String?) async throws -> [(path: String, filename: String, item: DAMDuplicateItem)] {
        try await DAMDatabase.shared.dbQueue.read { db in
            let sql: String
            let arguments: StatementArguments
            if let folderPath {
                sql = """
                    SELECT path, filename, fileSize, width, height, captureDate, fileModDate
                    FROM asset WHERE path LIKE ?
                    """
                arguments = ["\(folderPath)%"]
            } else {
                sql = """
                    SELECT path, filename, fileSize, width, height, captureDate, fileModDate
                    FROM asset
                    """
                arguments = []
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.map { row in
                let path: String = row["path"]
                let item = DAMDuplicateItem(
                    path: path,
                    size: row["fileSize"],
                    width: row["width"],
                    height: row["height"],
                    captureDate: row["captureDate"],
                    fileModDate: row["fileModDate"]
                )
                return (path: path, filename: row["filename"], item: item)
            }
        }
    }

    // MARK: - Key building

    private nonisolated func baseKey(for path: String, filename: String, patterns: [DAMVersionPattern]) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let stripped = DAMVersionPatternLearner.baseName(for: filename, using: patterns)
        return "\(folder)/\(stripped)"
    }
}

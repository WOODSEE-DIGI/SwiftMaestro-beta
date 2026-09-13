import Foundation
import GRDB

// MARK: - Statistics models

/// Aggregated catalog statistics for the Statistics dashboard.
struct DAMCatalogStats: Sendable, Identifiable {
    var id = UUID()

    var scope: Scope
    enum Scope: Sendable {
        case entireCatalog
        case folder(String)
    }

    // Top-line KPIs
    var totalAssets: Int = 0
    var totalSize: Int64 = 0
    var totalDuration: Double = 0
    var offlineAssets: Int = 0

    // Breakdowns
    var byKind: [KindCount] = []
    var byFlag: [FlagCount] = []
    var byRating: [RatingCount] = []
    var byColorLabel: [ColorLabelCount] = []
    var byColorTag: [ColorTagCount] = []
    var byVolume: [VolumeStat] = []
    var topFolders: [FolderStat] = []

    struct KindCount: Sendable, Identifiable {
        var id: String { kind }
        var kind: String
        var count: Int
        var size: Int64
    }

    struct FlagCount: Sendable, Identifiable {
        var id: String { flag.rawValue }
        var flag: DAMFlag
        var count: Int
    }

    struct RatingCount: Sendable, Identifiable {
        var id: Int { rating }
        var rating: Int
        var count: Int
    }

    struct ColorLabelCount: Sendable, Identifiable {
        var id: String { label.rawValue }
        var label: DAMColorLabel
        var count: Int
    }

    struct ColorTagCount: Sendable, Identifiable {
        var id: Int { colorIndex }
        var colorIndex: Int
        var name: String
        var count: Int
    }

    struct VolumeStat: Sendable, Identifiable {
        var id: Int64 { volumeId }
        var volumeId: Int64
        var name: String
        var size: Int64
        var isOnline: Bool
        var warnReplace: Bool
    }

    struct FolderStat: Sendable, Identifiable {
        var id: String { path }
        var path: String
        var count: Int
        var size: Int64
    }
}

// MARK: - Service

actor DAMStatisticsService {
    static let shared = DAMStatisticsService()

    private init() {}

    /// Returns aggregated statistics for the whole catalog or for a single
    /// folder (including subfolders).
    func stats(forFolderPath folder: String?) async -> DAMCatalogStats {
        let scope: DAMCatalogStats.Scope = folder.map { .folder($0) } ?? .entireCatalog
        let folderFilter = folderClause(folder)
        let topFolderFilter = topFolderClause(folder)

        do {
            return try await DAMDatabase.shared.dbQueue.read { db in
                var stats = DAMCatalogStats(scope: scope)

                // KPIs
                let totalRow = try Row.fetchOne(db, sql: """
                    SELECT COUNT(*) AS c, COALESCE(SUM(fileSize),0) AS s, COALESCE(SUM(duration),0) AS d,
                           SUM(CASE WHEN isAvailable = 0 THEN 1 ELSE 0 END) AS offline
                    FROM asset
                    \(folderFilter.sql)
                    """, arguments: folderFilter.args)
                stats.totalAssets = intCount(totalRow?["c"])
                stats.totalSize = totalRow?["s"] as? Int64 ?? 0
                stats.totalDuration = totalRow?["d"] as? Double ?? 0
                stats.offlineAssets = intCount(totalRow?["offline"])

                // By kind
                let kindRows = try Row.fetchAll(db, sql: """
                    SELECT COALESCE(kind,'unknown') AS k, COUNT(*) AS c, COALESCE(SUM(fileSize),0) AS s
                    FROM asset
                    \(folderFilter.sql)
                    GROUP BY k
                    ORDER BY s DESC
                    """, arguments: folderFilter.args)
                stats.byKind = kindRows.map {
                    DAMCatalogStats.KindCount(
                        kind: $0["k"] as? String ?? "unknown",
                        count: intCount($0["c"]),
                        size: $0["s"] as? Int64 ?? 0
                    )
                }

                // By flag
                let flagRows = try Row.fetchAll(db, sql: """
                    SELECT flag, COUNT(*) AS c
                    FROM asset
                    \(folderFilter.sql)
                    GROUP BY flag
                    """, arguments: folderFilter.args)
                var flagCounts: [DAMFlag: Int] = [:]
                for row in flagRows {
                    if let raw = row["flag"] as? String,
                       let flag = DAMFlag(rawValue: raw) {
                        flagCounts[flag] = intCount(row["c"])
                    }
                }
                stats.byFlag = DAMFlag.allCases.map { f in
                    DAMCatalogStats.FlagCount(flag: f, count: flagCounts[f] ?? 0)
                }

                // By rating
                let ratingRows = try Row.fetchAll(db, sql: """
                    SELECT rating, COUNT(*) AS c
                    FROM asset
                    \(folderFilter.sql)
                    GROUP BY rating
                    """, arguments: folderFilter.args)
                var ratingCounts: [Int: Int] = [:]
                for row in ratingRows {
                    if let r64 = row["rating"] as? Int64 {
                        ratingCounts[Int(r64)] = intCount(row["c"])
                    } else if let r = row["rating"] as? Int {
                        ratingCounts[r] = intCount(row["c"])
                    }
                }
                stats.byRating = (0...5).map { r in
                    DAMCatalogStats.RatingCount(rating: r, count: ratingCounts[r] ?? 0)
                }

                // By color label
                let colorRows = try Row.fetchAll(db, sql: """
                    SELECT colorLabel, COUNT(*) AS c
                    FROM asset
                    \(folderFilter.sql)
                    GROUP BY colorLabel
                    """, arguments: folderFilter.args)
                var colorCounts: [DAMColorLabel: Int] = [:]
                for row in colorRows {
                    if let raw = row["colorLabel"] as? String,
                       let label = DAMColorLabel(rawValue: raw) {
                        colorCounts[label] = intCount(row["c"])
                    }
                }
                stats.byColorLabel = DAMColorLabel.allCases.map { l in
                    DAMCatalogStats.ColorLabelCount(label: l, count: colorCounts[l] ?? 0)
                }

                // By Finder/xattr color tag (tagColors JSON: color index 2-7)
                let tagWhere = folderFilter.sql.isEmpty
                    ? "WHERE tagColors IS NOT NULL AND tagColors != '' AND tagColors != '{}'"
                    : folderFilter.sql + " AND tagColors IS NOT NULL AND tagColors != '' AND tagColors != '{}'"
                let tagRows = try Row.fetchAll(db, sql: """
                    SELECT tagColors FROM asset
                    \(tagWhere)
                    """, arguments: folderFilter.args)
                var tagColorCounts: [Int: Int] = [:]
                for row in tagRows {
                    guard let json = row["tagColors"] as? String,
                          let data = json.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
                    else { continue }
                    var seen = Set<Int>()
                    for (_, color) in dict {
                        if (1...7).contains(color) { seen.insert(color) }
                    }
                    for color in seen { tagColorCounts[color, default: 0] += 1 }
                }
                let tagColorNames = ["Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]
                stats.byColorTag = (1...7).map { index in
                    DAMCatalogStats.ColorTagCount(
                        colorIndex: index,
                        name: tagColorNames[index - 1],
                        count: tagColorCounts[index] ?? 0
                    )
                }

                // Volume stats (global, folder scope still filters assets)
                let volumeRows = try Row.fetchAll(db, sql: """
                    SELECT v.id AS vid, v.name, v.isOnline, v.healthWarnReplace,
                           COALESCE(SUM(a.fileSize),0) AS s
                    FROM volume v
                    LEFT JOIN asset a ON a.volumeId = v.id
                    WHERE v.name NOT LIKE '%@snap-%'
                    GROUP BY v.id
                    ORDER BY s DESC
                    """)
                stats.byVolume = volumeRows.compactMap { row in
                    guard let id = row["vid"] as? Int64,
                          let name = row["name"] as? String else { return nil }
                    let syntheticURL = URL(fileURLWithPath: "/Volumes/\(name)")
                    guard !DAMVolumeStore.isSystemOrSyntheticName(name, url: syntheticURL) else { return nil }
                    return DAMCatalogStats.VolumeStat(
                        volumeId: id,
                        name: name,
                        size: row["s"] as? Int64 ?? 0,
                        isOnline: (row["isOnline"] as? Int).map { $0 != 0 } ?? false,
                        warnReplace: (row["healthWarnReplace"] as? Int).map { $0 != 0 } ?? false
                    )
                }

                // Top folders (only meaningful when scoped to a folder or entire catalog)
                let topFolderRows = try Row.fetchAll(db, sql: """
                    SELECT folder, COUNT(*) AS c, COALESCE(SUM(fileSize),0) AS s
                    FROM asset
                    \(topFolderFilter.sql)
                    GROUP BY folder
                    ORDER BY s DESC
                    LIMIT 20
                    """, arguments: topFolderFilter.args)
                stats.topFolders = topFolderRows.compactMap { row in
                    guard let path = row["folder"] as? String else { return nil }
                    return DAMCatalogStats.FolderStat(
                        path: path,
                        count: intCount(row["c"]),
                        size: row["s"] as? Int64 ?? 0
                    )
                }

                return stats
            }
        } catch is CancellationError {
            // View-layer task cancellation is expected when the user switches
            // scope quickly; don't pollute logs or flash empty data.
        } catch {
            NSLog("[DAMStatisticsService] stats failed: %@", String(describing: error))
        }

        return DAMCatalogStats(scope: scope)
    }

    // MARK: - Private

    private struct FolderClause {
        var sql: String
        var args: StatementArguments
    }

    private func folderClause(_ folder: String?) -> FolderClause {
        guard let folder, !folder.isEmpty else {
            return FolderClause(sql: "", args: StatementArguments())
        }
        // Match the folder exactly or any descendant path.
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return FolderClause(
            sql: "WHERE (folder = ? OR folder LIKE ?)",
            args: [folder, prefix + "%"]
        )
    }

    private func topFolderClause(_ folder: String?) -> (sql: String, args: StatementArguments) {
        guard let folder, !folder.isEmpty else {
            return ("WHERE folder IS NOT NULL", StatementArguments())
        }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return (
            "WHERE folder IS NOT NULL AND (folder = ? OR folder LIKE ?)",
            [folder, prefix + "%"]
        )
    }

    /// GRDB returns aggregate counts as Int64 on some paths; normalize to Int.
    private nonisolated func intCount(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let i64 = value as? Int64 { return Int(i64) }
        if let d = value as? Double { return Int(d) }
        return 0
    }
}

import Foundation
import GRDB
import OSLog

private let relinkLogger = Logger(subsystem: "com.woodseedigi.swiftmaestro", category: "DAMRelink")

// MARK: - MaestroDAM Relink Service
//
// Reconnects cataloged assets to files whose absolute paths have gone stale
// (renamed/moved folders, remounted external drives with a different mount
// point, etc.). Works like Lightroom's "Find Missing Folder": the user picks
// the new root folder, and the catalog remaps paths by relative subpath or,
// if the internal structure changed, by filename match under the new root.
// When a filename matches more than one file, the candidates are returned so
// the UI can ask the user to pick.

enum DAMRelinkError: Error, Sendable {
    case targetNotFound
    case noAssets
    case noCommonPrefix
    case findTimeout
}

/// Update payload for one relinked asset.
struct DAMRelinkUpdate: Sendable {
    let id: Int64
    let path: String
    let folder: String
    let filename: String
    let volumeId: Int64?
    let relativePath: String?
}

/// One asset whose filename matches multiple files under the new root.
struct DAMRelinkAmbiguity: Identifiable, Sendable {
    let asset: DAMAsset
    let candidates: [URL]

    typealias ID = Int64
    var id: Int64 { asset.id ?? -1 }
}

/// Result of a relink attempt: unambiguous updates plus duplicates to resolve.
struct DAMRelinkResult: Sendable {
    let updates: [Int64: DAMRelinkUpdate]
    let ambiguous: [DAMRelinkAmbiguity]
    let volume: DAMVolume?
}

actor DAMRelinkService {

    static let shared = DAMRelinkService()

    private init() {}

    /// Attempt to relink a set of assets to a new root folder.
    /// - Parameters:
    ///   - assetIds: Assets whose paths should be checked and updated.
    ///   - targetFolderURL: The folder that now contains (or should contain)
    ///     the files. Can be set to the root of a drive; the service will crawl
    ///     all subdirectories.
    ///   - oldPrefix: The old root path to replace. If `nil`, the longest common
    ///     directory prefix of the stale asset paths is used.
    /// - Returns: A `DAMRelinkResult` containing the assets that were relinked
    ///   unambiguously and any duplicates that need user selection.
    func relink(
        assetIds: Set<Int64>,
        to targetFolderURL: URL,
        oldPrefix: String? = nil
    ) async throws -> DAMRelinkResult {
        let targetPath = targetFolderURL.standardizedFileURL.path

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DAMRelinkError.targetNotFound
        }

        let assets = try await DAMDatabase.shared.dbQueue.read { db in
            try DAMAsset.filter(assetIds.contains(DAMAsset.Columns.id)).fetchAll(db)
        }
        guard !assets.isEmpty else { throw DAMRelinkError.noAssets }

        // If the caller didn't supply the old root, derive it from the assets.
        let prefix = oldPrefix ?? Self.commonDirectoryPrefix(for: assets.map(\.path))
        guard let prefix, !prefix.isEmpty else { throw DAMRelinkError.noCommonPrefix }

        let volume = await DAMVolumeStore.shared.volumeInfo(for: targetFolderURL)

        let missingAssets = assets.filter { !FileManager.default.fileExists(atPath: $0.path) }
        let missingIds = Set(missingAssets.compactMap(\.id))
        relinkLogger.info("Relinking \(missingAssets.count) missing asset(s) under \(targetPath, privacy: .public)")

        // Use the Unix `find` command to look for the missing filenames. This is
        // far faster than enumerating an entire multi-terabyte drive root and
        // then filtering in memory.
        //
        // Some catalog rows (notably older Lightroom imports) store an empty
        // `filename`, so fall back to the last path component of `path`.
        let filenamesToSearch = Set(missingAssets.compactMap { Self.searchFilename(for: $0) })
        relinkLogger.info(
            "Searching for \(filenamesToSearch.count) distinct filename(s) among \(missingAssets.count) missing asset(s)"
        )
        if let sample = filenamesToSearch.first {
            relinkLogger.info("Sample search filename: \(sample, privacy: .public)")
        }
        let filenameMap = await Self.findFiles(named: Array(filenamesToSearch), under: targetFolderURL)
        relinkLogger.info("Found \(filenameMap.values.reduce(0) { $0 + $1.count }) candidate file(s) for \(filenameMap.count) filename(s)")

        var updates: [Int64: DAMRelinkUpdate] = [:]
        var ambiguousCandidates: [(asset: DAMAsset, candidates: [URL])] = []
        let assetById = Dictionary(uniqueKeysWithValues: assets.compactMap { ($0.id ?? -1, $0) })

        for asset in assets {
            guard let assetId = asset.id else { continue }

            // Already reachable — nothing to do.
            if !missingIds.contains(assetId) { continue }

            let remapped = Self.remappedPath(
                oldPath: asset.path,
                oldPrefix: prefix,
                newPrefix: targetPath
            )

            if FileManager.default.fileExists(atPath: remapped) {
                let finalURL = URL(fileURLWithPath: remapped)
                updates[assetId] = Self.update(for: finalURL, assetId: assetId, volume: volume)
            } else if let searchName = Self.searchFilename(for: asset),
                      let candidates = filenameMap[searchName], !candidates.isEmpty {
                switch candidates.count {
                case 1:
                    updates[assetId] = Self.update(for: candidates[0], assetId: assetId, volume: volume)
                default:
                    // Defer scoring until we've learned folder mappings from the
                    // unambiguous matches. Those mappings are often the strongest
                    // signal for the remaining ambiguous files.
                    ambiguousCandidates.append((asset: asset, candidates: candidates))
                }
            }
        }

        // Learn folder-to-folder mappings from unambiguous matches. If most files
        // from `/old/2023/` ended up in `/new/2023/`, we can use that to resolve
        // ambiguous candidates in the same original folder.
        let folderMapping = Self.inferFolderMapping(
            updates: updates,
            assetsById: assetById,
            oldPrefix: prefix,
            newPrefix: targetPath
        )
        if !folderMapping.isEmpty {
            relinkLogger.info("Inferred \(folderMapping.count) folder mapping(s) from unambiguous matches")
        }

        var ambiguous: [DAMRelinkAmbiguity] = []
        for (asset, candidates) in ambiguousCandidates {
            guard let assetId = asset.id else { continue }
            let mappedFolder = Self.relativeFolder(for: asset.path, under: prefix)
                .flatMap { folderMapping[$0] }
            let scored = candidates
                .map { (url: $0, score: Self.score(candidate: $0, for: asset, mappedFolder: mappedFolder, newPrefix: targetPath)) }
                .sorted { $0.score > $1.score }
            if scored[0].score >= 30,
               scored.count == 1 || scored[0].score - scored[1].score >= 15 {
                updates[assetId] = Self.update(for: scored[0].url, assetId: assetId, volume: volume)
            } else {
                ambiguous.append(DAMRelinkAmbiguity(asset: asset, candidates: scored.map(\.url)))
            }
        }

        relinkLogger.info("Relink result: \(updates.count) unambiguous, \(ambiguous.count) ambiguous")
        return DAMRelinkResult(updates: updates, ambiguous: ambiguous, volume: volume)
    }

    /// Turn explicit user choices for ambiguous matches into updates.
    func resolveAmbiguities(
        _ ambiguities: [DAMRelinkAmbiguity],
        choices: [Int64: URL],
        volume: DAMVolume?
    ) -> [Int64: DAMRelinkUpdate] {
        var updates: [Int64: DAMRelinkUpdate] = [:]
        for ambiguity in ambiguities {
            let id = ambiguity.asset.id ?? -1
            guard id > 0, let chosen = choices[id] else { continue }
            updates[id] = Self.update(for: chosen, assetId: id, volume: volume)
        }
        return updates
    }

    // MARK: - Path mapping helpers

    /// Returns the filename to search for on disk. Catalog rows that pre-date
    /// the filename column, or imports that failed to populate it, may store
    /// the filename only inside `path`.
    private static func searchFilename(for asset: DAMAsset) -> String? {
        let name = asset.filename.isEmpty
            ? (asset.path as NSString).lastPathComponent
            : asset.filename
        return name.isEmpty ? nil : name
    }

    private static func update(for url: URL, assetId: Int64, volume: DAMVolume?) -> DAMRelinkUpdate {
        let path = url.path
        return DAMRelinkUpdate(
            id: assetId,
            path: path,
            folder: (path as NSString).deletingLastPathComponent,
            filename: url.lastPathComponent,
            volumeId: volume?.id,
            relativePath: Self.relativePath(for: url)
        )
    }

    /// Replaces the old root prefix with the new root prefix, preserving the
    /// relative subpath.
    private static func remappedPath(oldPath: String, oldPrefix: String, newPrefix: String) -> String {
        let trimmedOld = oldPrefix.hasSuffix("/") ? String(oldPrefix.dropLast()) : oldPrefix
        let trimmedNew = newPrefix.hasSuffix("/") ? String(newPrefix.dropLast()) : newPrefix

        guard oldPath.hasPrefix(trimmedOld + "/") || oldPath == trimmedOld else {
            return trimmedNew
        }

        let suffix = String(oldPath.dropFirst(trimmedOld.count))
        let cleanSuffix = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
        return trimmedNew + "/" + cleanSuffix
    }

    /// Longest common directory prefix among the given paths.
    private static func commonDirectoryPrefix(for paths: [String]) -> String? {
        let dirs = paths.map { ($0 as NSString).deletingLastPathComponent }
        guard let first = dirs.first, !first.isEmpty else { return nil }

        var prefix = first
        for dir in dirs.dropFirst() {
            let current = dir
            while !current.hasPrefix(prefix) {
                prefix = (prefix as NSString).deletingLastPathComponent
                if prefix.isEmpty { return nil }
            }
        }
        return prefix
    }

    /// Searches `under` for files whose basename is in `names` using the
    /// system `find` command. This avoids walking millions of unrelated files
    /// on a large drive. Returns a map of basename -> candidate URLs.
    private static func findFiles(
        named names: [String],
        under url: URL
    ) async -> [String: [URL]] {
        let targetPath = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: targetPath),
              !names.isEmpty else { return [:] }

        // Batch names to stay well under ARG_MAX while still issuing one find
        // command per batch. 250 names per batch is conservative.
        let batchSize = 250
        var batches: [[String]] = []
        for i in stride(from: 0, to: names.count, by: batchSize) {
            batches.append(Array(names[i..<min(i + batchSize, names.count)]))
        }

        var allPaths: [String] = []
        for batch in batches {
            guard let paths = try? await Self.runFind(targetPath: targetPath, names: batch) else { continue }
            allPaths.append(contentsOf: paths)
        }

        var map: [String: [URL]] = [:]
        for path in allPaths {
            let fileURL = URL(fileURLWithPath: path)
            let name = fileURL.lastPathComponent
            map[name, default: []].append(fileURL)
        }
        return map
    }

    private static func runFind(targetPath: String, names: [String]) async throws -> [String] {
        guard !names.isEmpty else { return [] }
        let findURL = URL(fileURLWithPath: "/usr/bin/find")

        // Build: find targetPath -type f \( -name n1 -o -name n2 ... \) -print
        var arguments = [targetPath, "-type", "f", "("]
        for (index, name) in names.enumerated() {
            if index > 0 { arguments.append("-o") }
            arguments.append("-name")
            arguments.append(name)
        }
        arguments.append(")")
        arguments.append("-print")

        let process = Process()
        process.executableURL = findURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask {
                return try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { _ in
                        let stdout = stdoutPipe.fileHandleForReading.availableData
                        let output = String(data: stdout, encoding: .utf8) ?? ""
                        let lines = output.split(separator: "\n").map(String.init)
                        continuation.resume(returning: lines)
                    }
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                if process.isRunning { process.terminate() }
                throw DAMRelinkError.findTimeout
            }
            let result = try await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    /// Sort candidates so the path most similar to the original appears first.
    private static func sortedBySimilarity(candidates: [URL], to originalPath: String) -> [URL] {
        candidates.sorted {
            Self.levenshtein($0.path, originalPath) < Self.levenshtein($1.path, originalPath)
        }
    }

    /// Score a candidate file against the cataloged asset using file size,
    /// modification date, Finder tag/xattr keyword overlap, folder-path
    /// similarity, and an optional inferred folder mapping. This is the only
    /// way to disambiguate generic filenames (e.g., "Untitled - X of Y.jpeg")
    /// that exist in multiple folders.
    private static func score(
        candidate: URL,
        for asset: DAMAsset,
        mappedFolder: String? = nil,
        newPrefix: String? = nil
    ) -> Double {
        var score: Double = 0

        // File size is the strongest signal.
        let candidateAttributes = try? FileManager.default.attributesOfItem(atPath: candidate.path)
        if let candidateSize = candidateAttributes?[.size] as? Int64,
           let assetSize = asset.fileSize {
            if candidateSize == assetSize {
                score += 100
            } else {
                let diff = abs(candidateSize - assetSize)
                score -= Double(diff) / 1_000_000.0
            }
        }

        // Modification date within a few hours is a good corroborating signal.
        if let candidateDate = candidateAttributes?[.modificationDate] as? Date,
           let assetDate = asset.fileModDate {
            let hours = abs(candidateDate.timeIntervalSince(assetDate)) / 3600
            score -= hours
        }

        // Finder tag overlap (stored as xattr color map) is very discriminative.
        let assetTags = Self.assetTagNames(from: asset)
        if !assetTags.isEmpty,
           let candidateTags = try? candidate.resourceValues(forKeys: [.tagNamesKey]).tagNames {
            let common = assetTags.intersection(candidateTags).count
            score += Double(common) * 25
        }

        // Also score plain xattr keyword/tag name overlap for rows where the
        // color map wasn't captured.
        let assetKeywords = Self.assetKeywordSet(from: asset)
        if !assetKeywords.isEmpty,
           let candidateTags = try? candidate.resourceValues(forKeys: [.tagNamesKey]).tagNames {
            let common = assetKeywords.intersection(candidateTags).count
            score += Double(common) * 25
        }

        // Folder structure similarity: if the parent folder path is similar to
        // the original, the file likely moved together with its siblings.
        let originalFolder = asset.folder ?? (asset.path as NSString).deletingLastPathComponent
        let candidateFolder = (candidate.path as NSString).deletingLastPathComponent
        let folderDistance = Self.levenshtein(originalFolder, candidateFolder)
        let maxFolderLen = max(originalFolder.count, candidateFolder.count)
        if maxFolderLen > 0 {
            let similarity = 1.0 - Double(folderDistance) / Double(maxFolderLen)
            score += similarity * 20
        }

        // Inferred folder mapping from successful unambiguous matches is a very
        // strong signal (e.g., every other file from /old/2023/ landed in
        // /new/2023/, so an ambiguous file from /old/2023/ should too).
        if let mappedFolder, let newPrefix,
           let candidateRelFolder = Self.relativeFolder(for: candidate.path, under: newPrefix),
           candidateRelFolder == mappedFolder {
            score += 60
        }

        return score
    }

    private static func assetTagNames(from asset: DAMAsset) -> Set<String> {
        guard let json = asset.tagColors,
              let data = json.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
        else { return [] }
        return Set(map.keys)
    }

    private static func assetKeywordSet(from asset: DAMAsset) -> Set<String> {
        guard let keywords = asset.xattrKeywords, !keywords.isEmpty else { return [] }
        return Set(keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Classic Levenshtein distance — small strings only (file paths), so the
    /// O(n*m) cost is negligible.
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        var previous = [Int](0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Path relative to the file's volume root. Mirrors DAMVolumeStore's logic
    /// without crossing an actor boundary.
    private static func relativePath(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey]),
              let root = values.volume else { return nil }
        let rootPath = root.path
        let filePath = url.path
        guard filePath.hasPrefix(rootPath) else { return nil }
        let start = filePath.index(filePath.startIndex, offsetBy: rootPath.count)
        let remainder = String(filePath[start...])
        return remainder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Returns the folder path of `path` relative to `root`, or `nil` if `path`
    /// does not start with `root`. The filename itself is stripped.
    private static func relativeFolder(for path: String, under root: String) -> String? {
        let trimmedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard path.hasPrefix(trimmedRoot + "/") || path == trimmedRoot else { return nil }
        let suffix = String(path.dropFirst(trimmedRoot.count))
        let cleanSuffix = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
        let folder = (cleanSuffix as NSString).deletingLastPathComponent
        return folder
    }

    /// Learns folder relocation patterns from unambiguous matches. For each
    /// original folder (relative to the old root), returns the most common new
    /// folder (relative to the new root) observed among successful updates.
    private static func inferFolderMapping(
        updates: [Int64: DAMRelinkUpdate],
        assetsById: [Int64: DAMAsset],
        oldPrefix: String,
        newPrefix: String
    ) -> [String: String] {
        var counts: [String: [String: Int]] = [:]
        for (assetId, update) in updates {
            guard let asset = assetsById[assetId] else { continue }
            guard let oldFolder = Self.relativeFolder(for: asset.path, under: oldPrefix),
                  let newFolder = Self.relativeFolder(for: update.path, under: newPrefix) else { continue }
            counts[oldFolder, default: [:]][newFolder, default: 0] += 1
        }

        var mapping: [String: String] = [:]
        for (oldFolder, newFolders) in counts {
            guard let best = newFolders.max(by: { $0.value < $1.value }) else { continue }
            // Require at least two agreeing matches or a single unambiguous one.
            if best.value >= 2 || newFolders.count == 1 {
                mapping[oldFolder] = best.key
            }
        }
        return mapping
    }
}

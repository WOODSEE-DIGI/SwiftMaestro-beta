import Foundation

// MARK: - Storage Map model

/// A node in the DaisyDisk-style storage map.
struct StorageMapNode: Sendable, Identifiable {
    var id: String { path }
    var name: String
    var path: String
    var size: Int64
    var children: [StorageMapNode]
    var isDirectory: Bool
}

// MARK: - Progress

/// Progress snapshot for a Storage Map scan.
struct ScanProgress: Sendable {
    let scannedBytes: Int64
    let totalBytes: Int64
    let currentPath: String?
    let message: String?
    let elapsedSeconds: Double
    let completedItems: Int
    let totalItems: Int

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(scannedBytes) / Double(totalBytes))
    }

    var itemFraction: Double {
        guard totalItems > 0 else { return 0 }
        return min(1.0, Double(completedItems) / Double(totalItems))
    }

    var estimatedSecondsRemaining: Double? {
        guard scannedBytes > 0, totalBytes > scannedBytes, elapsedSeconds > 0 else { return nil }
        let rate = Double(scannedBytes) / elapsedSeconds
        return Double(totalBytes - scannedBytes) / rate
    }
}

// MARK: - Service

/// Performs a fresh filesystem scan and builds a folder-size tree for the
/// storage-map visualization. Runs as an actor so cancellation and progress
/// updates don't race.
actor DAMStorageMapService {
    static let shared = DAMStorageMapService()

    private init() {}

    /// Scans `url` recursively and returns a size tree up to `maxDepth`.
    /// Pass `maxDepth = .max` to walk the entire tree (not recommended for
    /// large volumes; 4-5 levels is usually enough for visualization).
    ///
    /// For volume roots (e.g. `/` or `/Volumes/MyDrive`) the scan uses `du`
    /// with `-x` (don’t cross filesystems), which is dramatically faster than
    /// a per-file Swift enumeration across millions of system files.
    ///
    /// `progress` is called on the MainActor with byte counts, the current
    /// path, an optional status message, elapsed time, and an estimated time
    /// remaining.
    func scan(
        url: URL,
        maxDepth: Int = 4,
        progress: @MainActor @Sendable @escaping (ScanProgress) -> Void = { _ in }
    ) async -> StorageMapNode {
        let rootPath = url.path
        let start = Date()

        if Self.isVolumeRoot(url: url) {
            if let node = await Self.scanVolumeRoot(
                url: url,
                rootPath: rootPath,
                maxDepth: maxDepth,
                start: start,
                progress: progress
            ) {
                return node
            }
        }

        // Get a quick total-size estimate so the UI can show a real progress
        // bar and ETA, then stream directory sizes from `du`. This is much
        // faster than a per-file Swift enumeration for folders like `/Users`.
        let totalBytes = await Self.totalSizeViaDU(path: rootPath) ?? 0

        await progress(ScanProgress(
            scannedBytes: 0,
            totalBytes: totalBytes,
            currentPath: rootPath,
            message: "Scanning with du…",
            elapsedSeconds: 0,
            completedItems: 0,
            totalItems: 0
        ))

        guard let duRoot = await Self.runDUStreaming(
            path: rootPath,
            depth: maxDepth,
            timeout: 1800,
            totalBytes: totalBytes,
            start: start,
            progress: progress
        ) else {
            return StorageMapNode(
                name: url.lastPathComponent,
                path: rootPath,
                size: totalBytes,
                children: [],
                isDirectory: true
            )
        }

        return Self.buildStorageMapNode(
            path: rootPath,
            duNode: duRoot,
            currentDepth: 0,
            maxDepth: maxDepth
        )
    }

    /// Returns true when `url` is the root of its volume (e.g. `/` or
    /// `/Volumes/Name`). Scanning these with `du` is much faster.
    private static func isVolumeRoot(url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey]),
              let volume = values.volume else { return false }
        return url.path == volume.path
    }

    /// Whether the app can actually read `/System/Volumes/Data`. This is a
    /// functional test for Full Disk Access: `du` can only size the system
    /// data volume when FDA is granted.
    private static func canReadSystemDataVolume() async -> Bool {
        (await totalSizeViaDU(path: "/System/Volumes/Data", timeout: 5) ?? 0) > 0
    }

    /// Quick total-size lookup using `/usr/bin/du -x -sk <path>`.
    /// Returns nil if `du` fails, times out, or the task is cancelled.
    private static func totalSizeViaDU(path: String, timeout: TimeInterval = 15) async -> Int64? {
        guard let root = await runDU(path: path, depth: 0, timeout: timeout) else { return nil }
        return root.size
    }

    /// Scans a volume root with a single streaming `du` process.
    ///
    /// Running one `du` process for the whole volume is slower than the
    /// parallel-per-child approach, but it avoids the per-child timeouts that
    /// were dropping huge folders like `/Users`, `/Library`, and `/Applications`
    /// from the result. Output is parsed incrementally so the byte progress bar
    /// fills smoothly and accurately as directories are reported.
    private static func scanVolumeRoot(
        url: URL,
        rootPath: String,
        maxDepth: Int,
        start: Date,
        progress: @MainActor @Sendable @escaping (ScanProgress) -> Void
    ) async -> StorageMapNode? {
        // Total used bytes on this volume gives the denominator for ETA.
        let totalBytes: Int64
        if let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
           let capacity = values.volumeTotalCapacity,
           let free = values.volumeAvailableCapacity {
            totalBytes = max(0, Int64(capacity) - Int64(free))
        } else {
            totalBytes = 0
        }

        // Scanning /System/Volumes/Data directly requires Full Disk Access and
        // returns zeros when the app lacks it. If Full Disk Access is granted,
        // scan the real data volume; otherwise fall back to /Users, which is
        // normally accessible, and present the result as Macintosh HD.
        let scanPath: String
        let rewriteFrom: String?
        let hasFDA = await Self.canReadSystemDataVolume()
        if rootPath == "/", hasFDA, FileManager.default.fileExists(atPath: "/System/Volumes/Data") {
            scanPath = "/System/Volumes/Data"
            rewriteFrom = scanPath
        } else if rootPath == "/", FileManager.default.fileExists(atPath: "/Users") {
            scanPath = "/Users"
            rewriteFrom = scanPath
        } else {
            scanPath = rootPath
            rewriteFrom = nil
        }

        await progress(ScanProgress(
            scannedBytes: 0,
            totalBytes: totalBytes,
            currentPath: rootPath,
            message: "Scanning volume with du…",
            elapsedSeconds: 0,
            completedItems: 0,
            totalItems: 0
        ))

        // A single deep scan can take several minutes on a large system drive.
        // 30 minutes is the hard ceiling before we return whatever du produced.
        guard let duRoot = await runDUStreaming(
            path: scanPath,
            depth: maxDepth,
            timeout: 1800,
            totalBytes: totalBytes,
            start: start,
            progress: progress
        ) else { return nil }

        var node = Self.buildStorageMapNode(path: scanPath, duNode: duRoot, currentDepth: 0, maxDepth: maxDepth)
        if let rewriteFrom {
            node = rewriteRoot(node, fromPrefix: rewriteFrom, toPrefix: "/")
        }
        if rootPath == "/" {
            node.name = "Macintosh HD"
        }
        return node
    }

    /// Runs `/usr/bin/du -x -d <depth> -k <path>` and returns a trie of
    /// directory sizes. Respects task cancellation and a hard timeout.
    private static func runDU(path: String, depth: Int, timeout: TimeInterval) async -> DuNode? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-x", "-d", "\(depth)", "-k", path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let began = Date()
            while process.isRunning {
                if Task.isCancelled {
                    process.terminate()
                    process.waitUntilExit()
                    return nil
                }
                if Date().timeIntervalSince(began) > timeout {
                    process.terminate()
                    process.waitUntilExit()
                    return nil
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // du exits 1 when it encounters protected subdirectories even
            // though it still emits usable sizes for accessible paths. Only
            // bail if the process exited with a hard signal or produced no
            // output at all.
            if process.terminationStatus != 0 && process.terminationStatus != 1 {
                return nil
            }
        } catch {
            return nil
        }

        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8),
              !output.isEmpty else { return nil }

        let root = DuNode()

        for line in output.split(whereSeparator: { $0.isNewline }) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2,
                  let kb = Int64(parts[0]) else { continue }
            let linePath = String(parts[1])
            let size = kb * 1024

            var node = root
            let components = linePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            for component in components {
                let child = node.children[component] ?? DuNode()
                node.children[component] = child
                node = child
            }
            node.size = size
        }

        // The caller expects the subtree rooted at `path`, not the overall
        // trie root. Descend to the node matching the scanned path so its
        // `size` and `children` are correct.
        let targetComponents = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var target = root
        for component in targetComponents {
            guard let child = target.children[component] else { return nil }
            target = child
        }
        return target
    }

    /// Parses a chunk of `du -k` output, inserts directories into `root`, and
    /// returns the number of bytes that can be counted without double-counting.
    /// `du` prints children before their parent (post-order), so a directory
    /// with no children in the trie is a leaf of the truncated tree and its
    /// size can be added to the running total.
    private static func parseDULines(
        from data: Data,
        into root: DuNode
    ) -> (scannedBytes: Int64, leftover: Data, parsedCount: Int, lastPath: String?) {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            return (0, data, 0, nil)
        }
        let complete = data.prefix(upTo: lastNewline)
        let leftover = data.suffix(from: lastNewline + 1)

        var scannedBytes: Int64 = 0
        var parsedCount = 0
        var lastPath: String?

        let lines = complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for lineData in lines {
            guard let line = String(data: Data(lineData), encoding: .utf8) else { continue }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2,
                  let kb = Int64(parts[0]) else { continue }
            let linePath = String(parts[1])
            let size = kb * 1024

            var node = root
            let components = linePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            for component in components {
                let child = node.children[component] ?? DuNode()
                node.children[component] = child
                node = child
            }
            node.size = size
            lastPath = linePath

            if node.children.isEmpty {
                scannedBytes += size
            }
            parsedCount += 1
        }

        return (scannedBytes, Data(leftover), parsedCount, lastPath)
    }

    /// Runs a single `du` process and parses its output as it streams in.
    /// Progress is reported periodically with byte counts derived from leaf
    /// directories, which avoids double-counting and gives an accurate fill
    /// of the top progress bar.
    private static func runDUStreaming(
        path: String,
        depth: Int,
        timeout: TimeInterval,
        totalBytes: Int64,
        start: Date,
        progress: @MainActor @Sendable @escaping (ScanProgress) -> Void
    ) async -> DuNode? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-x", "-d", "\(depth)", "-k", path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let handle = pipe.fileHandleForReading

        do {
            try process.run()
        } catch {
            return nil
        }

        let root = DuNode()
        var buffer = Data()
        var scannedBytes: Int64 = 0
        var parsedCount = 0
        var lastPath: String?
        var lastReport = Date()

        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                return nil
            }
            if Date().timeIntervalSince(start) > timeout {
                process.terminate()
                process.waitUntilExit()
                break
            }

            let available = handle.availableData
            if !available.isEmpty {
                buffer.append(available)
                let (chunkBytes, leftover, chunkCount, chunkLastPath) = Self.parseDULines(from: buffer, into: root)
                scannedBytes += chunkBytes
                parsedCount += chunkCount
                if let chunkLastPath { lastPath = chunkLastPath }
                buffer = leftover
            }

            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.5 {
                lastReport = now
                await progress(ScanProgress(
                    scannedBytes: scannedBytes,
                    totalBytes: totalBytes,
                    currentPath: lastPath ?? path,
                    message: nil,
                    elapsedSeconds: now.timeIntervalSince(start),
                    completedItems: parsedCount,
                    totalItems: 0
                ))
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if let remaining = try? handle.readToEnd() {
            buffer.append(remaining)
        }
        if !buffer.isEmpty {
            let (chunkBytes, leftover, chunkCount, chunkLastPath) = Self.parseDULines(from: buffer, into: root)
            scannedBytes += chunkBytes
            parsedCount += chunkCount
            if let chunkLastPath { lastPath = chunkLastPath }
            buffer = leftover
        }

        if process.terminationStatus != 0 && process.terminationStatus != 1 {
            return nil
        }

        let targetComponents = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var target = root
        for component in targetComponents {
            guard let child = target.children[component] else { return nil }
            target = child
        }
        return target
    }

    /// Fast `du`-based scan of a single folder, used for on-demand drill-down
    /// when the initial volume scan didn't include children for a node.
    func scanFolder(
        url: URL,
        maxDepth: Int = 2,
        progress: @MainActor @Sendable @escaping (ScanProgress) -> Void = { _ in }
    ) async -> StorageMapNode {
        let path = url.path
        let start = Date()
        await progress(ScanProgress(
            scannedBytes: 0,
            totalBytes: 0,
            currentPath: path,
            message: "Scanning \(url.lastPathComponent)…",
            elapsedSeconds: 0,
            completedItems: 0,
            totalItems: 0
        ))

        let duNode = await Self.runDUStreaming(
            path: path,
            depth: maxDepth,
            timeout: 600,
            totalBytes: 0,
            start: start,
            progress: progress
        )

        guard let duNode else {
            return StorageMapNode(name: url.lastPathComponent, path: path, size: 0, children: [], isDirectory: true)
        }

        return Self.buildStorageMapNode(path: path, duNode: duNode, currentDepth: 0, maxDepth: maxDepth)
    }

    /// A single file entry for leaf-folder file listings.
    struct FileSizeItem: Sendable, Identifiable {
        let id = UUID()
        let url: URL
        let size: Int64
        var name: String { url.lastPathComponent }
    }

    /// Returns the largest regular files directly inside `url`, sorted by size.
    func topFiles(in url: URL, limit: Int = 100) async -> [FileSizeItem] {
        await Task.detached(priority: .userInitiated) {
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            var items: [FileSizeItem] = []
            for object in enumerator.allObjects {
                guard let fileURL = object as? URL,
                      let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let size = values.fileSize else { continue }
                items.append(FileSizeItem(url: fileURL, size: Int64(size)))
            }
            items.sort { $0.size > $1.size }
            return Array(items.prefix(limit))
        }.value
    }

    private static func buildStorageMapNode(path: String, duNode: DuNode, currentDepth: Int, maxDepth: Int) -> StorageMapNode {
        let name = (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
        var children: [StorageMapNode] = []
        if currentDepth < maxDepth {
            for (nameKey, child) in duNode.children.sorted(by: { $0.value.size > $1.value.size }) {
                let childPath = (path as NSString).appendingPathComponent(nameKey)
                children.append(buildStorageMapNode(path: childPath, duNode: child, currentDepth: currentDepth + 1, maxDepth: maxDepth))
            }
        }
        return StorageMapNode(name: name, path: path, size: duNode.size, children: children, isDirectory: true)
    }

    private static func rewriteRoot(_ node: StorageMapNode, fromPrefix: String, toPrefix: String) -> StorageMapNode {
        let newPath: String
        if node.path == fromPrefix {
            newPath = toPrefix
        } else if node.path.hasPrefix(fromPrefix + "/") {
            newPath = toPrefix + node.path.dropFirst(fromPrefix.count)
        } else {
            newPath = node.path
        }
        let children = node.children.map { rewriteRoot($0, fromPrefix: fromPrefix, toPrefix: toPrefix) }
        return StorageMapNode(name: node.name, path: newPath, size: node.size, children: children, isDirectory: node.isDirectory)
    }

}

// MARK: - du trie

private final class DuNode: @unchecked Sendable {
    var size: Int64 = 0
    var children: [String: DuNode] = [:]
}

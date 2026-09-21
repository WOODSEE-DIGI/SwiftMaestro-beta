import AppKit
import CryptoKit
import Foundation
import ImageIO

// MARK: - MaestroDAM Offload Service

/// Offloads media from a source to a primary destination and an optional backup
/// destination with SHA-256 verification, template-based renaming, and optional
/// catalog import. Designed for camera-card and field-drive ingest workflows.
actor DAMOffloadService {

    static let shared = DAMOffloadService()

    enum OffloadError: Error, LocalizedError, Sendable {
        case invalidSource
        case invalidDestination
        case copyFailed(URL, Error)
        case checksumMismatch(URL, expected: String, actual: String)
        case importFailed(Error)
        case ejectFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidSource:
                return "The source folder is not valid or cannot be read."
            case .invalidDestination:
                return "The destination folder is not valid or cannot be written."
            case .copyFailed(let url, let error):
                return "Could not copy \(url.lastPathComponent): \(error.localizedDescription)"
            case .checksumMismatch(let url, let expected, let actual):
                return "SHA-256 mismatch for \(url.lastPathComponent): expected \(expected), got \(actual)"
            case .importFailed(let error):
                return "Catalog import failed: \(error.localizedDescription)"
            case .ejectFailed(let message):
                return "Could not eject source: \(message)"
            }
        }
    }

    private init() {}

    /// Performs the offload.
    /// - Parameters:
    ///   - options: Source, destinations, naming, and behavior options.
    ///   - database: Catalog database to import into.
    ///   - progress: Called on the MainActor with current progress.
    /// - Returns: A result summarizing copied, failed, and imported files.
    func offload(
        options: DAMOffloadOptions,
        database: DAMDatabase = .shared,
        progress: (@Sendable (DAMOffloadProgress) -> Void)? = nil
    ) async -> DAMOffloadResult {
        var result = DAMOffloadResult()

        guard let source = options.sourceURL,
              FileManager.default.fileExists(atPath: source.path) else {
            result.failed.append((URL(fileURLWithPath: ""), OffloadError.invalidSource.localizedDescription ?? "Invalid source"))
            return result
        }
        guard let primary = options.primaryDestinationURL else {
            result.failed.append((source, OffloadError.invalidDestination.localizedDescription ?? "Invalid destination"))
            return result
        }

        result.primaryURL = primary
        result.backupURL = options.backupDestinationURL

        // Start accessing the source in case it is a security-scoped or
        // iCloud-backed location.
        let accessedSource = source.startAccessingSecurityScopedResource()
        defer { if accessedSource { source.stopAccessingSecurityScopedResource() } }

        // Gather catalogable files from the source.
        await report(progress: progress, phase: .scanning, currentFile: "")
        let files = listCatalogableFiles(at: source)
        let total = files.count

        guard total > 0 else {
            await report(progress: progress, phase: .finished, completed: 0, total: 0)
            return result
        }

        // Prepare destination folders.
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: primary, withIntermediateDirectories: true)
            if let backup = options.backupDestinationURL {
                try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            }
        } catch {
            result.failed.append((source, OffloadError.invalidDestination.localizedDescription ?? error.localizedDescription))
            return result
        }

        var sequence = options.sequenceStart

        for (index, sourceURL) in files.enumerated() {
            do {
                try Task.checkCancellation()

                await report(
                    progress: progress,
                    phase: .copying,
                    currentFile: sourceURL.lastPathComponent,
                    completed: index,
                    total: total
                )

                let metadata = try await fileMetadata(for: sourceURL)
                let relativePath = try destinationRelativePath(
                    for: sourceURL,
                    sourceRoot: source,
                    options: options,
                    sequence: sequence,
                    metadata: metadata
                )

                let primaryFileURL = primary.appendingPathComponent(relativePath)
                try fm.createDirectory(
                    at: primaryFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                // Copy to primary.
                try copyFile(from: sourceURL, to: primaryFileURL)

                // Verify primary.
                if options.verifyChecksums {
                    await report(
                        progress: progress,
                        phase: .verifying,
                        currentFile: sourceURL.lastPathComponent,
                        completed: index,
                        total: total
                    )
                    try await verifyCopy(source: sourceURL, destination: primaryFileURL)
                }

                // Copy to backup and verify.
                if let backup = options.backupDestinationURL {
                    let backupFileURL = backup.appendingPathComponent(relativePath)
                    try fm.createDirectory(
                        at: backupFileURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try copyFile(from: sourceURL, to: backupFileURL)
                    if options.verifyChecksums {
                        try await verifyCopy(source: sourceURL, destination: backupFileURL)
                    }
                }

                result.copied += 1
                sequence += 1
            } catch {
                let message = (error as? OffloadError)?.errorDescription ?? error.localizedDescription
                result.failed.append((sourceURL, message))
            }
        }

        // Import the primary destination into the catalog.
        if options.importIntoCatalog, result.copied > 0 {
            await report(
                progress: progress,
                phase: .importing,
                currentFile: "",
                completed: result.copied,
                total: total
            )
            do {
                let imported = try await DAMImportService.shared.importFolder(at: primary, database: database)
                result.imported = imported
            } catch {
                result.failed.append((primary, OffloadError.importFailed(error).localizedDescription ?? error.localizedDescription))
            }
        }

        // Eject the source volume if requested.
        if options.ejectSourceWhenDone, let volumeURL = source.volumeRoot() {
            await report(progress: progress, phase: .ejecting, currentFile: "", completed: result.copied, total: total)
            do {
                try await ejectVolume(at: volumeURL)
            } catch {
                let message = (error as? OffloadError)?.errorDescription ?? error.localizedDescription
                result.failed.append((source, message))
            }
        }

        await report(progress: progress, phase: .finished, currentFile: "", completed: result.copied, total: total)
        return result
    }

    // MARK: - File discovery

    private nonisolated func listCatalogableFiles(at url: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator.compactMap { $0 as? URL }.filter { url in
            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty else { return false }
            return DAMFileKind.kind(for: url) != "unknown"
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - Metadata

    private nonisolated func fileMetadata(for url: URL) async throws -> DAMOffloadFileMetadata {
        var metadata = DAMOffloadFileMetadata()
        metadata.sourceName = url.deletingPathExtension().lastPathComponent
        metadata.sourceExtension = url.pathExtension.lowercased()
        metadata.sourceFolder = url.deletingLastPathComponent().lastPathComponent

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        metadata.modificationDate = attrs?[.modificationDate] as? Date

        // Try to read capture date and camera info from ImageIO without
        // decoding pixels.
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                metadata.captureDate = DAMImportService.parseEXIFDate(dateString)
            }
            if metadata.captureDate == nil,
               let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
               let dateString = tiff[kCGImagePropertyTIFFDateTime] as? String {
                metadata.captureDate = DAMImportService.parseEXIFDate(dateString)
            }
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                metadata.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
                metadata.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
            }
        }

        return metadata
    }

    // MARK: - Naming

    private nonisolated func destinationRelativePath(
        for sourceURL: URL,
        sourceRoot: URL,
        options: DAMOffloadOptions,
        sequence: Int,
        metadata: DAMOffloadFileMetadata
    ) throws -> String {
        let subfolder = renderTemplate(
            options.subfolderTemplate,
            sourceURL: sourceURL,
            sourceRoot: sourceRoot,
            sequence: sequence,
            metadata: metadata,
            options: options
        )
        let filename = renderTemplate(
            options.filenameTemplate,
            sourceURL: sourceURL,
            sourceRoot: sourceRoot,
            sequence: sequence,
            metadata: metadata,
            options: options
        )

        let cleanSubfolder = subfolder
            .components(separatedBy: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")

        let cleanFilename = filename
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")

        if cleanSubfolder.isEmpty {
            return cleanFilename
        }
        return cleanSubfolder + "/" + cleanFilename
    }

    private nonisolated func renderTemplate(
        _ template: String,
        sourceURL: URL,
        sourceRoot: URL,
        sequence: Int,
        metadata: DAMOffloadFileMetadata,
        options: DAMOffloadOptions
    ) -> String {
        let date = metadata.captureDate ?? metadata.modificationDate ?? Date()
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)

        var result = template

        // {date} and {date:FORMAT}
        result = result.replacingOccurrences(
            of: #"\{date(:([^}]+))?\}"#,
            with: { match in
                let format = match.groups.count > 1 ? String(match.groups[1]) : "yyyy-MM-dd"
                dateFormatter.dateFormat = format
                return dateFormatter.string(from: date)
            },
            options: .regularExpression
        )

        // {time}
        dateFormatter.dateFormat = "HHmmss"
        result = result.replacingOccurrences(of: "{time}", with: dateFormatter.string(from: date))

        // {seq}
        let seqString = String(format: "%0\(options.sequencePadding)d", sequence)
        result = result.replacingOccurrences(of: "{seq}", with: seqString)

        // {original}
        result = result.replacingOccurrences(of: "{original}", with: sourceURL.lastPathComponent)

        // {name}
        result = result.replacingOccurrences(of: "{name}", with: metadata.sourceName)

        // {ext}
        result = result.replacingOccurrences(of: "{ext}", with: metadata.sourceExtension)

        // {camera}
        let camera = [metadata.cameraMake, metadata.cameraModel]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        result = result.replacingOccurrences(of: "{camera}", with: camera)

        // {cameramake}
        result = result.replacingOccurrences(of: "{cameramake}", with: metadata.cameraMake ?? "")

        // {cameramodel}
        result = result.replacingOccurrences(of: "{cameramodel}", with: metadata.cameraModel ?? "")

        // {folder}
        result = result.replacingOccurrences(of: "{folder}", with: metadata.sourceFolder)

        return result
    }

    // MARK: - Copy & verify

    private nonisolated func copyFile(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            // Make a unique name rather than overwriting.
            var counter = 1
            let base = destination.deletingPathExtension().lastPathComponent
            let ext = destination.pathExtension
            var candidate = destination
            while fm.fileExists(atPath: candidate.path) {
                let suffix = ext.isEmpty ? "\(counter)" : "\(counter).\(ext)"
                let name = "\(base) \(suffix)"
                candidate = destination.deletingLastPathComponent().appendingPathComponent(name)
                counter += 1
            }
            try fm.copyItem(at: source, to: candidate)
        } else {
            try fm.copyItem(at: source, to: destination)
        }
    }

    private nonisolated func verifyCopy(source: URL, destination: URL) async throws {
        guard let sourceHash = await sha256(of: source) else {
            throw OffloadError.checksumMismatch(source, expected: "(unreadable)", actual: "(unreadable)")
        }
        guard let destHash = await sha256(of: destination) else {
            throw OffloadError.checksumMismatch(destination, expected: sourceHash, actual: "(unreadable)")
        }
        guard sourceHash.caseInsensitiveCompare(destHash) == .orderedSame else {
            throw OffloadError.checksumMismatch(destination, expected: sourceHash, actual: destHash)
        }
    }

    private nonisolated func sha256(of url: URL) async -> String? {
        do {
            return try await DAMResourceLimiter.shared.withTimeout(seconds: 300) {
                try await Self.computeSHA256(of: url)
            }
        } catch {
            return nil
        }
    }

    private nonisolated static func computeSHA256(of url: URL) async throws -> String {
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

    // MARK: - Eject

    private nonisolated func ejectVolume(at url: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["eject", url.path]

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: OffloadError.ejectFailed("diskutil exit code \(proc.terminationStatus)"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: OffloadError.ejectFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - Progress

    @MainActor
    private func report(
        progress: (@Sendable (DAMOffloadProgress) -> Void)?,
        phase: DAMOffloadProgress.Phase,
        currentFile: String = "",
        completed: Int = 0,
        total: Int = 0
    ) async {
        progress?(DAMOffloadProgress(
            currentFile: currentFile,
            completed: completed,
            total: total,
            phase: phase
        ))
    }
}

// MARK: - File metadata

struct DAMOffloadFileMetadata: Sendable {
    var sourceName: String = ""
    var sourceExtension: String = ""
    var sourceFolder: String = ""
    var modificationDate: Date?
    var captureDate: Date?
    var cameraMake: String?
    var cameraModel: String?
}

// MARK: - URL helpers

extension URL {
    /// Returns the nearest ancestor that is a mounted volume root.
    fileprivate func volumeRoot() -> URL? {
        let path = self.path
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ) ?? []
        return volumes
            .filter { path.hasPrefix($0.path) }
            .max(by: { $0.path.count < $1.path.count })
    }
}

// MARK: - Regex match helper

private struct RegexMatch {
    let fullMatch: String
    let groups: [String]
}

private extension String {
    func replacingOccurrences(
        of pattern: String,
        with replacement: (RegexMatch) -> String,
        options: NSString.CompareOptions
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return self }
        let nsString = self as NSString
        let matches = regex.matches(in: self, options: [], range: NSRange(location: 0, length: nsString.length))

        var result = self
        for match in matches.reversed() {
            let fullRange = match.range
            let fullMatch = nsString.substring(with: fullRange)
            var groups: [String] = []
            for i in 1..<match.numberOfRanges {
                let range = match.range(at: i)
                if range.location != NSNotFound {
                    groups.append(nsString.substring(with: range))
                } else {
                    groups.append("")
                }
            }
            let replacementString = replacement(RegexMatch(fullMatch: fullMatch, groups: groups))
            result = (result as NSString).replacingCharacters(in: fullRange, with: replacementString)
        }
        return result
    }
}

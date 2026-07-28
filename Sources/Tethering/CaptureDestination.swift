import Foundation

/// Manages the user-selected folder where captures are stored.
@MainActor
@Observable
final class CaptureDestination: Sendable {
    private let defaultsKey = "tethering.captureDestination"

    var folderURL: URL? {
        didSet {
            saveBookmark()
        }
    }

    var storageMode: CaptureStorageMode = .copyToFolder {
        didSet {
            UserDefaults.standard.set(storageMode.rawValue, forKey: "tethering.storageMode")
        }
    }

    init() {
        self.storageMode = CaptureStorageMode(
            rawValue: UserDefaults.standard.string(forKey: "tethering.storageMode") ?? ""
        ) ?? .copyToFolder
        restoreBookmark()
    }

    /// Resolves a folder for a source, creating a subfolder if desired.
    func resolvedFolder(forSource source: any CaptureSource, createSubfolder: Bool = true) throws -> URL {
        guard let base = folderURL else {
            throw CaptureDestinationError.noDestination
        }

        let resolved = try resolveSecurityScopedURL(base)
        var destination = resolved

        if createSubfolder {
            destination = resolved.appendingPathComponent(source.name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        guard FileManager.default.isWritableFile(atPath: destination.path) else {
            throw CaptureSourceError.destinationNotWritable(destination)
        }

        return destination
    }

    /// Returns a unique filename for a new capture.
    func uniqueFileURL(
        in folder: URL,
        prefix: String,
        fileType: CapturedFileType,
        date: Date = Date()
    ) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = "\(prefix)_\(formatter.string(from: date))"
        let ext = fileExtension(for: fileType)
        var candidate = folder.appendingPathComponent("\(base).\(ext)")
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)_\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    // MARK: - Security-scoped bookmark persistence

    private func saveBookmark() {
        guard let url = folderURL else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } catch {
            print("[CaptureDestination] Failed to create bookmark: \(error)")
        }
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                saveBookmark()
            }
            self.folderURL = url
        } catch {
            print("[CaptureDestination] Failed to restore bookmark: \(error)")
        }
    }

    private nonisolated func resolveSecurityScopedURL(_ url: URL) throws -> URL {
        let resolved = url
        let _ = resolved.startAccessingSecurityScopedResource()
        defer { resolved.stopAccessingSecurityScopedResource() }
        return resolved
    }

    private nonisolated func fileExtension(for fileType: CapturedFileType) -> String {
        switch fileType {
        case .jpeg:       return "jpg"
        case .raw:        return "raw"
        case .tiff:       return "tiff"
        case .png:        return "png"
        case .heif:       return "heif"
        case .videoFrame: return "jpg"
        }
    }
}

enum CaptureDestinationError: LocalizedError, Sendable {
    case noDestination

    var errorDescription: String? {
        switch self {
        case .noDestination:
            return "No capture destination folder selected."
        }
    }
}

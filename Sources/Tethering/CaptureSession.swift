import Foundation
import Observation

/// Orchestrates one capture source and a shared destination.
@MainActor
@Observable
final class CaptureSession: Sendable {
    let source: any CaptureSource
    private let destination: CaptureDestination
    private let thumbnailCache: CaptureThumbnailCache

    var recentCaptures: [CapturedImage] = []
    var lastError: CaptureSourceError? = nil
    var isPreviewing: Bool = false

    init(
        source: any CaptureSource,
        destination: CaptureDestination,
        thumbnailCache: CaptureThumbnailCache = .shared
    ) {
        self.source = source
        self.destination = destination
        self.thumbnailCache = thumbnailCache
    }

    func startPreview() async {
        do {
            try await source.startPreview()
            isPreviewing = true
            lastError = nil
        } catch {
            lastError = map(error)
        }
    }

    func stopPreview() async {
        await source.stopPreview()
        isPreviewing = false
    }

    func capture() async {
        do {
            let folder = try destination.resolvedFolder(forSource: source)
            var captured = try await source.captureStill(to: folder)
            if let thumbnail = await thumbnailCache.thumbnail(for: captured.fileURL) {
                captured = CapturedImage(
                    id: captured.id,
                    sourceID: captured.sourceID,
                    sourceName: captured.sourceName,
                    captureDate: captured.captureDate,
                    fileURL: captured.fileURL,
                    thumbnailData: thumbnail,
                    fileType: captured.fileType,
                    metadata: captured.metadata
                )
            }
            recentCaptures.insert(captured, at: 0)
            lastError = nil
        } catch {
            lastError = map(error)
        }
    }

    func disconnect() async {
        await source.disconnect()
        isPreviewing = false
    }

    private func map(_ error: Error) -> CaptureSourceError {
        if let capture = error as? CaptureSourceError {
            return capture
        }
        return .underlying(error)
    }
}

/// Shared in-memory thumbnail cache for the tethering UI.
@MainActor
@Observable
final class CaptureThumbnailCache: Sendable {
    static let shared = CaptureThumbnailCache()
    private init() {}

    private var cache: [URL: Data] = [:]

    func thumbnail(for url: URL?) async -> Data? {
        guard let url = url else { return nil }
        if let cached = cache[url] { return cached }
        do {
            let data = try Data(contentsOf: url)
            cache[url] = data
            return data
        } catch {
            return nil
        }
    }

    func clear() {
        cache.removeAll()
    }
}

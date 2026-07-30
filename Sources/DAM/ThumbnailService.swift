import AppKit
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: - MaestroDAM Thumbnail Service
//
// Generates and caches thumbnails with a four-engine pipeline:
//
//   1. ZIP-package guard — Capture One `.eip` files are ZIP archives (typed
//      as camera-raw-image, which hangs QuickLook): extract the inner RAW
//      and decode with LibRaw.
//   2. Camera RAW (any variant) — LibRaw-first (embedded preview first,
//      half-decode fallback): Apple's decoder fails on several variants
//      (RA30/RA02/RA04) while LibRaw is uniformly fast and quiet.
//   3. Standard images (HEIC/JPEG/PNG/TIFF/WebP) — QuickLook first
//      (out-of-process decode + shared system cache keeps IOSurface
//      pressure out of our process), ImageIO in-process as fallback.
//   4. Everything else (PDF/video/audio/docs) — QuickLook only,
//      concurrency-capped. There is deliberately NO LibRaw fallback for
//      non-RAW input: feeding JPEG/PNG bytes to LibRaw's parsers produced
//      EXC_BAD_ACCESS crashes (observed in production at 98% CPU).
//
// Caches: in-memory NSCache + JPEG disk cache keyed by path+size+mtime so
// edits invalidate automatically. Duplicate in-flight requests coalesce onto
// one task. Heavy decode work runs off-actor (Task.detached) so cache hits
// stay instant while RAWs decode in the background.

/// Wraps a non-Sendable value so it can cross a continuation/actor boundary
/// where the programmer knows the hand-off is safe (single ownership
/// transfer, never shared). Matches the `@unchecked Sendable` pattern used
/// throughout Tethering/.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// One-shot claim token guarding a continuation against QL's multi-fire
/// update handler (double-resume of a checked continuation traps).
private final class QLResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    /// Returns true exactly once — the first caller wins, later calls no-op.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didResume { return false }
        didResume = true
        return true
    }
}

/// Caps concurrent decodes per engine. FIFO, cancellation-safe: a caller
/// cancelled while queued is removed and NEVER handed a slot (a dead task
/// holding a slot it will never release leaks the pool → all later
/// requests queue forever → permanent spinners).
private actor DecodeSlotLimiter {
    private var available: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(maxConcurrent: Int) { available = maxConcurrent }

    /// Throws CancellationError if cancelled while queued — in that case no
    /// slot was acquired and the caller must NOT call release().
    func acquire() async throws {
        if available > 0 {
            available -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if available > 0 {
                    available -= 1
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.removeWaiter(id) }
        }
    }

    private func removeWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    func release() {
        // Skip cancelled waiters already removed; hand the slot to the
        // oldest live waiter, or return it to the pool.
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume()
        } else {
            available += 1
        }
    }
}

actor ThumbnailService {

    static let shared = ThumbnailService()

    /// Max simultaneous LibRaw decodes (QL has its own system-side queuing).
    private static let decodeSlots = DecodeSlotLimiter(maxConcurrent: 2)

    /// Max simultaneous QuickLook requests — QL starves silently when
    /// flooded (requests take minutes or never call back), so pace them.
    private static let qlSlots = DecodeSlotLimiter(maxConcurrent: 4)

    /// Max simultaneous ImageIO decodes — ImageIO runs synchronously inside
    /// each request's detached task, so without a cap a fast-scrolling grid
    /// can spawn hundreds of parallel decodes and CPU-storm the UI.
    private static let imageIOSlots = DecodeSlotLimiter(maxConcurrent: 4)

    enum ThumbnailError: Error, Sendable {
        case generationFailed
        case noRepresentation
        case noInnerRAW
        case timedOut
    }

    /// The grid requests this size; loupe/filmstrip will use a larger one.
    static let gridPixelSize: CGFloat = 256

    /// Above this size a request is a user-facing PREVIEW, not a grid cell —
    /// routed straight to ImageIO (see render()).
    private static let previewThreshold: CGFloat = 384

    /// Thread-safe on its own (Apple documents NSCache as safe for
    /// concurrent access without external locking); kept nonisolated so the
    /// detached render task can cache completed renders even when the
    /// awaiting caller (a view `.task`) was cancelled mid-flight — otherwise
    /// a cancelled preview drops the finished image and the next request
    /// pays full decode again.
    private nonisolated(unsafe) static let memoryCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // Bound the decoded-pixel pool: without a cost limit NSCache evicts
        // unpredictably under memory pressure, causing visible re-decode
        // flicker when scrolling back through a folder. ~512 MB of RGBA.
        cache.totalCostLimit = 512 * 1024 * 1024
        return cache
    }()

    private var inFlight: [String: Task<NSImage, Error>] = [:]

    /// Keys whose thumbnail generation already failed once this session
    /// (unsupported/corrupt files). Prevents the retry-on-every-scroll
    /// storm that floods the console with decoder errors. ONLY real file
    /// failures are recorded — never cancellation or timeouts.
    private var failedKeys: Set<String> = []

    private init() {}

    // MARK: - Public API

    /// Returns a thumbnail for the file, generating and caching on first use.
    /// - Parameter pixelSize: longest edge in points (rendered at 2x).
    func thumbnail(for url: URL, pixelSize: CGFloat = gridPixelSize) async throws -> NSImage {
        let key = Self.cacheKey(for: url, size: Int(pixelSize))

        if let cached = Self.memoryCache.object(forKey: key as NSString) {
            return cached
        }
        if failedKeys.contains(key) {
            throw ThumbnailError.generationFailed
        }

        // Coalesce duplicate requests for the same key.
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task<NSImage, Error>.detached(priority: .utility) {
            let image = try await Self.render(url: url, pixelSize: pixelSize, key: key)
            // Cache on the render side: if the awaiting caller is cancelled
            // (view teardown), the completed render is still kept.
            let cost = max(1, Int(image.size.width * image.size.height * 4))
            Self.memoryCache.setObject(image, forKey: key as NSString, cost: cost)
            return image
        }
        inFlight[key] = task

        do {
            let image = try await task.value
            inFlight.removeValue(forKey: key)
            return image
        } catch {
            inFlight.removeValue(forKey: key)
            // Transient conditions must NOT poison the key: cancellation
            // (the view went away mid-request) and QL timeout (queue
            // congestion on slow volumes) are not file failures — the next
            // request must be allowed to retry.
            let isTimeout = (error as? ThumbnailError) == .timedOut
            if !(error is CancellationError), !isTimeout {
                failedKeys.insert(key)
            }
            throw error
        }
    }

    // MARK: - Render pipeline (off-actor)

    /// Full generation path: disk cache → EIP extraction → LibRaw (RAW) →
    /// ImageIO (standard images) → QuickLook (everything else, QL only).
    /// Writes the JPEG disk cache on success.
    private nonisolated static func render(url: URL, pixelSize: CGFloat, key: String) async throws -> NSImage {
        // Disk cache hit?
        if let cacheURL = try? cacheDirectory().appendingPathComponent("\(key).jpg"),
           let data = try? Data(contentsOf: cacheURL),
           let image = NSImage(data: data) {
            return image
        }

        // Capture One .eip (ZIP): extract inner RAW, LibRaw decode.
        if DAMFileKind.isZIPPackage(url) {
            return try await rawDecodeAndCache(url, pixelSize: pixelSize, key: key, isPackagedEIP: true)
        }

        // ALL camera RAW variants: LibRaw-first. Apple's decoder fails on
        // several (RA30/RA02/RA04 per-file error spam), while LibRaw's
        // embedded-preview path is uniformly fast and quiet.
        if DAMFileKind.isCameraRAW(url) {
            return try await rawDecodeAndCache(url, pixelSize: pixelSize, key: key, isPackagedEIP: false)
        }

        // Standard images (HEIC/JPEG/PNG/TIFF/WebP) — routing depends on size:
        //
        // PREVIEWS (>384px): straight to ImageIO. A preview is ONE
        // user-facing decode (~12 MB at 1600px — trivial), synchronous and
        // milliseconds-fast. Crucially it is IMMUNE to the QL queue: the
        // grid floods the 4 QL slots, and zombie QL requests on slow
        // volumes each hold a slot for the full 8s timeout — a large
        // preview queued behind that backlog spun forever (the "flickering
        // spinner" bug). ImageIO has no XPC, no zombie mode, no queue.
        //
        // GRID THUMBNAILS (≤384px): QuickLook first — decoded
        // out-of-process by quicklookd and served from the shared system
        // cache, keeping hundreds of decoded-pixel IOSurfaces out of our
        // address space (critical with a ~26 GB LLM resident). ImageIO is
        // the fallback if QL fails/times out. Both engines are capped.
        if DAMFileKind.isStandardImage(url) {
            if pixelSize > previewThreshold {
                return try await imageIOWithSlots(url: url, pixelSize: pixelSize, key: key)
            }
            do {
                return try await quickLookAndCache(url, pixelSize: pixelSize, key: key)
            } catch {
                return try await imageIOWithSlots(url: url, pixelSize: pixelSize, key: key)
            }
        }

        // Everything else (PDF/video/docs): QuickLook, concurrency-capped.
        // NO LibRaw fallback — feeding non-RAW bytes to LibRaw's parsers can
        // crash the process (EXC_BAD_ACCESS; seen in production).
        return try await quickLookAndCache(url, pixelSize: pixelSize, key: key)
    }

    // MARK: - ImageIO engine (standard images)

    /// HEIC/JPEG/PNG/TIFF/WebP via ImageIO — synchronous, a few ms per file,
    /// called from the detached render task (no extra hop needed).
    private nonisolated static func imageIOWithSlots(
        url: URL, pixelSize: CGFloat, key: String
    ) async throws -> NSImage {
        try await imageIOSlots.acquire()
        do {
            let image = try imageIOAndCache(url: url, pixelSize: pixelSize, key: key)
            await imageIOSlots.release()
            return image
        } catch {
            await imageIOSlots.release()
            throw error
        }
    }

    private nonisolated static func imageIOAndCache(
        url: URL, pixelSize: CGFloat, key: String
    ) throws -> NSImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ThumbnailError.generationFailed
        }
        let maxPixel = max(1, Int((pixelSize * 2).rounded()))   // retina, like QL's scale 2
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ThumbnailError.generationFailed
        }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height))

        // Persist a JPEG to the disk cache (best-effort).
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]),
           let cacheURL = try? cacheDirectory().appendingPathComponent("\(key).jpg") {
            try? jpeg.write(to: cacheURL, options: .atomic)
        }
        return image
    }

    // MARK: - QuickLook engine

    private nonisolated static func quickLookAndCache(
        _ url: URL, pixelSize: CGFloat, key: String
    ) async throws -> NSImage {
        try await qlSlots.acquire()
        do {
            // QLThumbnailGenerator has a documented failure mode where the
            // callback is NEVER invoked (zombie request — seen for HEIC on
            // secondary volumes). Race it against a timeout so the caller
            // can fall back to ImageIO instead of spinning forever. The
            // slot is released on either outcome; an abandoned QL callback
            // arriving later is absorbed by QLResumeGuard.
            let box = try await raceWithTimeout(seconds: 8) {
                UncheckedSendableBox(try await performQuickLook(url, pixelSize: pixelSize, key: key))
            }
            await qlSlots.release()
            return box.value
        } catch {
            await qlSlots.release()
            throw error
        }
    }

    /// Races an async operation against a timeout, resuming exactly once.
    /// Deliberately NOT a TaskGroup: a group awaits cancelled children, and
    /// a child suspended on a never-resuming continuation (zombie QL
    /// request) would hang the group forever. Here the losing task is
    /// simply abandoned; the continuation is single-resume guarded.
    private nonisolated static func raceWithTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let guardBox = QLResumeGuard()
        return try await withCheckedThrowingContinuation { continuation in
            let operationTask = Task {
                do {
                    let value = try await operation()
                    if guardBox.claim() { continuation.resume(returning: value) }
                } catch {
                    if guardBox.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if guardBox.claim() {
                    continuation.resume(throwing: ThumbnailError.timedOut)
                    operationTask.cancel()
                }
            }
        }
    }

    private nonisolated static func performQuickLook(
        _ url: URL, pixelSize: CGFloat, key: String
    ) async throws -> NSImage {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pixelSize, height: pixelSize),
            scale: 2.0,                       // retina-quality for the grid
            representationTypes: .thumbnail
        )

        // QL's update handler may legally fire MORE THAN ONCE (progressively
        // better representations) — resume the continuation exactly once.
        let resumeGuard = QLResumeGuard()
        let representation = try await withCheckedThrowingContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, error in
                guard resumeGuard.claim() else { return }
                if let thumbnail {
                    // QLThumbnailRepresentation is non-Sendable, so it crosses
                    // the continuation boundary in an unchecked box.
                    continuation.resume(returning: UncheckedSendableBox(thumbnail))
                } else {
                    continuation.resume(throwing: error ?? ThumbnailError.generationFailed)
                }
            }
        }.value

        let image = representation.nsImage

        // Persist a JPEG to the disk cache (best-effort).
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]),
           let cacheURL = try? cacheDirectory().appendingPathComponent("\(key).jpg") {
            try? jpeg.write(to: cacheURL, options: .atomic)
        }

        return image
    }

    // MARK: - LibRaw engine

    /// Decodes via `RAWPreviewDecoder` (LibRaw), caches the JPEG data
    /// directly (no re-encode), and returns the image. Concurrency-capped:
    /// each 50 MP decode spikes ~1-2 GB transiently.
    private nonisolated static func rawDecodeAndCache(
        _ url: URL, pixelSize: CGFloat, key: String, isPackagedEIP: Bool
    ) async throws -> NSImage {
        try await decodeSlots.acquire()
        do {
            let image = try performRawDecode(url, pixelSize: pixelSize, key: key, isPackagedEIP: isPackagedEIP)
            await decodeSlots.release()
            return image
        } catch {
            await decodeSlots.release()
            throw error
        }
    }

    private nonisolated static func performRawDecode(
        _ url: URL, pixelSize: CGFloat, key: String, isPackagedEIP: Bool
    ) throws -> NSImage {
        var decodeURL = url
        var tempToDelete: URL?

        if isPackagedEIP {
            decodeURL = try extractInnerRAW(from: url, key: key)
            tempToDelete = decodeURL
        }
        defer { if let tempToDelete { try? FileManager.default.removeItem(at: tempToDelete) } }

        // NSError** out-param → Swift imports the ObjC method as `throws`.
        let jpeg = try RAWPreviewDecoder.jpegPreviewForRAW(
            atPath: decodeURL.path, maxPixelSize: pixelSize * 2)
        guard let image = NSImage(data: jpeg) else {
            throw ThumbnailError.noRepresentation
        }

        if let cacheURL = try? cacheDirectory().appendingPathComponent("\(key).jpg") {
            try? jpeg.write(to: cacheURL, options: .atomic)
        }
        return image
    }

    // MARK: - EIP (packaged RAW) extraction

    /// Extracts the inner camera RAW from a Capture One `.eip` ZIP package
    /// to a temp file for decoding. Deleted by the caller.
    private nonisolated static func extractInnerRAW(from eipURL: URL, key: String) throws -> URL {
        let listData = try runCommand("/usr/bin/unzip", ["-Z1", eipURL.path])
        guard let listing = String(data: listData, encoding: .utf8) else {
            throw ThumbnailError.noInnerRAW
        }
        let rawExtensions: Set<String> = [
            "cr3", "cr2", "nef", "iiq", "arw", "dng", "raf", "orf", "rw2", "pef", "srw", "erf"
        ]
        let entry = listing
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { rawExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        guard let entry else { throw ThumbnailError.noInnerRAW }

        let ext = URL(fileURLWithPath: entry).pathExtension.lowercased()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dam-eip-\(key).\(ext)")

        let rawData = try runCommand("/usr/bin/unzip", ["-p", eipURL.path, entry])
        try rawData.write(to: tempURL, options: .atomic)
        return tempURL
    }

    /// Runs a short-lived system command, returning stdout. Stderr is
    /// discarded; a non-zero exit is an error.
    private nonisolated static func runCommand(_ launchPath: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ThumbnailError.generationFailed
        }
        return data
    }

    // MARK: - Cache plumbing

    private nonisolated static func cacheDirectory() throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("SwiftMaestro/dam-thumbs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Cache key ties the thumbnail to the file's identity AND current
    /// modification state, so a re-saved edit produces a fresh thumbnail.
    /// The `v2` prefix busts entries written before the embedded-preview
    /// minimum-size rule (which cached fuzzy 160px DNG thumbs) — those
    /// stale files are simply never read again.
    private nonisolated static func cacheKey(for url: URL, size: Int) -> String {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSince1970) ?? 0
        let raw = "v2|\(url.path)|\(size)|\(mtime)"
        // Paths can exceed filename limits — hash the key to a fixed-length name.
        var hash: UInt64 = 5381
        for byte in raw.utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(byte) }
        return String(hash, radix: 16)
    }
}

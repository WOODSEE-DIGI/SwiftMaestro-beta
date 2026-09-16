import Foundation
import AppKit

// MARK: - Safe RAW thumbnail service

/// Decodes RAW files out-of-process using the system `sips` tool.
///
/// The vendored LibRaw decoder (`RAWPreviewDecoder`) is fast and supports many
/// formats, but it can crash (EXC_BAD_ACCESS) on malformed RAW files. Because
/// it runs in-process, one bad file can freeze or kill SwiftMaestro. This
/// service spawns `sips` for RAW files instead: if a file is corrupt, the
/// external process dies and the app keeps running.
actor DAMSafeRAWThumbnailService {
    static let shared = DAMSafeRAWThumbnailService()

    private init() {}

    /// Returns a small `NSImage` thumbnail for a RAW file, or nil if `sips`
    /// cannot decode it within the timeout.
    func thumbnail(for path: String, maxPixelSize: CGFloat = 80) async -> NSImage? {
        guard let data = await jpegData(for: path, maxPixelSize: maxPixelSize) else { return nil }
        return NSImage(data: data)
    }

    /// Returns a JPEG-encoded thumbnail for a RAW file. Useful when the caller
    /// needs pixels rather than an `NSImage` (e.g. perceptual hashing).
    func jpegData(for path: String, maxPixelSize: CGFloat = 80) async -> Data? {
        let inputURL = URL(fileURLWithPath: path)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftmaestro-raw-thumb-\(UUID().uuidString).jpg")

        do {
            return try await Self.runSips(input: inputURL, output: outputURL, maxPixelSize: maxPixelSize)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
    }

    // MARK: - sips wrapper

    private enum ServiceError: Error {
        case timeout
        case processFailed(Int32)
    }

    /// Runs `sips -Z <size> -s format jpeg <input> --out <output>` with a hard timeout.
    /// The explicit output format is required: without it, `sips` tries to write
    /// the source RAW format (e.g. `com.adobe.raw-image` or `com.sony.arw-raw-image`)
    /// and fails with "Can't write format" for most RAW files.
    private nonisolated static func runSips(
        input: URL,
        output: URL,
        maxPixelSize: CGFloat
    ) async throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        process.arguments = [
            "-Z", String(Int(maxPixelSize)),
            "-s", "format", "jpeg",
            "-s", "formatOptions", "80",
            input.path,
            "--out", output.path
        ]

        return try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    try? FileManager.default.removeItem(at: output)
                    return nil
                }

                let data = try? Data(contentsOf: output)
                try? FileManager.default.removeItem(at: output)
                return data.flatMap { $0.isEmpty ? nil : $0 }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC)
                if process.isRunning {
                    process.terminate()
                }
                throw ServiceError.timeout
            }

            guard let result = try await group.next() else { return nil }
            group.cancelAll()
            return result
        }
    }
}

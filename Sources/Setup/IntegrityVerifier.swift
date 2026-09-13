import CryptoKit
import Foundation

enum IntegrityVerifier {

    /// Streaming SHA-256 of a file without loading it into memory — required
    /// for multi-gigabyte payloads. `progress` is called on a background
    /// thread with values in 0...1.
    static func sha256Hex(
        of url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            let total = Self.fileSize(url)
            var hasher = SHA256()
            var consumed: Int64 = 0

            while true {
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                consumed += Int64(chunk.count)
                if total > 0 {
                    progress(Double(consumed) / Double(total))
                }
            }

            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }
}
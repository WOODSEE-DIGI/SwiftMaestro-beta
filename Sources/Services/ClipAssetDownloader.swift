import Foundation

// MARK: - Clip Asset Downloader
//
// Wayback-Machine-style asset capture for the Web Clipper. Downloads the
// images a clipped page references so the note survives the source page
// changing or disappearing — markdown links are rewritten to the local
// assets folder.
//
// Safety: per-file and total size caps, image-count cap, per-file timeout,
// and only http(s) URLs are fetched (data:/blob: skipped).

final class ClipAssetDownloader: Sendable {

    struct Options: Sendable {
        var maxImages = 25
        var maxFileBytes = 15 * 1024 * 1024      // 15 MB per image
        var maxTotalBytes = 150 * 1024 * 1024    // 150 MB per clip
        var perFileTimeout: TimeInterval = 20
        var totalTimeout: TimeInterval = 60
    }

    struct Result: Sendable {
        /// remote URL string -> local relative path (e.g. "assets/<slug>/001.jpg")
        let urlToLocalPath: [String: String]
        let downloadedBytes: Int
        let downloadedCount: Int
        let skippedCount: Int
    }

    enum AssetError: Error {
        case timeout, tooLarge, downloadFailed
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad  // the browser just loaded these — hit the shared cache first
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    /// Extract image URLs from cleaned content HTML (<img src/srcset>) plus
    /// the page's og:image. Returns absolute URLs, deduped, document order.
    static func imageURLs(contentHTML: String, pageURL: String, ogImage: String) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []

        func add(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("data:"),
                  !trimmed.hasPrefix("blob:"),
                  let url = URL(string: trimmed, relativeTo: URL(string: pageURL))?.absoluteURL,
                  url.scheme == "http" || url.scheme == "https",
                  seen.insert(url.absoluteString).inserted
            else { return }
            urls.append(url)
        }

        if !ogImage.isEmpty { add(ogImage) }

        // <img src="..."> and srcset first candidate
        let patterns = [
            #"<img[^>]+src\s*=\s*["']([^"']+)["']"#,
            #"<img[^>]+data-src\s*=\s*["']([^"']+)["']"#,   // lazy-load
            #"<source[^>]+srcset\s*=\s*["']([^"',\s]+)"#,   // first srcset candidate
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(contentHTML.startIndex..., in: contentHTML)
            for match in regex.matches(in: contentHTML, range: range) {
                add((contentHTML as NSString).substring(with: match.range(at: 1)))
            }
        }
        return urls
    }

    /// Download images into `assetsDir`. Returns the URL→local-path mapping.
    /// Best-effort: individual failures are skipped, never thrown.
    func download(_ urls: [URL], into assetsDir: URL, relativePrefix: String,
                  options: Options = Options()) async -> Result {
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        var mapping: [String: String] = [:]
        var totalBytes = 0
        var downloaded = 0
        var skipped = 0
        let deadline = Date().addingTimeInterval(options.totalTimeout)

        for (index, url) in urls.enumerated() {
            if index >= options.maxImages { skipped += 1; continue }
            if Date() > deadline { skipped += 1; continue }
            do {
                let (data, response) = try await session.data(from: url)
                let bytes = data.count
                if bytes > options.maxFileBytes || totalBytes + bytes > options.maxTotalBytes {
                    skipped += 1
                    continue
                }
                let ext = Self.fileExtension(for: url, mimeType: (response as? HTTPURLResponse)?.mimeType)
                let fileName = String(format: "%03d.%@", index + 1, ext)
                try data.write(to: assetsDir.appendingPathComponent(fileName), options: .atomic)
                mapping[url.absoluteString] = "\(relativePrefix)/\(fileName)"
                totalBytes += bytes
                downloaded += 1
            } catch {
                skipped += 1
            }
        }
        return Result(urlToLocalPath: mapping, downloadedBytes: totalBytes,
                      downloadedCount: downloaded, skippedCount: skipped)
    }

    private static func fileExtension(for url: URL, mimeType: String?) -> String {
        if let mimeType {
            switch mimeType {
            case "image/jpeg": return "jpg"
            case "image/png": return "png"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            case "image/svg+xml": return "svg"
            case "image/avif": return "avif"
            case "image/heic": return "heic"
            default: break
            }
        }
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "svg", "avif", "heic"].contains(ext) ? ext : "jpg"
    }
}

// MARK: - Markdown link rewriting

extension String {
    /// Rewrite image links in markdown/HTML content to local asset paths.
    /// Matches each remote URL in ALL its encodings: raw, HTML-escaped
    /// (`&amp;`), and URL-encoded — the HTML source, the Defuddle-cleaned
    /// content, and the Turndown markdown each encode differently, and an
    /// exact-match rewrite silently misses (markdown kept remote URLs).
    func rewritingImageURLs(_ mapping: [String: String]) -> String {
        guard !mapping.isEmpty else { return self }
        var result = self
        for (remote, local) in mapping {
            var variants: Set<String> = [remote]
            if remote.contains("&amp;") {
                variants.insert(remote.replacingOccurrences(of: "&amp;", with: "&"))
            }
            if remote.contains("&") {
                variants.insert(remote.replacingOccurrences(of: "&", with: "&amp;"))
            }
            if let decoded = remote.removingPercentEncoding, decoded != remote {
                variants.insert(decoded)
            }
            for variant in variants {
                result = result.replacingOccurrences(of: variant, with: local)
            }
        }
        return result
    }
}

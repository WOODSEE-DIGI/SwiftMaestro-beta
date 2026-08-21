import Foundation

// MARK: - Reader HTML Export
//
// Builds a single self-contained HTML file from a clip: the Defuddle-cleaned
// article HTML wrapped in a clean reader template, with downloaded images
// inlined as base64 data URIs. One file = the page as it read, portable
// anywhere, zero external references — the Wayback-style artifact.

enum ClipReaderExport {

    /// Build the reader HTML. `imageMapping` is remote URL -> local file name
    /// within the assets dir; `assetsDir` is where the downloaded files live.
    static func render(
        clip: WebClipResult,
        imageMapping: [String: String],   // remote URL -> "assets/<slug>/NNN.ext"
        assetsDir: URL
    ) -> String {
        // Inline downloaded images as data URIs so the file is fully portable.
        var inlinedContent = clip.html
        for (remote, localPath) in imageMapping {
            let fileName = (localPath as NSString).lastPathComponent
            let fileURL = assetsDir.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            let mime = mimeType(for: fileName)
            let dataURI = "data:\(mime);base64,\(data.base64EncodedString())"
            // Replace all encodings of the remote URL (see rewritingImageURLs).
            var variants: Set<String> = [remote]
            if remote.contains("&amp;") { variants.insert(remote.replacingOccurrences(of: "&amp;", with: "&")) }
            if remote.contains("&") { variants.insert(remote.replacingOccurrences(of: "&", with: "&amp;")) }
            if let decoded = remote.removingPercentEncoding, decoded != remote { variants.insert(decoded) }
            for variant in variants {
                inlinedContent = inlinedContent.replacingOccurrences(of: variant, with: dataURI)
            }
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="SwiftMaestro Web Clipper">
        <meta name="clip-source" content="\((clip.url).xmlEscaped)">
        <meta name="clip-captured" content="\(ISO8601DateFormatter().string(from: Date()))">
        <title>\(clip.title.xmlEscaped)</title>
        <style>
        :root { color-scheme: light dark; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", Georgia, serif;
          max-width: 42rem; margin: 0 auto; padding: 2.5rem 1.25rem 4rem;
          line-height: 1.65; font-size: 1.05rem;
        }
        header.clip-header { border-bottom: 1px solid rgba(128,128,128,.3); margin-bottom: 2rem; padding-bottom: 1rem; }
        header.clip-header .clip-meta { font-size: .85rem; opacity: .65; font-family: -apple-system, sans-serif; }
        header.clip-header .clip-meta a { color: inherit; }
        h1 { line-height: 1.25; }
        img, video { max-width: 100%; height: auto; border-radius: 6px; }
        figure { margin: 1.5rem 0; }
        figcaption { font-size: .85rem; opacity: .65; margin-top: .5rem; }
        blockquote { border-left: 3px solid rgba(128,128,128,.4); margin-left: 0; padding-left: 1rem; opacity: .85; }
        pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        pre { overflow-x: auto; padding: 1rem; background: rgba(128,128,128,.12); border-radius: 8px; }
        a { color: #0a84ff; }
        </style>
        </head>
        <body>
        <header class="clip-header">
          <h1>\(clip.title.xmlEscaped)</h1>
          <div class="clip-meta">
            \(clip.author.isEmpty ? "" : "By \(clip.author.xmlEscaped) · ")
            \(clip.site.isEmpty ? clip.domain : clip.site) ·
            <a href="\(clip.url.xmlEscaped)">\(clip.url.xmlEscaped)</a>
          </div>
        </header>
        \(inlinedContent)
        </body>
        </html>
        """
    }

    private static func mimeType(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "avif": return "image/avif"
        case "heic": return "image/heic"
        default: return "image/jpeg"
        }
    }
}

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

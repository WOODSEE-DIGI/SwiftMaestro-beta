import Foundation

/// Discovers publishable drafts inside MaestroDAM by searching asset captions,
/// OCR text, keywords, and filenames for monitored Publish tags.
enum PublishDAMSource {

    static func scan(monitoredTags: Set<String>) async -> [PublishDraft] {
        guard !monitoredTags.isEmpty else { return [] }

        let database = DAMDatabase.shared
        let tags = Array(monitoredTags)

        do {
            return try await Task.detached(priority: .userInitiated) {
                var assetIDs = Set<Int64>()
                for tag in tags {
                    let ids = try database.searchAssetIDs(matching: tag, folder: nil, limit: 1000)
                    assetIDs.formUnion(ids)
                }

                let assets = try database.fetchAssets(ids: Array(assetIDs))
                return assets.map { asset in
                    let summary = asset.aiCaption ?? asset.ocrText ?? asset.aiKeywords ?? asset.userKeywords ?? ""
                    let matchedTags = tags.filter { tag in
                        [asset.filename, asset.aiCaption, asset.ocrText, asset.aiKeywords, asset.userKeywords, asset.xattrKeywords]
                            .compactMap { $0 }
                            .contains { $0.lowercased().contains(tag) }
                    }

                    return PublishDraft(
                        sourceKind: .dam,
                        sourcePath: asset.path,
                        title: asset.filename,
                        summary: String(summary.prefix(240)),
                        bodyMarkdown: "",
                        bodyHTML: Self.html(for: asset),
                        tags: matchedTags,
                        assetPaths: [asset.path]
                    )
                }
            }.value
        } catch {
            NSLog("[PUBLISH] MaestroDAM scan failed: \(error)")
            return []
        }
    }

    // MARK: - Helpers

    private static func html(for asset: DAMAsset) -> String {
        var parts: [String] = []
        let imageURL = URL(fileURLWithPath: asset.path).absoluteString
        parts.append("""
            <figure>
              <img src="\(imageURL)" alt="\(asset.filename.htmlEscaped)" style="max-width:100%;height:auto;" />
              <figcaption>\(asset.filename.htmlEscaped)</figcaption>
            </figure>
            """)
        if let caption = asset.aiCaption, !caption.isEmpty {
            parts.append("<p><strong>Caption:</strong> \(caption.htmlEscaped)</p>")
        }
        if let keywords = asset.aiKeywords, !keywords.isEmpty {
            parts.append("<p><strong>Keywords:</strong> \(keywords.htmlEscaped)</p>")
        }
        if let keywords = asset.userKeywords, !keywords.isEmpty {
            parts.append("<p><strong>User Keywords:</strong> \(keywords.htmlEscaped)</p>")
        }
        if let keywords = asset.xattrKeywords, !keywords.isEmpty {
            parts.append("<p><strong>Finder Tags:</strong> \(keywords.htmlEscaped)</p>")
        }
        if let ocr = asset.ocrText, !ocr.isEmpty {
            parts.append("<p><strong>OCR:</strong> \(ocr.htmlEscaped)</p>")
        }
        return parts.joined(separator: "\n")
    }
}

private extension String {
    var htmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - MaestroDAM tools (digital asset management catalog)
//
// Agent-first access to the same DAMDatabase the MaestroDAM browser panel uses.
// Assets are identified by file path. Search uses FTS5 across filename, caption,
// keywords, and OCR text. Ratings are 0-5. Keywords support add/replace modes.
// Database operations go through DAMDatabase directly (no view-model dependency).

extension MaestroTools {

    static func registerDAMTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "dam_search", spec: damToolSpecs[0],
                category: ToolCategory.dam.rawValue,
                handler: { call in await damSearch(call) }),
            ToolDefinition(
                name: "dam_import", spec: damToolSpecs[1],
                category: ToolCategory.dam.rawValue,
                handler: { call in await damImport(call) }),
            ToolDefinition(
                name: "dam_list_folders", spec: damToolSpecs[2],
                category: ToolCategory.dam.rawValue,
                handler: { _ in await damListFolders() }),
            ToolDefinition(
                name: "dam_list_assets", spec: damToolSpecs[3],
                category: ToolCategory.dam.rawValue,
                handler: { call in await damListAssets(call) }),
            ToolDefinition(
                name: "dam_asset_info", spec: damToolSpecs[4],
                category: ToolCategory.dam.rawValue,
                handler: { call in await damAssetInfo(call) }),
            ToolDefinition(
                name: "dam_set_rating", spec: damToolSpecs[5],
                category: ToolCategory.dam.rawValue,
                handler: { call in await damSetRating(call) }),
            ToolDefinition(
                name: "dam_set_keywords", spec: damToolSpecs[6],
                category: ToolCategory.dam.rawValue,
                handler: { call in await damSetKeywords(call) }),
            ToolDefinition(
                name: "dam_filter_view", spec: damToolSpecs[7],
                category: ToolCategory.dam.rawValue,
                handler: { call in await damFilterView(call) }),
        ])
    }

    // MARK: - Tool Specs

    static var damToolSpecs: [ToolSpec] {
        [
            rawSpec("dam_search",
                "Full-text search across the MaestroDAM asset catalog (filename, "
                + "AI caption, user keywords, OCR text). Returns matching assets "
                + "with path, filename, rating, and keywords. Use this to find "
                + "assets before acting on them.",
                properties: [
                    "query": ["type": "string", "description": "Search text (FTS5 match)."],
                    "folder": ["type": "string", "description": "Restrict to this folder path."],
                    "limit": ["type": "integer", "description": "Max results (default 20, max 100)."],
                ],
                required: ["query"]),
            rawSpec("dam_import",
                "Import a folder into the MaestroDAM catalog. Recursively scans "
                + "for images, RAW files, videos, audio, and PDFs. Skips already-"
                + "cataloged files (delta import). Returns the count of new assets.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the folder to import."],
                ],
                required: ["path"]),
            rawSpec("dam_list_folders",
                "List all folders in the MaestroDAM catalog with their asset counts. "
                + "Use this to discover what folders have been imported.",
                properties: [:], required: []),
            rawSpec("dam_list_assets",
                "List assets in the catalog with optional folder, rating, and sort "
                + "filters. Returns path, filename, rating, keywords, and size.",
                properties: [
                    "folder": ["type": "string", "description": "Restrict to this folder path."],
                    "min_rating": ["type": "integer", "description": "Minimum rating 0-5."],
                    "sort": ["type": "string", "description": "Sort order: capture_date, filename, size, rating (default: capture_date)."],
                    "limit": ["type": "integer", "description": "Max results (default 30, max 200)."],
                    "offset": ["type": "integer", "description": "Skip this many results first."],
                ],
                required: []),
            rawSpec("dam_asset_info",
                "Get full metadata for a specific asset by file path. Returns "
                + "dimensions, camera info, EXIF, GPS, rating, keywords, OCR text, "
                + "and AI caption.",
                properties: [
                    "path": ["type": "string", "description": "Absolute file path of the asset."],
                ],
                required: ["path"]),
            rawSpec("dam_set_rating",
                "Set the star rating (0-5) on one or more assets. Pass asset paths "
                + "as a JSON array. Rating is audited in the DAM audit trail.",
                properties: [
                    "rating": ["type": "integer", "description": "Rating 0-5."],
                    "paths": ["type": "string", "description": "JSON array of absolute file paths."],
                ],
                required: ["rating", "paths"]),
            rawSpec("dam_set_keywords",
                "Add or replace user keywords on one or more assets. Pass asset "
                + "paths as a JSON array. Keywords are audited in the DAM audit trail.",
                properties: [
                    "keywords": ["type": "string", "description": "Comma-separated keywords."],
                    "paths": ["type": "string", "description": "JSON array of absolute file paths."],
                    "mode": ["type": "string", "description": "'add' (default) appends to existing; 'replace' overwrites."],
                ],
                required: ["keywords", "paths"]),
            rawSpec("dam_filter_view",
                "Set search and filter state on the DAM browser panel. Updates "
                + "the visible grid in real time so the user sees the filtered "
                + "results immediately. All parameters are optional — only supplied "
                + "filters are applied. Pass 'clear: true' to reset all filters.",
                properties: [
                    "search": ["type": "string", "description": "Full-text search query (FTS5 match against filename, caption, keywords, OCR)."],
                    "tag_color": ["type": "integer", "description": "Filter by Finder tag color: 2=green, 3=purple, 4=blue, 5=yellow, 6=red, 7=orange. Omit for all."],
                    "file_type": ["type": "string", "description": "Filter by file type category: 'image', 'raw', 'video', 'audio', 'pdf'. Omit for all."],
                    "flag": ["type": "string", "description": "Filter by flag: 'picked' or 'rejected'. Omit for all."],
                    "min_rating": ["type": "integer", "description": "Minimum star rating 0-5."],
                    "sort": ["type": "string", "description": "Sort order: 'capture_date', 'filename', 'size', 'rating'."],
                    "folder": ["type": "string", "description": "Restrict to this folder path (nil clears folder scope)."],
                    "clear": ["type": "boolean", "description": "If true, reset all filters and show full catalog."],
                ],
                required: []),
        ]
    }

    // MARK: - Args

    private struct SearchArgs: Codable { let query, folder: String?; let limit: Int? }
    private struct ImportArgs: Codable { let path: String? }
    private struct ListAssetsArgs: Codable {
        let folder: String?
        let min_rating: Int?
        let sort: String?
        let limit, offset: Int?
    }
    private struct AssetInfoArgs: Codable { let path: String? }
    private struct SetRatingArgs: Codable { let rating: Int?; let paths: String? }
    private struct SetKeywordsArgs: Codable { let keywords, paths, mode: String? }
    private struct FilterViewArgs: Codable {
        let search: String?
        let tag_color: Int?
        let file_type: String?
        let flag: String?
        let min_rating: Int?
        let sort: String?
        let folder: String?
        let clear: Bool?
    }

    // MARK: - Helpers

    /// Format user keywords from comma-separated string.
    private static func formatKeywords(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return raw
    }

    /// Format Finder tags from comma-separated string.
    private static func formatXattrKeywords(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return raw
    }

    /// Format asset for short listing.
    private static func assetLine(_ asset: DAMAsset) -> String {
        let kw = formatKeywords(asset.userKeywords)
        let kwStr = kw.isEmpty ? "" : " [\(kw)]"
        let rating = asset.rating > 0 ? " \(String(repeating: "★", count: asset.rating))" : ""
        return "- `\(asset.filename)` — \(asset.formattedSize)"
            + " — \(asset.folder ?? "—")\(rating)\(kwStr)\n  Path: \(asset.path)"
    }

    // MARK: - Handlers

    private static func damSearch(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SearchArgs.self),
              let query = args.query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return "Error: query is required."
        }
        let folder = args.folder
        let limit = args.limit ?? 20

        do {
            let ids = try DAMDatabase.shared.searchAssetIDs(
                matching: query, folder: folder, limit: min(limit, 100))
            guard !ids.isEmpty else { return "No assets matched '\(query)'." }

            let assets = try DAMDatabase.shared.fetchAssets(ids: Array(ids.prefix(limit)))
            var result = "Found \(ids.count) assets"
            if let folder { result += " in \(folder)" }
            result += ":\n\n"

            for asset in assets {
                result += assetLine(asset) + "\n"
            }
            return result
        } catch {
            return "Error searching DAM: \(error.localizedDescription)"
        }
    }

    private static func damImport(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ImportArgs.self),
              let path = args.path?.trimmingCharacters(in: .whitespaces), !path.isEmpty else {
            return "Error: path is required."
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return "Error: folder not found at \(path)"
        }

        do {
            _ = try DAMDatabase.shared.assetCount(folder: nil)
            let written = try await DAMImportService.shared.importFolder(at: url, database: .shared)
            let countAfter = try DAMDatabase.shared.assetCount(folder: nil)
            return "Import complete. \(written) rows written. Total catalog: \(countAfter) assets."
        } catch {
            return "Error importing folder: \(error.localizedDescription)"
        }
    }

    private static func damListFolders() async -> String {
        do {
            let folders = try DAMDatabase.shared.folderCounts()
            guard !folders.isEmpty else {
                return "No folders in the MaestroDAM catalog. Use dam_import to add a folder."
            }
            var result = "MaestroDAM folders:\n\n"
            for (path, count) in folders {
                result += "- \(path) — \(count) assets\n"
            }
            return result
        } catch {
            return "Error listing folders: \(error.localizedDescription)"
        }
    }

    private static func damListAssets(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ListAssetsArgs.self) else {
            return "Error: invalid arguments."
        }
        let folder = args.folder
        let minRating = args.min_rating ?? 0
        let limit = args.limit ?? 30
        let offset = args.offset ?? 0

        let sort: DAMDatabase.DAMSortOrder
        switch args.sort ?? "capture_date" {
        case "filename": sort = .filenameAsc
        case "size": sort = .sizeDesc
        case "rating": sort = .ratingDesc
        default: sort = .captureDateDesc
        }

        do {
            let total = try DAMDatabase.shared.assetCount(folder: folder, minRating: minRating)
            let assets = try DAMDatabase.shared.assets(
                folder: folder, minRating: minRating, sort: sort,
                limit: min(limit, 200), offset: offset)
            guard !assets.isEmpty else { return "No assets found." }

            var result = "Assets (\(assets.count) of \(total)"
            if let folder { result += " in \(folder)" }
            if minRating > 0 { result += ", rating ≥ \(minRating)" }
            result += "):\n\n"

            for asset in assets {
                result += "- `\(asset.filename)` — \(asset.formattedSize)"
                if asset.rating > 0 { result += " \(String(repeating: "★", count: asset.rating))" }
                let kw = formatKeywords(asset.userKeywords)
                if !kw.isEmpty { result += " [\(kw)]" }
                result += "\n"
            }
            return result
        } catch {
            return "Error listing assets: \(error.localizedDescription)"
        }
    }

    private static func damAssetInfo(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: AssetInfoArgs.self),
              let path = args.path?.trimmingCharacters(in: .whitespaces), !path.isEmpty else {
            return "Error: path is required."
        }
        do {
            guard let asset = try DAMDatabase.shared.asset(withPath: path) else {
                return "Asset not found in MaestroDAM catalog: \(path)"
            }

            var result = "**\(asset.filename)**\n\n"
            result += "- Path: \(asset.path)\n"
            result += "- Folder: \(asset.folder ?? "—")\n"
            result += "- Size: \(asset.formattedSize)\n"
            if let uti = asset.uti { result += "- Type: \(uti)\n" }
            if let w = asset.width, let h = asset.height {
                result += "- Dimensions: \(w) × \(h)\n"
            }
            if let d = asset.duration { result += "- Duration: \(String(format: "%.1f", d))s\n" }
            result += "- Rating: \(asset.rating)/5\n"
            if asset.colorLabel != .none { result += "- Color: \(asset.colorLabel.rawValue)\n" }
            if let cam = asset.cameraMake { result += "- Camera: \(cam)\n" }
            if let model = asset.cameraModel { result += "- Model: \(model)\n" }
            if let lens = asset.lensModel { result += "- Lens: \(lens)\n" }
            if let iso = asset.iso { result += "- ISO: \(iso)\n" }
            if let ap = asset.aperture { result += "- Aperture: f/\(ap)\n" }
            if let ss = asset.shutterSpeed { result += "- Shutter: \(ss)\n" }
            if let fl = asset.focalLength { result += "- Focal: \(fl)mm\n" }
            if let lat = asset.gpsLat, let lon = asset.gpsLon {
                result += "- GPS: \(lat), \(lon)\n"
            }
            if let date = asset.captureDate { result += "- Captured: \(date.formatted())\n" }
            let kw = formatKeywords(asset.userKeywords)
            if !kw.isEmpty { result += "- Keywords: \(kw)\n" }
            let xkw = formatXattrKeywords(asset.xattrKeywords)
            if !xkw.isEmpty { result += "- Finder tags: \(xkw)\n" }
            if let caption = asset.aiCaption, !caption.isEmpty {
                result += "- AI caption: \(caption)\n"
            }
            if let ocr = asset.ocrText, !ocr.isEmpty {
                let preview = ocr.count > 200 ? String(ocr.prefix(200)) + "…" : ocr
                result += "- OCR text: \(preview)\n"
            }
            if let date = asset.indexedAt { result += "- Indexed: \(date.formatted())\n" }
            return result
        } catch {
            return "Error fetching asset info: \(error.localizedDescription)"
        }
    }

    private static func damSetRating(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SetRatingArgs.self),
              let rating = args.rating, (0...5).contains(rating) else {
            return "Error: rating must be 0-5."
        }
        guard let pathsJSON = args.paths,
              let paths = try? JSONDecoder().decode([String].self, from: Data(pathsJSON.utf8)),
              !paths.isEmpty else {
            return "Error: paths must be a JSON array of file paths."
        }

        var updated = 0
        let database = DAMDatabase.shared
        for path in paths {
            guard let asset = try? database.asset(withPath: path),
                  let assetID = asset.id else { continue }
            let oldRating = asset.rating
            guard oldRating != rating else { continue }
            try? await database.dbQueue.write { db in
                guard var row = try? DAMAsset.fetchOne(db, key: assetID) else { return }
                row.rating = rating
                try? row.update(db)
                try? database.recordAudit(
                    db, assetId: assetID, field: "rating",
                    oldValue: "\(oldRating)", newValue: "\(rating)",
                    source: "agent")
            }
            updated += 1
        }
        return "Set rating \(rating)/5 on \(updated) asset(s)."
    }

    private static func damSetKeywords(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SetKeywordsArgs.self),
              let keywords = args.keywords?.trimmingCharacters(in: .whitespaces),
              !keywords.isEmpty else {
            return "Error: keywords is required."
        }
        guard let pathsJSON = args.paths,
              let paths = try? JSONDecoder().decode([String].self, from: Data(pathsJSON.utf8)),
              !paths.isEmpty else {
            return "Error: paths must be a JSON array of file paths."
        }

        let isReplace = args.mode == "replace"
        let parsed = keywords.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let database = DAMDatabase.shared
        var updated = 0
        for path in paths {
            guard let asset = try? database.asset(withPath: path),
                  let assetID = asset.id else { continue }
            let oldKeywords = asset.userKeywords ?? ""
            let newKeywords: String
            if isReplace {
                newKeywords = parsed.joined(separator: ", ")
            } else {
                let existing = oldKeywords.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let merged = Set(existing + parsed)
                newKeywords = merged.joined(separator: ", ")
            }
            guard newKeywords != oldKeywords else { continue }
            try? await database.dbQueue.write { db in
                guard var row = try? DAMAsset.fetchOne(db, key: assetID) else { return }
                row.userKeywords = newKeywords
                try? row.update(db)
                try? database.recordAudit(
                    db, assetId: assetID, field: "userKeywords",
                    oldValue: oldKeywords, newValue: newKeywords,
                    source: "agent")
            }
            updated += 1
        }
        return "\(isReplace ? "Replaced" : "Added") keywords on \(updated) asset(s): \(keywords)"
    }

    // MARK: - dam_filter_view

    private static func damFilterView(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: FilterViewArgs.self) else {
            return "Error: invalid arguments."
        }

        // Build a userInfo dict of only the filters the agent supplied.
        var info: [String: Any] = [:]
        if args.clear == true {
            info["clear"] = true
        } else {
            if let search = args.search { info["search"] = search }
            if let tagColor = args.tag_color { info["tag_color"] = tagColor }
            if let fileType = args.file_type { info["file_type"] = fileType }
        if let flagStr = args.flag {
            // Map user-friendly names to enum raw values.
            switch flagStr.lowercased() {
            case "picked", "pick": info["flag"] = "pick"
            case "rejected", "reject": info["flag"] = "reject"
            default: info["flag"] = flagStr  // pass through, DAMViewModel will handle nil if invalid
            }
        }
        if let minRating = args.min_rating { info["min_rating"] = minRating }
        if let sort = args.sort {
            // Map user-friendly names to enum raw values.
            switch sort.lowercased() {
            case "capture_date", "date": info["sort"] = "captureDateDesc"
            case "date_asc", "oldest": info["sort"] = "captureDateAsc"
            case "filename", "name": info["sort"] = "filenameAsc"
            case "size", "largest": info["sort"] = "sizeDesc"
            case "rating", "stars": info["sort"] = "ratingDesc"
            default: info["sort"] = sort
            }
        }
            if let folder = args.folder { info["folder"] = folder }
        }

        guard !info.isEmpty else {
            return "Error: provide at least one filter parameter, or set clear=true to reset."
        }

        await MainActor.run {
            NotificationCenter.default.post(
                name: .damApplyFilters, object: nil, userInfo: info)
        }

        var applied: [String] = []
        if args.clear == true { applied.append("cleared all filters") }
        if let s = args.search { applied.append("search=\"\(s)\"") }
        if let t = args.tag_color { applied.append("tag_color=\(t)") }
        if let ft = args.file_type { applied.append("file_type=\(ft)") }
        if let f = args.flag { applied.append("flag=\(f)") }
        if let r = args.min_rating { applied.append("min_rating=\(r)") }
        if let s = args.sort { applied.append("sort=\(s)") }
        if let fo = args.folder { applied.append("folder=\(fo)") }
        return "DAM panel filters updated: \(applied.joined(separator: ", "))"
    }
}

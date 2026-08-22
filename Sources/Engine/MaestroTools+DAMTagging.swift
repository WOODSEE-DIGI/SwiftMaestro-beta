import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - MaestroDAM AI tagging tools (learn-as-you-tag)
//
// Agent access to the OCR tagging engine: index the catalog (OCR + visual
// fingerprints), apply tags that teach the engine, review/resolve the
// suggestion queue, and search by visual/textual similarity. Registered from
// `registerDAMTools()` — same ToolRegistry pattern as the other DAM tools.

extension MaestroTools {

    static func registerDAMTaggingTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "dam_ai_index", spec: damTaggingToolSpecs[0],
                category: ToolCategory.dam.rawValue,
                handler: { _ in await damAIIndex() }),
            ToolDefinition(
                name: "dam_tag_apply", spec: damTaggingToolSpecs[1],
                category: ToolCategory.dam.rawValue,
                handler: { call in await damTagApply(call) }),
            ToolDefinition(
                name: "dam_tag_suggestions", spec: damTaggingToolSpecs[2],
                category: ToolCategory.dam.rawValue,
                handler: { call in await damTagSuggestions(call) }),
            ToolDefinition(
                name: "dam_tag_resolve", spec: damTaggingToolSpecs[3],
                category: ToolCategory.dam.rawValue,
                handler: { call in await damTagResolve(call) }),
            ToolDefinition(
                name: "dam_find_similar", spec: damTaggingToolSpecs[4],
                category: ToolCategory.dam.rawValue,
                handler: { call in await damFindSimilar(call) }),
            ToolDefinition(
                name: "dam_relearn", spec: damTaggingToolSpecs[5],
                category: ToolCategory.dam.rawValue,
                handler: { _ in await damRelearn() }),
        ])
    }

    // MARK: - Tool Specs

    static var damTaggingToolSpecs: [ToolSpec] {
        [
            rawSpec("dam_ai_index",
                "Run the AI indexing pass over the MaestroDAM catalog: Apple "
                + "Vision OCR (full text per image, stored searchable) plus a "
                + "visual similarity fingerprint per image. Required once "
                + "before similarity tagging works; incremental afterwards. "
                + "Returns counts of scanned and analyzed assets.",
                properties: [:], required: []),
            rawSpec("dam_tag_apply",
                "Apply one or more tags to assets (by path) AND learn from "
                + "them: every tagged asset becomes an exemplar, and similar "
                + "untagged images get tag suggestions automatically. This is "
                + "the learn-as-you-tag hook — prefer it over dam_set_keywords "
                + "when the user wants tags to propagate.",
                properties: [
                    "tags": ["type": "string", "description": "Comma-separated tag names."],
                    "paths": ["type": "string", "description": "JSON array of absolute file paths."],
                ],
                required: ["tags", "paths"]),
            rawSpec("dam_tag_suggestions",
                "List pending AI tag suggestions (learned from user-tagged "
                + "exemplars) with suggestion id, asset path, tag, confidence "
                + "0-1, and match basis (visual/ocr/both). Review these with "
                + "dam_tag_resolve.",
                properties: [
                    "min_confidence": ["type": "number", "description": "Minimum confidence 0-1 (default 0.62)."],
                    "limit": ["type": "integer", "description": "Max results (default 30, max 200)."],
                ],
                required: []),
            rawSpec("dam_tag_resolve",
                "Accept or reject one AI tag suggestion by id. Accepting "
                + "applies the tag (audited) and learns from the newly tagged "
                + "asset; rejecting permanently suppresses that tag for that "
                + "asset.",
                properties: [
                    "suggestion_id": ["type": "integer", "description": "Suggestion id from dam_tag_suggestions."],
                    "action": ["type": "string", "description": "'accept' or 'reject'."],
                ],
                required: ["suggestion_id", "action"]),
            rawSpec("dam_find_similar",
                "Find catalog assets visually/textually similar to the asset "
                + "at a path. Returns ranked matches with confidence and "
                + "basis. Useful before batch-tagging a family of images.",
                properties: [
                    "path": ["type": "string", "description": "Absolute file path of the reference asset."],
                    "limit": ["type": "integer", "description": "Max results (default 20, max 100)."],
                    "min_confidence": ["type": "number", "description": "Minimum confidence 0-1 (default 0.5)."],
                ],
                required: ["path"]),
            rawSpec("dam_relearn",
                "Propagate ALL existing tags (manual + Lightroom-imported "
                + "keywords) to similar untagged images across the catalog. "
                + "Run after dam_ai_index and after big metadata imports. "
                + "Background-scale operation: cost grows with tagged × "
                + "untagged counts. Returns the number of new suggestions.",
                properties: [:], required: []),
        ]
    }

    // MARK: - Args

    private struct TagApplyArgs: Codable { let tags, paths: String? }
    private struct SuggestionsArgs: Codable { let min_confidence: Double?; let limit: Int? }
    private struct ResolveArgs: Codable { let suggestion_id: Int?; let action: String? }
    private struct FindSimilarArgs: Codable {
        let path: String?; let limit: Int?; let min_confidence: Double?
    }

    // MARK: - Handlers

    private static func damAIIndex() async -> String {
        do {
            let result = try await DAMTaggingService.shared.indexFeatures()
            return "AI indexing complete: \(result.updated) assets analyzed "
                + "(\(result.scanned) scanned). OCR text is searchable and "
                + "similarity tagging is ready."
        } catch is CancellationError {
            return "AI indexing cancelled — safe to re-run; it resumes from the backlog."
        } catch {
            return "Error indexing catalog: \(error.localizedDescription)"
        }
    }

    private static func damTagApply(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: TagApplyArgs.self),
              let tagsRaw = args.tags?.trimmingCharacters(in: .whitespaces),
              !tagsRaw.isEmpty else {
            return "Error: tags is required."
        }
        guard let pathsJSON = args.paths,
              let paths = try? JSONDecoder().decode([String].self, from: Data(pathsJSON.utf8)),
              !paths.isEmpty else {
            return "Error: paths must be a JSON array of file paths."
        }
        let names = tagsRaw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return "Error: no usable tag names." }

        let database = DAMDatabase.shared
        var tagged = 0
        var suggestions = 0
        var missing: [String] = []
        for path in paths {
            guard let asset = try? database.asset(withPath: path),
                  let assetId = asset.id else {
                missing.append(path)
                continue
            }
            do {
                suggestions += try await DAMTaggingService.shared
                    .applyTagAndLearn(assetId: assetId, names: names)
                tagged += 1
            } catch {
                return "Error tagging \(path): \(error.localizedDescription)"
            }
        }
        var result = "Tagged \(tagged) asset(s) with [\(names.joined(separator: ", "))]. "
            + "\(suggestions) new suggestions generated for similar images."
        if !missing.isEmpty {
            result += "\nNot in catalog (\(missing.count)): \(missing.prefix(5).joined(separator: ", "))"
        }
        return result
    }

    private static func damTagSuggestions(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SuggestionsArgs.self) else {
            return "Error: invalid arguments."
        }
        let minConfidence = args.min_confidence ?? 0.62
        let limit = min(args.limit ?? 30, 200)
        do {
            let page = try DAMDatabase.shared.pendingSuggestions(
                minConfidence: minConfidence, limit: limit)
            if page.isEmpty {
                return "No pending suggestions at ≥ \(Int(minConfidence * 100))% confidence."
            }
            var result = "Pending suggestions (\(page.count)):\n\n"
            for (suggestion, asset) in page {
                let id = suggestion.id ?? -1
                result += "- #\(id) `\(asset.filename)` ← \"\(suggestion.tagName)\" "
                    + "(\(Int(suggestion.confidence * 100))%, \(suggestion.basis.rawValue))\n"
                    + "  Path: \(asset.path)\n"
            }
            return result
        } catch {
            return "Error listing suggestions: \(error.localizedDescription)"
        }
    }

    private static func damTagResolve(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ResolveArgs.self),
              let suggestionId = args.suggestion_id,
              let action = args.action?.lowercased() else {
            return "Error: suggestion_id and action are required."
        }
        do {
            switch action {
            case "accept":
                try await DAMTaggingService.shared.acceptSuggestion(id: Int64(suggestionId))
                return "Suggestion #\(suggestionId) accepted — tag applied and "
                    + "the engine learned from it."
            case "reject":
                try await DAMTaggingService.shared.rejectSuggestion(id: Int64(suggestionId))
                return "Suggestion #\(suggestionId) rejected — it won't be offered again."
            default:
                return "Error: action must be 'accept' or 'reject'."
            }
        } catch {
            return "Error resolving suggestion: \(error.localizedDescription)"
        }
    }

    private static func damRelearn() async -> String {
        do {
            let created = try await DAMTaggingService.shared.propagateFromAllExemplars()
            return "Relearn complete: \(created) new tag suggestions propagated "
                + "from all tagged assets. Review with dam_tag_suggestions."
        } catch is CancellationError {
            return "Relearn cancelled."
        } catch {
            return "Error during relearn: \(error.localizedDescription)"
        }
    }

    private static func damFindSimilar(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: FindSimilarArgs.self),
              let path = args.path?.trimmingCharacters(in: .whitespaces),
              !path.isEmpty else {
            return "Error: path is required."
        }
        let limit = min(args.limit ?? 20, 100)
        let minConfidence = args.min_confidence ?? 0.5
        do {
            let hits = try await DAMTaggingService.shared.findSimilar(
                path: path, limit: limit, minConfidence: minConfidence)
            if hits.isEmpty {
                return "No similar assets found for \(path) "
                    + "(is the catalog indexed? run dam_ai_index)."
            }
            var result = "Assets similar to `\(URL(fileURLWithPath: path).lastPathComponent)`:\n\n"
            for hit in hits {
                result += "- `\(hit.asset.filename)` — \(Int(hit.confidence * 100))% "
                    + "(\(hit.basis.rawValue))\n  Path: \(hit.asset.path)\n"
            }
            return result
        } catch {
            return "Error finding similar assets: \(error.localizedDescription)"
        }
    }
}

import Foundation

/// Bridges MaestroDAM's current selection/state to a dedicated Maestro agent.
///
/// A single project agent ("MaestroDAM / DAM Assistant") is created on first
/// use. It has the `.dam` tool category enabled so it can search, rate,
/// keyword, import, and filter the catalog in response to natural-language
/// requests typed from any MaestroDAM workspace.
@MainActor
enum DAMAgentHelper {
    static let projectName = "MaestroDAM"
    static let agentName = "DAM Assistant"

    /// Returns the dedicated MaestroDAM agent, creating it if necessary.
    static func ensureAgent(in workspace: WorkspaceStore) -> AgentRecord {
        let agent = workspace.createProjectAgent(
            projectName: projectName,
            agentName: agentName,
            category: .data
        )
        // Ensure the DAM tool category is enabled so the agent can run the
        // dam_search / dam_list_assets / dam_set_keywords / dam_filter_view
        // tools even though the generic `.data` category does not include it.
        var categories = workspace.enabledToolCategories(for: agent.id)
        if !categories.contains(.dam) {
            categories.insert(.dam)
            workspace.setEnabledToolCategories(categories, for: agent.id)
        }
        return agent
    }

    /// Build a concise context block describing the current DAM state.
    static func contextPrompt(from viewModel: DAMViewModel) -> String {
        var lines: [String] = []
        lines.append("You are helping inside MaestroDAM (the digital-asset-management catalog).")

        if let folder = viewModel.selectedFolder, !folder.isEmpty {
            lines.append("- Current folder: \(folder)")
        } else if let collectionID = viewModel.selectedCollectionID,
                  let collection = viewModel.collections.first(where: { $0.id == collectionID }) {
            lines.append("- Current album: \(collection.name)")
        } else {
            lines.append("- Scope: entire catalog")
        }

        let selectedAssets = viewModel.assets.filter { viewModel.selection.contains($0.id ?? -1) }
        lines.append("- Selection: \(selectedAssets.count) asset(s)")
        if !selectedAssets.isEmpty {
            let maxSamples = 20
            for asset in selectedAssets.prefix(maxSamples) {
                lines.append("  • \(asset.path)")
            }
            if selectedAssets.count > maxSamples {
                lines.append("  • … and \(selectedAssets.count - maxSamples) more")
            }
        }

        let filters = activeFilterSummary(from: viewModel)
        if !filters.isEmpty {
            lines.append("- Active filters: \(filters.joined(separator: ", "))")
        }

        if !viewModel.searchText.isEmpty {
            lines.append("- Catalog search: \"\(viewModel.searchText)\"")
        }

        lines.append("")
        lines.append("Available DAM actions include: search assets, import folders, list folders, get asset info, set ratings, set keywords, update the DAM panel filters, and read/write macOS extended attributes on files.")
        lines.append("Use the dam_* tools to act on the catalog. Searches do NOT require exact filenames — pass the key concepts from the user's request to dam_search (e.g. 'parenting plan October 2025').")
        lines.append("For metadata directly on the original files, use the file xattr tools: list_xattr, read_xattr, write_xattr, remove_xattr, read_finder_comment, write_finder_comment. Use reverse-DNS names like 'com.woodseedigi.SwiftMaestro.DAM.description' for MaestroDAM metadata.")
        lines.append("Ask before destructive operations (e.g. deleting files, bulk replacing keywords, or removing xattrs).")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func activeFilterSummary(from viewModel: DAMViewModel) -> [String] {
        var parts: [String] = []
        if viewModel.minimumRating > 0 { parts.append("rating ≥ \(viewModel.minimumRating)★") }
        if let color = viewModel.filterTagColor { parts.append("tag color \(color)") }
        if let type = viewModel.filterFileType { parts.append("type: \(type)") }
        if let tagged = viewModel.filterTagged { parts.append(tagged ? "tagged only" : "untagged only") }
        if let flag = viewModel.filterFlag { parts.append("flag: \(flag.rawValue)") }
        if !viewModel.filterExtensions.isEmpty {
            parts.append("extensions: \(viewModel.filterExtensions.sorted().joined(separator: ", "))")
        }
        if viewModel.filterHasAICaption == true { parts.append("has AI caption") }
        if viewModel.filterHasAIKeywords == true { parts.append("has AI keywords") }
        if viewModel.filterHasOCR == true { parts.append("has OCR") }
        if viewModel.filterHasUserKeywords == true { parts.append("has user keywords") }
        if viewModel.filterHasXattr == true { parts.append("has Finder tags") }
        return parts
    }

}

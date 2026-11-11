import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Game Studio tools
//
// Gives Maestro and project agents explicit control over Game Studio:
// open the panel, import a legacy scenes.json from a path, and export the
// current project as a self-contained web build.

extension MaestroTools {

    static func registerStoryGameTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "game_studio_open",
                spec: storyGameToolSpecs[0],
                category: ToolCategory.storyGame.rawValue,
                handler: { call in await storyGameOpen(call) }
            ),
            ToolDefinition(
                name: "game_studio_import",
                spec: storyGameToolSpecs[1],
                category: ToolCategory.storyGame.rawValue,
                handler: { call in await storyGameImport(call) }
            ),
            ToolDefinition(
                name: "game_studio_export_web",
                spec: storyGameToolSpecs[2],
                category: ToolCategory.storyGame.rawValue,
                handler: { call in await storyGameExportWeb(call) }
            ),
        ])
    }

    static var storyGameToolSpecs: [ToolSpec] {
        [
            rawSpec("game_studio_open",
                "Open the Game Studio workspace panel so the user can author or play "
                + "DOS-style text adventures. Equivalent to open_panel('gameStudio').",
                properties: [:],
                required: []),

            rawSpec("game_studio_import",
                "Import a legacy scenes.json into Game Studio. The path can be the "
                + "scenes.json file itself or any parent folder/repo root; Game Studio "
                + "will search up to 5 levels deep for a file named scenes.json.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to scenes.json or the project/repo folder containing it."]
                ],
                required: ["path"]),

            rawSpec("game_studio_export_web",
                "Export the currently loaded Game Studio project to a self-contained "
                + "web build (index.html + game.json + portraits). The output directory "
                + "is created if it does not exist.",
                properties: [
                    "outputDirectory": ["type": "string", "description": "Absolute path to the folder that will receive index.html and game.json."]
                ],
                required: ["outputDirectory"]),
        ]
    }

    // MARK: - Handlers

    private static func storyGameOpen(_ call: ToolCall) async -> String {
        await MainActor.run {
            guard let layout = workspaceLayout else {
                return errorJSON("workspace layout unavailable")
            }
            let result = layout.open(.storyGame, zone: .right)
            let status: String
            switch result {
            case .dockedDirectly, .floated:
                layout.dock(.storyGame)
                status = "opened"
            case .alreadyOpen:
                NotificationCenter.default.post(name: .bringWorkspacePanelToFront, object: WorkspacePanelKind.storyGame)
                status = "already_open"
            }
            return jsonString([
                "status": status,
                "panel": "gameStudio",
                "note": "Game Studio is now visible in the workspace."
            ])
        }
    }

    private static func storyGameImport(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: StoryGameImportArgs.self),
              !args.path.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return errorJSON("game_studio_import requires 'path'")
        }

        let url = URL(fileURLWithPath: args.path)
        do {
            let scenesURL = try resolveScenesJSONURL(from: url)
            return await MainActor.run {
                StoryGameStore.shared.importFromLegacyScenesJSON(at: scenesURL)
                if let project = StoryGameStore.shared.project {
                    return jsonString([
                        "status": "imported",
                        "title": project.metadata.title,
                        "scenes": project.scenes.count,
                        "characters": project.characters.count,
                        "locations": project.locations.count,
                        "stats": project.statDefinitions.count,
                        "source": scenesURL.path
                    ])
                } else if let error = StoryGameStore.shared.errorMessage {
                    return errorJSON(error)
                } else {
                    return errorJSON("import returned no project")
                }
            }
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    private static func storyGameExportWeb(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: StoryGameExportWebArgs.self),
              !args.outputDirectory.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return errorJSON("game_studio_export_web requires 'outputDirectory'")
        }

        let outputURL = URL(fileURLWithPath: args.outputDirectory)
        return await MainActor.run {
            guard let project = StoryGameStore.shared.project else {
                return errorJSON("No Game Studio project is loaded. Import or open a project first.")
            }
            do {
                try StoryGameWebExporter.export(
                    project: project,
                    to: outputURL,
                    assetSourceDirectory: StoryGameStore.shared.projectURL
                )
                return jsonString([
                    "status": "exported",
                    "outputDirectory": outputURL.path,
                    "files": ["index.html", "game.json"]
                ])
            } catch {
                return errorJSON("Export failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Args

    private struct StoryGameImportArgs: Codable {
        let path: String
    }

    private struct StoryGameExportWebArgs: Codable {
        let outputDirectory: String
    }

    // MARK: - Path resolution

    private static func resolveScenesJSONURL(from url: URL) throws -> URL {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw StoryGameImportError.pathDoesNotExist
        }

        if isDirectory.boolValue {
            let candidates = [
                url.appendingPathComponent("game/data/scenes.json"),
                url.appendingPathComponent("data/scenes.json"),
                url.appendingPathComponent("scenes.json")
            ]
            for candidate in candidates where manager.fileExists(atPath: candidate.path) {
                return candidate
            }
            if let found = findScenesJSON(in: url, maxDepth: 5) {
                return found
            }
            throw StoryGameImportError.scenesJSONNotFound
        }

        return url
    }

    private static func findScenesJSON(in directory: URL, maxDepth: Int) -> URL? {
        findScenesJSON(in: directory, currentDepth: 0, maxDepth: maxDepth)
    }

    private static func findScenesJSON(in directory: URL, currentDepth: Int, maxDepth: Int) -> URL? {
        guard currentDepth < maxDepth else { return nil }
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var subdirectories: [URL] = []
        for item in contents {
            let resourceValues = try? item.resourceValues(forKeys: [.isDirectoryKey])
            let isDir = resourceValues?.isDirectory ?? false
            if isDir {
                subdirectories.append(item)
            } else if item.lastPathComponent == "scenes.json" {
                return item
            }
        }

        for subdir in subdirectories {
            if let found = findScenesJSON(in: subdir, currentDepth: currentDepth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    private enum StoryGameImportError: LocalizedError {
        case pathDoesNotExist
        case scenesJSONNotFound

        var errorDescription: String? {
            switch self {
            case .pathDoesNotExist:
                return "The selected path does not exist."
            case .scenesJSONNotFound:
                return "Could not find scenes.json inside the selected folder (searched 5 levels deep)."
            }
        }
    }
}

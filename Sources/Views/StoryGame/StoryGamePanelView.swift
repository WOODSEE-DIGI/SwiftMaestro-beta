import SwiftUI
import UniformTypeIdentifiers

// MARK: - Story Game Panel View
//
// Entry point for the Game Studio workspace panel. Handles the empty state
// (open/import) and wraps the full editor once a project is loaded.

struct StoryGamePanelView: View {
    @State private var store = StoryGameStore.shared
    @State private var isPlaying = false
    @State private var pendingImportSaveURL: URL?

    private var projectBinding: Binding<StoryGameProject> {
        Binding(
            get: { store.project ?? StoryGameProject(
                id: UUID(),
                metadata: StoryMetadata(title: ""),
                statDefinitions: [:],
                characters: [:],
                locations: [:],
                scenes: []
            )},
            set: { newValue in
                store.project = newValue
                store.isDirty = true
            }
        )
    }

    private var editorHeader: some View {
        HStack(spacing: 12) {
            if store.isDirty {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Play") { isPlaying = true }

            Button("Export Web…") { exportWeb() }

            Button("Save") { store.save() }
                .disabled(!store.isDirty || store.projectURL == nil)

            Button("Save As…") { saveAs() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
                .background(.separator)
        }
    }

    var body: some View {
        Group {
            if let project = store.project {
                VStack(spacing: 0) {
                    editorHeader
                    StoryGameEditorView(project: projectBinding, projectURL: store.projectURL)
                }
                .sheet(isPresented: $isPlaying) {
                    StoryGamePlayerView(
                        project: project,
                        projectURL: store.projectURL
                    ) {
                        isPlaying = false
                    }
                    .frame(minWidth: 800, minHeight: 600)
                }
            } else {
                welcomeView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(
            "Save imported project?",
            isPresented: Binding(
                get: { pendingImportSaveURL != nil },
                set: { if !$0 { pendingImportSaveURL = nil } }
            ),
            presenting: pendingImportSaveURL
        ) { url in
            Button("Save Game.json here") { saveImportedProject(to: url) }
            Button("Not now", role: .cancel) { pendingImportSaveURL = nil }
        } message: { url in
            Text("A legacy scenes.json was found but no Game.json. Save the imported project to \(url.path) so it opens directly next time?")
        }
    }

    // MARK: - Welcome / empty state

    private var welcomeView: some View {
        VStack(spacing: 20) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Game Studio")
                .font(.title)

            Text("Open a Game Studio project or import an existing scenes.json file.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button("Open Project…") { openProject() }
                    .buttonStyle(.borderedProminent)

                Button("Import Legacy Game…") { importLegacy() }
            }

            if let error = store.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Game Studio Project"
        panel.message = "Choose a project folder containing Game.json, or a legacy repo with scenes.json"

        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            store.load(from: url)

            // If there's no Game.json, the folder might be a legacy repo/project.
            // Auto-detect scenes.json up to 5 levels deep and import it instead.
            if store.project == nil {
                do {
                    let scenesURL = try Self.resolveScenesJSONURL(from: url)
                    store.importFromLegacyScenesJSON(at: scenesURL)
                    if store.project != nil {
                        pendingImportSaveURL = url
                    }
                } catch {
                    // Leave the original load error in place.
                }
            }
        }
    }

    private func importLegacy() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Legacy Game"
        panel.message = "Select scenes.json or the project/repo folder containing it"
        panel.allowedContentTypes = [UTType.json]
        panel.directoryURL = UserDefaults.standard.url(forKey: lastImportDirectoryKey)

        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                let scenesURL = try Self.resolveScenesJSONURL(from: url)
                store.importFromLegacyScenesJSON(at: scenesURL)
                UserDefaults.standard.set(url, forKey: lastImportDirectoryKey)
            } catch {
                store.errorMessage = "Failed to locate scenes.json: \(error.localizedDescription)"
                NSLog("[StoryGamePanelView] importLegacy failed: \(error)")
            }
        }
    }

    private static func resolveScenesJSONURL(from url: URL) throws -> URL {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ImportResolutionError.pathDoesNotExist
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
            throw ImportResolutionError.scenesJSONNotFound
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

    private enum ImportResolutionError: LocalizedError {
        case pathDoesNotExist
        case scenesJSONNotFound

        var errorDescription: String? {
            switch self {
            case .pathDoesNotExist:
                return "The selected path does not exist."
            case .scenesJSONNotFound:
                return "Could not find scenes.json inside the selected folder."
            }
        }
    }

    private let lastImportDirectoryKey = "StoryGameLastImportDirectory"

    private func saveImportedProject(to url: URL) {
        guard let project = store.project else {
            pendingImportSaveURL = nil
            return
        }
        do {
            try store.save(project, to: url)
            store.projectURL = url
            store.isDirty = false
            store.errorMessage = "Saved Game.json to \(url.path)"
        } catch {
            store.errorMessage = "Failed to save Game.json: \(error.localizedDescription)"
            NSLog("[StoryGamePanelView] saveImportedProject failed: \(error)")
        }
        pendingImportSaveURL = nil
    }

    private func saveAs() {
        guard let project = store.project else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Project Folder"
        panel.message = "Choose a folder to save Game.json into"

        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try store.save(project, to: url)
                store.projectURL = url
                store.isDirty = false
                store.errorMessage = nil
            } catch {
                store.errorMessage = "Failed to save project: \(error.localizedDescription)"
                NSLog("[StoryGamePanelView] saveAs failed: \(error)")
            }
        }
    }

    private func exportWeb() {
        guard let project = store.project else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Web Build"
        panel.message = "Choose a folder to export the web build into"

        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try StoryGameWebExporter.export(
                    project: project,
                    to: url,
                    assetSourceDirectory: store.projectURL
                )
                store.errorMessage = nil
            } catch {
                store.errorMessage = "Failed to export web build: \(error.localizedDescription)"
                NSLog("[StoryGamePanelView] exportWeb failed: \(error)")
            }
        }
    }
}

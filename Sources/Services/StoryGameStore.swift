import Foundation

// MARK: - Story Game Store
//
// Holds the loaded Game Studio project, handles persistence, and provides a
// one-time import path from the legacy scenes.json format used by the current
// web-based adventure game.

@Observable
@MainActor
final class StoryGameStore {
    static let shared = StoryGameStore()

    var project: StoryGameProject?
    var projectURL: URL?
    var isDirty = false
    var errorMessage: String?

    private let projectFilename = "Game.json"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    // MARK: - Load / Save

    /// Load a project from a directory containing `Game.json`.
    func load(from directoryURL: URL) {
        do {
            let fileURL = directoryURL.appendingPathComponent(projectFilename)
            let data = try Data(contentsOf: fileURL)
            project = try decoder.decode(StoryGameProject.self, from: data)
            projectURL = directoryURL
            isDirty = false
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load project: \(error.localizedDescription)"
            NSLog("[StoryGameStore] load failed: \(error)")
        }
    }

    /// Save the current project back to its loaded directory.
    func save() {
        guard let project else {
            errorMessage = "No project is loaded."
            return
        }
        guard let directoryURL = projectURL else {
            errorMessage = "Project has no save location."
            return
        }
        do {
            try save(project, to: directoryURL)
            isDirty = false
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save project: \(error.localizedDescription)"
            NSLog("[StoryGameStore] save failed: \(error)")
        }
    }

    /// Save a project to a specific directory, creating it if necessary.
    func save(_ project: StoryGameProject, to directoryURL: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let fileURL = directoryURL.appendingPathComponent(projectFilename)
        let data = try encoder.encode(project)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - New project

    /// Create a blank project. If a directory is supplied, the project is
    /// saved there immediately.
    @discardableResult
    func newProject(title: String, directoryURL: URL? = nil) -> StoryGameProject {
        let project = StoryGameProject(
            id: UUID(),
            metadata: StoryMetadata(title: title),
            statDefinitions: defaultStatDefinitions(),
            characters: [:],
            locations: [:],
            scenes: []
        )
        self.project = project
        self.projectURL = directoryURL
        self.isDirty = directoryURL == nil
        if let directoryURL {
            save()
        }
        return project
    }

    // MARK: - Import legacy scenes.json

    /// Import a legacy `scenes.json` file (such as the one produced by the
    /// current Python pipeline) and convert it into a StoryGameProject.
    /// The imported project becomes the current project but is not saved
    /// until the caller supplies a directory and calls `save()`.
    @discardableResult
    func importFromLegacyScenesJSON(at url: URL) -> StoryGameProject? {
        do {
            let data = try Data(contentsOf: url)
            let legacy = try decoder.decode(LegacyScenesDocument.self, from: data)
            let imported = try convertLegacyDocument(legacy)
            project = imported
            projectURL = nil
            isDirty = true
            errorMessage = nil
            return imported
        } catch {
            errorMessage = "Failed to import legacy game: \(error.localizedDescription)"
            NSLog("[StoryGameStore] import failed: \(error)")
            return nil
        }
    }

    private func convertLegacyDocument(_ legacy: LegacyScenesDocument) throws -> StoryGameProject {
        let title = legacy.metadata?.title ?? "Imported Game"
        let subtitle = legacy.metadata?.subtitle

        // Collect locations as we discover them from scene locations.
        var locations: [String: StoryLocation] = [:]
        var locationNameToID: [String: String] = [:]

        func locationID(for name: String?) -> String? {
            guard let name, !name.isEmpty else { return nil }
            if let id = locationNameToID[name] { return id }
            let id = slugify(name)
            locations[id] = StoryLocation(
                id: id,
                name: name,
                description: "",
                mapPosition: nil,
                notes: ""
            )
            locationNameToID[name] = id
            return id
        }

        // Characters.
        var characters: [String: StoryCharacter] = [:]
        for (key, legacyCharacter) in legacy.characters ?? [:] {
            characters[key] = StoryCharacter(
                id: key,
                name: legacyCharacter.name ?? key,
                role: legacyCharacter.role ?? "",
                aliases: [],
                bio: legacyCharacter.description ?? "",
                motivation: "",
                notes: legacyCharacter.firstScene?.isEmpty == false
                    ? "First scene: \(legacyCharacter.firstScene!)"
                    : "",
                keyQuotes: [],
                icon: legacyCharacter.icon ?? "✦",
                portraitFilename: legacyCharacter.portrait
            )
        }

        // Scenes.
        var scenes: [StoryScene] = []
        for legacyScene in legacy.scenes ?? [] {
            let locationIDValue = locationID(for: legacyScene.location)
            let primaryCharacterID = legacyScene.character?.isEmpty == false
                ? legacyScene.character
                : nil

            var choices: [StoryChoice] = []
            for legacyChoice in legacyScene.choices ?? [] {
                let choiceID = legacyChoice.id ?? UUID().uuidString
                let isHistorical = choiceID == legacyScene.chosenChoice
                let effects = isHistorical ? (legacyScene.statChanges ?? [:]) : [:]
                let consequence = isHistorical ? (legacyScene.consequence ?? "") : ""

                choices.append(StoryChoice(
                    id: choiceID,
                    text: legacyChoice.text ?? "",
                    targetSceneID: nil,
                    effects: effects,
                    consequence: consequence,
                    isHistorical: isHistorical
                ))
            }

            scenes.append(StoryScene(
                id: legacyScene.id,
                title: legacyScene.title ?? legacyScene.id,
                date: legacyScene.date,
                displayDate: legacyScene.displayDate,
                locationID: locationIDValue,
                primaryCharacterID: primaryCharacterID,
                narrative: legacyScene.narrative ?? "",
                sceneType: legacyScene.type ?? "event",
                choices: choices,
                symbols: legacyScene.symbols ?? [],
                characterIDs: legacyScene.characters ?? [],
                notes: legacyScene.notes ?? "",
                sourceEventIDs: legacyScene.sourceEventIDs ?? []
            ))
        }

        return StoryGameProject(
            id: UUID(),
            metadata: StoryMetadata(title: title, subtitle: subtitle),
            statDefinitions: defaultStatDefinitions(),
            characters: characters,
            locations: locations,
            scenes: scenes
        )
    }

    // MARK: - Defaults

    private func defaultStatDefinitions() -> [String: StatDefinition] {
        [
            "motivation": StatDefinition(
                id: "motivation",
                name: "Motivation",
                defaultValue: 80,
                min: 0,
                max: 100,
                isDanger: false
            ),
            "depression": StatDefinition(
                id: "depression",
                name: "Depression",
                defaultValue: 10,
                min: 0,
                max: 100,
                isDanger: true
            ),
            "access": StatDefinition(
                id: "access",
                name: "Access",
                defaultValue: 100,
                min: 0,
                max: 100,
                isDanger: false
            ),
            "legalThreat": StatDefinition(
                id: "legalThreat",
                name: "Legal Heat",
                defaultValue: 0,
                min: 0,
                max: 100,
                isDanger: true
            ),
        ]
    }
}

// MARK: - Helpers

private func slugify(_ string: String) -> String {
    let lower = string.lowercased()
    let alphanum = lower
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .joined(separator: "_")
    return alphanum.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}

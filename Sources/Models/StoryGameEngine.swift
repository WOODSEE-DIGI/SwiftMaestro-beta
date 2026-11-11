import Foundation
import SwiftUI

// MARK: - Story Game Engine
//
// Runtime state for playing a Game Studio project. Tracks the current scene,
// mutable stats, visited scenes, and choice history. Designed to be used as a
// @StateObject or plain @State value in a SwiftUI view.

@Observable
@MainActor
final class StoryGameEngine {
    private(set) var project: StoryGameProject?
    private(set) var currentSceneID: String?
    private(set) var stats: [String: Int] = [:]
    private(set) var visitedSceneIDs: Set<String> = []
    private(set) var history: [StoryChoice] = []
    private(set) var isGameOver = false
    private(set) var endReason: String?

    var currentScene: StoryScene? {
        guard let project, let currentSceneID else { return nil }
        return project.scenes.first { $0.id == currentSceneID }
    }

    var currentSceneIndex: Int? {
        guard let project, let currentSceneID else { return nil }
        return project.scenes.firstIndex { $0.id == currentSceneID }
    }

    // MARK: - Lifecycle

    func start(with project: StoryGameProject) {
        self.project = project
        self.stats = project.statDefinitions.mapValues { $0.defaultValue }
        self.visitedSceneIDs = []
        self.history = []
        self.isGameOver = false
        self.endReason = nil

        if let firstScene = project.scenes.first {
            self.currentSceneID = firstScene.id
            self.visitedSceneIDs.insert(firstScene.id)
        } else {
            self.currentSceneID = nil
            self.isGameOver = true
            self.endReason = "This project has no scenes."
        }
    }

    func restart() {
        guard let project else { return }
        start(with: project)
    }

    // MARK: - Choices

    func choose(_ choiceID: String) {
        guard let project, let scene = currentScene, !isGameOver else { return }
        guard let choice = scene.choices.first(where: { $0.id == choiceID }) else { return }

        applyEffects(choice.effects)
        history.append(choice)

        if let targetID = choice.targetSceneID, project.scenes.contains(where: { $0.id == targetID }) {
            currentSceneID = targetID
            visitedSceneIDs.insert(targetID)
        } else if let index = currentSceneIndex, index + 1 < project.scenes.count {
            let nextID = project.scenes[index + 1].id
            currentSceneID = nextID
            visitedSceneIDs.insert(nextID)
        } else {
            isGameOver = true
            endReason = choice.consequence.isEmpty
                ? "The story ends here."
                : choice.consequence
        }
    }

    // MARK: - Stats

    private func applyEffects(_ effects: [String: Int]) {
        guard let project else { return }
        for (key, delta) in effects {
            guard let definition = project.statDefinitions[key] else { continue }
            let current = stats[key] ?? definition.defaultValue
            stats[key] = min(definition.max, max(definition.min, current + delta))
        }
    }

    func value(for statID: String) -> Int {
        guard let project else { return 0 }
        guard let definition = project.statDefinitions[statID] else { return 0 }
        return stats[statID] ?? definition.defaultValue
    }

    func normalizedValue(for statID: String) -> Double {
        guard let project, let definition = project.statDefinitions[statID] else { return 0 }
        let range = Double(definition.max - definition.min)
        guard range > 0 else { return 0 }
        return Double(value(for: statID) - definition.min) / range
    }
}

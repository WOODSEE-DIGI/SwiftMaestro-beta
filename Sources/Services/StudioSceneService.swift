import Foundation
import Combine

/// Manages scenes and renders them. Scene definitions are persisted; actual
/// compositing/output is Phase 3 and will be powered by FFmpeg or AVFoundation.
@MainActor
final class StudioSceneService: ObservableObject {
    static let shared = StudioSceneService()

    @Published private(set) var scenes: [StudioScene] = []
    @Published var selectedSceneID: UUID? = nil

    private var saveURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SwiftMaestro/Scenes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scenes.json")
    }

    private init() {
        loadScenes()
        if scenes.isEmpty {
            scenes = [StudioScene.default()]
            selectedSceneID = scenes.first?.id
        }

        NotificationCenter.default.addObserver(
            forName: .reassignCameraLayer,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let oldSourceID = notification.userInfo?["oldSourceID"] as? String,
                  let newSourceID = notification.userInfo?["newSourceID"] as? String,
                  let selectedSceneID = self.selectedSceneID,
                  let sceneIndex = self.scenes.firstIndex(where: { $0.id == selectedSceneID }) else { return }

            var scene = self.scenes[sceneIndex]
            var changed = false
            for index in scene.layers.indices {
                if case .camera(let sourceID) = scene.layers[index].source, sourceID == oldSourceID {
                    scene.layers[index].source = .camera(sourceID: newSourceID)
                    changed = true
                }
            }
            if changed {
                self.updateScene(scene)
            }
        }
    }

    var selectedScene: StudioScene? {
        selectedSceneID.flatMap { id in scenes.first(where: { $0.id == id }) }
    }

    // MARK: - Persistence

    private func loadScenes() {
        guard let data = try? Data(contentsOf: saveURL),
              let saved = try? JSONDecoder().decode([StudioScene].self, from: data) else {
            return
        }
        scenes = saved
    }

    private func saveScenes() {
        guard let data = try? JSONEncoder().encode(scenes) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }

    // MARK: - CRUD

    func addScene(_ scene: StudioScene) {
        scenes.append(scene)
        selectedSceneID = scene.id
        saveScenes()
    }

    func updateScene(_ scene: StudioScene) {
        guard let index = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        scenes[index] = scene
        saveScenes()
    }

    func removeScene(id: UUID) {
        scenes.removeAll { $0.id == id }
        if selectedSceneID == id {
            selectedSceneID = scenes.first?.id
        }
        saveScenes()
    }

    // MARK: - Layer helpers

    func addLayer(to sceneID: UUID, layer: SceneLayer) {
        guard let index = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        var scene = scenes[index]
        let maxZ = scene.layers.map(\.zIndex).max() ?? 0
        var newLayer = layer
        newLayer.zIndex = maxZ + 1
        scene.layers.append(newLayer)
        updateScene(scene)
    }

    func updateLayer(in sceneID: UUID, layer: SceneLayer) {
        guard let index = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        var scene = scenes[index]
        guard let layerIndex = scene.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        scene.layers[layerIndex] = layer
        updateScene(scene)
    }

    func updateLayer(in sceneID: UUID, layer: SceneLayer, save: Bool) {
        guard let index = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        var scene = scenes[index]
        guard let layerIndex = scene.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        scene.layers[layerIndex] = layer
        if save {
            updateScene(scene)
        } else {
            scenes[index] = scene
        }
    }

    func removeLayer(from sceneID: UUID, layerID: UUID) {
        guard let index = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        var scene = scenes[index]
        scene.layers.removeAll { $0.id == layerID }
        updateScene(scene)
    }

    func moveLayer(in sceneID: UUID, layerID: UUID, toZIndex: Int) {
        guard let index = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        var scene = scenes[index]
        guard let layerIndex = scene.layers.firstIndex(where: { $0.id == layerID }) else { return }
        scene.layers[layerIndex].zIndex = toZIndex
        scene.layers.sort(by: { $0.zIndex < $1.zIndex })
        updateScene(scene)
    }
}

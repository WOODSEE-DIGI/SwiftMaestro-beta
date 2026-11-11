import SwiftUI

// MARK: - Story Game Scene Section
//
// Master-detail list of scenes with add/delete/reorder support.

struct StoryGameSceneSection: View {
    @Binding var project: StoryGameProject
    @State private var selectedSceneID: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSceneID) {
                ForEach(project.scenes) { scene in
                    HStack {
                        Text(scene.title)
                        Spacer()
                        Text(scene.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(scene.id)
                }
                .onDelete(perform: delete)
                .onMove(perform: move)
            }
            .navigationTitle("Scenes")
            .toolbar {
                ToolbarItem {
                    Button(action: addScene) {
                        Image(systemName: "plus")
                    }
                }
            }
        } detail: {
            if let id = selectedSceneID {
                StoryGameSceneEditor(
                    scene: sceneBinding(for: id),
                    project: project
                )
                .navigationTitle(project.scenes.first(where: { $0.id == id })?.title ?? "Scene")
            } else {
                ContentUnavailableView(
                    "Select a scene",
                    systemImage: "list.number",
                    description: Text("Choose a scene from the list to edit its narrative and choices.")
                )
            }
        }
    }

    private func sceneBinding(for id: String) -> Binding<StoryScene> {
        Binding(
            get: {
                project.scenes.first { $0.id == id } ?? StoryScene(id: id, title: "")
            },
            set: { newValue in
                if let index = project.scenes.firstIndex(where: { $0.id == id }) {
                    var scenes = project.scenes
                    scenes[index] = newValue
                    project.scenes = scenes
                }
            }
        )
    }

    private func addScene() {
        let base = "new_scene"
        var id = base
        var counter = 1
        while project.scenes.contains(where: { $0.id == id }) {
            id = "\(base)_\(counter)"
            counter += 1
        }
        var scenes = project.scenes
        scenes.append(StoryScene(id: id, title: "New Scene"))
        project.scenes = scenes
        selectedSceneID = id
    }

    private func delete(at offsets: IndexSet) {
        var scenes = project.scenes
        for offset in offsets.sorted(by: >) {
            let scene = scenes[offset]
            scenes.remove(at: offset)
            if selectedSceneID == scene.id {
                selectedSceneID = nil
            }
        }
        project.scenes = scenes
    }

    private func move(from source: IndexSet, to destination: Int) {
        var scenes = project.scenes
        scenes.move(fromOffsets: source, toOffset: destination)
        project.scenes = scenes
    }
}

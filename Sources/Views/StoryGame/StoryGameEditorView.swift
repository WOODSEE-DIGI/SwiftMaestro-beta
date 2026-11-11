import SwiftUI

// MARK: - Story Game Editor View
//
// Container for the Game Studio authoring UI. Uses a sidebar to switch
// between Overview, Characters, Locations, and Scenes.

struct StoryGameEditorView: View {
    @Binding var project: StoryGameProject
    let projectURL: URL?
    @State private var selectedSection: EditorSection = .overview

    enum EditorSection: Hashable {
        case overview
        case characters
        case locations
        case map
        case scenes
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Section("Project") {
                    Label("Overview", systemImage: "info.circle")
                        .tag(EditorSection.overview)
                }

                Section("Story Bible") {
                    Label("Characters", systemImage: "person.2")
                        .tag(EditorSection.characters)
                    Label("Locations", systemImage: "mappin.and.ellipse")
                        .tag(EditorSection.locations)
                    Label("Map", systemImage: "map")
                        .tag(EditorSection.map)
                }

                Section("Narrative") {
                    Label("Scenes", systemImage: "list.number")
                        .tag(EditorSection.scenes)
                }
            }
            .navigationTitle(project.metadata.title)
        } detail: {
            switch selectedSection {
            case .overview:
                StoryGameOverviewView(project: project)
            case .characters:
                StoryGameCharacterSection(project: $project, projectURL: projectURL)
            case .locations:
                StoryGameLocationSection(project: $project)
            case .map:
                StoryGameMapSection(project: $project, projectURL: projectURL)
            case .scenes:
                StoryGameSceneSection(project: $project)
            }
        }
    }
}

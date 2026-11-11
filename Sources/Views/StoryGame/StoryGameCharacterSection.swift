import SwiftUI

// MARK: - Story Game Character Section
//
// Master-detail list of characters. Selecting a character opens the editor.

struct StoryGameCharacterSection: View {
    @Binding var project: StoryGameProject
    let projectURL: URL?
    @State private var selectedCharacterID: String?

    private var sortedCharacters: [StoryCharacter] {
        project.characters.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedCharacterID) {
                ForEach(sortedCharacters) { character in
                    Text(character.name)
                        .tag(character.id)
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Characters")
            .toolbar {
                ToolbarItem {
                    Button(action: addCharacter) {
                        Image(systemName: "plus")
                    }
                }
            }
        } detail: {
            if let id = selectedCharacterID {
                StoryGameCharacterEditor(
                    character: characterBinding(for: id),
                    projectURL: projectURL
                )
                .navigationTitle(project.characters[id]?.name ?? "Character")
            } else {
                ContentUnavailableView(
                    "Select a character",
                    systemImage: "person",
                    description: Text("Choose a character from the list to edit their bio, role, and notes.")
                )
            }
        }
    }

    private func characterBinding(for id: String) -> Binding<StoryCharacter> {
        Binding(
            get: { project.characters[id] ?? StoryCharacter(id: id, name: "") },
            set: { newValue in
                var characters = project.characters
                characters[id] = newValue
                project.characters = characters
            }
        )
    }

    private func addCharacter() {
        let base = "new_character"
        var id = base
        var counter = 1
        while project.characters[id] != nil {
            id = "\(base)_\(counter)"
            counter += 1
        }
        var characters = project.characters
        characters[id] = StoryCharacter(id: id, name: "New Character")
        project.characters = characters
        selectedCharacterID = id
    }

    private func delete(at offsets: IndexSet) {
        var characters = project.characters
        for offset in offsets {
            let character = sortedCharacters[offset]
            characters.removeValue(forKey: character.id)
            if selectedCharacterID == character.id {
                selectedCharacterID = nil
            }
        }
        project.characters = characters
    }
}

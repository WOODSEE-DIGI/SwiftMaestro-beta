import SwiftUI

// MARK: - Story Game Scene Editor
//
// Form for editing a single scene, including its choices.

struct StoryGameSceneEditor: View {
    @Binding var scene: StoryScene
    let project: StoryGameProject

    private var sortedCharacters: [StoryCharacter] {
        project.characters.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var sortedLocations: [StoryLocation] {
        project.locations.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section("Identity") {
                Text("ID: \(scene.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Title", text: $scene.title)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    TextField(
                        "Date (YYYY-MM-DD)",
                        text: Binding(
                            get: { scene.date ?? "" },
                            set: { scene.date = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    TextField(
                        "Display date",
                        text: Binding(
                            get: { scene.displayDate ?? "" },
                            set: { scene.displayDate = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }

                TextField("Scene type", text: $scene.sceneType)
                    .textFieldStyle(.roundedBorder)

                Picker("Location", selection: $scene.locationID) {
                    Text("None")
                        .tag(String?.none)
                    ForEach(sortedLocations) { location in
                        Text(location.name)
                            .tag(Optional(location.id))
                    }
                }

                Picker("Primary character", selection: $scene.primaryCharacterID) {
                    Text("None")
                        .tag(String?.none)
                    ForEach(sortedCharacters) { character in
                        Text(character.name)
                            .tag(Optional(character.id))
                    }
                }
            }

            Section("Narrative") {
                TextEditor(text: $scene.narrative)
                    .frame(minHeight: 200)
            }

            Section("Symbols") {
                StoryGameEditableStringList(
                    items: $scene.symbols,
                    placeholder: "Symbol",
                    singularName: "symbol"
                )
            }

            Section("Character tags") {
                StoryGameEditableStringList(
                    items: $scene.characterIDs,
                    placeholder: "Character ID",
                    singularName: "character"
                )
            }

            Section("Choices") {
                ForEach($scene.choices) { $choice in
                    StoryGameChoiceEditor(
                        choice: $choice,
                        sourceSceneID: scene.id,
                        allScenes: project.scenes,
                        statDefinitions: project.statDefinitions
                    )
                }

                Button {
                    addChoice()
                } label: {
                    Label("Add choice", systemImage: "plus")
                }
            }

            Section("Source event IDs") {
                StoryGameEditableStringList(
                    items: $scene.sourceEventIDs,
                    placeholder: "Event ID",
                    singularName: "event"
                )
            }

            Section("Notes") {
                TextEditor(text: $scene.notes)
                    .frame(minHeight: 100)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func addChoice() {
        let base = "choice_\(scene.choices.count + 1)"
        var id = base
        var counter = 1
        while scene.choices.contains(where: { $0.id == id }) {
            id = "\(base)_\(counter)"
            counter += 1
        }
        var choices = scene.choices
        choices.append(StoryChoice(id: id, text: ""))
        scene.choices = choices
    }
}

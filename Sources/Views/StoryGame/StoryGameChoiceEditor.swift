import SwiftUI

// MARK: - Story Game Choice Editor
//
// Edits one choice within a scene: text, target scene, consequence,
// historical flag, and per-stat effects.

struct StoryGameChoiceEditor: View {
    @Binding var choice: StoryChoice
    let sourceSceneID: String
    let allScenes: [StoryScene]
    let statDefinitions: [String: StatDefinition]

    private var availableTargets: [StoryScene] {
        allScenes.filter { $0.id != sourceSceneID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TextField("Choice text", text: $choice.text)
                    .textFieldStyle(.roundedBorder)

                Toggle("Historical", isOn: $choice.isHistorical)
                    .toggleStyle(.switch)
            }

            Picker("Target scene", selection: $choice.targetSceneID) {
                Text("Next scene (linear)")
                    .tag(String?.none)
                ForEach(availableTargets) { scene in
                    Text(scene.title)
                        .tag(Optional(scene.id))
                }
            }

            Text("Consequence")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $choice.consequence)
                .frame(minHeight: 60)

            if !statDefinitions.isEmpty {
                Text("Effects")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(sortedStatIDs, id: \.self) { statID in
                    if let stat = statDefinitions[statID] {
                        Stepper(
                            "\(stat.name): \(choice.effects[statID] ?? 0)",
                            value: effectBinding(for: statID),
                            in: -100...100
                        )
                    }
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var sortedStatIDs: [String] {
        statDefinitions.values.sorted { $0.name < $1.name }.map(\.id)
    }

    private func effectBinding(for statID: String) -> Binding<Int> {
        Binding(
            get: { choice.effects[statID] ?? 0 },
            set: { newValue in
                if newValue == 0 {
                    choice.effects.removeValue(forKey: statID)
                } else {
                    choice.effects[statID] = newValue
                }
            }
        )
    }
}

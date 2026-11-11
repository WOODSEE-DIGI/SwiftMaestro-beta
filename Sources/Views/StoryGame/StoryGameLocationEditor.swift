import SwiftUI

// MARK: - Story Game Location Editor
//
// Form for editing a single location.

struct StoryGameLocationEditor: View {
    @Binding var location: StoryLocation

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $location.name)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Map Position") {
                HStack {
                    TextField(
                        "X",
                        value: Binding(
                            get: { location.mapPosition?.x },
                            set: { newValue in
                                if let x = newValue {
                                    location.mapPosition = MapPosition(
                                        x: x,
                                        y: location.mapPosition?.y ?? 0
                                    )
                                } else {
                                    location.mapPosition = nil
                                }
                            }
                        ),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)

                    TextField(
                        "Y",
                        value: Binding(
                            get: { location.mapPosition?.y },
                            set: { newValue in
                                if let y = newValue {
                                    location.mapPosition = MapPosition(
                                        x: location.mapPosition?.x ?? 0,
                                        y: y
                                    )
                                } else {
                                    location.mapPosition = nil
                                }
                            }
                        ),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }

            Section("Description") {
                TextEditor(text: $location.description)
                    .frame(minHeight: 140)
            }

            Section("Notes") {
                TextEditor(text: $location.notes)
                    .frame(minHeight: 100)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

import SwiftUI

// MARK: - Story Game Location Section
//
// Master-detail list of locations.

struct StoryGameLocationSection: View {
    @Binding var project: StoryGameProject
    @State private var selectedLocationID: String?

    private var sortedLocations: [StoryLocation] {
        project.locations.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedLocationID) {
                ForEach(sortedLocations) { location in
                    Text(location.name)
                        .tag(location.id)
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Locations")
            .toolbar {
                ToolbarItem {
                    Button(action: addLocation) {
                        Image(systemName: "plus")
                    }
                }
            }
        } detail: {
            if let id = selectedLocationID {
                StoryGameLocationEditor(location: locationBinding(for: id))
                    .navigationTitle(project.locations[id]?.name ?? "Location")
            } else {
                ContentUnavailableView(
                    "Select a location",
                    systemImage: "mappin.and.ellipse",
                    description: Text("Choose a location from the list to edit its description and map position.")
                )
            }
        }
    }

    private func locationBinding(for id: String) -> Binding<StoryLocation> {
        Binding(
            get: { project.locations[id] ?? StoryLocation(id: id, name: "") },
            set: { newValue in
                var locations = project.locations
                locations[id] = newValue
                project.locations = locations
            }
        )
    }

    private func addLocation() {
        let base = "new_location"
        var id = base
        var counter = 1
        while project.locations[id] != nil {
            id = "\(base)_\(counter)"
            counter += 1
        }
        var locations = project.locations
        locations[id] = StoryLocation(id: id, name: "New Location")
        project.locations = locations
        selectedLocationID = id
    }

    private func delete(at offsets: IndexSet) {
        var locations = project.locations
        for offset in offsets {
            let location = sortedLocations[offset]
            locations.removeValue(forKey: location.id)
            if selectedLocationID == location.id {
                selectedLocationID = nil
            }
        }
        project.locations = locations
    }
}

import SwiftUI

// MARK: - Story Game Overview
//
// Read-only summary of the loaded project: title, subtitle, and counts.

struct StoryGameOverviewView: View {
    let project: StoryGameProject

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.metadata.title)
                        .font(.title)
                    if let subtitle = project.metadata.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 120, maximum: 180))],
                    spacing: 12
                ) {
                    statCard(title: "Scenes", value: project.scenes.count)
                    statCard(title: "Characters", value: project.characters.count)
                    statCard(title: "Locations", value: project.locations.count)
                    statCard(title: "Stats", value: project.statDefinitions.count)
                }

                if !project.statDefinitions.isEmpty {
                    Text("Stats")
                        .font(.headline)
                    ForEach(project.statDefinitions.values.sorted(by: { $0.name < $1.name })) { stat in
                        HStack {
                            Text(stat.name)
                            Spacer()
                            Text("\(stat.defaultValue) / \(stat.max)")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statCard(title: String, value: Int) -> some View {
        VStack {
            Text("\(value)")
                .font(.largeTitle)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

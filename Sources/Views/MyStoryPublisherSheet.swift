import SwiftUI

/// Sheet for publishing a MyStory episode from PocketBase through the
/// MyStoryPublisher pipeline.
struct MyStoryPublisherSheet: View {
    let onDismiss: () -> Void

    @State private var selectedConfigID: UUID?
    @State private var selectedWebsiteID: String?
    @State private var selectedEpisodeID: String?
    @State private var websites: [PBWebsite] = []
    @State private var episodes: [PBMyStoryEpisode] = []
    @State private var isLoading = false
    @State private var isPublishing = false
    @State private var progressText = ""
    @State private var result: MyStoryPublisher.PublishedArtifact?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var store: PublishStore { PublishStore.shared }

    var body: some View {
        NavigationStack {
            Form {
                Section("PocketBase Server") {
                    Picker("Server", selection: $selectedConfigID) {
                        Text("Select a server").tag(UUID?.none)
                        ForEach(store.pocketBaseConfigs) { config in
                            Text(config.label).tag(config.id as UUID?)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedConfigID) { _ in
                        Task { await loadData() }
                    }
                }

                Section("Website") {
                    Picker("Website", selection: $selectedWebsiteID) {
                        Text("Select a website").tag(String?.none)
                        ForEach(websites) { website in
                            Text(website.name).tag(website.id as String?)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Episode") {
                    Picker("Episode", selection: $selectedEpisodeID) {
                        Text("Select an episode").tag(String?.none)
                        ForEach(episodes) { episode in
                            Text(episode.title).tag(episode.id as String?)
                        }
                    }
                    .pickerStyle(.menu)
                }

                if !progressText.isEmpty {
                    Section("Progress") {
                        HStack(spacing: 8) {
                            if isPublishing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(progressText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let result {
                    Section("Published") {
                        LabeledContent("Content", value: result.contentFile.lastPathComponent)
                        LabeledContent("Video", value: result.videoFile.lastPathComponent)
                        if let hash = result.commitHash {
                            LabeledContent("Commit", value: hash)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.callout)
                    } header: {
                        Text("Error")
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Button("Publish Episode") {
                            Task { await publish() }
                        }
                        .disabled(selectedConfigID == nil || selectedWebsiteID == nil || selectedEpisodeID == nil || isPublishing)
                        .controlSize(.large)
                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Publish MyStory Episode")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismissSheet() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await loadData() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading || selectedConfigID == nil)
                }
            }
            .frame(minWidth: 520, minHeight: 500)
        }
    }

    private func loadData() async {
        guard let configID = selectedConfigID,
              let config = store.pocketBaseConfigs.first(where: { $0.id == configID }) else {
            websites = []
            episodes = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = PocketBaseClient(config: config)
            try await client.authenticate()
            websites = try await client.listWebsites()
            episodes = try await client.listEpisodes()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func publish() async {
        guard let configID = selectedConfigID,
              let config = store.pocketBaseConfigs.first(where: { $0.id == configID }),
              let websiteID = selectedWebsiteID,
              let website = websites.first(where: { $0.id == websiteID }),
              let episodeID = selectedEpisodeID,
              let episode = episodes.first(where: { $0.id == episodeID }) else { return }

        isPublishing = true
        progressText = "Starting publish…"
        errorMessage = nil
        result = nil

        do {
            let publisher = MyStoryPublisher()
            let artifact = try await publisher.publish(episode: episode, website: website) { message in
                Task { @MainActor in
                    progressText = message
                }
            }
            result = artifact
            progressText = "Published successfully."
        } catch {
            errorMessage = error.localizedDescription
            progressText = ""
        }

        isPublishing = false
    }

    private func dismissSheet() {
        dismiss()
        onDismiss()
    }
}

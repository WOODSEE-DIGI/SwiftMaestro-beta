import SwiftUI
import UniformTypeIdentifiers

// MARK: - Story Game Character Editor
//
// Form for editing a single character's fields, including uploading and
// cropping a portrait image.

struct StoryGameCharacterEditor: View {
    @Binding var character: StoryCharacter
    let projectURL: URL?

    @State private var isCropperPresented = false
    @State private var selectedImageURL: URL?
    @State private var uploadError: String?

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $character.name)
                    .textFieldStyle(.roundedBorder)
                TextField("Role", text: $character.role)
                    .textFieldStyle(.roundedBorder)
                TextField("Icon", text: $character.icon)
                    .textFieldStyle(.roundedBorder)

                portraitSection
            }

            Section("Aliases") {
                StoryGameEditableStringList(
                    items: $character.aliases,
                    placeholder: "Alias",
                    singularName: "alias"
                )
            }

            Section("Bio") {
                TextEditor(text: $character.bio)
                    .frame(minHeight: 140)
            }

            Section("Motivation") {
                TextEditor(text: $character.motivation)
                    .frame(minHeight: 100)
            }

            Section("Key Quotes") {
                StoryGameEditableStringList(
                    items: $character.keyQuotes,
                    placeholder: "Quote",
                    singularName: "quote"
                )
            }

            Section("Notes") {
                TextEditor(text: $character.notes)
                    .frame(minHeight: 100)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .sheet(isPresented: $isCropperPresented) {
            if let selectedImageURL, let projectURL {
                StoryGamePortraitCropper(
                    imageURL: selectedImageURL,
                    projectURL: projectURL,
                    characterID: character.id,
                    isPresented: $isCropperPresented
                ) { savedURL in
                    character.portraitFilename = savedURL.lastPathComponent
                }
            }
        }
    }

    // MARK: - Portrait UI

    @ViewBuilder
    private var portraitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Portrait")
                    .font(.headline)
                Spacer()
                if let uploadError {
                    Text(uploadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack(spacing: 16) {
                portraitPreview

                VStack(alignment: .leading, spacing: 8) {
                    Button("Choose portrait image…") { choosePortrait() }
                        .disabled(projectURL == nil)

                    if projectURL == nil {
                        Text("Save the project first to upload portraits.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField(
                        "Portrait filename",
                        text: Binding(
                            get: { character.portraitFilename ?? "" },
                            set: { character.portraitFilename = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                }
            }
        }
    }

    @ViewBuilder
    private var portraitPreview: some View {
        if let filename = character.portraitFilename,
           let url = projectURL?.appendingPathComponent("portraits", isDirectory: true)
                              .appendingPathComponent(filename),
           FileManager.default.fileExists(atPath: url.path),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.tertiary)
                .frame(width: 80, height: 80)
                .overlay {
                    Image(systemName: "person.crop.square")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        }
    }

    // MARK: - Actions

    private func choosePortrait() {
        guard projectURL != nil else {
            uploadError = "Save the project first."
            return
        }
        uploadError = nil

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Portrait"
        panel.message = "Select an image to use as the character portrait"
        panel.allowedContentTypes = [UTType.image]

        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            selectedImageURL = url
            isCropperPresented = true
        }
    }
}

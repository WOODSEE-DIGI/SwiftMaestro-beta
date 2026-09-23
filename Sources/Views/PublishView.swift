import SwiftUI
import WebKit
import UniformTypeIdentifiers

// MARK: - View mode

private enum PublishViewMode: String, CaseIterable, Identifiable {
    case kanban, list, tags, feeds, destinations, history
    var id: String { rawValue }
    var label: String {
        switch self {
        case .kanban: return String(localized: "Kanban")
        case .list: return String(localized: "List")
        case .tags: return String(localized: "Tags")
        case .feeds: return String(localized: "Feeds")
        case .destinations: return String(localized: "Destinations")
        case .history: return String(localized: "History")
        }
    }
}

// MARK: - Main view

struct PublishView: View {
    @State private var store = PublishStore.shared
    @State private var viewMode: PublishViewMode = .kanban
    @State private var selectedDraft: PublishDraft? = nil
    @State private var showingTagSheet = false
    @State private var editingTag: PublishTag? = nil
    @State private var newTagName = ""
    @State private var showingFeedSheet = false
    @State private var editingFeed: PublishFeed? = nil
    @State private var showingNeocitiesSheet = false
    @State private var editingNeocities: NeocitiesConfig? = nil
    @State private var showingSocialSheet = false
    @State private var editingSocial: SocialDestinationConfig? = nil
    @State private var selectedFeedID: UUID = PublishStore.defaultFeed.id

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onAppear {
            Task {
                await store.scan()
            }
        }
        .sheet(item: $selectedDraft) { draft in
            PublishDraftDetailSheet(draft: draft, selectedFeedID: $selectedFeedID)
        }
        .sheet(isPresented: $showingTagSheet) {
            tagManagementSheet
        }
        .sheet(isPresented: $showingFeedSheet) {
            feedManagementSheet
        }
        .sheet(isPresented: $showingNeocitiesSheet) {
            neocitiesManagementSheet
        }
        .sheet(item: $editingNeocities) { config in
            EditNeocitiesSheet(config: config) { editingNeocities = nil }
        }
        .sheet(isPresented: $showingSocialSheet) {
            socialManagementSheet
        }
        .sheet(item: $editingSocial) { config in
            EditSocialSheet(config: config) { editingSocial = nil }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $viewMode) {
                ForEach(PublishViewMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 380)

            Spacer()

            if viewMode == .tags {
                Button {
                    showingTagSheet = true
                } label: {
                    Label("Manage Tags", systemImage: "tag")
                }
            } else if viewMode == .feeds {
                Button {
                    showingFeedSheet = true
                } label: {
                    Label("Manage Feeds", systemImage: "wave.3.forward")
                }
            } else if viewMode == .destinations {
                HStack(spacing: 12) {
                    Button {
                        showingSocialSheet = true
                    } label: {
                        Label("Social Accounts", systemImage: "person.2")
                    }
                    Button {
                        showingNeocitiesSheet = true
                    } label: {
                        Label("Manage Neocities", systemImage: "network")
                    }
                }
            } else if store.isScanning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task {
                        await store.scan()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewMode {
        case .kanban:
            PublishKanbanView(selectedDraft: $selectedDraft)
        case .list:
            PublishListView(selectedDraft: $selectedDraft)
        case .tags:
            PublishTagsView()
        case .feeds:
            PublishFeedsView()
        case .destinations:
            PublishDestinationsView(editingConfig: $editingNeocities, editingSocial: $editingSocial)
        case .history:
            PublishHistoryView()
        }
    }

    // MARK: - Tag management sheet

    private var tagManagementSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Form {
                    Section("Add Custom Tag") {
                        TextField("Tag name", text: $newTagName)
                        Button("Add") {
                            guard !newTagName.isEmpty else { return }
                            store.addTag(name: newTagName)
                            newTagName = ""
                        }
                        .disabled(newTagName.isEmpty)
                    }

                    Section("Monitored Tags") {
                        ForEach(store.tags) { tag in
                            HStack {
                                Circle()
                                    .fill((tag.color?.swiftUIColor ?? Color.secondary).opacity(0.6))
                                    .frame(width: 10, height: 10)

                                Text("#\(tag.name)")

                                if tag.isSystem {
                                    Text(tag.role?.displayName ?? "system")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15))
                                        .clipShape(Capsule())
                                }

                                Spacer()

                                if !tag.isSystem {
                                    Button(role: .destructive) {
                                        store.removeTag(name: tag.name)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingTag = tag
                            }
                        }
                    }
                }
                .navigationTitle("Publishing Tags")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingTagSheet = false }
                    }
                }
                .sheet(item: $editingTag) { tag in
                    EditTagSheet(tag: tag) { editingTag = nil }
                }
                .frame(minWidth: 400, minHeight: 400)
            }
        }
    }

    // MARK: - Feed management sheet

    @State private var newFeedName = ""
    @State private var newFeedDirectory: String = ""

    @State private var newNeocitiesSitename = ""
    @State private var newNeocitiesSecretName = ""
    @State private var newNeocitiesBasePath = ""

    @State private var newSocialPlatform: SocialPlatform = .bluesky
    @State private var newSocialLabel = ""
    @State private var newSocialSecretName = ""
    @State private var newSocialServerURL = ""
    @State private var newSocialAccountIdentifier = ""

    private var feedManagementSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Form {
                    Section("Add Feed") {
                        TextField("Feed name", text: $newFeedName)
                        TextField("Output directory (optional)", text: $newFeedDirectory)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            guard !newFeedName.isEmpty else { return }
                            let directory = newFeedDirectory.isEmpty ? nil : newFeedDirectory
                            store.addFeed(name: newFeedName, outputDirectory: directory)
                            newFeedName = ""
                            newFeedDirectory = ""
                        }
                        .disabled(newFeedName.isEmpty)
                    }

                    Section("Feeds") {
                        ForEach(store.feeds) { feed in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feed.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(feed.outputDirectory ?? "Default output directory")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if feed.id != PublishStore.defaultFeed.id {
                                    Button(role: .destructive) {
                                        store.removeFeed(id: feed.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingFeed = feed
                            }
                        }
                    }
                }
                .navigationTitle("Publishing Feeds")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingFeedSheet = false }
                    }
                }
                .sheet(item: $editingFeed) { feed in
                    EditFeedSheet(feed: feed) { editingFeed = nil }
                }
                .frame(minWidth: 400, minHeight: 400)
            }
        }
    }

    // MARK: - Feed editing sheet

    private struct EditFeedSheet: View {
        let feed: PublishFeed
        let onDismiss: () -> Void

        @State private var name: String
        @State private var outputDirectory: String
        @Environment(\.dismiss) private var dismiss

        init(feed: PublishFeed, onDismiss: @escaping () -> Void) {
            self.feed = feed
            self.onDismiss = onDismiss
            _name = State(initialValue: feed.name)
            _outputDirectory = State(initialValue: feed.outputDirectory ?? "")
        }

        var body: some View {
            NavigationStack {
                Form {
                    Section("Feed Name") {
                        TextField("Feed name", text: $name)
                    }

                    Section("Output Directory") {
                        TextField("Leave empty for default", text: $outputDirectory)
                    }
                }
                .formStyle(.grouped)
                .navigationTitle("Edit Feed")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismissSheet() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let directory = outputDirectory.isEmpty ? nil : outputDirectory
                            PublishStore.shared.updateFeed(feed, newName: name, newOutputDirectory: directory)
                            dismissSheet()
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .frame(minWidth: 360, minHeight: 280)
            }
        }

        private func dismissSheet() {
            dismiss()
            onDismiss()
        }
    }

    // MARK: - Tag editing sheet

    private struct EditTagSheet: View {
        let tag: PublishTag
        let onDismiss: () -> Void

        @State private var name: String
        @State private var color: KanbanColumnColor?
        @Environment(\.dismiss) private var dismiss

        init(tag: PublishTag, onDismiss: @escaping () -> Void) {
            self.tag = tag
            self.onDismiss = onDismiss
            _name = State(initialValue: tag.name)
            _color = State(initialValue: tag.color)
        }

        var body: some View {
            NavigationStack {
                Form {
                    Section("Tag Name") {
                        TextField("Tag name", text: $name)
                    }

                    if let role = tag.role {
                        Section("Workflow Role") {
                            Text(role.displayName)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Color") {
                        Picker("Color", selection: $color) {
                            Text("Default").tag(KanbanColumnColor?.none)
                            ForEach(KanbanColumnColor.allCases) { colorCase in
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(colorCase.swiftUIColor)
                                        .frame(width: 12, height: 12)
                                    Text(colorCase.rawValue.capitalized)
                                }
                                .tag(Optional(colorCase))
                            }
                        }
                        .pickerStyle(.inline)
                    }
                }
                .formStyle(.grouped)
                .navigationTitle(tag.isSystem ? "Edit System Tag" : "Edit Tag")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismissSheet() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            PublishStore.shared.updateTag(tag, newName: name, newColor: color)
                            dismissSheet()
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .frame(minWidth: 360, minHeight: 320)
            }
        }

        private func dismissSheet() {
            dismiss()
            onDismiss()
        }
    }
}

// MARK: - Kanban view

private struct PublishKanbanView: View {
    @State private var store = PublishStore.shared
    @Binding var selectedDraft: PublishDraft?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(PublishStatus.allCases) { status in
                    PublishKanbanColumn(
                        status: status,
                        drafts: store.drafts(withStatus: status),
                        selectedDraft: $selectedDraft
                    )
                }
            }
            .padding(12)
        }
    }
}

private struct PublishKanbanColumn: View {
    let status: PublishStatus
    let drafts: [PublishDraft]
    @Binding var selectedDraft: PublishDraft?
    @State private var store = PublishStore.shared
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(status.displayName)
                    .font(.headline)
                Spacer()
                Text("\(drafts.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(status.kanbanColumnColor.swiftUIColor.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(drafts) { draft in
                        PublishDraftCard(draft: draft) {
                            selectedDraft = draft
                        }
                    }
                }
            }
        }
        .frame(width: 260)
        .padding(8)
        .background(isTargeted ? status.kanbanColumnColor.swiftUIColor.opacity(0.15) : Color.secondary.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isTargeted ? status.kanbanColumnColor.swiftUIColor : Color.clear, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onDrop(of: [UTType.plainText.identifier], isTargeted: $isTargeted) { providers, _ in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: String.self) { object, _ in
                guard let draftID = object else { return }
                Task { @MainActor in
                    store.setStatus(draftID: draftID, to: status)
                }
            }
            return true
        }
    }
}

private struct PublishDraftCard: View {
    let draft: PublishDraft
    let action: () -> Void
    @State private var store = PublishStore.shared

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                Text(draft.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                HStack(spacing: 4) {
                    Image(systemName: draft.sourceKind.icon)
                        .font(.caption2)
                    Text(draft.sourceKind.displayName)
                        .font(.caption2)
                    Spacer()
                    Text(draft.modifiedAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !draft.tags.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(draft.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .contextMenu {
            draftContextMenu
        }
        .onDrag {
            NSItemProvider(object: draft.id as NSString)
        }
    }

    @ViewBuilder
    private var draftContextMenu: some View {
        Section("Move to") {
            ForEach(PublishStatus.allCases) { status in
                Button {
                    store.setStatus(draftID: draft.id, to: status)
                } label: {
                    Text(status.displayName)
                    if draft.status == status {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }

        Divider()

        Button {
            _ = store.publish(draftID: draft.id)
        } label: {
            Label("Publish Now", systemImage: "newspaper")
        }
        .disabled(draft.status == .published)

        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: draft.sourcePath)])
        } label: {
            Label("Reveal in Finder", systemImage: "arrow.up.right.folder")
        }
    }
}

// MARK: - List view

private struct PublishListView: View {
    @State private var store = PublishStore.shared
    @Binding var selectedDraft: PublishDraft?

    var body: some View {
        List(selection: Binding(
            get: { selectedDraft?.id },
            set: { newID in
                selectedDraft = store.drafts.first { $0.id == newID }
            }
        )) {
            ForEach(store.drafts) { draft in
                PublishListRow(draft: draft)
                    .tag(draft.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedDraft = draft
                    }
                    .contextMenu {
                        statusMenu(for: draft)
                    }
            }
        }
    }

    private func statusMenu(for draft: PublishDraft) -> some View {
        Group {
            Section("Move to") {
                ForEach(PublishStatus.allCases) { status in
                    Button {
                        store.setStatus(draftID: draft.id, to: status)
                    } label: {
                        Text(status.displayName)
                        if draft.status == status {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button {
                _ = store.publish(draftID: draft.id)
            } label: {
                Label("Publish Now", systemImage: "newspaper")
            }
            .disabled(draft.status == .published)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: draft.sourcePath)])
            } label: {
                Label("Reveal in Finder", systemImage: "arrow.up.right.folder")
            }
        }
    }
}

private struct PublishListRow: View {
    let draft: PublishDraft

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: draft.sourceKind.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(draft.title)
                    .font(.system(size: 13, weight: .medium))
                Text(draft.sourceKind.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                ForEach(draft.tags.prefix(3), id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            Text(draft.status.displayName)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(draft.status.kanbanColumnColor.swiftUIColor.opacity(0.2))
                .clipShape(Capsule())

            Text(draft.modifiedAt, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Tags view

private struct PublishTagsView: View {
    @State private var store = PublishStore.shared
    @State private var newTagName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("New tag…", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button("Add") {
                    guard !newTagName.isEmpty else { return }
                    store.addTag(name: newTagName)
                    newTagName = ""
                }
                .disabled(newTagName.isEmpty)
                Spacer()
            }
            .padding()

            Divider()

            List(store.tags) { tag in
                HStack {
                    Text("#\(tag.name)")
                        .font(.system(size: 14, weight: .medium))
                    if tag.isSystem {
                        Text("system")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    if !tag.isSystem {
                        Button(role: .destructive) {
                            store.removeTag(name: tag.name)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

// MARK: - Feeds view

private struct PublishFeedsView: View {
    @State private var store = PublishStore.shared

    var body: some View {
        List {
            if store.feeds.isEmpty {
                ContentUnavailableView(
                    "No Feeds",
                    systemImage: "wave.3.forward",
                    description: Text("Add a feed in Manage Feeds.")
                )
            } else {
                ForEach(store.feeds) { feed in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(feed.name)
                            .font(.system(size: 13, weight: .medium))
                        Text(feed.outputDirectory ?? "Default output directory")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: - History view

private struct PublishHistoryView: View {
    @State private var store = PublishStore.shared

    var body: some View {
        List {
            if store.history.isEmpty {
                ContentUnavailableView(
                    "No Published Items",
                    systemImage: "newspaper",
                    description: Text("Publish a draft to see it here.")
                )
            } else {
                ForEach(store.history.sorted(by: { $0.publishedAt > $1.publishedAt })) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                            .font(.system(size: 13, weight: .medium))
                        HStack {
                            Text(entry.feedName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.publishedAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.outputPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: - Draft detail sheet

private struct PublishDraftDetailSheet: View {
    let draft: PublishDraft
    @Binding var selectedFeedID: UUID
    @State private var store = PublishStore.shared
    @State private var selectedStatus: PublishStatus
    @State private var outputPath: String?
    @State private var selectedNeocitiesConfigID: UUID?
    @State private var neocitiesOutputPath: String?
    @State private var isUploadingToNeocities = false
    @State private var selectedSocialDestinationIDs: Set<UUID> = []
    @State private var crossPostResults: [CrossPostResult] = []
    @State private var isCrossPosting = false
    @Environment(\.dismiss) private var dismiss

    init(draft: PublishDraft, selectedFeedID: Binding<UUID>) {
        self.draft = draft
        self._selectedFeedID = selectedFeedID
        self._selectedStatus = State(initialValue: draft.status)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Draft") {
                    Text(draft.title)
                        .font(.headline)
                    Text(draft.sourceKind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Modified: \(draft.modifiedAt, style: .date)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Status") {
                    Picker("Status", selection: $selectedStatus) {
                        ForEach(PublishStatus.allCases) { status in
                            Text(status.displayName).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Tags") {
                    FlowLayout(spacing: 6) {
                        ForEach(draft.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }

                Section("Preview") {
                    PublishHTMLPreviewWebView(
                        html: draft.bodyHTML,
                        baseURL: URL(fileURLWithPath: draft.sourcePath).deletingLastPathComponent()
                    )
                    .frame(minHeight: 200, idealHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Section("Publish") {
                    Picker("Feed", selection: $selectedFeedID) {
                        ForEach(store.feeds) { feed in
                            Text(feed.name).tag(feed.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Button("Publish Now") {
                        store.setStatus(draftID: draft.id, to: selectedStatus)
                        outputPath = store.publish(draftID: draft.id, feedID: selectedFeedID)
                    }
                    .disabled(draft.status == .published && selectedStatus == .published)

                    if let path = outputPath {
                        Text("Feed written to:\n\(path)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !store.neocitiesConfigs.isEmpty {
                    Section("Neocities") {
                        Picker("Site", selection: $selectedNeocitiesConfigID) {
                            Text("Choose a site…").tag(nil as UUID?)
                            ForEach(store.neocitiesConfigs) { config in
                                Text(config.sitename).tag(config.id as UUID?)
                            }
                        }
                        .pickerStyle(.menu)

                        Button {
                            guard let configID = selectedNeocitiesConfigID else { return }
                            store.setStatus(draftID: draft.id, to: selectedStatus)
                            isUploadingToNeocities = true
                            Task {
                                neocitiesOutputPath = await store.publishToNeocities(draftID: draft.id, configID: configID)
                                isUploadingToNeocities = false
                            }
                        } label: {
                            if isUploadingToNeocities {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Upload to Neocities", systemImage: "arrow.up.circle")
                            }
                        }
                        .disabled(selectedNeocitiesConfigID == nil || isUploadingToNeocities)

                        if let path = neocitiesOutputPath {
                            Text("Uploaded to:\n\(path)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !store.socialDestinations.isEmpty {
                    Section("Cross-post") {
                        ForEach(store.socialDestinations) { config in
                            Toggle(isOn: Binding(
                                get: { selectedSocialDestinationIDs.contains(config.id) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedSocialDestinationIDs.insert(config.id)
                                    } else {
                                        selectedSocialDestinationIDs.remove(config.id)
                                    }
                                }
                            )) {
                                HStack {
                                    Image(systemName: config.platform.icon)
                                        .foregroundStyle(.secondary)
                                    Text(config.label)
                                    Spacer()
                                    Text(config.platform.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!config.isEnabled)
                        }

                        Button {
                            let ids = Array(selectedSocialDestinationIDs)
                            guard !ids.isEmpty else { return }
                            store.setStatus(draftID: draft.id, to: selectedStatus)
                            isCrossPosting = true
                            Task {
                                crossPostResults = await store.crossPost(draftID: draft.id, destinationIDs: ids)
                                isCrossPosting = false
                            }
                        } label: {
                            if isCrossPosting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Cross-post Now", systemImage: "arrow.up.forward.square")
                            }
                        }
                        .disabled(selectedSocialDestinationIDs.isEmpty || isCrossPosting)

                        if !crossPostResults.isEmpty {
                            ForEach(crossPostResults) { result in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(result.success ? .green : .red)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.label)
                                            .font(.system(size: 12, weight: .medium))
                                        Text(result.message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let urlString = result.postedURL, let url = URL(string: urlString) {
                                            Link(urlString, destination: url)
                                                .font(.caption)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Draft Details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        store.setStatus(draftID: draft.id, to: selectedStatus)
                        dismiss()
                    }
                }
            }
            .frame(minWidth: 420, minHeight: 500)
            .onAppear {
                selectedSocialDestinationIDs = Set(store.socialDestinations.filter(\.isEnabled).map(\.id))
            }
        }
    }
}

// MARK: - Social platform UI helpers

private func platformSecretHint(for platform: SocialPlatform) -> String {
    switch platform {
    case .mastodon:
        return "Use the same secret name saved in the Mastodon plugin (usually plugin.mastodon.accessToken)."
    case .facebook:
        return "Store a Facebook Page access token in Keychain and use its account name here."
    case .threads:
        return "Store a Threads Graph API user access token in Keychain and use its account name here."
    case .twitter:
        return "Store a Twitter/X OAuth 2.0 user access token in Keychain and use its account name here."
    case .linkedin:
        return "Store a LinkedIn OAuth 2.0 access token in Keychain and use its account name here."
    case .instagram:
        return "Store an Instagram Graph API access token in Keychain and use its account name here."
    case .youtube:
        return "Store a YouTube Data API OAuth 2.0 access token in Keychain and use its account name here."
    case .vimeo:
        return "Store a Vimeo API access token in Keychain and use its account name here."
    case .dailymotion:
        return "Store a Dailymotion API access token in Keychain and use its account name here."
    case .peertube:
        return "Store a PeerTube OAuth 2.0 access token in Keychain and use its account name here."
    case .tiktok:
        return "Store a TikTok Content Posting API access token in Keychain and use its account name here."
    case .vk:
        return "Store a VKontakte access token in Keychain and use its account name here."
    default:
        return ""
    }
}

// MARK: - HTML preview

private struct PublishHTMLPreviewWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        WKWebView(frame: .zero)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let styledHTML = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            font-size: 14px;
            line-height: 1.5;
            color: #e0e0e0;
            margin: 12px;
            word-wrap: break-word;
          }
          img { max-width: 100%; height: auto; }
          pre, code { background: rgba(255,255,255,0.1); border-radius: 4px; padding: 2px 4px; }
          pre { padding: 8px; overflow-x: auto; }
          blockquote { border-left: 3px solid #666; margin-left: 0; padding-left: 12px; color: #bbb; }
        </style>
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
        webView.loadHTMLString(styledHTML, baseURL: baseURL)
    }
}

// MARK: - Destinations view

private struct PublishDestinationsView: View {
    @State private var store = PublishStore.shared
    @Binding var editingConfig: NeocitiesConfig?
    @Binding var editingSocial: SocialDestinationConfig?

    var body: some View {
        VStack(spacing: 0) {
            if store.neocitiesConfigs.isEmpty && store.socialDestinations.isEmpty {
                ContentUnavailableView(
                    "No Destinations",
                    systemImage: "network",
                    description: Text("Add a Neocities site or a social account to publish remotely.")
                )
            } else {
                List {
                    if !store.socialDestinations.isEmpty {
                        Section("Social Accounts") {
                            ForEach(store.socialDestinations) { config in
                                HStack {
                                    Image(systemName: config.platform.icon)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(config.label)
                                            .font(.system(size: 13, weight: .medium))
                                        Text(config.platform.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if !config.isEnabled {
                                        Text("Disabled")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Button {
                                        editingSocial = config
                                    } label: {
                                        Image(systemName: "pencil")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .contentShape(Rectangle())
                                .opacity(config.isEnabled ? 1.0 : 0.6)
                            }
                        }
                    }

                    if !store.neocitiesConfigs.isEmpty {
                        Section("Neocities Sites") {
                            ForEach(store.neocitiesConfigs) { config in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(config.sitename)
                                            .font(.system(size: 13, weight: .medium))
                                        Text(config.basePath?.isEmpty == false ? "Path: /\(config.basePath!)" : "Root upload")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button {
                                        editingConfig = config
                                    } label: {
                                        Image(systemName: "pencil")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .contentShape(Rectangle())
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Neocities management sheet

extension PublishView {

    private var neocitiesManagementSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Form {
                    Section("Add Neocities Site") {
                        TextField("Sitename", text: $newNeocitiesSitename)
                        TextField("API key secret name", text: $newNeocitiesSecretName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Remote path prefix (optional)", text: $newNeocitiesBasePath)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            guard !newNeocitiesSitename.isEmpty, !newNeocitiesSecretName.isEmpty else { return }
                            let config = NeocitiesConfig(
                                sitename: newNeocitiesSitename,
                                apiKeySecretName: newNeocitiesSecretName,
                                basePath: newNeocitiesBasePath
                            )
                            store.addNeocitiesConfig(config)
                            newNeocitiesSitename = ""
                            newNeocitiesSecretName = ""
                            newNeocitiesBasePath = ""
                        }
                        .disabled(newNeocitiesSitename.isEmpty || newNeocitiesSecretName.isEmpty)
                    }

                    Section("Configured Sites") {
                        ForEach(store.neocitiesConfigs) { config in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(config.sitename)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(config.apiKeySecretName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    store.removeNeocitiesConfig(id: config.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingNeocities = config
                            }
                        }
                    }
                }
                .navigationTitle("Neocities Destinations")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingNeocitiesSheet = false }
                    }
                }
                .frame(minWidth: 400, minHeight: 400)
            }
        }
    }
}

// MARK: - Social management sheet

extension PublishView {

    private var socialManagementSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Platform", selection: $newSocialPlatform) {
                        ForEach(SocialPlatform.allCases.filter(\.supportsPosting)) { platform in
                            Label(platform.displayName, systemImage: platform.icon).tag(platform)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Add Social Account")
                } footer: {
                    Text("Choose the platform you want to publish to. Each platform needs its own access token stored in Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Account Details") {
                    TextField("Label (e.g. @alice)", text: $newSocialLabel)
                        .textFieldStyle(.roundedBorder)

                    if !newSocialPlatform.accountIdentifierHint.isEmpty {
                        TextField(newSocialPlatform.accountIdentifierHint, text: $newSocialAccountIdentifier)
                            .textFieldStyle(.roundedBorder)
                    }

                    if newSocialPlatform == .mastodon {
                        TextField("Instance URL (e.g. mastodon.social)", text: $newSocialServerURL)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section {
                    if newSocialPlatform == .bluesky {
                        Text("Sign in via the Bluesky plugin panel first. No extra secret is needed here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Keychain secret name", text: $newSocialSecretName)
                            .textFieldStyle(.roundedBorder)
                    }
                } header: {
                    Text("Credentials")
                } footer: {
                    if newSocialPlatform != .bluesky {
                        Text(platformSecretHint(for: newSocialPlatform))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Button("Add Account") {
                            let label = newSocialLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !label.isEmpty else { return }
                            let destination = SocialDestinationConfig(
                                platform: newSocialPlatform,
                                label: label,
                                secretName: newSocialSecretName.trimmingCharacters(in: .whitespaces),
                                serverURL: newSocialServerURL.isEmpty ? nil : newSocialServerURL,
                                accountIdentifier: newSocialAccountIdentifier.isEmpty ? nil : newSocialAccountIdentifier
                            )
                            store.addSocialDestination(destination)
                            newSocialLabel = ""
                            newSocialSecretName = ""
                            newSocialServerURL = ""
                            newSocialAccountIdentifier = ""
                            newSocialPlatform = .bluesky
                        }
                        .disabled(!canAddSocialAccount)
                        .controlSize(.large)
                        Spacer()
                    }
                }

                Section("Configured Accounts") {
                    ForEach(store.socialDestinations) { config in
                        HStack {
                            Image(systemName: config.platform.icon)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(config.label)
                                    .font(.system(size: 13, weight: .medium))
                                Text(config.platform.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { config.isEnabled },
                                set: { newValue in
                                    var updated = config
                                    updated.isEnabled = newValue
                                    store.updateSocialDestination(updated)
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            Button(role: .destructive) {
                                store.removeSocialDestination(id: config.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editingSocial = config
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Social Destinations")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingSocialSheet = false }
                }
            }
            .frame(minWidth: 520, minHeight: 540)
        }
    }

    private var canAddSocialAccount: Bool {
        let label = newSocialLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return false }
        if newSocialPlatform == .bluesky { return true }
        return !newSocialSecretName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Social editing sheet

private struct EditSocialSheet: View {
    let config: SocialDestinationConfig
    let onDismiss: () -> Void

    @State private var platform: SocialPlatform
    @State private var label: String
    @State private var secretName: String
    @State private var serverURL: String
    @State private var accountIdentifier: String
    @State private var isEnabled: Bool
    @Environment(\.dismiss) private var dismiss

    init(config: SocialDestinationConfig, onDismiss: @escaping () -> Void) {
        self.config = config
        self.onDismiss = onDismiss
        _platform = State(initialValue: config.platform)
        _label = State(initialValue: config.label)
        _secretName = State(initialValue: config.secretName)
        _serverURL = State(initialValue: config.serverURL ?? "")
        _accountIdentifier = State(initialValue: config.accountIdentifier ?? "")
        _isEnabled = State(initialValue: config.isEnabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    Picker("Platform", selection: $platform) {
                        ForEach(SocialPlatform.allCases.filter(\.supportsPosting)) { platform in
                            Label(platform.displayName, systemImage: platform.icon).tag(platform)
                        }
                    }
                    .pickerStyle(.menu)

                    TextField("Label", text: $label)
                        .textFieldStyle(.roundedBorder)

                    if !platform.accountIdentifierHint.isEmpty {
                        TextField(platform.accountIdentifierHint, text: $accountIdentifier)
                            .textFieldStyle(.roundedBorder)
                    }

                    Toggle("Enabled", isOn: $isEnabled)
                }

                if platform == .mastodon {
                    Section("Mastodon Instance") {
                        TextField("Instance URL", text: $serverURL)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section {
                    if platform == .bluesky {
                        Text("Sign in via the Bluesky plugin panel first. No extra secret is needed here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Keychain secret name", text: $secretName)
                            .textFieldStyle(.roundedBorder)
                    }
                } header: {
                    Text("Credentials")
                } footer: {
                    if platform != .bluesky {
                        Text(platformSecretHint(for: platform))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Social Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismissSheet() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedLabel.isEmpty else { return }
                        var updated = config
                        updated.platform = platform
                        updated.label = trimmedLabel
                        updated.secretName = secretName.trimmingCharacters(in: .whitespaces)
                        updated.serverURL = serverURL.isEmpty ? nil : serverURL
                        updated.accountIdentifier = accountIdentifier.isEmpty ? nil : accountIdentifier
                        updated.isEnabled = isEnabled
                        PublishStore.shared.updateSocialDestination(updated)
                        dismissSheet()
                    }
                    .disabled(!canSave)
                }
            }
            .frame(minWidth: 440, minHeight: 360)
        }
    }

    private var canSave: Bool {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else { return false }
        if platform == .bluesky { return true }
        return !secretName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func dismissSheet() {
        dismiss()
        onDismiss()
    }
}

// MARK: - Neocities editing sheet

private struct EditNeocitiesSheet: View {
    let config: NeocitiesConfig
    let onDismiss: () -> Void

    @State private var sitename: String
    @State private var secretName: String
    @State private var basePath: String
    @Environment(\.dismiss) private var dismiss

    init(config: NeocitiesConfig, onDismiss: @escaping () -> Void) {
        self.config = config
        self.onDismiss = onDismiss
        _sitename = State(initialValue: config.sitename)
        _secretName = State(initialValue: config.apiKeySecretName)
        _basePath = State(initialValue: config.basePath ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Site") {
                    TextField("Sitename", text: $sitename)
                }

                Section("API Key") {
                    TextField("Keychain secret name", text: $secretName)
                }

                Section("Upload Path") {
                    TextField("Remote path prefix (optional)", text: $basePath)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Neocities Site")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismissSheet() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = config
                        updated.sitename = sitename.trimmingCharacters(in: .whitespaces)
                        updated.apiKeySecretName = secretName.trimmingCharacters(in: .whitespaces)
                        updated.basePath = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        PublishStore.shared.updateNeocitiesConfig(updated)
                        dismissSheet()
                    }
                    .disabled(sitename.trimmingCharacters(in: .whitespaces).isEmpty || secretName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .frame(minWidth: 360, minHeight: 280)
        }
    }

    private func dismissSheet() {
        dismiss()
        onDismiss()
    }
}


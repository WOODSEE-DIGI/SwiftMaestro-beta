import SwiftUI

// MARK: - Tagging Workspace
//
// The learn-as-you-tag UI. Layout:
//   • Toolbar — AI indexing controls + confidence thresholds.
//   • Left — the AI suggestion queue (grouped by tag, confidence-sorted),
//     accept/reject per row; clicking a row drives the main preview.
//   • Center — big preview of the primary selection, its OCR text, tags.
//   • Bottom — filmstrip of untagged assets plus the manual tag field;
//     "Apply & Learn" tags the selection and immediately propagates to
//     similar images.

struct TaggingWorkspaceView: View {
    var viewModel: DAMViewModel
    @State private var tagging = DAMTaggingViewModel()
    @State private var tagDraft = ""

    /// The asset to preview. `DAMViewModel.primaryAsset` only resolves IDs
    /// against the browser grid's loaded page — but this workspace's
    /// filmstrip shows the UNTAGGED pool and the queue shows suggestion
    /// assets, neither of which is guaranteed to be in that page. Fall back
    /// to both pools so selecting them actually previews.
    private var displayAsset: DAMAsset? {
        if let primary = viewModel.primaryAsset { return primary }
        guard let id = viewModel.primarySelectedID else { return nil }
        return tagging.untaggedPool.first { $0.id == id }
            ?? tagging.queue.first { $0.asset.id == id }?.asset
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                suggestionQueue
                    .frame(minWidth: 280, idealWidth: 330, maxWidth: 380)
                Divider()
                detailPanel
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            manualStrip
        }
        .task { await tagging.reload() }
        // .task(id:) coalesces selection churn (see DAMViewModel notes).
        .task(id: viewModel.primarySelectedID) {
            await tagging.loadPrimaryDetails(displayAsset)
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 12) {
            if tagging.isIndexing {
                Button { tagging.cancelIndexing() } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .controlSize(.small)
                Text(tagging.indexProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Button { tagging.startIndexing() } label: {
                    Label("Index \(tagging.backlogCount) assets",
                          systemImage: "bolt.badge.clock")
                }
                .controlSize(.small)
                .disabled(tagging.backlogCount == 0)
                .help("Run OCR + visual fingerprinting over un-indexed assets (on-device)")
            }

            Button {
                Task { await tagging.relearnFromAllExemplars() }
            } label: {
                Label("Relearn All", systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)
            .disabled(tagging.isPropagating || tagging.isIndexing)
            .help("Propagate every existing tag (including Lightroom-imported "
                  + "keywords) to similar untagged images")

            Divider().frame(height: 16)

            HStack(spacing: 4) {
                Text("Suggest ≥ \(Int(tagging.thresholds.suggest * 100))%")
                    .font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { tagging.thresholds.suggest },
                    set: { tagging.thresholds.suggest = min($0, tagging.thresholds.autoApply - 0.01) }
                ), in: 0.3...0.98) { editing in
                    // Reload when the drag ENDS, not per tick: firing reload()
                    // (which rewrites the queue arrays) mid-render is the exact
                    // mutation-during-body-eval pattern that crashes SwiftUI.
                    if !editing {
                        Task { await tagging.reload() }
                    }
                }
                .frame(width: 90)
            }
            .help("Minimum confidence for a suggestion to appear in the queue")

            Toggle(isOn: Binding(
                get: { tagging.thresholds.autoApplyEnabled },
                set: { tagging.thresholds.autoApplyEnabled = $0 }
            )) {
                Text("Auto-apply ≥ \(Int(tagging.thresholds.autoApply * 100))%")
                    .font(.caption2)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("Apply very-high-confidence tags without review")

            Spacer()

            if tagging.isPropagating {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await tagging.acceptAllAboveThreshold() }
            } label: {
                Label("Accept all ≥ \(Int(tagging.thresholds.autoApply * 100))%",
                      systemImage: "checkmark.circle.fill")
            }
            .controlSize(.small)
            .disabled(tagging.queue.isEmpty || tagging.isPropagating)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Suggestion queue

    @ViewBuilder
    private var suggestionQueue: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Suggestions")
                    .font(.headline)
                Spacer()
                Text("\(tagging.pendingCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            if tagging.queue.isEmpty {
                ContentUnavailableView(
                    "No Suggestions",
                    systemImage: "checkmark.seal",
                    description: Text(tagging.backlogCount > 0
                        ? "Index the catalog, then tag a few images — similar ones will appear here."
                        : "Tag a few images in the strip below — similar ones will appear here."))
            } else {
                List {
                    ForEach(tagging.groupedQueue, id: \.tag) { group in
                        Section {
                            ForEach(group.items, id: \.suggestion.id) { item in
                                SuggestionRow(
                                    item: item,
                                    isSelected: viewModel.selection.contains(item.asset.id ?? -1),
                                    onSelect: { viewModel.selectSingle(item.asset.id) },
                                    onAccept: { Task { await tagging.accept(item.suggestion) } },
                                    onReject: { Task { await tagging.reject(item.suggestion) } })
                            }
                        } header: {
                            Label(group.tag, systemImage: "tag")
                                .font(.subheadline.weight(.semibold))
                                .badge(group.items.count)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: - Detail panel (preview + OCR + tags)

    @ViewBuilder
    private var detailPanel: some View {
        VStack(spacing: 0) {
            DAMBigPreview(asset: displayAsset)
                .frame(minHeight: 240)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // User tags (accent color chips)
                    if !tagging.primaryUserTags.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tags").font(.subheadline.weight(.semibold))
                            FlowTagChips(tags: tagging.primaryUserTags.map { (name: $0, source: .user) })
                        }
                    }
                    // AI classification tags (purple chips with sparkles icon)
                    if !tagging.primaryAITags.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(.purple)
                                Text("AI Tags").font(.subheadline.weight(.semibold))
                            }
                            FlowTagChips(tags: tagging.primaryAITags.map { (name: $0, source: .ai) })
                        }
                    }
                    if let ocr = tagging.primaryOCR, !ocr.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OCR Text").font(.subheadline.weight(.semibold))
                            Text(ocr)
                                .font(.caption)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let status = tagging.statusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Manual tagging strip

    @ViewBuilder
    private var manualStrip: some View {
        VStack(spacing: 0) {
            FilmstripBar(viewModel: viewModel, assets: tagging.untaggedPool)
                .frame(height: 132)
            HStack(spacing: 8) {
                TextField("tag, another tag, …", text: $tagDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyDraft() }
                Button { applyDraft() } label: {
                    Label("Apply to \(viewModel.selection.count) & Learn",
                          systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .disabled(viewModel.selection.isEmpty
                          || tagDraft.trimmingCharacters(in: .whitespaces).isEmpty
                          || tagging.isPropagating)
                .help("Tag the selected images — the AI learns from this and "
                      + "suggests the same tags on similar images")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func applyDraft() {
        let draft = tagDraft
        let selection = viewModel.selection
        tagDraft = ""
        Task {
            await tagging.applyTagsAndLearn(draft, to: selection)
            await viewModel.reload()
        }
    }
}

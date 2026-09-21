import AppKit
import SwiftUI

// MARK: - Quick Look-style Crop Sheet
//
// A modal crop tool that opens from the DAM toolbar (like Finder's Quick Look
// crop). Shows the full-frame image with a draggable crop overlay and saves
// the crop to the asset's non-destructive edit recipe on Done.

struct DAMQuickCropSheet: View {
    let asset: DAMAsset
    let onDismiss: () -> Void

    @State private var edit = DAMEditState()
    @State private var rendered: NSImage?
    @State private var isRendering = false

    var body: some View {
        VStack(spacing: 0) {
            // Title bar with close button.
            HStack {
                Text(asset.filename)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()

            // Image + crop overlay.
            ZStack {
                Color.black
                if let rendered {
                    Image(nsImage: rendered)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)

                    DAMCropOverlay(
                        crop: $edit.crop,
                        imageSize: rendered.size,
                        onChange: {},
                        onEnd: { }
                    )
                    .padding(8)
                } else if isRendering {
                    ProgressView("Loading…")
                        .tint(.white)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 22))
                        Text("Could not load this file")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Action bar.
            HStack(spacing: 16) {
                Button("Reset") {
                    edit.crop = nil
                }
                .disabled(edit.crop == nil)

                Spacer()

                Button("Done") {
                    saveAndDismiss()
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 700)
        .task(id: asset.id ?? 0) { await loadAndRender() }
    }

    private func loadAndRender() async {
        guard let assetId = asset.id else { return }
        await MainActor.run { isRendering = true }
        defer { Task { @MainActor in isRendering = false } }

        let recipe = DAMDatabase.shared.loadEdits(assetId: assetId) ?? DAMEditState()
        await MainActor.run { edit = recipe }

        let displayRecipe = recipe.forCropEditing
        do {
            let image = try DAMEditRenderer.render(
                asset: asset,
                edit: displayRecipe,
                maxPixelSize: 1600,
                showRedactions: false
            )
            await MainActor.run { rendered = image }
        } catch {
            NSLog("[DAMQuickCropSheet] render failed: %@", "\(error)")
        }
    }

    private func saveAndDismiss() {
        guard let assetId = asset.id else {
            onDismiss()
            return
        }
        let recipe = edit
        try? DAMDatabase.shared.saveEdits(assetId: assetId, recipe)
        onDismiss()
    }
}


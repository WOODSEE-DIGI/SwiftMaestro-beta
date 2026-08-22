import SwiftUI

// MARK: - Tagging workspace subviews
//
// Suggestion rows for the AI queue and the simple wrapping tag-chip flow
// used in the detail panel.

/// One pending suggestion: thumbnail, filename, confidence bar with the
/// evidence-basis icon, and accept/reject actions. Tapping the row selects
/// the asset (drives the big preview + OCR panel).
struct SuggestionRow: View {
    let item: (suggestion: DAMTagSuggestion, asset: DAMAsset)
    let isSelected: Bool
    let onSelect: () -> Void
    let onAccept: () -> Void
    let onReject: () -> Void

    @State private var image: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if let image {
                    Image(nsImage: image)
                        .resizable().aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.asset.filename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Image(systemName: DAMTaggingViewModel.basisIcon(item.suggestion.basis))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ProgressView(value: item.suggestion.confidence)
                        .progressViewStyle(.linear)
                        .tint(confidenceColor)
                    Text("\(Int(item.suggestion.confidence * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onAccept) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .help("Accept — tag this asset and keep learning")

            Button(action: onReject) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Reject — never suggest this tag for this image again")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                .padding(.horizontal, 2)
        )
        .help(DAMTaggingViewModel.basisLabel(item.suggestion.basis)
              + " — \(item.asset.path)")
        .task {
            image = try? await ThumbnailService.shared.thumbnail(
                for: URL(fileURLWithPath: item.asset.path))
        }
    }

    private var confidenceColor: Color {
        switch item.suggestion.confidence {
        case 0.9...: return .green
        case 0.75..<0.9: return .blue
        default: return .orange
        }
    }
}

/// Minimal wrapping chip layout for the detail panel's tag list.
/// (No dependency on external flow-layout packages.)
struct FlowTags: View {
    let tags: [String]

    var body: some View {
        // Adaptive grid approximates a flow layout for short tag lists.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 70), spacing: 6)],
            alignment: .leading, spacing: 6
        ) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .lineLimit(1)
            }
        }
    }
}

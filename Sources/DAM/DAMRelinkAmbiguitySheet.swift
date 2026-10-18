import SwiftUI

// MARK: - Relink ambiguity resolution sheet
//
// Presented when a relink finds the same filename in more than one place
// under the new root (common when pointing at a whole drive). The user picks
// the correct file for each ambiguous asset; unselected assets are skipped.
// Each candidate shows a thumbnail plus size/dimensions/date metadata so the
// user can tell similar paths apart and spot duplicates.

struct DAMRelinkAmbiguitySheet: View {
    let ambiguities: [DAMRelinkAmbiguity]
    let onResolve: ([Int64: URL]) -> Void
    let onCancel: () -> Void

    @State private var choices: [Int64: URL] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()

            List {
                ForEach(Array(ambiguities.enumerated()), id: \.offset) { _, ambiguity in
                    AmbiguityRow(ambiguity: ambiguity, choices: $choices)
                }
            }

            footer
                .padding()
        }
        .frame(minWidth: 780, minHeight: 520)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Multiple matches found")
                .font(.headline)
            Text("Choose the correct file for each asset below. Thumbnails and metadata show what each candidate actually is.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                onCancel()
            }
            Spacer()
            Text("\(choices.count)/\(ambiguities.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                onResolve(choices)
            } label: {
                Text("Relink Selected")
            }
            .disabled(choices.count != ambiguities.count)
            .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Row subviews

private struct AmbiguityRow: View {
    let ambiguity: DAMRelinkAmbiguity
    @Binding var choices: [Int64: URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(ambiguity.asset.filename)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if let size = ambiguity.asset.fileSize {
                    MetadataBadge(text: ByteCountFormatter.string(fromByteCount: size, countStyle: .file), accent: false)
                }
                if let date = ambiguity.asset.fileModDate {
                    MetadataBadge(text: Self.dateFormatter.string(from: date), accent: false)
                }
                if let w = ambiguity.asset.width, let h = ambiguity.asset.height {
                    MetadataBadge(text: "\(w)×\(h)", accent: false)
                }
            }

            Text("was: \(ambiguity.asset.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(ambiguity.candidates.enumerated()), id: \.offset) { _, candidate in
                    CandidateButton(
                        candidate: candidate,
                        asset: ambiguity.asset,
                        assetId: ambiguity.id,
                        choices: $choices
                    )
                }
            }
            .padding(.leading, 4)
        }
        .padding(.vertical, 6)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct CandidateButton: View {
    let candidate: URL
    let asset: DAMAsset
    let assetId: Int64
    @Binding var choices: [Int64: URL]

    @State private var thumbnail: NSImage?
    @State private var metadata: CandidateMetadata?

    private var isSelected: Bool {
        choices[assetId] == candidate
    }

    var body: some View {
        Button {
            choices[assetId] = candidate
        } label: {
            HStack(spacing: 12) {
                // Thumbnail
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))

                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 80, height: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )

                // Path + metadata
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.path)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(2)
                        .truncationMode(.head)

                    HStack(spacing: 6) {
                        if let metadata {
                            if let size = metadata.fileSize {
                                let same = asset.fileSize.map { abs($0 - size) == 0 } ?? false
                                MetadataBadge(
                                    text: ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                                    accent: same
                                )
                            }
                            if let date = metadata.modDate {
                                let same = asset.fileModDate.map { abs($0.timeIntervalSince(date)) < 60 } ?? false
                                MetadataBadge(
                                    text: Self.dateFormatter.string(from: date),
                                    accent: same
                                )
                            }
                                } else {
                            Text("Reading metadata…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .opacity(isSelected ? 1.0 : 0.4)
                    .font(.title3)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task {
            await loadThumbnail()
            metadata = CandidateMetadata(url: candidate)
        }
    }

    private func loadThumbnail() async {
        // Use the out-of-process sips-based decoder for camera RAW files. The
        // vendored LibRaw decoder is fast but can crash (EXC_BAD_ACCESS) on
        // malformed RAWs; because the ambiguity sheet may load hundreds of
        // arbitrary files, we must not bring the app down on one bad file.
        if DAMFileKind.isCameraRAW(candidate) || DAMFileKind.isLibRAWOnly(candidate) {
            thumbnail = await DAMSafeRAWThumbnailService.shared.thumbnail(
                for: candidate.path,
                maxPixelSize: 128
            )
            return
        }

        do {
            let image = try await ThumbnailService.shared.thumbnail(for: candidate, pixelSize: 128)
            thumbnail = image
        } catch {
            thumbnail = nil
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Metadata helpers

private struct CandidateMetadata {
    let fileSize: Int64?
    let modDate: Date?

    init(url: URL) {
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ])
        self.fileSize = values?.fileSize.map(Int64.init)
        self.modDate = values?.contentModificationDate
    }
}

private struct MetadataBadge: View {
    let text: String
    let accent: Bool

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(accent ? .semibold : .regular)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(accent ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15))
            .foregroundStyle(accent ? Color.accentColor : .secondary)
            .clipShape(Capsule())
    }
}

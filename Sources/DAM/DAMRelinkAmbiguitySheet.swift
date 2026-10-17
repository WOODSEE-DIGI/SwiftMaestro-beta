import SwiftUI

// MARK: - Relink ambiguity resolution sheet
//
// Presented when a relink finds the same filename in more than one place
// under the new root (common when pointing at a whole drive). The user picks
// the correct file for each ambiguous asset; unselected assets are skipped.

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
        .frame(minWidth: 560, minHeight: 320)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Multiple matches found")
                .font(.headline)
            Text("Choose the correct file for each asset below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(ambiguity.asset.filename)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Text("was: \(ambiguity.asset.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(ambiguity.candidates.enumerated()), id: \.offset) { _, candidate in
                    CandidateButton(
                        candidate: candidate,
                        assetId: ambiguity.id,
                        choices: $choices
                    )
                }
            }
            .padding(.leading, 8)
        }
        .padding(.vertical, 4)
    }
}

private struct CandidateButton: View {
    let candidate: URL
    let assetId: Int64
    @Binding var choices: [Int64: URL]

    private var isSelected: Bool {
        choices[assetId] == candidate
    }

    var body: some View {
        Button {
            choices[assetId] = candidate
        } label: {
            HStack(spacing: 8) {
                Text(candidate.path)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .opacity(isSelected ? 1.0 : 0.4)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

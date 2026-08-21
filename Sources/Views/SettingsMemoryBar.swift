import SwiftUI

/// Live system-memory graphic for Settings → Models — the same data the
/// model-load guard uses (`host_statistics64` via `SystemMemory`), rendered as
/// a segmented bar in the style of Activity Monitor / model-monitor widgets:
/// Wired (red), Used (orange), Cache (blue), Compressed (purple), Free
/// (green), Other (gray).
///
/// The bar is SYSTEM-WIDE, not per-process — it deliberately includes memory
/// held by other apps and by other logged-in user sessions (fast user
/// switching), so a user can SEE when another session is holding a model and a
/// big local load is a bad idea.
///
/// A white tick marks SwiftMaestro's model-residency budget; the caption line
/// under the legend names what this app itself is holding resident.
struct SettingsMemoryBar: View {

    /// Bytes this app is currently holding in resident models (estimated).
    let residentModelBytes: Int
    /// The engine's residency budget in bytes (where the white tick sits).
    let residentBudgetBytes: Int

    /// Refresh cadence while the tab is visible. 2s is cheap (one syscall) and
    /// feels live without distracting.
    private let refreshInterval: TimeInterval = 2

    @State private var snapshot: SystemMemorySnapshot? = SystemMemory.snapshot()

    private struct Segment: Identifiable {
        let id: String
        let label: String
        let bytes: Int
        let color: Color
    }

    private func segments(for snap: SystemMemorySnapshot) -> [Segment] {
        [
            Segment(id: "wired", label: "Wired", bytes: snap.wiredBytes, color: .red),
            Segment(id: "used", label: "Used", bytes: snap.usedBytes, color: .orange),
            Segment(id: "cache", label: "Cache", bytes: snap.cacheBytes, color: .blue),
            Segment(id: "compressed", label: "Compressed", bytes: snap.compressedBytes, color: .purple),
            Segment(id: "free", label: "Free", bytes: snap.freeBytes, color: .green),
            Segment(id: "other", label: "Other", bytes: snap.otherBytes, color: .gray),
        ]
    }

    private static func gb(_ bytes: Int) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
    }

    var body: some View {
        Group {
            if let snap = snapshot {
                content(for: snap)
            } else {
                Text("System memory statistics unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onReceive(
            Timer.publish(every: refreshInterval, on: .main, in: .common).autoconnect()
        ) { _ in
            snapshot = SystemMemory.snapshot()
        }
    }

    @ViewBuilder
    private func content(for snap: SystemMemorySnapshot) -> some View {
        let segs = segments(for: snap)
        let total = max(1, snap.totalBytes)

        VStack(alignment: .leading, spacing: 10) {
            // Segmented bar with a residency-budget tick.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    HStack(spacing: 1) {
                        ForEach(segs) { seg in
                            if seg.bytes > 0 {
                                seg.color
                                    .frame(width: max(0, geo.size.width * CGFloat(seg.bytes) / CGFloat(total) - 1))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                    // Residency budget tick — models past this point get
                    // evicted; a single new model larger than the gap to the
                    // tick is refused by the load guard.
                    let tickX = geo.size.width
                        * CGFloat(min(residentBudgetBytes, snap.totalBytes)) / CGFloat(total)
                    Rectangle()
                        .fill(.white.opacity(0.9))
                        .frame(width: 2, height: geo.size.height + 4)
                        .offset(x: tickX - 1, y: -2)
                }
            }
            .frame(height: 18)

            // Legend.
            HStack(spacing: 14) {
                ForEach(segs) { seg in
                    HStack(spacing: 4) {
                        Circle().fill(seg.color).frame(width: 8, height: 8)
                        Text(seg.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(Self.gb(seg.bytes))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Text("\(Self.gb(snap.availableBytes)) available right now (free + cache). "
                + "SwiftMaestro holds ~\(residentModelBytes / 1_073_741_824) GB in resident models "
                + "of its ~\(residentBudgetBytes / 1_073_741_824) GB budget (white tick). "
                + "Another user account's models count toward Wired/Used — they shrink what "
                + "you can load here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

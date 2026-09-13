import SwiftUI

/// A btop/terminal-style animated scanning indicator.
///
/// Use this while waiting for filesystem or hardware scans so the user has
/// obvious visual proof that work is happening in the background.
struct RetroScanIndicator: View {
    let message: String

    @State private var tick = 0
    private let blockCount = 24
    private let timer = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 2) {
                ForEach(0..<blockCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color(for: index))
                        .frame(width: 7, height: 14)
                        .animation(.easeInOut(duration: 0.05), value: tick)
                }
            }
        }
        .onReceive(timer) { _ in
            tick = (tick + 1) % (blockCount * 2)
        }
    }

    private func color(for index: Int) -> Color {
        let width = 6
        let head = tick % (blockCount + width)
        let distance = abs(index - head)

        if distance == 0 {
            return .green
        } else if distance <= 2 {
            return .yellow
        } else if distance <= width {
            return .green.opacity(Double(width - distance) / Double(width) * 0.6 + 0.1)
        } else {
            return .gray.opacity(0.25)
        }
    }
}

/// Full-screen overlay used when the whole view is blocked on an initial scan.
struct RetroLoadingOverlay: View {
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            RetroScanIndicator(message: message)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

#Preview {
    RetroScanIndicator(message: "Scanning drives…")
        .padding()
}

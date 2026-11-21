import SwiftUI

// MARK: - Engine Status Bar

/// Compact engine readout shown at the bottom of the Agents window: state
/// dot, tokens/second while generating, and every resident model with its
/// memory footprint.
struct EngineStatusBar: View {
    @Environment(MLXInferenceEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if engine.tokensPerSecond > 0 {
                    Text(String(format: "%.1f tok/s", engine.tokensPerSecond))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if !engine.residentModelsReadout.isEmpty {
                ForEach(engine.residentModelsReadout) { model in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(model.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .help(model.name)
                        Spacer(minLength: 4)
                        Text("~\(model.gb) GB")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var statusColor: Color {
        switch engine.state {
        case .idle: return .gray
        case .loading: return .orange
        case .ready: return .green
        case .generating: return .blue
        case .downloading: return .cyan
        case .error: return .red
        }
    }

    private var statusText: String {
        switch engine.state {
        case .idle: return "Ready"
        case .loading(let name): return "Loading \(name)…"
        case .ready: return "Ready"
        case .generating: return "Generating…"
        case .downloading(let name): return name
        case .error(let msg): return msg
        }
    }
}

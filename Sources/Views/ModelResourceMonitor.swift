import SwiftUI

/// Per-model activity monitor showing a status card + sparkline for each
/// active or recently active model, similar to the process resource monitor.
struct ModelResourceMonitor: View {
    @Environment(MLXInferenceEngine.self) private var engine
    private let sampler = ModelActivitySampler.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(activeModels) { activity in
                modelCard(activity)
            }
        }
    }

    /// Models currently resident in the engine, merged with any the sampler
    /// has tracked recently. Most-recently-used first.
    private var activeModels: [ModelActivity] {
        let residentIDs = Set(engine.residentModelsReadout.map(\.id))
        let trackedIDs = Set(sampler.models.keys)
        let allIDs = residentIDs.union(trackedIDs)

        return allIDs
            .compactMap { id -> ModelActivity? in
                if var activity = sampler.models[id] {
                    return activity
                }
                guard let readout = engine.residentModelsReadout.first(where: { $0.id == id }) else {
                    return nil
                }
                return ModelActivity(
                    id: readout.id,
                    name: readout.name,
                    estimatedMemoryGB: readout.gb,
                    state: .idle)
            }
            .sorted {
                let lhsActive = $0.state == .generating ? 1 : 0
                let rhsActive = $1.state == .generating ? 1 : 0
                if lhsActive != rhsActive { return lhsActive > rhsActive }
                return ($0.lastUsed ?? Date.distantPast) > ($1.lastUsed ?? Date.distantPast)
            }
    }

    private func modelCard(_ activity: ModelActivity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow(activity)
            metricsRow(activity)
            sparklineRow(activity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func headerRow(_ activity: ModelActivity) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "cube")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("Loaded model")
            Text(activity.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Button {
                engine.unloadModel(activity.id)
                sampler.remove(id: activity.id)
            } label: {
                Image(systemName: "eject")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Unload \(activity.name) from memory")
            statusBadge(activity)
        }
    }

    private func statusBadge(_ activity: ModelActivity) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(activity.state))
                .frame(width: 6, height: 6)
            Text(statusText(activity.state))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func metricsRow(_ activity: ModelActivity) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Model memory footprint")
                Text("\(activity.estimatedMemoryGB) GB")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if activity.state == .generating {
                HStack(spacing: 4) {
                    Image(systemName: "bolt")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Generation speed")
                    Text(String(format: "%.1f tok/s", activity.currentTokensPerSecond))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if activity.currentTokensPerSecond > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "bolt")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Generation speed")
                    Text(String(format: "%.1f tok/s", activity.currentTokensPerSecond))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sparklineRow(_ activity: ModelActivity) -> some View {
        let samples = activity.history.map(\.tokensPerSecond)
        let accent = activity.state == .generating ? Color.blue : Color.green
        return ZStack {
            // Sparkline shows tokens/second history for this model.
            if samples.isEmpty {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.05))
                    .overlay(
                        Text("No activity yet")
                            .font(.caption2)
                            .foregroundStyle(.secondary.opacity(0.6))
                    )
            } else {
                Sparkline(samples: samples)
                    .fill(accent.opacity(0.25))
                    .overlay(
                        Sparkline(samples: samples)
                            .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(accent)
                    )
            }
        }
        .frame(height: 24)
    }

    private func statusColor(_ state: ModelActivityState) -> Color {
        switch state {
        case .loading: return .orange
        case .generating: return .blue
        case .idle: return .green
        }
    }

    private func statusText(_ state: ModelActivityState) -> String {
        switch state {
        case .loading: return "Loading"
        case .generating: return "Generating"
        case .idle: return "Ready"
        }
    }
}

import SwiftUI

// MARK: - Risk Badge

/// A small badge that displays a risk flag severity with an icon and colour.
struct RiskBadge: View {
    let flag: RiskFlag?

    var body: some View {
        if let flag {
            Label(flag.severity.displayName, systemImage: icon(for: flag.severity))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color(for: flag.severity).opacity(0.15))
                .foregroundStyle(color(for: flag.severity))
                .clipShape(Capsule())
                .help("\(flag.reason) • \(flag.reportCount) report(s)")
        }
    }

    private func icon(for severity: RiskFlag.Severity) -> String {
        switch severity {
        case .info:     return "info.circle"
        case .low:      return "exclamationmark.triangle"
        case .medium:   return "exclamationmark.triangle.fill"
        case .high:     return "xmark.shield"
        case .critical: return "xmark.shield.fill"
        }
    }

    private func color(for severity: RiskFlag.Severity) -> Color {
        switch severity {
        case .info:     return .blue
        case .low:      return .yellow
        case .medium:   return .orange
        case .high:     return .red
        case .critical: return .purple
        }
    }
}

// MARK: - Risk Flag Detail Sheet

/// Explains why a contact is flagged and what the user can do.
struct RiskFlagDetailSheet: View {
    let flag: RiskFlag
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                RiskBadge(flag: flag)
                Spacer()
                Button("Done") { dismiss() }
            }
            Text(flag.reason)
                .font(.body)
                .foregroundStyle(theme.chatText)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    DetailRow(label: "Reports", value: "\(flag.reportCount)")
                    DetailRow(label: "Last reported", value: flag.lastReported)
                    DetailRow(label: "Source", value: flag.source.rawValue.uppercased())
                }
            }
            Text("This flag is based on reports from other SwiftMaestro users. It does not prove the entity is currently unreliable — use it as one signal among many and do your own enquiries.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .frame(minWidth: 320, minHeight: 220)
        .background(theme.chatBackground)
    }
}

// MARK: - Risk Flag Banner

struct RiskFlagBanner: View {
    let flag: RiskFlag
    @State private var showDetail = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: flag.severity))
                .foregroundStyle(color(for: flag.severity))
            VStack(alignment: .leading, spacing: 2) {
                Text("Risk flag: \(flag.severity.displayName)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color(for: flag.severity))
                Text(flag.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Review") { showDetail = true }
                .controlSize(.small)
        }
        .padding(10)
        .background(color(for: flag.severity).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $showDetail) {
            RiskFlagDetailSheet(flag: flag)
        }
    }

    private func icon(for severity: RiskFlag.Severity) -> String {
        switch severity {
        case .info:     return "info.circle"
        case .low:      return "exclamationmark.triangle"
        case .medium:   return "exclamationmark.triangle.fill"
        case .high:     return "xmark.shield"
        case .critical: return "xmark.shield.fill"
        }
    }

    private func color(for severity: RiskFlag.Severity) -> Color {
        switch severity {
        case .info:     return .blue
        case .low:      return .yellow
        case .medium:   return .orange
        case .high:     return .red
        case .critical: return .purple
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    init(label: String, value: Date) {
        self.label = label
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        self.value = formatter.string(from: value)
    }

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

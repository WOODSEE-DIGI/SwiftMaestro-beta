import SwiftUI

// MARK: - Shell Approval Banner

/// A banner view that shows when a shell command requires user approval.
public struct ShellApprovalBanner: View {
    @ObservedObject private var approvalStore = ShellApprovalStore.shared
    @State private var editedCommands: [UUID: String] = [:]
    @State private var expirationTimer: Timer?

    let onApprove: (UUID, Bool) -> Void
    let onDeny: (UUID) -> Void

    public init(
        onApprove: @escaping (UUID, Bool) -> Void = { _, _ in },
        onDeny: @escaping (UUID) -> Void = { _ in }
    ) {
        self.onApprove = onApprove
        self.onDeny = onDeny
    }

    public var body: some View {
        Group {
            if let approval = activeApproval {
                bannerView(approval)
            }
        }
        .onAppear {
            startExpirationTimer()
        }
        .onDisappear {
            expirationTimer?.invalidate()
        }
    }

    private var activeApproval: ShellApprovalRequest? {
        approvalStore.activeApprovals.first
    }

    @ViewBuilder
    private func bannerView(_ approval: ShellApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with classification badge
            HStack {
                classificationBadge(approval.classification)
                Text("Shell Command Requires Approval")
                    .font(.headline)
                Spacer()
            }

            // Agent name
            HStack {
                Image(systemName: "person.circle")
                Text("Requested by: \(approval.agentName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Command (editable)
            VStack(alignment: .leading, spacing: 4) {
                Text("Command:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Edit command...", text: .init(
                    get: { editedCommands[approval.id] ?? approval.command },
                    set: { editedCommands[approval.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            }

            // Cwd (read-only)
            HStack {
                Image(systemName: "folder")
                Text("Working directory: \(approval.cwd.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Reason (if provided)
            if let reason = approval.reason, !reason.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reason:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Expiration timer
            Text("Expires in: \(formatTime(approval.timeRemaining))")
                .font(.caption2)
                .foregroundStyle(.orange)

            // Action buttons
            HStack(spacing: 12) {
                Button("Deny") {
                    approvalStore.deny(id: approval.id)
                    onDeny(approval.id)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button("Approve Once") {
                    let command = editedCommands[approval.id] ?? approval.command
                    handleApproval(approval.id, command: command, remember: false)
                }
                .buttonStyle(.borderedProminent)

                Button("Approve and Remember") {
                    let command = editedCommands[approval.id] ?? approval.command
                    handleApproval(approval.id, command: command, remember: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.orange, lineWidth: 2)
        )
        .padding(.horizontal)
        .padding(.top)
    }

    private func classificationBadge(_ classification: ShellPolicyClassification) -> some View {
        let (icon, color, label) = classificationBadgeInfo(classification)
        return HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label)
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.2))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    private func classificationBadgeInfo(_ classification: ShellPolicyClassification) -> (String, Color, String) {
        switch classification {
        case .allowed:
            return ("checkmark.circle.fill", .green, "Always Allow")
        case .ask:
            return ("questionmark.circle.fill", .orange, "Always Ask")
        case .denied:
            return ("xmark.circle.fill", .red, "Never Allow")
        case .unknown:
            return ("info.circle.fill", .blue, "Unknown")
        }
    }

    private func handleApproval(_ id: UUID, command: String, remember: Bool) {
        // If command was edited, reclassify it
        if command != approvalStore.getApproval(id: id)?.command {
            let newClassification = ShellPolicyStore.shared.classify(command)
            if newClassification == .denied {
                // Edited command is denied
                return
            }
        }
        approvalStore.approve(id: id, remember: remember)
        onApprove(id, remember)
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }

    private func startExpirationTimer() {
        expirationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            approvalStore.cleanupExpired()
        }
    }
}

// MARK: - Preview

#Preview {
    ShellApprovalBanner(
        onApprove: { _, _ in print("Approved") },
        onDeny: { _ in print("Denied") }
    )
    .frame(maxWidth: 600)
    .padding()
}

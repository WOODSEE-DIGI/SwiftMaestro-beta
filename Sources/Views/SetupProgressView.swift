import SwiftUI

/// First-run dependency-install screen (Photoshop / DaVinci Resolve style).
///
/// Shown instead of the welcome sheet whenever `SetupProgressService` has
/// planned install work for this launch. The whole point: a new user's first
/// experience must NEVER be a spinning beachball with no explanation — the
/// app stays responsive (all install work runs off the main thread) and this
/// sheet names exactly what is being installed, live, line by line.
struct SetupProgressView: View {
    @State private var setup = SetupProgressService.shared

    /// Dismiss the sheet while work continues in the background.
    let onContinueInBackground: () -> Void
    /// Dismiss the sheet after all work is done.
    let onFinished: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.vertical, 16)
            stepList
            Spacer(minLength: 16)
            activityLine
            overallBar
            footer
        }
        .padding(28)
        .frame(width: 560, height: 470)
        .interactiveDismissDisabled()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text("Setting up SwiftMaestro")
                    .font(.title.bold())
                Text("Installing built-in components. This only happens on first launch — "
                    + "the app is not frozen and stays fully usable while this finishes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step list

    private var stepList: some View {
        VStack(spacing: 12) {
            ForEach(setup.steps) { step in
                HStack(alignment: .top, spacing: 12) {
                    statusIcon(for: step)
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(step.outcome == .pending ? .secondary : .primary)
                        if !step.detail.isEmpty {
                            Text(step.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if case .running = step.outcome, let progress = step.progress {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statusIcon(for step: SetupStep) -> some View {
        switch step.outcome {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary.opacity(0.5))
        case .running:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Live activity line (the beachball replacement)

    private var activityLine: some View {
        HStack(spacing: 8) {
            Image(systemName: setup.isComplete ? "checkmark.seal.fill" : "gearshape.2")
                .foregroundStyle(setup.isComplete ? .green : .secondary)
                .font(.caption)
            Text(setup.currentActivity)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Keep the line from shifting layout as text changes.
                .animation(.none, value: setup.currentActivity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - Overall progress

    private var overallBar: some View {
        ProgressView(value: setup.overallProgress) {
            EmptyView()
        }
        .progressViewStyle(.linear)
        .padding(.top, 10)
    }

    // MARK: - Footer buttons

    private var footer: some View {
        HStack {
            if setup.isComplete {
                Spacer()
                Button("Get Started") { onFinished() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Text("You can keep exploring — setup will finish on its own.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Continue in Background") { onContinueInBackground() }
            }
        }
        .padding(.top, 16)
    }
}

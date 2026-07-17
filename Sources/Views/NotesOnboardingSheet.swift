import SwiftUI

// MARK: - Notes onboarding sheet

/// First-run prompt for Notes.md: lets the user choose iCloud Drive sync
/// (default ON) or a local Documents vault. The choice is persisted so it
/// only appears once.
struct NotesOnboardingSheet: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss
    let onDone: () -> Void

    @State private var useICloud = true
    @State private var isICloudAvailable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes.md")
                    .font(.largeTitle.bold())
                Text("Choose where your SwiftMaestro notes vault lives.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "icloud.and.arrow.up")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sync with iCloud Drive")
                                .font(.body.weight(.semibold))
                            Text("Notes sync across your Apple devices and are visible in iCloud Drive.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $useICloud)
                            .labelsHidden()
                            .disabled(!isICloudAvailable)
                    }

                    if !isICloudAvailable {
                        Label("iCloud Drive is not available on this Mac; notes will be stored locally.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Local Documents")
                                .font(.body.weight(.semibold))
                            Text("Notes stay in ~/Documents/SwiftMaestro Notes and are not synced.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .opacity(useICloud && isICloudAvailable ? 0.5 : 1.0)
                }
                .padding(6)
            }

            Text("You can change this later in Settings → Notes.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("Use Local") {
                    apply(useICloud: false)
                }
                Spacer()
                Button("Continue") {
                    apply(useICloud: useICloud)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled()
        .onAppear {
            isICloudAvailable = NotesiCloudSupport.iCloudVaultURL != nil
            if !isICloudAvailable {
                useICloud = false
            }
        }
    }

    private func apply(useICloud: Bool) {
        NotesiCloudSupport.isEnabled = useICloud && isICloudAvailable
        NotesiCloudSupport.onboardingChoiceMade = true
        // Notify the NotesViewModel singleton to pick up the new default.
        NotificationCenter.default.post(name: .notesVaultDefaultsChanged, object: nil)
        onDone()
    }
}

extension Notification.Name {
    static let notesVaultDefaultsChanged = Notification.Name("notesVaultDefaultsChanged")
}
